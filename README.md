<div align="center">

```text
 █████   ████                             ███████████                     █████   
░░███   ███░                             ░░███░░░░░███                   ░░███    
 ░███  ███    ████████   ██████   ██████  ░███    ░███  ██████   ██████  ███████  
 ░███████    ░░███░░███ ███░░███ ███░░███ ░██████████  ███░░███ ███░░███░░░███░   
 ░███░░███    ░███ ░░░ ░███████ ░███ ░███ ░███░░░░░███░███ ░███░███ ░███  ░███    
 ░███ ░░███   ░███     ░███░░░  ░███ ░███ ░███    ░███░███ ░███░███ ░███  ░███ ███
 █████ ░░████ █████    ░░██████ ░░██████  ███████████ ░░██████ ░░██████   ░░█████ 
░░░░░   ░░░░ ░░░░░      ░░░░░░   ░░░░░░  ░░░░░░░░░░░   ░░░░░░   ░░░░░░     ░░░░░  
```

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![GitHub stars](https://img.shields.io/github/stars/KREASIOKA/KreoBoot.svg?style=social)](https://github.com/KREASIOKA/KreoBoot/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/KREASIOKA/KreoBoot.svg?style=social)](https://github.com/KREASIOKA/KreoBoot/network/members)
[![Website](https://img.shields.io/website?url=https%3A%2F%2Fwww.kreasioka.com&up_message=online&up_color=green&down_message=offline&down_color=red)](https://www.kreasioka.com)

**Universal Bootable Media Creator**
<br />
Developed by the **[KREASIOKA](https://www.kreasioka.com)** Team

</div>

---

KreoBoot is a lightweight, universal bootable media creator designed to make the process of creating bootable USB drives and burning optical media as simple and reliable as possible. It is a cross-platform tool built to handle complex formatting and imaging tasks seamlessly through an intuitive Terminal User Interface (TUI).

## Features

- **Cross-Platform Compatibility**: Native scripts available for Windows, Linux, and macOS.
- **Intelligent Formatting**: Automatically handles GPT/MBR partition tables and formats devices to FAT32, exFAT, NTFS, or EXT4 (HFS+ on macOS).
- **Large File Handling**: Automatically detects and splits large Windows installation files (install.wim or install.esd over 4GB) into smaller .swm chunks to maintain FAT32 compatibility for UEFI boot.
- **Windows Setup Tweaks**: Includes optional bypasses for Windows 11 requirements (TPM, Secure Boot, RAM, Storage, CPU) and forces local account creation by generating an autounattend.xml file.
- **Optical Media Support**: Capable of burning ISO images directly to CD/DVD using native tools (growisofs/wodim on Linux, hdiutil on macOS).
- **Safe Device Detection**: Scans specifically for removable drives to prevent accidental formatting of your primary operating system drives.

## Usage (Direct Execution)

You can run KreoBoot directly from the terminal without needing to clone the repository or download the files manually.

### ![linux](https://www.readmecodegen.com/api/social-icon?name=linux&size=16) ![apple](https://www.readmecodegen.com/api/social-icon?name=apple&size=16&color=%23ffffff) Linux and macOS

![terminal](https://www.readmecodegen.com/api/social-icon?name=terminal&size=16) Open your terminal and execute the following command. The script will automatically request root permissions (via sudo) for disk manipulation.

```bash
curl -sSL https://raw.githubusercontent.com/KREASIOKA/KreoBoot/main/src/KreoBoot.sh | sudo bash
```

### ![windows](https://www.readmecodegen.com/api/social-icon?name=windows&size=16) Windows (Beta)

The Windows version is currently in active development but is fully functional. Open **PowerShell** and execute the following command to securely download and run the application in memory:

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/KREASIOKA/KreoBoot/main/src/KreoBoot.bat" -OutFile "$env:TEMP\KreoBoot.bat"; & "$env:TEMP\KreoBoot.bat"
```
*(Note: Running the command above will download the batch file to your temporary folder and execute it. It will automatically request UAC elevation if you are not running as Administrator).*

## System Requirements

KreoBoot utilizes native system tools to ensure maximum stability without requiring heavy graphical dependencies.

### Linux
The following standard packages are typically pre-installed. If not, they can be installed via your package manager (apt, dnf, pacman):
- ![gnubash](https://www.readmecodegen.com/api/social-icon?name=gnubash&size=16) Bash (v4.0+)
- coreutils (lsblk, findmnt, wipefs, blkid, partprobe)
- parted, udev, rsync
- wimlib (for splitting large Windows WIM files)
- mkfs utilities (mkfs.fat, mkfs.exfat, mkfs.ntfs)

### macOS
- ![gnubash](https://www.readmecodegen.com/api/social-icon?name=gnubash&size=16) Bash
- Built-in diskutil and hdiutil
- rsync
- wimlib (installable via Homebrew: `brew install wimlib`)

### Windows
- Windows 10 or Windows 11
- PowerShell (Built-in)
- Administrator Privileges (The script handles elevation automatically)

## Important Notes

- **Data Loss Warning**: Creating a bootable device will permanently erase all existing data on the selected target drive. Please ensure you have backed up any important files before proceeding.
- **Root/Admin Privileges**: Disk manipulation commands require elevated access on all operating systems.

## License

This project is open-source and is licensed under the MIT License.

Developed and maintained by the **KREASIOKA** Team. Visit our official website at [www.kreasioka.com](https://www.kreasioka.com).
