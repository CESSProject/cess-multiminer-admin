#!/bin/bash
#
# CESS mineradm main script
# This script is the main entry point for managing CESS miners and related services.
# It handles installation, service lifecycle (start, stop, restart), and miner-specific operations.

# --- Strict Mode ---
set -o errexit
set -o nounset
set -o pipefail

# --- Source Dependencies ---
# It's assumed these scripts are in /opt/cess/mineradm/scripts/ on the target system.
# shellcheck source=scripts/utils.sh
source /opt/cess/mineradm/scripts/utils.sh
# shellcheck source=scripts/version.sh
source /opt/cess/mineradm/scripts/version.sh
# shellcheck source=scripts/config.sh
source /opt/cess/mineradm/scripts/config.sh
# shellcheck source=scripts/tools.sh
source /opt/cess/mineradm/scripts/tools.sh

# --- Global Variables ---
skip_chain="false"

# --- Help Functions ---

help() {
  cat <<EOF
Usage:
    mineradm [COMMAND] [OPTIONS]

Primary Commands:
    install             Install and start all services defined in the configuration.
        --skip-chain    Do not start the local chain service.
    stop [service...]   Stop all or specified services.
    restart [service...]Restart all or specified services.
    down [service...]   Stop and remove all or specified services and networks.
    status              Show the status of all running services.
    pullimg             Pull the latest Docker images for all services.
    purge               Remove all chain data (irreversible).
    
    miners <subcommand> Manage storage miners (see 'mineradm miners help').
    cacher <subcommand> Manage cacher services (see 'mineradm cacher help').
    config <subcommand> Manage configuration files (see 'mineradm config help').
    tools <subcommand>  Use utility tools (see 'mineradm tools help').

    profile [name]      View or set the active network profile (devnet, testnet, etc.).
    version             Show version information.
    help                Show this help message.
EOF
}

miner_ops_help() {
  cat <<EOF
Usage: mineradm miners [COMMAND]

Commands:
    increase staking <amount> [miner]   Increase stake for one or all miners.
    increase space <amount> [miner]     Increase declared space for one or all miners (in TiB).
    exit [miner]                        Exit one or all miners from the network.
    withdraw [miner]                    Withdraw stake for one or all miners.
    stat                                Get on-chain statistics for all miners.
    reward                              Query reward information for all miners.
    claim [miner]                       Claim rewards for one or all miners.
    update account <address> [miner]    Update the earnings account for one or all miners.
EOF
}

cacher_ops_help() {
  cat <<EOF
Usage: mineradm cacher [COMMAND]

Commands:
    restart     Restart all cacher services.
    stop        Stop all cacher services.
    remove      Stop and remove all cacher services.
EOF
}

# --- Service Lifecycle Functions ---

install() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -s | --skip-chain)
      skip_chain="true"
      shift
      ;;
    *)
      log_err "Invalid option for install: $1"
      exit 1
      ;;
    esac
  done

  log_info "--- Starting Installation ---"
  is_processors_satisfied
  is_ram_satisfied
  is_sminer_disk_satisfied

  local services
  if [ "$skip_chain" == "true" ]; then
    log_info "Skipping chain service as requested."
    services=$(yq eval '.services | keys | map(select(. != "chain")) | join(" ")' "$compose_yaml")
    if yq eval '.services | has("chain")' "$compose_yaml" &>/dev/null; then
      yq eval 'del(.services.chain)' -i "$compose_yaml"
      log_info "Chain service removed from compose file for this run."
    fi
  else
    services=$(yq eval '.services | keys | join(" ")' "$compose_yaml")
  fi

  log_info "Starting services: $services"
  docker compose -f "$compose_yaml" up -d $services
  
  if [ "$(yq eval ".watchdog.enable" "$config_path")" == "true" ]; then
      log_info "Storage monitor dashboard (if enabled): http://localhost:13080"
  fi
  log_success "Installation complete."
}

