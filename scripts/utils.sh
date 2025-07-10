#!/bin/bash
#
# CESS mineradm utility functions
# This script contains shared functions for logging, system checks,
# configuration management, and other common tasks.

# --- Strict Mode ---
# Exit immediately if a command exits with a non-zero status.
set -o errexit
# Treat unset variables as an error when substituting.
set -o nounset
# Return the exit status of the last command in a pipeline that failed.
set -o pipefail

# --- Global Variables & Constants ---
# Versioning
mineradm_version="v0.2.1"
network_version="testnet"

# Paths
readonly base_dir="/opt/cess/mineradm"
readonly script_dir="$base_dir/scripts"
readonly config_path="$base_dir/config.yaml"
readonly build_dir="$base_dir/build"
readonly compose_yaml="$build_dir/docker-compose.yaml"

# Configuration Profile
profile="testnet"

# System Requirements
readonly kernel_ver_req="5.11"
readonly docker_ver_req="20.10"
readonly yq_ver_req="4.25"
readonly cpu_req=4
readonly ram_req=8 # GB

# Per-service Requirements
readonly each_miner_ram_req=4   # GB
readonly each_miner_cpu_req=1   # Cores
readonly each_rpcnode_ram_req=2 # GB
readonly each_rpcnode_cpu_req=1 # Cores

# System Info
PM=""      # Package Manager (apt, yum)
DISTRO=""  # Linux Distribution (Ubuntu, CentOS)
ARCH="x86_64" # System Architecture

# --- Logging Functions ---

# Prints a colored message.
# Usage: echo_c <color_code> <message>
echo_c() {
  printf "\033[0;%dm%s\033[0m\n" "$1" "$2"
}

# Logs an informational message (yellow).
log_info() {
  echo_c 33 "$1"
}

# Logs a success message (green).
log_success() {
  echo_c 32 "$1"
}

# Logs an error message (magenta) and exits if not in an interactive shell.
log_err() {
  echo_c 35 "[ERROR] $1"
  # if ! [[ $- == *i* ]]; then
  #   exit 1
  # fi
}

# --- System & Prerequisite Checks ---

# Checks if a command exists.
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Ensures the script is run as root.
ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root. Please use sudo."
    exit 1
  fi
}

# Detects the Linux distribution and package manager.
get_packageManager_type() {
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    DISTRO=$ID
    case $ID in
    ubuntu | debian | raspbian)
      PM="apt"
      ;;
    centos | rhel | fedora | aliyun)
      PM="yum"
      ;;
    *)
      log_err "Unsupported Linux distribution: $ID"
      exit 1
      ;;
    esac
  else
    log_err "Cannot determine Linux distribution."
    exit 1
  fi
  log_info "Detected Distro: $DISTRO, Package Manager: $PM"
}

# Detects the system architecture.
get_system_arch() {
  ARCH=$(uname -m)
  case "$ARCH" in
  x86_64 | aarch64)
    log_info "System architecture: $ARCH"
    ;;
  *)
    log_err "Unsupported system architecture: $ARCH. Only x86_64 and aarch64 are supported."
    exit 1
    ;;
  esac
}

# Compares two version strings (e.g., 20.10 vs 19.03).
# Returns 0 if version A >= version B, 1 otherwise.
is_ver_a_ge_b() {
  local ver_a="$1"
  local ver_b="$2"
  [ "$(printf '%s\n' "$ver_a" "$ver_b" | sort -V | head -n1)" = "$ver_b" ]
}

# Validates the kernel version.
is_kernel_satisfied() {
  local kernel_version
  kernel_version=$(uname -r | cut -d- -f1)
  log_info "Current Linux kernel version: $kernel_version"
  if ! is_ver_a_ge_b "$kernel_version" "$kernel_ver_req"; then
    log_err "Kernel version must be $kernel_ver_req or higher. Please upgrade your kernel."
    exit 1
  fi
}

# Gets the total number of CPU processors.
get_cur_processors() {
  grep -c ^processor /proc/cpuinfo
}

