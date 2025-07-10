#!/bin/bash
#
# CESS mineradm version information script
# This script displays version information for mineradm, its components,
# and the Docker images it uses.

# --- Strict Mode ---
set -o errexit
set -o nounset
set -o pipefail

# --- Source Dependencies ---
# shellcheck source=scripts/utils.sh
source /opt/cess/mineradm/scripts/utils.sh

# --- Functions ---

# Shows version information for a specific Docker image.
# If the image is not found, it prints 'not found'.
# Usage: show_version <program_name> <image_name> <version_command> [extra_docker_opts]
show_version() {
  local prog_name="$1"
  local image_name="$2"
  local version_cmd="$3"
  local extra_docker_opts="${4:-}"
  local image_tag="$profile"
  
  local image_info
  image_info=$(docker images --format "{{.ID}}	{{.Tag}}" "$image_name" | grep "\b$image_tag$")
  
  local image_id="not found"
  local version="not found"

  if [ -n "$image_info" ]; then
    image_id=$(echo "$image_info" | awk '{print $1}')
    # Run docker command to get the version, redirect stderr to /dev/null to hide errors if command fails
    version=$(docker run --rm $extra_docker_opts "$image_name:$image_tag" "$version_cmd" 2>/dev/null || echo "error getting version")
  fi
  
  printf "%-20s %-40s %-40s\n" "$prog_name" "$version" "$image_id"
}

# Displays versions of all relevant Docker images.
inner_docker_version() {
  echo "----------------------------------------------------------------"
  printf "Docker Images:\n"
  printf "%-20s %-40s %-40s\n" "IMAGE" "VERSION" "IMAGE ID"
  show_version "config-gen" "cesslab/config-gen" "version"
  show_version "chain" "cesslab/cess-chain" "--version"
  show_version "miner" "cesslab/cess-miner" "version"
}

# Main function to display all version information.
version() {
  printf "CESS Mineradm Version Information\n"
  printf "%s\n" "---------------------------------"
  printf "%-20s: %s\n" "Network" "$network_version"
  printf "%-20s: %s\n" "Mineradm Version" "$mineradm_version"
  printf "%-20s: %s\n" "Mode" "$(yq eval ".node.mode" "$config_path")"
  printf "%-20s: %s\n" "Profile" "$profile"

  if [[ -f "$config_path" ]]; then
    local no_watch_containers
    no_watch_containers=$(yq eval '.node.noWatchContainers // [] | join(", ")' "$config_path")
    if [[ -n "$no_watch_containers" ]]; then
      log_info "No-watch containers: $no_watch_containers"
    fi
  fi

  inner_docker_version
}