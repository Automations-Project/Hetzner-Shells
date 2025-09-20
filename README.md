# 🗂️ Hetzner Storage Box Auto-Mount

[![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Hetzner](https://img.shields.io/badge/Hetzner-D50C2D?style=for-the-badge&logo=hetzner&logoColor=white)](https://www.hetzner.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)

[![ARM64](https://img.shields.io/badge/ARM64-✅-success?style=flat-square)](https://github.com/Automations-Project/Hetzner-Shells)
[![x86_64](https://img.shields.io/badge/x86__64-✅-success?style=flat-square)](https://github.com/Automations-Project/Hetzner-Shells)
[![Production Ready](https://img.shields.io/badge/Production-Ready-brightgreen?style=flat-square)](https://github.com/Automations-Project/Hetzner-Shells)

> **One-command solution** to automatically mount Hetzner Storage Box on Ubuntu systems with **zero manual configuration**.

## 🚀 Quick Start

### One-Line Install (Recommended)
```bash
curl -fsSL https://raw.githubusercontent.com/Automations-Project/Hetzner-Shells/main/Storage/Mount-Storage-Box.sh | sudo bash
```

### Download & Review (Safer)
```bash
wget https://raw.githubusercontent.com/Automations-Project/Hetzner-Shells/main/Storage/Mount-Storage-Box.sh
chmod +x Mount-Storage-Box.sh
sudo ./Mount-Storage-Box.sh
```

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🔍 **Auto-Detection** | Detects Ubuntu version, architecture (ARM64/x86_64), and system compatibility |
| 🔧 **Repository Fixes** | Automatically fixes ARM64 repository configuration for ports.ubuntu.com |
| 📦 **Package Management** | Installs `cifs-utils`, `keyutils`, and required kernel modules |
| 🔐 **Security First** | Creates secure credentials file with 0600 permissions |
| 🗂️ **Smart Mounting** | Tests SMB versions, validates write access, handles existing mounts |
| ⚙️ **Persistent Setup** | Optional `/etc/fstab` or systemd mount unit integration |
| 📊 **Comprehensive Logging** | Full operation logging with timestamps and colored output |
| 🛡️ **Error Handling** | Automatic backups, rollback capabilities, graceful failure handling |

## 💻 Supported Systems

- ✅ **Ubuntu 20.04 LTS** (ARM64/x86_64)
- ✅ **Ubuntu 22.04 LTS** (ARM64/x86_64) 
- ✅ **Ubuntu 24.04 LTS** (ARM64/x86_64)
- ✅ **Hetzner Cloud VPS**
- ✅ **Other Ubuntu-based systems**

## 🎯 Problem Solved

**Before (Manual Process):**
```bash
# Multiple commands, architecture-specific issues
sudo nano /etc/apt/sources.list  # Fix ARM64 repositories
sudo apt update                   # Often fails with 404s
sudo apt install cifs-utils      # "Package not found" errors
sudo nano /etc/cifs-credentials.txt  # Manual credential creation
sudo chmod 0600 /etc/cifs-credentials.txt
sudo mkdir /mnt/hetzner-storage
sudo mount.cifs //server/path /mnt/...  # Complex mount options
sudo nano /etc/fstab             # Manual fstab editing
```

**After (This Script):**
```bash
# Single command - everything automated
curl -fsSL https://raw.githubusercontent.com/Automations-Project/Hetzner-Shells/main/Storage/Mount-Storage-Box.sh | sudo bash
```

## 🔧 How It Works

1. **System Analysis** - Detects Ubuntu version, architecture, network connectivity
2. **Repository Fix** - Automatically configures correct repositories (especially ARM64)
3. **Package Installation** - Installs all required packages with error handling
4. **Interactive Setup** - Prompts for Storage Box credentials with validation
5. **Smart Mounting** - Tests SMB protocol versions and validates access
6. **Persistent Configuration** - Optionally configures automatic mounting at boot
7. **Verification** - Tests the setup and provides usage recommendations

## 📋 Usage Example

```bash
$ sudo ./Mount-Storage-Box.sh

    __  __     __                     
   / / / /__  / /_____  ____  ___  _____
  / /_/ / _ \/ __/_  / / __ \/ _ \/ ___/
 / __  /  __/ /_  / /_/ / / /  __/ /    
/_/ /_/\___/\__/ /___/_/ /_/\___/_/     

    Storage Box Auto-Mount Assistant
Version 0.0.1 - Production Ready

✓ Ubuntu 22.04 (ARM64) detected
✓ Network connectivity verified
✓ Repositories configured for ARM64
✓ Packages installed successfully
? Storage Box username: u123456-sub1
? Storage Box password: ••••••••
✓ DNS resolution successful
✓ SMB 3.1.1 protocol working
✓ Mount successful with read/write access
✓ fstab entry added with automount
✓ Setup completed successfully!
```

## 🏗️ Project Structure

```
Hetzner-Shells/
├── Storage/
│   └── Mount-Storage-Box.sh    # Main auto-mount script
├── README.md                   # This file
├── Draft.md                    # Development documentation
└── TESTING.md                  # Testing & deployment guide
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🆘 Support

- 📖 **Documentation**: Check `TESTING.md` for detailed testing procedures
- 🐛 **Issues**: Report bugs via GitHub Issues
- 💡 **Feature Requests**: Submit via GitHub Issues
- 📧 **Contact**: Create an issue for questions

## ⭐ Show Your Support

If this project helped you, please consider giving it a ⭐ on GitHub!

---

<div align="center">
<strong>Made with ❤️ for the Ubuntu & Hetzner community</strong>
<br>
<a href="#-quick-start">Get Started</a> • <a href="#-features">Features</a> • <a href="https://docs.hetzner.com/robot/storage-box/">Hetzner Docs</a>
</div>
