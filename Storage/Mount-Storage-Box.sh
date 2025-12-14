#!/bin/bash

################################################################################
# Hetzner Storage Box Auto-Mount Script
# Production Version with Advanced Features
# Version: 1.1.3
# Author: Nskha Automation Projects - Hetzner Community Edition
# License: MIT
#
# Description:
#   Automates the mounting of Hetzner Storage Boxes on Linux systems.
#   Supports multiple distributions, SMB protocol negotiation, and
#   both interactive and non-interactive modes.
#   Supports multiple storage boxes via named profiles.
#
# Usage:
#   Interactive mode: ./Mount-Storage-Box.sh
#   Non-interactive: ./Mount-Storage-Box.sh --non-interactive [OPTIONS]
#   With profile:     ./Mount-Storage-Box.sh --profile NAME [OPTIONS]
#   List profiles:    ./Mount-Storage-Box.sh --list-profiles
#   Help: ./Mount-Storage-Box.sh --help
################################################################################

# Enable strict error handling
# -e: Exit on error
# -E: ERR trap is inherited by shell functions
# -u: Treat unset variables as errors
# -o pipefail: Pipe command fails if any command in the pipe fails
set -eEuo pipefail

# Set up error handling and signal traps
trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

# Colors and styling - Safer fallback
if [[ "${TERM:-}" != "dumb" ]] && [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    # Only use colors if terminal explicitly supports them
    # shellcheck disable=SC2312
    if tput colors >/dev/null 2>&1 && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
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

################################################################################
# Global Configuration Variables
################################################################################

# Script version
readonly VERSION="1.1.3"
# File paths and defaults - these will be computed dynamically based on profile
readonly CREDENTIALS_BASE="/etc/cifs-credentials"
readonly MOUNT_POINT_BASE="/mnt/hetzner-storage"
# shellcheck disable=SC2155
readonly BACKUP_SUFFIX=".backup-$(date +%Y%m%d-%H%M%S)"

# Profile configuration - empty means default (backward compatible)
PROFILE=""
# These will be set dynamically based on profile in compute_profile_paths()
CREDENTIALS_FILE=""
DEFAULT_MOUNT_POINT=""
readonly MAX_RETRIES=3
readonly RETRY_DELAY=5
readonly SMB_VERSIONS=("3.1.1" "3.0" "2.1" "2.0" "1.0")
# shellcheck disable=SC2155
readonly DEFAULT_UID=$(id -u)
# shellcheck disable=SC2155
readonly DEFAULT_GID=$(id -g)

# Non-interactive mode variables (can be set via command line)
NON_INTERACTIVE=false
USERNAME_ARG=""
PASSWORD_ARG=""
PASSWORD_FILE=""
MOUNT_POINT_ARG=""
UID_ARG=""
GID_ARG=""
PERF_TUNING=true
MOUNT_METHOD="systemd"  # systemd, fstab, or none
SKIP_CONFIRMATION=false
VERBOSE=false
DRY_RUN=false
PROFILE_ARG=""
LIST_PROFILES=false

# Logging configuration
# Initialize logging variables without creating directories yet
LOG_DIR="/var/log/hetzner-mount"
LOG_FILE=""  # Will be set after root check
LOG_ENABLED=false  # Will be enabled after successful log setup

# UI elements
readonly SPINNER_CHARS="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

# Distribution detection variables
DISTRO=""
DISTRO_VERSION=""
PACKAGE_MANAGER=""
SERVICE_MANAGER=""

################################################################################
# Utility Functions
################################################################################

# Log a message to both console and log file
# Arguments:
#   $1 - Message to log
# Strips ANSI escape sequences from log file output while preserving colors
# in terminal output
log() {
    local msg="${1:-}"
    local clean_msg
    
    # Always output to console
    echo -e "$msg"
    
    # Only write to log file if logging is enabled and file is writable
    if [[ "$LOG_ENABLED" == "true" ]] && [[ -n "$LOG_FILE" ]]; then
        # Remove ANSI escape sequences for log file
        # This handles both actual ESC bytes (\x1b) and literal \033 strings
        clean_msg=$(printf '%s' "$msg" \
            | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' \
            | sed -E 's/\\033\[[0-9;]*[A-Za-z]//g')
        # Write to log file if possible
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $clean_msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# Enhanced error handler with command context
# Arguments:
#   $1 - Exit code
#   $2 - Line number
#   $3 - Command that failed
handle_error() {
    local exit_code=$1
    local line_no=$2
    local cmd="${3:-Unknown command}"
    
    log "${RED}✗ ERROR: Command failed at line $line_no${NC}"
    log "${RED}  Exit code: $exit_code${NC}"
    log "${RED}  Command: $cmd${NC}"
    if [[ "$LOG_ENABLED" == "true" ]] && [[ -n "$LOG_FILE" ]]; then
        log "${RED}  Log file: $LOG_FILE${NC}"
    fi
    
    cleanup_on_error
    exit "$exit_code"
}

# Signal handler for graceful shutdown
# Arguments:
#   $1 - Signal name (INT, TERM, etc.)
handle_signal() {
    local signal="$1"
    log "${YELLOW}⚠ Received signal: $signal${NC}"
    log "${YELLOW}  Cleaning up and exiting...${NC}"
    cleanup_on_error
    exit 130  # Standard exit code for terminated by signal
}

# Exit with error message
# Arguments:
#   $1 - Error message
#   $2 - Exit code (optional, default: 1)
error_exit() {
    local message="${1:-Unknown error}"
    local exit_code="${2:-1}"
    log "${RED}✗ ERROR: $message${NC}"
    cleanup_on_error
    exit "$exit_code"
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

# Display a question to the user
# Arguments:
#   $1 - Question text
question() {
    echo -e "${MAGENTA}❓ $1${NC}"
}

# Display a formatted header section
# Arguments:
#   $1 - Header text
header() {
    local width=60
    local text="$1"
    local text_len=${#text}
    local padding=$(( (width - text_len - 2) / 2 ))
    local right_padding=$(( width - padding - text_len ))
    
    echo
    echo -e "${BLUE}${BOLD}╔$(printf '═%.0s' {1..60})╗${NC}"
    echo -e "${BLUE}${BOLD}║$(printf ' %.0s' $(seq 1 "$padding"))$text$(printf ' %.0s' $(seq 1 "$right_padding"))║${NC}"
    echo -e "${BLUE}${BOLD}╚$(printf '═%.0s' {1..60})╝${NC}"
    echo
}

# Display a subheader for sections
# Arguments:
#   $1 - Subheader text
subheader() {
    echo -e "${CYAN}${BOLD}▶ $1${NC}"
    echo -e "${GRAY}$(printf '─%.0s' {1..40})${NC}"
}

# Display a spinner while a background process runs
# Arguments:
#   $1 - Process ID to monitor
#   $2 - Message to display
spinner() {
    local pid=$1
    local message=$2
    local i=0
    local tput_available=false
    
    # Check tput availability once
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && tput el >/dev/null 2>&1; then
        tput_available=true
    fi
    
    # Display spinner while process is running
    while kill -0 "$pid" 2>/dev/null; do
        if [[ "$tput_available" == true ]]; then
            printf "\r%s %s..." "${SPINNER_CHARS:i++%${#SPINNER_CHARS}:1}" "$message"
            tput el  # Clear to end of line
        else
            printf "\r%s..." "$message"
        fi
        sleep 0.1
    done
    
    # Clear the spinner line
    if [[ "$tput_available" == true ]]; then
        printf "\r"
        tput el
    else
        printf "\r%*s\r" $(( ${#message} + 5 )) ""
    fi
}

################################################################################
# Profile Management Functions
################################################################################

# Compute dynamic file paths based on profile
# Sets CREDENTIALS_FILE and DEFAULT_MOUNT_POINT based on PROFILE variable
# Must be called after parse_arguments() and before any functions that use these paths
compute_profile_paths() {
    if [[ -n "$PROFILE" ]]; then
        # Profile-specific paths
        CREDENTIALS_FILE="${CREDENTIALS_BASE}-${PROFILE}.txt"
        DEFAULT_MOUNT_POINT="${MOUNT_POINT_BASE}-${PROFILE}"
        if [[ "$VERBOSE" == "true" ]]; then
            info "Using profile: $PROFILE"
            info "  Credentials file: $CREDENTIALS_FILE"
            info "  Default mount point: $DEFAULT_MOUNT_POINT"
        fi
    else
        # Default paths (backward compatible)
        CREDENTIALS_FILE="${CREDENTIALS_BASE}.txt"
        DEFAULT_MOUNT_POINT="${MOUNT_POINT_BASE}"
    fi
}

# List all configured profiles
# Searches for credentials files and systemd mount units
list_profiles() {
    header "Configured Storage Box Profiles"
    
    local found_profiles=false
    local profiles=()
    
    # Find profiles from credentials files
    while IFS= read -r -d '' cred_file; do
        local profile_name
        local filename
        filename=$(basename "$cred_file")
        
        # Extract profile name from filename
        if [[ "$filename" == "cifs-credentials.txt" ]]; then
            profile_name="(default)"
        elif [[ "$filename" =~ ^cifs-credentials-(.+)\.txt$ ]]; then
            profile_name="${BASH_REMATCH[1]}"
        else
            continue
        fi
        
        profiles+=("$profile_name:$cred_file")
        found_profiles=true
    done < <(find /etc -maxdepth 1 -name "cifs-credentials*.txt" -print0 2>/dev/null)
    
    if [[ "$found_profiles" == "false" ]]; then
        info "No profiles configured yet."
        echo
        echo "To create a profile, run:"
        echo "  $0 --profile <name> [OPTIONS]"
        echo
        echo "Or run without --profile for default configuration:"
        echo "  $0"
        return 0
    fi
    
    echo -e "${CYAN}${BOLD}Found Profiles:${NC}"
    echo -e "${GRAY}$(printf '─%.0s' {1..60})${NC}"
    
    for profile_entry in "${profiles[@]}"; do
        IFS=':' read -r profile_name cred_file <<< "$profile_entry"
        
        echo -e "\n${WHITE}${BOLD}Profile: $profile_name${NC}"
        echo -e "  Credentials: ${GRAY}$cred_file${NC}"
        
        # Get username from credentials file
        local username
        username=$(grep '^username=' "$cred_file" 2>/dev/null | cut -d'=' -f2 || echo "unknown")
        echo -e "  Username: ${GRAY}$username${NC}"
        
        # Find associated mount points
        local mount_point_suffix=""
        if [[ "$profile_name" != "(default)" ]]; then
            mount_point_suffix="-${profile_name}"
        fi
        local expected_mount="${MOUNT_POINT_BASE}${mount_point_suffix}"
        
        # Check if mounted
        if mountpoint -q "$expected_mount" 2>/dev/null; then
            echo -e "  Mount point: ${GREEN}$expected_mount (mounted)${NC}"
            # Show disk usage
            local usage
            usage=$(df -h "$expected_mount" 2>/dev/null | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')
            echo -e "  Usage: ${GRAY}$usage${NC}"
        elif [[ -d "$expected_mount" ]]; then
            echo -e "  Mount point: ${YELLOW}$expected_mount (not mounted)${NC}"
        else
            echo -e "  Mount point: ${GRAY}$expected_mount (not created)${NC}"
        fi
        
        # Check for systemd units
        local unit_name
        unit_name=$(systemd-escape -p "$expected_mount" 2>/dev/null).mount
        if [[ -f "/etc/systemd/system/$unit_name" ]]; then
            local unit_status
            unit_status=$(systemctl is-enabled "$unit_name" 2>/dev/null || echo "unknown")
            echo -e "  Systemd unit: ${GRAY}$unit_name ($unit_status)${NC}"
        fi
        
        # Check for fstab entry
        if grep -q "$expected_mount" /etc/fstab 2>/dev/null; then
            echo -e "  fstab: ${GRAY}configured${NC}"
        fi
    done
    
    echo
    echo -e "${GRAY}$(printf '─%.0s' {1..60})${NC}"
    echo -e "${CYAN}Total profiles: ${#profiles[@]}${NC}"
    echo
    echo "To add a new profile:"
    echo "  $0 --profile <name> -n -u <username> -f <password-file>"
}

################################################################################
# Help and Usage Functions
################################################################################

# Display usage information
show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Automatically mount Hetzner Storage Box on Linux systems.
Supports multiple storage boxes via named profiles.

OPTIONS:
    -h, --help              Show this help message
    -v, --version           Show script version
    -n, --non-interactive   Run in non-interactive mode
    -u, --username USER     Storage Box username (e.g., u123456)
    -p, --password PASS     Storage Box password (NOT recommended)
    -f, --password-file FILE Read password from file
    -m, --mount-point PATH  Custom mount point (default: $MOUNT_POINT_BASE)
    --profile NAME          Profile name for multi-account support
                            Creates separate credentials and mount points
    --list-profiles         List all configured profiles and exit
    --uid UID               User ID for mounted files
    --gid GID               Group ID for mounted files
    --no-tuning             Disable performance tuning
    --mount-method METHOD   Mount method: systemd, fstab, none
    --skip-confirmation     Skip confirmation prompts
    --dry-run               Show what would be done without making changes
    --verbose               Enable verbose output

EXAMPLES:
    # Interactive mode (recommended)
    $(basename "$0")
    
    # Non-interactive with password file
    $(basename "$0") -n -u u123456 -f /secure/pass.txt
    
    # Custom mount point
    $(basename "$0") -n -u u123456 -f /secure/pass.txt -m /data/storage
    
    # Mount primary storage with profile
    $(basename "$0") --profile primary -n -u u123456 -f /secure/pass1.txt
    
    # Mount backup storage with different profile
    $(basename "$0") --profile backup -n -u u789012 -f /secure/pass2.txt
    
    # List all configured profiles
    $(basename "$0") --list-profiles

PROFILE USAGE:
    Profiles allow mounting multiple Hetzner Storage Boxes simultaneously.
    Each profile creates:
      - Credentials file: /etc/cifs-credentials-{profile}.txt
      - Mount point:      /mnt/hetzner-storage-{profile}
      - Systemd units:    Named with profile suffix
    
    Without --profile, uses default paths (backward compatible).

For more information, visit:
https://docs.hetzner.com/robot/storage-box

EOF
}

# Display welcome banner
show_welcome() {
    if [[ "$NON_INTERACTIVE" == "false" ]]; then
        clear
    fi
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
    echo -e "${CYAN}Version $VERSION - Production${NC}"
    echo -e "${GRAY}────────────────────────────────────────${NC}"
    echo
    if [[ "$NON_INTERACTIVE" == "false" ]]; then
        sleep 1
    fi
}

################################################################################
# Command-line Argument Parsing
################################################################################

# Parse command-line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                echo "Mount-Storage-Box.sh version $VERSION"
                exit 0
                ;;
            -n|--non-interactive)
                NON_INTERACTIVE=true
                shift
                ;;
            -u|--username)
                USERNAME_ARG="$2"
                shift 2
                ;;
            -p|--password)
                PASSWORD_ARG="$2"
                warning "Using password on command line is insecure!"
                shift 2
                ;;
            -f|--password-file)
                PASSWORD_FILE="$2"
                shift 2
                ;;
            -m|--mount-point)
                MOUNT_POINT_ARG="$2"
                shift 2
                ;;
            --uid)
                UID_ARG="$2"
                shift 2
                ;;
            --gid)
                GID_ARG="$2"
                shift 2
                ;;
            --no-tuning)
                PERF_TUNING=false
                shift
                ;;
            --mount-method)
                MOUNT_METHOD="$2"
                shift 2
                ;;
            --skip-confirmation)
                SKIP_CONFIRMATION=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                NON_INTERACTIVE=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --profile)
                PROFILE_ARG="$2"
                shift 2
                ;;
            --list-profiles)
                LIST_PROFILES=true
                shift
                ;;
            *)
                error_exit "Unknown option: $1\nUse --help for usage information."
                ;;
        esac
    done
    
    # Set profile if provided
    if [[ -n "$PROFILE_ARG" ]]; then
        # Validate profile name (alphanumeric, dash, underscore only)
        if [[ ! "$PROFILE_ARG" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            error_exit "Invalid profile name: $PROFILE_ARG\nProfile names can only contain letters, numbers, dashes, and underscores."
        fi
        PROFILE="$PROFILE_ARG"
    fi
    
    # Validate non-interactive mode requirements (skip in dry-run)
    if [[ "$NON_INTERACTIVE" == "true" && "$DRY_RUN" != "true" ]]; then
        if [[ -z "$USERNAME_ARG" ]]; then
            error_exit "Username is required in non-interactive mode. Use -u or --username."
        fi
        if [[ -z "$PASSWORD_ARG" && -z "$PASSWORD_FILE" ]]; then
            error_exit "Password is required in non-interactive mode. Use -f or --password-file."
        fi
        if [[ -n "$PASSWORD_FILE" && ! -f "$PASSWORD_FILE" ]]; then
            error_exit "Password file not found: $PASSWORD_FILE"
        fi
    fi
}

################################################################################
# Network and System Detection Functions
################################################################################

# Check network connectivity
check_network() {
    subheader "Network Connectivity Check"
    
    local test_hosts=(
        "your-storagebox.de:Hetzner Storage"
        "8.8.8.8:Google DNS"
        "1.1.2.1:Cloudflare DNS"
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

# Enhanced system detection supporting multiple distributions
detect_system() {
    subheader "System Detection"
    
    # Architecture
    ARCH=$(uname -m)
    echo -e "  Architecture: ${WHITE}$ARCH${NC}"
    
    # Robust distribution detection using multiple methods
    # Method 1: Try /etc/os-release with safe parsing (no shell eval, no unset)
    if [[ -f /etc/os-release ]]; then
        DISTRO=$(grep '^ID=' /etc/os-release 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' || echo "unknown")
        DISTRO_VERSION=$(grep '^VERSION_ID=' /etc/os-release 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' || echo "unknown")
        DISTRO_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' || echo "")
        DISTRO_NAME=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' || echo "$DISTRO $DISTRO_VERSION")
    # Method 2: Try /etc/lsb-release (safe parsing)
    elif [[ -f /etc/lsb-release ]]; then
        DISTRO=$(grep '^DISTRIB_ID=' /etc/lsb-release 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' || echo "unknown")
        DISTRO_VERSION=$(grep '^DISTRIB_RELEASE=' /etc/lsb-release 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' || echo "unknown")
        DISTRO_CODENAME=$(grep '^DISTRIB_CODENAME=' /etc/lsb-release 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' || echo "")
        DISTRO_NAME=$(grep '^DISTRIB_DESCRIPTION=' /etc/lsb-release 2>/dev/null | head -1 | cut -d'=' -f2 | tr -d '"' || echo "$DISTRO $DISTRO_VERSION")
    # Method 3: Try alternative detection methods
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
        DISTRO_VERSION=$(cat /etc/debian_version 2>/dev/null || echo "unknown")
        DISTRO_NAME="Debian $DISTRO_VERSION"
        DISTRO_CODENAME=""
    elif [[ -f /etc/redhat-release ]]; then
        DISTRO="rhel"
        DISTRO_VERSION=$(rpm -E '%{rhel}' 2>/dev/null || echo "unknown")
        DISTRO_NAME=$(cat /etc/redhat-release 2>/dev/null || echo "Red Hat Enterprise Linux")
        DISTRO_CODENAME=""
    # Method 4: Fallback to basic detection
    else
        # Last resort: use uname and basic heuristics
        local uname_info
        uname_info=$(uname -a 2>/dev/null || echo "unknown")
        if echo "$uname_info" | grep -qi ubuntu; then
            DISTRO="ubuntu"
            DISTRO_VERSION="unknown"
            DISTRO_NAME="Ubuntu (detected from uname)"
        elif echo "$uname_info" | grep -qi debian; then
            DISTRO="debian"
            DISTRO_VERSION="unknown"
            DISTRO_NAME="Debian (detected from uname)"
        else
            DISTRO="unknown"
            DISTRO_VERSION="unknown"
            DISTRO_NAME="Unknown Linux Distribution"
        fi
        DISTRO_CODENAME=""
        warning "Could not reliably detect distribution. Proceeding with best guess: $DISTRO_NAME"
    fi
    
    # Convert distribution ID to lowercase for consistency
    DISTRO=$(echo "$DISTRO" | tr '[:upper:]' '[:lower:]')
    
    echo -e "  Distribution: ${WHITE}$DISTRO_NAME${NC}"
    
    # Detect package manager and service manager
    if command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt"
    elif command -v yum >/dev/null 2>&1; then
        PACKAGE_MANAGER="yum"
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER="dnf"
    elif command -v zypper >/dev/null 2>&1; then
        PACKAGE_MANAGER="zypper"
    else
        error_exit "No supported package manager found (apt, yum, dnf, zypper)."
    fi
    
    # Detect service manager
    if command -v systemctl >/dev/null 2>&1; then
        SERVICE_MANAGER="systemd"
    elif command -v service >/dev/null 2>&1; then
        SERVICE_MANAGER="sysvinit"
    else
        SERVICE_MANAGER="unknown"
    fi
    
    echo -e "  Package Manager: ${WHITE}$PACKAGE_MANAGER${NC}"
    echo -e "  Service Manager: ${WHITE}$SERVICE_MANAGER${NC}"
    
    # Kernel version
    KERNEL=$(uname -r)
    echo -e "  Kernel: ${WHITE}$KERNEL${NC}"
    
    # Available memory
    MEM_TOTAL=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}' || echo "unknown")
    echo -e "  Memory: ${WHITE}$MEM_TOTAL${NC}"
    
    # Check if ARM64
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        IS_ARM64=true
        if [[ "$DISTRO" == "ubuntu" ]]; then
            echo -e "  ${YELLOW}Note: ARM64 detected - will use ports.ubuntu.com${NC}"
        fi
    else
        IS_ARM64=false
    fi
    
    # Set Ubuntu-specific variables for compatibility
    if [[ "$DISTRO" == "ubuntu" ]]; then
        UBUNTU_CODENAME="$DISTRO_CODENAME"
    fi
    
    if [[ "$NON_INTERACTIVE" == "false" ]]; then
        sleep 1
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root. Please run: sudo $0"
    fi
}

# Setup logging after root check
# Creates log directory and initializes log file
# Falls back to temp directory if /var/log is not writable
setup_logging() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    
    # Try to create the primary log directory
    if mkdir -p "$LOG_DIR" 2>/dev/null; then
        LOG_FILE="$LOG_DIR/mount-${timestamp}.log"
        # Test if we can write to the log file
        if echo "Log initialized at $(date)" >> "$LOG_FILE" 2>/dev/null; then
            LOG_ENABLED=true
            readonly LOG_FILE
            if [[ "$VERBOSE" == "true" ]]; then
                info "Logging enabled: $LOG_FILE"
            fi
        else
            # Can't write to the file, disable logging
            LOG_ENABLED=false
            LOG_FILE=""
            if [[ "$VERBOSE" == "true" ]]; then
                warning "Cannot write to log file in $LOG_DIR, logging disabled"
            fi
        fi
    else
        # Try fallback to /tmp if we're root but still can't create /var/log directory
        LOG_DIR="/tmp/hetzner-mount"
        if mkdir -p "$LOG_DIR" 2>/dev/null; then
            LOG_FILE="$LOG_DIR/mount-${timestamp}.log"
            if echo "Log initialized at $(date)" >> "$LOG_FILE" 2>/dev/null; then
                LOG_ENABLED=true
                readonly LOG_FILE
                if [[ "$VERBOSE" == "true" ]]; then
                    warning "Using fallback log location: $LOG_FILE"
                fi
            else
                LOG_ENABLED=false
                LOG_FILE=""
                if [[ "$VERBOSE" == "true" ]]; then
                    warning "Cannot create log file, logging disabled"
                fi
            fi
        else
            # Complete failure, disable logging
            LOG_ENABLED=false
            LOG_FILE=""
            if [[ "$VERBOSE" == "true" ]]; then
                warning "Cannot create log directory, logging disabled"
            fi
        fi
    fi
}

# Fix repositories for ARM64 (Ubuntu-specific)
fix_arm64_repositories() {
    # Only applicable for Ubuntu on ARM64
    if [[ "$IS_ARM64" != true || "$DISTRO" != "ubuntu" ]]; then
        return 0
    fi
    
    header "ARM64 Repository Configuration"
    
    if grep -q "ports.ubuntu.com" /etc/apt/sources.list 2>/dev/null; then
        success "ARM64 repositories already configured correctly"
        return 0
    fi
    
    warning "ARM64 Ubuntu system with incorrect repository configuration detected"
    
    if [[ "$NON_INTERACTIVE" == "false" ]]; then
        question "Fix repository configuration? (recommended) [Y/n]: "
        read -r fix_repos </dev/tty
        
        if [[ "$fix_repos" =~ ^[Nn]$ ]]; then
            return 0
        fi
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would backup and update /etc/apt/sources.list for ARM64"
        return 0
    fi
    
    info "Backing up sources.list..."
    cp /etc/apt/sources.list "/etc/apt/sources.list$BACKUP_SUFFIX"
    
    info "Creating ARM64-compatible sources.list..."
    cat > /etc/apt/sources.list << EOF
# ARM64 Ubuntu repositories
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ ${UBUNTU_CODENAME:-focal} main restricted universe multiverse
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ ${UBUNTU_CODENAME:-focal}-updates main restricted universe multiverse
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ ${UBUNTU_CODENAME:-focal}-backports main restricted universe multiverse
deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports/ ${UBUNTU_CODENAME:-focal}-security main restricted universe multiverse
EOF
    
    success "ARM64 repositories configured"
}

# Update package lists based on distribution
update_packages() {
    subheader "Package Repository Update"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would update package lists using $PACKAGE_MANAGER"
        return 0
    fi
    
    local update_cmd
    case "$PACKAGE_MANAGER" in
        apt)
            update_cmd="apt-get update"
            ;;
        yum)
            update_cmd="yum makecache"
            ;;
        dnf)
            update_cmd="dnf makecache"
            ;;
        zypper)
            update_cmd="zypper refresh"
            ;;
        *)
            error_exit "Unsupported package manager: $PACKAGE_MANAGER"
            ;;
    esac
    
    if [[ "$VERBOSE" == "true" ]]; then
        info "Running: $update_cmd"
    fi
    
    ($update_cmd > /dev/null 2>&1) &
    spinner "$!" "Updating package lists"
    
    if wait $!; then
        success "Package lists updated"
    else
        warning "Failed to update package lists (non-critical)"
    fi
}

# Install required packages based on distribution
install_packages() {
    header "Installing Required Packages"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would install: cifs-utils keyutils"
        return 0
    fi
    
    local packages
    local -a install_cmd
    local -a check_cmd
    
    # Set package names and commands based on distribution
    case "$PACKAGE_MANAGER" in
        apt)
            packages=("cifs-utils" "keyutils")
            install_cmd=(apt-get install -y)
            check_cmd=(dpkg -l)
            
            # Check if CIFS kernel module is available
            # If not, we need linux-modules-extra package (common in containers/VMs)
            if ! modprobe cifs &>/dev/null; then
                # shellcheck disable=SC2155
                local kernel_pkg
                kernel_pkg="linux-modules-extra-$(uname -r)"
                if apt-cache show "$kernel_pkg" &>/dev/null; then
                    info "CIFS kernel module not loaded, adding $kernel_pkg"
                    packages+=("$kernel_pkg")
                else
                    warning "CIFS module missing and $kernel_pkg not available"
                    warning "You may need to install kernel modules manually"
                fi
            fi
            ;;
        yum|dnf)
            packages=("cifs-utils" "keyutils")
            install_cmd=("$PACKAGE_MANAGER" install -y)
            check_cmd=(rpm -q)
            ;;
        zypper)
            packages=("cifs-utils" "keyutils")
            install_cmd=(zypper install -y)
            check_cmd=(rpm -q)
            ;;
        *)
            error_exit "Unsupported package manager: $PACKAGE_MANAGER"
            ;;
    esac
    
    # Install each package
    for package in "${packages[@]}"; do
        # Check if package is already installed
        # For apt, we need special handling since dpkg -l needs grep
        local is_installed=false
        if [[ "$PACKAGE_MANAGER" == "apt" ]]; then
            if dpkg -l "$package" 2>/dev/null | grep -q "^ii"; then
                is_installed=true
            fi
        else
            if "${check_cmd[@]}" "$package" &>/dev/null; then
                is_installed=true
            fi
        fi
        
        if [[ "$is_installed" == "true" ]]; then
            success "$package already installed"
        else
            echo -n "  Installing $package... "
            if [[ "$VERBOSE" == "true" ]]; then
                info "Running: ${install_cmd[*]} $package"
            fi
            
            if "${install_cmd[@]}" "$package" &>/dev/null; then
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
    
    # Check for missing shared libraries (error 79 prevention)
    # This catches issues where mount.cifs binary exists but required libs are missing
    local missing_libs
    if command -v ldd >/dev/null 2>&1; then
        missing_libs=$(ldd "$(command -v mount.cifs)" 2>/dev/null | grep "not found" || true)
        if [[ -n "$missing_libs" ]]; then
            warning "Missing shared libraries for mount.cifs:"
            echo "$missing_libs"
            error_exit "mount.cifs has missing dependencies. Try: apt reinstall cifs-utils"
        fi
    fi
    
    # Ensure CIFS kernel module is loaded
    if ! lsmod | grep -q "^cifs"; then
        info "Loading CIFS kernel module..."
        if modprobe cifs 2>/dev/null; then
            success "CIFS kernel module loaded"
        else
            error_exit "Failed to load CIFS kernel module. You may need to install linux-modules-extra-$(uname -r) or reboot after installing it."
        fi
    else
        success "CIFS kernel module already loaded"
    fi
    
    # Ensure NLS UTF-8 module is loaded (required for iocharset=utf8 mount option)
    if ! lsmod | grep -q "^nls_utf8"; then
        info "Loading NLS UTF-8 kernel module..."
        if modprobe nls_utf8 2>/dev/null; then
            success "NLS UTF-8 module loaded"
        else
            warning "nls_utf8 module not available. Attempting to install kernel modules package."
            if [[ "$PACKAGE_MANAGER" == "apt" ]]; then
                local kernel_pkg
                kernel_pkg="linux-modules-extra-$(uname -r)"
                if apt-cache show "$kernel_pkg" &>/dev/null; then
                    info "Installing $kernel_pkg for UTF-8 support..."
                    if apt-get install -y "$kernel_pkg" &>/dev/null; then
                        info "Retrying to load nls_utf8..."
                        if modprobe nls_utf8 2>/dev/null; then
                            success "NLS UTF-8 module loaded after installing $kernel_pkg"
                        else
                            error_exit "Failed to load nls_utf8 even after installing $kernel_pkg. Please reboot and try again."
                        fi
                    else
                        error_exit "Failed to install $kernel_pkg. Cannot load nls_utf8."
                    fi
                else
                    error_exit "Package $kernel_pkg not found. Cannot load nls_utf8."
                fi
            else
                error_exit "nls_utf8 module missing. Install the UTF-8 NLS kernel module for your kernel and retry."
            fi
        fi
    else
        success "NLS UTF-8 module already loaded"
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

