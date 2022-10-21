## Prerequisites
1. Download repo as zip and extract into 'workspace' directory
1. Import wimauto module
1. Install WSUS
   1. Run `Install-WSUS -WsusRepoDirectory "$workspacePath\updaterepo" -UpdateLanguageCode "en"`
      1. This will take some time to fully complete due to the initial sync (will take a LONG time)
      1. There is an option to install WSUS as part of the 'Invoke-BuildUpdate' wrapper function, but I don't recommend using it since it's a single-run process - it's mostly there as a template
   1. Run Set-WsusConfiguration
   1. Run Set-EnabledProductUpdateApproval
      1. This will take some time as it gathers the product updates and filters them
1. Download desired Windows ISO and copy into the workspace directory
1. To obtain oscdimg.exe
   1. Download [WADK](https://go.microsoft.com/fwlink/?linkid=2196127)
      1. Select only 'Deployment Tools' feature to install
      1. Either copy the exe to workspace, and/or update path in build params ($isoSettings.OscdimgPath)

## Operations
1. Modify the updateWim.ps1 wrapper script as necessary
   1. Update workspace variable and ensure Server Version is set to desired version
   1. Ensure the path to the wimauto module files is correct
   1. Update the buildParams variable as necessary
      1. ImageIndex attribute controls which version of the OS to install (e.g. Standard vs Datacenter)
   1. Update OscdimgPath in isoSettings variable if necessary
   1. Update the options as necessary
      1. Typically only need to copy the wim from the ISO once, then set this to false
      1. Should leave InjectAnswerFiles on true at least once so the correct license is injected into the auto/unattend.xml files
   1. Update server version build Params as necessary
      1. Update the IsoPath to the correct file path to the downloaded OS Source ISO
   1. Feel free to strip out the 2012 stuff - I've left it in just in case

## Passwords
Passwords in unattend files are encoded in base64 with 'Password' and 'AdministratorPassword' appended to the password string

- P@ssw0rd123 <-- OG PW
- UABAAHMAcwB3ADAAcgBkADEAMgAzAFAAYQBzAHMAdwBvAHIAZAA= <-- Base64 encoding in unattend.xml 'AutoLogon | Password' value
   - P@ssw0rd123Password
- UABAAHMAcwB3ADAAcgBkADEAMgAzAEEAZABtAGkAbgBpAHMAdAByAGEAdABvAHIAUABhAHMAcwB3AG8AcgBkAA== <-- Base64 encoding in unattend.xml 'UserAccounts | AdministratorPassword' value
   - P@ssw0rd123AdministratorPassword

### Code to decode/encode unattend passwords:
```
$encryptedText = 'UABAAHMAcwB3ADAAcgBkADEAMgAzAEEAZABtAGkAbgBpAHMAdAByAGEAdABvAHIAUABhAHMAcwB3AG8AcgBkAA=='
Write-Host 'Decoded Admin Password'
[System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($encryptedText))

$adminPasswordText = 'P@ssw0rd123AdministratorPassword'
Write-Host 'Base64 encoded Admin Password'
[System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(($adminPasswordText)))
```


## Upload blob
To offload the ISO/VHD from an Azure VM:
```
Connect-AzAccount -Environment $azureEnvironment
$sa=Get-AzStorageAccount -ResourceGroupName $saRG -Name $saName
Set-AzStorageBlobContent -File $pathToFile -Container $containerName -Context $sa.Context
```