stop() {
  if [ ! -f "$compose_yaml" ]; then log_err "Compose file not found. Run 'mineradm config generate' first."; exit 1; fi
  log_info "Stopping services: ${*:-all}"
  docker compose -f "$compose_yaml" stop "$@"
  log_success "Services stopped."
}

restart() {
  if [ ! -f "$compose_yaml" ]; then log_err "Compose file not found. Run 'mineradm config generate' first."; exit 1; fi
  log_info "Restarting services: ${*:-all}"
  if [ $# -eq 0 ]; then
    docker compose -f "$compose_yaml" down
    docker compose -f "$compose_yaml" up -d
  else
    docker compose -f "$compose_yaml" restart "$@"
  fi
  log_success "Services restarted."
}

down() {
  if [ ! -f "$compose_yaml" ]; then log_err "Compose file not found. Run 'mineradm config generate' first."; exit 1; fi
  log_info "Taking down services: ${*:-all}"
  docker compose -f "$compose_yaml" down -v "$@"
  log_success "Services taken down."
}

pullimg() {
  log_info "Pulling latest Docker images for profile: $profile"
  docker pull "cesslab/config-gen:$profile"
  if [ -f "$compose_yaml" ]; then
    docker compose -f "$compose_yaml" pull
  fi
  log_success "Image pull complete."
}

status() {
  docker ps -a --filter "label=com.docker.compose.project=cess-${mode}" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
}

purge() {
  log_info "WARNING: This will permanently remove all chain data in /opt/cess/config/$mode/"
  log_info "         The RPC node will have to re-sync from scratch."
  printf "Press \033[0;33mY\033[0m to confirm: "
  local confirm
  read -r confirm
  if [[ "$confirm" != "Y" && "$confirm" != "y" ]]; then
    log_info "Purge cancelled."
    return
  fi
  
  log_info "Stopping chain service..."
  stop chain
  log_info "Deleting chain data..."
  rm -rf "/opt/cess/config/$mode/"*
  log_success "Purge complete."
}

# --- Cacher Operations ---

cacher_ops() {
  if [ ! -f "$compose_yaml" ]; then log_err "Compose file not found."; exit 1; fi
  
  local cacher_names
  cacher_names=$(yq eval '.services | keys | map(select(. == "cacher*")) | join(" ")' "$compose_yaml")
  if [ -z "$cacher_names" ]; then
    log_info "No cacher services found in configuration."
    return
  fi

  case "${1:-help}" in
  restart)
    log_info "Restarting cacher services: $cacher_names"
    docker compose -f "$compose_yaml" restart $cacher_names
    ;;
  stop)
    log_info "Stopping cacher services: $cacher_names"
    docker compose -f "$compose_yaml" stop $cacher_names
    ;;
  remove)
    log_info "Removing cacher services: $cacher_names"
    docker compose -f "$compose_yaml" down $cacher_names
    ;;
  help | *)
    cacher_ops_help
    ;;
  esac
}

# --- Miner Operations ---

