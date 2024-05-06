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
  docker compose -f $compose_yaml stop $*
  return $?
}

restart() {
  if [ ! -f "$compose_yaml" ]; then
    log_err "docker-compose.yaml is not found in /opt/cess/mineradm/build"
    exit 1
  fi

  if [ x"$1" = x"" ]; then
    log_info "Restart all services"
    docker compose -f $compose_yaml down
    if [ $? -eq 0 ]; then
      docker compose -f $compose_yaml up -d
    fi
    return $?
  fi

  log_info "Restart service: $*"
  docker compose -f $compose_yaml rm -fs $*
  if [ $? -eq 0 ]; then
    docker compose -f $compose_yaml up -d
  fi
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
  docker compose -f $compose_yaml down $*
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
  log_info "WARNING: this operation can remove all your data in /opt/cess/miners/* and can't revert."
  log_info "         Make sure you understand you do!"
  printf "Press \033[0;33mY\033[0m if you really want to do: "
  local y=""
  read y
  if [ x"$y" != x"Y" ]; then
    echo "purge operate cancel"
    return 1
  fi

  if [ x"$1" = x"" ]; then
    purge_miner
    purge_chain
    return $?
  fi
  if [ x"$1" = x"chain" ]; then
    purge_chain
    return $?
  fi
  if [ x"$1" = x"miner" ]; then
    purge_miner
    return $?
  fi
  help
  return 1
}

