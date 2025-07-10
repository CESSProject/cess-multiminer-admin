#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipelines return the exit status of the last command to exit with a non-zero status.
set -o pipefail

# --- Global Variables ---
# Directories
local_base_dir=$(cd "$(dirname "$0")" && pwd)
local_script_dir="$local_base_dir/scripts"
install_dir="/opt/cess/mineradm"

# Options
skip_dep="false"
retain_config="false"
no_rmi="false"
keep_running="false"

# Source utilities
# shellcheck source=scripts/utils.sh
source "$local_script_dir/utils.sh"

# --- Functions ---

help() {
  cat <<EOF
Usage:
    install.sh [OPTIONS]

Options:
    -h, --help                Show this help information
    -n, --no-rmi              Do not remove the corresponding image when uninstalling the service
    -r, --retain-config       Retain old config when updating mineradm
    -s, --skip-dep            Skip installing dependencies
    -k, --keep-running        Do not stop services from a previous installation
EOF
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      help
      ;;
    -n | --no-rmi)
      no_rmi="true"
      shift
      ;;
    -r | --retain-config)
      retain_config="true"
      shift
      ;;
    -s | --skip-dep)
      skip_dep="true"
      shift
      ;;
    -k | --keep-running)
      keep_running="true"
      shift
      ;;
    *)
      log_err "Unknown option: $1"
      help
      ;;
    esac
  done
}

update_package_manager() {
  log_info "--- Updating package manager ($PM) ---"
  if [ "$PM" = "apt" ]; then
    apt-get update
  elif [ "$PM" = "yum" ]; then
    yum -y update
  fi
  log_success "Package manager updated successfully."
}

install_packages() {
  log_info "Installing packages: $*"
  if [ "$PM" = "apt" ]; then
    apt-get install -y "$@"
  elif [ "$PM" = "yum" ]; then
    yum install -y "$@"
  fi
}

install_base_dependencies() {
  log_info "--- Installing base dependencies ---"
  local pkgs="git jq curl wget net-tools bc dmidecode"
  install_packages $pkgs

  if ! command_exists nc; then
    log_info "Installing netcat..."
    if [ "$PM" = "apt" ]; then
      install_packages netcat-openbsd
    elif [ "$PM" = "yum" ]; then
      # EPEL repository provides nmap-ncat
      install_packages epel-release
      install_packages nmap-ncat
    fi
  fi
  log_success "Base dependencies installed."
}

install_yq() {
  log_info "--- Checking and installing yq ---"
  local yq_ver_req="4.25"
  if command_exists yq; then
    local yq_ver_cur
    yq_ver_cur=$(yq -V | awk '{print $NF}' | sed 's/v//' | cut -d. -f1,2)
    if is_ver_a_ge_b "$yq_ver_cur" "$yq_ver_req"; then
      log_info "yq is already installed and meets version requirements."
      return
    fi
    log_info "yq version is old, upgrading..."
  fi

  log_info "Downloading and installing yq..."
  local yq_url_base="https://github.com/mikefarah/yq/releases/download/v4.25.3/yq_linux"
  local yq_binary="/usr/bin/yq"
  local arch_suffix
  if [ "$ARCH" = "x86_64" ]; then
    arch_suffix="amd64"
  else
    arch_suffix="arm64"
  fi

  wget "${yq_url_base}_${arch_suffix}" -O "$yq_binary"
  chmod +x "$yq_binary"
  log_success "yq installed successfully: $(yq -V)"
}

install_docker() {
  log_info "--- Checking and installing Docker ---"
  local docker_ver_req="20.10"
  if command_exists docker && [ -e /var/run/docker.sock ]; then
    local cur_docker_ver
    cur_docker_ver=$(docker version -f '{{.Server.Version}}' | cut -d. -f1,2)
    log_info "Current Docker version: $cur_docker_ver"
    if is_ver_a_ge_b "$cur_docker_ver" "$docker_ver_req"; then
      log_info "Docker is already installed and meets version requirements."
      return
    fi
    log_info "Docker version is old or not installed, proceeding with installation..."
  fi

  log_info "Installing Docker via get.docker.com script..."
  curl -fsSL https://get.docker.com | bash
  log_success "Docker installed successfully."
}

install_docker_compose_plugin() {
  log_info "--- Checking and installing Docker Compose plugin ---"
  if docker compose version &>/dev/null; then
    log_info "Docker Compose plugin is already installed."
    return
  fi

  log_info "Installing Docker Compose plugin..."
  if [ "$PM" = "apt" ]; then
    add_docker_ubuntu_repo
    install_packages docker-compose-plugin
  elif [ "$PM" = "yum" ]; then
    add_docker_centos_repo
    install_packages docker-compose-plugin
  fi
  log_success "Docker Compose plugin installed successfully."
}

install_all_dependencies() {
  if [ "$skip_dep" = "true" ]; then
    log_info "Skipping dependency installation as requested."
    return
  fi

  trap 'log_err "An error occurred during dependency installation."; exit 1' ERR

  update_package_manager
  install_base_dependencies
  install_yq
  install_docker
  install_docker_compose_plugin

  sysctl -w net.core.rmem_max=2500000
  log_success "All dependencies installed successfully."

  # remove trap
  trap - ERR
}

