#!/bin/bash

source /opt/cess/mineradm/scripts/utils.sh
source /opt/cess/mineradm/scripts/version.sh
source /opt/cess/mineradm/scripts/config.sh
source /opt/cess/mineradm/scripts/tools.sh

########################################base################################################

install() {
  for option in "$@"; do
    case "$option" in
    -s | --skip-chain)
      skip_chain="true"
      ;;
    *) echo "Invalid option: $option" ;;
    esac
  done

  # cores request in config.yaml must less than hardware-cores
  is_processors_satisfied

  # ram request in config.yaml must less than hardware-ram
  is_ram_satisfied

  # disk request in config.yaml must less than hardware-disk
  is_disk_satisfied

  # install services with (chain)rpcnode or not
  local services
  if [ $skip_chain == 'true' ]; then
    local services=$(yq eval '.services | keys | map(select(. != "chain")) | join(" ")' $compose_yaml)
    if [ "$(yq eval '.services | has("chain")' $compose_yaml)" == 'true' ]; then
      yq eval 'del(.services.chain)' -i $compose_yaml
      log_info "Chain configuration has deleted in: $compose_yaml"
      log_info "Execute [ sudo mineradm config generate ] to restore"
    fi
  else
    local services=$(yq eval '.services | keys | join(" ")' $compose_yaml)
  fi

  docker compose -f $compose_yaml up -d $services

  if [ "$(yq eval ".services.watchdog-web" $compose_yaml)" ]; then
    if [ "$(yq eval ".services.watchdog-web.environment" $compose_yaml)" ]; then
      log_info "Storage monitor run at: http://localhost:13080"
    fi
  fi

  return $?
}

stop() {
  if [ ! -f "$compose_yaml" ]; then
    log_err "docker-compose.yaml not found in /opt/cess/mineradm/build"
    exit 1
  fi
  if [ x"$1" = x"" ]; then
    log_info "Stop all services"
    docker compose -f $compose_yaml stop
    return $?
  fi

  log_info "Stop service: $*"
  docker compose -f $compose_yaml stop "$@"
  return $?
}

restart() {
  if [ ! -f "$compose_yaml" ]; then
    log_err "docker-compose.yaml is not found in /opt/cess/mineradm/build"
    exit 1
  fi

  if [ x"$1" = x"" ]; then
    log_info "Restart all services"
    if docker compose -f $compose_yaml down; then
      docker compose -f $compose_yaml up -d
    fi
    return $?
  fi

  log_info "Restart service: $*"
  docker compose -f $compose_yaml restart "$@"
  return $?
}

down() {
  if [ ! -f "$compose_yaml" ]; then
    log_err "docker-compose.yaml not found in /opt/cess/mineradm/build"
    exit 1
  fi

  if [ x"$1" = x"" ]; then
    log_info "Remove all services"
    docker compose -f $compose_yaml down -v
    return $?
  fi

  log_info "Remove service: $*"
  docker compose -f $compose_yaml down "$@"
  return $?
}

pullimg() {
  docker pull cesslab/config-gen:$profile
  if [ -f "$compose_yaml" ]; then
    docker compose -f $compose_yaml pull
  fi
}

status() {
  docker ps -a --filter "label=com.docker.compose.project=cess-${mode}" --format 'table {{.Names}}\t{{.Status}}' | sort
}

purge() {
  log_info "WARNING: this operation can remove all your data in /opt/cess/data/$mode/* and can't revert."
  printf "Press \033[0;33mY\033[0m if you really want to do: "
  local y=""
  read y
  if [ x"$y" != x"Y" ]; then
    echo "purge operate cancel"
    return 1
  fi
  purge_data
  return $?
}

purge_data() {
  stop chain
  if rm -rf /opt/cess/data/$mode/*; then
    log_success "purge data successfully"
  else
    log_err "Can not remove data in: /opt/cess/data/$mode/"
  fi
}

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
          log_success "$3: Increase Stake To $4"
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
            log_success "${names_array[$i]}: Increase Stake To $3"
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
        if echo "$res" | grep -q -E "!!|XX"; then
          log_err "${names_array[$i]}: Some exceptions have occurred when request on chain"
        else
          log_success "-----------------------------------${names_array[$i]}-----------------------------------"
          log_info "$res"
        fi
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

miner_ops_help() {
  cat <<EOF
cess miners usage:
    increase                            Increase the stake/space of storage miner
      options:
        staking                         Increase the stake of storage miner
        space                           Increase the declaration space to $amount of miner on the chain, unit: TiB
    exit                                Unregister the storage miner role from cess network
    withdraw                            Withdraw stake
    stat                                Get storage miner stat
    reward                              Query reward information
    claim                               Claim reward
    update                              Update earnings account
EOF
}

###################################### main entrance ###########################################

help() {
  cat <<EOF
Usage:
    help                                        show help information
    -v | version                                show version information
    install                                     run all services
       option:
           -s, --skip-chain                     do not run a local chain if miners want to access to a chain in others host
    miners                                      miners operations
       option:
           increase                             Increase the stake/declarationSpace of storage miner
           exit                                 Unregister the storage miner role
           withdraw                             Withdraw stake
           stat                                 Query storage miners stat
           reward                               Query reward information
           claim                                Claim reward
           update                               Update earnings account
    stop                                        stop all or one cess service
       option:
           chain                                stop chain at localhost
           watchtower                           stop watchtower at localhost
           miner_i                              stop a specific storage node at localhost
    restart                                     restart all or one cess service
       option:
           chain                                restart chain at localhost
           watchtower                           restart watchtower at localhost
           miner_i                              restart a specific storage node at localhost
    down                                        down all or one cess service
       option:
           chain                                down chain at localhost
           watchtower                           down watchtower at localhost
           miner_i                              down a specific storage node at localhost
    status                                      check service status
    pullimg                                     update or download all service images
    purge                                       remove chain data. WARNING: this operation can"t be reverted
    config                                      configuration operations
       option:
           -s | show                            show configurations
           -g | generate                        generate configuration by default file: /opt/cess/mineradm/config.yaml
    profile {devnet|testnet|mainnet}            switch CESS network profile, testnet for default
    tools                                       use 'mineradm tools help' for more details
       option:
           space-info                           show information about miner disk
           no-watch                             do not auto-update container: {autoheal/chain/miner1/miner2 ...}
           set
             option:
               use-space                        change miner's use-space, unit: GiB
EOF
}

load_profile

case "$1" in
miners)
  shift
  miner_ops "$@"
  ;;
-v | version)
  version
  ;;
install | start)
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
-s | status)
  shift
  status
  ;;
pullimg)
  pullimg
  ;;
purge)
  shift
  purge "$@"
  ;;
config)
  shift
  config "$@"
  ;;
profile)
  set_profile
  ;;
tools)
  shift
  tools "$@"
  ;;
*)
  help
  ;;
esac
exit 0
