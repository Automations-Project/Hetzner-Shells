# Quick Test & Setup Guide

## Test the Script Locally

### 1. Make the script executable:
```bash
chmod +x Mount-Storage-Box.sh
```

### 2. Test run (dry run mode - add to script if needed):
```bash
sudo ./Mount-Storage-Box.sh
```

## Deploy for Public Use

### Option 1: GitHub (Recommended)
1. Create GitHub repository named `Hetzner-Shells`
2. Upload `Mount-Storage-Box.sh` to `Storage/` folder
3. Users run:
```bash
curl -fsSL https://raw.githubusercontent.com/Automations-Project/Hetzner-Shells/main/Storage/Mount-Storage-Box.sh | sudo bash
```

### Option 2: Your Own Server
1. Upload script to your web server
2. Users run:
```bash
curl -fsSL https://your-domain.com/Mount-Storage-Box.sh | sudo bash
```

### Option 3: Local Testing
1. Run the web deployment script:
```bash
chmod +x deploy-web.sh
./deploy-web.sh
```
2. Test with:
```bash
curl -fsSL http://YOUR_SERVER_IP:8000/Mount-Storage-Box.sh | sudo bash
```

## Script Command Examples

Based on your experience, the script will handle these scenarios automatically:

### Your Ubuntu 22.04 ARM64 Server (karek):
```bash
# What you did manually:
sudo apt update  # → Script detects ARM64 and fixes repositories first
sudo apt install cifs-utils  # → Script installs all required packages
sudo nano /etc/cifs-credentials.txt  # → Script prompts interactively
sudo chmod 0600 /etc/cifs-credentials.txt  # → Script sets secure permissions
sudo mkdir /mnt/hetzner-storage  # → Script creates mount point
sudo mount.cifs -o seal,credentials=/etc/cifs-credentials.txt //u493700-sub2.your-storagebox.de/u493700-sub2 /mnt/hetzner-storage  # → Script mounts and tests

# What users will do with your script:
curl -fsSL https://raw.githubusercontent.com/Automations-Project/Hetzner-Shells/main/Storage/Mount-Storage-Box.sh | sudo bash
# Then just follow the prompts!
```

### Your Ubuntu 20.04 ARM64 Server (supporters):
```bash
# Your logs showed issues with:
# - mount: /mnt/HC_Volume_100753392: mount point does not exist
# - s3fs: MOUNTPOINT directory /mnt/hetzner-s3 is not empty

# Script will handle these by:
# - Checking for existing mounts
# - Asking user about non-empty directories
# - Providing cleanup options
```

## Integration with Your Current Infrastructure

Since you have Docker and multiple services running, the script provides recommendations for:

### 🗂️ Directory Structure:
```bash
/mnt/hetzner-storage/
├── backups/           # Database backups, config backups
├── docker-data/       # Non-critical Docker volumes
├── media/             # Media files, uploads
├── logs/              # Application logs
└── archives/          # Long-term storage
```

### 🔧 Docker Integration Examples:
```yaml
# In your docker-compose.yml files:
services:
  app:
    volumes:
      # Critical data - keep local
      - /opt/docker-local/db:/var/lib/mysql

      # Media/backup data - use Storage Box
      - /mnt/hetzner-storage/media:/app/media
      - /mnt/hetzner-storage/backups:/backups
```

## Error Handling

The script handles all the issues you encountered:

1. **ARM64 Repository Issues** → Auto-fixes sources.list
2. **Package Not Found** → Uses correct repositories
3. **Mount Point Conflicts** → Interactive resolution
4. **Existing Mounts** → Safe handling and options
5. **Credential Security** → Secure file creation
6. **fstab Integration** → Optional with testing

## Monitoring & Maintenance

After installation, users can monitor with:
```bash
# Check mount status
df -h /mnt/hetzner-storage

# Check mount details
findmnt /mnt/hetzner-storage

# View logs
tail -f /tmp/hetzner-mount-*.log
```

This gives your users a professional, automated solution instead of the manual process you went through!