get_mineradm_version() {
  local util_script="$1"
  if [ -f "$util_script" ]; then
    grep 'mineradm_version=' "$util_script" | cut -d'"' -f2
  else
    echo "N/A"
  fi
}

confirm_config_overwrite() {
  local old_version="$1"
  log_info "WARNING: An existing installation (version: $old_version) was found."
  log_info "         Re-installing will overwrite the existing configuration."
  log_info "         To keep your old configuration, use the -r or --retain-config flag."
  printf "Press \033[0;33mY\033[0m to continue, or any other key to cancel: "
  local y=""
  read -r y
  if [[ "$y" != "Y" && "$y" != "y" ]]; then
    echo "Installation canceled by user."
    exit 0
  fi
}

uninstall_previous_version() {
  local old_version="$1"
  local uninstall_script="$install_dir/scripts/uninstall.sh"
  if [ -f "$uninstall_script" ]; then
    log_info "Uninstalling previous CESS mineradm version: $old_version"
    local uninstall_opts=()
    if [ "$no_rmi" = "true" ]; then
      uninstall_opts+=("--no-rmi")
    fi
    if [ "$keep_running" = "true" ]; then
      uninstall_opts+=("--keep-running")
    fi
    bash "$uninstall_script" "${uninstall_opts[@]}"
  fi
}

install_mineradm_files() {
  log_info "--- Installing CESS mineradm files ---"
  mkdir -p "$install_dir/scripts"

  cp "$local_base_dir/config.yaml" "$install_dir/config.yaml"
  cp -r "$local_base_dir/scripts" "$install_dir/"
  cp "$local_script_dir/miner.sh" /usr/bin/mineradm

  log_info "Setting file permissions..."
  chown root:root "$install_dir/config.yaml"
  chmod 0600 "$install_dir/config.yaml"
  chmod +x /usr/bin/mineradm
  chmod +x "$install_dir/scripts/"*.sh
  log_success "Files installed."
}

setup_bash_completion() {
  log_info "--- Setting up bash completion ---"
  local completion_script_path="$install_dir/scripts/completion.sh"
  if ! grep -q "source $completion_script_path" ~/.bashrc; then
    echo "source $completion_script_path" >>~/.bashrc
    log_info "Bash completion sourced in ~/.bashrc"
  fi
  # shellcheck source=scripts/completion.sh
  source "$completion_script_path"
}

attempt_enable_docker_api() {
  log_info "--- Enabling Docker Remote API ---"
  if ! enable_docker_api; then
    log_err "Failed to enable Docker API automatically."
    log_info "The monitor service (watchdog) requires the Docker API."
    log_info "Please try to enable it manually: https://docs.docker.com/config/daemon/remote-access/"
    if [ -f /lib/systemd/system/backup-docker.service ]; then
        log_info "Restoring docker service from backup and restarting."
        cat /lib/systemd/system/backup-docker.service >/lib/systemd/system/docker.service
        systemctl daemon-reload
        systemctl restart docker
    fi
  else
    log_success "Docker Remote API enabled."
  fi
}

install_mineradm() {
  local dst_utils_sh="$install_dir/scripts/utils.sh"
  local src_utils_sh="$local_script_dir/utils.sh"
  local old_version
  old_version=$(get_mineradm_version "$dst_utils_sh")
  local new_version
  new_version=$(get_mineradm_version "$src_utils_sh")

  log_info "--- Starting CESS mineradm installation (v$new_version) ---"

  if [ -f "$install_dir/config.yaml" ] && [ "$retain_config" != "true" ]; then
    confirm_config_overwrite "$old_version"
  fi

  local old_config_backup=""
  if [ -f "$install_dir/config.yaml" ] && [ "$retain_config" = "true" ]; then
    old_config_backup=$(mktemp /tmp/cess-config.XXXXXX.yaml)
    log_info "Backing up existing configuration to $old_config_backup"
    cp "$install_dir/config.yaml" "$old_config_backup"
  fi

  uninstall_previous_version "$old_version"
  install_mineradm_files

  if [ -n "$old_config_backup" ] && [ -f "$old_config_backup" ]; then
    log_info "Restoring old config to $install_dir/.old_config.yaml"
    mv "$old_config_backup" "$install_dir/.old_config.yaml"
  fi

  setup_bash_completion
  attempt_enable_docker_api

  log_success "CESS mineradm v$new_version installed successfully!"
}

main() {
  parse_args "$@"
  
  ensure_root
  get_system_arch
  get_packageManager_type

  if [ "$PM" != "yum" ] && [ "$PM" != "apt" ]; then
    log_err "This installer only supports apt (Debian/Ubuntu) and yum (CentOS/RHEL) package managers."
    exit 1
  fi

  if ! is_kernel_satisfied; then
    exit 1
  fi

  if ! is_base_hardware_satisfied; then
    exit 1
  fi

  install_all_dependencies
  install_mineradm
}

main "$@"

