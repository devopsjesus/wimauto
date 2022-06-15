#requires -RunAsAdministrator
$workspacePath     = "C:\workspace"
$ServerVersion     = "Windows Server 2019"
$WimAutoModulePath = "$workspacePath\modules\wimauto\wimauto.psd1"

Get-Module wimauto | Remove-Module -ErrorAction Ignore
Import-Module -FullyQualifiedName $WimAutoModulePath

# Uncomment this command to retrieve and approve new updates - takes a few minutes to complete
# Set-EnabledProductUpdateApproval -Verbose -ErrorAction Stop

$buildParams = @{
    ServerVersion        = $ServerVersion
    WorkspacePath        = $workspacePath
    ImageMountPath       = "$workspacePath\mount"
    ImageIndex           = 2                                 # Default index list 1:StdCore - 2:StdFull - 3:DcCore - 4:DcFull
    # WindowsProductKey    = 'N69G4-B89J2-4G8F4-WWYCC-J464C' # Specify the Product Key if known - otherwise the module will attempt to find the KMS key to use, but the InjectAnswerFiles attribute in $options will need to be enabled
    UpdateRepoDirectory  = "$workspacePath\updaterepo"
    UnattendFilePath     = "$workspacePath\unattend.xml"     # Unattend File Sets Product KMS Key, sets admin pw, autologs admin in, bypasses OOBE wizard, and launches powershell
    AutounattendFilePath = "$workspacePath\Autounattend.xml" # Autounattend File Sets language, partitions hard drive, sets Product KMS Key, and sets which partition hosts the OS
}

$vhdSettings = @{
    VhdSizeGB = 21GB
    VhdPath   = "C:\VirtualHardDisks\$($ServerVersion.replace(' ',''))-$($buildParams.ImageIndex)-$(Get-Date -Format yyyyMMdd).vhdx"
}

$isoSettings = @{
    OscdimgPath        = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\x86\Oscdimg\oscdimg.exe"
    IsoContentsPath    = "$WorkspacePath\ISOContents"
    IsoDestinationPath = "$WorkspacePath\Win2K19Std-$(Get-Date -Format yyyyMMdd).iso"
}

$options = @{
    CopyWimFromIso    = $false
    InjectUpdates     = $true
    InjectDrivers     = $false
    InjectAnswerFiles = $true
    GenerateVHDx      = $false
    GenerateIso       = $true
}

if ($ServerVersion -eq "Windows Server 2019")
{
    $buildParams += @{
        IsoPath            = "$workspacePath\ISOs\en-us_windows_server_2019_updated_aug_2021_x64_dvd_a6431a28.iso"
        WimDestinationPath = "$workspacePath\wimrepo\win2019\install.wim"
        ExportedWimPath    = "$workspacePath\wimrepo\win2019\install.optimized.wim"
    }
}
elseif ($ServerVersion -eq "Windows Server 2016")
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

Invoke-BuildUpdate @buildParams @vhdSettings @isoSettings @options
