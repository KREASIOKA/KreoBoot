<# :
@echo off
setlocal
:: Check for administrative permissions
fsutil dirty query %systemdrive% >nul
if %errorlevel% neq 0 (
    echo KreoBoot requires Administrator privileges to manage disks.
    echo Requesting elevation...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
:: Execute the embedded PowerShell script
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Command -ScriptBlock ([Scriptblock]::Create((Get-Content -Raw '%~f0')))"
exit /b
#>

$ErrorActionPreference = 'Stop'
$Global:Version = "1.0.0"

function Pause-Prompt {
    Write-Host "`nPress Enter to continue..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Show-Banner {
    Clear-Host
    if ($Host.UI.RawUI.WindowSize.Width -ge 86) {
        Write-Host " "
        Write-Host " █████   ████                             ███████████                     █████   " -ForegroundColor Cyan
        Write-Host "░░███   ███░                             ░░███░░░░░███                   ░░███    " -ForegroundColor Cyan
        Write-Host " ░███  ███    ████████   ██████   ██████  ░███    ░███  ██████   ██████  ███████  " -ForegroundColor Cyan
        Write-Host " ░███████    ░░███░░███ ███░░███ ███░░███ ░██████████  ███░░███ ███░░███░░░███░   " -ForegroundColor Cyan
        Write-Host " ░███░░███    ░███ ░░░ ░███████ ░███ ░███ ░███░░░░░███░███ ░███░███ ░███  ░███    " -ForegroundColor Cyan
        Write-Host " ░███ ░░███   ░███     ░███░░░  ░███ ░███ ░███    ░███░███ ░███░███ ░███  ░███ ███" -ForegroundColor Cyan
        Write-Host " █████ ░░████ █████    ░░██████ ░░██████  ███████████ ░░██████ ░░██████   ░░█████ " -ForegroundColor Cyan
        Write-Host "░░░░░   ░░░░ ░░░░░      ░░░░░░   ░░░░░░  ░░░░░░░░░░░   ░░░░░░   ░░░░░░     ░░░░░  " -ForegroundColor Cyan
        Write-Host " "
        Write-Host "          Universal Bootable Media Creator  ·  v$Global:Version" -ForegroundColor DarkCyan
        Write-Host "          Windows Edition" -ForegroundColor Gray
        Write-Host " "
    } else {
        Write-Host "`n  KreoBoot - Universal Bootable Media Creator (v$Global:Version)" -ForegroundColor Cyan
        Write-Host "  Windows Edition`n" -ForegroundColor Gray
    }
}

function Show-SystemInfo {
    $os = (Get-CimInstance Win32_OperatingSystem).Caption
    $usbCount = (Get-Disk | Where-Object BusType -eq 'USB').Count
    Write-Host "=================================================================" -ForegroundColor DarkCyan
    Write-Host "  Operating System    : $os"
    Write-Host "  Removable drives    : $usbCount detected"
    Write-Host "=================================================================`n" -ForegroundColor DarkCyan
}

function Show-Menu {
    param([string]$Title, [string[]]$Options)
    Write-Host "--- $Title ---`n" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Length; $i++) {
        $num = $i + 1
        Write-Host "  $num) $($Options[$i])"
    }
    Write-Host "  0) Exit / Cancel"
    Write-Host ""
    while ($true) {
        $choice = Read-Host "Select an option (0-$($Options.Length))"
        if ($choice -match '^\d+$') {
            $val = [int]$choice
            if ($val -ge 0 -and $val -le $Options.Length) {
                return $val
            }
        }
        Write-Host "Invalid choice, please try again." -ForegroundColor Red
    }
}

function Invoke-SelectImage {
    Show-Banner
    $images = @()
    Write-Host "Scanning common folders for ISO/IMG files..." -ForegroundColor Gray
    
    $searchPaths = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyDocuments'),
        [Environment]::GetFolderPath('UserProfile') + "\Downloads"
    )
    
    foreach ($path in $searchPaths) {
        if (Test-Path $path) {
            $images += Get-ChildItem -Path $path -Include *.iso,*.img -Recurse -ErrorAction SilentlyContinue -Depth 2 | Where-Object { $_.Length -gt 20MB }
        }
    }
    
    $options = @()
    foreach ($img in $images) {
        $sizeMB = [math]::Round($img.Length / 1MB, 2)
        $options += "$($img.Name) ($sizeMB MB) - $($img.DirectoryName)"
    }
    $options += "Browse manually (Type full path)"
    
    $choice = Show-Menu "Select Source Image" $options
    if ($choice -eq 0) { return $null }
    
    if ($choice -eq $options.Length) {
        $manualPath = Read-Host "Enter full path to ISO/IMG file"
        if (Test-Path $manualPath -PathType Leaf) {
            return (Get-Item $manualPath)
        } else {
            Write-Host "File not found!" -ForegroundColor Red
            Pause-Prompt
            return $null
        }
    }
    
    return $images[$choice - 1]
}

