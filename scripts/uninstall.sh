#!/bin/bash
#
# CESS mineradm uninstallation script
# This script removes the mineradm application, its configuration,
# and optionally the Docker containers and images it uses.

# --- Strict Mode ---
set -o errexit
set -o nounset
set -o pipefail

# --- Source Utilities ---
# Source logging utilities if available, but don't fail if they're already removed.
if [ -f /opt/cess/mineradm/scripts/utils.sh ]; then
  # shellcheck source=scripts/utils.sh
  source /opt/cess/mineradm/scripts/utils.sh
else
  # Define fallback logging functions if utils.sh is missing
  log_info() { echo "[INFO] $1"; }
  log_err() { echo "[ERROR] $1"; }
  log_success() { echo "[SUCCESS] $1"; }
fi

# --- Default Options ---
no_rmi="false"
keep_running="false"
install_dir="/opt/cess/mineradm"
compose_yaml="$install_dir/build/docker-compose.yaml"
bin_file="/usr/bin/mineradm"

# --- Functions ---

# Displays help information.
help() {
  cat <<EOF
Usage:
    uninstall.sh [OPTIONS]

Options:
    -h, --help                Show this help information
    --no-rmi                  Do not remove Docker images during uninstallation.
    --keep-running            Do not stop or remove running CESS services.
EOF
  exit 0
}

# Parses command-line arguments.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --no-rmi)
      no_rmi="true"
      shift
      ;;
    --keep-running)
      keep_running="true"
      shift
      ;;
    -h | --help)
      help
      ;;
    *)
      log_err "Unknown option: $1"
      help
      ;;
    esac
  done
}

# Stops and removes Docker containers and volumes.
cleanup_docker() {
  if [ "$keep_running" = "true" ]; then
    log_info "Skipping Docker cleanup as requested (--keep-running)."
    return
  fi

  if [ ! -f "$compose_yaml" ]; then
    log_info "Docker compose file not found, skipping Docker cleanup."
    return
  fi

  log_info "Stopping and removing CESS services..."
  docker compose -f "$compose_yaml" down -v --remove-orphans
  
  if [ "$no_rmi" = "true" ]; then
    log_info "Skipping Docker image removal as requested (--no-rmi)."
  else
    log_info "Removing associated Docker images..."
    docker compose -f "$compose_yaml" down --rmi all
  fi
  log_success "Docker cleanup complete."
}

# Removes mineradm application files and directories.
remove_application_files() {
  log_info "Removing mineradm application files..."
  
  if [ -f "$bin_file" ]; then
    log_info "Removing binary: $bin_file"
    rm -f "$bin_file"
  fi

  if [ -d "$install_dir" ]; then
    log_info "Removing installation directory: $install_dir"
    rm -rf "$install_dir"
  fi

  # Optional: remove bash completion entry
  if [ -f ~/.bashrc ]; then
      sed -i "\|source $install_dir/scripts/completion.sh|d" ~/.bashrc
      log_info "Removed bash completion entry from ~/.bashrc"
  fi

  log_success "Application files removed."
}

# --- Main Execution ---
main() {
  # Must be run as root
  if [ "$(id -u)" -ne 0 ]; then
      echo "This script must be run with sudo or as root."
      exit 1
  fi

  parse_args "$@"

  log_info "Starting CESS mineradm uninstallation..."

  cleanup_docker
  remove_application_files

  log_success "CESS mineradm has been successfully uninstalled."
}

main "$@"