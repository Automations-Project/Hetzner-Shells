# 🗂️ Hetzner Storage Box Auto-Mount

[![Shell Script](https://img.shields.io/badge/Shell-Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Multi-Distro](https://img.shields.io/badge/Distro-Ubuntu%20Debian%20RHEL-blue?style=for-the-badge&logo=linux&logoColor=white)](https://ubuntu.com/)
[![Hetzner](https://img.shields.io/badge/Hetzner-D50C2D?style=for-the-badge&logo=hetzner&logoColor=white)](https://www.hetzner.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)

[![ARM64](https://img.shields.io/badge/ARM64-✅-success?style=flat-square)](https://github.com/Automations-Project/Hetzner-Shells)
[![x86_64](https://img.shields.io/badge/x86__64-✅-success?style=flat-square)](https://github.com/Automations-Project/Hetzner-Shells)
[![Production Ready](https://img.shields.io/badge/Production-Ready-brightgreen?style=flat-square)](https://github.com/Automations-Project/Hetzner-Shells)

> **One-command solution** to automatically mount Hetzner Storage Box on Linux systems with **zero manual configuration**. Now supports multiple distributions, non-interactive mode, and enhanced security.

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
| 🔍 **Auto-Detection** | Detects distribution (Ubuntu, Debian, RHEL), version, architecture (ARM64/x86_64), package/service managers, and system compatibility |
| 🔧 **Repository Fixes** | Automatically fixes ARM64 repository configuration for ports.ubuntu.com (Ubuntu-specific) |
| 📦 **Package Management** | Installs `cifs-utils`, `keyutils`, and required kernel modules using apt/yum/dnf/zypper |
| 🔐 **Security First** | Creates secure credentials file with 0600 permissions; supports password files for non-interactive use; validates mount points; signal handling (INT/TERM) for graceful cleanup; warnings for insecure CLI passwords |
| 🗂️ **Smart Mounting** | Tests SMB versions (3.1.1 to 1.0), validates write access, handles existing mounts; centralized command building for efficiency |
| ⚙️ **Persistent Setup** | Optional `/etc/fstab` or systemd mount unit integration with automount support |
| 🎛️ **Non-Interactive Mode** | Run without prompts using flags (e.g., `--username`, `--password-file`, `--mount-point`); dry-run (`--dry-run`) and verbose (`--verbose`) options |
| 📊 **Comprehensive Logging** | Full operation logging with timestamps, colored output, and ANSI stripping for clean logs |
| 🛡️ **Error Handling** | Strict mode (`set -eEuo pipefail`), traps for errors/signals, retries (up to 3), automatic backups, rollback capabilities, specific failure diagnostics |
| ⚡ **Optimizations** | Performance tuning (rsize/wsize for Hetzner network); conditional skips for existing setups; spinner for non-blocking operations |

## 💻 Supported Systems

- ✅ **Ubuntu 20.04+ LTS** (ARM64/x86_64)
- ✅ **Debian 10+** (x86_64/ARM64 where supported)
- ✅ **RHEL/CentOS 7+** (x86_64)
- ✅ **Fedora** (via DNF)
- ✅ **openSUSE** (via Zypper)
- ✅ **Hetzner Cloud VPS** (all architectures)
- ✅ **Other Linux systems** with compatible package managers

## 🎯 Problem Solved

**Before (Manual Process):**
```bash
# Multiple commands, distro/arch-specific issues
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

Non-interactive example:
```bash
sudo ./Mount-Storage-Box.sh --non-interactive --username u123456 --password-file /secure/pass.txt --mount-point /data/storage --mount-method systemd
```

## 🔧 How It Works

1. **Argument Parsing & Welcome** - Handles flags, shows banner
2. **System Analysis** - Detects distro, arch, managers, network/DNS
3. **Preparation** - Fixes repos (ARM64), updates packages, installs dependencies
4. **Configuration** - Gets credentials (interactive or args), mount options with validation
5. **Mount Testing** - Negotiates SMB, mounts with retries, verifies access
6. **Persistence** - Configures fstab/systemd based on choice/method
7. **Verification & Tips** - Shows stats, commands, performance advice

## 📋 Usage Examples

Interactive:
```bash
sudo ./Mount-Storage-Box.sh
```

Non-Interactive with Password File:
```bash
sudo ./Mount-Storage-Box.sh --non-interactive --username u123456-sub1 --password-file /secure/pass.txt --verbose
```

Dry-Run (Preview Changes):
```bash
sudo ./Mount-Storage-Box.sh --dry-run --username u123456 --password-file /secure/pass.txt
```

Custom Options:
```bash
sudo ./Mount-Storage-Box.sh --non-interactive --username u123456 --password-file /secure/pass.txt --mount-point /mnt/custom --uid 1000 --gid 1000 --no-tuning --mount-method fstab
```

Full Help:
```bash
sudo ./Mount-Storage-Box.sh --help
```

## 🏗️ Project Structure

```
Hetzner-Shells/
├── Storage/
│   └── Mount-Storage-Box.sh    # Main auto-mount script (v1.0.1)
├── README.md                   # This file
├── LICENSE                     # MIT License
├── TESTING.md                  # Testing & deployment guide
└── test-logs.txt               # Example test output
```

## 🔒 Security Considerations

- **Credentials**: Stored in `/etc/cifs-credentials.txt` with root:0600 ownership. Use `--password-file` for automation to avoid CLI exposure.
- **Validation**: Mount points sanitized against dangerous paths (e.g., /etc, /boot); username regex-checked.
- **Signals**: Handles Ctrl+C (INT) and TERM for cleanup (unmount, temp file removal).
- **Recommendations**: On production, consider encrypting credentials (e.g., via `gpg`) or using secrets managers. Run in isolated environments.
- **Audits**: Script passes ShellCheck; no known vulnerabilities.

## ⚡ Optimizations & Best Practices

- **Performance**: Hetzner-specific options (seal, rsize=130048, cache=loose) for 300-800 MB/s throughput.
- **Efficiency**: Skips redundant steps (e.g., existing packages); non-blocking spinners; conditional network checks in dry-run.
- **Maintainability**: Modular functions, readonly globals, centralized logging/error handling.
- **Testing**: Use `--dry-run` for safe previews; full tests in TESTING.md.

## 🤝 Contributing

Contributions welcome! Submit PRs for new distros, features, or fixes. Run `shellcheck Mount-Storage-Box.sh` before submitting.

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

## 🆘 Support

- 📖 **Documentation**: [TESTING.md](TESTING.md) for tests; [Hetzner Docs](https://docs.hetzner.com/robot/storage-box/)
- 🐛 **Issues**: GitHub Issues
- 💡 **Features**: Suggest via Issues
- 📧 **Contact**: Open an issue

## ⭐ Show Your Support

Star this repo if it helps! Contributions and feedback drive improvements.

---

<div align="center">
<strong>Made with ❤️ for the Linux & Hetzner community</strong>
<br>
<a href="#-quick-start">Get Started</a> • <a href="#-features">Features</a> • <a href="#-security-considerations">Security</a> • <a href="https://docs.hetzner.com/robot/storage-box/">Hetzner Docs</a>
</div>
