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
            IsoPath            = "$workspacePath\osimages\win16\en_windows_server_2016_x64_dvd_11636701.iso"
            WimDestinationPath = "$workspacePath\osimages\win16\install.wim"
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
    .PARAMETER UpdateFileList
        Hashtable array of update/packages to install.
    
    .EXAMPLE
        $UpdateFileList = @{
            ID       = ""
            FilePath = Join-path -Path $WsusRepoDirectory -ChildPath $($_.FileUri.LocalPath.replace("/Content","/WsusContent"))
        }
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
            "Update $($update.ID) added successfully" | Tee-Object -FilePath $updateLogPath
        }
        catch
        {
            $packageError = $_

            if ($packageError.Exception.Message.Contains("0x800f081e"))
            {
                "Update $($update.ID) not applicable" | Tee-Object -FilePath $updateLogPath
            }
            else
            {
                "Update $($update.ID) not added. Error: $packageError" | Tee-Object -FilePath $updateLogPath
                $failedUpdates = $update
            }
        }
    }

    Copy-Item -Path $updateLogPath -Destination (Split-Path -Path $WimPath -Parent)

    return $failedUpdates
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
        Choose either Windows Server 2016 or 2012 as the product version to return updates.

    .Example
        $updateWimParams = @{
            WimPath           = "$workspacePath\osimages\win16\install.wim"
            ImageIndex        = 1
            ImageMountPath    = "$workspacePath\osimages\mount"
            WsusRepoDirectory = "$workspacePath\updaterepo"
            ServerVersion     = "Windows Server 2016"
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
        [ValidateSet("Windows Server 2016","Windows Server 2012 R2")]
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
    $failedPackages = Add-PackageToWim @packageToWimParams

    return $failedPackages
}

<#
    .SYNOPSIS
        Returns a list of the approved & self-contained updates' file paths.

    .DESCRIPTION
        Returns an array of hashtables containing the ID and filepath of all approved, self-contained
        updates for Windows Server 2016 or 2012.

    .PARAMETER WsusRepoDirectory
        Path to set as the desired WSUS Update repository.

    .PARAMETER ServerVersion
        Choose either Windows Server 2016 or 2012 as the product version to return updates.

    .Example
        Get-SelfContainedApprovedUpdateFileList -WsusRepoDirectory "$workspacePath\updatewim\updaterepo" -ServerVersion "Windows Server 2012 R2"
