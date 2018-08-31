#requires -RunAsAdministrator
$workspacePath = "$env:USERPROFILE\Desktop\wimauto"
$WimAutoModulePath = "$workspacePath\wimauto.psd1"

#region Modules
Get-Module wimauto | Remove-Module -ErrorAction Ignore
Import-Module -FullyQualifiedName $WimAutoModulePath
#endregion Modules

#Uncomment the below two lines to install WSUS - only needs to be run once to initialize WSUS
#The second command will not run successfully until the initial WSUS Sync is complete
#Install-WSUS -WsusRepoDirectory "$workspacePath\updaterepo" -UpdateLanguageCode "en"
#Set-WsusConfigurationWin16

$copyWimParams = @{
    IsoPath            = "$workspacePath\osimages\win16\en_windows_server_2016_vl_x64_dvd_11636701.iso"
    WimDestinationPath = "$workspacePath\osimages\win16\install.wim"
}
Copy-WimFromISO @copyWimParams

$updateWimParams = @{
    WimPath           = "$workspacePath\osimages\win16\install.wim"
    ImageIndex        = 1
    ImageMountPath    = "$workspacePath\osimages\mount"
    WsusRepoDirectory = "$workspacePath\updaterepo"
    ServerVersion     = "Windows Server 2016"
}
Install-UpdateListToWim @updateWimParams -Verbose

$newVHDxParams = @{
    LocalVhdPath       = "C:\VHDs\win2016-$(Get-Date -Format yyyyMMdd).vhdx"
    VhdSize            = 21GB
    WindowsVolumeLabel = "OSDisk"
    VHDDType           = "Dynamic"
    BootDriveLetter    = "S"
    OSDriveLetter      = "V"
    WimPath            = "$workspacePath\osimages\win16\install.wim"
    ImageIndex         = 1
    ClobberVHDx        = $true
    DismountVHDx       = $true
}
New-VHDxFromWim @newVHDxParams

New-VM -Name "test" -MemoryStartupBytes 1028MB -VHDPath $newVHDxParams.LocalVhdPath -Generation 2