function Invoke-SelectTarget {
    Show-Banner
    Write-Host "Scanning for USB drives..." -ForegroundColor Gray
    $disks = Get-Disk | Where-Object BusType -eq 'USB'
    if ($disks.Count -eq 0) {
        Write-Host "`nNo USB drives detected!" -ForegroundColor Yellow
        Pause-Prompt
        return $null
    }
    
    $options = @()
    foreach ($d in $disks) {
        $sizeGB = [math]::Round($d.Size / 1GB, 2)
        $options += "Disk $($d.Number) : $($d.FriendlyName) ($sizeGB GB)"
    }
    
    $choice = Show-Menu "Select Target USB Drive" $options
    if ($choice -eq 0) { return $null }
    return $disks[$choice - 1]
}

function Invoke-FormatTarget {
    param($Disk, $FS, $Label)
    Write-Host "Formatting Disk $($Disk.Number) ($($Disk.FriendlyName))..." -ForegroundColor Cyan
    try {
        Clear-Disk -Number $Disk.Number -RemoveData -Confirm:$false
        Initialize-Disk -Number $Disk.Number -PartitionStyle GPT -Confirm:$false
        $part = New-Partition -DiskNumber $Disk.Number -UseMaximumSize
        Format-Volume -Partition $part -FileSystem $FS -NewFileSystemLabel $Label -Confirm:$false | Out-Null
        $vol = Get-Volume -Partition $part
        return $vol.DriveLetter
    } catch {
        Write-Host "Failed to format disk: $_" -ForegroundColor Red
        return $null
    }
}

function Invoke-CopyFiles {
    param($SourcePath, $DriveLetter)
    
    Write-Host "Mounting Image..." -ForegroundColor Cyan
    $mountResult = Mount-DiskImage -ImagePath $SourcePath -StorageType ISO -PassThru
    $isoVol = $mountResult | Get-Volume
    if (-not $isoVol.DriveLetter) {
        Write-Host "Failed to mount ISO. Make sure it is a valid format." -ForegroundColor Red
        return $false
    }
    $isoDrive = "$($isoVol.DriveLetter):\"
    $targetDrive = "$($DriveLetter):\"
    
    $hasWim = Test-Path "$isoDrive\sources\install.wim"
    $isLargeWim = $false
    if ($hasWim) {
        $wimInfo = Get-Item "$isoDrive\sources\install.wim"
        if ($wimInfo.Length -gt 4GB) { $isLargeWim = $true }
    }
    $hasEsd = Test-Path "$isoDrive\sources\install.esd"
    if ($hasEsd) {
        $esdInfo = Get-Item "$isoDrive\sources\install.esd"
        if ($esdInfo.Length -gt 4GB) { $isLargeWim = $true; $hasWim = $false }
    }
    
    if ($isLargeWim) {
        $bigFileName = if ($hasWim) { "install.wim" } else { "install.esd" }
        Write-Host "Large $bigFileName detected (> 4GB). Splitting image for FAT32 compatibility..." -ForegroundColor Yellow
        Write-Host "Copying standard files..." -ForegroundColor Gray
        & robocopy $isoDrive $targetDrive /MIR /XD "$isoDrive\System Volume Information" /XF "$isoDrive\sources\$bigFileName" /R:0 /W:0 /NP | Out-Null
        
        Write-Host "Splitting $bigFileName... This may take a while." -ForegroundColor Cyan
        $swmTarget = "$targetDrive\sources\" + $bigFileName.Replace(".wim", ".swm").Replace(".esd", ".swm")
        & dism /Split-Image /ImageFile:"$isoDrive\sources\$bigFileName" /SWMFile:$swmTarget /FileSize:3800 | Out-Null
    } else {
        Write-Host "Copying files to USB... This may take a while." -ForegroundColor Cyan
        & robocopy $isoDrive $targetDrive /MIR /XD "$isoDrive\System Volume Information" /R:0 /W:0 /NP | Out-Null
    }
    
    Write-Host "Dismounting Image..." -ForegroundColor Cyan
    Dismount-DiskImage -ImagePath $SourcePath | Out-Null
    
    return $true
}