# Get Storage Box credentials (interactive or from arguments)
get_credentials() {
    header "Storage Box Configuration"
    
    # Use command-line arguments if provided
    if [[ -n "$USERNAME_ARG" ]]; then
        storage_username="$USERNAME_ARG"
        info "Using username from command line: $storage_username"
        
        # Validate username
        user_type=$(validate_username "$storage_username")
        if [[ "$user_type" == "invalid" ]]; then
            error_exit "Invalid username format: $storage_username\nExpected: u123456 or u123456-sub1"
        fi
        
        if [[ "$user_type" == "main" ]]; then
            info "✓ Main user account detected"
        else
            info "✓ Sub-user account detected"
        fi
        
        # Get password from file or argument
        if [[ -n "$PASSWORD_FILE" ]]; then
            storage_password=$(cat "$PASSWORD_FILE" 2>/dev/null) || error_exit "Cannot read password file: $PASSWORD_FILE"
            info "Password loaded from file"
        elif [[ -n "$PASSWORD_ARG" ]]; then
            storage_password="$PASSWORD_ARG"
            info "Using password from command line"
        else
            error_exit "Password required in non-interactive mode"
        fi
    else
        # Interactive mode
        echo -e "${CYAN}Please provide your Hetzner Storage Box details${NC}"
        echo -e "${GRAY}Need help? Check: https://docs.hetzner.com/robot/storage-box${NC}"
        echo
        
        # Username with validation
        while true; do
            question "Storage Box username (e.g., u123456 or u123456-sub1): "
            read -r storage_username </dev/tty
            
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
            read -r -s storage_password </dev/tty
            echo
            
            if [[ -z "$storage_password" ]]; then
                warning "Password cannot be empty"
                continue
            fi
            
            if [[ "$SKIP_CONFIRMATION" == "false" ]]; then
                question "Confirm password: "
                read -r -s storage_password_confirm </dev/tty
                echo
                
                if [[ "$storage_password" != "$storage_password_confirm" ]]; then
                    warning "Passwords do not match. Please try again."
                    continue
                fi
            fi
            
            success "Password confirmed"
            break
        done
    fi
    
    # Auto-generate hostname and path
    # For sub-users, append sub-user suffix to mount point if no profile specified
    if [[ "$user_type" == "sub" ]]; then
        storage_hostname="$storage_username.your-storagebox.de"
        storage_path="$storage_username"
        # Only append sub-user suffix if not using a named profile
        # (profile already provides unique mount point)
        if [[ -z "$PROFILE" ]]; then
            default_mount="${DEFAULT_MOUNT_POINT}-${storage_username##*-}"
        else
            default_mount="$DEFAULT_MOUNT_POINT"
        fi
    else
        storage_hostname="${storage_username}.your-storagebox.de"
        storage_path="backup"
        default_mount="$DEFAULT_MOUNT_POINT"
    fi
    
    echo
    info "Generated configuration:"
    echo -e "  ${BOLD}Username:${NC} $storage_username"
    echo -e "  ${BOLD}Hostname:${NC} $storage_hostname"
    echo -e "  ${BOLD}Path:${NC}     ${storage_path:-'/ (root)'}"
    echo -e "  ${BOLD}Type:${NC}     ${user_type^} User"
    if [[ -n "$PROFILE" ]]; then
        echo -e "  ${BOLD}Profile:${NC}  $PROFILE"
    fi
    echo
    
    # DNS check
    check_dns "$storage_hostname"
}

