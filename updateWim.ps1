#requires -RunAsAdministrator

param
(
    [parameter()]
    [ValidateSet("Windows Server 2016","Windows Server 2012")]
    [string]
    $ServerVersion     = "Windows Server 2016",

    [parameter()]
    [ValidateScript({Test-Path $_})]
    [string]
    $IsoPath           = "C:\Library\ISOs\en_windows_server_2016_updated_feb_2018_x64_dvd_11636692.iso",

    [parameter()]
    [string]
    $WimPath           = "$workspacePath\wimrepo\win2016\install.wim",

    [parameter()]
    [string]
    $ExportedWimPath   = "$workspacePath\wimrepo\win2016\install.optimized.wim",

    [parameter()]
    [string]
    $VhdPath           = "C:\VirtualHardDisks\win2016core-$(Get-Date -Format yyyyMMdd).vhdx",

    [parameter()]
    [string]
    $VmName            = "win2016updatedimage-$(Get-Date -Format yyyyMMdd)",

    [parameter()]
    [ValidateScript({Test-Path $_})]
    [string]
    $WorkspacePath     = "C:\Library\deploy\updatewim",

    [parameter()]
    [ValidateScript({Test-Path $_})]
    [string]
    $WimAutoModulePath = "$workspacePath\wimauto.psd1",

    [parameter()]
    [string]
    $ImageMountPath    = "$workspacePath\mount",

    [parameter()]
    [int]
    $ImageIndex        = 1,

    [parameter()]
    [int64]
    $VhdSizeGB         = 21GB,
    
    [parameter()]
    [switch]
    $InstallWSUS
)

#just storing my 2012 data here for now - don't judge
if ($ServerVersion -eq "Windows Server 2012 R2")
{
    $IsoPath           = "C:\Library\ISOs\en_windows_server_2012_r2_with_update_x64_dvd_6052708.iso"
    $wimPath           = "$workspacePath\wimrepo\win2012\install.wim"
    $exportedWimPath   = "$workspacePath\wimrepo\win2012\install.optimized.wim"
    $VhdPath           = "C:\VirtualHardDisks\win2012core-$(Get-Date -Format yyyyMMdd).vhdx"
    $vmName            = "win2012updatedimage-$(Get-Date -Format yyyyMMdd)"
    $win12UpdatesPath  = "$workspacePath\Win12Updates" #Will Copy contents to C:\Windows\Temp\Win12Updates
    $wmf51Path         = "$workspacePath\wmf5.1.msu"
}

#region Modules
Get-Module wimauto | Remove-Module -ErrorAction Ignore
Import-Module -FullyQualifiedName $WimAutoModulePath
#endregion Modules

if ($InstallWSUS)
{
    #The section below will install WSUS - only needs to be run once - I've only tested installing on the deployment host.
    #The Set-WsusConfiguration command will not run successfully until the initial WSUS Sync is complete (takes a while).
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

    <#to enable reporting in WSUS:
    Invoke-WebRequest -Uri 'https://download.microsoft.com/download/F/B/7/FB728406-A1EE-4AB5-9C56-74EB8BDDF2FF/ReportViewer.msi' -OutFile "$workspacePath\ReportViewer.msi"
    go to "https://www.microsoft.com/en-us/download/confirmation.aspx?id=49999&6B49FDFB-8E5B-4B07-BC31-15695C5A2143=1" and download "SQLSysClrTypes.msi"
    then run the two MSI files - SQL CLR types first
    #>
}

Write-Output "Copying Wim from ISO: $IsoPath"
$copyWimParams = @{
    IsoPath            = $IsoPath
    WimDestinationPath = $wimPath
}
Copy-WimFromISO @copyWimParams

Write-Output "Mounting image"
if (! (Test-Path $imageMountPath))
{
    $null = New-Item -Path $ImageMountPath -ItemType "Directory" -ErrorAction Stop
}    
$null = Mount-WindowsImage -ImagePath $wimPath -Index $imageIndex -Path $imageMountPath -ErrorAction Stop

if ($serverVersion -eq "Windows Server 2012 R2")
{
    Write-Output "Adding WMF5.1 to image"
    $updateWimParams = @{
        WimPath        = $wimPath
        ImageMountPath = $imageMountPath
        UpdateFileList = $UpdateFileList = @{
            ID       = "Win8.1AndW2K12R2-KB3191564-x64"
            FilePath = $wmf51Path
        }
    }
    Add-PackageToWim @updateWimParams

    Write-Output "Adding updates from Win12 updates path to image"
    $win12Updates = Get-ChildItem $win12UpdatesPath
    $win12UpdatesDestinationPath = Join-Path -Path $ImageMountPath -ChildPath "Windows\Temp"
    foreach ($update in $win12Updates)
    {
        Copy-Item -Path $win12UpdatesPath -Destination $win12UpdatesDestinationPath -Force -Recurse -ErrorAction Stop
    }
}

Write-Output "Adding Updates to image"
$updateWimParams = @{
    WimPath           = $wimPath
    ImageMountPath    = $imageMountPath
    WsusRepoDirectory = "$workspacePath\updaterepo"
    ServerVersion     = $serverVersion
}
$retryUpdates = Install-UpdateListToWim @updateWimParams

Write-Output "Unmounting Image"
$wimLogPath = Join-Path -Path (Split-Path -Path $wimPath -Parent) -ChildPath "DismountErrors-$(Get-Date -Format yyyyMMdd).log"
#Dism command used below because I just could NOT seem to get the PS cmdlet following to actually save the image with the packages
& Dism.exe /Unmount-Image /MountDir:$imageMountPath /Commit /LogLevel:1 /LogPath:$wimLogPath
#$null = Dismount-WindowsImage -Path $ImageMountPath -Save -LogPath $wimLogPath -Append -LogLevel Errors -ErrorAction Stop

#since we typically only deploy the target index ($imageIndex) from the image, export that as the final target wim
Write-Output "Exporting target index from image"
#Removing item below so as not to introduce multiple images into the WIM
$null = Remove-Item -Path $exportedWimPath -Force -Confirm:$false
$null = Export-WindowsImage -SourceImagePath $wimPath -CheckIntegrity -DestinationImagePath $exportedWimPath -SourceIndex $imageIndex -ErrorAction Stop

Write-Output "Creating VHDx at $VhdPath"
$newVHDxParams = @{
    LocalVhdPath       = $VhdPath
    VhdSize            = $vhdSizeGB
    VHDDType           = "Dynamic"
    WimPath            = $exportedWimPath
    ImageIndex         = 1 #only a single image after export
    ClobberVHDx        = $true
    UnattendFilePath   = "$workspacePath\unattend.xml"
    DismountVHDx       = $true
}
New-VHDxFromWim @newVHDxParams