purge_chain() {
  stop chain
  rm -rf /opt/cess/data/$mode/chain/*
  if [ $? -eq 0 ]; then
    log_success "purge chain data successfully"
  fi
}

purge_miner() {
  stop
  rm -rf /opt/cess/data/$mode/miners/*
  if [ $? -eq 0 ]; then
    log_success "purge miner data successfully"
  fi
}

miner_ops() {
  if [ ! -f "$compose_yaml" ]; then
    log_err "docker-compose.yaml not found in /opt/cess/mineradm/build"
    return 1
  fi

  docker compose -f $compose_yaml config >/dev/null
  if [ ! $? -eq 0 ]; then
    log_err "docker-compose.yaml is not valid !"
  fi

  case "$1" in
  increase)
    if [ $# -eq 3 ]; then
      log_info "WARNING: This operation will increase all of your miners stake"
      printf "Press \033[0;33mY\033[0m to continue: "
      local y=""
      read y
      if [ x"$y" != x"Y" ]; then
        exit 1
      fi
    fi
    ;;
  exit)
    if [ $# -eq 1 ]; then
      log_info "I am sure that I have staked for more than 180 days"
      log_info "WARNING: This operation will make all of your miners exit from cess network"
      printf "Press \033[0;33mY\033[0m to continue: "
      local y=""
      read y
      if [ x"$y" != x"Y" ]; then
        exit 1
      fi
    fi
    ;;
  update)
    if [ $# -eq 3 ]; then
      log_info "WARNING: This operation will update all of your miner's earningsAcc"
      printf "Press \033[0;33mY\033[0m to continue: "
      local y=""
      read y
      if [ x"$y" != x"Y" ]; then
        exit 1
      fi
    fi
    ;;
  *) ;;
  esac

  local miner_names=$(yq eval '.services | keys | map(select(. == "'miner'*" )) | join(" ")' $compose_yaml)
  local volumes=$(yq eval '.services | to_entries | map(select(.key | test("^miner.*"))) | from_entries | .[] | .volumes' $compose_yaml | xargs | sed "s/['\"]//g" | sed "s/- /-v /g" | xargs -n 4 echo)
  readarray -t volumes_array <<<"$volumes" # read array split with /n
  read -a names_array <<<"$miner_names"    # read array split with " "
  local miner_image="cesslab/cess-miner:$profile"
  local -r cfg_arg="-c /opt/miner/config.yaml"

  for i in "${!volumes_array[@]}"; do
    local cmd="docker run --rm --network=host ${volumes_array[$i]} $miner_image"
    case "$1" in
    increase)
      # sudo mineradm miners increase staking <miner name> <deposit amount>
      if [ $# -eq 4 ]; then
        local miner_i_volumes=$(docker inspect -f '{{.HostConfig.Binds}}' $3 | sed -e 's/\[\(.*\):rw \(.*\):rw\]/-v \1 -v \2/')
        local cmd="docker run --rm --network=host $miner_i_volumes $miner_image"
        res=$($cmd $1 $2 $4 $cfg_arg)
        log_info "$res"
        if [ $? -ne 0 ]; then
          log_err "$3: Increase Operation Failed"
          exit 1
        else
          if echo "$res" | grep -q "!"; then
            log_err "Please make sure that you have enough TCESS in signatureAcc and signatureAcc is same as stakingAcc"
            log_err "$3: Increase Operation Failed"
            exit 1
          else
            log_success "$3: Increase Operation Success"
            exit 0
          fi
        fi
      # sudo mineradm miners increase staking <deposit amount>
      elif [ $# -eq 3 ]; then
        res=$($cmd $1 $2 $3 $cfg_arg)
        log_info "$res"
        if [ $? -ne 0 ]; then
          log_err "${names_array[$i]}: Increase Operation Failed"
        else
          if echo "$res" | grep -q "!"; then
            log_info "Please make sure that you have enough TCESS in signatureAcc and signatureAcc is same as stakingAcc"
            log_err "${names_array[$i]}: Increase Operation Failed"
          else
            log_info "${names_array[$i]}: Increase Operation Success"
          fi
        fi
      else
        log_err "Args Error"
        exit 1
      fi
      ;;
    exit)
      # sudo mineradm miners exit <miner name>
      if [ $# -eq 2 ]; then
        local miner_i_volumes=$(docker inspect -f '{{.HostConfig.Binds}}' $2 | sed -e 's/\[\(.*\):rw \(.*\):rw\]/-v \1 -v \2/')
        local cmd="docker run --rm --network=host $miner_i_volumes $miner_image"
        res=$($cmd $1 $cfg_arg)
        log_info "$res"
        if [ $? -ne 0 ]; then
          log_err "$2: Exit Operation Failed"
          exit 1
        else
          if echo "$res" | grep -q "!"; then
            log_err "Stake less than 180 days or network issue"
            log_err "$2: Exit Operation Failed"
            exit 1
          else
            log_info "$2: Exit Operation Success"
            exit 0
          fi
        fi
      # sudo mineradm miners exit
      elif [ $# -eq 1 ]; then
        res=$($cmd $1 $cfg_arg)
        log_info "$res"
        if [ $? -ne 0 ]; then
          log_err "${names_array[$i]}: Exit Operation Failed"
        else
          if echo "$res" | grep -q "!"; then
            log_info "Stake less than 180 days or network issue"
            log_err "${names_array[$i]}: Exit Operation Failed"
          else
            log_info "${names_array[$i]}: Exit Operation Success"
          fi
        fi
      else
        log_err "Args Error"
        exit 1
      fi
      ;;
    withdraw)
      # sudo mineradm miners withdraw <miner name>
      if [ $# -eq 2 ]; then
        miner_i_volumes=$(docker inspect -f '{{.HostConfig.Binds}}' $2 | sed -e 's/\[\(.*\):rw \(.*\):rw\]/-v \1 -v \2/')
        local cmd="docker run --rm --network=host $miner_i_volumes $miner_image"
        res=$($cmd $1 $cfg_arg)
        log_info "$res"
        if [ $? -ne 0 ]; then
          log_err "$2: Withdraw Operation Failed"
          exit 1
        else
          if echo "$res" | grep -q "!"; then
            log_info "Please make sure the miner have staked for more than 180 days and the miner have exit the cess network"
            log_err "$2: Withdraw Operation Failed"
            exit 1
          else
            log_success "$2: Withdraw Operation Success"
            exit 0
          fi
        fi
      # sudo mineradm miners withdraw
      elif [ $# -eq 1 ]; then
        res=$($cmd $1 $cfg_arg)
        log_info "$res"
        if [ $? -ne 0 ]; then
          log_err "${names_array[$i]}: Withdraw Operation Failed"
        else
          if echo "$res" | grep -q "!"; then
            log_info "Please make sure the miner have staked for more than 180 days and the miner have exit the cess network"
            log_err "${names_array[$i]}: Withdraw Operation Failed"
          else
            log_success "${names_array[$i]}: Withdraw Operation Success"
          fi
        fi
      else
        log_err "Args Error"
        exit 1
      fi
      ;;
    # sudo mineradm miners status
    stat)
      $cmd $1 $cfg_arg
      if [ $? -ne 0 ]; then
        log_err "${names_array[$i]}: Query Failed"
      else
        log_success "${names_array[$i]}: Query Success"
      fi
      ;;
    # sudo mineradm miners reward
    reward)
      $cmd $1 $cfg_arg
      if [ $? -ne 0 ]; then
        log_err "${names_array[$i]}: Reward Operation Failed"
        exit 1
      else
        log_success "${names_array[$i]}: Reward Operation Success"
      fi
      ;;
    claim)
      # sudo mineradm miners claim <miner name>
      if [ $# -eq 2 ]; then
        miner_i_volumes=$(docker inspect -f '{{.HostConfig.Binds}}' $2 | sed -e 's/\[\(.*\):rw \(.*\):rw\]/-v \1 -v \2/')
        local cmd="docker run --rm --network=host $miner_i_volumes $miner_image"
        $cmd $1 $cfg_arg
        if [ $? -ne 0 ]; then
          log_err "$2: Claim Operation Failed"
          exit 1
        else
          log_success "$2: Claim Operation Success"
          exit 0
        fi
      # sudo mineradm miners claim
      elif [ $# -eq 1 ]; then
        $cmd $1 $cfg_arg
        if [ $? -ne 0 ]; then
          log_err "${names_array[$i]}: Claim Operation Failed"
        else
          log_success "${names_array[$i]}: Claim Operation Success"
        fi
      else
        log_err "Args Error"
        exit 1
      fi
      ;;
    update)
      # sudo mineradm miners update account $miner_n $earnings_account
      if [ $# -eq 4 ]; then
        local miner_i_volumes=$(docker inspect -f '{{.HostConfig.Binds}}' $3 | sed -e 's/\[\(.*\):rw \(.*\):rw\]/-v \1 -v \2/')
        local cmd="docker run --rm --network=host $miner_i_volumes $miner_image"
        res=$($cmd $1 "earnings" $4 $cfg_arg)
        log_info "$res"
        if [ $? -ne 0 ]; then
          log_err "$3: Change EarningsAcc Operation Failed"
          exit 1
        else
          if echo "$res" | grep -q "!"; then
            log_err "$3: Change EarningsAcc Operation Failed"
            exit 1
          else
            log_success "$3: Change EarningsAcc Operation Success"
            exit 0
          fi
        fi
      # sudo mineradm miners update account $earnings_account
      elif [ $# -eq 3 ]; then
        res=$($cmd $1 "earnings" $3 $cfg_arg)
        log_info "$res"
        if [ $? -ne 0 ]; then
          log_err "${names_array[$i]}: Change EarningsAcc Operation Failed"
        else
          if echo "$res" | grep -q "!"; then
            log_err "${names_array[$i]}: Change EarningsAcc Operation Failed"
          else
            log_info "${names_array[$i]}: Change EarningsAcc Operation Success"
          fi
        fi
      else
        log_err "Args Error"
        exit 1
      fi
      ;;
    *)
      miner_ops_help
      exit 0
      ;;
    esac
    log_info "----------------------------------------------------------------------------\n"
  done
}

miner_ops_help() {
  cat <<EOF
cess miners usage:
    increase [amount]                   Increase the stakes of storage miner
    exit                                Unregister the storage miner role
    withdraw                            Withdraw stakes
    stat                                Query storage miner information
    reward                              Query reward information
    claim                               Claim reward
    update earnings [wallet account]    Update earnings account
EOF
}

######################################main entrance############################################

help() {
  cat <<EOF
Usage:
    help                                        show help information
    -v | version                                show version information
    install                                     run all services
       option:
           -s, --skip-chain                     do not install chain if you do not run a chain at localhost
    miners                                     miners operations
       option:
           increase [amount]                    Increase the stakes of storage miner
           exit                                 Unregister the storage miner role
           withdraw                             Withdraw stakes
           stat                                 Query storage miners stat
           reward                               Query reward information
           claim                                Claim reward
           update earnings [wallet account]     Update earnings account
    stop                                        stop all or one cess service
       option:
           chain                                stop chain at localhost
           watchtower                           stop watchtower at localhost
           miner_$i                            stop a specific storage node at localhost
    restart                                     restart all or one cess service
       option:
           chain                                restart chain at localhost
           watchtower                           restart watchtower at localhost
           miner_$i                            restart a specific storage node at localhost
    down                                        down all or one cess service
       option:
           chain                                down chain at localhost
           watchtower                           down watchtower at localhost
           miner_$i                            down a specific storage node at localhost
    status                                      check service status
    pullimg                                     update all service images
    purge {chain|miner}                        remove datas regarding program, WARNING: this operate can't revert, make sure you understand you do
    config                                      configuration operations
       option:
           -s | show                            show configurations
           -g | generate                        generate configuration by default file: /opt/cess/mineradm/config.yaml
           -p | pull-image                      download corresponding images after set config
    profile {devnet|testnet|mainnet}            switch CESS network profile, testnet for default
    tools                                       use 'mineradm tools help' for more details
       option:
           rotate-keys                          generate session key of chain node
           space-info                           show information about miner disk
EOF
}

load_profile

case "$1" in
miners)
  shift
  miner_ops $@
  ;;
-v | version)
  version
  ;;
install)
  shift
  install $@
  ;;
stop)
  shift
  stop $@
  ;;
restart)
  shift
  restart $@
  ;;
down)
  shift
  down $@
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
  purge $@
  ;;
config)
  shift
  config $@
  ;;
profile)
  set_profile
  ;;
tools)
  shift
  tools $@
  ;;
*)
  help
  ;;
esac
exit 0