# Validate and sanitize mount point path
# Arguments:
#   $1 - Mount point path
# Returns:
#   0 if valid, 1 if invalid
validate_mount_point() {
    local path="$1"
    
    # Check for invalid characters
    if [[ "$path" =~ [\<\>\|\:] ]]; then
        return 1
    fi
    
    # Ensure absolute path
    if [[ "$path" != /* ]]; then
        return 1
    fi
    
    # Check for dangerous paths
    local dangerous_paths=("/" "/bin" "/boot" "/dev" "/etc" "/lib" "/proc" "/root" "/sbin" "/sys" "/usr")
    for dangerous in "${dangerous_paths[@]}"; do
        if [[ "$path" == "$dangerous" ]]; then
            return 1
        fi
    done
    
    return 0
}

# Get mount options (interactive or from arguments)
get_mount_options() {
    subheader "Mount Options"
    
    # Mount point
    if [[ -n "$MOUNT_POINT_ARG" ]]; then
        mount_point="$MOUNT_POINT_ARG"
        info "Using mount point from command line: $mount_point"
        
        if ! validate_mount_point "$mount_point"; then
            error_exit "Invalid mount point: $mount_point\nMount point must be an absolute path and not a system directory."
        fi
    else
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            mount_point="$default_mount"
            info "Using default mount point: $mount_point"
        else
            question "Mount point path [$default_mount]: "
            read -r mount_point </dev/tty
            [[ -z "$mount_point" ]] && mount_point="$default_mount"
            
            if ! validate_mount_point "$mount_point"; then
                error_exit "Invalid mount point: $mount_point\nMount point must be an absolute path and not a system directory."
            fi
        fi
    fi
    echo -e "  ${BOLD}Mount point:${NC} $mount_point"
    
    # UID/GID
    if [[ -n "$UID_ARG" ]]; then
        mount_uid="$UID_ARG"
        info "Using UID from command line: $mount_uid"
    else
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            mount_uid="$DEFAULT_UID"
        else
            question "User ID for mounted files [$DEFAULT_UID]: "
            read -r mount_uid </dev/tty
            [[ -z "$mount_uid" ]] && mount_uid="$DEFAULT_UID"
        fi
    fi
    
    if [[ -n "$GID_ARG" ]]; then
        mount_gid="$GID_ARG"
        info "Using GID from command line: $mount_gid"
    else
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            mount_gid="$DEFAULT_GID"
        else
            question "Group ID for mounted files [$DEFAULT_GID]: "
            read -r mount_gid </dev/tty
            [[ -z "$mount_gid" ]] && mount_gid="$DEFAULT_GID"
        fi
    fi
    
    echo -e "  ${BOLD}Ownership:${NC} UID=$mount_uid, GID=$mount_gid"
    
    # Performance tuning
    if [[ "$NON_INTERACTIVE" == "false" ]]; then
        question "Enable performance tuning? [Y/n]: "
        read -r perf_tune </dev/tty
        if [[ "$perf_tune" =~ ^[Nn]$ ]]; then
            PERF_TUNING=false
        fi
    fi
    
    # Build final mount options
    MOUNT_OPTIONS="iocharset=utf8,rw,seal,credentials=$CREDENTIALS_FILE"
    MOUNT_OPTIONS="${MOUNT_OPTIONS},uid=$mount_uid,gid=$mount_gid"
    MOUNT_OPTIONS="${MOUNT_OPTIONS},file_mode=0660,dir_mode=0770"
    
    # Add Hetzner Storage Box specific options (seal is critical for Hetzner)
    MOUNT_OPTIONS="${MOUNT_OPTIONS},noperm,domain=WORKGROUP"
    
    if [[ "$PERF_TUNING" == "true" ]]; then
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
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would create credentials file: $CREDENTIALS_FILE"
        return 0
    fi
    
    if [[ -f "$CREDENTIALS_FILE" ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            # In non-interactive mode, always overwrite
            info "Overwriting existing credentials file"
            cp "$CREDENTIALS_FILE" "${CREDENTIALS_FILE}$BACKUP_SUFFIX"
            info "Backed up to: ${CREDENTIALS_FILE}$BACKUP_SUFFIX"
        else
            warning "Credentials file exists"
            question "Overwrite existing credentials? [y/N]: "
            read -r overwrite </dev/tty
            
            if [[ "$overwrite" =~ ^[Yy]$ ]]; then
                cp "$CREDENTIALS_FILE" "${CREDENTIALS_FILE}$BACKUP_SUFFIX"
                info "Backed up to: ${CREDENTIALS_FILE}$BACKUP_SUFFIX"
            else
                info "Using existing credentials"
                return 0
            fi
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
            read -r unmount_first </dev/tty
            
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
            read -r continue_anyway </dev/tty
            
            [[ ! "$continue_anyway" =~ ^[Yy]$ ]] && error_exit "Aborted: non-empty mount point"
        fi
    fi
}

# Build the mount.cifs command
# Returns the command as a string via echo
build_mount_command() {
    local opts="${1:-$MOUNT_OPTIONS}"
    local cmd="mount.cifs -o $opts"
    
    if [[ -n "$storage_path" ]]; then
        cmd="$cmd //$storage_hostname/$storage_path $mount_point"
    else
        cmd="$cmd //$storage_hostname $mount_point"
    fi
    
    echo "$cmd"
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
        
        # Build test mount command with specific SMB version
        local test_opts="vers=$version,${MOUNT_OPTIONS}"
        local test_mount
        test_mount=$(build_mount_command "$test_opts")
        
        if [[ "$VERBOSE" == "true" ]]; then
            info "Testing: $test_mount"
        fi
        
        # Capture error for debugging
        if last_error=$(timeout 10 bash -c "$test_mount" 2>&1); then
            echo -e "${GREEN}✓ Works${NC}"
            working_version="$version"
            umount "$mount_point" &>/dev/null || true
            break
        else
            echo -e "${YELLOW}✗ Not supported${NC}"
            # Log the actual error for debugging
            if [[ "$VERBOSE" == "true" ]]; then
                log "Mount error for SMB $version: $last_error"
            fi
            # Show first error for debugging
            if [[ "$version" == "${SMB_VERSIONS[0]}" && "$VERBOSE" == "true" ]]; then
                warning "Mount error: $last_error"
            fi
        fi
    done
    
    if [[ -z "$working_version" ]]; then
        # Check for specific error codes and provide helpful messages
        if echo "$last_error" | grep -q "error(79)"; then
            echo
            warning "Error 79 indicates missing shared libraries or kernel modules."
            
            # Check dmesg for more specific error
            local dmesg_error
            dmesg_error=$(dmesg 2>/dev/null | tail -10 | grep -i "cifs" || true)
            
            if echo "$dmesg_error" | grep -q "iocharset utf8 not found"; then
                warning "Specific issue: NLS UTF-8 kernel module is not loaded!"
                echo
                info "Fix with:"
                echo "  modprobe nls_utf8"
                echo
            else
                info "Please run these commands to diagnose:"
                echo "  ldd \$(which mount.cifs) | grep 'not found'"
                echo "  dmesg | tail -20 | grep -i cifs"
                echo
                info "Common fixes:"
                echo "  modprobe nls_utf8          # For iocharset=utf8 support"
                echo "  apt reinstall cifs-utils"
                echo "  apt install linux-modules-extra-\$(uname -r)"
                echo "  modprobe cifs"
            fi
            echo
        fi
        error_exit "No compatible SMB version found. Last error: $last_error"
    fi
    
    SMB_VERSION="$working_version"
    success "Selected SMB version: $SMB_VERSION"
    MOUNT_OPTIONS="vers=$SMB_VERSION,${MOUNT_OPTIONS}"
}

# Test mount with retries
test_mount() {
    header "Testing Storage Box Mount"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would test SMB versions and mount storage box"
        info "[DRY RUN] Mount point: $mount_point"
        info "[DRY RUN] Options: $MOUNT_OPTIONS"
        return 0
    fi
    
    test_smb_versions
    
    # Build the final mount command
    local mount_command
    mount_command=$(build_mount_command)
    
    info "Mount command:"
    echo -e "${GRAY}  $mount_command${NC}"
    echo
    
    local attempt=1
    local last_error_output=""
    while [[ $attempt -le $MAX_RETRIES ]]; do
        echo -n "  Attempt $attempt/$MAX_RETRIES... "
        # Capture stderr to show real error on failure
        if last_error_output=$(bash -c "$mount_command" 2>&1); then
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

# Add to fstab or systemd based on configuration
add_permanent_mount() {
    header "Permanent Mount Configuration"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would configure permanent mount using method: $MOUNT_METHOD"
        return 0
    fi
    
    # In interactive mode, ask for mount method
    if [[ "$NON_INTERACTIVE" == "false" ]]; then
        echo -e "${CYAN}Choose mount method:${NC}"
        echo "  1) fstab (traditional, simple)"
        echo "  2) systemd mount unit (modern, more control)"
        echo "  3) Skip permanent mount"
        echo
        question "Your choice [1-3]: "
        read -r mount_choice </dev/tty
        
        case "$mount_choice" in
            1) MOUNT_METHOD="fstab" ;;
            2) MOUNT_METHOD="systemd" ;;
            3) MOUNT_METHOD="none" ;;
            *) MOUNT_METHOD="none"; warning "Invalid choice. Skipping permanent mount." ;;
        esac
    fi
    
    # Apply the chosen mount method
    case "$MOUNT_METHOD" in
        fstab)
            add_to_fstab
            ;;
        systemd)
            create_systemd_mount
            ;;
        none)
            info "Skipping permanent mount configuration"
            ;;
        *)
            warning "Unknown mount method: $MOUNT_METHOD. Skipping permanent mount."
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
    
    # Build description with optional profile name
    local mount_description="Hetzner Storage Box mount for $storage_username"
    local automount_description="Automount Hetzner Storage Box for $storage_username"
    if [[ -n "$PROFILE" ]]; then
        mount_description="Hetzner Storage Box mount for $storage_username (profile: $PROFILE)"
        automount_description="Automount Hetzner Storage Box for $storage_username (profile: $PROFILE)"
    fi
    
    cat > "$unit_file" << EOF
[Unit]
Description=$mount_description
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
Description=$automount_description
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
    
    if [[ -n "$PROFILE" ]]; then
        info "Systemd units created for profile: $PROFILE"
    fi
    
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
    if [[ -n "$PROFILE" ]]; then
        echo -e "${GREEN}${BOLD}  Profile: $PROFILE${NC}"
    fi
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
    if [[ -n "$PROFILE" ]]; then
        echo -e "  ${WHITE}$0 --list-profiles${NC}  ${GRAY}# List all profiles${NC}"
    fi
    echo
    
    echo -e "${CYAN}${BOLD}Performance Tips:${NC}"
    echo "  • Use for: Backups, archives, media files"
    echo "  • Avoid for: Databases, high-frequency I/O"
    echo "  • Expected: 300-800 MB/s within Hetzner network"
    echo
    
    echo -e "${CYAN}${BOLD}Configuration Files:${NC}"
    if [[ -n "$PROFILE" ]]; then
        echo -e "  Profile:     ${WHITE}$PROFILE${NC}"
    fi
    echo -e "  Credentials: ${WHITE}$CREDENTIALS_FILE${NC}"
    echo -e "  Mount point: ${WHITE}$mount_point${NC}"
    echo -e "  Logs:        ${WHITE}$LOG_FILE${NC}"
    
    if [[ -f "/etc/fstab$BACKUP_SUFFIX" ]]; then
        echo -e "  fstab backup: ${WHITE}/etc/fstab$BACKUP_SUFFIX${NC}"
    fi
    
    echo
    if [[ -n "$PROFILE" ]]; then
        echo -e "${CYAN}To add another storage box, use a different profile:${NC}"
        echo -e "  ${WHITE}$0 --profile <new-name> [OPTIONS]${NC}"
        echo
    fi
    echo -e "${GREEN}${BOLD}Need help? Visit: https://docs.hetzner.com/robot/storage-box${NC}"
}

# Cleanup on error
cleanup_on_error() {
    # Only clean up temp file if CREDENTIALS_FILE is set
    if [[ -n "${CREDENTIALS_FILE:-}" ]] && [[ -f "${CREDENTIALS_FILE}.tmp" ]]; then
        rm -f "${CREDENTIALS_FILE}.tmp"
    fi
    
    # Only try to unmount if mount_point is defined
    if [[ -n "${mount_point:-}" ]] && mountpoint -q "$mount_point" 2>/dev/null; then
        umount "$mount_point" 2>/dev/null || true
    fi
}

# Main execution
main() {
    # Parse command-line arguments first
    parse_arguments "$@"
    
    # Handle --list-profiles early (before root check for read-only operation)
    if [[ "$LIST_PROFILES" == "true" ]]; then
        # list_profiles can work without root for basic info
        list_profiles
        exit 0
    fi
    
    # Compute profile-specific paths after parsing arguments
    compute_profile_paths
    
    # Show welcome banner
    show_welcome
    
    # Display profile info if using a named profile
    if [[ -n "$PROFILE" ]]; then
        info "Using profile: $PROFILE"
    fi
    
    # Pre-checks
    check_root
    
    # Setup logging after confirming root access
    setup_logging
    
    header "System Preparation"
    detect_system
    
    # Only check network if not in dry-run mode
    if [[ "$DRY_RUN" != "true" ]]; then
        check_network
    fi
    
    # Repository and packages
    fix_arm64_repositories
    update_packages
    install_packages
    
    # Skip interactive and mount steps in dry-run
    if [[ "$DRY_RUN" == "true" ]]; then
        header "Dry Run Summary"
        info "[DRY RUN] Would collect credentials, build mount options, create credentials file, create mount point, test mount, and configure persistence"
        success "Dry run completed"
        return 0
    fi

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

# Entry point: Ensure script runs only when executed directly, not sourced.
# This check is safe for piped execution (e.g., curl | bash).
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi