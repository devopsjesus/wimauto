
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
        [string]
        $WimDestinationPath
    )

    Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -ErrorAction Stop

    $mountedDiskImageLetter = (Get-Volume).where({$_.FileSystem -eq "UDF"}).DriveLetter

    Copy-Item -Path "${mountedDiskImageLetter}:\sources\install.wim" -Destination $WimDestinationPath -Force -ErrorAction Stop

    Set-ItemProperty $WimDestinationPath -Name "IsReadOnly" -Value $false

    Dismount-DiskImage -ImagePath $IsoPath
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
        [ValidatePattern("[1-9]")]
        [int]
        $ImageIndex,

        [parameter(Mandatory)]
        [string]
        $ImageMountPath,

        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WsusRepoDirectory,

        [parameter(Mandatory)]
        [ValidateSet("Windows Server 2016","Windows Server 2012")]
        [string]
        $ServerVersion
    )

    #requires -Module Dism

    $logPath = Join-Path -Path $ImageMountPath -ChildPath "InstalledUpdates-$(Get-Date -Format yyyyMMdd).log"

    if (! (Test-Path $ImageMountPath))
    {
        New-Item -Path $ImageMountPath -ItemType "Directory" -ErrorAction Stop
    }

    Mount-WindowsImage -ImagePath $WimPath -Index $ImageIndex -Path $ImageMountPath -ErrorAction Stop
    
    $updateFileList = Get-SelfContainedApprovedUpdateFileList -WsusRepoDirectory $WsusRepoDirectory -ServerVersion $ServerVersion

    foreach ($update in $updateFileList)
    {
        Write-Verbose "Adding Update $($update.ID) from $($update.FilePath) to image path $ImageMountPath"
        try
        {
            Add-WindowsPackage -PackagePath $update.FilePath -Path $ImageMountPath -WarningAction Ignore
            "Update $($update.ID) added successfully" >> $logname
        }
        catch
        {
            $packageError = $_

            if ($packageError.Exception.Message.Contains("0x800f081e"))
            {
                "Update $($update.ID) not applicable" >> $logname
            }
            else
            {
                "Update $($update.ID) not added. Error: $packageError" >> $logname
            }
        }
    }

    $wimLogPath = Join-Path -Path (Split-Path -Path $WimPath -Parent) -ChildPath "DismountErrors-$(Get-Date -Format yyyyMMdd).log"

    Dismount-WindowsImage -Path $ImageMountPath -Save -LogPath $wimLogPath -Append -LogLevel Errors
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
        Get-SelfContainedApprovedUpdateFileList -WsusRepoDirectory "$workspacePath\updaterepo" -ServerVersion "Windows Server 2016"
