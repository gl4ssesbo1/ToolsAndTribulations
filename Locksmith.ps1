﻿function Invoke-Locksmith {
    <#
    .SYNOPSIS
    Finds the most common malconfigurations of Active Directory Certificate Services (AD CS).

    .DESCRIPTION
    Locksmith uses the Active Directory (AD) Powershell (PS) module to identify 6 misconfigurations
    commonly found in Enterprise mode AD CS installations.

    .COMPONENT
    Locksmith requires the AD PS module to be installed in the scope of the Current User.
    If Locksmith does not identify the AD PS module as installed, it will attempt to
    install the module. If module installation does not complete successfully,
    Locksmith will fail.

    .PARAMETER Mode
    Specifies sets of common script execution modes.

    -Mode 0
    Finds any malconfigurations and displays them in the console.
    No attempt is made to fix identified issues.

    -Mode 1
    Finds any malconfigurations and displays them in the console.
    Displays example Powershell snippet that can be used to resolve the issue.
    No attempt is made to fix identified issues.

    -Mode 2
    Finds any malconfigurations and writes them to a series of CSV files.
    No attempt is made to fix identified issues.

    -Mode 3
    Finds any malconfigurations and writes them to a series of CSV files.
    Creates code snippets to fix each issue and writes them to an environment-specific custom .PS1 file.
    No attempt is made to fix identified issues.

    -Mode 4
    Finds any malconfigurations and creates code snippets to fix each issue.
    Attempts to fix all identified issues. This mode may require high-privileged access.

    .PARAMETER Scans
    Specify which scans you want to run. Available scans: 'All' or Auditing, ESC1, ESC2, ESC3, ESC4, ESC5, ESC6, ESC8, or 'PromptMe'

    -Scans All
    Run all scans (default)

    -Scans PromptMe
    Presents a grid view of the available scan types that can be selected and run them after you click OK.

    .PARAMETER OutputPath
    Specify the path where you want to save reports and mitigation scripts.

    .INPUTS
    None. You cannot pipe objects to Invoke-Locksmith.ps1.

    .OUTPUTS
    Output types:
    1. Console display of identified issues
    2. Console display of identified issues and their fixes
    3. CSV containing all identified issues
    4. CSV containing all identified issues and their fixes

    .NOTES
    Windows PowerShell cmdlet Restart-Service requires RunAsAdministrator
    #>

    [CmdletBinding()]
    param (
        [string]$Forest,
        [string]$InputPath,
        [int]$Mode = 0,
        [Parameter()]
            [ValidateSet('Auditing','ESC1','ESC2','ESC3','ESC4','ESC5','ESC6','ESC8','All','PromptMe')]
            [array]$Scans = 'All',
        [string]$OutputPath = (Get-Location).Path,
        [System.Management.Automation.PSCredential]$Credential
    )

    $Version = '2023.11'
    $Logo = @"
    _       _____  _______ _     _ _______ _______ _____ _______ _     _
    |      |     | |       |____/  |______ |  |  |   |      |    |_____|
    |_____ |_____| |_____  |    \_ ______| |  |  | __|__    |    |     |
        .--.                  .--.                  .--.
       /.-. '----------.     /.-. '----------.     /.-. '----------.
       \'-' .--'--''-'-'     \'-' .--'--''-'-'     \'-' .--'--''-'-'
        '--'                  '--'                  '--'
                                                               v$Version

"@
   $Logo

    # Check if ActiveDirectory PowerShell module is available, and attempt to install if not found
    if (-not(Get-Module -Name 'ActiveDirectory' -ListAvailable)) {
        if (Test-IsElevated) {
            $OS = (Get-CimInstance -ClassName Win32_OperatingSystem).ProductType
            # 1 - workstation, 2 - domain controller, 3 - non-dc server
            if ($OS -gt 1) {
                # Attempt to install ActiveDirectory PowerShell module for Windows Server OSes, works with Windows Server 2012 R2 through Windows Server 2022
                Install-WindowsFeature -Name RSAT-AD-PowerShell
            } else {
                # Attempt to install ActiveDirectory PowerShell module for Windows Desktop OSes
                Add-WindowsCapability -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0 -Online
            }
        }
        else {
            Write-Warning -Message "The ActiveDirectory PowerShell module is required for Locksmith, but is not installed. Please launch an elevated PowerShell session to have this module installed for you automatically."
            # The goal here is to exit the script without closing the PowerShell window. Need to test.
            Return
        }
    }

    # Exit if running in restricted admin mode without explicit credentials
    if (!$Credential -and (Get-RestrictedAdminModeSetting)) {
        Write-Warning "Restricted Admin Mode appears to be in place, re-run with the '-Credential domain\user' option"
        break;
    }

    # Initial variables
    $AllDomainsCertPublishersSIDs = @()
    $AllDomainsDomainAdminSIDs = @()
    $ClientAuthEKUs = '1\.3\.6\.1\.5\.5\.7\.3\.2|1\.3\.6\.1\.5\.2\.3\.4|1\.3\.6\.1\.4\.1\.311\.20\.2\.2|2\.5\.29\.37\.0'
    $DangerousRights = 'GenericAll|WriteDacl|WriteOwner|WriteProperty'
    $EnrollmentAgentEKU = '1\.3\.6\.1\.4\.1\.311\.20\.2\.1'
    $SafeObjectTypes = '0e10c968-78fb-11d2-90d4-00c04f79dc55|a05b8cc2-17bc-4802-a710-e7c15ab866a2'
    $SafeOwners = '-512$|-519$|-544$|-18$|-517$|-500$'
    $SafeUsers = '-512$|-519$|-544$|-18$|-517$|-500$|-516$|-9$|-526$|-527$|S-1-5-10'
    $UnsafeOwners = 'S-1-1-0|-11$|-513$|-515$'
    $UnsafeUsers = 'S-1-1-0|-11$|-513$|-515$'

    # Generated variables
    $Dictionary = New-Dictionary
    $ForestGC = $(Get-ADDomainController -Discover -Service GlobalCatalog -ForceDiscover | Select-Object -ExpandProperty Hostname) + ":3268"
    $DNSRoot = [string]((Get-ADForest -server $server).RootDomain | Get-ADDomain -server $server).DNSRoot
    $EnterpriseAdminsSID = ([string]((Get-ADForest -server $server).RootDomain | Get-ADDomain -server $server).DomainSID) + '-519'
    $PreferredOwner = New-Object System.Security.Principal.SecurityIdentifier($EnterpriseAdminsSID)
    $DomainSIDs = (Get-ADForest -server $server).Domains | ForEach-Object { (Get-ADDomain -server $server $_).DomainSID.Value }
    $DomainSIDs | ForEach-Object {
        $AllDomainsCertPublishersSIDs += $_ + '-517'
        $AllDomainsDomainAdminSIDs += $_ + '-512'
    }

    # Add SIDs of (probably) Safe Users to $SafeUsers
    #Get-ADGroupMember -server $server $EnterpriseAdminsSID | ForEach-Object {
    #    $SafeUsers += '|' + $_.SID.Value
    #}
	
	<#
    #(Get-ADForest -server $server).Domains | ForEach-Object {
        $DomainSID = (Get-ADDomain -server $server).DomainSID.Value
        $SafeGroupRIDs = @('-517','-512')
        $SafeGroupSIDs = @('S-1-5-32-544')
        #foreach ($rid in $SafeGroupRIDs ) {
        #    $SafeGroupSIDs += $DomainSID + $rid
        #}
        foreach ($sid in $SafeGroupSIDs) {
            $sid = ($DomainSID + $sid)
            $groupmembers = (Get-ADGroupMember $sid -Server $server -Recursive)
            $users += $groupMembers.SID.Value
        }
        foreach ($user in $users) {
            $SafeUsers += '|' + $user
        }
    #}
	#>

    if (!$Credential -and (Get-RestrictedAdminModeSetting)) {
        Write-Warning "Restricted Admin Mode appears to be in place, re-run with the '-Credential domain\user' option"
        break;
    }

    if ($Forest) {
        $Targets = $Forest
    } elseif ($InputPath) {
        $Targets = Get-Content $InputPath
    } else {
        if ($Credential){
            $Targets = (Get-ADForest -server $server -Credential $Credential).Name
        } else {
            $Targets = (Get-ADForest -server $server).Name
        }
    }

    Write-Host "Gathering AD CS Objects from $($Targets)..."
    
	$ADRoot = (Get-ADRootDSE -Server $server).defaultNamingContext
	$ADCSObjects = (Get-ADObject -Server $server -Filter * -SearchBase "CN=Public Key Services,CN=Services,CN=Configuration,$ADRoot" -SearchScope 2 -Properties *)
	
	#Set-AdditionalCAProperty -ADCSObjects $ADCSObjects
	
	$ADCSObjects | Where-Object objectClass -Match 'pKIEnrollmentService' | ForEach-Object {
		[string]$CAEnrollmentEndpoint = $_.'msPKI-Enrollment-Servers' | Select-String 'http.*' | ForEach-Object { $_.Matches[0].Value }
		[string]$CAFullName = "$($_.dNSHostName)\$($_.Name)"
		$CAHostname = $_.dNSHostName.split('.')[0]
		# $CAName = $_.Name
		if ($Credential) {
			$cadn = (Get-ADObject -Server $server -Filter { (Name -eq $CAHostName) -and (objectclass -eq 'computer') } -Credential $Credential)
			$CAHostDistinguishedName = $cadn.DistinguishedName
			$cafqdn = (Get-ADObject -server $server -Filter { (Name -eq $CAHostName) -and (objectclass -eq 'computer') } -Properties DnsHostname -Credential $Credential)
			$CAHostFQDN = $cafqdn.DnsHostname
		} else {
			$cadn = (Get-ADObject -server $server -Filter { (Name -eq $CAHostName) -and (objectclass -eq 'computer')})
			$CAHostDistinguishedName = $cadn.DistinguishedName
			$cafqdn = (Get-ADObject -server $server -Filter { (Name -eq $CAHostName) -and (objectclass -eq 'computer') } -Properties DnsHostname)
			$CAHostFQDN = $cafqdn.DnsHostname
		}
		$ping = Test-Connection -ComputerName $CAHostFQDN -Quiet -Count 1
		if ($ping) {
			try {
				if ($Credential) {
					$CertutilAudit = Invoke-Command -ComputerName $CAHostname -Credential $Credential -ScriptBlock { param($CAFullName); certutil -config $CAFullName -getreg CA\AuditFilter } -ArgumentList $CAFullName
				} else {
					$CertutilAudit = certutil -config $CAFullName -getreg CA\AuditFilter
				}
			} catch {
				$AuditFilter = 'Failure'
			}
			try {
				if ($Credential) {
					$CertutilFlag = Invoke-Command -ComputerName $CAHostname -Credential $Credential -ScriptBlock { param($CAFullName); certutil -config $CAFullName -getreg policy\EditFlags } -ArgumentList $CAFullName
				} else {
					$CertutilFlag = certutil -config $CAFullName -getreg policy\EditFlags
				}
			} catch {
				$AuditFilter = 'Failure'
			}
		} else {
			$AuditFilter = 'CA Unavailable'
			$SANFlag = 'CA Unavailable'
		}
		if ($CertutilAudit) {
			try {
				[string]$AuditFilter = $CertutilAudit | Select-String 'AuditFilter REG_DWORD = ' | Select-String '\('
				$AuditFilter = $AuditFilter.split('(')[1].split(')')[0]
			} catch {
				try {
					[string]$AuditFilter = $CertutilAudit | Select-String 'AuditFilter REG_DWORD = '
					$AuditFilter = $AuditFilter.split('=')[1].trim()
				} catch {
					$AuditFilter = 'Never Configured'
				}
			}
		}
		if ($CertutilFlag) {
			[string]$SANFlag = $CertutilFlag | Select-String ' EDITF_ATTRIBUTESUBJECTALTNAME2 -- 40000 \('
			if ($SANFlag) {
				$SANFlag = 'Yes'
			} else {
				$SANFlag = 'No'
			}
		}
		Add-Member -InputObject $_ -MemberType NoteProperty -Name AuditFilter -Value $AuditFilter -Force
		Add-Member -InputObject $_ -MemberType NoteProperty -Name CAEnrollmentEndpoint -Value $CAEnrollmentEndpoint -Force
		Add-Member -InputObject $_ -MemberType NoteProperty -Name CAFullName -Value $CAFullName -Force
		Add-Member -InputObject $_ -MemberType NoteProperty -Name CAHostname -Value $CAHostname -Force
		Add-Member -InputObject $_ -MemberType NoteProperty -Name CAHostDistinguishedName -Value $CAHostDistinguishedName -Force
		Add-Member -InputObject $_ -MemberType NoteProperty -Name SANFlag -Value $SANFlag -Force
	}
	
	$ADCSObjects += Get-CAHostObject -ADCSObjects $ADCSObjects
	$CAHosts = Get-CAHostObject -ADCSObjects $ADCSObjects
	$CAHosts | ForEach-Object { $SafeUsers += '|' + $_.Name }
    

    if ( $Scans ) {
    # If the Scans parameter was used, Invoke-Scans with the specified checks.
        $Results = Invoke-Scans -Scans $Scans
            # Re-hydrate the findings arrays from the Results hash table
            $AllIssues      = $Results['AllIssues']
            $AuditingIssues = $Results['AuditingIssues']
            $ESC1           = $Results['ESC1']
            $ESC2           = $Results['ESC2']
            $ESC3           = $Results['ESC3']
            $ESC4           = $Results['ESC4']
            $ESC5           = $Results['ESC5']
            $ESC6           = $Results['ESC6']
            $ESC8           = $Results['ESC8']
    }

    # If these are all empty = no issues found, exit
    if ($null -eq $Results) {
        Write-Host "`n$(Get-Date) : No ADCS issues were found." -ForegroundColor Green
        break
    }

    switch ($Mode) {
        0 {
            Format-Result $AuditingIssues '0'
            Format-Result $ESC1 '0'
            Format-Result $ESC2 '0'
            Format-Result $ESC3 '0'
            Format-Result $ESC4 '0'
            Format-Result $ESC5 '0'
            Format-Result $ESC6 '0'
            Format-Result $ESC8 '0'
        }
        1 {
            Format-Result $AuditingIssues '1'
            Format-Result $ESC1 '1'
            Format-Result $ESC2 '1'
            Format-Result $ESC3 '1'
            Format-Result $ESC4 '1'
            Format-Result $ESC5 '1'
            Format-Result $ESC6 '1'
            Format-Result $ESC8 '1'
        }
        2 {
            $Output = 'ADCSIssues.CSV'
            Write-Host "Writing AD CS issues to $Output..."
            try {
                $AllIssues | Select-Object Forest, Technique, Name, Issue | Export-Csv -NoTypeInformation $Output
                Write-Host "$Output created successfully!"
            } catch {
                Write-Host 'Ope! Something broke.'
            }
        }
        3 {
            $Output = 'ADCSRemediation.CSV'
            Write-Host "Writing AD CS issues to $Output..."
            try {
                $AllIssues | Select-Object Forest, Technique, Name, DistinguishedName, Issue, Fix | Export-Csv -NoTypeInformation $Output
                Write-Host "$Output created successfully!"
            } catch {
                Write-Host 'Ope! Something broke.'
            }
        }
        4 {
            Write-Host 'Creating a script to revert any changes made by Locksmith...'
            try { Export-RevertScript -AuditingIssues $AuditingIssues -ESC1 $ESC1 -ESC2 $ESC2 -ESC6 $ESC6 } catch {}
            Write-Host 'Executing Mode 4 - Attempting to fix all identified issues!'
            if ($AuditingIssues) {
                $AuditingIssues | ForEach-Object {
                    $FixBlock = [scriptblock]::Create($_.Fix)
                    Write-Host "Attempting to fully enable AD CS auditing on $($_.Name)..."
                    Write-Host "This should have little impact on your environment.`n"
                    Write-Host 'Command(s) to be run:'
                    Write-Host 'PS> ' -NoNewline
                    Write-Host "$($_.Fix)`n" -ForegroundColor Cyan
                    try {
                        $WarningError = $null
                        Write-Warning 'If you continue, this script will attempt to fix this issue.' -WarningAction Inquire -ErrorVariable WarningError
                        if (!$WarningError) {
                            try {
                                Invoke-Command -ScriptBlock $FixBlock
                            } catch {
                                Write-Error 'Could not modify AD CS auditing. Are you a local admin on this host?'
                            }
                        }
                    } catch {
                        Write-Host 'SKIPPED!' -ForegroundColor Yellow
                    }
                    Read-Host -Prompt 'Press enter to continue...'
                }
            }
            if ($ESC1) {
                $ESC1 | ForEach-Object {
                    $FixBlock = [scriptblock]::Create($_.Fix)
                    Write-Host "Attempting to enable Manager Approval on the $($_.Name) template...`n"
                    Write-Host 'Command(s) to be run:'
                    Write-Host 'PS> ' -NoNewline
                    Write-Host "$($_.Fix)`n" -ForegroundColor Cyan
                    try {
                        $WarningError = $null
                        Write-Warning "This could cause some services to stop working until certificates are approved.`nIf you continue this script will attempt to fix this issues." -WarningAction Inquire -ErrorVariable WarningError
                        if (!$WarningError) {
                            try {
                                Invoke-Command -ScriptBlock $FixBlock
                            } catch {
                                Write-Error 'Could not enable Manager Approval. Are you an Active Directory or AD CS admin?'
                            }
                        }
                    } catch {
                        Write-Host 'SKIPPED!' -ForegroundColor Yellow
                    }
                    Read-Host -Prompt 'Press enter to continue...'
                }
            }
            if ($ESC2) {
                $ESC2 | ForEach-Object {
                    $FixBlock = [scriptblock]::Create($_.Fix)
                    Write-Host "Attempting to enable Manager Approval on the $($_.Name) template...`n"
                    Write-Host 'Command(s) to be run:'
                    Write-Host 'PS> ' -NoNewline
                    Write-Host "$($_.Fix)`n" -ForegroundColor Cyan
                    try {
                        $WarningError = $null
                        Write-Warning "This could cause some services to stop working until certificates are approved.`nIf you continue, this script will attempt to fix this issue." -WarningAction Inquire -ErrorVariable WarningError
                        if (!$WarningError) {
                            try {
                                Invoke-Command -ScriptBlock $FixBlock
                            } catch {
                                Write-Error 'Could not enable Manager Approval. Are you an Active Directory or AD CS admin?'
                            }
                        }
                    } catch {
                        Write-Host 'SKIPPED!' -ForegroundColor Yellow
                    }
                    Read-Host -Prompt 'Press enter to continue...'
                }
            }
            if ($ESC6) {
                $ESC6 | ForEach-Object {
                    $FixBlock = [scriptblock]::Create($_.Fix)
                    Write-Host "Attempting to disable the EDITF_ATTRIBUTESUBJECTALTNAME2 flag on $($_.Name)...`n"
                    Write-Host 'Command(s) to be run:'
                    Write-Host 'PS> ' -NoNewline
                    Write-Host "$($_.Fix)`n" -ForegroundColor Cyan
                    try {
                        $WarningError = $null
                        Write-Warning "This could cause some services to stop working.`nIf you continue this script will attempt to fix this issues." -WarningAction Inquire -ErrorVariable WarningError
                        if (!$WarningError) {
                            try {
                                Invoke-Command -ScriptBlock $FixBlock
                            } catch {
                                Write-Error 'Could not disable the EDITF_ATTRIBUTESUBJECTALTNAME2 flag. Are you an Active Directory or AD CS admin?'
                            }
                        }
                    } catch {
                        Write-Host 'SKIPPED!' -ForegroundColor Yellow
                    }
                    Read-Host -Prompt 'Press enter to continue...'
                }
            }
        }
    }
}