miner_ops() {
  if [ ! -f "$compose_yaml" ]; then
    log_err "docker-compose.yaml not found in /opt/cess/mineradm/build"
    return 1
  fi

  if ! docker compose -f $compose_yaml config >/dev/null; then
    log_err "docker-compose.yaml is not valid !"
    exit 1
  fi

  local miner_names=$(yq eval '.services | keys | map(select(. == "miner*" )) | join(" ")' $compose_yaml)
  local volumes=$(yq eval '.services | to_entries | map(select(.key | test("^miner.*"))) | from_entries | .[] | .volumes' $compose_yaml | xargs | sed "s/['\"]//g" | sed "s/- /-v /g" | xargs -n 4 echo)
  readarray -t volumes_array <<<"$volumes" # read array split with /n
  read -a names_array <<<"$miner_names"    # read array split with " "
  local miner_image="cesslab/cess-miner:$profile"
  local -r cfg_arg="-c /opt/miner/config.yaml" # read only

  case "$1" in
  increase)
    # sudo mineradm miners increase staking $miner_name $token_amount
    if [ $# -eq 4 ] && [ $2 == "staking" ]; then
      # check miner name is correct or not
      is_match_regex "miner" $3
      # $token_amount must be a number
      is_num $4
      local cmd=$(gen_miner_cmd $3 $miner_image)
      if ! local res=$($cmd $1 $2 $4 $cfg_arg); then
        log_err "$3: Increase Stake Failed"
        exit 1
      else
        log_info "$res"
        if echo "$res" | grep -q -E "!!|XX"; then
          log_err "Please make sure that the miner has enough TCESS in signatureAcc and the signatureAcc is the same as stakingAcc"
          log_err "$3: Increase Stake Failed"
          exit 1
        else
          log_success "$3: $4 TCESS has been increased successfully"
          exit 0
        fi
      fi
    # sudo mineradm miners increase staking $token_amount
    elif [ $# -eq 3 ] && [ $2 == "staking" ]; then
      is_num $3
      log_info "WARNING: This operation will increase all of the miners stake and cannot be reverted"
      printf "Press \033[0;33mY\033[0m to continue: "
      local y=""
      read y
      if [ x"$y" != x"Y" ]; then
        exit 1
      fi
      for i in "${!volumes_array[@]}"; do
        local cmd="docker run --rm --network=host ${volumes_array[$i]} $miner_image"
        if ! local res=$($cmd $1 $2 $3 $cfg_arg); then
          log_err "${names_array[$i]}: Increase Stake Failed"
        else
          log_info "$res"
          if echo "$res" | grep -q -E "!!|XX"; then
            log_info "Please make sure that the miners have enough TCESS in signatureAcc and each signatureAcc is the same as its stakingAcc"
            log_err "${names_array[$i]}: Increase Stake Failed"
          else
            log_success "${names_array[$i]}: $3 TCESS has been increased successfully"
          fi
        fi
        echo
      done
    # sudo mineradm miners increase space $miner_name $space_amount(TB)
    elif [ $# -eq 4 ] && [ $2 == "space" ]; then
      # check miner name is correct or not
      is_match_regex "miner" $3
      # $token_amount must be a number
      is_num $4
      local cmd=$(gen_miner_cmd $3 $miner_image)
      if ! local res=$($cmd $1 $2 $4 $cfg_arg); then
        log_err "$3: Increase Declaration Space Failed"
        log_err "Network exception or insufficient balance in stakingAcc"
        exit 1
      else
        log_info "$res"
        if echo "$res" | grep -q -E "!!|XX"; then
          log_err "Please make sure that miner:$3 has enough TCESS in stakingAcc"
          log_err "$3: Increase Declaration Space Failed"
          exit 1
        else
          log_success "$3: Increase Declaration Space to $4 TiB Successfully"
          exit 0
        fi
      fi
    # sudo mineradm miners increase space $space_amount (TB)
    elif [ $# -eq 3 ] && [ $2 == "space" ]; then
      is_num $3
      log_info "WARNING: This operation will increase the declaration space of all miners on the chain by $3 TiB and cannot be reverted"
      printf "Press \033[0;33mY\033[0m to continue: "
      local y=""
      read y
      if [ x"$y" != x"Y" ]; then
        exit 1
      fi
      for i in "${!volumes_array[@]}"; do
        local cmd="docker run --rm --network=host ${volumes_array[$i]} $miner_image"
        if ! local res=$($cmd $1 $2 $3 $cfg_arg); then
          log_err "${names_array[$i]}: Increase Declaration Space Operation Failed"
          log_err "Network exception or insufficient balance in stakingAcc"
        else
          log_info "$res"
          if echo "$res" | grep -q -E "!!|XX"; then
            log_err "Please make sure that the miner:${names_array[$i]} have enough TCESS in stakingAcc"
            log_err "${names_array[$i]}: Increase Declaration Space Operation Failed"
          else
            log_success "${names_array[$i]}: Increase Declaration Space to $3 TiB Operation Success"
          fi
        fi
        echo
      done
    else
      log_err "Parameters Error"
      miner_ops_help
      exit 1
    fi
    ;;
  exit)
    # sudo mineradm miners exit $miner_name
    if [ $# -eq 2 ]; then
      is_match_regex "miner" $2
      local cmd=$(gen_miner_cmd $2 $miner_image)
      if ! local res=$($cmd $1 $cfg_arg); then
        log_err "$2: Exit Operation Failed"
        exit 1
      else
        log_info "$res"
        if echo "$res" | grep -q -E "!!|XX"; then
          log_err "Stake less than 180 days or network exception"
          log_err "$2: Exit Operation Failed"
          exit 1
        else
          log_success "$2: Exit Operation Success"
          exit 0
        fi
      fi
    # sudo mineradm miners exit
    elif [ $# -eq 1 ]; then
      log_info "WARNING: This operation will make all of the miners exit from cess network and cannot be reverted"
      log_info "Please make sure that the miner have staked for more than 180 days"
      printf "Press \033[0;33mY\033[0m to continue: "
      local y=""
      read y
      if [ x"$y" != x"Y" ]; then
        exit 1
      fi
      for i in "${!volumes_array[@]}"; do
        local cmd="docker run --rm --network=host ${volumes_array[$i]} $miner_image"
        if ! local res=$($cmd $1 $cfg_arg); then
          log_err "${names_array[$i]}: Exit Operation Failed"
        else
          log_info "$res"
          if echo "$res" | grep -q -E "!!|XX"; then
            log_info "Stake less than 180 days or network exception"
            log_err "${names_array[$i]}: Exit Operation Failed"
          else
            log_success "${names_array[$i]}: Exit Operation Success"
          fi
        fi
        echo
      done
    else
      log_err "Parameters Error"
      miner_ops_help
      exit 1
    fi
    ;;
  withdraw)
    # sudo mineradm miners withdraw $miner_name
    if [ $# -eq 2 ]; then
      is_match_regex "miner" $2
      local cmd=$(gen_miner_cmd $2 $miner_image)
      if ! local res=$($cmd $1 $cfg_arg); then
        log_err "$2: Withdraw Operation Failed"
        exit 1
      else
        log_info "$res"
        if echo "$res" | grep -q -E "!!|XX"; then
          log_info "Please make sure that the miner has been staking for more than 180 days and the miner has already exited the cess network"
          log_err "$2: Withdraw Operation Failed"
          exit 1
        else
          log_success "$2: Withdraw Operation Success"
          exit 0
        fi
      fi
    # sudo mineradm miners withdraw
    elif [ $# -eq 1 ]; then
      for i in "${!volumes_array[@]}"; do
        local cmd="docker run --rm --network=host ${volumes_array[$i]} $miner_image"
        if ! local res=$($cmd $1 $cfg_arg); then
          log_err "${names_array[$i]}: Withdraw Operation Failed"
        else
          log_info "$res"
          if echo "$res" | grep -q -E "!!|XX"; then
            log_info "Please make sure that the miners have been staking for more than 180 days and the miners have already exited the cess network"
            log_err "${names_array[$i]}: Withdraw Operation Failed"
          else
            log_success "${names_array[$i]}: Withdraw Operation Success"
          fi
        fi
        echo
      done
    else
      log_err "Parameters Error"
      miner_ops_help
      exit 1
    fi
    ;;
  # sudo mineradm miners stat
  stat)
    for i in "${!volumes_array[@]}"; do
      local cmd="docker run --rm --network=host ${volumes_array[$i]} $miner_image"
      if ! local res=$($cmd $1 $cfg_arg); then
        log_err "${names_array[$i]}: Some exceptions have occurred when request on chain"
      else
        log_success "-----------------------------------${names_array[$i]}-----------------------------------"
        log_info "$res"
      fi
      echo
    done
    ;;
  # sudo mineradm miners reward
  reward)
    for i in "${!volumes_array[@]}"; do
      local cmd="docker run --rm --network=host ${volumes_array[$i]} $miner_image"
      if ! $cmd $1 $cfg_arg; then
        log_err "${names_array[$i]}: Reward Operation Failed"
      else
        log_success "${names_array[$i]}: Reward Operation Success"
      fi
      echo
    done
    ;;
  claim)
    # sudo mineradm miners claim $miner_name
    if [ $# -eq 2 ]; then
      is_match_regex "miner" $2
      local cmd=$(gen_miner_cmd $2 $miner_image)
      if ! $cmd $1 $cfg_arg; then
        log_err "$2: Claim Operation Failed"
        exit 1
      else
        log_success "$2: Claim Operation Success"
        exit 0
      fi
    # sudo mineradm miners claim
    elif [ $# -eq 1 ]; then
      for i in "${!volumes_array[@]}"; do
        local cmd="docker run --rm --network=host ${volumes_array[$i]} $miner_image"
        if ! $cmd $1 $cfg_arg; then
          log_err "${names_array[$i]}: Claim Operation Failed"
        else
          log_success "${names_array[$i]}: Claim Operation Success"
        fi
        echo
      done
    else
      log_err "Parameters Error"
      miner_ops_help
      exit 1
    fi
    ;;
  update)
    # sudo mineradm miners update account $miner_name $earnings_account
    if [ $# -eq 4 ]; then
      is_str_equal $2 "account"
      is_match_regex "miner" $3
      local cmd=$(gen_miner_cmd $3 $miner_image)
      if ! local res=$($cmd $1 "earnings" $4 $cfg_arg); then
        log_err "$3: Change To EarningsAcc:$4 Failed"
        exit 1
      else
        log_info "$res"
        if echo "$res" | grep -q -E "!!|XX"; then
          log_err "$3: Change To EarningsAcc:$4 Failed"
          exit 1
        else
          log_success "$3: Change To EarningsAcc:$4"
          exit 0
        fi
      fi
    # sudo mineradm miners update account $earnings_account
    elif [ $# -eq 3 ]; then
      is_str_equal $2 "account"
      log_info "WARNING: This operation will change all of miners earningsAcc to $3"
      printf "Press \033[0;33mY\033[0m to continue: "
      local y=""
      read y
      if [ x"$y" != x"Y" ]; then
        exit 1
      fi
      for i in "${!volumes_array[@]}"; do
        local cmd="docker run --rm --network=host ${volumes_array[$i]} $miner_image"
        if ! res=$($cmd $1 "earnings" $3 $cfg_arg); then
          log_err "${names_array[$i]}: Change To EarningsAcc:$3 Failed"
        else
          log_info "$res"
          if echo "$res" | grep -q -E "!!|XX"; then
            log_err "${names_array[$i]}: Change To EarningsAcc:$3 Failed"
          else
            log_success "${names_array[$i]}: Change To EarningsAcc:$3"
          fi
        fi
        echo
      done
    else
      log_err "Parameters Error"
      miner_ops_help
      exit 1
    fi
    ;;
  *)
    miner_ops_help
    exit 0
    ;;
  esac
}

# --- Main Execution ---

main() {
  case "${1:-help}" in
  install)
    shift
    install "$@"
    ;;
  stop)
    shift
    stop "$@"
    ;;
  restart)
    shift
    restart "$@"
    ;;
  down)
    shift
    down "$@"
    ;;
  status)
    status
    ;;
  pullimg)
    pullimg
    ;;
  purge)
    purge
    ;;
  miners)
    shift
    miner_ops "$@"
    ;;
  cacher)
    shift
    cacher_ops "$@"
    ;;
  config)
    shift
    config "$@"
    ;;
  profile)
    shift
    set_profile "${1:-}"
    ;;
  tools)
    shift
    tools "$@"
    ;;
  version)
    version
    ;;
  help | *)
    help
    ;;
  esac
}

main "$@"