function Invoke-CreateBootable {
    $img = Invoke-SelectImage
    if (-not $img) { return }
    
    $disk = Invoke-SelectTarget
    if (-not $disk) { return }
    
    Show-Banner
    Write-Host "WARNING: ALL DATA ON DISK $($disk.Number) ($($disk.FriendlyName)) WILL BE ERASED!" -ForegroundColor Red
    $confirm = Show-Menu "Proceed with formatting?" @("Yes, format and create bootable USB", "No, cancel")
    if ($confirm -ne 1) { return }
    
    $fsChoice = Show-Menu "Select File System" @("FAT32 (Recommended for UEFI Windows/Linux)", "exFAT", "NTFS")
    if ($fsChoice -eq 0) { return }
    $fsMap = @{1="FAT32"; 2="exFAT"; 3="NTFS"}
    $fs = $fsMap[$fsChoice]
    
    $driveLetter = Invoke-FormatTarget -Disk $disk -FS $fs -Label "KREOBOOT"
    if (-not $driveLetter) {
        Pause-Prompt
        return
    }
    
    $copySuccess = Invoke-CopyFiles -SourcePath $img.FullName -DriveLetter $driveLetter
    
    if ($copySuccess) {
        Show-Banner
        Write-Host "Successfully created bootable USB on Drive $driveLetter!" -ForegroundColor Green
        
        $isWin = (Test-Path "$driveLetter:\sources\boot.wim")
        if ($isWin) {
            $tweak = Show-Menu "Add Windows 11 Requirements Bypass? (Optional)" @("Yes, bypass TPM/SecureBoot/RAM", "No, skip tweaks")
            if ($tweak -eq 1) {
                # Create autounattend.xml using UTF8 without BOM for maximum compatibility
                $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>BypassTPMCheck</Description>
                    <Path>cmd /c reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassTPMCheck" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Description>BypassSecureBootCheck</Description>
                    <Path>cmd /c reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassSecureBootCheck" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Description>BypassRAMCheck</Description>
                    <Path>cmd /c reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassRAMCheck" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Description>BypassStorageCheck</Description>
                    <Path>cmd /c reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassStorageCheck" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Description>BypassCPUCheck</Description>
                    <Path>cmd /c reg add "HKLM\SYSTEM\Setup\LabConfig" /v "BypassCPUCheck" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Description>BypassNRO</Description>
                    <Path>cmd /c reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v "BypassNRO" /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
</unattend>
"@
                [System.IO.File]::WriteAllText("$driveLetter:\autounattend.xml", $xml, (New-Object System.Text.UTF8Encoding $false))
                Write-Host "Added autounattend.xml to bypass requirements." -ForegroundColor Cyan
            }
        }
    }
    Pause-Prompt
}

function Invoke-FormatOnly {
    $disk = Invoke-SelectTarget
    if (-not $disk) { return }
    
    Show-Banner
    Write-Host "WARNING: ALL DATA ON DISK $($disk.Number) ($($disk.FriendlyName)) WILL BE ERASED!" -ForegroundColor Red
    $confirm = Show-Menu "Proceed with formatting?" @("Yes, format USB", "No, cancel")
    if ($confirm -ne 1) { return }
    
    $fsChoice = Show-Menu "Select File System" @("FAT32", "exFAT", "NTFS")
    if ($fsChoice -eq 0) { return }
    $fsMap = @{1="FAT32"; 2="exFAT"; 3="NTFS"}
    $fs = $fsMap[$fsChoice]
    
    $label = Read-Host "Enter Volume Label (Default: KREOBOOT)"
    if ([string]::IsNullOrWhiteSpace($label)) { $label = "KREOBOOT" }
    
    $driveLetter = Invoke-FormatTarget -Disk $disk -FS $fs -Label $label
    if ($driveLetter) {
        Write-Host "Successfully formatted drive $driveLetter as $fs." -ForegroundColor Green
    }
    Pause-Prompt
}

# Main Loop
while ($true) {
    Show-Banner
    Show-SystemInfo
    $mainChoice = Show-Menu "Main Menu" @(
        "Create Bootable USB",
        "Format USB Drive"
    )
    
    switch ($mainChoice) {
        1 { Invoke-CreateBootable }
        2 { Invoke-FormatOnly }
        0 { exit }
    }
}
