function Invoke-BuildUpdate
{
    param
    (
        [parameter()]
        [ValidateSet("Microsoft Server operating system-22H2", "Windows Server 2019 SERVERDATACENTER", "Windows Server 2019 SERVERSTANDARD")]
        [string]
        $ServerVersion,

        [parameter()]
        [ValidateScript({Test-Path $_})]
        [string]
        $WorkspacePath,

        [parameter()]
        [ValidateScript({Test-Path $_})]
        [string]
        $IsoPath,

        [parameter()]
        [string]
        $WimDestinationPath,

        [parameter()]
        [string]
        $ExportedWimPath,

        [parameter()]
        [string]
        $ImageMountPath,

        [parameter()]
        [int]
        $ImageIndex,

        [parameter()]
        [string]
        $UpdateRepoDirectory,

        [parameter(<#ParameterSetName = "UpdateInjection"#>)]
        [ValidateScript({Test-Path $_})]
        [string]
        $Wmf51Path,

        [parameter(<#ParameterSetName = "AnswerFileInjection"#>)]
        [string]
        $WindowsProductKey,

        [parameter()]
        [ValidateScript({Test-Path $_})]
        [string]
        $UnattendFilePath,

        [parameter()]
        [ValidateScript({Test-Path $_})]
        [string]
        $AutounattendFilePath,

        [parameter()]
        [ValidateScript({Test-Path $_})]
        [string]
        $DriverDirectoryPath,

        [parameter()]
        [ValidateScript({Test-Path $_})]
        [string]
        $OscdimgPath,

        [parameter()]
        [string]
        $IsoContentsPath,

        [parameter()]
        [string]
        $IsoDestinationPath,

        [parameter()]
        [string]
        $VhdPath,

        [parameter()]
        [int64]
        $VhdSizeGB,

        [parameter()]
        [switch]
        $InstallWSUS,

        [parameter()]
        [switch]
        $CopyWimFromIso = $false,

        [parameter(<#ParameterSetName = "UpdateInjection"#>)]
        [switch]
        $InjectUpdates,

        [parameter(<#ParameterSetName = "DriverInjection"#>)]
        [switch]
        $InjectDrivers,

        [parameter(<#ParameterSetName = "AnswerFileInjection"#>)]
        [switch]
        $InjectAnswerFiles,

        [parameter(<#ParameterSetName = "VHDxGeneration"#>)]
        [switch]
        $GenerateVHDx,

        [parameter(<#ParameterSetName = "IsoGeneration"#>)]
        [switch]
        $GenerateIso
    )

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

    if ($CopyWimFromIso)
    {
        Write-Output "Copying Wim from ISO: $IsoPath"
        $copyWimParams = @{
            IsoPath            = $IsoPath
            WimDestinationPath = $WimDestinationPath
        }
        Copy-WimFromISO @copyWimParams
    }

    if ($InjectUpdates -or $injectDrivers -or $InjectAnswerFiles)
    {
        Write-Output "Mounting image ($WimDestinationPath) at $ImageMountPath"
        $logPath = Join-Path -Path (Split-Path -Path $WimDestinationPath -Parent) -ChildPath "DismountErrors-$(Get-Date -Format yyyyMMdd).log"
        $params = @{
            ImagePath      = $WimDestinationPath
            ImageMountPath = $ImageMountPath
            Index          = $ImageIndex
            LogPath        = $logPath
            Mount          = $true
        }
        $imageInfo = Assert-WindowsImageMounted @params
        Add-PackageToWim @updateWimParams
    }

    if ($InjectUpdates)
    {
        Write-Output "  Adding Updates to image"
        $updateWimParams = @{
            WimPath           = $WimDestinationPath
            ImageMountPath    = $ImageMountPath
            WsusRepoDirectory = $UpdateRepoDirectory
            ServerVersion     = $serverVersion
        }
        Install-UpdateListToWim @updateWimParams
    }

    if ($InjectDrivers)
    {
        $injectDriverParams = @{
            ImageMountPath      = $ImageMountPath
            DriverDirectoryPath = $DriverDirectoryPath
        }
        Add-DriverToWim @injectDriverParams
    }

    if ($InjectAnswerFiles)
    {
        if (! $WindowsProductKey)
        {
            Write-Output "  Injecting $UnattendFilePath to $unattendDestinationPath"
            $kmsActivationKeys = @(
                @{
                    Name = "Windows Server 2022 Datacenter"
                    Key  = "WX4NM-KYWYW-QJJR4-XV3QB-6VM33"
                }
                @{
                    Name = "Windows Server 2022 Standard"
                    Key  = "VDYBN-27WPP-V4HQT-9VMD4-VMK7H"
                }
                @{
                    Name = "Windows Server 2019 SERVERDATACENTER"
                    Key  = "WMDGN-G9PQG-XVVXX-R3X43-63DFG"
                }
                @{
                    Name = "Windows Server 2019 SERVERSTANDARD"
                    Key  = "N69G4-B89J2-4G8F4-WWYCC-J464C"
                }
            )

            $WindowsProductKey = $kmsActivationKeys.Where({$imageInfo.ImageName -like "$($_.Name)*"}).Key
            if ([string]::IsNullOrEmpty($WindowsProductKey) -or $WindowsProductKey.Count -ne 1)
            {
                throw "Could not assume product key from image name: $($imageInfo.ImageName)."
            }
        }

        [xml]$unattendContents = Get-Content -Path $UnattendFilePath
        $unattendContents.GetElementsByTagName("ProductKey").ForEach({ $_.InnerText = $WindowsProductKey })

        $unattendDestinationPath = Join-Path -Path $ImageMountPath -ChildPath "Windows\System32\Sysprep\unattend.xml"
        Write-Verbose "Saving $UnattendFilePath with Product key ($WindowsProductKey) injected."
        $unattendContents.Save($unattendDestinationPath)
    }

    Write-Output "Dismounting image at $ImageMountPath"
    $params = @{
        ImagePath      = $WimDestinationPath
        ImageMountPath = $ImageMountPath
        Index          = $ImageIndex
        LogPath        = $logPath
        Dismount       = $true
    }
    Assert-WindowsImageMounted @params

    #since we typically only deploy the target index ($ImageIndex) from the image, export that as the final target wim
    Write-Output "Exporting target index $ImageIndex from image $WimDestinationPath"
    #Removing item below so as not to introduce multiple images into the WIM
    $null = Remove-Item -Path $exportedWimPath -Force -Confirm:$false
    $null = Export-WindowsImage -SourceImagePath $WimDestinationPath -CheckIntegrity -DestinationImagePath $exportedWimPath -SourceIndex $ImageIndex -ErrorAction Stop

    if ($GenerateVHDx)
    {
        Write-Output "Creating VHDx at $VhdPath"
        $newVHDxParams = @{
            VhdPath      = $VhdPath
            VhdSize      = $vhdSizeGB
            VHDDType     = "Dynamic"
            WimPath      = $exportedWimPath
            ImageIndex   = 1 #only a single image after export
            ClobberVHDx  = $true
            DismountVHDx = $true
        }
        New-VHDxFromWim @newVHDxParams
    }

    if ($GenerateIso)
    {
        Write-Output "Creating ISO at $IsoDestinationPath"
        $newIsoParams = @{
            OscdimgPath          = $OscdimgPath
            IsoPath              = $IsoPath
            IsoContentsPath      = $IsoContentsPath
            IsoLabel             = $ServerVersion.Replace(" ","")
            WimPath              = $exportedWimPath
            IsoDestinationPath   = $IsoDestinationPath
            AutounattendFilePath = $AutounattendFilePath
            WindowsProductKey    = $WindowsProductKey
        }
        New-IsoFromWim @newIsoParams
    }
}

<#
    .SYNOPSIS
        Copies the Windows image (install.wim) from a Windows Server ISO.

    .DESCRIPTION
        Copies $:\sources\install.wim from a Windows Server ISO to a specified local path.

    .PARAMETER IsoPath
        Path to the target Windows Server ISO.

    .PARAMETER WimDestinationPath
        Full path to which the Windows image will be copied.

    .Example
        $copyWimParams = @{
            IsoPath            = "$workspacePath\osimages\win19\en_windows_server_2019_x64_dvd_11636701.iso"
            WimDestinationPath = "$workspacePath\osimages\win19\install.wim"
        }
        Copy-WimFromISO @copyWimParams
#>
function Copy-WimFromISO
{
    param(
        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $IsoPath,

        [parameter(Mandatory)]
        [ValidatePattern(".*\.wim$")]
        [string]
        $WimDestinationPath
    )

    $wimParentPath = Split-Path -Path $WimDestinationPath -Parent

    if (! (Test-Path $wimParentPath))
    {
        $null = New-Item -Path $wimParentPath -ItemType Directory -Force -ErrorAction Stop
    }

    $mountResult = Mount-DiskImage $IsoPath -PassThru -StorageType ISO -ErrorAction Stop | Get-Volume
    $sourceWimPath = "$($mountResult.DriveLetter):\sources\install.wim"
    try
    {
        $null = & xcopy.exe $sourceWimPath $wimParentPath /R /Y /J
        Set-ItemProperty $WimDestinationPath -Name "IsReadOnly" -Value $false
    }
    finally
    {
        Dismount-DiskImage -ImagePath $IsoPath
    }
}

<#
    .SYNOPSIS
        Attempts to add a Windows package to a Windows image.

    .DESCRIPTION
        Receives a list of updates and file paths, and attempts to add them to a mounted Windows Image. Updates are logged as
        either success, unnecessary, or failed depending on the results of the Add-WindowsPackage cmdlet.

    .PARAMETER WimPath
        Path to set as the desired WSUS Update repository.

    .PARAMETER ImageMountPath
        Directory to which the image will be mounted.

    .PARAMETER UpdateFileList
        Hashtable array of update/packages to install. There are 2 keys: ID and FilePath. ID is used for the logging,
        FilePath points to the package file.

    .EXAMPLE
        $packageToWimParams = @{
            WimPath        = $WimPath
            ImageMountPath = $ImageMountPath
            UpdateFileList = @{
                ID       = "KB300XXXX"
                FilePath = "C:\Library\deploy\updatewim\updaterepo\WsusContent\0C\D28266C0C18747BB4A6CE1380C40A2A573A4AB0C.cab"
            }
        }
        Add-PackageToWim @packageToWimParams
#>
function Add-PackageToWim
{
    param
    (
        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WimPath,

        [parameter(Mandatory)]
        [string]
        $ImageMountPath,

        [parameter(Mandatory)]
        [hashtable[]]
        $UpdateFileList
    )

    $updateLogPath = Join-Path -Path $ImageMountPath -ChildPath "Windows\Temp\InstalledUpdates-$(Get-Date -Format yyyyMMdd).log"
    $failedUpdates = @()

    foreach ($update in $UpdateFileList)
    {
        Write-Verbose "Adding Update $($update.ID) from $($update.FilePath) to image path $ImageMountPath"
        try
        {
            $null = Add-WindowsPackage -PackagePath $update.FilePath -Path $ImageMountPath -WarningAction Ignore
            "Update $($update.ID) added successfully" | Tee-Object -FilePath $updateLogPath -Append
        }
        catch
        {
            $packageError = $_

            if ($packageError.Exception.Message.Contains("0x800f081e"))
            {
                "Update $($update.ID) not applicable" | Tee-Object -FilePath $updateLogPath -Append
            }
            else
            {
                "Update $($update.ID) not added. Error: $packageError" | Tee-Object -FilePath $updateLogPath -Append
                $failedUpdates = $update
            }
        }
    }

    Copy-Item -Path $updateLogPath -Destination (Split-Path -Path $WimPath -Parent)

    #return $failedUpdates
}

<#
    .SYNOPSIS
        Attempts to add drivers from a specified directory to a Windows image.

    .DESCRIPTION
        This function will attempt to recurse through a specified directory to add any drivers found to the specified image mount path.

    .PARAMETER ImageMountPath
        Directory the image is mounted.

    .PARAMETER DriverDirectoryPath
        Path to the folder with the drivers to inject into the wim

    .EXAMPLE
        $packageToWimParams = @{
            ImageMountPath = $ImageMountPath
            DriverDirectoryPath = $DriverDirectoryPath
        }
        Add-DriverToWim @packageToWimParams
#>
function Add-DriverToWim
{
    param
    (
        [parameter(Mandatory)]
        [string]
        $ImageMountPath,

        [parameter(Mandatory)]
        [string]
        $DriverDirectoryPath
    )

    $logPath = Join-Path -Path $ImageMountPath -ChildPath "Windows\Temp\InstalledDrivers-$(Get-Date -Format yyyyMMdd).log"

    Write-Verbose "Adding Drivers from $DriverDirectoryPath to image path $ImageMountPath"
    $null = Add-WindowsDriver -Path $ImageMountPath -Driver $DriverDirectoryPath -Recurse -ErrorAction Stop -LogPath $logPath -LogLevel Errors
}

<#
    .SYNOPSIS
        Installs a list of updates to a specified image.

    .DESCRIPTION
        Mounts a Windows image (.Wim file), and applies a list of specified updates gathered from a WSUS server.
        Update installation success is appended to a file on the root of the mounted image to keep a record of
        updates applied to the image.

    .PARAMETER WimPath
        Path to set as the desired WSUS Update repository.

    .PARAMETER ImageIndex
        A number (acceptable range "1-9") to specify which image index to apply.

    .PARAMETER ImageMountPath
        Directory to which the image will be mounted.

    .PARAMETER WsusRepoDirectory
        Path to set as the desired WSUS Update repository.

    .PARAMETER ServerVersion
        Choose either Windows Server 2022 or 2019 as the product version to return updates.

    .Example
        $updateWimParams = @{
            WimPath           = "$workspacePath\osimages\win16\install.wim"
            ImageIndex        = 1
            ImageMountPath    = "$workspacePath\osimages\mount"
            WsusRepoDirectory = "$workspacePath\updaterepo"
            ServerVersion     = "Windows Server 2019"
        }
        Install-UpdateListToWim @updateWimParams -Verbose
#>
function Install-UpdateListToWim
{
    param(
        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WimPath,

        [parameter(Mandatory)]
        [string]
        $ImageMountPath,

        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WsusRepoDirectory,

        [parameter(Mandatory)]
        [ValidateSet("Microsoft Server operating system-22H2", "Windows Server 2019 SERVERDATACENTER", "Windows Server 2019 SERVERSTANDARD")]
        [string]
        $ServerVersion
    )
    #requires -Module Dism

    $updateFileList = Get-SelfContainedApprovedUpdateFileList -WsusRepoDirectory $WsusRepoDirectory -ServerVersion $ServerVersion -ErrorAction Stop

    Write-Verbose "Adding packages to Wim"
    $packageToWimParams = @{
        WimPath        = $WimPath
        ImageMountPath = $ImageMountPath
        UpdateFileList = $updateFileList
    }
    Add-PackageToWim @packageToWimParams

    #return $failedPackages
}

<#
    .SYNOPSIS
        Returns a list of the approved & self-contained updates' file paths.

    .DESCRIPTION
        Returns an array of hashtables containing the ID and filepath of all approved, self-contained
        updates for Windows Server 2022 or 2019.

    .PARAMETER WsusRepoDirectory
        Path to set as the desired WSUS Update repository.

    .PARAMETER ServerVersion
        Choose either Windows Server 2022 or 2019 as the product version to return updates.

    .Example
        Get-SelfContainedApprovedUpdateFileList -WsusRepoDirectory "$workspacePath\updatewim\updaterepo" -ServerVersion "Windows Server 2019"
#>
function Get-SelfContainedApprovedUpdateFileList
{
    param(
        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WsusRepoDirectory,

        [parameter(Mandatory)]
        [ValidateSet("Microsoft Server operating system-22H2", "Windows Server 2019 SERVERDATACENTER", "Windows Server 2019 SERVERSTANDARD")]
        [string]
        $ServerVersion
    )

    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530 -ErrorAction Stop
    $approvedUpdates = Get-WsusUpdate -UpdateServer $wsusServer -Approval Approved -Verbose:$false

    $approvedServerVersionUpdates = $approvedUpdates.Where({$_.Products -eq $ServerVersion})

    if ("NotReady" -in $approvedServerVersionUpdates.Update.State)
    {
        throw "Not all updates are finished downloading. Please try again later :)"
    }

    if ($approvedServerVersionUpdates.Count -eq 0)
    {
        throw "No updates to approve were found for '$ServerVersion'. Please try a different Version."
    }

    $supportedUpdates = $approvedServerVersionUpdates.Update.GetInstallableItems().Files.Where({$_.Type -eq "SelfContained" -or $_.Type -eq "None"})

    $approvedUpdateList = $supportedUpdates.foreach({
        @{
            ID       = $_.Name
            FilePath = Join-path -Path $WsusRepoDirectory -ChildPath $($_.FileUri.LocalPath.replace("/Content","/WsusContent"))
        }
    })

    $injectableUpdateList = $approvedUpdateList.where({$_.FilePath -notlike "*.exe"})

    $injectableUpdateList.FilePath.ForEach({
        if (! (Test-Path $_))
        {
            throw "Update file not found at $_"
        }
    })

    return $injectableUpdateList
}

<#
    .SYNOPSIS
        Creates a VHDx from a Wim.

    .DESCRIPTION
        Creates a new VHDX virtual disk, initializes and partitions the disk, the applies the desired
        WIM to the VHDx, and makes the disk bootable from a Gen 2 Hyper-V VM.

    .PARAMETER LocalVhdPath
        Path to create the new VHDx locally.

    .PARAMETER VhdSize
        Size in GB for the target VHDx.

    .PARAMETER VHDDType
        Specifies whether the VHDx is dynamic or fixed.

    .PARAMETER BootDriveLetter
        A single character to use as the target System ("boot") Volume drive letter.

    .PARAMETER OBDriveLetter
        A single character to use as the target Windows Volume drive letter.

    .PARAMETER WindowsVolumeLabel
        Label to be applied to the Windows Volumate.

    .PARAMETER WimPath
        Path to the WIM to be applied.

    .PARAMETER ImageIndex
        A number (acceptable range "1-9") to specify which image index to apply.

    .PARAMETER ClobberVHDx
        Removes the VHDx if there is one located at the LocalVhdPath.

    .PARAMETER DismountVHDx
        Dismounts the VHDx if switch is present.

    .Example
        $newVHDxParams = @{
            LocalVhdPath       = "C:\VHDs\win2019-$(Get-Date -Format yyyyMMdd).vhdx"
            VhdSize            = 21GB
            WindowsVolumeLabel = "OSDisk"
            VHDDType           = "Dynamic"
            BootDriveLetter    = "S"
            OSDriveLetter      = "V"
            WimPath            = "$workspacePath\osimages\win19\install.wim"
            ImageIndex         = 1
            ClobberVHDx        = $true
            DismountVHDx       = $true
        }
        New-VHDxFromWim @newVHDxParams
#>
function New-VhdxFromWim
{
    param(
        [parameter(Mandatory)]
        [string]
        $VhdPath,

        [parameter(Mandatory)]
        [double]
        $VhdSize,

        [parameter(Mandatory)]
        [ValidateSet("Dynamic","Fixed")]
        [string]
        $VHDDType,

        [parameter()]
        [string]
        $WindowsVolumeLabel = "OSDrive",

        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WimPath,

        [parameter(Mandatory)]
        [ValidatePattern("[1-9]")]
        [int]
        $ImageIndex,

        [parameter()]
        [switch]
        $ClobberVHDx,

        [parameter()]
        [switch]
        $DismountVHDx
    )

    #Don't use the requires statement, because this is the only function that requires the following modules
    if (! (Get-Module -Name Hyper-V,Dism))
    {
        throw "This function requires the Hyper-V and DISM modules."
    }

    if ($ClobberVHDx -and (Test-Path -Path $VhdPath))
    {
        Write-Verbose "Clobbering existing VHD"
        Remove-Item $VhdPath -Force -ErrorAction Stop
    }

    Write-Verbose "Creating VHD at $VhdPath"
    if ($VHDDType -eq "Dynamic")
    {
        $null = New-VHD -Path $VhdPath -SizeBytes $VhdSize -Dynamic -ErrorAction Stop
    }
    else
    {
        $null = New-VHD -Path $VhdPath -SizeBytes $VhdSize -Fixed -ErrorAction Stop
    }

    #Mount the new VHDx, get the mounted disk number, and initialize as GPT
    Mount-DiskImage -ImagePath $VhdPath -ErrorAction Stop
    $mountedDisk = Get-DiskImage -ImagePath $VhdPath
    $mountedDiskNumber = $mountedDisk.Number
    $null = Initialize-Disk -Number $mountedDisk.Number -PartitionStyle GPT -ErrorAction Stop

    #region Partition the new VHDx
    Write-Verbose "Partitioning the VHDx"
    try
        {
        #System partition
        $systemPartition = New-Partition -DiskNumber $mountedDiskNumber -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -Size 499MB -Verbose
        $null = $systemPartition | Format-Volume -FileSystem FAT32 -Confirm:$false -Verbose
        $systemPartition | Set-Partition -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'

        #MSR Partition
        $null = New-Partition -DiskNumber $mountedDiskNumber -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' -Size 128MB

        #OS Partition
        $osPartition = New-Partition -DiskNumber $mountedDiskNumber -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}' -UseMaximumSize -Verbose
        $null = $osPartition | Format-Volume -FileSystem NTFS -NewFileSystemLabel $WindowsVolumeLabel -Confirm:$false -Verbose

        Add-PartitionAccessPath -DiskNumber $mountedDiskNumber -PartitionNumber $systemPartition.PartitionNumber -AssignDriveLetter
        $systemDrive = Get-Partition -DiskNumber $mountedDiskNumber -PartitionNumber $systemPartition.PartitionNumber
        Add-PartitionAccessPath -DiskNumber $mountedDiskNumber -PartitionNumber $osPartition.PartitionNumber -AssignDriveLetter
        $osDrive = Get-Partition -DiskNumber $mountedDiskNumber -PartitionNumber $osPartition.PartitionNumber
    }
    catch
    {
        Dismount-DiskImage -ImagePath $VhdPath
        break
    }
    #endregion Partition the new VHDx

    Write-Verbose "Applying Wim to VHDD"
    $osDriveRootPath = "$($osDrive.DriveLetter):"
    $null = Expand-WindowsImage -ImagePath $WimPath -ApplyPath $osDriveRootPath -Index $ImageIndex -ErrorAction Stop

    #Copy boot files from the now applied image in the Windows partition to the System partition using bcdboot
    $null = & "$("$($osDrive.DriveLetter):\Windows\System32\bcdboot.exe")" $("$osDriveRootPath\Windows") /s "$($systemDrive.DriveLetter):" /F UEFI

    if ($DismountVHDx)
    {
        Write-Verbose "Dismounting VHDD"
        Dismount-DiskImage -ImagePath $VhdPath
    }
}

<#
    .SYNOPSIS
        Creates an ISO from the contents of an existing ISO and a specified Wim.

    .DESCRIPTION
        Copies the contents of a specified

    .PARAMETER OscdimgPath
        Path to the WADK utility osdcimg.exe, which can be installed via the WADK.

    .PARAMETER IsoPath
        Path to the ISO from which to copy bootable ISO media contents.

    .PARAMETER IsoContentsPath
        Path to the directory that will contain the contents of the ISO with the updated WIM.

    .PARAMETER IsoDestinationPath
        Path to export the resulting ISO.

    .PARAMETER IsoLabel
        The label to attach to the resulting ISO image.

    .PARAMETER WimPath
        Path to the WIM to be applied.

    .EXAMPLE
        $newIsoParams = @{
            OscdimgPath          = "$WorkspacePath\Oscdimg\oscdimg.exe"
            IsoPath              = "C:\Library\ISOs\en_windows_server_2019_updated_feb_2018_x64_dvd_11636692.iso"
            IsoContentsPath      = "$WorkspacePath\ISOContents"
            IsoLabel             = "Win2K19DC"
            WimPath              = "$workspacePath\wimrepo\win2019\install.optimized.wim"
            IsoDestinationPath   = "$WorkspacePath\Win2K16DC-$(Get-Date -Format yyyyMMdd).iso"
        }
        New-IsoFromWim @newIsoParams
#>
function New-IsoFromWim
{
    param
    (
        [parameter()]
        [ValidateScript({Test-Path $_})]
        [string]
        $OscdimgPath,

        [parameter()]
        [ValidateScript({Test-Path $_})]
        [string]
        $IsoPath,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $IsoContentsPath,

        [parameter()]
        [string]
        $IsoDestinationPath,

        [parameter()]
        [string]
        $IsoLabel,

        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WimPath,

        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $AutounattendFilePath,

        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $WindowsProductKey
    )

    if (-Not (Test-Path -Path $IsoContentsPath))
    {
        $null = New-Item -Path $IsoContentsPath -Type Directory -Force
    }

    $iso = Get-DiskImage -ImagePath $IsoPath -StorageType ISO
    if (! ($iso.Attached))
    {
        $driveLetter = (Mount-DiskImage $IsoPath -PassThru -StorageType ISO -ErrorAction Stop | Get-Volume).DriveLetter
    }
    else
    {
        $driveLetter = (Get-Volume -DiskImage $iso -ErrorAction Stop).DriveLetter
    }

    #Copy-Item -Path "$($driveLetter):\*" -Destination $IsoContentsPath -Exclude "install.wim" -Recurse -Force
    "${driveLetter}:\Sources\install.wim" > "$Env:TEMP\xcopyexclude.txt"
    $null = & xcopy.exe "${driveLetter}:\" "$IsoContentsPath\*" /R /Y /E /EXCLUDE:"$Env:TEMP\xcopyexclude.txt"
    Remove-Item -Path "$Env:TEMP\xcopyexclude.txt" -Force -ErrorAction Stop

    $null = Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop

    $autounattendDestinationPath = Join-Path -Path $IsoContentsPath -ChildPath "Autounattend.xml"
    Write-Output "Injecting $AutounattendFilePath to $autounattendDestinationPath"
    [xml]$autounattendContents = Get-Content -Path $AutounattendFilePath
    $autounattendContents.GetElementsByTagName("ProductKey").ForEach({ $_.Key = $WindowsProductKey })

    Write-Output "Saving $AutounattendFilePath with $WindowsProductKey injected."
    $autounattendContents.Save($autounattendDestinationPath)

    #Copy-Item -Path $WimPath -Destination (Join-Path -Path $IsoContentsPath -ChildPath "Sources\install.wim") -Force
    Write-Output "  Copying $WimPath to ISO Contents folder $(Join-Path -Path $IsoContentsPath -ChildPath "Sources\install.wim")"
    $null = & xcopy.exe $WimPath "$(Join-Path -Path $IsoContentsPath -ChildPath "Sources\install.wim")*" /R /Y /E

    $bootFilePath = Join-Path -Path $IsoContentsPath -ChildPath "efi\microsoft\boot\efisys.bin"
    if (! (Test-Path $bootFilePath))
    {
        throw "Boot file (efisys.bin) not found in ISO contents - CD cannot be made bootable."
    }
    try
    {
        Write-Output "  Running $OscdimgPath to generate ISO at $IsoDestinationPath"
        $sb = [scriptblock]::Create(". '$OscdimgPath' -u2 -b$bootFilePath $IsoContentsPath $IsoDestinationPath")
        $null = $sb.Invoke()
    }
    catch
    {
        throw "Could not create ISO"
    }
}

<#
    .SYNOPSIS
        Attempts to add a Windows package to a Windows image.

    .DESCRIPTION
        Receives a list of updates and file paths, and attempts to add them to a mounted Windows Image. Updates are logged as
        either success, unnecessary, or failed depending on the results of the Add-WindowsPackage cmdlet.

    .PARAMETER ImagePath
        Path to the Windows Image.

    .PARAMETER ImageMountPath
        Directory to which the image will be mounted.

    .PARAMETER UpdateFileList
        Hashtable array of update/packages to install. There are 2 keys: ID and FilePath. ID is used for the logging,
        FilePath points to the package file.

    .EXAMPLE
        $wimParams = @{
            WimPath        = $WimPath
            ImageMountPath = $ImageMountPath
            UpdateFileList = @{
                ID       = "KB300XXXX"
                FilePath = "C:\Library\deploy\updatewim\updaterepo\WsusContent\0C\D28266C0C18747BB4A6CE1380C40A2A573A4AB0C.cab"
            }
        }
        Assert-WindowsImageMounted @wimParams
#>
function Assert-WindowsImageMounted
{
    param
    (
        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $ImagePath,

        [parameter(Mandatory)]
        [int]
        $Index,

        [parameter(Mandatory)]
        [string]
        $ImageMountPath,

        [parameter(ParameterSetName='Mount')]
        [parameter(ParameterSetName='Dismount')]
        $LogPath,

        [parameter(ParameterSetName='Mount')]
        [switch]
        $Mount = $true,

        [parameter(ParameterSetName='Dismount')]
        [switch]
        $Dismount,

        [parameter(ParameterSetName='Dismount')]
        [switch]
        $Save = $true
    )

    if (! (Test-Path $ImageMountPath))
    {
        $null = New-Item -Path $ImageMountPath -ItemType "Directory" -ErrorAction Stop
    }

    $params = @{
        Path = $ImageMountPath
        LogPath = $LogPath
        ErrorAction = "Stop"
    }

    if ($Dismount)
    {
        if ($Save)
        {
            $null = & Dism.exe /Unmount-Image /MountDir:$ImageMountPath /Commit /LogLevel:1 /LogPath:$LogPath
        }
        else
        {
            $null = & Dism.exe /Unmount-Image /MountDir:$ImageMountPath /Discard /LogLevel:1 /LogPath:$LogPath

        }
        return
    }

    $wimInfo = Get-WindowsImage -ImagePath $ImagePath -Index $Index -ErrorAction Stop
    $mountedWims = Get-WindowsImage -Mounted

    if ($ImagePath -notin $mountedWims.ImagePath)
    {
        $params += @{ ImagePath = $ImagePath }
        $params += @{ Index = $Index }
        Write-Verbose "Image not mounted"
        try
        {
            $null = Mount-WindowsImage @params
            $wimInfo = Get-WindowsImage -ImagePath $ImagePath -Index $Index -ErrorAction Stop
        }
        catch
        {
           throw "Could not mount Windows image at $ImagePath. Check for invalid mount point by running 'dism /cleanup-wim'"
        }
    }

    return $wimInfo
}

<#
    .SYNOPSIS
        Installs and configures the UpdateServices (WSUS) Windows feature.

    .DESCRIPTION
        Installs the UpdateServices (WSUS) Windows feature, completes the postinstall tasks, including
        specifying the update repository directory, setting the update language, and initiating the first sync
        to the Microsoft Update Catalog.

    .PARAMETER WsusRepoDirectory
        Path to set as the desired WSUS Update repository.

    .PARAMETER UpdateLanguageCode
        Two letter code to use for the update language.

    .Example
        Install-WSUS -WsusRepoDirectory "$workspacePath\updaterepo" -UpdateLanguageCode "en"
#>
function Install-WSUS
{
    param(
        [parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $WsusRepoDirectory,

        [parameter(Mandatory)]
        [ValidatePattern("[a-zA-Z]{2}")]
        [string]
        $UpdateLanguageCode
    )

    if (! (Test-Path $WsusRepoDirectory))
    {
        $null = New-Item -Path $WsusRepoDirectory -ItemType Directory -Force -ErrorAction Stop
    }

    #Check for existing installation of WSUS and exit if exists
    if ((Get-WindowsFeature -Name "UpdateServices").Installed)
    {
        Write-Warning "WSUS role already installed, exiting."
        break
    }

    Install-WindowsFeature -Name "UpdateServices" -IncludeManagementTools -ErrorAction Stop

    & 'C:\Program Files\Update Services\Tools\wsusutil.exe' postinstall CONTENT_DIR=$WsusRepoDirectory

    Set-WsusServerSynchronization -SyncFromMU

    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530

    $wsusConfiguration = $wsusServer.GetConfiguration()
    $wsusConfiguration.SetEnabledUpdateLanguages($UpdateLanguageCode)
    $wsusConfiguration.AllUpdateLanguagesEnabled = $false
    $wsusConfiguration.Save()

    # $wsusSubscription = $wsusServer.GetSubscription()
    # $wsusSubscription.StartSynchronization()
}

<#
    .SYNOPSIS
        Configures WSUS to download specific product updates.

    .DESCRIPTION
        This function will remove all products but the ones specified in the ProductIDList parameter 
        from the WSUS configuration. ProductIDList below contains Windows Server 2022 (22H2) & 2019.
        ProductID for Microsoft Server operating system-22H2 is 2c7888b6-f9e9-4ee9-87af-a77705193893
    .Example
        Set-WsusConfiguration
#>
function Set-WsusConfiguration
{
    param
    (
        [Parameter()]
        [string[]]
        $ProductIDList = @("2c7888b6-f9e9-4ee9-87af-a77705193893", "f702a48c-919b-45d6-9aef-ca4248d50397") #, "f702a48c-919b-45d6-9aef-ca4248d50397", "569e8e8f-c6cd-42c8-92a3-efbb20a0f6f5") #, "d31bd4c3-d872-41c9-a2e7-231f372588cb")
    )

    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530
    $wsusProductList = Get-WsusProduct -UpdateServer $wsusServer
    $productsToEnable = $wsusProductList.Where({$_.Product.ID -in $ProductIDList})
    $wsusProductList.ForEach({if ($_.Product.ID -notin $ProductIDList) { [Microsoft.UpdateServices.Commands.WsusProduct[]]$productsToDisable += $_ }})

    #Disable all products not specified
    $productsToDisable.ForEach({Set-WsusProduct -Product $_ -Disable})

    #Enable products specified
    $productsToEnable.ForEach({Set-WsusProduct -Product $_})

    # $wsusSubscription = $wsusServer.GetSubscription()

    # $wsusSubscription.StartSynchronization()
}

<#
    .SYNOPSIS
        Enables upates for the specified WSUS product IDs.

    .DESCRIPTION
        This function will approve all non-superseded (latest) updates for the All Computers group for any 
        WSUS product ID passed in. It will deny any other updates, so the list of product IDs should be 
        exhaustively inclusive of all products to approve. Defaults to localhost for WsusServerName 
        and Windows Server 2022 & 2019.

    .Example
        Set-EnabledProductUpdateApproval
#>
function Set-EnabledProductUpdateApproval
{
    param
    (
        [Parameter()]
        [string]
        $WsusServerName = "localhost",

        [Parameter()]
        [string[]]
        $ProductIDList = @("2c7888b6-f9e9-4ee9-87af-a77705193893", "f702a48c-919b-45d6-9aef-ca4248d50397") #, "f702a48c-919b-45d6-9aef-ca4248d50397", "569e8e8f-c6cd-42c8-92a3-efbb20a0f6f5") #, "d31bd4c3-d872-41c9-a2e7-231f372588cb")
    )

    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530

    $wsusSubscription = $wsusServer.GetSubscription()
    $wsusSubscription.StartSynchronization()
    while (($wsusSubscription.GetSynchronizationStatus()) -eq 'Running')
    {
        Start-Sleep -Seconds 5
        Write-Output $wsusSubscription.GetSynchronizationProgress()
    }

    Write-Verbose "Gathering updates, this will take some time"
    $updateList = Get-WsusUpdate -UpdateServer $wsusServer -Status Any -Approval AnyExceptDeclined
    $updateList += Get-WsusUpdate -UpdateServer $wsusServer -Status Any -Approval Declined

    Write-Verbose "Retrieving list of specified products from IDs"
    $wsusProductList = Get-WsusProduct -UpdateServer $wsusServer
    $productsToEnable = $wsusProductList.Where({$_.Product.ID -in $ProductIDList})
    $enabledProductNames = $productsToEnable.Product.Title

    Write-Verbose "Setting Updates for non-specified products to declined"
    $updatesToApprove = $enabledProductNames.foreach({ $productName = $_ ; $updatelist.Where({$_.Products -like "*$productName*"})})

    $latestUpdates = $updatesToApprove.where({$_.update.IsSuperseded -eq $false})

    $updatesToDeny = $updatelist.Where({$_ -notin $latestUpdates})
    $updatesToDeny.ForEach({ Deny-WsusUpdate -Update $_ })

    $latestUpdates.ForEach({ Approve-WsusUpdate -Update $_ -Action Install -TargetGroupName "All Computers" })

    # $wsusSubscription = $wsusServer.GetSubscription()

    # $wsusSubscription.StartSynchronization()
}
