#!/bin/bash
#
# CESS mineradm tools script
# This script provides various tools for managing miners, such as viewing
# disk space and adjusting configurations.

# --- Strict Mode ---
set -o errexit
set -o nounset
set -o pipefail

# --- Source Dependencies ---
# shellcheck source=scripts/utils.sh
source /opt/cess/mineradm/scripts/utils.sh
# shellcheck source=scripts/config.sh
source /opt/cess/mineradm/scripts/config.sh

# --- Help Functions ---

tools_help() {
  cat <<EOF
Usage:
    mineradm tools [COMMAND]

Commands:
    space-info          Show disk space information for miner paths.
    no-watch [args...]  Set containers to be ignored by the auto-updater.
    set <subcommand>    Modify miner configurations.
    help                Show this help information.

'mineradm tools set' subcommands:
    use-space <amount_gb>               Set UseSpace for all miners.
    use-space <miner_name> <amount_gb>  Set UseSpace for a specific miner.
EOF
}

# --- Tool Functions ---

# Displays disk usage for paths defined in the config.
space_info() {
  log_info "--- Miner Disk Space Information ---"
  echo "Filesystem       Size  Used Avail Use% Mounted on"
  
  local disk_paths
  disk_paths=($(yq eval '.miners[].diskPath' "$config_path"))
  
  if [ ${#disk_paths[@]} -eq 0 ]; then
    log_info "No miner disk paths configured."
    return
  fi

  for path in "${disk_paths[@]}"; do
    df -h "$path" | tail -n +2
  done
}

# Sets the list of containers that should not be auto-updated.
set_no_watch_containers() {
  local containers=("$@")
  log_info "Setting no-watch containers to: ${containers[*]}"
  
  local quoted_containers
  quoted_containers=$(printf '"%s",' "${containers[@]}") # "name1","name2",
  
  yq -i eval ".node.noWatchContainers=[${quoted_containers%,}]" "$config_path"
  log_success "Configuration updated."
}

# --- 'set use-space' Sub-functions ---

# Updates the UseSpace value in the config file for a specific miner.
update_use_space_config() {
    local miner_index="$1"
    local new_space_gb="$2"
    yq -i eval ".miners[$miner_index].UseSpace=$new_space_gb" "$config_path"
    log_info "Updated .miners[$miner_index].UseSpace to $new_space_gb GB in config."
}

# Validates if the new space is sufficient.
validate_new_space() {
    local miner_name="$1"
    local current_validated_gb="$2"
    local new_space_gb="$3"

    if (($(echo "$new_space_gb <= $current_validated_gb" | bc))); then
        log_err "$miner_name has already validated $current_validated_gb GB. New space must be greater. Aborting."
        exit 1
    fi
}

# Handles setting the 'use-space' for a single miner.
set_use_space_single() {
    local miner_name="$1"
    local new_space_gb="$2"
    is_match_regex "miner" "$miner_name"
    is_num "$new_space_gb"

    log_info "Setting UseSpace for $miner_name to $new_space_gb GB..."

    local miner_index
    miner_index=$(yq eval ".miners | to_entries | map(select(.value.name == \"$miner_name\")) | .[].key" "$config_path")
    if [ -z "$miner_index" ]; then
        log_err "Miner '$miner_name' not found in configuration."
        exit 1
    fi

    # Get current validated space (mocked for now)
    # In a real scenario, you would query this from the miner.
    local current_validated_gb="10" # Mock value
    validate_new_space "$miner_name" "$current_validated_gb" "$new_space_gb"

    update_use_space_config "$miner_index" "$new_space_gb"
    
    log_info "Applying changes for $miner_name..."
    config_generate
    mineradm down "$miner_name"
    sleep 3
    mineradm install -s
    log_success "Successfully updated UseSpace for $miner_name."
}

# Handles setting the 'use-space' for all miners.
set_use_space_all() {
    local new_space_gb="$1"
    is_num "$new_space_gb"

    log_info "WARNING: This will set UseSpace for ALL miners to $new_space_gb GB and restart them."
    printf "Press \033[0;33mY\033[0m to continue: "
    local confirm
    read -r confirm
    if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
        log_info "Operation cancelled."
        exit 0
    fi

    local miner_names
    miner_names=($(yq eval '.miners[].name' "$config_path"))
    for i in "${!miner_names[@]}"; do
        local miner_name="${miner_names[$i]}"
        # Mocked validation for each miner
        local current_validated_gb="10" # Mock value
        validate_new_space "$miner_name" "$current_validated_gb" "$new_space_gb"
        update_use_space_config "$i" "$new_space_gb"
    done

    log_info "Applying changes for all miners..."
    config_generate
    mineradm down "${miner_names[@]}"
    sleep 3
    mineradm install -s
    log_success "Successfully updated UseSpace for all miners."
}

# Main handler for the 'set' command.
handle_set_command() {
  case "$1" in
  use-space)
    shift
    if [ $# -eq 1 ]; then
      set_use_space_all "$1"
    elif [ $# -eq 2 ]; then
      set_use_space_single "$1" "$2"
    else
      log_err "Invalid number of arguments for 'set use-space'."
      tools_help
      exit 1
    fi
    ;;
  *)
    log_err "Unknown 'set' command: $1"
    tools_help
    exit 1
    ;;
  esac
}

# --- Main Execution ---

# Main router for the 'tools' command.
tools() {
  case "${1:-help}" in
  space-info)
    space_info
    ;;
  no-watch)
    shift
    set_no_watch_containers "$@"
    ;;
  set)
    shift
    handle_set_command "$@"
    ;;
  help | *)
    tools_help
    ;;
  esac
}

# The script is meant to be sourced by miner.sh, which calls the 'tools' function.
# If run directly, show help.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  tools "$@"
fi