#>
function Get-SelfContainedApprovedUpdateFileList
{
    param(
        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WsusRepoDirectory,

        [parameter(Mandatory)]
        [ValidateSet("Windows Server 2016","Windows Server 2012")]
        [string]
        $ServerVersion
    )

    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530 -ErrorAction Stop
    $approvedUpdates = Get-WsusUpdate -UpdateServer $wsusServer -Approval Approved

    $approvedServerVersionUpdates = $approvedUpdates.Where({$_.Products -eq $ServerVersion})
    
    $approvedUpdateList = $approvedServerVersionUpdates.Update.foreach({
        @{
            ID    = $_.Id.UpdateId
            FilePath=$_.GetInstallableItems().Files.Where({$_.Type -eq "SelfContained"})
        }
    })

    $approvedUpdateList.ForEach({
    
        $updateFSPath = $_.FilePath.FileUri.LocalPath.replace("/Content","/WsusContent")
        $_.FilePath = Join-path -Path $WsusRepoDirectory -ChildPath $updateFSPath
    })

    $approvedUpdateList.FilePath.ForEach({
        if (! (Test-Path $_))
        {
            throw "Update file not found at $_"
        }
    })

    return $approvedUpdateList
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

        [parameter(Mandatory)]
        [ValidatePattern("[a-zA-Z]")]
        [string]
        $BootDriveLetter,

        [parameter(Mandatory)]
        [ValidatePattern("[a-zA-Z]")]
        [string]
        $OSDriveLetter,

        [parameter(Mandatory)]
        [string]
        $WindowsVolumeLabel,

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
            Write-Warning "$LocalVhdPath not found, so clobber no happen."
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
    Initialize-Disk -Number $mountedDisk.Number -PartitionStyle GPT

    #region Partition the new VHDx
    Write-Verbose "Partitioning the VHDx"
    #System partition
    $systemPartitionParams = @{
        DiskNumber  = $mountedDisk.Number
        Size        = 100MB
        GptType     = "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
        DriveLetter = $BootDriveLetter
    }
    $null = New-Partition @systemPartitionParams -ErrorAction Stop
    $null = Format-Volume -DriveLetter $BootDriveLetter -FileSystem FAT32 -NewFileSystemLabel "System" -confirm:$false -ErrorAction Stop
    
    #MSR partition
    $null = New-Partition -DiskNumber $mountedDisk.Number -Size 128MB -GptType "{e3c9e316-0b5c-4db8-817d-f92df00215ae}" -ErrorAction Stop

    #Windows partition
    $null = New-Partition -DiskNumber $mountedDisk.Number -UseMaximumSize -DriveLetter $OSDriveLetter -ErrorAction Stop
    $null = Format-Volume -DriveLetter $OSDriveLetter -FileSystem NTFS -NewFileSystemLabel $WindowsVolumeLabel -confirm:$false -ErrorAction Stop
    #endregion Partition the new VHDx

    Write-Verbose "Applying Wim to VHDD"
    Expand-WindowsImage -ImagePath $WimPath -ApplyPath "${OSDriveLetter}:\" -Index $ImageIndex -ErrorAction Stop

    #Copy boot files from the now applied image in the Windows partition to the System partition using bcdboot
    & "$("${OSDriveLetter}:\Windows\System32\bcdboot.exe")" $("${OSDriveLetter}:\Windows") /s ${BootDriveLetter}: /F UEFI

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
        [ValidateScript({Test-Path $_})]
        [string]
        $WsusRepoDirectory,

        [parameter(Mandatory)]
        [ValidatePattern("[a-zA-Z]{2}")]
        [string]
        $UpdateLanguageCode
    )

    #Check for existing installation of WSUS and exit if exists
    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530 -ErrorAction SilentlyContinue
    if ($wsusServer)
    {
        Write-Warning "WSUS role already installed, exiting."
        break
    }

    Install-WindowsFeature -Name "UpdateServices" -IncludeManagementTools -ErrorAction Stop

    New-Item -Path $WsusRepoDirectory -ItemType "Directory" -Force -ErrorAction Stop
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
        Configures WSUS to download only Windows 2016 updates.

    .DESCRIPTION
        This function will remove all products but Windows 2016 from the WSUS configuration.
        This is a temporary function that will be replaced with something more fully-featured.

    .Example
        Set-WsusConfigurationWin16
#>
function Set-WsusConfigurationWin16
{
    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530
    $wsusProductList = Get-WsusProduct -UpdateServer $wsusServer
    $wsusProductList.ForEach({if ($_.Product.ID -ne "569e8e8f-c6cd-42c8-92a3-efbb20a0f6f5") { [Microsoft.UpdateServices.Commands.WsusProduct[]]$everythingButWin16 += $_ }})

    #Disable everything but Windows 2016
    $everythingButWin16.ForEach({Set-WsusProduct -Product $_ -Disable})
    
    Write-Verbose "Gathering updates, this will take some time"
    $updateList = Get-WsusUpdate -UpdateServer $wsusServer

    Write-Verbose "Setting non-Windows 2016 Updates to declined"
    $win16Updates = $updatelist.Where({$_.Products -like "*windows Server 2016*" -and ($_.Update.Title -notlike "*(1709)*" -and $_.Update.Title -notlike "*(1803)*")})
    
    $nonWin16Updates = $updatelist.Where({$_ -notin $win16Updates})
    $nonwin16Updates.ForEach({Deny-WsusUpdate -Update $_})

    $latestWin16Updates = $win16Updates.where({$_.update.IsSuperseded -eq $false})

    $latestWin16Updates.ForEach({ Approve-WsusUpdate -Update $_ -Action Install -TargetGroupName "All Computers" })

    $wsusSubscription = $wsusServer.GetSubscription()

    $wsusSubscription.StartSynchronization()
}
