#requires -RunAsAdministrator
$workspacePath = "C:\Library\deploy\updatewim"
$WimAutoModulePath = "$workspacePath\wimauto.psd1"

#region vars
$wimPath = "$workspacePath\wimrepo\win2016\install.wim"
#endregion

#region Modules
Get-Module wimauto | Remove-Module -ErrorAction Ignore
Import-Module -FullyQualifiedName $WimAutoModulePath
#endregion Modules

#Uncomment the section below to install WSUS - only needs to be run once to initialize WSUS
#The Set-WsusConfigurationWin16 command will not run successfully until the initial WSUS Sync is complete (takes a while)
<#
Install-WSUS -WsusRepoDirectory "$workspacePath\updaterepo" -UpdateLanguageCode "en"

$wsusServer = Get-WsusServer -Name localhost -PortNumber 8530
$wsusSubscription = $wsusServer.GetSubscription()
while (($wsusSubscription.GetSynchronizationStatus()) -eq 'Running')
{
    Start-Sleep -Seconds 5
    Write-Output $wsusSubscription.GetSynchronizationProgress()
}

Set-WsusConfigurationWin16
#>

$copyWimParams = @{
    IsoPath            = "C:\Library\ISOs\en_windows_server_2016_updated_feb_2018_x64_dvd_11636692.iso"
    WimDestinationPath = $wimPath
}
Copy-WimFromISO @copyWimParams

$updateWimParams = @{
    WimPath           = $wimPath
    ImageIndex        = 1
    ImageMountPath    = "$workspacePath\mount"
    WsusRepoDirectory = "$workspacePath\updaterepo"
    ServerVersion     = "Windows Server 2016"
}
Install-UpdateListToWim @updateWimParams -Verbose

$newVHDxParams = @{
    LocalVhdPath       = "C:\VirtualHardDisks\win2016core-$(Get-Date -Format yyyyMMdd).vhdx"
    VhdSize            = 21GB
    VHDDType           = "Dynamic"
    WimPath            = "$workspacePath\wimrepo\win2016\install.wim"
    ImageIndex         = 1
    ClobberVHDx        = $true
    UnattendFilePath   = "$workspacePath\unattend.xml"
    DismountVHDx       = $true
}
New-VHDxFromWim @newVHDxParams

New-VM -Name "wimtest" -MemoryStartupBytes 1028MB -VHDPath $newVHDxParams.LocalVhdPath -Generation 2 | Start-VM

#Stop-VM -Name "wimtest" -TurnOff -Force -Confirm:$false
#Remove-VM -Name "wimtest" -Force -Confirm:$false
#Remove-Item -Path $newVHDxParams.LocalVhdPath -Force -Confirm:$false