# Gets the total system RAM in GB, rounded to the nearest whole number.
# It prefers using dmidecode to get hardware-reported values, which often
# matches advertised specs, and falls back to /proc/meminfo.
get_cur_ram() {
  # Fallback function if dmidecode is not available or fails
  get_cur_ram_from_proc() {
    log_info "Using /proc/meminfo for RAM size."
    local mem_total_kib
    mem_total_kib=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    # Round to nearest GiB: add half a GiB in KiB then divide.
    echo $(((mem_total_kib + 524288) / 1048576))
  }

  if command_exists dmidecode && sudo dmidecode -t memory &>/dev/null; then
    local total_mb=0
    # Process each line like "Size: 8 GB" or "Size: 4096 MB"
    while read -r size unit; do
        if [[ "$size" =~ ^[0-9]+$ ]]; then
            if [[ "$unit" == "GB" ]]; then
                total_mb=$((total_mb + size * 1024))
            elif [[ "$unit" == "MB" ]]; then
                total_mb=$((total_mb + size))
            fi
        fi
    done < <(sudo dmidecode -t memory | grep -i "Size:" | grep -v "No Module Installed" | awk '{print $2, $3}')

    if [ "$total_mb" -gt 0 ]; then
        # Round to the nearest GB. Add 512MB for rounding before integer division.
        echo $(((total_mb + 512) / 1024))
    else
        get_cur_ram_from_proc
    fi
  else
    get_cur_ram_from_proc
  fi
}

# Checks if the base hardware (CPU, RAM) meets minimum requirements.
is_base_hardware_satisfied() {
  local cur_processors
  cur_processors=$(get_cur_processors)
  local cur_ram
  cur_ram=$(get_cur_ram)

  log_info "Server has $cur_processors processors and $cur_ram GB of RAM."

  if [ "$cur_processors" -lt "$cpu_req" ]; then
    log_err "CPU requirement not met: need at least $cpu_req cores, but found $cur_processors."
    exit 1
  fi
  if [ "$cur_ram" -lt "$ram_req" ]; then
    log_err "RAM requirement not met: need at least $ram_req GB, but found $cur_ram GB."
    exit 1
  fi
}

# --- Configuration File Handling ---

# Validates that the main config file exists and is valid YAML.
is_cfgfile_valid() {
  if [ ! -f "$config_path" ]; then
    log_err "Configuration file not found: $config_path"
    exit 1
  fi
  if ! yq '.' "$config_path" >/dev/null; then
    log_err "Configuration file is not valid YAML: $config_path"
    exit 1
  fi
}

# Loads the profile from the config file.
load_profile() {
  is_cfgfile_valid
  local current_profile
  current_profile=$(yq eval ".node.profile" "$config_path")
  case "$current_profile" in
  devnet | testnet | premainnet | mainnet)
    profile="$current_profile"
    log_info "Loaded profile: $profile"
    ;;
  *)
    log_err "Invalid profile '$current_profile' in config file. Using default: $profile"
    ;;
  esac
}

# Sets a new profile in the config file.
set_profile() {
  local to_set="$1"
  is_cfgfile_valid
  if [ -z "$to_set" ]; then
    log_info "Current profile is: $(yq eval ".node.profile" "$config_path")"
    return
  fi
  case "$to_set" in
  devnet | testnet | premainnet | mainnet)
    yq -i eval ".node.profile=\"$to_set\"" "$config_path"
    log_success "Set profile to: $to_set"
    ;;
  *)
    log_err "Invalid profile value. Choose from: devnet, testnet, premainnet, mainnet"
    return 1
    ;;
  esac
}

# --- Docker & Network Utilities ---

