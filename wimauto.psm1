function Copy-WimFromISO
{
    param(
        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $IsoPath,

        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WimDestinationPath
    )

    Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -ErrorAction Stop

    $mountedDiskImageLetter = (Get-Volume).where({$_.FileSystem -eq "UDF"}).DriveLetter

    Copy-Item -Path "${mountedDiskImageLetter}:\sources\install.wim" -Destination $WimDestinationPath -Force -ErrorAction Stop

    Set-ItemProperty $WimDestinationPath -Name "IsReadOnly" -Value $false

    Dismount-DiskImage -ImagePath $IsoPath
}

function Install-UpdateListToWim
{
    param(
        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WimPath,

        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
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

    if (! (Test-Path $ImageMountPath))
    {
        New-Item -Path $ImageMountPath -ItemType "Directory" -ErrorAction Stop
    }

    #Mount-WindowsImage -ImagePath $WimPath -Index 2 -Path $ImageMountPath -ErrorAction Stop

    $updateFileList = Get-SelfContainedApprovedUpdateFileList -WsusRepoDirectory $WsusRepoDirectory -ServerVersion $ServerVersion

    foreach ($update in $updateFileList)
    {
        Write-Verbose "Adding Update $($update.ID) from $($update.FilePath) to image path $ImageMountPath"
        try
        {
            Add-WindowsPackage -PackagePath $update.FilePath -Path $ImageMountPath -WarningAction Ignore
            #add to update log on root of mount
        }
        catch
        {
            $packageError = $_

            if ($packageError.Exception.Message.Contains("0x800f081e"))
            {
                Write-Output "Update Not applicable"
            }
        }
    }

    $wimLogPath = Join-Path -Path (Split-Path -Path $WimPath -Parent) -ChildPath "dism.log"

    Dismount-WindowsImage -Path $ImageMountPath -Save -LogPath $wimLogPath -Append -LogLevel Errors


}

function Install-WSUS
{
    param(
        [parameter(Mandatory)]
        [ValidateScript({Test-Path $_})]
        [string]
        $WsusRepoDirectory = "C:\library\ngenbuild\updaterepo"
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

    & 'C:\Program Files\Update Services\Tools\wsusutil.exe' postinstall CONTENT_DIR=C:\library\ngenbuild\updaterepo

    Set-WsusServerSynchronization -SyncFromMU

    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530

    $wsusConfiguration = $wsusServer.GetConfiguration()

    $wsusConfiguration.SetEnabledUpdateLanguages("en")

    $wsusConfiguration.AllUpdateLanguagesEnabled = $false

    $wsusConfiguration.Save()

    $wsusSubscription = $wsusServer.GetSubscription()

    $wsusSubscription.StartSynchronization()

}

function Set-WsusConfigurationWin16
{
    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530
    $wsusProductList = Get-WsusProduct -UpdateServer $wsusServer
    $wsusProductList.ForEach({if ($_.Product.ID -ne "569e8e8f-c6cd-42c8-92a3-efbb20a0f6f5") { [Microsoft.UpdateServices.Commands.WsusProduct[]]$everythingButWin16 += $_ }})

    #disable everything but Windows 2016
    $everythingButWin16.ForEach({Set-WsusProduct -Product $_ -Disable})
    
    Write-Verbose "Gathering updates, this will take some time"
    $updateList = Get-WsusUpdate -UpdateServer $wsusServer

    #Invoke-WsusServerCleanup -UpdateServer $wsusServer -CleanupObsoleteUpdates -CleanupUnneededContentFiles -CompressUpdates -DeclineExpiredUpdates -DeclineSupersededUpdates

    Write-Verbose "Setting non-Windows 2016 Updates to declined"
    $win16Updates = $updatelist.Where({$_.Products -like "*windows Server 2016*" -and ($_.Update.Title -notlike "*(1709)*" -and $_.Update.Title -notlike "*(1803)*")})
    
    $nonWin16Updates = $updatelist.Where({$_ -notin $win16Updates})
    $nonwin16Updates.ForEach({Deny-WsusUpdate -Update $_})

    $latestWin16Updates = $win16Updates.where({$_.update.IsSuperseded -eq $false})

    $latestWin16Updates.ForEach({ Approve-WsusUpdate -Update $_ -Action Install -TargetGroupName "All Computers" })

    $wsusSubscription = $wsusServer.GetSubscription()

    $wsusSubscription.StartSynchronization()
}

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
        $ServerVersion = "Windows Server 2016"
    )

    $wsusServer = Get-WsusServer -Name localhost -PortNumber 8530
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
