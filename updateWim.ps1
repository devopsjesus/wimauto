#requires -RunAsAdministrator
$workspacePath = "C:\Library\deploy\updatewim"
$ServerVersion = "Windows Server 2012 R2"
$WimAutoModulePath    = "$workspacePath\wimauto.psd1"

#region Modules
Get-Module wimauto | Remove-Module -ErrorAction Ignore
Import-Module -FullyQualifiedName $WimAutoModulePath
#endregion Modules

$buildParams = @{
    ServerVersion        = $ServerVersion
    WorkspacePath        = $workspacePath
    ImageMountPath       = "$workspacePath\mount"
    ImageIndex           = 4
    UpdateRepoDirectory  = "$workspacePath\updaterepo"
    UnattendFilePath     = "$workspacePath\unattend.xml"
    AutounattendFilePath = "$workspacePath\Autounattend.xml"
    DriverDirectoryPath  = "$workspacePath\drivers\HPE_DL380_Gen10"
    OscdimgPath          = "$WorkspacePath\Oscdimg\oscdimg.exe"
    IsoContentsPath      = "$WorkspacePath\ISOContents"
    IsoDestinationPath   = "$WorkspacePath\$($ServerVersion.replace(' ',''))-drivers-$(Get-Date -Format yyyyMMdd).iso"
    VhdSizeGB            = 21GB
    CopyWimFromIso       = $false
    InjectUpdates        = $false
    InjectDrivers        = $false
    InjectAnswerFiles    = $true
    GenerateVHDx         = $false
    GenerateIso          = $true
}

if ($ServerVersion -eq "Windows Server 2016")
{
    $buildParams += @{
        IsoPath              = "C:\Library\ISOs\en_windows_server_2016_updated_feb_2018_x64_dvd_11636692.iso"
        WimDestinationPath   = "$workspacePath\wimrepo\win2016\install.wim"
        ExportedWimPath      = "$workspacePath\wimrepo\win2016\install.optimized.wim"
        VhdPath              = "C:\VirtualHardDisks\win2016-$(Get-Date -Format yyyyMMdd).vhdx"
    }
}
else
{
    $buildParams += @{
        IsoPath              = "C:\Library\ISOs\en_windows_server_2012_r2_with_update_x64_dvd_6052708.iso"
        WimDestinationPath   = "$workspacePath\wimrepo\win2012\install.wim"
        ExportedWimPath      = "$workspacePath\wimrepo\win2012\install.optimized.wim"
        VhdPath              = "C:\VirtualHardDisks\win2012-$(Get-Date -Format yyyyMMdd).vhdx"
        Wmf51Path            = "$workspacePath\wmf5.1.msu"
    }
}

Invoke-BuildUpdate @buildParams
