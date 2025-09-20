#!/bin/bash

# Hetzner Storage Box Auto-Mount Script
# Enhanced Production Version with Advanced Features
# Version: 0.0.7
# Author: Auto-generated for Hetzner Storage Box mounting

set -eE
trap 'handle_error $? $LINENO' ERR

# Colors and styling - Safer fallback
if [[ "${TERM:-}" != "dumb" ]] && [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    # Only use colors if terminal explicitly supports them
    if tput colors >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[0;33m'
        BLUE='\033[0;34m'
        MAGENTA='\033[0;35m'
        CYAN='\033[0;36m'
        WHITE='\033[0;37m'
        GRAY='\033[0;90m'
        BOLD='\033[1m'
        NC='\033[0m'
    else
        RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' GRAY='' BOLD='' NC=''
    fi
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' GRAY='' BOLD='' NC=''
fi

# Configuration variables
VERSION="0.0.7"
CREDENTIALS_FILE="/etc/cifs-credentials.txt"
DEFAULT_MOUNT_POINT="/mnt/hetzner-storage"
BACKUP_SUFFIX=".backup-$(date +%Y%m%d-%H%M%S)"
MAX_RETRIES=3
RETRY_DELAY=5
SMB_VERSIONS=("3.1.1" "3.0" "2.1" "2.0" "1.0")
DEFAULT_UID=$(id -u)
DEFAULT_GID=$(id -g)

# Logging
LOG_DIR="/var/log/hetzner-mount"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/mount-$(date +%Y%m%d-%H%M%S).log"

# Spinner chars
SPINNER_CHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

# Functions
log() {
    # Strip both real ESC sequences and literal \033 sequences before writing to log
    # Real ESC bytes: \x1b[[...letter]
    # Literal text:  \033[[...letter]
    local msg="$1"
    local clean_msg
    clean_msg=$(printf '%s' "$msg" \
        | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        | sed -E 's/\\033\[[0-9;]*[A-Za-z]//g')
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $clean_msg" >> "$LOG_FILE"
    # For console, keep original (with colors if available)
    echo -e "$msg"
}

handle_error() {
    local exit_code=$1
    local line_no=$2
    log "${RED}✗ ERROR: Command failed with exit code $exit_code at line $line_no${NC}"
    log "${RED}Check log file for details: $LOG_FILE${NC}"
    cleanup_on_error
    exit "$exit_code"
}

error_exit() {
    log "${RED}✗ ERROR: $1${NC}"
    cleanup_on_error
    exit 1
}

success() {
    log "${GREEN}✓ $1${NC}"
}

warning() {
    log "${YELLOW}⚠ WARNING: $1${NC}"
}

info() {
    log "${CYAN}ℹ INFO: $1${NC}"
}

question() {
    echo -e "${PURPLE}❓ $1${NC}"
}

header() {
    local width=60
    local text="$1"
    local padding=$(( (width - ${#text} - 2) / 2 ))
    echo
    echo -e "${BLUE}${BOLD}╔$(printf '═%.0s' {1..60})╗${NC}"
    echo -e "${BLUE}${BOLD}║$(printf ' %.0s' $(seq 1 $padding))$text$(printf ' %.0s' $(seq 1 $((width - padding - ${#text}))))║${NC}"
    echo -e "${BLUE}${BOLD}╚$(printf '═%.0s' {1..60})╝${NC}"
    echo
}

subheader() {
    echo -e "${CYAN}${BOLD}▶ $1${NC}"
    echo -e "${GRAY}$(printf '─%.0s' {1..40})${NC}"
}

spinner() {
    local pid=$1
    local message=$2
    local i=0
    
    # Colorless spinner to avoid escape sequences in consoles/log captures
    while kill -0 "$pid" 2>/dev/null; do
        if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
            printf "\r%s %s..." "${SPINNER_CHARS:i++%${#SPINNER_CHARS}:1}" "$message"
            # Clear to end of line to avoid leftovers
            tput el
        else
            printf "\r%s..." "$message"
        fi
        sleep 0.1
    done
    # Fully clear the line after the spinner finishes
    if command -v tput >/dev/null 2>&1; then
        printf "\r"
        tput el
    else
        printf "\r%*s\r" $(( ${#message} + 5 )) ""
    fi
}

show_welcome() {
    clear
    echo -e "${BLUE}${BOLD}"
    cat << "EOF"
    __  __     __                     
   / / / /__  / /_____  ____  ___  _____
  / /_/ / _ \/ __/_  / / __ \/ _ \/ ___/
 / __  /  __/ /_  / /_/ / / /  __/ /    
/_/ /_/\___/\__/ /___/_/ /_/\___/_/     
                                         
    Storage Box Auto-Mount Assistant
EOF
    echo -e "${NC}"
    echo -e "${CYAN}Version $VERSION - Production Ready${NC}"
    echo -e "${GRAY}────────────────────────────────────────${NC}"
    echo
    sleep 1
}

# Check network connectivity
check_network() {
    subheader "Network Connectivity Check"
    
    local test_hosts=(
        "your-storagebox.de:Hetzner Storage"
        "8.8.8.8:Google DNS"
        "1.1.1.1:Cloudflare DNS"
    )
    
    for host_info in "${test_hosts[@]}"; do
        IFS=':' read -r host name <<< "$host_info"
        echo -n "  Testing $name... "
        
        if ping -c 1 -W 2 "$host" &>/dev/null; then
            echo -e "${GREEN}✓${NC}"
            return 0
        else
            echo -e "${YELLOW}✗${NC}"
        fi
    done
    
    error_exit "No network connectivity detected. Please check your internet connection."
}

# DNS resolution check
check_dns() {
    local hostname=$1
    subheader "DNS Resolution Check"
    
    echo -n "  Resolving $hostname... "
    
    if host "$hostname" &>/dev/null || nslookup "$hostname" &>/dev/null; then
        echo -e "${GREEN}✓${NC}"
        local ip
        ip=$(host "$hostname" 2>/dev/null | grep "has address" | head -1 | awk '{print $NF}')
        [[ -n "$ip" ]] && info "  Resolved to: $ip"
        return 0
    else
        echo -e "${RED}✗${NC}"
        error_exit "Cannot resolve $hostname. Please check the hostname or your DNS settings."
    fi
}

# Detect system information
detect_system() {
    subheader "System Detection"
    
    # Architecture
    ARCH=$(uname -m)
    echo -e "  Architecture: ${WHITE}$ARCH${NC}"
    
    # Ubuntu version
    if [[ -f /etc/lsb-release ]]; then
        source /etc/lsb-release
        UBUNTU_VERSION="$DISTRIB_RELEASE"
        UBUNTU_CODENAME="$DISTRIB_CODENAME"
        echo -e "  Ubuntu: ${WHITE}$UBUNTU_VERSION ($UBUNTU_CODENAME)${NC}"
    else
        error_exit "This script requires Ubuntu. Please run on Ubuntu system."
    fi
    
    # Kernel version
    KERNEL=$(uname -r)
    echo -e "  Kernel: ${WHITE}$KERNEL${NC}"
    
    # Available memory
    MEM_TOTAL=$(free -h | awk '/^Mem:/ {print $2}')
    echo -e "  Memory: ${WHITE}$MEM_TOTAL${NC}"
    
    # Check if ARM64
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        IS_ARM64=true
        echo -e "  ${YELLOW}Note: ARM64 detected - will use ports.ubuntu.com${NC}"
    else
        IS_ARM64=false
    fi
    
    sleep 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root. Please run: sudo $0"
    fi
}

# Fix repositories for ARM64
fix_arm64_repositories() {
    if [[ "$IS_ARM64" != true ]]; then
        return 0
    fi
    
    header "ARM64 Repository Configuration"
    
    if grep -q "ports.ubuntu.com" /etc/apt/sources.list; then
        success "ARM64 repositories already configured correctly"
        return 0
    fi
    
    warning "ARM64 system with incorrect repository configuration detected"
    question "Fix repository configuration? (recommended) [Y/n]: "
    read -r fix_repos
    
    if [[ ! "$fix_repos" =~ ^[Nn]$ ]]; then
        info "Backing up sources.list..."
        cp /etc/apt/sources.list "/etc/apt/sources.list$BACKUP_SUFFIX"
        
        info "Creating ARM64-compatible sources.list..."
        cat > /etc/apt/sources.list << EOF
# ARM64 Ubuntu repositories
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ $UBUNTU_CODENAME main restricted universe multiverse
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ $UBUNTU_CODENAME-updates main restricted universe multiverse
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ $UBUNTU_CODENAME-backports main restricted universe multiverse
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ $UBUNTU_CODENAME-security main restricted universe multiverse
EOF
        
        success "ARM64 repositories configured"
    fi
}

# Update package lists
update_packages() {
    subheader "Package Repository Update"
    
    (apt update > /dev/null 2>&1) &
    spinner $! "Updating package lists"
    
    if wait $!; then
        success "Package lists updated"
    else
        error_exit "Failed to update package lists"
    fi
}

# Install required packages
install_packages() {
    header "Installing Required Packages"
    
    local packages=("cifs-utils" "keyutils")
    
    # Add kernel modules for older versions
    if dpkg --compare-versions "$UBUNTU_VERSION" lt "22.04"; then
        packages+=("linux-modules-extra-$(uname -r)")
    fi
    
    for package in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii  $package "; then
            success "$package already installed"
        else
            echo -n "  Installing $package... "
            if apt install -y "$package" &>/dev/null; then
                echo -e "${GREEN}✓${NC}"
            else
                echo -e "${RED}✗${NC}"
                error_exit "Failed to install $package"
            fi
        fi
    done
    
    # Verify mount.cifs
    if command -v mount.cifs >/dev/null 2>&1; then
        local cifs_version
        cifs_version=$(mount.cifs -V 2>&1 | grep -oP 'version: \K[0-9.]+' || echo "unknown")
        success "mount.cifs available (version: $cifs_version)"
    else
        error_exit "mount.cifs not found after installation"
    fi
}

# Validate username format
validate_username() {
    local username=$1
    
    if [[ "$username" =~ ^u[0-9]+$ ]]; then
        echo "main"
        return 0
    elif [[ "$username" =~ ^u[0-9]+-sub[0-9]+$ ]]; then
        echo "sub"
        return 0
    else
        echo "invalid"
        return 1
    fi
}

# Get Storage Box credentials
get_credentials() {
    header "Storage Box Configuration"
    
    echo -e "${CYAN}Please provide your Hetzner Storage Box details${NC}"
    echo -e "${GRAY}Need help? Check: https://docs.hetzner.com/robot/storage-box${NC}"
    echo
    
    # Username with validation
    while true; do
        question "Storage Box username (e.g., u123456 or u123456-sub1): "
        read -r storage_username
        
        if [[ -z "$storage_username" ]]; then
            warning "Username cannot be empty"
            continue
        fi
        
        user_type=$(validate_username "$storage_username")
        if [[ "$user_type" == "invalid" ]]; then
            warning "Invalid username format. Expected: u123456 or u123456-sub1"
            echo -e "${GRAY}  Main user: u followed by numbers${NC}"
            echo -e "${GRAY}  Sub-user: u followed by numbers, then -sub and number${NC}"
            continue
        fi
        
        if [[ "$user_type" == "main" ]]; then
            info "✓ Main user account detected"
        else
            info "✓ Sub-user account detected"
        fi
        break
    done
    
    # Password with confirmation
    while true; do
        question "Storage Box password: "
        read -r -s storage_password
        echo
        
        if [[ -z "$storage_password" ]]; then
            warning "Password cannot be empty"
            continue
        fi
        
        question "Confirm password: "
        read -r -s storage_password_confirm
        echo
        
        if [[ "$storage_password" != "$storage_password_confirm" ]]; then
            warning "Passwords do not match. Please try again."
            continue
        fi
        
        success "Password confirmed"
        break
    done
    
    # Auto-generate hostname and path
    if [[ "$user_type" == "sub" ]]; then
        storage_hostname="$storage_username.your-storagebox.de"  # Sub-users use full sub-user as hostname
        storage_path="$storage_username"  # Sub-users access their own folder
        default_mount="${DEFAULT_MOUNT_POINT}-${storage_username##*-}"
    else
        storage_hostname="${storage_username}.your-storagebox.de"  # Main users use username as hostname
        storage_path="backup"
        default_mount="$DEFAULT_MOUNT_POINT"
    fi
    
    echo
    info "Generated configuration:"
    echo -e "  ${BOLD}Username:${NC} $storage_username"
    echo -e "  ${BOLD}Hostname:${NC} $storage_hostname"
    echo -e "  ${BOLD}Path:${NC}     ${storage_path:-'/ (root)'}"
    echo -e "  ${BOLD}Type:${NC}     ${user_type^} User"
    echo
    
    # DNS check
    check_dns "$storage_hostname"
}

# Get mount options
get_mount_options() {
    subheader "Mount Options"
    
    # Mount point
    question "Mount point path [$default_mount]: "
    read -r mount_point
    [[ -z "$mount_point" ]] && mount_point="$default_mount"
    echo -e "  ${BOLD}Mount point:${NC} $mount_point"
    
    # UID/GID
    question "User ID for mounted files [$DEFAULT_UID]: "
    read -r mount_uid
    [[ -z "$mount_uid" ]] && mount_uid="$DEFAULT_UID"
    
    question "Group ID for mounted files [$DEFAULT_GID]: "
    read -r mount_gid
    [[ -z "$mount_gid" ]] && mount_gid="$DEFAULT_GID"
    
    echo -e "  ${BOLD}Ownership:${NC} UID=$mount_uid, GID=$mount_gid"
    
    # Performance tuning
    question "Enable performance tuning? [Y/n]: "
    read -r perf_tune
    
    # Build final mount options
    MOUNT_OPTIONS="iocharset=utf8,rw,seal,credentials=$CREDENTIALS_FILE"
    MOUNT_OPTIONS="${MOUNT_OPTIONS},uid=$mount_uid,gid=$mount_gid"
    MOUNT_OPTIONS="${MOUNT_OPTIONS},file_mode=0660,dir_mode=0770"
    
    # Add Hetzner Storage Box specific options (seal is critical for Hetzner)
    MOUNT_OPTIONS="${MOUNT_OPTIONS},noperm,domain=WORKGROUP"
    
    if [[ ! "$perf_tune" =~ ^[Nn]$ ]]; then
        mount_options="rsize=130048,wsize=130048,cache=loose"
        echo -e "  ${BOLD}Performance:${NC} Optimized for Hetzner network"
    else
        mount_options="cache=strict"
        echo -e "  ${BOLD}Performance:${NC} Default settings"
    fi
    
    [[ -n "$mount_options" ]] && MOUNT_OPTIONS="${MOUNT_OPTIONS},${mount_options}"
}

# Create credentials file
create_credentials_file() {
    subheader "Creating Credentials File"
    
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        warning "Credentials file exists"
        question "Overwrite existing credentials? [y/N]: "
        read -r overwrite
        
        if [[ "$overwrite" =~ ^[Yy]$ ]]; then
            cp "$CREDENTIALS_FILE" "${CREDENTIALS_FILE}$BACKUP_SUFFIX"
            info "Backed up to: ${CREDENTIALS_FILE}$BACKUP_SUFFIX"
        else
            info "Using existing credentials"
            return 0
        fi
    fi
    
    # Write password as-is for CIFS credentials file (no escaping required)
    {
        echo "username=$storage_username"
        echo "password=$storage_password"
        echo "domain=WORKGROUP"
    } > "$CREDENTIALS_FILE"
    
    chmod 0600 "$CREDENTIALS_FILE"
    chown root:root "$CREDENTIALS_FILE"
    success "Credentials file created with secure permissions"
}

# Create mount point directory
create_mount_point() {
    subheader "Preparing Mount Point"
    
    if [[ ! -d "$mount_point" ]]; then
        mkdir -p "$mount_point"
        success "Created directory: $mount_point"
    else
        if mountpoint -q "$mount_point"; then
            warning "Already mounted at $mount_point"
            question "Unmount existing mount? [y/N]: "
            read -r unmount_first
            
            if [[ "$unmount_first" =~ ^[Yy]$ ]]; then
                umount "$mount_point" || warning "Failed to unmount"
            else
                return 0
            fi
        fi
        
        if [[ -n "$(find "$mount_point" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
            warning "Directory not empty: $mount_point"
            find "$mount_point" -mindepth 1 -maxdepth 1 -ls | head -5
            question "Continue anyway? [y/N]: "
            read -r continue_anyway
            
            [[ ! "$continue_anyway" =~ ^[Yy]$ ]] && error_exit "Aborted: non-empty mount point"
        fi
    fi
}

# Test SMB versions
test_smb_versions() {
    subheader "Testing SMB Protocol Versions"
    
    local working_version=""
    local last_error=""
    
    # First test basic connectivity
    echo -n "  Testing connectivity to $storage_hostname:445... "
    if timeout 5 bash -c "echo >/dev/tcp/$storage_hostname/445" 2>/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        warning "Cannot connect to $storage_hostname:445. Check firewall/network."
    fi
    
    for version in "${SMB_VERSIONS[@]}"; do
        echo -n "  Testing SMB $version... "
        
        local test_mount="mount.cifs -o vers=$version,${MOUNT_OPTIONS}"
        if [[ -n "$storage_path" ]]; then
            test_mount="$test_mount //$storage_hostname/$storage_path $mount_point"
        else
            test_mount="$test_mount //$storage_hostname $mount_point"
        fi
        
        # Capture error for debugging
        last_error=$(timeout 10 bash -c "$test_mount" 2>&1)
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✓ Works${NC}"
            working_version="$version"
            umount "$mount_point" &>/dev/null || true
            break
        else
            echo -e "${YELLOW}✗ Not supported${NC}"
            # Log the actual error for debugging
            log "Mount error for SMB $version: $last_error"
            # Show first error for debugging
            if [[ "$version" == "${SMB_VERSIONS[0]}" ]]; then
                warning "Mount error: $last_error"
            fi
        fi
    done
    
    if [[ -z "$working_version" ]]; then
        error_exit "No compatible SMB version found. Last error: $last_error"
    fi
    
    SMB_VERSION="$working_version"
    success "Selected SMB version: $SMB_VERSION"
    MOUNT_OPTIONS="vers=$SMB_VERSION,${MOUNT_OPTIONS}"
}

# Test mount with retries
test_mount() {
    header "Testing Storage Box Mount"
    
    test_smb_versions
    
    local mount_command="mount.cifs -o ${MOUNT_OPTIONS}"
    if [[ -n "$storage_path" ]]; then
        mount_command="$mount_command //$storage_hostname/$storage_path $mount_point"
    else
        mount_command="$mount_command //$storage_hostname $mount_point"
    fi
    
    info "Mount command:"
    echo -e "${GRAY}  $mount_command${NC}"
    echo
    
    local attempt=1
    local last_error_output=""
    while [[ $attempt -le $MAX_RETRIES ]]; do
        echo -n "  Attempt $attempt/$MAX_RETRIES... "
        # Capture stderr to show real error on failure
        last_error_output=$(bash -c "$mount_command" 2>&1)
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}✓${NC}"
            success "Storage Box mounted successfully!"
            
            # Test write access
            local test_file
            test_file="$mount_point/.test-$(date +%s).tmp"
            echo -n "  Testing write access... "
            
            if echo "test" > "$test_file" 2>/dev/null; then
                rm "$test_file"
                echo -e "${GREEN}✓ Read/Write${NC}"
            else
                echo -e "${YELLOW}✗ Read-only${NC}"
                warning "Mount is read-only. Check permissions."
            fi
            
            # Show mount info
            echo
            df -h "$mount_point" | grep -v "^Filesystem" | while read -r line; do
                echo -e "  ${GRAY}$line${NC}"
            done
            
            return 0
        else
            echo -e "${RED}✗${NC}"
            # Log and display the real error output
            log "mount.cifs error: $last_error_output"
            if echo "$last_error_output" | grep -qi "Permission denied"; then
                warning "Mount failed: Permission denied. Likely causes:"
                echo "  - Wrong username or password in $CREDENTIALS_FILE"
                echo "  - Sub-user disabled or wrong sub-user used"
                echo "  - Using a share path not permitted for this sub-user"
            elif echo "$last_error_output" | grep -qi "No such file"; then
                warning "Mount failed: Share path not found. Verify //${storage_hostname}/${storage_path}"
            elif echo "$last_error_output" | grep -qi "Invalid argument"; then
                warning "Mount failed: Invalid argument. Check SMB version and mount options."
            fi
            ((attempt++))
            [[ $attempt -le $MAX_RETRIES ]] && sleep $RETRY_DELAY
        fi
    done
    
    error_exit "Failed to mount after $MAX_RETRIES attempts. Last error: ${last_error_output}"
}

# Add to fstab or systemd
add_permanent_mount() {
    header "Permanent Mount Configuration"
    
    echo -e "${CYAN}Choose mount method:${NC}"
    echo "  1) fstab (traditional, simple)"
    echo "  2) systemd mount unit (modern, more control)"
    echo "  3) Skip permanent mount"
    echo
    question "Your choice [1-3]: "
    read -r mount_method
    
    case "$mount_method" in
        1)
            add_to_fstab
            ;;
        2)
            create_systemd_mount
            ;;
        3)
            info "Skipping permanent mount configuration"
            ;;
        *)
            warning "Invalid choice. Skipping permanent mount."
            ;;
    esac
}

# Add to fstab
add_to_fstab() {
    subheader "Adding fstab Entry"
    
    local fstab_entry
    if [[ -n "$storage_path" ]]; then
        fstab_entry="//$storage_hostname/$storage_path $mount_point cifs ${MOUNT_OPTIONS},_netdev,x-systemd.automount,x-systemd.idle-timeout=60 0 0"
    else
        fstab_entry="//$storage_hostname $mount_point cifs ${MOUNT_OPTIONS},_netdev,x-systemd.automount,x-systemd.idle-timeout=60 0 0"
    fi
    
    # Backup fstab
    cp /etc/fstab "/etc/fstab$BACKUP_SUFFIX"
    info "Backed up fstab to: /etc/fstab$BACKUP_SUFFIX"
    
    # Check existing entry
    if grep -q "$mount_point" /etc/fstab; then
        sed -i "\|$mount_point|d" /etc/fstab
        warning "Replaced existing fstab entry"
    fi
    
    # Add entry
    echo "$fstab_entry" >> /etc/fstab
    success "fstab entry added with automount support"
    
    # Test
    umount "$mount_point" 2>/dev/null || true
    if mount "$mount_point"; then
        success "fstab configuration verified"
    else
        warning "fstab test failed - manual intervention may be needed"
    fi
}

# Create systemd mount unit
create_systemd_mount() {
    subheader "Creating systemd Mount Unit"
    
    local unit_name
    unit_name=$(systemd-escape -p "$mount_point").mount
    local unit_file="/etc/systemd/system/$unit_name"
    
    cat > "$unit_file" << EOF
[Unit]
Description=Hetzner Storage Box mount for $storage_username
After=network-online.target
Wants=network-online.target

[Mount]
What=//$storage_hostname$([ -n "$storage_path" ] && echo "/$storage_path" || echo "")
Where=$mount_point
Type=cifs
Options=${MOUNT_OPTIONS},_netdev
TimeoutSec=30

[Install]
WantedBy=multi-user.target
EOF
    
    # Create automount unit
    local automount_file="${unit_file%.mount}.automount"
    cat > "$automount_file" << EOF
[Unit]
Description=Automount Hetzner Storage Box for $storage_username
After=network-online.target
Wants=network-online.target

[Automount]
Where=$mount_point
TimeoutIdleSec=60

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "$unit_name"
    systemctl enable "${unit_name%.mount}.automount"
    
    # If the mount point is already mounted (from test step), unmount it so
    # systemd automount can take control cleanly.
    if mountpoint -q "$mount_point"; then
        info "Unmounting existing mount at $mount_point to activate systemd automount"
        if umount "$mount_point"; then
            success "Unmounted $mount_point"
        else
            warning "Failed to unmount $mount_point; systemd may fail to start."
            warning "You can unmount manually and then run: systemctl start ${unit_name%.mount}.automount"
        fi
    fi
    
    if systemctl start "${unit_name%.mount}.automount"; then
        success "systemd mount units created and enabled"
    else
        warning "Failed to start automount. Run: journalctl -u ${unit_name%.mount}.automount -xe"
    fi
}

# Show usage recommendations
show_usage_recommendations() {
    header "Setup Complete!"
    
    echo -e "${GREEN}${BOLD}✓ Storage Box mounted at: $mount_point${NC}"
    echo
    
    echo -e "${CYAN}${BOLD}Quick Stats:${NC}"
    df -h "$mount_point" | tail -1 | awk '{
        printf "  Total Space:  %s\n", $2
        printf "  Used Space:   %s (%s)\n", $3, $5
        printf "  Free Space:   %s\n", $4
    }'
    echo
    
    echo -e "${CYAN}${BOLD}Useful Commands:${NC}"
    echo -e "  ${WHITE}df -h $mount_point${NC}              ${GRAY}# Check space${NC}"
    echo -e "  ${WHITE}mount | grep $mount_point${NC}       ${GRAY}# View mount details${NC}"
    echo -e "  ${WHITE}umount $mount_point${NC}             ${GRAY}# Unmount${NC}"
    echo -e "  ${WHITE}mount $mount_point${NC}              ${GRAY}# Remount${NC}"
    echo
    
    echo -e "${CYAN}${BOLD}Performance Tips:${NC}"
    echo "  • Use for: Backups, archives, media files"
    echo "  • Avoid for: Databases, high-frequency I/O"
    echo "  • Expected: 300-800 MB/s within Hetzner network"
    echo
    
    echo -e "${CYAN}${BOLD}Configuration Files:${NC}"
    echo -e "  Credentials: ${WHITE}$CREDENTIALS_FILE${NC}"
    echo -e "  Mount point: ${WHITE}$mount_point${NC}"
    echo -e "  Logs:        ${WHITE}$LOG_FILE${NC}"
    
    if [[ -f "/etc/fstab$BACKUP_SUFFIX" ]]; then
        echo -e "  fstab backup: ${WHITE}/etc/fstab$BACKUP_SUFFIX${NC}"
    fi
    
    echo
    echo -e "${GREEN}${BOLD}Need help? Visit: https://docs.hetzner.com/robot/storage-box${NC}"
}

# Cleanup on error
cleanup_on_error() {
    if [[ -f "${CREDENTIALS_FILE}.tmp" ]]; then
        rm -f "${CREDENTIALS_FILE}.tmp"
    fi
    
    if mountpoint -q "$mount_point" 2>/dev/null; then
        umount "$mount_point" 2>/dev/null || true
    fi
}

# Main execution
main() {
    show_welcome
    
    # Pre-checks
    check_root
    
    header "System Preparation"
    detect_system
    check_network
    
    # Repository and packages
    fix_arm64_repositories
    update_packages
    install_packages
    
    # Configuration
    get_credentials
    get_mount_options
    
    # Implementation
    create_credentials_file
    create_mount_point
    test_mount
    add_permanent_mount
    
    # Final
    show_usage_recommendations
    
    echo
    success "${BOLD}Installation completed successfully!${NC}"
    info "Full log available at: $LOG_FILE"
}

# Entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi