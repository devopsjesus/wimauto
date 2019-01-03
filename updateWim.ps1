#requires -RunAsAdministrator
$workspacePath     = "C:\DscPushTest\updatewim"
$ServerVersion     = "Windows Server 2016"
$WimAutoModulePath = "$workspacePath\wimauto.psd1"

#region Modules
Get-Module wimauto | Remove-Module -ErrorAction Ignore
Import-Module -FullyQualifiedName $WimAutoModulePath
#endregion Modules

$buildParams = @{
    ServerVersion        = $ServerVersion
    WorkspacePath        = $workspacePath
    ImageMountPath       = "$workspacePath\mount"
    ImageIndex           = 2                                 # Default index list 1:StdCore - 2:StdFull - 3:DcCore - 4:DcFull
    UpdateRepoDirectory  = "$workspacePath\updaterepo"
    UnattendFilePath     = "$workspacePath\unattend.xml"     # Unattend File Sets Product KMS Key, sets admin pw, autologs admin in, bypasses OOBE wizard, and launches powershell
    AutounattendFilePath = "$workspacePath\Autounattend.xml" # Autounattend File Sets language, partitions hard drive, sets Product KMS Key, and sets which partition hosts the OS
    OscdimgPath          = "$WorkspacePath\Oscdimg\oscdimg.exe"
    IsoContentsPath      = "$WorkspacePath\ISOContents"
}

$vhdSettings = @{
    VhdSizeGB = 21GB
    VhdPath   = "C:\VirtualHardDisks\$($ServerVersion.replace(' ',''))-$($foo.ImageIndex)-$(Get-Date -Format yyyyMMdd).vhdx"
}

$options = @{
    CopyWimFromIso    = $false
    InjectUpdates     = $true
    InjectDrivers     = $false
    InjectAnswerFiles = $true
    GenerateVHDx      = $true
    GenerateIso       = $false
}

if ($ServerVersion -eq "Windows Server 2016")
{
    $buildParams += @{
        IsoPath            = "C:\Library\ISOs\en_windows_server_2016_updated_feb_2018_x64_dvd_11636692.iso"
        WimDestinationPath = "$workspacePath\wimrepo\win2016\install.wim"
        ExportedWimPath    = "$workspacePath\wimrepo\win2016\install.optimized.wim"
    }
}
else
{
    $buildParams += @{
        IsoPath            = "C:\Library\ISOs\en_windows_server_2012_r2_with_update_x64_dvd_6052708.iso"
        WimDestinationPath = "$workspacePath\wimrepo\win2012\install.wim"
        ExportedWimPath    = "$workspacePath\wimrepo\win2012\install.optimized.wim"
        VhdPath            = "C:\VirtualHardDisks\win2012-$(Get-Date -Format yyyyMMdd).vhdx"
        Wmf51Path          = "$workspacePath\wmf5.1.msu"
    }
}

Set-EnabledProductUpdateApproval -Verbose -ErrorAction Stop

Invoke-BuildUpdate @buildParams @vhdSettings @options