#>
function Get-SelfContainedApprovedUpdateFileList
{
    param(
        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WsusRepoDirectory,

        [parameter(Mandatory)]
        [ValidateSet("Windows Server 2016","Windows Server 2012 R2")]
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
#>
function New-VhdxFromWim
{
    param(
        [parameter(Mandatory)]
        [string]
        $LocalVhdPath,
    
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
        [string]
        $UnattendFilePath,

        [parameter()]
        [switch]
        $DismountVHDx
    )

    #requires -Module Hyper-V, Dism -RunAsAdministrator

    if ($ClobberVHDx)
    {
        if (Test-Path -Path $LocalVhdPath)
        {
            Write-Verbose "Clobbering existing VHD"
            Remove-Item $LocalVhdPath -Force
        }
        else
        {
            Write-Verbose "$LocalVhdPath not found, so clobber no happen."
        }
    }
    
    Write-Verbose "Creating VHDx"
    try
    {
        if ($VHDDType -eq "Dynamic")
        {
            $null = New-VHD -Path $LocalVhdPath -SizeBytes $VhdSize -Dynamic -ErrorAction Stop
        }
        else
        {
            $null = New-VHD -Path $LocalVhdPath -SizeBytes $VhdSize -Fixed -ErrorAction Stop
        }
    }
    catch
    {
        throw "Could not create Virtual disk."
    }

    #Mount the new VHDx, get the mounted disk number, and initialize as GPT
    Mount-DiskImage -ImagePath $LocalVhdPath
    $mountedDisk = Get-DiskImage -ImagePath $LocalVhdPath
    $mountedDiskNumber = $mountedDisk.Number
    $null = Initialize-Disk -Number $mountedDisk.Number -PartitionStyle GPT

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
        Dismount-DiskImage -ImagePath $LocalVhdPath
        break
    }
    #endregion Partition the new VHDx

    Write-Verbose "Applying Wim to VHDD"
    $osDriveRootPath = "$($osDrive.DriveLetter):"
    $null = Expand-WindowsImage -ImagePath $WimPath -ApplyPath $osDriveRootPath -Index $ImageIndex -ErrorAction Stop

    #Copy boot files from the now applied image in the Windows partition to the System partition using bcdboot
    $null = & "$("$($osDrive.DriveLetter):\Windows\System32\bcdboot.exe")" $("$osDriveRootPath\Windows") /s "$($systemDrive.DriveLetter):" /F UEFI

    #Copy unattend file to mounted image
    if ($UnattendFilePath)
    {
        $null = & xcopy.exe $UnattendFilePath "$osDriveRootPath\Windows\System32\Sysprep" /R /Y /J
    }

    if ($DismountVHDx)
    {
        Write-Verbose "Dismounting VHDD"
        Dismount-DiskImage -ImagePath $LocalVhdPath
    }
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

    $wsusSubscription = $wsusServer.GetSubscription()
    $wsusSubscription.StartSynchronization()
}

<#
    .SYNOPSIS
        Configures WSUS to download only Windows 2016 & 2012 R2 updates.

    .DESCRIPTION
        This function will remove all products but Windows 2016 & 2012 R2 from the WSUS configuration.
        This is a temporary function that will be replaced with something more fully-featured.

    .Example
        Set-WsusConfiguration
#>
function Set-WsusConfiguration
{
    param
    (
        [Parameter()]
        [string[]]
        $ProductIDList = @("569e8e8f-c6cd-42c8-92a3-efbb20a0f6f5","d31bd4c3-d872-41c9-a2e7-231f372588cb")
    )
    
    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530
    $wsusProductList = Get-WsusProduct -UpdateServer $wsusServer
    $productsToEnable = $wsusProductList.Where({$_.Product.ID -in $ProductIDList})
    $wsusProductList.ForEach({if ($_.Product.ID -notin $ProductIDList) { [Microsoft.UpdateServices.Commands.WsusProduct[]]$productsToDisable += $_ }})

    #Disable all products not specified
    $productsToDisable.ForEach({Set-WsusProduct -Product $_ -Disable})

    #Enable products specified
    $productsToEnable.ForEach({Set-WsusProduct -Product $_})
    
    $wsusSubscription = $wsusServer.GetSubscription()

    $wsusSubscription.StartSynchronization()
}

function Set-EnabledProductUpdateApproval
{
    param
    (
        [Parameter()]
        [string[]]
        $ProductIDList = @("569e8e8f-c6cd-42c8-92a3-efbb20a0f6f5","d31bd4c3-d872-41c9-a2e7-231f372588cb")
    )

    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530
    Write-Verbose "Gathering updates, this will take some time"
    $updateList = Get-WsusUpdate -UpdateServer $wsusServer -Status Any -Approval AnyExceptDeclined
    $updateList += Get-WsusUpdate -UpdateServer $wsusServer -Status Any -Approval Declined

    $wsusProductList = Get-WsusProduct -UpdateServer $wsusServer
    $productsToEnable = $wsusProductList.Where({$_.Product.ID -in $ProductIDList})
    $enabledProductNames = $productsToEnable.Product.Title

    Write-Verbose "Setting Updates for non-specified products to declined"
    $updatesToApprove = $enabledProductNames.foreach({ $productName = $_ ; $updatelist.Where({$_.Products -like "*$productName*"})})

    <#if ("Windows Server 2016" -in $enabledProductNames)
    {
         $updatesToApprove = $updatesToApprove.where({$_.Update.Title -notlike "*(1709)*" -and $_.Update.Title -notlike "*(1803)*"})
    }#>

    $latestUpdates = $updatesToApprove.where({$_.update.IsSuperseded -eq $false})

    $updatesToDeny = $updatelist.Where({$_ -notin $latestUpdates})
    $updatesToDeny.ForEach({Deny-WsusUpdate -Update $_})

    $latestUpdates.ForEach({Approve-WsusUpdate -Update $_ -Action Install -TargetGroupName "All Computers"})
    
    $wsusSubscription = $wsusServer.GetSubscription()

    $wsusSubscription.StartSynchronization()
}