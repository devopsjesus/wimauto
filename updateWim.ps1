#requires -Modules wimauto -RunAsAdministrator
param(
    $WimAutoModulePath = "C:\Library\ngenbuild\modules\wimauto\wimauto.psd1"
)

#region Modules
Get-Module wimauto | Remove-Module -ErrorAction Ignore
Import-Module -FullyQualifiedName $WimAutoModulePath
#endregion Modules


#region initial steps
$copyWimParams = @{
    IsoPath            = "C:\library\ngenbuild\osimages\win16\en_windows_server_2016_vl_x64_dvd_11636701.iso"
    WimDestinationPath = "C:\library\ngenbuild\osimages\win16\install.wim"
}
Copy-WimFromISO @copyWimParams


$updateWimParams = @{
    WimPath           = "C:\library\ngenbuild\osimages\win16\install.wim"
    ImageMountPath    = "C:\library\ngenbuild\osimages\mount"
    WsusRepoDirectory = "C:\library\ngenbuild\updaterepo"
    ServerVersion     = "Windows Server 2016"
}
Install-UpdateListToWim @updateWimParams
#endregion
