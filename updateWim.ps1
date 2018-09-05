#requires -RunAsAdministrator
#region vars
$workspacePath     = "C:\Library\deploy\updatewim"
$WimAutoModulePath = "$workspacePath\wimauto.psd1"
$imageMountPath    = "$workspacePath\mount"
$imageIndex        = 1
$vhdSizeGB         = 21GB

<# Windows 2016 vars 
$serverVersion     = "Windows Server 2016"
$IsoPath           = "C:\Library\ISOs\en_windows_server_2016_updated_feb_2018_x64_dvd_11636692.iso"
$wimPath           = "$workspacePath\wimrepo\win2016\install.wim"
$exportedWimPath   = "$workspacePath\wimrepo\win2016\install.optimized.wim"
$VhdPath           = "C:\VirtualHardDisks\win2016core-$(Get-Date -Format yyyyMMdd).vhdx"
$vmName            = "win2016updatedimage-$(Get-Date -Format yyyyMMdd)"
#>
# Windows 2012 R2 vars
$serverVersion     = "Windows Server 2012 R2"
$IsoPath           = "C:\Library\ISOs\en_windows_server_2012_r2_with_update_x64_dvd_6052708.iso"
$wimPath           = "$workspacePath\wimrepo\win2012\install.wim"
$exportedWimPath   = "$workspacePath\wimrepo\win2012\install.optimized.wim"
$VhdPath           = "C:\VirtualHardDisks\win2012core-$(Get-Date -Format yyyyMMdd).vhdx"
$vmName            = "win2012updatedimage-$(Get-Date -Format yyyyMMdd)"
$wmf51Path          = "$workspacePath\wmf5.1.msu"
#>
#endregion

#region Modules
Get-Module wimauto | Remove-Module -ErrorAction Ignore
Import-Module -FullyQualifiedName $WimAutoModulePath
#endregion Modules

#Uncomment the section below to install WSUS - only needs to be run once to initialize WSUS.
#The Set-WsusConfiguration command will not run successfully until the initial WSUS Sync is complete (takes a while).
<#
Install-WSUS -WsusRepoDirectory "$workspacePath\updaterepo" -UpdateLanguageCode "en"

$wsusServer = Get-WsusServer -Name localhost -PortNumber 8530
$wsusSubscription = $wsusServer.GetSubscription()
while (($wsusSubscription.GetSynchronizationStatus()) -eq 'Running')
{
    Start-Sleep -Seconds 5
    Write-Output $wsusSubscription.GetSynchronizationProgress()
}

Set-WsusConfiguration

$wsusSubscription = $wsusServer.GetSubscription()
while (($wsusSubscription.GetSynchronizationStatus()) -eq 'Running')
{
    Start-Sleep -Seconds 5
    Write-Output $wsusSubscription.GetSynchronizationProgress()
}

Set-EnabledProductUpdateApproval
#>
Write-Output "Copying Wim from ISO"
$copyWimParams = @{
    IsoPath            = $IsoPath
    WimDestinationPath = $wimPath
}
Copy-WimFromISO @copyWimParams

#mount the wim
if (! (Test-Path $imageMountPath))
{
    $null = New-Item -Path $ImageMountPath -ItemType "Directory" -ErrorAction Stop
}    
Write-Output "Mounting image"
$null = Mount-WindowsImage -ImagePath $wimPath -Index $imageIndex -Path $imageMountPath -ErrorAction Stop

#Dism command used here because there's no parallel PS cmdlet
Write-Output "Cleaning image and resetting base"
& Dism.exe /Image:$imageMountPath /Cleanup-Image /StartComponentCleanup /ResetBase
#Not sure the below line is necessary here
#Save-WindowsImage -Path $imageMountPath

if ($serverVersion -eq "Windows Server 2012 R2")
{
    Write-Output "Adding WMF5.1 to image"
    $updateWimParams = @{
        WimPath        = $wimPath
        ImageIndex     = $imageIndex
        ImageMountPath = $imageMountPath
        UpdateFileList = $UpdateFileList = @{
            ID       = "Win8.1AndW2K12R2-KB3191564-x64"
            FilePath = $wmf51Path
        }
    }
    Add-PackageToWim @updateWimParams
}

Write-Output "Adding Updates to image"
$updateWimParams = @{
    WimPath           = $wimPath
    ImageIndex        = $ImageIndex
    ImageMountPath    = $imageMountPath
    WsusRepoDirectory = "$workspacePath\updaterepo"
    ServerVersion     = $serverVersion
}
Install-UpdateListToWim @updateWimParams -Verbose

Write-Output "Unmounting Image"
$wimLogPath = Join-Path -Path (Split-Path -Path $wimPath -Parent) -ChildPath "DismountErrors-$(Get-Date -Format yyyyMMdd).log"
#Dism command used below because I just could NOT seem to get the PS cmdlet following to actually save the image with the packages
& Dism.exe /Unmount-Image /MountDir:$imageMountPath /Commit /LogLevel:1 /LogPath:$wimLogPath
#$null = Dismount-WindowsImage -Path $ImageMountPath -Save -LogPath $wimLogPath -Append -LogLevel Errors -ErrorAction Stop

#since we typically only deploy the target index ($imageIndex) from the image, export that as the final target wim
Write-Output "Exporting target index from image"
Export-WindowsImage -SourceImagePath $wimPath -CheckIntegrity -DestinationImagePath $exportedWimPath -SourceIndex 1

Write-Output "Creating VHDx and VM"
$newVHDxParams = @{
    LocalVhdPath       = $vhdPath
    VhdSize            = $vhdSizeGB
    VHDDType           = "Dynamic"
    WimPath            = $exportedWimPath
    ImageIndex         = $imageIndex
    ClobberVHDx        = $true
    UnattendFilePath   = "$workspacePath\unattend.xml"
    DismountVHDx       = $true
}
New-VHDxFromWim @newVHDxParams
New-VM -Name $vmName -MemoryStartupBytes 1028MB -VHDPath $newVHDxParams.LocalVhdPath -Generation 2 | Start-VM

#Stop-VM -Name $vmName -TurnOff -Force -Confirm:$false
#Remove-VM -Name $vmName -Force -Confirm:$false
#Remove-Item -Path $newVHDxParams.LocalVhdPath -Force -Confirm:$false
