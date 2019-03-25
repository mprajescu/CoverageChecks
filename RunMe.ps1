<#
	.SYNOPSIS
		ECI Coverage check automation
	
	.DESCRIPTION
		Automatically finds and checks for the most common problems in a variety of areas
	
	.PARAMETER IgnoredServers
        An array of server names or IP addresses to ignore / not attempt to gather information
        
    .PARAMETER SendEmail
        If this flag is added, the script will try to send an email after the checks complete

    .PARAMETER TargetEmail
        Which address(s) to send the report to. Only active if SendEmail is also used

    .PARAMETER MailServer
        Which SMTP server to use. Only active if SendEmail is also used

    .PARAMETER MailPort
        Which port to use. Only active if SendEmail is also used

    .PARAMETER FromEmail
        Which address to show as FROM. Only active if SendEmail is also used

	.EXAMPLE
		PS C:\> .\RunMe.ps1 
	
    .NOTES
        Andrew de la Pole
        2019
	
    .LINK
        www.eci.com
#>
[CmdletBinding()]
Param (
    [Parameter(HelpMessage = "An array of server names (strings) to exclude from checks).")]
    [ValidateNotNullOrEmpty()]
    [string[]]$IgnoredServers = @(""),

    [Parameter(HelpMessage = "Send an email report once checks are complete")]
    [ValidateNotNullOrEmpty()]
    [switch]$SendEmail,

    [Parameter(HelpMessage = "The email address to send the report to")]
    [ValidateNotNullOrEmpty()]
    [string]$TargetEmail = "recipient@example.com",
	
    [Parameter(HelpMessage = "The SMTP relay to send the mail to / from")]
    [ValidateNotNullOrEmpty()]
	[string]$MailServer = "mail.example.com",
	
    [Parameter(HelpMessage = "The port used. Default = 25")]
    [ValidateNotNullOrEmpty()]
	[int]$MailPort = 25,
	
    [Parameter(HelpMessage = "The from email address")]
    [ValidateNotNullOrEmpty()]
	[string]$FromEmail = "ServerChecks@example.com"
)

# Convert SwitchParameter type to boolean
$OnlyShowWarnings = $OnlyShowWarnings -as [boolean]

# Check if verbose flag is set to later dump more info
$IsVerbose = $PSCmdlet.MyInvocation.BoundParameters["Verbose"].IsPresent

# Get PSScriptRoot on PS 2.0
if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
}

# Todays date in filename compatible format
$Today = (Get-Date -Format "dd-MM-yy")

# Stop any current transcript / logging & restart logging to same folder as it's run
$ErrorActionPreference = "SilentlyContinue"
Stop-Transcript | Out-Null
$ErrorActionPreference = "Continue"
Start-Transcript -Path (Join-Path -Path $PSScriptRoot -ChildPath "$Today.log") -Append

# Required modules
Import-Module ActiveDirectory -ErrorAction Stop

# Optional modules
#Import-Module FailoverClusters,VMWare.PowerCLI -ErrorAction SilentlyContinue

# Make sure that the user running script is a domain admin
# Ensures full access to all servers for full info grab
# Can replace with another administrator level group if required i.e. ServerAdmins 
$RunningUser = Get-ADUser ($env:USERNAME) -ErrorAction Stop
Write-Verbose "Script running as: $($env:USERNAME)@$($env:USERDNSDOMAIN)"
$RunningUserGroups = Get-ADGroup -LDAPFilter ("(member:1.2.840.113556.1.4.1941:={0})" -f ($RunningUser.DistinguishedName)) | Select-Object -ExpandProperty Name
If ($RunningUserGroups -Contains "Domain Admins") {
    Write-Verbose "$($env:USERNAME)@$($env:USERDNSDOMAIN) is a domain admin"
} else {
    # If user is not a domain admin then stop script
    Write-Warning "$($env:USERNAME)@$($env:USERDNSDOMAIN) is not a domain admin!"
    Write-Warning "Exiting script..."
    exit
}

########################################################
# BEGIN DEFINE FUNCTIONS

