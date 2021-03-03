#UAG Auto Deploy Script Proof of Concept
#Updated: 3/1/21
#Author: VMware PSO
#Note: Offered as is, no warranty, no support officially from VMware
#Requires
#--------
#uagdeploy-20.12.0.0-17307559 (if 3.10 or newer UAG being deployed - BE SURE TO USE RIGHT UAG DEPLOY PACKAGE! WRONG VERSION FOR OVA BEING DEPLOYED CAN FAIL)
#uagdeploy-3.9.1.0-15851887 (if UAG 3.9.1 being deployed) - WARNING! Script has not be tested with anything older than 3.9.1 - use at your own risk
#OVFtool 4.4+
#PowerCLI 12.2
#PowerShell 5.1.18362.145+
#find-module Posh-SSH | Install-Module
#'master-uag-list.csv' - File created with a configuration per row representing a UAG appliance, fill out all information per row and column for each UAG, passwords can be left blank for now with "" and use the script to set the passwords as optional capability
#Also need to permit the uagdeploy.ps1 & uagdeploy.psm1 files to run without promptig of the autodeploy scripts.
#--------
#Misc
#Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
#Unblock-File <full path>uagdeploy.ps1
#Unblock-File <full path>uagdeploy.psm1
#--------
#Updates:
#*v1 - Basic script functionality to auto-deploy UAG developed with the ini generated on the fly allowing for all setttings to be configured via master-uag-list.csv (only some attributes coded in at this time, not all aspects of the INI have been developed)
#*v2 - Added encrypted passwords parsing capabilty for UAG root and admin accounts so the deploy can mitigate seeing these in plain text
#*v3 - Added redumintary menu system to the script to create, delete, and exit to increase the speed of deploying and deleting UAG appliances
#*v3 - The CSV is now the basis for being able to create and delete UAG VM's as all UAG's that are used within this script need to be managed (configured) within the master-uag-list.csv
#*v3 - Added some cleanup aspects to the script for deleting and clearing files & variables
#*v4 - Added menu option to manage passwords directly from this script in the CSV eliminating need for seperate encrypt file and process
#*v4 - Added seperate AES 32-bit keys per credential type per uag
#*v4 - Added confirmation for deletions
#*v5 - Added extra layer to pasword menu to change vcenter, root or admin passwords for all UAGs (records) in the CSV file
#*v5 - Added ability to mass deploy UAG's based on Horizon Pod Name column in the CSV 'PodName'
#*v6 - Fixed bug with setting passwords for single UAG's
#*v6 - Added feature to delete UAG's at scale based off of Horizon Pod name
#*v6 - Updated CSV and code to use an INItmpl field per UAG to specify the UAG INI template
#*v6 - Added vCenter username in password management
#*v6 - Added feature in CSV for Disabled = 0 or 1 to set the VM record to be disabled and if so it cannot be created or deleted if that value is set to 1, this is for skipping speciifc UAGs capability
#*v6 - Updated CSV and code to use Horizon edge service settings for the most core settings - 5 settings so template can be agnostic from those to help with very large scale deployments where UAG N+1 VIP model may be needed
#*v6 - Added capabilty to reset UAG root passwords on DEPLOYED appliances
#*v7 - Added capability to reset admin password on DEPLOYED appliances using REST-API but it *REQUIRES* reboot if UAG 3.9.1 OVA used, recommend only using 20.09+ as 3.9.1& 3.10 are unstable using REST API here.
#*v7 - Added capability to reset role_monitoring password on DEPLOYED appliances using REST-API but it *REQUIRES* reboot if UAG 3.9.1 OVA used, recommend only using 20.09+ as 3.9.1 & 3.10 are unstable using REST API here.
#*v7 - Added capability to deploy UAG with role_monitoring UAG in the INI and CSV - This UAG capabilty only works with UAG 2009+, it is not supported with 3.10 and older
#*v8 - Added ability to get, start, and stop Quiesce mode for Horizon Pod UAG's that are running and tested with 3.9.1 successfully
#*v9 - Modified menu options to hopefully make it more consistent and easier to use
#*v9 - Added logging where it will record a transcript of the console  and create it into a '_Deploy-Log-(domain)-(username)-(date-time).txt' file
#*v10 - Added capability to update UAG SSL certificates for user and admin certs for running UAG's as part of day 2 ops
#*v10 - Added capability to specify certs in CSV for admin and end_user and deploy UAG's with those certs - NOTE don't set the SSL settings in the INI template, leave them out and configure in CSV instead.
#*v11 - Added Multi-NIC support by adding deploymentOption(onenic,twonic,threenic),ip0,ip1,ip2,netmask0,netmask1,netmask2,routes0,routes1,routes2,netInternet,netManagementNetwork,netBackendNetwork and also added sessionTimeout,ssEnabled INI parameters to CSV.  From here 1,2,3, NIC deployments can happen with the INI having the fields and the values configured in the CSV to set them to.
#*v12 - Modified reboot of UAG's when changing admin/monitoring for 3.9.1 to occur via vSphere and not root - commented out old code so can be re-enabled via root if desired
#*v12 - Changed 'Disabled' in CSV to be 'Skipped' to better reflect what it does
#*v12 - Added Quiesce mode in CSV to be possibel to be set to true/false or left blank in which case it will default to whatever is in the template INI
#
#Notes
#--------
#netInternet (eth0)          - ip0
#netManagementNetwork (eth1) - ip1
#netBackendNetwork (eth2)    - ip2
#
#Asks
#--------
#None
#--------
Stop-Transcript | out-null
$LogFilename = "_Deploy-Log-" + $env:userdomain + "-" + $env:username + "-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".txt"
cls
Start-Transcript -path $LogFilename -Force
$ScriptRun = $true
while ($ScriptRun) {
    $MenuAction = @()
    #MENU-MAIN
    $MenuAction = Read-Host -Prompt "[1] - Deploy UAG(s), [2] - Delete UAG(s), [3] - CSV Credential Editing, [4] - UAG Day 2 operations, or [5] - Done"
    if ($MenuAction -eq "1") { #MENU-DEPLOY
        write-host "INFO: Deploy Mode"
        write-host "-----"
        $DeployModeType = @()
        $DeployModeType = Read-Host -Prompt "[1] Single UAG deploy, or [2] Horizon Pod UAGs deploy?"
        if ($DeployModeType -eq "1") { #MENU-DEPLOY-SINGLE
            $CreateVM = @()
            $CreateVM = Read-Host -Prompt "Enter name of UAG VM to create and pull configuration from CSV"
            $CSV = @()
            $UAGinitemplate = @()
            $UAGini = @()
            $iniFile = @()
            $SecurePassword = @()
            $VCUnsecurePassword = @()
            $UAGrootPWsec = @()
            $UAGrootPWunsec = @()
            $UAGadminPWsec = @()
            $UAGadminPWunsec = @()
            $RoleMonitoringUserPresent = $false
            $CSV = Import-Csv -Path ".\master-uag-list.csv"
            write-host "INFO:" @($CSV).Count "UAG configuration(s) founds in CSV"
            $CreateVM = $CSV | Where-Object {$_.UAGname -match $CreateVM}
            if ($CreateVM) {
                if (test-Path $CreateVM.INItmpl) {
                    Remove-Item $CreateVM.INItmpl -Force
                    write-host "INFO: Deleted Temporary UAG INI file"
                } else {}
                write-host "INFO: UAG VM record for"$CreateVM.UAGname "located"
                if ($CreateVM.Skipped -eq 1) {
                    #VM record is set to be disabled so skip this process
                    write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                    continue
                } else {}
                $iniFile = $CreateVM.INItmpl
                write-host "INFO: INI template file being used is" $iniFile
                $timer = @()
                $timer = [Diagnostics.Stopwatch]::StartNew()
                $vckey = Get-Content $CreateVM.VCkey
                $uagrootkey = Get-Content $CreateVM.UAGrootkey
                $uagadminkey = Get-Content $CreateVM.UAGadminkey
                $uagMonitoringkey = Get-Content $CreateVM.UAGmonitoringkey
                if (!$vckey -or !$uagrootkey -or !$uagadminkey) {
                    write-host "ERROR: Could not load a required key for decryption, check your CSV settings or key is in the local working directory as the script and try again"
                    break
                } else {}
                $UAGiniTemplate = Get-Content $iniFile
                if (!$UAGiniTemplate) {
                    write-host "FATAL: Could not load INI Template File" $iniFile ", please ensure this INI template file is in the same directory as the script!"
                    Stop-Transcript
                    exit
                } else {}
                $SecurePassword = ($CreateVM.vCenterPassword | ConvertTo-SecureString -Key $vckey)
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                $VCUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                $UAGrootPWsec = ($CreateVM.UAGrootPW | ConvertTo-SecureString -Key $uagrootkey)
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($UAGrootPWsec)
                $UAGrootPWunsec = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                $UAGadminPWsec = ($CreateVM.UAGadminPW | ConvertTo-SecureString -Key $uagadminkey)
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($UAGadminPWsec)
                $UAGadminPWunsec = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                $UAGMonitoringPWsec = ($CreateVM.UAGMonitoringPW | ConvertTo-SecureString -Key $uagMonitoringkey)
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($UAGMonitoringPWsec)
                $UAGMonitoringPWunsec = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                Connect-VIServer -Server $CreateVM.vCentername -User $CreateVM.vCenterUser -Password $VCUnsecurePassword -Force
                $VMList = @()
                $VMList = Get-VM
                if ($VMList | Where-Object {$_.Name -eq $CreateVM.UAGname}) {
                    write-host "WARNING: VM ALREADY EXISTS IN VPHERE!!!"
                } else {
                    write-host "INFO: VM name" $CSV.UAGname "not found in VM inventory in vsphere"
                    if ($UAGiniTemplate) {
                        write-host "INFO: Loaded UAG INI Template Successfully"
                        foreach ($iniLine in $UAGiniTemplate) {
                            if ($iniLine -match "defaultGateway=") { 
                                $UAGini += "defaultGateway=" + $CreateVM.defaultGateway
                                write-host "MODIFY: defaultGateway="$CreateVM.defaultGateway
                            } elseif ($iniLine -match "ip0=") {
                                $UAGini += "ip0=" + $CreateVM.ip0
                                write-host "MODIFY: ip0="$CreateVM.ip0
                            } elseif ($iniLine -match "ip1=") {
                                $UAGini += "ip1=" + $CreateVM.ip1
                                write-host "MODIFY: ip1="$CreateVM.ip1
                            } elseif ($iniLine -match "ip2=") {
                                $UAGini += "ip2=" + $CreateVM.ip2
                                write-host "MODIFY: ip2="$CreateVM.ip2
                            } elseif ($iniLine -match "netmask0=") {
                                $UAGini += "netmask0=" + $CreateVM.netmask0
                                write-host "MODIFY: netmask0="$CreateVM.netmask0
                            } elseif ($iniLine -match "netmask1=") {
                                $UAGini += "netmask1=" + $CreateVM.netmask1
                                write-host "MODIFY: netmask1="$CreateVM.netmask1
                            } elseif ($iniLine -match "netmask2=") {
                                $UAGini += "netmask2=" + $CreateVM.netmask2
                                write-host "MODIFY: netmask2="$CreateVM.netmask2
                            } elseif ($iniLine -match "routes0=") {
                                $UAGini += "routes0=" + $CreateVM.routes0
                                write-host "MODIFY: routes0="$CreateVM.routes0
                            } elseif ($iniLine -match "routes1=") {
                                $UAGini += "routes1=" + $CreateVM.routes1
                                write-host "MODIFY: routes1="$CreateVM.routes1
                            } elseif ($iniLine -match "routes2=") {
                                $UAGini += "routes2=" + $CreateVM.routes2
                                write-host "MODIFY: routes2="$CreateVM.routes2
                            } elseif ($iniLine -match "dns=") {
                                $UAGini += "dns=" + $CreateVM.dns
                                write-host "MODIFY: dns="$CreateVM.dns
                            } elseif ($iniLine -match "dnsSearch=") {
                                $UAGini += "dnsSearch=" + $CreateVM.dnsSearch
                                write-host "MODIFY: dnsSearch="$CreateVM.dnsSearch
                            } elseif ($iniLine -match "ntpServers=") {
                                $UAGini += "ntpServers=" + $CreateVM.ntpServers
                                write-host "MODIFY: ntpServers="$CreateVM.ntpServers
                            } elseif ($iniLine -imatch "uagName=") {
                                $UAGini += "uagName=" + $CreateVM.UAGname
                                write-host "MODIFY: uagName="$CreateVM.UAGname
                            } elseif ($iniLine -imatch "name=" -and $iniLine -inotmatch $("name=" + $UAGvm.UAGmonitoringUsername)) {
                                $UAGini += "name=" + $CreateVM.VCname
                                write-host "MODIFY: name="$CreateVM.VCname
                            } elseif ($iniLine -match "source=") {
                                $UAGini += "source=" + $(pwd).Path + "\" + $CreateVM.source
                                write-host "MODIFY: source="$(pwd)"\"$CreateVM.source
                            } elseif ($iniLine -match "ds=") {
                                $UAGini += "ds=" + $CreateVM.ds
                                write-host "MODIFY: ds="$CreateVM.ds
                            } elseif ($iniLine -match "netInternet=") {
                                $UAGini += "netInternet=" + $CreateVM.netInternet
                                write-host "MODIFY: netInternet="$CreateVM.netInternet
                            } elseif ($iniLine -match "netManagementNetwork=") {
                                $UAGini += "netManagementNetwork=" + $CreateVM.netManagementNetwork
                                write-host "MODIFY: netManagementNetwork="$CreateVM.netManagementNetwork
                            } elseif ($iniLine -match "netBackendNetwork=") {
                                $UAGini += "netBackendNetwork=" + $CreateVM.netBackendNetwork
                                write-host "MODIFY: netBackendNetwork="$CreateVM.netBackendNetwork
                            } elseif ($iniLine -match "target=") {
                                $UAGini += "target=" + "vi://" + $CreateVM.vCenterUser + ":" + $VCUnsecurePassword + "@" + $CreateVM.vCentername + $CreateVM.target
                                write-host "MODIFY: target=vi://"$CreateVM.vCenterUser"@"$CreateVM.vCentername"/"$CreateVM.target
                            } elseif ($iniLine -match "blastExternalUrl=") {
                                $UAGini += "blastExternalUrl=" + $CreateVM.blastExternalUrl
                                write-host "MODIFY: blastExternalUrl="$CreateVM.blastExternalUrl
                            } elseif ($iniLine -match "pcoipExternalUrl=") {
                                $UAGini += "pcoipExternalUrl=" + $CreateVM.pcoipExternalUrl
                                write-host "MODIFY: pcoipExternalUrl="$CreateVM.pcoipExternalUrl
                            } elseif ($iniLine -match "tunnelExternalUrl=") {
                                $UAGini += "tunnelExternalUrl=" + $CreateVM.tunnelExternalUrl
                                write-host "MODIFY: tunnelExternalUrl="$CreateVM.tunnelExternalUrl
                            } elseif ($iniLine -match "proxyDestinationUrl=") {
                                $UAGini += "proxyDestinationUrl=" + $CreateVM.proxyDestinationUrl
                                write-host "MODIFY: proxyDestinationUrl="$CreateVM.proxyDestinationUrl
                            } elseif ($iniLine -match "proxyDestinationUrlThumbprints=") {
                                $UAGini += "proxyDestinationUrlThumbprints=" + $CreateVM.proxyDestinationUrlThumbprints
                                write-host "MODIFY: proxyDestinationUrlThumbprints="$CreateVM.proxyDestinationUrlThumbprints
                            } elseif ($iniLine -match $("name=" + $CreateVM.UAGmonitoringUsername)) {
                                $RoleMonitoringUserPresent = $true
                                $UAGini += $iniLine
                            } elseif ($iniLine -match "sessionTimeout=") {
                                $UAGini += "sessionTimeout=" + $CreateVM.sessionTimeout
                                write-host "MODIFY: sessionTimeout="$CreateVM.sessionTimeout
                            } elseif ($iniLine -match "sshEnabled=") {
                                $UAGini += "sshEnabled=" + $CreateVM.sshEnabled
                                write-host "MODIFY: sshEnabled="$CreateVM.sshEnabled
                            } elseif ($iniLine -match "deploymentOption=") {
                                $UAGini += "deploymentOption=" + $CreateVM.deploymentOption
                                write-host "MODIFY: deploymentOption="$CreateVM.deploymentOption
                            } elseif ($iniLine -match "quiesceMode=") {
                                if ($CreateVM.quiesceMode) {
                                    $UAGini += "quiesceMode=" + $CreateVM.quiesceMode
                                    write-host "MODIFY: quiesceMode="$CreateVM.quiesceMode
                                } else {
                                    $UAGini += $iniLine
                                }
                            } else {
                                $UAGini += $iniLine
                            }
                        }
                        if ($CreateVM.AdminCert -and $CreateVM.AdminCertKey) {
                            $UAGini += ""
                            $UAGini += "[SSLCertAdmin]"
                            write-host "MODIFY: [SSLCertAdmin]"
                            $UAGini += "pemPrivKey=" + $CreateVM.AdminCertKey
                            write-host "MODIFY: pemPrivKey=" $CreateVM.AdminCertKey
                            $UAGini += "pemCerts=" + $CreateVM.AdminCert
                            write-host "MODIFY: pemCerts=" $CreateVM.AdminCert
                        } else {}
                        if ($CreateVM.UserCert -and $CreateVM.UserCertKey) {
                            $UAGini += ""
                            $UAGini += "[SSLCert]"
                            write-host "MODIFY: [SSLCert]"
                            $UAGini += "pemPrivKey=" + $CreateVM.UserCertKey
                            write-host "MODIFY: pemPrivKey+" $CreateVM.UserCertKey
                            $UAGini += "pemCerts=" + $CreateVM.UserCert
                            write-host "MODIFY: pemCerts=" $CreateVM.UserCert
                        } else {}
                        $UAGini | Out-File ".\TempUAGini.ini"
                        #Check if Role Monitoring User Account present in INI and also that we are not using 3.9.1 UAG which doesn't support it at deploy time
                        if ($RoleMonitoringUserPresent -and ($CreateVM.source -inotmatch "3.9.1")) {
                            if ($uagMonitoringkey) {
                                $monitoringcred = @()
                                $monitoringcred = $CreateVM.UAGmonitoringUsername + ":" + $UAGMonitoringPWunsec
                                write-host "INFO: Deploying UAG with Monitoring account as additional configuration"
                                .\uagdeploy.ps1 -iniFile ".\TempUAGini.ini" -rootPwd $UAGrootPWunsec -adminPwd $UAGadminPWunsec -newAdminUserPwd $monitoringcred -ceipEnabled $false -noSSLVerify $true                                   
                                $RoleMonitoringUserPresent = $false
                            } else {
                                write-host "WARNING: UAG Monitoring key not loaded, so skipping deploying with Monitoring user account and instead deploying without that account"
                                .\uagdeploy.ps1 -iniFile ".\TempUAGini.ini" -rootPwd $UAGrootPWunsec -adminPwd $UAGadminPWunsec -ceipEnabled $false -noSSLVerify $true
                            } 
                        } else {
                            .\uagdeploy.ps1 -iniFile ".\TempUAGini.ini" -rootPwd $UAGrootPWunsec -adminPwd $UAGadminPWunsec -ceipEnabled $false -noSSLVerify $true
                        }
                    } else {
                        write-host "FATAL: Could not load UAG Template INI!!!"
                        $CSV = @()
                        $CreateVM = @()
                        $UAGinitemplate = @()
                        $UAGini = @()
                        $iniFile = @()
                        $SecurePassword = @()
                        $VCUnsecurePassword = @()
                        $UAGrootPWsec = @()
                        $UAGrootPWunsec = @()
                        $UAGadminPWsec = @()
                        $UAGadminPWunsec = @()
                        $BSTR = @()
                        $KeyFile = @()
                        $Key = @()
                        $UAGMonitoringPWsec = @()
                        $uagMonitoringkey = @()
                        $UAGMonitoringPWunsec = @()
                        $monitoringcred = @()
                        $timer.Stop()
                        Write-Host "Compeleted script in: " $timer.Elapsed.Hours ":" $timer.Elapsed.Minutes ":" $timer.Elapsed.Seconds
                        Stop-Transcript
                        exit
                    }
                }
                $CSV = @()
                $CreateVM = @()
                $UAGinitemplate = @()
                $UAGini = @()
                $iniFile = @()
                $SecurePassword = @()
                $VCUnsecurePassword = @()
                $UAGrootPWsec = @()
                $UAGrootPWunsec = @()
                $UAGadminPWsec = @()
                $UAGadminPWunsec = @()
                $BSTR = @()
                $KeyFile = @()
                $Key = @()
                $UAGMonitoringPWsec = @()
                $uagMonitoringkey = @()
                $UAGMonitoringPWunsec = @()
                $monitoringcred = @()
                Disconnect-VIServer -Server * -confirm:$false -Force
                Remove-Item ".\TempUAGini.ini" -Force
                Remove-Item ".\log-*" -Force
                $timer.Stop()
                Write-Host "Compeleted UAG deploy in: " $timer.Elapsed.Hours ":" $timer.Elapsed.Minutes ":" $timer.Elapsed.Seconds
            } else {
                write-host "ERROR: UAG VM record for"$CreateVM.UAGname "not located, please ensure the CSV has the configuration for the UAG or you are entering in the correct name and try again"
            } #END OF MENU-DEPLOY-SINGLE
        } elseif ($DeployModeType -eq "2") { #MENU-DEPLOY-POD
            write-host "INFO: All UAGs within a Horizon Pod deployment type selected"
            write-host "-----"
            $DeleteExisting = @()
            $DeleteQuestion = @()
            $DeleteQuestion = Read-Host -Prompt "Delete existing UAGs that are running in the Pod: (Y)es or (N)o - if 'N' they will be skipped"
            if ($DeleteQuestion -eq "Y") {
                $DeleteExisting = $true
            } elseif ($DeleteQuestion -eq "N") {
                $DeleteExisting = $false
            } else {
                write-host "ERROR: Invalid selection entered, please try again"
                break
            }
            $CSV = Import-Csv -Path ".\master-uag-list.csv"
            $HorizonPod = Read-Host -Prompt "Enter the name (Case Sensitive) of the Horizon Pod for which to deploy all UAG's as configured in CSV for the 'PodName' column?"
            $UAGvms = $CSV | Where-Object {$_.PodName -imatch $HorizonPod}
            if ($UAGvms) {
                write-host "Found" $UAGvms.Count "UAG appliances with configurations to deploy"
                $timer = @()
                $timer = [Diagnostics.Stopwatch]::StartNew()
                foreach ($UAGvm in $UAGvms) {
                    write-host "INFO: UAG VM record for"$UAGvm.UAGname "located"
                    if ($UAGvm.Skipped -eq 1) {
                        #VM record is set to be disabled so skip this process
                        write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                        continue
                    } else {}
                    $CSV = @()
                    $UAGinitemplate = @()
                    $UAGini = @()
                    $iniFile = @()
                    $SecurePassword = @()
                    $VCUnsecurePassword = @()
                    $UAGrootPWsec = @()
                    $UAGrootPWunsec = @()
                    $UAGadminPWsec = @()
                    $UAGadminPWunsec = @()
                    $RoleMonitoringUserPresent = $false
                    $iniFile = $UAGvm.INItmpl
                    if (test-Path $UAGvm.INItmpl) {
                        Remove-Item $UAGvm.INItmpl -Force
                        write-host "INFO: Deleted Temporary UAG INI file"
                    } else {}
                    write-host "INFO: INI template file being used is" $iniFile
                    $vckey = @()
                    $uagrootkey = @()
                    $uagadminkey = @()
                    $vckey = Get-Content $UAGvm.VCkey
                    $uagrootkey = Get-Content $UAGvm.UAGrootkey
                    $uagadminkey = Get-Content $UAGvm.UAGadminkey
                    $uagMonitoringkey = Get-Content $UAGvm.UAGmonitoringkey
                    if (!$vckey -or !$uagrootkey -or !$uagadminkey) {
                        write-host "ERROR: Could not load a required key for decryption, check your CSV settings or key is in the local working directory as the script and try again"
                        break
                    } else {}
                    $UAGiniTemplate = Get-Content $iniFile
                    if (!$UAGiniTemplate) {
                        write-host "FATAL: Could not load INI Template File" $iniFile " for VM:" $UAGvm.UAGName ", please ensure this INI template file is in the same directory as the script!"
                        continue
                    } else {}
                    $SecurePassword = ($UAGvm.vCenterPassword | ConvertTo-SecureString -Key $vckey)
                    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                    $VCUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                    $UAGrootPWsec = ($UAGvm.UAGrootPW | ConvertTo-SecureString -Key $uagrootkey)
                    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($UAGrootPWsec)
                    $UAGrootPWunsec = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                    $UAGadminPWsec = ($UAGvm.UAGadminPW | ConvertTo-SecureString -Key $uagadminkey)
                    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($UAGadminPWsec)
                    $UAGadminPWunsec = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                    $UAGMonitoringPWsec = ($UAGvm.UAGMonitoringPW | ConvertTo-SecureString -Key $uagMonitoringkey)
                    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($UAGMonitoringPWsec)
                    $UAGMonitoringPWunsec = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                    Connect-VIServer -Server $UAGvm.vCentername -User $UAGvm.vCenterUser -Password $VCUnsecurePassword -Force
                    $VMList = @()
                    $VMList = Get-VM
                    if ($VMList | Where-Object {$_.Name -eq $UAGvm.UAGname}) {
                        write-host "WARNING: VM" $UAGvm.UAGname "EXISTS IN VPHERE!!!"
                        if ($DeleteExisting) {
                            if (($VMList | Where-Object {$_.Name -eq $UAGvm.UAGname}).PowerState -eq "PoweredOn") {
                                write-host "INFO:" $UAGvm.UAGname "is powered on, powering off first before deletion"
                                Stop-VM -VM ($VMList | Where-Object {$_.Name -eq $UAGvm.UAGname}).Name -Confirm:$false
                            } else {}
                            write-host "INFO: Deleting" $UAGvm.UAGname
                            Remove-VM -VM ($VMList | Where-Object {$_.Name -eq $UAGvm.UAGname}).Name -DeletePermanently -Confirm:$false
                        } else {
                            write-host "Skipping VM" $UAGvm.UAGname "due to user election to not delete existing UAG VMs"
                            continue
                        }
                    } else {
                        write-host "INFO: VM name" $UAGvm.UAGname "not found in VM inventory in vsphere"
                    }
                    if ($UAGiniTemplate) {
                        write-host "INFO: Loaded UAG INI Template Successfully"
                        foreach ($iniLine in $UAGiniTemplate) {
                            if ($iniLine -match "defaultGateway=") { 
                                $UAGini += "defaultGateway=" + $UAGvm.defaultGateway
                                write-host "MODIFY: defaultGateway="$UAGvm.defaultGateway
                            } elseif ($iniLine -match "ip0=") {
                                $UAGini += "ip0=" + $UAGvm.ip0
                                write-host "MODIFY: ip0="$UAGvm.ip0
                            } elseif ($iniLine -match "ip1=") {
                                $UAGini += "ip1=" + $UAGvm.ip1
                                write-host "MODIFY: ip1="$UAGvm.ip1
                            } elseif ($iniLine -match "ip2=") {
                                $UAGini += "ip2=" + $UAGvm.ip2
                                write-host "MODIFY: ip2="$UAGvm.ip2
                            } elseif ($iniLine -match "netmask0=") {
                                $UAGini += "netmask0=" + $UAGvm.netmask0
                                write-host "MODIFY: netmask0="$UAGvm.netmask0
                            } elseif ($iniLine -match "netmask1=") {
                                $UAGini += "netmask1=" + $UAGvm.netmask1
                                write-host "MODIFY: netmask1="$UAGvm.netmask1
                            } elseif ($iniLine -match "netmask2=") {
                                $UAGini += "netmask2=" + $UAGvm.netmask2
                                write-host "MODIFY: netmask2="$UAGvm.netmask2
                            } elseif ($iniLine -match "routes0=") {
                                $UAGini += "routes0=" + $UAGvm.routes0
                                write-host "MODIFY: routes0="$UAGvm.routes0
                            } elseif ($iniLine -match "routes1=") {
                                $UAGini += "routes1=" + $UAGvm.routes1
                                write-host "MODIFY: routes1="$UAGvm.routes1
                            } elseif ($iniLine -match "routes2=") {
                                $UAGini += "routes2=" + $UAGvm.routes2
                                write-host "MODIFY: routes2="$UAGvm.routes2
                            } elseif ($iniLine -match "dns=") {
                                $UAGini += "dns=" + $UAGvm.dns
                                write-host "MODIFY: dns="$UAGvm.dns
                            } elseif ($iniLine -match "dnsSearch=") {
                                $UAGini += "dnsSearch=" + $UAGvm.dnsSearch
                                write-host "MODIFY: dnsSearch="$UAGvm.dnsSearch
                            } elseif ($iniLine -match "ntpServers=") {
                                $UAGini += "ntpServers=" + $UAGvm.ntpServers
                                write-host "MODIFY: ntpServers="$UAGvm.ntpServers
                            } elseif ($iniLine -imatch "uagName=") {
                                $UAGini += "uagName=" + $UAGvm.UAGname
                                write-host "MODIFY: uagName="$UAGvm.UAGname
                            } elseif ($iniLine -imatch "name=" -and $iniLine -inotmatch $("name=" + $UAGvm.UAGmonitoringUsername)) {
                                $UAGini += "name=" + $UAGvm.VCname
                                write-host "MODIFY: name="$UAGvm.VCname
                            } elseif ($iniLine -match "source=") {
                                $UAGini += "source=" + $(pwd).Path + "\" + $UAGvm.source
                                write-host "MODIFY: source="$(pwd)"\"$UAGvm.source
                            } elseif ($iniLine -match "ds=") {
                                $UAGini += "ds=" + $UAGvm.ds
                                write-host "MODIFY: ds="$UAGvm.ds
                            } elseif ($iniLine -match "netInternet=") {
                                $UAGini += "netInternet=" + $UAGvm.netInternet
                                write-host "MODIFY: netInternet="$UAGvm.netInternet
                            } elseif ($iniLine -match "netManagementNetwork=") {
                                $UAGini += "netManagementNetwork=" + $UAGvm.netManagementNetwork
                                write-host "MODIFY: netManagementNetwork="$UAGvm.netManagementNetwork
                            } elseif ($iniLine -match "netBackendNetwork=") {
                                $UAGini += "netBackendNetwork=" + $UAGvm.netBackendNetwork
                                write-host "MODIFY: netBackendNetwork="$UAGvm.netBackendNetwork
                            } elseif ($iniLine -match "target=") {
                                $UAGini += "target=" + "vi://" + $UAGvm.vCenterUser + ":" + $VCUnsecurePassword + "@" + $UAGvm.vCentername + $UAGvm.target
                                write-host "MODIFY: target=vi://"$UAGvm.vCenterUser"@"$UAGvm.vCentername"/"$UAGvm.target
                            } elseif ($iniLine -match "blastExternalUrl=") {
                                $UAGini += "blastExternalUrl=" + $UAGvm.blastExternalUrl
                                write-host "MODIFY: blastExternalUrl="$UAGvm.blastExternalUrl
                            } elseif ($iniLine -match "pcoipExternalUrl=") {
                                $UAGini += "pcoipExternalUrl=" + $UAGvm.pcoipExternalUrl
                                write-host "MODIFY: pcoipExternalUrl="$UAGvm.pcoipExternalUrl
                            } elseif ($iniLine -match "tunnelExternalUrl=") {
                                $UAGini += "tunnelExternalUrl=" + $UAGvm.tunnelExternalUrl
                                write-host "MODIFY: tunnelExternalUrl="$UAGvm.tunnelExternalUrl
                            } elseif ($iniLine -match "proxyDestinationUrl=") {
                                $UAGini += "proxyDestinationUrl=" + $UAGvm.proxyDestinationUrl
                                write-host "MODIFY: proxyDestinationUrl="$UAGvm.proxyDestinationUrl
                            } elseif ($iniLine -match "proxyDestinationUrlThumbprints=") {
                                $UAGini += "proxyDestinationUrlThumbprints=" + $UAGvm.proxyDestinationUrlThumbprints
                                write-host "MODIFY: proxyDestinationUrlThumbprints="$UAGvm.proxyDestinationUrlThumbprints
                            } elseif ($iniLine -match $("name=" + $UAGvm.UAGmonitoringUsername)) {
                                $RoleMonitoringUserPresent = $true
                                $UAGini += $iniLine
                            } elseif ($iniLine -match "sessionTimeout=") {
                                $UAGini += "sessionTimeout=" + $UAGvm.sessionTimeout
                                write-host "MODIFY: sessionTimeout="$UAGvm.sessionTimeout
                            } elseif ($iniLine -match "sshEnabled=") {
                                $UAGini += "sshEnabled=" + $UAGvm.sshEnabled
                                write-host "MODIFY: sshEnabled="$UAGvm.sshEnabled
                            } elseif ($iniLine -match "deploymentOption=") {
                                $UAGini += "deploymentOption=" + $UAGvm.deploymentOption
                                write-host "MODIFY: deploymentOption="$UAGvm.deploymentOption
                            } elseif ($iniLine -match "quiesceMode=") {
                                if ($UAGvm.quiesceMode) {
                                    $UAGini += "quiesceMode=" + $UAGvm.quiesceMode
                                    write-host "MODIFY: quiesceMode="$UAGvm.quiesceMode
                                } else {
                                    $UAGini += $iniLine
                                }
                            } else {
                                $UAGini += $iniLine
                            }
                        }
                        if ($UAGvm.AdminCert -and $UAGvm.AdminCertKey) {
                            $UAGini += ""
                            $UAGini += "[SSLCertAdmin]"
                            write-host "MODIFY: [SSLCertAdmin]"
                            $UAGini += "pemPrivKey=" + $UAGvm.AdminCertKey
                            write-host "MODIFY: pemPrivKey=" $UAGvm.AdminCertKey
                            $UAGini += "pemCerts=" + $UAGvm.AdminCert
                            write-host "MODIFY: pemCerts=" $UAGvm.AdminCert
                        } else {}
                        if ($UAGvm.UserCert -and $UAGvm.UserCertKey) {
                            $UAGini += ""
                            $UAGini += "[SSLCert]"
                            write-host "MODIFY: [SSLCert]"
                            $UAGini += "pemPrivKey=" + $UAGvm.UserCertKey
                            write-host "MODIFY: pemPrivKey+" $UAGvm.UserCertKey
                            $UAGini += "pemCerts=" + $UAGvm.UserCert
                            write-host "MODIFY: pemCerts=" $UAGvm.UserCert
                        } else {}
                        $UAGini | Out-File ".\TempUAGini.ini"
                        #Check if Role Monitoring User Account present in INI and also that we are not using 3.9.1 UAG which doesn't support it at deploy time
                        if ($RoleMonitoringUserPresent -and ($UAGvm.source -inotmatch "3.9.1")) {
                            if ($uagMonitoringkey) {
                                $monitoringcred = @()
                                $monitoringcred = $UAGvm.UAGmonitoringUsername + ":" + $UAGMonitoringPWunsec
                                write-host "INFO: Deploying UAG with Monitoring account as additional configuration"
                                .\uagdeploy.ps1 -iniFile ".\TempUAGini.ini" -rootPwd $UAGrootPWunsec -adminPwd $UAGadminPWunsec -newAdminUserPwd $monitoringcred -ceipEnabled $false -noSSLVerify $true                                   
                                $RoleMonitoringUserPresent = $false
                            } else {
                                write-host "WARNING: UAG Monitoring key not loaded, so skipping deploying with Monitoring user account and instead deploying without that account"
                                .\uagdeploy.ps1 -iniFile ".\TempUAGini.ini" -rootPwd $UAGrootPWunsec -adminPwd $UAGadminPWunsec -ceipEnabled $false -noSSLVerify $true
                            } 
                        } else {
                            .\uagdeploy.ps1 -iniFile ".\TempUAGini.ini" -rootPwd $UAGrootPWunsec -adminPwd $UAGadminPWunsec -ceipEnabled $false -noSSLVerify $true
                        }
                    } else {
                        write-host "FATAL: Could not load UAG Template INI!!!"
                        $CSV = @()
                        $CreateVM = @()
                        $UAGinitemplate = @()
                        $UAGini = @()
                        $iniFile = @()
                        $SecurePassword = @()
                        $VCUnsecurePassword = @()
                        $UAGrootPWsec = @()
                        $UAGrootPWunsec = @()
                        $UAGadminPWsec = @()
                        $UAGadminPWunsec = @()
                        $BSTR = @()
                        $KeyFile = @()
                        $Key = @()
                        $UAGMonitoringPWsec = @()
                        $uagMonitoringkey = @()
                        $UAGMonitoringPWunsec = @()
                        $monitoringcred = @()
                        $timer.Stop()
                        Stop-Transcript
                        exit
                    }
                    $CSV = @()
                    $CreateVM = @()
                    $UAGinitemplate = @()
                    $UAGini = @()
                    $iniFile = @()
                    $SecurePassword = @()
                    $VCUnsecurePassword = @()
                    $UAGrootPWsec = @()
                    $UAGrootPWunsec = @()
                    $UAGadminPWsec = @()
                    $UAGadminPWunsec = @()
                    $BSTR = @()
                    $KeyFile = @()
                    $Key = @()
                    $UAGMonitoringPWsec = @()
                    $uagMonitoringkey = @()
                    $UAGMonitoringPWunsec = @()
                    $monitoringcred = @()
                    Disconnect-VIServer -Server * -confirm:$false -Force
                    Remove-Item ".\TempUAGini.ini" -Force
                    Remove-Item ".\log-*" -Force  
                }
                $timer.Stop()
                Write-Host "Compeleted UAG deploys in: " $timer.Elapsed.Hours ":" $timer.Elapsed.Minutes ":" $timer.Elapsed.Seconds  
            } else {
                write-host "ERROR: No UAG's found in 'master-uag-list.csv' for the Horizon Pod with the name:"$HorizonPod
            }
        } else {
            write-host "ERROR: Invalid selection entered, please try again"
        } #END OF MENU-DEPLOY-POD
    } elseif ($MenuAction -eq "2") { #MENU-DELETE
        $DeleteMode = $true
        while ($DeleteMode) {
            write-host "INFO: Delete Mode"
            write-host "-----"
            $DeleteMenuAction = @()
            $DeleteMenuAction = Read-Host -Prompt "[1] - Delete Single, [2] - Delete All UAG VM's per Horizon Pod, or [3] - Done"
            if ($DeleteMenuAction -eq "1") { #MENU-DELETE-SINGLE
                $DeleteVM = @()
                $DeleteVM = Read-Host -Prompt "Name of VM in vCenter inventory to delete?"
                $CSV = Import-Csv -Path ".\master-uag-list.csv"
                $DeleteVM = $CSV | Where-Object {$_.UAGname -match $DeleteVM}
                if ($DeleteVM) {
                    write-host "INFO: Deleting VM" $DeleteVM.UAGname
                    if ($DeleteVM.Skipped -eq 1) {
                        #VM record is set to be disabled so skip this process
                        write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                        continue
                    } else {}
                    $DeleteWarning = Read-Host "Are you sure you want to delete? (Y)es or (N)o"
                    if ($DeleteWarning -eq "Y") {
                    } else {
                        write-host "WARNING: Aborted VM delete by request of script user"
                        break
                    }
                    $key = Get-Content $DeleteVM.VCkey
                    $SecurePassword = ($DeleteVM.vCenterPassword | ConvertTo-SecureString -Key $key)
                    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                    $VCUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                    Connect-VIServer -Server $DeleteVM.vCentername -User $DeleteVM.vCenterUser -Password $VCUnsecurePassword -Force
                    $VMList = @()
                    $VMList = Get-VM
                    $VMList = $VMList | Where-Object {$_.Name -eq $DeleteVM.UAGname}
                    if ($VMList) {
                        write-host "VM(s) founds with that name:"$DeleteVM.Count
                        if ($VMList.Count -ge 2) {
                            write-host "WARNING: Multiple VM's found if you proceed, they will all be deleted!!!"
                            $Proceed = @()
                            $Proceed = Read-Host -Prompt "Proceed with mass VM deletions?"
                            if ($Proceed -eq "Y") {
                                write-host "INFO: VM(s) located in vSphere inventory, deleting..."
                                foreach ($VM in $VMList) {
                                    if ($VM.PowerState -eq "PoweredOn") {
                                        write-host "INFO: $VM is powered on, powered off first before deletion"
                                        Stop-VM -VM $VM -Confirm:$false
                                    } else {}
                                    write-host "INFO: Deleting $VM"
                                    Remove-VM -VM $VM -DeletePermanently -Confirm:$false
                                }
                            } else {
                                write-host "INFO: Aborted mass VM deletion"
                            }
                        } else {
                            write-host "INFO: VM $VMList located in vSphere inventory, deleting..."
                            if ($VMList.PowerState -eq "PoweredOn") {
                                write-host "INFO: VM is powered on, powered off first before deletion"
                                Stop-VM -VM $VMList -Confirm:$false
                            } else {}
                            Remove-VM -VM $VMList -DeletePermanently -Confirm:$false
                        }
                    } else {
                        write-host "ERROR: VM" $DeleteVM.UAGname "not found in vSphere inventory"
                        $CSV = @()
                        $UAGinitemplate = @()
                        $UAGini = @()
                        $iniFile = @()
                        $SecurePassword = @()
                        $VCUnsecurePassword = @()
                        $UAGrootPWsec = @()
                        $UAGrootPWunsec = @()
                        $UAGadminPWsec = @()
                        $UAGadminPWunsec = @()
                        $BSTR = @()
                        $VMList = @()
                        $DeleteVM = @()
                        $VM = @()
                        $KeyFile = @()
                        $Key = @()
                        Disconnect-VIServer -Server * -confirm:$false -Force
                    }
                    $CSV = @()
                    $UAGinitemplate = @()
                    $UAGini = @()
                    $iniFile = @()
                    $SecurePassword = @()
                    $VCUnsecurePassword = @()
                    $UAGrootPWsec = @()
                    $UAGrootPWunsec = @()
                    $UAGadminPWsec = @()
                    $UAGadminPWunsec = @()
                    $BSTR = @()
                    $VMList = @()
                    $DeleteVM = @()
                    $VM = @()
                    $KeyFile = @()
                    $Key = @()
                    Disconnect-VIServer -Server * -confirm:$false -Force
                } else {
                    write-host "ERROR: VM not found in master-uag-list.csv and thus cannot be deleted, only can delete VM's using this script that are configured within the CSV"
                } #END OF MENU-DELETE-SINGLE
            } elseif ($DeleteMenuAction -eq "2") { #MENU-DELETE-POD
                #Code for Delete (A)ll UAG's per Horizon Pod
                $CSV = Import-Csv -Path ".\master-uag-list.csv"
                if (!$CSV) {
                    write-host "FATAL: Could not load 'master-uage-list.csv', please ensure it is present in the same directory as the script!"
                    Stop-Transcript
                    exit
                } else {}
                $HorizonPod = Read-Host -Prompt "Enter the name (Case Sensitive) of the Horizon Pod for which to delete all UAG's configured in CSV for the 'PodName' column?"
                $DeleteUAGs = $CSV | Where-Object {$_.PodName -imatch $HorizonPod}
                if ($DeleteUAGs) {
                    write-host "Found" $DeleteUAGs.Count "UAG appliances with configurations to delete"
                    $ConfirmDelete = Read-Host "Are you sure you want to proceed with UAG deletions for Horizon Pod '" $HorizonPod "' (Y)es or (N)o"
                    if ($ConfirmDelete -eq "Y") {
                        $timer = @()
                        $timer = [Diagnostics.Stopwatch]::StartNew()
                        foreach ($DeleteUAG in $DeleteUAGs) {
                            write-host "INFO: UAG VM record for"$DeleteUAG.UAGname "located"
                            if ($DeleteUAG.Skipped -eq 1) {
                                #VM record is set to be disabled so skip this process
                                write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                                continue
                            } else {}
                            $key = Get-Content $DeleteUAG.VCkey
                            $SecurePassword = ($DeleteUAG.vCenterPassword | ConvertTo-SecureString -Key $key)
                            $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                            $VCUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                            Connect-VIServer -Server $DeleteUAG.vCentername -User $DeleteUAG.vCenterUser -Password $VCUnsecurePassword -Force
                            $VMList = @()
                            $VMList = Get-VM
                            $VMList = $VMList | Where-Object {$_.Name -eq $DeleteUAG.UAGname}
                            if ($VMList) {
                                write-host "VM found with that name:"$VMList.Name " and deleting..."
                                if ($VMList.PowerState -eq "PoweredOn") {
                                    write-host "INFO:" $VMList.Name "is powered on, powering off first before deletion"
                                    Stop-VM -VM $VMList.Name -Confirm:$false
                                } else {}
                                write-host "INFO: Deleting" $VM.Name
                                Remove-VM -VM $VMList.Name -DeletePermanently -Confirm:$false
                            } else {
                                write-host "ERROR: VM" $DeleteUAG.UAGname "not found in vSphere inventory"
                                $SecurePassword = @()
                                $VCUnsecurePassword = @()
                                $BSTR = @()
                                $VMList = @()
                                $DeleteVM = @()
                                $KeyFile = @()
                                $Key = @()
                                Disconnect-VIServer -Server * -confirm:$false -Force
                            }
                            $SecurePassword = @()
                            $VCUnsecurePassword = @()
                            $BSTR = @()
                            $VMList = @()
                            $KeyFile = @()
                            $Key = @()
                            Disconnect-VIServer -Server * -confirm:$false -Force
                        }
                        #End For Loop
                        $timer.Stop()
                        Write-Host "Compeleted UAG deletions in: " $timer.Elapsed.Hours ":" $timer.Elapsed.Minutes ":" $timer.Elapsed.Seconds  
                    } elseif ($ConfirmDelete -eq "N") {
                        write-host "INFO: UAG deletion for Horizon Pod aborted by user"
                    } else {
                        write-host "ERROR: Invalid menu selection, please try again"
                    }
                } else {
                    #Could not find any UAG's for the given Horizon Pod   
                    write-host "ERROR: Horizon Pod UAGs not found in master-uag-list.csv and thus cannot be deleted, only can delete VM's for specified Horizon Pod using this script that are configured within the CSV" 
                } #END OF MENU-DELETE-POD
            } elseif ($DeleteMenuAction -eq "3") { #MENU-DELETE-BACK
                $DeleteMode = $false
                #END OF MENU-DELETE-BACK
            } else {
                write-host "ERROR: Invalid selection entered, please try again"    
            } #End of While Loop for Delete Mode
        } #END OF MENU-DELETE 
    } elseif ($MenuAction -eq "3") { #MENU-CREDS
        write-host "INFO: CSV Credential Editing Mode"
        write-host "-----"
        $PasswordChoice = @()
        $PasswordChoice = Read-Host -Prompt "Modify credential(s) for [1] - Single UAG, or [2] - All UAGs in CSV"
        $CSV = Import-Csv -Path ".\master-uag-list.csv"
        if (!$CSV) {
            write-host "FATAL: Unable to load the 'master-uag-list.csv' please make sure it is in the same directory as this script"
            Stop-Transcript
            exit
        } else {}
        if ($PasswordChoice -eq "1") { #MENU-CREDS-SINGLE
            write-host "INFO: Editing Credentials for Single UAG"
            $PasswordVM = @()
            $PasswordVM = Read-Host -Prompt "Name of UAG to modify credential(s) for"
            $PasswordVM = $CSV | Where-Object {$_.UAGname -match $PasswordVM}
            if ($PasswordVM) {
                $PasswordEditing = $true
                while ($PasswordEditing) {
                    $PWType = @()
                    $PWType = Read-Host -Prompt "Edit one at a time: [1] - vCenter Username, [2] - vCenter Password, [3] - UAG Root, [4] - UAG Admin password, [5] - UAG Monitoring password, or [6] - Done"
                    if ($PWType -eq "2") { #MENU-CREDS-SINGLE-VCPASS
                        #Edit the vCenter password
                        write-host "INFO: Edit the vCenter password selected for"$PasswordVM.UAGname
                        $ChangeVCpassword = Read-Host -Prompt "Enter the new vCenter password" | ConvertTo-SecureString -AsPlainText -Force
                        $Key = @()
                        $Key = New-Object Byte[] 32   # You can use 16, 24, or 32 for AES
                        [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
                        $TempFilename = @()
                        $TempFilename = "pw-" + $PasswordVM.UAGname + "-vc-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".key"
                        $Key | out-file $TempFilename
                        $Key = Get-Content $TempFilename
                        $ChangeVCpassword = $ChangeVCpassword | ConvertFrom-SecureString -key $Key
                        <#write-host "New Key File Name:"$TempFilename
                        write-host "Old Key File Name:"$($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname} | Select-Object -ExpandProperty VCkey)
                        write-host "New Password:" $ChangeVCpassword
                        write-host "Old Password:" $($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname} | Select-Object -ExpandProperty vCenterPassword)#>
                        write-host "Modified vCenter password for:" $PasswordVM.UAGname
                        $CSVbackup = @()
                        $CSVbackup = ".\master-uag-list-backup-vcp-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".csv"
                        ($CSV | Export-CSV -Path $CSVbackup -Force -Confirm:$false)
                        ($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname}).VCkey = $TempFilename
                        ($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname}).vCenterPassword = $ChangeVCpassword
                        ($CSV | Export-Csv -Path ".\master-uag-list.csv" -Force -Confirm:$false)
                        #END OF MENU-CREDS-SINGLE-VCPASS
                    } elseif ($PWType -eq "1") { #MENU-CREDS-SINGLE-VCUSER
                        #Edit the vCenter username
                        write-host "INFO: Edit the vCenter username selected for"$PasswordVM.UAGname
                        $ChangeVCuser = Read-Host -Prompt "Enter the new vCenter username"
                        <#write-host "New Username:" $ChangeVCuser
                        write-host "Old Username:" $($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname} | Select-Object -ExpandProperty vCenterUser)#>
                        write-host "Modified vCenter username for:" $PasswordVM.UAGname
                        $CSVbackup = @()
                        $CSVbackup = ".\master-uag-list-backup-vcu-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".csv"
                        ($CSV | Export-CSV -Path $CSVbackup -Force -Confirm:$false)
                        ($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname}).vCenterUser = $ChangeVCuser
                        ($CSV | Export-Csv -Path ".\master-uag-list.csv" -Force -Confirm:$false)
                        #END OF MENU-CREDS-SINGLE-VCUSER
                    } elseif ($PWType -eq "3") { #MENU-CREDS-SINGLE-ROOT
                        #Edit the UAG Root password
                        write-host "INFO: Edit the UAG root password selected for"$PasswordVM.UAGname
                        $ChangeUAGROOTpassword = Read-Host -Prompt "Enter the new UAG root password" | ConvertTo-SecureString -AsPlainText -Force
                        $Key = @()
                        $Key = New-Object Byte[] 32   # You can use 16, 24, or 32 for AES
                        [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
                        $TempFilename = @()
                        $TempFilename = "pw-" + $PasswordVM.UAGname + "-root-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".key"
                        $Key | out-file $TempFilename
                        $Key = Get-Content $TempFilename
                        $ChangeUAGROOTpassword = $ChangeUAGROOTpassword | ConvertFrom-SecureString -key $Key
                        <#write-host "New Key File Name:"$TempFilename
                        write-host "Old Key File Name:"$($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname} | Select-Object -ExpandProperty UAGrootkey)
                        write-host "New Password:" $ChangeUAGROOTpassword
                        write-host "Old Password:" $($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname} | Select-Object -ExpandProperty UAGrootPW)#>
                        write-host "Modified UAG root password for:" $PasswordVM.UAGname
                        $CSVbackup = @()
                        $CSVbackup = ".\master-uag-list-backup-root-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".csv"
                        ($CSV | Export-CSV -Path $CSVbackup -Force -Confirm:$false)
                        ($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname}).UAGrootkey = $TempFilename
                        ($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname}).UAGrootPW = $ChangeUAGROOTpassword
                        ($CSV | Export-Csv -Path ".\master-uag-list.csv" -Force -Confirm:$false)
                        #END OF MENU-CREDS-SINGLE-ROOT
                    } elseif ($PWType -eq "4") { #MENU-CREDS-SINGLE-ADMIN
                        #Edit the UAG Admin password
                        write-host "INFO: Edit the UAG Admin password selected for"$PasswordVM.UAGname
                        $ChangeUAGADMINpassword = Read-Host -Prompt "Enter the new UAG Admin password" | ConvertTo-SecureString -AsPlainText -Force
                        $Key = @()
                        $Key = New-Object Byte[] 32   # You can use 16, 24, or 32 for AES
                        [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
                        $TempFilename = @()
                        $TempFilename = "pw-" + $PasswordVM.UAGname + "-admin-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".key"
                        $Key | out-file $TempFilename
                        $Key = Get-Content $TempFilename
                        $ChangeUAGADMINpassword = $ChangeUAGADMINpassword | ConvertFrom-SecureString -key $Key
                        <#write-host "New Key File Name:"$TempFilename
                        write-host "Old Key File Name:"$($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname} | Select-Object -ExpandProperty UAGadminkey)
                        write-host "New Password:" $ChangeUAGADMINpassword
                        write-host "Old Password:" $($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname} | Select-Object -ExpandProperty UAGadminPW)#>
                        write-host "Modified UAG Admin password for:" $PasswordVM.UAGname
                        $CSVbackup = @()
                        $CSVbackup = ".\master-uag-list-backup-admin-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".csv"
                        ($CSV | Export-CSV -Path $CSVbackup -Force -Confirm:$false)
                        ($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname}).UAGadminkey = $TempFilename
                        ($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname}).UAGadminPW = $ChangeUAGADMINpassword
                        ($CSV | Export-Csv -Path ".\master-uag-list.csv" -Force -Confirm:$false)
                        #END OF MENU-CREDS-SINGLE-ADMIN
                    } elseif ($PWType -eq "5") { #MENU-CREDS-SINGLE-MONITOR
                        #Edit the UAG Monitoring password for single UAG
                        write-host "INFO: Edit the UAG Monitoring password for UAG:" $PasswordVM.UAGname
                        $ChangeUAGMonitoringpassword = Read-Host -Prompt "Enter the new UAG Monitoring password" | ConvertTo-SecureString -AsPlainText -Force
                        $Key = @()
                        $Key = New-Object Byte[] 32   # You can use 16, 24, or 32 for AES
                        [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
                        $TempFilename = @()
                        $TempFilename = "pw-" + $PasswordVM.UAGname + "-monitoring-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".key"
                        $Key | out-file $TempFilename
                        $Key = Get-Content $TempFilename
                        $ChangeUAGMonitoringpassword = $ChangeUAGMonitoringpassword | ConvertFrom-SecureString -key $Key
                        $CSVbackup = @()
                        $CSVbackup = ".\master-uag-list-backup-monitoring-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".csv"
                        ($CSV | Export-CSV -Path $CSVbackup -Force -Confirm:$false)
                        <#write-host "New Key File Name:"$TempFilename
                        write-host "Old Key File Name:"$($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname} | Select-Object -ExpandProperty UAGmonitoringkey)
                        write-host "New Password:" $ChangeUAGMonitoringpassword
                        write-host "Old Password:" $($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname} | Select-Object -ExpandProperty UAGmonitoringPW)#>
                        write-host "Modified UAG Monitoring password for:" $PasswordVM.UAGname
                        ($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname}).UAGmonitoringkey = $TempFilename
                        ($CSV | Where-Object {$_.UAGname -eq $PasswordVM.UAGname}).UAGmonitoringPW = $ChangeUAGMonitoringpassword
                        ($CSV | Export-Csv -Path ".\master-uag-list.csv" -Force -Confirm:$false)
                        #END OF MENU-CREDS-SINGLE-MONITOR
                    } elseif ($PWType -eq "6") { #MENU-CREDS-SINGLE-DONE
                        $PasswordEditing = $false
                        #END OF MENU-CREDS-SINGLE-DONE
                    } else {
                        write-host "ERROR: Invalid selection entered, please try again"
                    }
                #End of while loop
                }   
            } else {
                write-host "ERROR: VM" $PasswordVM "not found in 'master-uag-list.csv'"
            } #END OF MENU-CREDS-SINGLE
        } elseif ($PasswordChoice -eq "2") { #MENU-CREDS-POD
             write-host "INFO: Editing Credentials for All UAGs in CSV"
            #This is for editing all VC, root, admin, or role_monitoring user passwords for all UAG's in an entire CSV list file
            $PasswordEditing = $true
            while ($PasswordEditing) {
                $PWType = @()
                $PWType = Read-Host -Prompt "Edit one at a time: [1] - vCenter Username, [2] - vCenter Password, [3] - UAG Root password, [4] - UAG Admin password, [5] - UAG Monitoring password, or [6] - Done"
                if ($PWType -eq "2") { #MENU-CREDS-POD-VCPASS
                    #Edit the vCenter password for all UAGs
                    write-host "INFO: Edit the vCenter password for all UAG appliances"
                    $ChangeVCpassword = Read-Host -Prompt "Enter the new vCenter password for all UAGs" | ConvertTo-SecureString -AsPlainText -Force
                    $Key = @()
                    $Key = New-Object Byte[] 32   # You can use 16, 24, or 32 for AES
                    [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
                    $TempFilename = @()
                    $TempFilename = "pw-vc-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".key"
                    $Key | out-file $TempFilename
                    $Key = Get-Content $TempFilename
                    $ChangeVCpassword = $ChangeVCpassword | ConvertFrom-SecureString -key $Key
                    $CSVbackup = @()
                    $CSVbackup = ".\master-uag-list-backup-allvcp-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".csv"
                    ($CSV | Export-CSV -Path $CSVbackup -Force -Confirm:$false)
                    foreach ($UAG in $CSV) {
                        <#write-host "New Key File Name:"$TempFilename
                        write-host "Old Key File Name:"$UAG.VCkey
                        write-host "New Password:" $ChangeVCpassword
                        write-host "Old Password:" $UAG.vCenterPassword#>
                        write-host "Modified vCenter password for:" $UAG.UAGname
                        $UAG.VCkey = $TempFilename
                        $UAG.vCenterPassword = $ChangeVCpassword
                    }
                    ($CSV | Export-Csv -Path ".\master-uag-list.csv" -Force -Confirm:$false)
                    #END OF MENU-CREDS-POD-VCPASS
                } elseif ($PWType -eq "1") { #MENU-CREDS-POD-VCUSER
                    #Edit the vCenter username for all UAGs
                    write-host "INFO: Edit the vCenter username for all UAGs appliances"
                    $ChangeVCuser = Read-Host -Prompt "Enter the new vCenter username for all UAGs"
                    $CSVbackup = @()
                    $CSVbackup = ".\master-uag-list-backup-allvcu-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".csv"
                    ($CSV | Export-CSV -Path $CSVbackup -Force -Confirm:$false)
                    foreach ($UAG in $CSV) {
                        write-host "Modifying vCenter username for UAG:" $UAG.UAGname
                        <#write-host "New Username:" $ChangeVCuser
                        write-host "Old Username:" $UAG.vCenterUser#>
                        write-host "Modified vCenter username for:" $UAG.UAGname
                        $UAG.vCenterUser = $ChangeVCuser
                    } #End of foreach loop
                    ($CSV | Export-Csv -Path ".\master-uag-list.csv" -Force -Confirm:$false)
                    #END OF MENU-CREDS-POD-VCUSER
                } elseif ($PWType -eq "3") { #MENU-CREDS-POD-ROOT
                    #Edit the UAG Root password for all UAGs
                    write-host "INFO: Edit the UAG root password for all UAG appliances"
                    $ChangeUAGROOTpassword = Read-Host -Prompt "Enter the new UAG root password for all UAGs" | ConvertTo-SecureString -AsPlainText -Force
                    $Key = @()
                    $Key = New-Object Byte[] 32   # You can use 16, 24, or 32 for AES
                    [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
                    $TempFilename = @()
                    $TempFilename = "pw-root-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".key"
                    $Key | out-file $TempFilename
                    $Key = Get-Content $TempFilename
                    $ChangeUAGROOTpassword = $ChangeUAGROOTpassword | ConvertFrom-SecureString -key $Key
                    $CSVbackup = @()
                    $CSVbackup = ".\master-uag-list-backup-allroot" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".csv"
                    ($CSV | Export-CSV -Path $CSVbackup -Force -Confirm:$false)
                    foreach ($UAG in $CSV) {
                        <#write-host "New Key File Name:"$TempFilename
                        write-host "Old Key File Name:"$UAG.UAGrootkey
                        write-host "New Password:" $ChangeUAGROOTpassword
                        write-host "Old Password:" $UAG.UAGrootPW#>
                        write-host "Modified UAG root password for:" $UAG.UAGname
                        $UAG.UAGrootkey = $TempFilename
                        $UAG.UAGrootPW = $ChangeUAGROOTpassword
                    }
                    ($CSV | Export-Csv -Path ".\master-uag-list.csv" -Force -Confirm:$false)
                    #END OF MENU-CREDS-POD-ROOT
                } elseif ($PWType -eq "4") { #MENU-CREDS-POD-ADMIN
                    #Edit the UAG Admin password for all UAGs
                    write-host "INFO: Edit the UAG Admin password for all UAG appliances"
                    $ChangeUAGADMINpassword = Read-Host -Prompt "Enter the new UAG Admin password for all UAGs" | ConvertTo-SecureString -AsPlainText -Force
                    $Key = @()
                    $Key = New-Object Byte[] 32   # You can use 16, 24, or 32 for AES
                    [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
                    $TempFilename = @()
                    $TempFilename = "pw-admin-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".key"
                    $Key | out-file $TempFilename
                    $Key = Get-Content $TempFilename
                    $ChangeUAGADMINpassword = $ChangeUAGADMINpassword | ConvertFrom-SecureString -key $Key
                    $CSVbackup = @()
                    $CSVbackup = ".\master-uag-list-backup-alladmin-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".csv"
                    ($CSV | Export-CSV -Path $CSVbackup -Force -Confirm:$false)
                    foreach ($UAG in $CSV) {
                        <#write-host "New Key File Name:"$TempFilename
                        write-host "Old Key File Name:"$UAG.UAGadminkey
                        write-host "New Password:" $ChangeUAGADMINpassword
                        write-host "Old Password:" $UAG.UAGadminPW#>
                        write-host "Modified UAG Admin password for:" $UAG.UAGname
                        $UAG.UAGadminkey = $TempFilename
                        $UAG.UAGadminPW = $ChangeUAGADMINpassword
                    }
                    ($CSV | Export-Csv -Path ".\master-uag-list.csv" -Force -Confirm:$false)
                    #END OF MENU-CREDS-POD-ADMIN
                } elseif ($PWType -eq "5") { #MENU-CREDS-POD-MONITOR
                    #Edit the UAG Monitoring password for all UAGs
                    write-host "INFO: Edit the UAG Monitoring password for all UAG appliances"
                    $ChangeUAGMonitoringpassword = Read-Host -Prompt "Enter the new UAG Monitoring password for all UAGs" | ConvertTo-SecureString -AsPlainText -Force
                    $Key = @()
                    $Key = New-Object Byte[] 32   # You can use 16, 24, or 32 for AES
                    [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($Key)
                    $TempFilename = @()
                    $TempFilename = "pw-monitoring-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".key"
                    $Key | out-file $TempFilename
                    $Key = Get-Content $TempFilename
                    $ChangeUAGMonitoringpassword = $ChangeUAGMonitoringpassword | ConvertFrom-SecureString -key $Key
                    $CSVbackup = @()
                    $CSVbackup = ".\master-uag-list-backup-allmonitoring-" + $(Get-Date -Format "MM-dd-yyyy-HH-mm-ss") + ".csv"
                    ($CSV | Export-CSV -Path $CSVbackup -Force -Confirm:$false)
                    foreach ($UAG in $CSV) {
                        <#write-host "New Key File Name:"$TempFilename
                        write-host "Old Key File Name:"$UAG.UAGmonitoringkey
                        write-host "New Password:" $ChangeUAGMonitoringpassword
                        write-host "Old Password:" $UAG.UAGmonitoringPW#>
                        write-host "Modified UAG Monitoring password for:" $UAG.UAGname
                        $UAG.UAGmonitoringkey = $TempFilename
                        $UAG.UAGmonitoringPW = $ChangeUAGMonitoringpassword
                    }
                    ($CSV | Export-Csv -Path ".\master-uag-list.csv" -Force -Confirm:$false)
                    #END OF MENU-CREDS-POD-MONITOR
                } elseif ($PWType -eq "6") { #MENU-CREDS-POD-DONE
                    $PasswordEditing = $false
                    #END OF MENU-CREDS-POD-DONE
                } else {
                    write-host "ERROR: Invalid selection entered, please try again"
                }
            #End of while loop
            } #END OF MENU-CREDS-POD
        } else {
            write-host "ERROR: Invalid selection entered, please try again"
        }
        #Cleanup
        $PasswordVM = @()
        $CSV = @()
        $PasswordEditing = @()
        $PWType = @()
        $Key = @()
        $ChangeVCpassword = @()
        $ChangeUAGROOTpassword = @()
        $ChangeUAGADMINpassword = @()
        $TempFilename = @()
        $UAG=@()
        $CSVbackup = @()
        #END OF MENU-CREDS
    } elseif ($MenuAction -eq "4") { #MENU-DAY2OPS
        #Day2 Operations UAG appliances Mode
        $UpdateMode = $true
        $ExistingRootPW = @()
        write-host "INFO: UAG Day 2 Operations mode"
        write-host "-----"
        while ($UpdateMode) {
            #Nest all sub-menus within a while loop
            $UpdateOption = Read-Host "[1] - Update Root passwords, [2] - Update Admin passwords, [3] - Update Monitoring passwords, [4] - Quiesce mode, [5] - Certificates, or [6] - Done"
            if ($UpdateOption -eq "1") { #MENU-DAY2OPS-ROOT
                #Update root passwords selection
                $ExistingRootPW = Read-Host "Enter existing root password for UAG appliance(s)"
                $CSV = Import-Csv -Path ".\master-uag-list.csv"
                if (!$CSV) {
                    write-host "FATAL: Could not load 'master-uage-list.csv', please ensure it is present in the same directory as the script!"
                    Stop-Transcript
                    exit
                } else {}
                $HorizonPod = Read-Host -Prompt "Enter the name (Case Sensitive) of the Horizon Pod for which to update all UAG's configured in CSV for the 'PodName' column?"
                $UpdateRootPWUAGs = $CSV | Where-Object {$_.PodName -imatch $HorizonPod}
                if ($UpdateRootPWUAGs) {
                    write-host "Found" $UpdateRootPWUAGs.Count "UAG appliances to update root passwords with"
                    $timer = @()
                    $timer = [Diagnostics.Stopwatch]::StartNew()
                    foreach ($UpdateRoot in $UpdateRootPWUAGs) {
                        write-host "INFO: UAG VM record for"$UpdateRoot.UAGname "located"
                        if ($UpdateRoot.Skipped -eq 1) {
                            #VM record is set to be disabled so skip this process
                            write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                            continue
                        } else {}
                        $key = Get-Content $UpdateRoot.UAGrootkey
                        $SecurePassword = ($UpdateRoot.UAGrootPW | ConvertTo-SecureString -Key $key)
                        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                        $RootUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                        $UserName = "root"
                        $pass = ConvertTo-SecureString $ExistingRootPW -AsPlainText -Force
                        $mycreds =  New-Object -TypeName PSCredential -ArgumentList $UserName, $pass
                        $sshSession = New-SSHSession -ComputerName $UpdateRoot.ip0 -Credential $mycreds -AcceptKey -Force
$Command = @"
echo "root:$($RootUnsecurePassword)" | chpasswd
"@
                        if ((Invoke-SSHCommand -Command $Command -SessionId "0").ExitStatus -eq 0) {
                            write-host "INFO: Successfully updated root password on UAG" $UpdateRoot.UAGname
                        } else {
                            write-host "WARNING: Was not able to successfully update root password on UAG!"
                        }
                        Remove-SSHSession -SSHsession $sshSession
                        $key = @()
                        $SecurePassword = @()
                        $BSTR = @()
                        $RootUnsecurePassword = @()
                        $Command = @()
                        $sshSession = @()
                        $ExistingRootPW = @()
                        $mycreds = @()
                        $UserName = @()
                        $pass = @()
                    } #End of foreach loop
                } else {
                    write-host "ERROR: Could not find any UAG's for Horizon Pod " $HorizonPod "in 'master-uag-list.csv'"
                }
                #Clean Up
                $ExistingRootPW = @()
                $key = @()
                $SecurePassword = @()
                $BSTR = @()
                $RootUnsecurePassword = @()
                $Command = @()
                $sshSession = @()
                $mycreds = @()
                $UserName = @()
                $pass = @()
                $timer.Stop()
                Write-Host "Compeleted UAG Root password updates in: " $timer.Elapsed.Hours ":" $timer.Elapsed.Minutes ":" $timer.Elapsed.Seconds 
                #END OF MENU-DAY2OPS-ROOT 
            } elseif ($UpdateOption -eq "2") { #MENU-DAY2OPS-ADMIN
                #Update Admin Passwords selection
                $ExistingAdminPW = Read-Host "Enter existing admin password for UAG appliance(s)"
                $CSV = Import-Csv -Path ".\master-uag-list.csv"
                if (!$CSV) {
                    write-host "FATAL: Could not load 'master-uage-list.csv', please ensure it is present in the same directory as the script!"
                    Stop-Transcript
                    exit
                } else {}
                $HorizonPod = Read-Host -Prompt "Enter the name (Case Sensitive) of the Horizon Pod for which to update all UAG's configured in CSV for the 'PodName' column?"
                $UpdateAdminPWUAGs = $CSV | Where-Object {$_.PodName -imatch $HorizonPod}
                if ($UpdateAdminPWUAGs) {
                    write-host "Found" $UpdateAdminPWUAGs.Count "UAG appliances to update admin passwords with"
                    $timer = @()
                    $timer = [Diagnostics.Stopwatch]::StartNew()
                    #Had to setup SSL ignore for invoke-rest method as self-signed certs in lab
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
                    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
                    foreach ($UpdateAdmin in $UpdateAdminPWUAGs) {
                        $key = @()
                        $SecurePassword = @()
                        $BSTR = @()
                        $AdminUnsecurePassword = @()
                        $UserName = @()
                        $pass = @()
                        $ChangeAdminPWurl = @()
                        $changePasswordJSON = @()
                        $adminInfo = @()
                        $adminUserId = @()
                        write-host "INFO: UAG VM record for"$UpdateAdmin.UAGname "located"
                        if ($UpdateAdmin.Skipped -eq 1) {
                            #VM record is set to be disabled so skip this process
                            write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                            continue
                        } else {}
                        $key = Get-Content $UpdateAdmin.UAGadminkey
                        if (!$key) {
                            write-host "FATAL: Could not load" $UpdateAdmin.UAGadminkey ", please ensure it is present in the same directory as the script!"
                            Stop-Transcript
                            exit
                        } else {}
                        $SecurePassword = ($UpdateAdmin.UAGadminPW | ConvertTo-SecureString -Key $key)
                        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                        $AdminUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                        $UserName = "admin"
                        $pass = ConvertTo-SecureString $ExistingAdminPW -AsPlainText -Force
                        $mycreds =  New-Object -TypeName PSCredential -ArgumentList $UserName, $pass
                        $ChangeAdminPWurl = "https://" + $UpdateAdmin.ip0 + ":9443/rest/v1/config/adminusers/change-password"
                        #Get the existing admin userId from REST-API
                        $GetAdminUrl = "https://" + $UpdateAdmin.ip0 + ":9443/rest/v1/config/adminusers"
                        #Try to run the invoke-rest method to get the admin account details
                        try {
                            $jsonOutput = Invoke-RestMethod -Uri $GetAdminUrl -Method Get -ContentType "application/json" -Credential $mycreds
                            $adminInfo = $jsonOutput | Where-Object {$_.adminUsersList.name -imatch "admin" -and $_.adminUsersList.roles -match "ROLE_ADMIN"}
                            if ($adminInfo) {
                            } else {
                                write-host "ERROR: Unable to pull infomration on admin account from Rest API"
                                continue
                            }
                        } catch {
                            Write-Host "Encountered exception running Admin User Change Password Method:" $Error[0].Exception.Message -ForegroundColor Red
                            continue
                        }
                        #Build the Change password JSON
                        $adminUserId = $adminInfo[0].adminUsersList.userId 
                        $changePasswordJSON = @"
{
"userId":"$adminUserId",
"userName":"admin",
"oldPassword":"$ExistingAdminPW",
"newPassword":"$AdminUnsecurePassword"
}
"@
                        #Try to run the invoke-rest method to change the admin account password
                        try {
                            $jsonOutput = Invoke-RestMethod -Uri $ChangeAdminPWurl -Method Post -ContentType "application/json" -Body $changePasswordJSON -Credential $mycreds
                            write-host "Updated Admin password via Rest API for UAG:" $UpdateAdmin.UAGname
                            #Check if OVA version 3.9.1 is being used for this UAG as if so, it will need to have itself rebooted due to instability with using REST API after being used
                            if ($UpdateAdmin.source -imatch "3.9.1") {
                                write-host "Sleeping 5 seconds, and rebooting UAG"
                                sleep -Seconds 5
                                <#write-host "INFO: Rebooting UAG via SSH as root"
                                $key = Get-Content $UpdateAdmin.UAGrootkey
                                if (!$key) {
                                    write-host "FATAL: Could not load" $UpdateAdmin.UAGrootkey ", please ensure it is present in the same directory as the script!"
                                    write-host "RECOMMEND: Manually reboot the UAG appliance as the Admin password has been reset and appliance needs to be rebooted to get admin service back"
                                    Stop-Transcript
                                    exit
                                } else {}
                                $SecurePassword = ($UpdateAdmin.UAGrootPW | ConvertTo-SecureString -Key $key)
                                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                                $RootUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                                $UserName = "root"
                                $RootCreds =  New-Object -TypeName PSCredential -ArgumentList $UserName, $SecurePassword
                                $sshSession = New-SSHSession -ComputerName $UpdateAdmin.ip0 -Credential $RootCreds -AcceptKey -Force
$Command = @"
reboot&
"@
                                if ((Invoke-SSHCommand -Command $Command -SessionId "0" -TimeOut 4).ExitStatus -eq 0) {
                                    write-host "INFO: Successfully sent reboot UAG command" $UpdateAdmin.UAGname
                                } else {
                                    write-host "WARNING: Reboot command reurned non-zero status but this may be safely ignored!"
                                }
                                Remove-SSHSession -SSHsession $sshSession#>
                                write-host "INFO: Rebooting UAG via vSphere"
                                $key = Get-Content $UpdateAdmin.VCkey
                                $SecurePassword = ($UpdateAdmin.vCenterPassword | ConvertTo-SecureString -Key $key)
                                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                                $VCUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                                Connect-VIServer -Server $UpdateAdmin.vCentername -User $UpdateAdmin.vCenterUser -Password $VCUnsecurePassword -Force
                                $VMList = @()
                                $VMList = Get-VM
                                $VMList = $VMList | Where-Object {$_.Name -eq $UpdateAdmin.UAGname}
                                if ($VMList) {
                                    write-host "INFO: Rebooting via Gust OS:" $VMList.Name
                                    Restart-VMGuest -VM $VMList.Name -Confirm:$false
                                } else {
                                    write-host "ERROR: VM" $UpdateAdmin.UAGname "not found in vSphere inventory"
                                    $SecurePassword = @()
                                    $VCUnsecurePassword = @()
                                    $BSTR = @()
                                    $VMList = @()
                                    $DeleteVM = @()
                                    $KeyFile = @()
                                    $Key = @()
                                    Disconnect-VIServer -Server * -confirm:$false -Force
                                }
                                $SecurePassword = @()
                                $VCUnsecurePassword = @()
                                $BSTR = @()
                                $VMList = @()
                                $KeyFile = @()
                                $Key = @()
                                Disconnect-VIServer -Server * -confirm:$false -Force
                            } else {}
                        } catch {
                            Write-Host "Encountered exception running Admin User Change Password Method:" $Error[0].Exception.Message -ForegroundColor Red
                            continue
                        }
                    } #end of foreach loop
                } else {
                    #Could not find any records for UAGs with that Horizon Pod name supplied
                    write-host "ERROR: Could not find any UAG's for Horizon Pod " $HorizonPod "in 'master-uag-list.csv'"
                }
                $timer.Stop()
                Write-Host "Compeleted UAG Admin password updates in: " $timer.Elapsed.Hours ":" $timer.Elapsed.Minutes ":" $timer.Elapsed.Seconds
                #Clean Up
                $key = @()
                $SecurePassword = @()
                $BSTR = @()
                $AdminUnsecurePassword = @()
                $UserName = @()
                $pass = @()
                $ChangeAdminPWurl = @()
                $changePasswordJSON = @()
                $adminInfo = @()
                $adminUserId = @()
                #END OF MENU-DAY2OPS-ADMIN
            } elseif ($UpdateOption -eq "3") { #MENU-DAY2OPS-MON
                #Update Monitoring Passwords selection
                $ExistingMonitoringPW = Read-Host "Enter existing monitoring password for UAG appliance(s)"
                $CSV = Import-Csv -Path ".\master-uag-list.csv"
                if (!$CSV) {
                    write-host "FATAL: Could not load 'master-uage-list.csv', please ensure it is present in the same directory as the script!"
                    Stop-Transcript
                    exit
                } else {}
                $HorizonPod = Read-Host -Prompt "Enter the name (Case Sensitive) of the Horizon Pod for which to update all UAG's configured in CSV for the 'PodName' column?"
                $UpdateMonitoringPWUAGs = $CSV | Where-Object {$_.PodName -imatch $HorizonPod}
                if ($UpdateMonitoringPWUAGs) {
                    write-host "Found" $UpdateMonitoringPWUAGs.Count "UAG appliances to update admin passwords with"
                    $timer = @()
                    $timer = [Diagnostics.Stopwatch]::StartNew()
                    #Had to setup SSL ignore for invoke-rest method as self-signed certs in lab
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
                    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
                    foreach ($UpdateMonitoring in $UpdateMonitoringPWUAGs) {
                        $key = @()
                        $SecurePassword = @()
                        $BSTR = @()
                        $MonitoringUnsecurePassword = @()
                        $UserName = @()
                        $pass = @()
                        $ChangeMonitoringPWurl = @()
                        $changePasswordJSON = @()
                        $MonitoringInfo = @()
                        $MonitoringUserId = @()
                        write-host "INFO: UAG VM record for"$UpdateMonitoring.UAGname "located"
                        if ($UpdateMonitoring.Skipped -eq 1) {
                            #VM record is set to be disabled so skip this process
                            write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                            continue
                        } else {}
                        $key = Get-Content $UpdateMonitoring.UAGmonitoringkey
                        if (!$key) {
                            write-host "FATAL: Could not load" $UpdateMonitoring.UAGmonitoringkey ", please ensure it is present in the same directory as the script!"
                            Stop-Transcript
                            exit
                        } else {}
                        $SecurePassword = ($UpdateMonitoring.UAGmonitoringPW | ConvertTo-SecureString -Key $key)
                        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                        $MonitoringUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                        $UserName = $UpdateMonitoring.UAGmonitoringUsername
                        $pass = ConvertTo-SecureString $ExistingMonitoringPW -AsPlainText -Force
                        $mycreds =  New-Object -TypeName PSCredential -ArgumentList $UserName, $pass
                        $ChangeMonitoringPWurl = "https://" + $UpdateMonitoring.ip0 + ":9443/rest/v1/config/adminusers/change-password"
                        #Get the existing admin userId from REST-API
                        $GetMonitoringUrl = "https://" + $UpdateMonitoring.ip0 + ":9443/rest/v1/config/adminusers"
                        #Try to run the invoke-rest method to get the admin account details
                        try {
                            $jsonOutput = Invoke-RestMethod -Uri $GetMonitoringUrl -Method Get -ContentType "application/json" -Credential $mycreds
                            $MonitoringInfo = $jsonOutput | Where-Object {$_.adminUsersList.name -imatch $UserName -and $_.adminUsersList.roles -match "ROLE_MONITORING"}
                            if ($MonitoringInfo) {
                            } else {
                                write-host "ERROR: Unable to pull infomration on admin account from Rest API"
                                continue
                            }
                        } catch {
                            Write-Host "Encountered exception running Admin User Change Password Method:" $Error[0].Exception.Message -ForegroundColor Red
                            continue
                        }
                        #Build the Change password JSON
                        $MonitoringUserId = $MonitoringInfo[0].adminUsersList.userId 
                        $changePasswordJSON = @"
{
"userId":"$MonitoringUserId",
"userName":"$UserName",
"oldPassword":"$ExistingMonitoringPW",
"newPassword":"$MonitoringUnsecurePassword"
}
"@
                        #Try to run the invoke-rest method to change the admin account password
                        try {
                            $jsonOutput = Invoke-RestMethod -Uri $ChangeMonitoringPWurl -Method Post -ContentType "application/json" -Body $changePasswordJSON -Credential $mycreds
                            write-host "Updated Monitoring password via Rest API for UAG:" $UpdateMonitoring.UAGname
                            #Check if OVA version 3.9.1 is being used for this UAG as if so, it will need to have itself rebooted due to instability with using REST API after being used
                            if ($UpdateMonitoring.source -imatch "3.9.1") {
                                write-host "Sleeping 5 seconds, and rebooting UAG"
                                sleep -Seconds 5
                                <#$key = Get-Content $UpdateMonitoring.UAGrootkey
                                if (!$key) {
                                    write-host "FATAL: Could not load" $UpdateMonitoring.UAGrootkey ", please ensure it is present in the same directory as the script!"
                                    write-host "RECOMMEND: Manually reboot the UAG appliance as the Admin password has been reset and appliance needs to be rebooted to get admin service back"
                                    Stop-Transcript
                                    exit
                                } else {}
                                $SecurePassword = ($UpdateMonitoring.UAGrootPW | ConvertTo-SecureString -Key $key)
                                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                                $RootUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                                $UserName = "root"
                                $RootCreds =  New-Object -TypeName PSCredential -ArgumentList $UserName, $SecurePassword
                                $sshSession = New-SSHSession -ComputerName $UpdateMonitoring.ip0 -Credential $RootCreds -AcceptKey -Force
$Command = @"
reboot&
"@
                                if ((Invoke-SSHCommand -Command $Command -SessionId "0" -TimeOut 4).ExitStatus -eq 0) {
                                    write-host "INFO: Successfully sent reboot UAG command" $UpdateMonitoring.UAGname
                                } else {
                                    write-host "WARNING: Reboot command reurned non-zero status but this may be safely ignored!"
                                }
                                Remove-SSHSession -SSHsession $sshSession#>
                                $key = Get-Content $UpdateMonitoring.VCkey
                                $SecurePassword = ($UpdateMonitoring.vCenterPassword | ConvertTo-SecureString -Key $key)
                                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                                $VCUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                                Connect-VIServer -Server $UpdateMonitoring.vCentername -User $UpdateMonitoring.vCenterUser -Password $VCUnsecurePassword -Force
                                $VMList = @()
                                $VMList = Get-VM
                                $VMList = $VMList | Where-Object {$_.Name -eq $UpdateMonitoring.UAGname}
                                if ($VMList) {
                                    write-host "INFO: Rebooting via Gust OS:" $VMList.Name
                                    Restart-VMGuest -VM $VMList.Name -Confirm:$false
                                } else {
                                    write-host "ERROR: VM" $UpdateMonitoring.UAGname "not found in vSphere inventory"
                                    $SecurePassword = @()
                                    $VCUnsecurePassword = @()
                                    $BSTR = @()
                                    $VMList = @()
                                    $DeleteVM = @()
                                    $KeyFile = @()
                                    $Key = @()
                                    Disconnect-VIServer -Server * -confirm:$false -Force
                                }
                                $SecurePassword = @()
                                $VCUnsecurePassword = @()
                                $BSTR = @()
                                $VMList = @()
                                $KeyFile = @()
                                $Key = @()
                                Disconnect-VIServer -Server * -confirm:$false -Force
                            } else {}
                        } catch {
                            Write-Host "Encountered exception running Admin User Change Password Method:" $Error[0].Exception.Message -ForegroundColor Red
                            continue
                        }
                    } #end of foreach loop
                } else {
                    #Could not find any records for UAGs with that Horizon Pod name supplied
                    write-host "ERROR: Could not find any UAG's for Horizon Pod " $HorizonPod "in 'master-uag-list.csv'"
                }
                $timer.Stop()
                Write-Host "Compeleted UAG Monitoring password updates in: " $timer.Elapsed.Hours ":" $timer.Elapsed.Minutes ":" $timer.Elapsed.Seconds
                #Clean Up
                $key = @()
                $SecurePassword = @()
                $BSTR = @()
                $MonitoringUnsecurePassword = @()
                $UserName = @()
                $pass = @()
                $ChangeMonitoringPWurl = @()
                $changePasswordJSON = @()
                $MonitoringInfo = @()
                $MonitoringUserId = @()
                #END OF MENU-DAY2OPS-MON
            } elseif ($UpdateOption -eq "4") { #MENU-DAY2OPS-QUIESCE
                #Update Quiesce mode selection
                $HorizonPod = Read-Host -Prompt "Enter the name (Case Sensitive) of the Horizon Pod for which to update all UAG's configured in CSV for the 'PodName' column?"
                $CSV = Import-Csv -Path ".\master-uag-list.csv"
                if (!$CSV) {
                    write-host "FATAL: Could not load 'master-uage-list.csv', please ensure it is present in the same directory as the script!"
                    Stop-Transcript
                    exit
                } else {}
                $QuiesceModeUAGs = $CSV | Where-Object {$_.PodName -imatch $HorizonPod}
                if ($QuiesceModeUAGs) { 
                    $QuiesceMode = $true
                    #Embed the user in a while loop to allow for modifications at the Horizon Pod level for day 2 ops
                    while ($QuiesceMode) { #QUIESCE MODE MENU LOOP
                        $QuiesceOption = Read-Host "[1] - Enable Quiesce, [2] - Disable Quiesce, [3] - Get status, or [4] - Done for ($HorizonPod)"
                        if ($QuiesceOption -eq "3") { #MENU-DAY2OPS-QUIESCE-STATUS
                            #Get status selected
                            #Had to setup SSL ignore for invoke-rest method as self-signed certs in lab
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
                            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
                            foreach ($QuiesceVM in $QuiesceModeUAGs) {
                                $key = @()
                                $SecurePassword = @()
                                $BSTR = @()
                                $AdminUnsecurePassword = @()
                                $UserName = @()
                                $pass = @()
                                $GetQuiesceStatusUrl = @()
                                $QuiesceInfo = @()
                                if ($QuiesceVM.Skipped -eq 1) {
                                    #VM record is set to be disabled so skip this process
                                    write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                                    continue
                                } else {}
                                $key = Get-Content $QuiesceVM.UAGadminkey
                                if (!$key) {
                                    write-host "FATAL: Could not load" $QuiesceVM.UAGadminkey ", please ensure it is present in the same directory as the script!"
                                    Stop-Transcript
                                    exit
                                } else {}
                                $SecurePassword = ($QuiesceVM.UAGadminPW | ConvertTo-SecureString -Key $key)
                                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                                $AdminUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                                $UserName = "admin"
                                $pass = ConvertTo-SecureString $AdminUnsecurePassword -AsPlainText -Force
                                $mycreds =  New-Object -TypeName PSCredential -ArgumentList $UserName, $pass
                                $GetQuiesceStatusUrl = "https://" + $QuiesceVM.ip0 + ":9443/rest/v1/config/system"
                                #Try to run the invoke-rest method to get the Quiesce mode details
                                try {
                                    $jsonOutput = Invoke-RestMethod -Uri $GetQuiesceStatusUrl -Method Get -ContentType "application/json" -Credential $mycreds
                                    write-host "UAG:" $QuiesceVM.UAGname "Quiesce Mode Setting:" $jsonOutput.quiesceMode
                                } catch {
                                    Write-Host "Encountered exception running Get Quiesce Mode Method:" $Error[0].Exception.Message -ForegroundColor Red
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $AdminUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $GetQuiesceStatusUrl = @()
                                    continue
                                }
                                $key = @()
                                $SecurePassword = @()
                                $BSTR = @()
                                $AdminUnsecurePassword = @()
                                $UserName = @()
                                $pass = @()
                                $GetQuiesceStatusUrl = @()
                            }#End of foreach loop
                            #END OF MENU-DAY2OPS-QUIESCE-STATUS
                        } elseif ($QuiesceOption -eq "1") { #MENU-DAY2OPS-QUIESCE-ENABLE
                            #Turn on Quiesce Mode selected
                            #Had to setup SSL ignore for invoke-rest method as self-signed certs in lab
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
                            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
                            foreach ($QuiesceVM in $QuiesceModeUAGs) {
                                $key = @()
                                $SecurePassword = @()
                                $BSTR = @()
                                $AdminUnsecurePassword = @()
                                $UserName = @()
                                $pass = @()
                                $SetQuiesceStatusUrl = @()
                                $SetQuiesceModeJSON = @()
                                if ($QuiesceVM.Skipped -eq 1) {
                                    #VM record is set to be disabled so skip this process
                                    write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                                    continue
                                } else {}
                                $key = Get-Content $QuiesceVM.UAGadminkey
                                if (!$key) {
                                    write-host "FATAL: Could not load" $QuiesceVM.UAGadminkey ", please ensure it is present in the same directory as the script!"
                                    Stop-Transcript
                                    exit
                                } else {}
                                $SecurePassword = ($QuiesceVM.UAGadminPW | ConvertTo-SecureString -Key $key)
                                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                                $AdminUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                                $UserName = "admin"
                                $pass = ConvertTo-SecureString $AdminUnsecurePassword -AsPlainText -Force
                                $mycreds =  New-Object -TypeName PSCredential -ArgumentList $UserName, $pass
                                $SetQuiesceStatusUrl = "https://" + $QuiesceVM.ip0 + ":9443/rest/v1/config/system"
                                #Try to run the invoke-rest method to get the Quiesce mode details
                                try {
                                    $SetQuiesceModeJSON = Invoke-RestMethod -Uri $SetQuiesceStatusUrl -Method Get -ContentType "application/json" -Credential $mycreds
                                    $SetQuiesceModeJSON.quiesceMode = "True"
                                    $SetQuiesceModeJSON.adminPassword = $AdminUnsecurePassword
                                } catch {
                                    Write-Host "Encountered exception running Get Settings Method:" $Error[0].Exception.Message -ForegroundColor Red
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $AdminUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $SetQuiesceStatusUrl = @()
                                    $SetQuiesceModeJSON = @()
                                    continue
                                }
                                $SetQuiesceModeJSON = $SetQuiesceModeJSON | ConvertTo-Json
                                try {
                                    $jsonOutput = Invoke-RestMethod -Uri $SetQuiesceStatusUrl -Method Put -ContentType "application/json" -Body $SetQuiesceModeJSON -Credential $mycreds
                                    write-host "Updated UAG:" $QuiesceVM.UAGname "Quiesce Mode Setting to 'true'"
                                } catch {
                                    Write-Host "Encountered exception running Set Quiesce Mode Method:" $Error[0].Exception.Message -ForegroundColor Red
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $AdminUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $SetQuiesceStatusUrl = @()
                                    $SetQuiesceModeJSON = @()
                                    continue
                                }
                                $key = @()
                                $SecurePassword = @()
                                $BSTR = @()
                                $AdminUnsecurePassword = @()
                                $UserName = @()
                                $pass = @()
                                $SetQuiesceStatusUrl = @()
                                $SetQuiesceModeJSON = @()
                            }#end foreach loop
                            #END OF MENU-DAY2OPS-QUIESCE-ENABLE
                        } elseif ($QuiesceOption -eq "2") { #MENU-DAY2OPS-QUIESCE-DISABLE
                            #Turn off Quiesce Mode selected
                            #Had to setup SSL ignore for invoke-rest method as self-signed certs in lab
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
                            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
                            foreach ($QuiesceVM in $QuiesceModeUAGs) {
                                $key = @()
                                $SecurePassword = @()
                                $BSTR = @()
                                $AdminUnsecurePassword = @()
                                $UserName = @()
                                $pass = @()
                                $SetQuiesceStatusUrl = @()
                                $SetQuiesceModeJSON = @()
                                if ($QuiesceVM.Skipped -eq 1) {
                                    #VM record is set to be disabled so skip this process
                                    write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                                    continue
                                } else {}
                                $key = Get-Content $QuiesceVM.UAGadminkey
                                if (!$key) {
                                    write-host "FATAL: Could not load" $QuiesceVM.UAGadminkey ", please ensure it is present in the same directory as the script!"
                                    Stop-Transcript
                                    exit
                                } else {}
                                $SecurePassword = ($QuiesceVM.UAGadminPW | ConvertTo-SecureString -Key $key)
                                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                                $AdminUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                                $UserName = "admin"
                                $pass = ConvertTo-SecureString $AdminUnsecurePassword -AsPlainText -Force
                                $mycreds =  New-Object -TypeName PSCredential -ArgumentList $UserName, $pass
                                $SetQuiesceStatusUrl = "https://" + $QuiesceVM.ip0 + ":9443/rest/v1/config/system"
                                #Try to run the invoke-rest method to get the Quiesce mode details
                                try {
                                    $SetQuiesceModeJSON = Invoke-RestMethod -Uri $SetQuiesceStatusUrl -Method Get -ContentType "application/json" -Credential $mycreds
                                    $SetQuiesceModeJSON.quiesceMode = "False"
                                    $SetQuiesceModeJSON.adminPassword = $AdminUnsecurePassword
                                    
                                } catch {
                                    Write-Host "Encountered exception running Get Settings Method:" $Error[0].Exception.Message -ForegroundColor Red
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $AdminUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $SetQuiesceStatusUrl = @()
                                    $SetQuiesceModeJSON = @()
                                    continue
                                }
                                $SetQuiesceModeJSON = $SetQuiesceModeJSON | ConvertTo-Json
                                try {
                                    $foo = $SetQuiesceModeJSON
                                    $jsonOutput = Invoke-RestMethod -Uri $SetQuiesceStatusUrl -Method Put -ContentType "application/json" -Body $SetQuiesceModeJSON -Credential $mycreds
                                    write-host "Updated UAG:" $QuiesceVM.UAGname "Quiesce Mode Setting to 'false'"
                                } catch {
                                    Write-Host "Encountered exception running Set Quiesce Mode Method:" $Error[0].Exception.Message -ForegroundColor Red
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $AdminUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $SetQuiesceStatusUrl = @()
                                    $SetQuiesceModeJSON = @()
                                    continue
                                }
                                $key = @()
                                $SecurePassword = @()
                                $BSTR = @()
                                $AdminUnsecurePassword = @()
                                $UserName = @()
                                $pass = @()
                                $SetQuiesceStatusUrl = @()
                                $SetQuiesceModeJSON = @()
                            }#end foreach loop
                            #END OF MENU-DAY2OPS-QUIESCE-DISABLE
                        } elseif ($QuiesceOption -eq "4") { #MENU-DAY2OPS-QUIESCE-DONE
                            #Done selected
                            $QuiesceMode = $false
                            #END OF MENU-DAY2OPS-QUIESCE-DONE
                        } else {
                            write-host "Invalid key input, try again please..."
                        }
                    } #END OF QUIESCE MODE MENU LOOP
                } else {
                    #Could not find any records for UAGs with that Horizon Pod name supplied
                    write-host "ERROR: Could not find any UAG's for Horizon Pod " $HorizonPod "in 'master-uag-list.csv'"
                } #END OF MENU-DAY2OPS-QUIESCE
            } elseif ($UpdateOption -eq "5") { #MENU-DAY2OPS-CERTS
                #Certificates mode selection
                $HorizonPod = Read-Host -Prompt "Enter the name (Case Sensitive) of the Horizon Pod for which to update all UAG's configured in CSV for the 'PodName' column?"
                $CSV = Import-Csv -Path ".\master-uag-list.csv"
                if (!$CSV) {
                    write-host "FATAL: Could not load 'master-uage-list.csv', please ensure it is present in the same directory as the script!"
                    Stop-Transcript
                    exit
                } else {}
                $CertsModeUAGs = $CSV | Where-Object {$_.PodName -imatch $HorizonPod}
                if ($CertsModeUAGs) { 
                    $CertsMode = $true
                    #Embed the user in a while loop to allow for modifications at the Horizon Pod level for day 2 ops
                    while ($CertsMode) { #CERTS MODE MENU LOOP
                        $CertsOption = Read-Host "[1] - Update User Certs, [2] - Update Admin Certs, [3] - Get Existing Certs, or [4] - Done for ($HorizonPod)"
                        if ($CertsOption -eq "1") { #MENU-DAY2OPS-CERTS-USER
                            #Update User certs selected
                            #Had to setup SSL ignore for invoke-rest method as self-signed certs in lab
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
                            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
                            foreach ($CertsVM in $CertsModeUAGs) {
                                $key = @()
                                $SecurePassword = @()
                                $BSTR = @()
                                $UserUnsecurePassword = @()
                                $UserName = @()
                                $pass = @()
                                $CertJSON = @()
                                $UserCertKey = @()
                                $UserCert = @()
                                $Userkeyfoo = @()
                                $UserCertfoo = @()
                                $SetCertsUserUrl = @()
                                $CertJSON = @()
                                $SetCertsUserUrl = "https://" + $CertsVM.ip0 + ":9443/rest/v1/config/certs/ssl/end_user"
                                if ($CertsVM.Skipped -eq 1) {
                                    #VM record is set to be disabled so skip this process
                                    write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                                    continue
                                } else {}
                                $key = Get-Content $CertsVM.UAGadminkey
                                if (!$key) {
                                    write-host "FATAL: Could not load" $CertsVM.UAGadminkey ", please ensure it is present in the same directory as the script!"
                                    Stop-Transcript
                                    exit
                                } else {}
                                $SecurePassword = ($CertsVM.UAGadminPW | ConvertTo-SecureString -Key $key)
                                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                                $UserUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                                $UserName = "admin"
                                $pass = ConvertTo-SecureString $UserUnsecurePassword -AsPlainText -Force
                                $mycreds =  New-Object -TypeName PSCredential -ArgumentList $UserName, $pass
                                $UserCertKey = Get-Content -Path $CertsVM.UserCertKey
                                if (!$UserCertKey) {
                                    write-host "ERROR:"$CertsVM.UserCertKey "was not found for UAG:" $CertsVM.UAGname
                                    Stop-Transcript
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $UserUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $CertJSON = @()
                                    $UserCertKey = @()
                                    $UserCert = @()
                                    $Userkeyfoo = @()
                                    $UserCertfoo = @()
                                    $SetCertsUserUrl = @()
                                    $CertJSON = @()
                                    exit
                                } else {}
                                foreach ($line in $UserCertKey) {
                                    $UserKeyfoo += $line + "\n"
                                }
                                $UserCert = Get-Content -Path $CertsVM.UserCert
                                if (!$UserCert) {
                                    write-host "ERROR:"$CertsVM.UserCert "was not found for UAG:" $CertsVM.UAGname
                                    Stop-Transcript
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $UserUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $CertJSON = @()
                                    $UserCertKey = @()
                                    $UserCert = @()
                                    $Userkeyfoo = @()
                                    $UserCertfoo = @()
                                    $SetCertsUserUrl = @()
                                    $CertJSON = @()
                                    exit
                                } else {}
                                foreach ($line in $UserCert) {
                                    $UserCertfoo += $line + "\n"
                                }
                                $CertJSON = @"
{
"privateKeyPem": "$UserKeyfoo",
"certChainPem": "$UserCertfoo"
}
"@
                                $CertJSON = $CertJSON -replace " ",""
                                $CertJSON = $CertJSON -replace "-----BEGINCERTIFICATE-----","-----BEGIN CERTIFICATE-----"
                                $CertJSON = $CertJSON -replace "-----ENDCERTIFICATE-----","-----END CERTIFICATE-----"
                                $CertJSON = $CertJSON -replace "-----BEGINRSAPRIVATEKEY-----","-----BEGIN RSA PRIVATE KEY-----"
                                $CertJSON = $CertJSON -replace "-----ENDRSAPRIVATEKEY-----","-----END RSA PRIVATE KEY-----"
                                #Try to run the invoke-rest method to get the certificates for end_user and admin
                                try {
                                    Invoke-RestMethod -Uri $SetCertsUserUrl -Method Put -ContentType "application/json" -Body $CertJSON -Credential $mycreds
                                    write-host "Updated User Certificate for UAG:" $CertsVM.UAGname
                                } catch {
                                    Write-Host "Encountered exception running Put UAG User Certificate Method:" $Error[0].Exception.Message "for UAG:" $CertsVM.UAGname -ForegroundColor Red
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $UserUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $CertJSON = @()
                                    $UserCertKey = @()
                                    $UserCert = @()
                                    $Userkeyfoo = @()
                                    $UserCertfoo = @()
                                    $SetCertsUserUrl = @()
                                    $CertJSON = @()
                                    continue
                                }
                            } #End of for loop
                            $key = @()
                            $SecurePassword = @()
                            $BSTR = @()
                            $UserUnsecurePassword = @()
                            $UserName = @()
                            $pass = @()
                            $CertJSON = @()
                            $UserCertKey = @()
                            $UserCert = @()
                            $Userkeyfoo = @()
                            $UserCertfoo = @()
                            $SetCertsUserUrl = @()
                            $CertJSON = @()
                            #END OF MENU-DAY2OPS-CERTS-USER
                        } elseif ($CertsOption -eq "2") { #MENU-DAY2OPS-CERTS-ADMIN
                            #Update Admin certs selected
                            #Had to setup SSL ignore for invoke-rest method as self-signed certs in lab
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
                            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
                            foreach ($CertsVM in $CertsModeUAGs) {
                                $key = @()
                                $SecurePassword = @()
                                $BSTR = @()
                                $AdminUnsecurePassword = @()
                                $UserName = @()
                                $pass = @()
                                $CertJSON = @()
                                $AdminCertKey = @()
                                $AdminCert = @()
                                $Adminkeyfoo = @()
                                $AdminCertfoo = @()
                                $SetCertsAdminUrl = @()
                                $CertJSON = @()
                                $SetCertsAdminUrl = "https://" + $CertsVM.ip0 + ":9443/rest/v1/config/certs/ssl/admin"
                                if ($CertsVM.Skipped -eq 1) {
                                    #VM record is set to be disabled so skip this process
                                    write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                                    continue
                                } else {}
                                $key = Get-Content $CertsVM.UAGadminkey
                                if (!$key) {
                                    write-host "FATAL: Could not load" $CertsVM.UAGadminkey ", please ensure it is present in the same directory as the script!"
                                    Stop-Transcript
                                    exit
                                } else {}
                                $SecurePassword = ($CertsVM.UAGadminPW | ConvertTo-SecureString -Key $key)
                                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                                $AdminUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                                $UserName = "admin"
                                $pass = ConvertTo-SecureString $AdminUnsecurePassword -AsPlainText -Force
                                $mycreds =  New-Object -TypeName PSCredential -ArgumentList $UserName, $pass
                                $AdminCertKey = Get-Content -Path $CertsVM.AdminCertKey
                                if (!$AdminCertKey) {
                                    write-host "ERROR:"$CertsVM.AdminCertKey "was not found for UAG:" $CertsVM.UAGname
                                    Stop-Transcript
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $AdminUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $CertJSON = @()
                                    $AdminCertKey = @()
                                    $AdminCert = @()
                                    $Adminkeyfoo = @()
                                    $AdminCertfoo = @()
                                    $SetCertsAdminUrl = @()
                                    $CertJSON = @()
                                    exit
                                } else {}
                                foreach ($line in $AdminCertKey) {
                                    $AdminKeyfoo += $line + "\n"
                                }
                                $AdminCert = Get-Content -Path $CertsVM.AdminCert
                                if (!$AdminCert) {
                                    write-host "ERROR:"$CertsVM.AdminCert "was not found for UAG:" $CertsVM.UAGname
                                    Stop-Transcript
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $AdminUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $CertJSON = @()
                                    $AdminCertKey = @()
                                    $AdminCert = @()
                                    $Adminkeyfoo = @()
                                    $AdminCertfoo = @()
                                    $SetCertsAdminUrl = @()
                                    $CertJSON = @()
                                    exit
                                } else {}
                                foreach ($line in $AdminCert) {
                                    $AdminCertfoo += $line + "\n"
                                }
                                $CertJSON = @"
{
"privateKeyPem": "$AdminKeyfoo",
"certChainPem": "$AdminCertfoo"
}
"@
                                $CertJSON = $CertJSON -replace " ",""
                                $CertJSON = $CertJSON -replace "-----BEGINCERTIFICATE-----","-----BEGIN CERTIFICATE-----"
                                $CertJSON = $CertJSON -replace "-----ENDCERTIFICATE-----","-----END CERTIFICATE-----"
                                $CertJSON = $CertJSON -replace "-----BEGINRSAPRIVATEKEY-----","-----BEGIN RSA PRIVATE KEY-----"
                                $CertJSON = $CertJSON -replace "-----ENDRSAPRIVATEKEY-----","-----END RSA PRIVATE KEY-----"
                                #Try to run the invoke-rest method to get the certificates for end_user and admin
                                try {
                                    Invoke-RestMethod -Uri $SetCertsAdminUrl -Method Put -ContentType "application/json" -Body $CertJSON -Credential $mycreds
                                    write-host "Updated Admin Certificate for UAG:" $CertsVM.UAGname
                                } catch {
                                    Write-Host "Encountered exception running Put UAG Admin Certificate Method:" $Error[0].Exception.Message "for UAG:" $CertsVM.UAGname -ForegroundColor Red
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $AdminUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $CertJSON = @()
                                    $AdminCertKey = @()
                                    $AdminCert = @()
                                    $Adminkeyfoo = @()
                                    $AdminCertfoo = @()
                                    $SetCertsAdminUrl = @()
                                    $CertJSON = @()
                                    continue
                                }
                            } #End of for loop
                            $key = @()
                            $SecurePassword = @()
                            $BSTR = @()
                            $AdminUnsecurePassword = @()
                            $UserName = @()
                            $pass = @()
                            $CertJSON = @()
                            $AdminCertKey = @()
                            $AdminCert = @()
                            $Adminkeyfoo = @()
                            $AdminCertfoo = @()
                            $SetCertsAdminUrl = @()
                            $CertJSON = @()
                            #END OF MENU-DAY2OPS-CERTS-ADMIN
                        } elseif ($CertsOption -eq "3") { #MENU-DAY2OPS-CERTS-STATUS
                            #Get certs selected
                            #Had to setup SSL ignore for invoke-rest method as self-signed certs in lab
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
                            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
                            foreach ($CertsVM in $CertsModeUAGs) {
                                $key = @()
                                $SecurePassword = @()
                                $BSTR = @()
                                $AdminUnsecurePassword = @()
                                $UserName = @()
                                $pass = @()
                                $GetCertsUserUrl = @()
                                $GetCertsAdminUrl = @()
                                $CertsInfo = @()
                                if ($CertsVM.Skipped -eq 1) {
                                    #VM record is set to be disabled so skip this process
                                    write-host "WARNING: Record for this object is set Skipped = 1, so skipping..."
                                    continue
                                } else {}
                                $key = Get-Content $CertsVM.UAGadminkey
                                if (!$key) {
                                    write-host "FATAL: Could not load" $CertsVM.UAGadminkey ", please ensure it is present in the same directory as the script!"
                                    Stop-Transcript
                                    exit
                                } else {}
                                $SecurePassword = ($CertsVM.UAGadminPW | ConvertTo-SecureString -Key $key)
                                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
                                $AdminUnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                                $UserName = "admin"
                                $pass = ConvertTo-SecureString $AdminUnsecurePassword -AsPlainText -Force
                                $mycreds =  New-Object -TypeName PSCredential -ArgumentList $UserName, $pass
                                $GetCertsUserUrl = "https://" + $CertsVM.ip0 + ":9443/rest/v1/config/certs/ssl/end_user"
                                $GetCertsAdminUrl = "https://" + $CertsVM.ip0 + ":9443/rest/v1/config/certs/ssl/admin"
                                #Try to run the invoke-rest method to get the certificates for end_user and admin
                                try {
                                    $jsonOutput = Invoke-RestMethod -Uri $GetCertsUserUrl -Method Get -ContentType "application/json" -Credential $mycreds
                                    write-host "__________"
                                    write-host "UAG:" $CertsVM.UAGname "User Facing Certificate:"
                                    write-host ""
                                    $jsonOutput
                                } catch {
                                    Write-Host "Encountered exception running Get UAG User Certificate Method:" $Error[0].Exception.Message -ForegroundColor Red
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $AdminUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $GetCertsUserUrl = @()
                                    continue
                                }
                                try {
                                    $jsonOutput = Invoke-RestMethod -Uri $GetCertsAdminUrl -Method Get -ContentType "application/json" -Credential $mycreds
                                    write-host "UAG:" $CertsVM.UAGname "Admin Portal Certificate:"
                                    write-host ""
                                    $jsonOutput
                                    write-host "__________"
                                } catch {
                                    Write-Host "Encountered exception running Get UAG Admin Certificate Method:" $Error[0].Exception.Message -ForegroundColor Red
                                    $key = @()
                                    $SecurePassword = @()
                                    $BSTR = @()
                                    $AdminUnsecurePassword = @()
                                    $UserName = @()
                                    $pass = @()
                                    $GetCertsAdminUrl = @()
                                    continue
                                }
                                $key = @()
                                $SecurePassword = @()
                                $BSTR = @()
                                $AdminUnsecurePassword = @()
                                $UserName = @()
                                $pass = @()
                                $GetCertsUserUrl = @()
                                $GetCertsAdminUrl = @()
                            }#End of foreach loop
                            #END OF MENU-DAY2OPS-CERTS-STATUS
                        } elseif ($CertsOption -eq "4") { #MENU-DAY2OPS-CERTS-DONE
                            #Exit Update Mode
                            $CertsMode = $false
                            #END OF MENU-DAY2OPS-CERTS-DONE
                        } else {
                            write-host "ERROR: Invalid selection entered, please try again"
                        }
                    } #END OF CERTS MODE MENU LOOP
                } else {
                    #Could not find any records for UAGs with that Horizon Pod name supplied
                    write-host "ERROR: Could not find any UAG's for Horizon Pod " $HorizonPod "in 'master-uag-list.csv'"
                }
            } elseif ($UpdateOption -eq "6") { #MENU-DAY2OPS-DONE
                #Exit the Day 2 Operations mode
                $UpdateMode = $false
            } else {
                write-host "ERROR: Invalid selection entered, please try again"
            }
        } #END OF MENU-DAY2OPS
    } elseif ($MenuAction -eq "5") { #MENU-EXIT
        write-host "INFO: Exiting..."
        $CSV = @()
        $UAGinitemplate = @()
        $UAGini = @()
        $iniFile = @()
        $SecurePassword = @()
        $VCUnsecurePassword = @()
        $UAGrootPWsec = @()
        $UAGrootPWunsec = @()
        $UAGadminPWsec = @()
        $UAGadminPWunsec = @()
        $BSTR = @()
        $VMList = @()
        $DeleteVM = @()
        $VM = @()
        $KeyFile = @()
        $Key = @()
        $ScriptRun = $false
    } else {
        write-host "Invalid key input, try again please..."
    }
} #END OF MENU
Stop-Transcript
#END OF SCRIPT