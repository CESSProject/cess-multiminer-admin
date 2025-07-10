#!/bin/bash
#
# CESS mineradm configuration management script
# This script handles showing, and generating configuration files
# for all CESS services, including miners, chain nodes, and watchdog.

# --- Strict Mode ---
set -o errexit
set -o nounset
set -o pipefail

# --- Source Dependencies ---
# shellcheck source=scripts/utils.sh
source /opt/cess/mineradm/scripts/utils.sh

# --- Help Functions ---

config_help() {
  cat <<EOF
Usage:
    mineradm config [COMMAND]

Commands:
    show        (or -s) Show the current configuration in JSON format.
    generate    (or -g) Generate Docker Compose and service configs from config.yaml.
    help        (or -h) Show this help information.
EOF
}

# --- Core Functions ---

# Shows a filtered view of the main configuration file.
config_show() {
  log_info "--- Current Configuration ---"
  is_cfgfile_valid
  
  local keys=('"node"' '"miners"')
  local use_external_chain
  use_external_chain=$(yq eval ".node.externalChain // false" "$config_path")

  if [ "$use_external_chain" != "true" ]; then
    keys+=('"chain"')
  fi
  
  local key_filter
  key_filter=$(join_by , "${keys[@]}")
  
  yq eval ". |= pick([$key_filter])" "$config_path" -o json
}

# --- Configuration Generation Sub-functions ---

# Validates system state and config before generating files.
validate_pre_generation_state() {
  log_info "Validating prerequisites..."
  is_cfgfile_valid
  is_sminer_workpaths_valid
  is_cacher_workpath_valid

  # Skip port check if miners are already running to allow for seamless upgrades.
  if ! docker ps --format '{{.Image}}' | grep -q 'cesslab/cess-miner'; then
    is_ports_valid
  fi
  log_success "Prerequisites validated."
}

# Prepares the build directory, cleaning any previous build artifacts.
prepare_build_dir() {
  log_info "Preparing build directory: $build_dir"
  rm -rf "$build_dir"
  mkdir -p "$build_dir/.tmp"
  log_success "Build directory prepared."
}

# Runs the config-gen Docker container to generate initial configs.
run_config_generator() {
  log_info "Running config generator..."
  pullimg # Ensure latest images are used

  local cidfile=$(mktemp)
  rm $cidfile

  local cg_image="cesslab/config-gen:$profile"
  docker run --cidfile $cidfile -v $base_dir/etc:/opt/app/etc -v $build_dir/.tmp:/opt/app/.tmp -v $config_path:/opt/app/config.yaml $cg_image

  local res="$?"
  local cid=$(cat $cidfile)
  docker rm $cid

  if [ "$res" -ne "0" ]; then
    log_err "Failed to generate configurations, please check your config file and try again."
    exit 1
  fi

  log_success "Config generator finished."
}

# Deploys the generated configuration files to their final destinations.
deploy_generated_configs() {
  log_info "Deploying generated configurations..."
  local base_data_path="/opt/cess/data/$mode"

  # Move base configs from .tmp to build dir
  cp -r "$build_dir/.tmp/"* "$build_dir/"
  rm -rf "$build_dir/.tmp"

  # Deploy miner configs
  mkdir -p "$base_data_path/miners/"
  cp "$build_dir/miners/"* "$base_data_path/miners/"
  
  # Deploy chain configs if not external
  if [ -d "$build_dir/chain" ]; then
    mkdir -p "$base_data_path/chain/"
    cp "$build_dir/chain/"* "$base_data_path/chain/"
  fi

  chown -R root:root "$build_dir"
  split_miners_config # Generate individual miner configs

  # Deploy watchdog config if enabled
  if [ "$(yq eval ".watchdog.enable" "$config_path")" == "true" ] && [ -d "$build_dir/watchdog" ]; then
    mkdir -p "$base_data_path/watchdog/"
    cp "$build_dir/watchdog/"* "$base_data_path/watchdog/"
    log_success "Watchdog configuration deployed."
  fi

  # Deploy cacher config if enabled
  if [ "$(yq eval '.cacher.enable' "$config_path")" == "true" ] && [ -d "$build_dir/cacher" ]; then
    local cacher_workspace
    cacher_workspace=$(yq eval '.cacher.WorkSpace' "$config_path")
    cp "$build_dir/cacher/"* "$cacher_workspace/"
    log_success "Cacher configuration deployed to $cacher_workspace"
  fi
  
  log_success "All configurations deployed."
}

# Main function to generate all configuration files.
config_generate() {
  log_info "--- Starting Configuration Generation ---"
  
  validate_pre_generation_state
  prepare_build_dir
  run_config_generator
  deploy_generated_configs

  log_success "Configuration generation complete. Docker Compose file is at: $compose_yaml"
}

# --- Main Execution ---
mode=$(yq eval ".node.mode" "$config_path")
# Main router for the 'config' command.
config() {
  # Set default mode if not valid
  if [ "$mode" != "multiminer" ]; then
    log_info "The mode in $config_path is invalid, setting value to: multiminer"
    yq -i eval '.node.mode="multiminer"' "$config_path"
  fi

  case "${1:-help}" in
  -s | show)
    config_show
    ;;
  -g | generate)
    config_generate
    ;;
  -h | help | *)
    config_help
    ;;
  esac
}