function Get-DfsrBacklog {
<#
    .SYNOPSIS
        Gets DFSR backlogs
    
    .DESCRIPTION
        Gets DFSR backlogs
    
    .PARAMETER ComputerName
        The computer to get DFSR backlogs from
    
    .EXAMPLE
        PS C:\> Get-DfsrBacklog -ComputerName DC01

        Get the backlog information from one DC
    
    .EXAMPLE
        PS C:\> $DCList = Get-ADDomainController -Filter * | Select-Object -ExpandProperty Name
        PS C:\> Get-DfsrBacklog -ComputerName $DCList | Format-Table -AutoSize

        Get backlog info from all DCs in the current domain
    
    .NOTES
        Original from the internet (unsure of exact source)
        Updated 2019-03-20 by Andy DLP
        adelapole@eci.com

    .LINK
        www.eci.com
#>
    
    [CmdletBinding(PositionalBinding = $true)]
    param
    (
        [Parameter(Mandatory = $true,
                    ValueFromPipeline = $true,
                    ValueFromPipelineByPropertyName = $true,
                    Position = 0,
                    HelpMessage = 'The computername from which to check backlog')]
        [ValidateNotNullOrEmpty()]
        [string[]]$ComputerName
    )

    begin {}

    process {
        foreach ($computer in $ComputerName) {
            Write-Verbose "Connecting to $computer"
            $RGroups = Get-WmiObject -Namespace "root\MicrosoftDFS" -Query "SELECT * FROM DfsrReplicationGroupConfig" -ComputerName $computer
            foreach ($Group in $RGroups) {
                Write-Verbose "Replication group $($Group.ReplicationGroupName)"
                $RGFoldersWMIQ = "SELECT * FROM DfsrReplicatedFolderConfig WHERE ReplicationGroupGUID='" + $Group.ReplicationGroupGUID + "'"
                $RGFolders = Get-WmiObject -Namespace "root\MicrosoftDFS" -Query  $RGFoldersWMIQ -ComputerName $computer
                $RGConnectionsWMIQ = "SELECT * FROM DfsrConnectionConfig WHERE ReplicationGroupGUID='"+ $Group.ReplicationGroupGUID + "'"
                $RGConnections = Get-WmiObject -Namespace "root\MicrosoftDFS" -Query $RGConnectionsWMIQ -ComputerName $computer
                foreach ($Connection in $RGConnections) {
                    $ConnectionName = $Connection.PartnerName#.Trim()
                    if ($Connection.Enabled -eq $True) {
                        foreach ($Folder in $RGFolders) {
                            $RGName = $Group.ReplicationGroupName
                            $RFName = $Folder.ReplicatedFolderName
                            if ($Connection.Inbound -eq $True) {
                                $SendingMember = $ConnectionName
                                $ReceivingMember = $computer
                            } else {
                                $SendingMember = $computer
                                $ReceivingMember = $ConnectionName
                            }

                            $outputObjectParams = @{
                                ComputerName = $computer
                                ReplicationGroupname = $RGName
                                SendingMember = $SendingMember
                                ReceivingMember = $ReceivingMember
                            }

                            if ((Get-Item 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion' | Get-ItemProperty).installationtype -ne 'Server Core') {
                                # Neither DFSRdiag nor DFSR diag tool are available on server core? :(
                                $BLCommand = "dfsrdiag Backlog /RGName:'" + $RGName + "' /RFName:'" + $RFName + "' /SendingMember:" + $SendingMember + " /ReceivingMember:" + $ReceivingMember
                                if ($computer -eq $env:ComputerName) {
                                    $Backlog = Invoke-Expression -Command $BLCommand
                                } else {
                                    $Backlog = Invoke-Command -ComputerName $computer -HideComputerName -ScriptBlock {
                                        $Backlog = Invoke-Expression -Command $args[0]
                                        $Backlog
                                    } -ArgumentList $BLCommand
                                }
                                $BackLogFilecount = 0
                                foreach ($item in $Backlog) {
                                    if ($item -ilike "*Backlog File count*") {
                                        $BacklogFileCount = [int]$Item.Split(":")[1].Trim()
                                    }
                                }
                                Write-Verbose "$BacklogFileCount files in backlog $SendingMember->$ReceivingMember for $RGName"
                                $outputObjectParams.Add('BacklogFileCount',$BackLogFilecount)
                            } else {
                                Write-Verbose "DFSRDIAG tool / DFSR PS cmdlets are not available on Server Core! Skipping..."
                                $outputObjectParams.Add('BacklogFileCount',-1)
                            }
                            $outputObject = [PSCustomObject]$outputObjectParams
                            $outputObject
                        } # Closing iterate through all folders
                    } # Closing  If Connection enabled
                } # Closing iteration through all connections
            } # Closing iteration through all groups
        } # foreach computer
    } # process

    end {}
}

function Get-RecentUpdateInfo {
<#
    .SYNOPSIS
        Gets information about recent windows updates
    
    .DESCRIPTION
        Finds the last time windows updates were searched for and when the last install was.
    
    .PARAMETER ComputerName
        The name of the machine to check
    
    .PARAMETER UpToDateTime
        The amount of days that will be used when determining the UpToDate state.
    
    .EXAMPLE
        PS C:\> Get-RecentUpdateInfo -ComputerName $Server.Name
    
    .OUTPUTS
        System.Object
    
    .NOTES
        Updated 2017-11-18
#>
    
    [CmdletBinding()]
    [OutputType([object])]
    param
    (
        [Parameter(Position = 1,
                    ValueFromPipeline = $true,
                    ValueFromPipelineByPropertyName = $true,
                    Mandatory = $false,
                    HelpMessage = 'The name of the machine to check')]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName = $env:COMPUTERNAME,

        [Parameter(Position = 2,
                    HelpMessage = 'The amount of days that will be used when determining the UpToDate state.')]
        [ValidateNotNullOrEmpty()]
        [int]$UpToDateTime = 180
    )
    
    begin {}

    process {
        Write-Verbose "Computer name is: $ComputerName"
        if ($ComputerName -eq $env:COMPUTERNAME) {
            Write-Verbose "Getting update info from local machine"
            $UpdateObj = New-Object -ComObject Microsoft.Update.AutoUpdate
            $LastSearch = $UpdateObj.Results.LastSearchSuccessDate
            $LastInstall = $UpdateObj.Results.LastInstallationSuccessDate
            $UpToDate = if ($LastInstall -lt (Get-Date).AddDays(-$UpToDateTime)) { $false } else { $true }
            $windowsUpdateObject = [PSCustomObject]@{
                ComputerName    = $env:COMPUTERNAME
                LastSearch	    = $LastSearch
                LastInstall	    = $LastInstall
                UpToDate	    = $UpToDate
            }
            $windowsUpdateObject = $windowsUpdateObject | Select-Object ComputerName, LastSearch, LastInstall, UpToDate
        } else {
            Write-Verbose "Getting update info from remote machine: $ComputerName"
            $windowsUpdateObject = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
                $UpdateObj = New-Object -ComObject Microsoft.Update.AutoUpdate
                $LastSearch = $UpdateObj.Results.LastSearchSuccessDate
                $LastInstall = Get-HotFix -ComputerName $env:COMPUTERNAME | Sort-Object InstalledOn -Descending | Select-Object -First 1 -ExpandProperty InstalledOn
                $UpToDate = if ($LastInstall -lt (Get-Date).AddDays(-$UpToDateTime)) { $false } else { $true }
                $windowsUpdateObject = [PSCustomObject]@{
                    ComputerName    = $env:COMPUTERNAME
                    LastSearch	    = $LastSearch
                    LastInstall	    = $LastInstall
                    UpToDate	    = $UpToDate
                }
                $windowsUpdateObject
            } -HideComputerName
            $windowsUpdateObject = $windowsUpdateObject | Select-Object ComputerName, LastSearch, LastInstall, UpToDate
        }
        $windowsUpdateObject
    }

    end {}
}