# Enables the Docker Remote API on localhost.
enable_docker_api() {
  if ss -tl | grep -qE ':2375|:2376'; then
    log_info "Docker Remote API is already enabled."
    return
  fi

  log_info "Enabling Docker Remote API..."
  local docker_service_file="/lib/systemd/system/docker.service"
  if [ ! -f "$docker_service_file" ]; then
      log_err "Docker service file not found at $docker_service_file"
      return 1
  fi

  local backup_file="/lib/systemd/system/docker.service.bak"
  log_info "Backing up docker.service to $backup_file"
  cp "$docker_service_file" "$backup_file"

  # This is a common but potentially fragile way to modify the service file.
  # A more robust method would be using a systemd override file.
  sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/dockerd -H fd:// -H unix:///var/run/docker.sock -H tcp://127.0.0.1:2375|' "$docker_service_file"

  systemctl daemon-reload
  systemctl restart docker
  log_success "Docker daemon now listening on tcp://127.0.0.1:2375"
}

# Checks if a given port is in use.
check_port() {
  local port="$1"
  if netstat -tlpn | grep -q "\b$port\b"; then
    log_err "Port $port is already in use."
    exit 1
  fi
}

# Checks the status of a Docker container.
# Returns: 0 (running), 1 (not found), 2 (stopped)
check_docker_status() {
  if ! command_exists docker; then return 1; fi
  local status
  status=$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)
  case "$status" in
  running) return 0 ;;
  exited | created) return 2 ;;
  *) return 1 ;;
  esac
}

# --- Miner-Specific Functions ---

# Gets the number of miners defined in the config.
get_miners_num() {
  yq eval '.miners | length' "$config_path"
}

# Creates the working directories for storage miners.
mk_sminer_workdir() {
  log_info "Creating storage miner working directories..."
  local disk_paths
  disk_paths=$(yq eval '.miners[].diskPath' "$config_path" | xargs)
  for disk_path in $disk_paths; do
    mkdir -p "$disk_path/miner" "$disk_path/storage"
    log_info "Created $disk_path/miner and $disk_path/storage"
  done
}

# Splits the main miners config into individual files for each miner.
split_miners_config() {
  log_info "Splitting miner configurations..."
  local miners_num
  miners_num=$(get_miners_num)
  for ((i = 0; i < miners_num; i++)); do
    local disk_path
    disk_path=$(yq eval ".miners[$i].diskPath" "$config_path")
    local miner_config_path="$disk_path/miner/config.yaml"
    
    yq eval ".miners[$i]" "$config_path" > "$miner_config_path"
    
    log_success "Generated miner config: $miner_config_path"
  done
}

# --- Validation Functions ---

# Validates that a value is a non-negative integer.
is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

# Validates that a value is an integer (positive, negative, or zero).
is_int() {
  [[ "$1" =~ ^-?[0-9]+$ ]]
}

# Validates that a value is a number (integer or float).
is_num() {
  if ! [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    log_err "Invalid number format: '$1'. Please provide a valid number."
    exit 1
  fi
}

# Validates that a string matches an expected value.
is_str_equal() {
  if [ "$1" != "$2" ]; then
    log_err "Input error: '$1' does not match expected value '$2'."
    exit 1
  fi
}

# Validates that a name matches a given prefix (e.g., "miner" for "miner1").
is_match_regex() {
  local prefix="$1"
  local name="$2"
  if [[ ! "$name" =~ ^$prefix ]]; then
    log_err "Invalid name: '$name'. It must start with '$prefix'."
    exit 1
  fi
}

# --- Miscellaneous ---

# Joins array elements with a separator.
# Usage: join_by <separator> <array_element1> <array_element2> ...
join_by() {
  local IFS="$1"
  shift
  echo "$*"
}

# Generates a random number within a given range.
rand() {
  local min=$1
  local max=$2
  # Use /dev/urandom for better randomness if available
  if [ -c /dev/urandom ]; then
      head -c 4 /dev/urandom | od -An -tu4 | awk -v min="$min" -v max="$max" '{print ($1 % (max-min+1)) + min}'
  else
      # Fallback to date
      echo $(( ( $(date +%s%N) % (max-min+1) ) + min ))
  fi
}