function Get-PendingReboot {
    <#
    .SYNOPSIS
        Gets the pending reboot status on a local or remote computer.
    
    .DESCRIPTION
        This function will query the registry on a local or remote computer and determine if the
        system is pending a reboot, from Microsoft updates, Configuration Manager Client SDK, Pending Computer 
        Rename, Domain Join or Pending File Rename Operations. For Windows 2008+ the function will query the 
        CBS registry key as another factor in determining pending reboot state.  "PendingFileRenameOperations" 
        and "Auto Update\RebootRequired" are observed as being consistant across Windows Server 2003 & 2008.
        
        CBServicing = Component Based Servicing (Windows 2008+)
        WindowsUpdate = Windows Update / Auto Update (Windows 2003+)
        CCMClientSDK = SCCM 2012 Clients only (DetermineIfRebootPending method) otherwise $null value
        PendComputerRename = Detects either a computer rename or domain join operation (Windows 2003+)
        PendFileRename = PendingFileRenameOperations (Windows 2003+)
        PendFileRenVal = PendingFilerenameOperations registry value; used to filter if need be, some Anti-
                         Virus leverage this key for def/dat removal, giving a false positive PendingReboot
    
    .PARAMETER ComputerName
        A single Computer or an array of computer names.  The default is localhost ($env:COMPUTERNAME).
    
    .PARAMETER ErrorLog
        A single path to send error data to a log file.
    
    .EXAMPLE
        PS C:\> Get-PendingReboot -ComputerName (Get-Content C:\ServerList.txt) | Format-Table -AutoSize
        
        Computer CBServicing WindowsUpdate CCMClientSDK PendFileRename PendFileRenVal RebootPending
        -------- ----------- ------------- ------------ -------------- -------------- -------------
        DC01           False         False                       False                        False
        DC02           False         False                       False                        False
        FS01           False         False                       False                        False
    
        This example will capture the contents of C:\ServerList.txt and query the pending reboot
        information from the systems contained in the file and display the output in a table. The
        null values are by design, since these systems do not have the SCCM 2012 client installed,
        nor was the PendingFileRenameOperations value populated.
    
    .EXAMPLE
        PS C:\> Get-PendingReboot
        
        Computer           : WKS01
        CBServicing        : False
        WindowsUpdate      : True
        CCMClient          : False
        PendComputerRename : False
        PendFileRename     : False
        PendFileRenVal     : 
        RebootPending      : True
        
        This example will query the local machine for pending reboot information.
        
    .EXAMPLE
        PS C:\> $Servers = Get-Content C:\Servers.txt
        PS C:\> Get-PendingReboot -Computer $Servers | Export-Csv C:\PendingRebootReport.csv -NoTypeInformation
        
        This example will create a report that contains pending reboot information.
    
    .LINK
        Component-Based Servicing:
        http://technet.microsoft.com/en-us/library/cc756291(v=WS.10).aspx
        
        PendingFileRename/Auto Update:
        http://support.microsoft.com/kb/2723674
        http://technet.microsoft.com/en-us/library/cc960241.aspx
        http://blogs.msdn.com/b/hansr/archive/2006/02/17/patchreboot.aspx
    
        SCCM 2012/CCM_ClientSDK:
        http://msdn.microsoft.com/en-us/library/jj902723.aspx
    
    .NOTES
        Author:  Brian Wilhite
        Email:   bcwilhite (at) live.com
        Date:    29AUG2012
        PSVer:   2.0/3.0/4.0/5.0
        Updated: 27JUL2015
        UpdNote: Added Domain Join detection to PendComputerRename, does not detect Workgroup Join/Change
                 Fixed Bug where a computer rename was not detected in 2008 R2 and above if a domain join occurred at the same time.
                 Fixed Bug where the CBServicing wasn't detected on Windows 10 and/or Windows Server Technical Preview (2016)
                 Added CCMClient property - Used with SCCM 2012 Clients only
                 Added ValueFromPipelineByPropertyName=$true to the ComputerName Parameter
                 Removed $Data variable from the PSObject - it is not needed
                 Bug with the way CCMClientSDK returned null value if it was false
                 Removed unneeded variables
                 Added PendFileRenVal - Contents of the PendingFileRenameOperations Reg Entry
                 Removed .Net Registry connection, replaced with WMI StdRegProv
                 Added ComputerPendingRename
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Position=0,
                   ValueFromPipeline=$true,
                   ValueFromPipelineByPropertyName=$true)]
        [Alias("CN","Computer")]
        [String[]]$ComputerName="$env:COMPUTERNAME",
        [String]$ErrorLog
        )
    
    Begin {}## End Begin Script Block
    
    Process {
      Foreach ($Computer in $ComputerName) {
        Try {
            ## Setting pending values to false to cut down on the number of else statements
            $CompPendRen,$PendFileRename,$Pending,$SCCM = $false,$false,$false,$false
                            
            ## Setting CBSRebootPend to null since not all versions of Windows has this value
            $CBSRebootPend = $null
                            
            ## Querying WMI for build version
            $WMI_OS = Get-WmiObject -Class Win32_OperatingSystem -Property BuildNumber, CSName -ComputerName $Computer -ErrorAction Stop
    
            ## Making registry connection to the local/remote computer
            $HKLM = [UInt32] "0x80000002"
            $WMI_Reg = [WMIClass] "\\$Computer\root\default:StdRegProv"
                            
            ## If Vista/2008 & Above query the CBS Reg Key
            If ([Int32]$WMI_OS.BuildNumber -ge 6001) {
                $RegSubKeysCBS = $WMI_Reg.EnumKey($HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\")
                $CBSRebootPend = $RegSubKeysCBS.sNames -contains "RebootPending"		
            }
                                
            ## Query WUAU from the registry
            $RegWUAURebootReq = $WMI_Reg.EnumKey($HKLM,"SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\")
            $WUAURebootReq = $RegWUAURebootReq.sNames -contains "RebootRequired"
                            
            ## Query PendingFileRenameOperations from the registry
            $RegSubKeySM = $WMI_Reg.GetMultiStringValue($HKLM,"SYSTEM\CurrentControlSet\Control\Session Manager\","PendingFileRenameOperations")
            $RegValuePFRO = $RegSubKeySM.sValue
    
            ## Query JoinDomain key from the registry - These keys are present if pending a reboot from a domain join operation
            $Netlogon = $WMI_Reg.EnumKey($HKLM,"SYSTEM\CurrentControlSet\Services\Netlogon").sNames
            $PendDomJoin = ($Netlogon -contains 'JoinDomain') -or ($Netlogon -contains 'AvoidSpnSet')
    
            ## Query ComputerName and ActiveComputerName from the registry
            $ActCompNm = $WMI_Reg.GetStringValue($HKLM,"SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName\","ComputerName")            
            $CompNm = $WMI_Reg.GetStringValue($HKLM,"SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName\","ComputerName")
    
            If (($ActCompNm -ne $CompNm) -or $PendDomJoin) {
                $CompPendRen = $true
            }
                            
            ## If PendingFileRenameOperations has a value set $RegValuePFRO variable to $true
            If ($RegValuePFRO) {
                $PendFileRename = $true
            }
    
            ## Determine SCCM 2012 Client Reboot Pending Status
            ## To avoid nested 'if' statements and unneeded WMI calls to determine if the CCM_ClientUtilities class exist, setting EA = 0
            $CCMClientSDK = $null
            $CCMSplat = @{
                NameSpace='ROOT\ccm\ClientSDK'
                Class='CCM_ClientUtilities'
                Name='DetermineIfRebootPending'
                ComputerName=$Computer
                ErrorAction='Stop'
            }
            ## Try CCMClientSDK
            Try {
                $CCMClientSDK = Invoke-WmiMethod @CCMSplat
            } Catch [System.UnauthorizedAccessException] {
                $CcmStatus = Get-Service -Name CcmExec -ComputerName $Computer -ErrorAction SilentlyContinue
                If ($CcmStatus.Status -ne 'Running') {
                    Write-Warning "$Computer`: Error - CcmExec service is not running."
                    $CCMClientSDK = $null
                }
            } Catch {
                $CCMClientSDK = $null
            }
    
            If ($CCMClientSDK) {
                If ($CCMClientSDK.ReturnValue -ne 0) {
                    Write-Warning "Error: DetermineIfRebootPending returned error code $($CCMClientSDK.ReturnValue)"          
                }
                If ($CCMClientSDK.IsHardRebootPending -or $CCMClientSDK.RebootPending) {
                    $SCCM = $true
                }
            }
                
            Else {
                $SCCM = $null
            }
    
            ## Creating Custom PSObject and Select-Object Splat
            $SelectSplat = @{
                Property=(
                    'Computer',
                    'CBServicing',
                    'WindowsUpdate',
                    'CCMClientSDK',
                    'PendComputerRename',
                    'PendFileRename',
                    'PendFileRenVal',
                    'RebootPending'
                )}
            New-Object -TypeName PSObject -Property @{
                Computer=$WMI_OS.CSName
                CBServicing=$CBSRebootPend
                WindowsUpdate=$WUAURebootReq
                CCMClientSDK=$SCCM
                PendComputerRename=$CompPendRen
                PendFileRename=$PendFileRename
                PendFileRenVal=$RegValuePFRO
                RebootPending=($WUAURebootReq -or $SCCM)
            } | Select-Object @SelectSplat
    
        } Catch {
            Write-Warning "$Computer`: $_"
            ## If $ErrorLog, log the file to a user specified location/path
            If ($ErrorLog) {
                Out-File -InputObject "$Computer`,$_" -FilePath $ErrorLog -Append
            }				
        }			
      }## End Foreach ($Computer in $ComputerName)			
    }## End Process

    End {}## End End
}

function Get-GPOChanges {
<#
    .SYNOPSIS
        Gets a summary of changes to Group Policy
    
    .DESCRIPTION
        Gets a summary of changes to Group Policy
    
    .PARAMETER LastRunFolder
        The folder path to where the last runs XML files will be stored and checked
    
    .PARAMETER ThisRunFolder
        The folder to save the current export of GPOs as XML
    
    .EXAMPLE
        PS C:\> Get-GPOChanges -LastRunFolder $PSScriptRoot -ThisRunFolder $PSScriptRoot
    
    .OUTPUTS
        System.Management.Automation.PSCustomObject
    
    .NOTES
        Updated 2017-11-24
#>
    
    [CmdletBinding(PositionalBinding = $true)]
    [OutputType([PSCustomObject])]
    param
    (
        [Parameter(Mandatory = $false,
                    Position = 0,
                    HelpMessage = 'The folder path to where the last runs XML files will be stored and checked')]
        [ValidateScript({ Test-Path -Path $_ })]
        [string]$LastRunFolder = '.\XML\LastRun',
        [Parameter(Mandatory = $false,
                    Position = 1,
                    HelpMessage = 'The folder to save the current export of GPOs as XML')]
        [ValidateScript({ Test-Path -Path $_ })]
        [string]$ThisRunFolder = '.\XML\ThisRun'
    )
    
    begin {
        $AllGPOs = Get-GPO -All
        Write-Verbose "Exporting current GPOs to: $ExportLocation"
        Write-Verbose ""
    }

    process {
        foreach ($GPO in $AllGPOs) {
            # Export XML to export location
            $DisplayNameNoDots = ($GPo.DisplayName).Replace(".", "")
            $DisplayNameNoDots = $DisplayNameNoDots.Replace(":", "")
            $FileWithPath = Join-Path -Path $ThisRunFolder -ChildPath "$DisplayNameNoDots.xml"
            
            Write-Verbose "Original name: $($GPO.DisplayName)"
            Write-Verbose "Fixed name: $DisplayNameNoDots.xml"
            Write-Verbose "GUID: $($GPO.Id)"
            Write-Verbose "Exported path: $FileWithPath"
            
            # Create the file
            $GPO.GenerateReportToFile("xml", $FileWithPath)
            
            $CurrentGPOContent = Get-Content -Path $FileWithPath | Where-Object {
                $_ -notlike "*<ReadTime>*"
            }
            try {
                $LastGPOContent = Get-Content (Join-Path -Path $LastRunFolder -ChildPath "$DisplayNameNoDots.xml") -ErrorAction Stop | Where-Object {
                    $_ -notlike "*<ReadTime>*"
                }
                $Differences = Compare-Object -ReferenceObject $LastGPOContent -DifferenceObject $CurrentGPOContent
                If (($Differences.count) -gt 0) {
                    # GPO Changed
                    Write-Verbose "GPO CHANGED: $($GPO.DisplayName)"
                    $GPOObj = [PSCustomObject]@{
                        GPOName	    = ($GPo.DisplayName)
                        ChangeType  = "Modified"
                    }
                    $GPOObj
                } else {
                    # GPO same
                    Write-Verbose "No Change on $($GPO.DisplayName)"
                }
            } catch {
                # Failed find - could be new?
                Write-Verbose "Failed to find $($GPO.DisplayName)"
            }
        }
        
        $LastGPOs = Get-ChildItem -Path $LastRunFolder -Name
        $NewGpos = Get-ChildItem -Path $ThisRunFolder -Name
        $Differences = Compare-Object -ReferenceObject $NewGpos -DifferenceObject $LastGPOs

        $NewGPOList = $Differences | Where-Object {
            $_.sideIndicator -eq "<="
        } | Select-Object InputObject -ExpandProperty InputObject
        foreach ($NewGPO in $NewGPOList) {
            $GPOObj = [PSCustomObject]@{
                GPOName	    = $NewGPO
                ChangeType  = "New"
            }
            $GPOObj
        }
        
        $DeletedGposList = $Differences | Where-Object {
            $_.sideIndicator -eq "=>"
        } | Select-Object InputObject -ExpandProperty InputObject
        foreach ($DeletedGPO in $DeletedGposList) {
            $GPOObj = [PSCustomObject]@{
                GPOName	    = $DeletedGPO
                ChangeType  = "Deleted"
            }
            $GPOObj
        }
    }
    
    end {
        # Delete old and move current run
        Get-ChildItem -Path $LastRunFolder | Remove-Item -Include "*.xml" -Force
        Get-ChildItem -Path $ThisRunFolder | Move-Item -Destination $LastRunFolder -Force
    }
}

# END DEFINE FUNCTIONS
########################################################

########################################################
# GET AD INFORMATION

# !Assumption is the environment is one forest with one root domain only!

$ThisForest = Get-ADForest

$AllDomainInfo = @()
$AllDomainObjectInfo =@()
foreach ($Domain in $ThisForest.Domains) {
    $ThisDomain = Get-ADDomain -Identity $Domain
    $AllDomainControllersPS = ( $ThisDomain.ReplicaDirectoryServers + $ThisDomain.ReadOnlyReplicaDirectoryServers ) | Get-ADDomainController
    $AllDomainControllersAD = Get-ADObject -Server $ThisDomain.PDCEmulator -Filter {ObjectClass -eq 'computer'} -SearchBase "OU=Domain Controllers,$($ThisDomain.DistinguishedName)"
    $DCRefObj = $AllDomainControllersPS | Select-Object -ExpandProperty ComputerObjectDN
    $DCDiffObj = $AllDomainControllersAD | Select-Object -ExpandProperty DistinguishedName
    $Differences = Compare-Object -ReferenceObject $DCRefObj -DifferenceObject $DCDiffObj
    $SYSVOLReplicationMode = switch ((Get-ADObject "CN=DFSR-GlobalSettings,CN=System,$($ThisDomain.DistinguishedName)" -Properties 'msDFSR-Flags').'msDFSR-Flags') {
        0 {'FRS'}
        16 {'FRS'}
        32 {'DFSR'}
        48 {'DFSR'}
        Default {'FRS'}
     }
    $ADInfoParams = @{
        ForestName = $ThisForest.Name
        DomainDNSRoot = $ThisDomain.DNSRoot
        DomainName = $ThisDomain.NetBIOSName
        ForestMode = $ThisForest.ForestMode
        DomainMode = $ThisDomain.DomainMode
        SchemaMaster = $ThisForest.SchemaMaster
        DomainNamingMaster = $ThisForest.DomainNamingMaster
        PDCEmulator = $ThisDomain.PDCEmulator
        RIDMaster = $ThisDomain.RIDMaster
        InfrastructureMaster = $ThisDomain.InfrastructureMaster
        Sites = (($ThisForest.Sites | Sort-Object) -join ', ')
        SYSVOLReplicationMode = $SYSVOLReplicationMode
    }
    if ($null -ne $Differences) {
        $ADInfoParams.Add('Notes',"MISMATCHED DC LIST: PS: $($AllDomainControllersPS | Out-String) - AD: $($AllDomainControllersAD | Out-String)")
    } else {
        # All good / do nothing
    }
    $ADInfo = [PSCustomObject]$ADInfoParams
    $AllDomainInfo = $AllDomainInfo + $ADInfo

    ##### AD Object info #####
    $DomainObjectInfoParams = @{}
    # OU no delete
    [array]$AllVulnerableOUs = Get-ADObject -Properties ProtectedFromAccidentalDeletion -Filter {(ObjectClass -eq 'organizationalUnit')} -Server $ThisDomain.PDCEmulator | Where-Object -FilterScript {$_.ProtectedFromAccidentalDeletion -eq $false} | Select-Object -ExpandProperty DistinguishedName
    
    # user no expire
    [array]$AllUsersNoExpiryPW = Get-ADUser -Filter {PasswordNeverExpires -eq $true} -Server $ThisDomain.PDCEmulator | Select-Object -ExpandProperty SamAccountName

    # reversible encryption
    [array]$AllUsersReversiblePW = Get-ADUser -Filter {AllowReversiblePasswordEncryption -eq $true} -Server $ThisDomain.PDCEmulator | Select-Object -ExpandProperty SamAccountName

    $DomainObjectInfoParams = @{
        DomainName = $ThisDomain.NetBIOSName
        OUVulnerableToAccidentalDeletion = if ($AllVulnerableOUs.count -gt 0) { ($AllVulnerableOUs -join ', ') } else { 'None - ALL OK' }
        UsersWithNoPasswordExpiry = if ($AllUsersNoExpiryPW.count -gt 0) { ($AllUsersNoExpiryPW -join ', ') } else { 'None - ALL OK' }
        UsersWithReversiblePWEncryption = if ($AllUsersReversiblePW.count -gt 0) { ($AllUsersReversiblePW -join ', ') } else { 'None - ALL OK' }
    }
    $DomainObjectInfo = [PSCustomObject]$DomainObjectInfoParams
    $AllDomainObjectInfo = $AllDomainObjectInfo + $DomainObjectInfo
} # foreach domain

# DC INFO
$AllDCInfo = @()
$FailedDCInfo = @()
$AllDCBacklogs = @()
$inc = 1

foreach ($DC in $AllDomainControllersPS) {
    Write-Verbose "Starting checks on: $($DC.Name)"
    Write-Verbose "DC: $($DC.Name) --- $inc / $($AllDomainControllersPS.count)"
    $inc++

    # Find if PC is ON and responding to WinRM
    $ServerResponding = Test-Connection -Count 1 -ComputerName $DC.Name -Quiet
    # Assume WMF / PowerShell 5.1 is installed and working and if not then set flag to false
    try {
        Test-WSMan -ComputerName $DC.Name -ErrorAction Stop | Out-Null
        $ServerWSManrunning = $true
    }
    catch { $ServerWSManrunning = $false }

    if (($ServerResponding -eq $true) -and ($ServerWSManrunning -eq $true)) {
        # Server responding fine
        try {
            $DCPSSession = New-PSSession -ComputerName $DC.name
            # Invoke it all, don't rely on the inbuilt remoting of Get-WmiObject or other cmdlets
            Write-Verbose "Gathering DC info from: $($DC.Name)"
            $OutputObjectParams = Invoke-Command -Session $DCPSSession -HideComputerName -ScriptBlock {
                $OSInfo = Get-WmiObject -Class 'win32_operatingsystem'
                $PCInfo = Get-WmiObject -Class 'win32_computersystem'
                $DiskInfo = Get-WmiObject -Class 'win32_logicaldisk' -Filter {DriveType=3}
                $ADDSDBPath = (Get-Item 'HKLM:SYSTEM\CurrentControlSet\Services\NTDS\Parameters' | Get-ItemProperty).'DSA Working Directory'
                $ADDSLogPath = (Get-Item 'HKLM:SYSTEM\CurrentControlSet\Services\NTDS\Parameters' | Get-ItemProperty).'Database log files path'
                $ADDSSYSVOLPath = (Get-Item 'HKLM:SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' | Get-ItemProperty).SYSVOL
                $IsServerCore = if ((Get-Item 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion' | Get-ItemProperty).InstallationType -eq 'Server Core') { $true } else { $false }
                $OutputObjectParams = @{
                    ComputerName = $env:COMPUTERNAME
                    OperatingSystem = $OSInfo.Caption
                    LastBootTime = $OSInfo.ConvertToDateTime($OSInfo.LastBootUpTime)
                    IsVirtual = if (($PCInfo.model -like "*virtual*") -or ($PCInfo.Manufacturer -eq 'QEMU')) {$true} else {$false}
                    IsGlobalCatalog = $args[0].IsGlobalCatalog
                    NTDSServiceStatus = (Get-Service -Name 'NTDS').Status
                    NetlogonServiceStatus = (Get-Service -Name 'Netlogon').Status
                    DNSServiceStatus = (Get-Service -Name 'DNS').Status
                    IsServerCore = $IsServerCore
                }
                foreach ($Disk in $DiskInfo) {
                    $Freespace = $Disk.FreeSpace / 1GB
                    $TotalSize = $Disk.Size / 1GB
                    $PercentFree = (($Freespace / $TotalSize) * 100)
                    # Only care about ADDS volumes
                    if ($Disk.DeviceId -eq ($ADDSDBPath -split '\\')[0]) {
                        $OutputObjectParams.Add("ADDS volume % free",([math]::round($PercentFree)))
                    }
                    if ($Disk.DeviceId -eq ($ADDSLogPath -split '\\')[0]) {
                        $OutputObjectParams.Add("ADDS log volume % free",([math]::round($PercentFree)))
                    }
                    if ($Disk.DeviceId -eq ($ADDSSYSVOLPath -split '\\')[0]) {
                        $OutputObjectParams.Add("SYSVOL volume % free",([math]::round($PercentFree)))
                    }
                }
                $OutputObjectParams
            } -ErrorAction Stop -ArgumentList $DC

            Write-Verbose "Gathering DFS backlog information from $($DC.name)"
            $DCBacklog = Invoke-Command -Session $DCPSSession -ScriptBlock ${function:Get-DfsrBacklog} -ArgumentList $DC.Name
            $DCBacklog = $DCBacklog | Select-Object -Property ComputerName,ReplicationGroupname,SendingMember,ReceivingMember,BacklogFileCount
            $AllDCBacklogs = $AllDCBacklogs + $DCBacklog

            $OutputObjectParams.Add('NetlogonAccessible',(Test-Path -Path "\\$($DC.HostName)\NETLOGON\"))
            # TODO: FIX BELOW  -  This wont work properly for a multi-domain environment...
            $OutputObjectParams.Add('SYSVOLAccessible',(Test-Path -Path "\\$($DC.HostName)\SYSVOL\$((Get-ADDomain).DNSRoot)"))

            $DCResponse = New-Object -TypeName 'PSCustomObject' -Property $OutputObjectParams
            $AllDCInfo = $AllDCInfo + $DCResponse
        } # try
        catch {
            Write-Verbose "$($DC.Name) failed"
            $FailObject = [PSCustomObject]@{
                ComputerName = $DC.HostName
                DC = $DC
                ServerResponding = $ServerResponding
                ServerWSManrunning = $ServerWSManrunning
            }
            $FailedDCInfo = $FailedDCInfo + $FailObject
        } # catch
    } else {
        Write-Verbose "$($DC.Name) failed"
        $FailObject = [PSCustomObject]@{
            ComputerName = $DC.HostName
            DC = $DC
            ServerResponding = $ServerResponding
            ServerWSManrunning = $ServerWSManrunning
        }
        $FailedDCInfo = $FailedDCInfo + $FailObject
    } # else server not responding fine
} # foreach DC


if ($IsVerbose) {
    Write-Verbose "Domain Info:"
    $AllDomainInfo | Format-List *
    Write-Verbose "DC Info:"
    $AllDCInfo  |  Format-List *
    Write-Verbose "DFSR Backlogs"
    $AllDCBacklogs | Format-List *
    Write-Verbose "Failed DC info"
    $FailedDCInfo | Format-List *
    Write-Verbose "All domain object infos"
    $AllDomainObjectInfo | Format-List *
}

# END AD INFORMATION
#########################################################

#########################################################
# BEGIN MAIN LOOP

# Get all Windows servers with all properties
Write-Verbose "Searching for windows servers in domain: $CurrentDomainName"
$ServerList = Get-ADComputer -Filter { (OperatingSystem -Like "Windows *Server*") } -Properties *

# incremental counter
$inc = 1

$AllServerInfo = @()
$FailedServers = @()

foreach ($Server in $ServerList) {
    Write-Verbose "Server: $($Server.Name) --- $inc / $($ServerList.count)"
    $inc++

    if ($IgnoredServers -notcontains $Server.Name) {
        # Server is not filtered
        Write-Verbose "Starting checks on: $($Server.Name)"

        # Find if PC is ON and responding to WinRM
        $ServerResponding = Test-Connection -Count 1 -ComputerName $Server.Name -Quiet
        # Assume WMF / PowerShell 5.1 is installed and working and if not then set flag to false
        try {
            Test-WSMan -ComputerName $Server.Name -ErrorAction Stop | Out-Null
            $ServerWSManrunning = $true
        }
        catch { $ServerWSManrunning = $false }

        if (($ServerResponding -eq $true) -and ($ServerWSManrunning -eq $true)) {
            # Server responding fine
            try {
                # Run it all locally via an invoked session
                $ServerSSession = New-PSSession -ComputerName $Server.name -ErrorAction Stop
                $OutputObjectParams = Invoke-Command -Session $ServerSSession -HideComputerName -ScriptBlock {

                    # Get some WMI info about the machine
                    $OSInfo = Get-WmiObject -Class 'win32_operatingsystem'
                    $PCInfo = Get-WmiObject -Class 'win32_computersystem'
                    $DiskInfo = Get-WmiObject -Class 'win32_logicaldisk' -Filter {DriveType=3}

                    # General info
                    $OutputObjectParams = @{
                        ComputerName = $env:COMPUTERNAME
                        OperatingSystem = $OSInfo.Caption
                        IsVirtual = if (($PCInfo.model -like "*virtual*") -or ($PCInfo.Manufacturer -eq 'QEMU')) { $true } else { $false }
                        IsServerCore = if ((Get-Item 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion' | Get-ItemProperty).InstallationType -eq 'Server Core') { $true } else { $false }
                    }

                    # Disk info
                    $Disks = @()
                    foreach ($Disk in $DiskInfo) {
                        $Freespace = $Disk.FreeSpace / 1GB
                        $TotalSize = $Disk.Size / 1GB
                        $PercentFree = [math]::Round((($Freespace / $TotalSize) * 100))
                        $DiskObj = [PSCustomObject]@{
                            Volume = $Disk.DeviceId
                            TotalSize = $TotalSize
                            FreeSpace = $Freespace
                            PercentFree = $PercentFree
                        }
                        $Disks = $Disks + $DiskObj
                    }
                    $OutputObjectParams.Add('Disks',$Disks)

                    # local admins
                    # TODO: Filter domain admins / Administrator account
                    $LocalAdmins = net localgroup "Administrators" | Where-Object -FilterScript {$_ -AND $_ -notmatch "command completed successfully"} | Select-Object -Skip 4
                    $OutputObjectParams.Add('LocalAdministrators',$LocalAdmins)

                    # Printers shared from this machine
                    #  TODO: Add port checks + management page check?
                    $SharedPrinters = Get-Printer -ComputerName $env:COMPUTERNAME | Where-Object -FilterScript { ($_.Shared -eq $true) }
                    $PrinterList = @()
                    foreach ($Printer in $SharedPrinters) {
                        $PrinterObjectParams = @{
                            ComputerName = $env:COMPUTERNAME
                            PrinterName = $Printer.Name
                            PrinterDriver = $Printer.DriverName
                            PublishedToAD = $Printer.Published
                        }
                        try { $PrinterAddress = (Get-PrinterPort -Name $Printer.PortName -ErrorAction Stop | Select-Object -ExpandProperty 'PrinterHostAddress') }
                        catch { $PrinterAddress = $Printer.PortName }

                        $IsPingable = Test-Connection $PrinterAddress -Count 1 -Quiet
                        $PrinterObjectParams.Add('PrinterAddress',$PrinterAddress)
                        $PrinterObjectParams.Add('IsPingable',$IsPingable)

                        $PrinterObject = [PSCustomObject]$PrinterObjectParams
                        $PrinterList = $PrinterList + $PrinterObject
                    }
                    $OutputObjectParams.Add('SharedPrinters',$PrinterList)

                    # scheduled task with domain / local credentials (non-system)
                    # or system account task created by domain user
                    $IgnoredTaskRunAsUsers = @('INTERACTIVE','SYSTEM','NT AUTHORITY\SYSTEM','LOCAL SERVICE','NETWORK SERVICE','Users','Administrators','Everyone','Authenticated Users')
                    $DomainNames = $args[1] | Select-Object -ExpandProperty DomainName
                    $NonStandardScheduledTasks = schtasks.exe /query /s $env:COMPUTERNAME /V /FO CSV | ConvertFrom-Csv | Where-Object -FilterScript { ($_.TaskName -ne "TaskName") -and ( ($_.'Run As User' -notin $IgnoredTaskRunAsUsers) -or (($_.Author -split '\\')[0] -in $DomainNames)  ) }
                    $OutputObjectParams.Add('NonStandardScheduledTasks',$NonStandardScheduledTasks)

                    # services with domain / local credentials (non-system)
                    $IgnoredServiceRunAsUsers = @('LocalSystem', 'NT AUTHORITY\LocalService', 'NT AUTHORITY\NetworkService')
                    $NonStandardServices = Get-WmiObject -Class 'win32_service' | Where-Object -FilterScript { ($_.StartName -notin $IgnoredServiceRunAsUsers) -or ( ($_.StartMode -eq 'Auto') -and ($_.State -ne 'Running') ) }
                    $OutputObjectParams.Add('NonStandardServices',$NonStandardServices)

                    # Expired certificates / less than 30 days


                    
                } -ArgumentList $Server,$AllDomainInfo -ErrorAction Stop

                # Get Windows Update info
                $UpdateInfo = Invoke-Command -Session $ServerSSession -HideComputerName -ErrorAction Stop -ScriptBlock ${function:Get-RecentUpdateInfo}
                $OutputObjectParams.Add('UpdateInfo',$UpdateInfo)

                # pending reboot
                $RebootInfo = Invoke-Command -Session $ServerSSession -HideComputerName -ErrorAction Stop -ScriptBlock ${function:Get-PendingReboot}
                $OutputObjectParams.Add('PendingReboot',$RebootInfo)

                # GPO changes?

                # create object from params
                $ServerObject = [PSCustomObject]$OutputObjectParams
                $AllServerInfo = $AllServerInfo + $ServerObject
            }
            catch {
                Write-Warning "Failed to gather information from server: $($server.Name)"
                $FailObject = [PSCustomObject]@{
                    ComputerName = $Server.Name
                    Server = $Server
                    Error = $_
                    ServerResponding = $ServerResponding
                    ServerWSManrunning = $ServerWSManrunning
                    Ignored = $false
                }
                $FailedServers = $FailedServers + $FailObject
            }
        } else {
            Write-Warning "Failed to gather information from server: $($server.Name)"
            $FailObject = [PSCustomObject]@{
                ComputerName = $Server.Name
                Server = $Server
                Error = $null
                ServerResponding = $ServerResponding
                ServerWSManrunning = $ServerWSManrunning
                Ignored = $false
            }
            $FailedServers = $FailedServers + $FailObject
        } # else server not responding fine
    } else {
        Write-Verbose "Ignored server: $($Server.Name)"
        $FailObject = [PSCustomObject]@{
            ComputerName = $Server.Name
            Server = $Server
            Error = $null
            ServerResponding = $null
            ServerWSManrunning = $null
            Ignored = $true
        }
        $FailedServers = $FailedServers + $FailObject
    } # else ignored
} # main foreach


if ($IsVerbose) {
    Write-Verbose 'Domain Info:'
    $AllServerInfo | Format-List *
    Write-Verbose 'Failed servers:'
    $FailedServers | Format-List *
}


# END MAIN LOOP
##########################################################

# Stop script logging
Stop-Transcript | Out-Null