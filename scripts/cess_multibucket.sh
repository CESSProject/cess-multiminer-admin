#!/bin/bash

source /opt/cess/multibucket-admin/scripts/utils.sh
source /opt/cess/multibucket-admin/scripts/version.sh
source /opt/cess/multibucket-admin/scripts/config.sh
source /opt/cess/multibucket-admin/scripts/tools.sh

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
  is_base_cores_satisfied

  # ram request in config.yaml must less than hardware-ram
  is_base_ram_satisfied

  # install services with (chain)rpcnode or not
  local services
  if [ $skip_chain == 'true' ]; then
    local services=$(yq eval '.services | keys | map(select(. != "rpcnode")) | join(" ")' $compose_yaml)
  else
    local services=$(yq eval '.services | keys | join(" ")' $compose_yaml)
  fi

  docker compose -f $compose_yaml up -d $services

  return $?
}

stop() {
  if [ ! -f "$compose_yaml" ]; then
    log_err "No configuration file: docker-compose.yaml, please set configuration"
    exit 1
  fi
  docker compose -f $compose_yaml stop $1
  return $?
}

restart() {
  #  restart from docker-compose.yaml
  if [ ! -f "$compose_yaml" ]; then
    log_err "No configuration file, please set config"
    exit 1
  fi

  docker compose -f $compose_yaml restart $1
  return $?
}

reload() {
  #  reload configuration from config.yaml and regenerate docker-compose.yaml
  if [ ! -f "$compose_yaml" ]; then
    log_err "No configuration file, please set config"
    exit 1
  fi

  if [ x"$1" = x"" ]; then
    log_info "Reload all service"
    docker compose -f $compose_yaml down
    if [ $? -eq 0 ]; then
      docker compose -f $compose_yaml up -d
    fi
    return $?
  fi

  docker compose -f $compose_yaml rm -fs $1
  if [ $? -eq 0 ]; then
    docker compose -f $compose_yaml up -d
  fi
  return $?
}

down() {
  if [ ! -f "$compose_yaml" ]; then
    log_err "No configuration file, please set config"
    exit 1
  fi
  log_info "remove all service"
  docker compose -f $compose_yaml down -v
}

pullimg() {
  docker pull cesslab/config-gen:$profile
  if [ -f "$compose_yaml" ]; then
    docker compose -f $compose_yaml pull
  fi
}

status() {
  echo -e "NAMES        STATUS" && docker ps -a --filter "label=com.docker.compose.project" --format 'table {{.Names}}\t{{.Status}}' | tail -n+2 | sort
}

purge() {
  log_info "WARNING: this operate can remove your data regarding program and can't revert."
  log_info "         Make sure you understand you do!"
  printf "Press \033[0;33mY\033[0m if you really want to do: "
  local y=""
  read y
  if [ x"$y" != x"Y" ]; then
    echo "purge operate cancel"
    return 1
  fi

  if [ x"$1" = x"" ]; then
    if [ x"$mode" == x"authority" ]; then
      purge_chain
      purge_ceseal
    elif [ x"$mode" == x"storage" ]; then
      purge_bucket
      purge_chain
    elif [[ "$mode" == "watcher" || "$mode" == "rpcnode" ]]; then
      purge_chain
    fi
    return $?
  fi

  if [ x"$1" = x"chain" ]; then
    purge_chain
    return $?
  fi

  if [ x"$1" = x"bucket" ]; then
    purge_bucket
    return $?
  fi
  help
  return 1
}

purge_chain() {
  stop chain
  rm -rf /opt/cess/$mode/chain/*
  if [ $? -eq 0 ]; then
    log_success "purge chain data success"
  fi
}

purge_bucket() {
  stop bucket
  rm -rf /opt/cess/$mode/bucket/*
  if [ $? -eq 0 ]; then
    log_success "purge bucket data success"
  fi
}

######################################main entrance############################################

help() {
  cat <<EOF
Usage:
    help                                      show help information
    version                                   show version

    install {chain|kld-sgx|kld-agent|bucket}    start all or one cess service
       option:
           -s, --skip-chain        do not install rpcnode if exist
    stop {chain|kld-sgx|kld-agent|bucket}     stop all or one cess service
    reload {chain|kld-sgx|kld-agent|bucket}   reload (stop remove then start) all or one service
    restart {chain|kld-sgx|kld-agent|bucket}  restart all or one cess service
    down                                      stop and remove all service

    status                              check service status
    pullimg                             update all service images
    purge {chain|kaleido|bucket}        remove datas regarding program, WARNING: this operate can't revert, make sure you understand you do 
    
    config {...}                        configuration operations, use 'cess config help' for more details
    profile {devnet|testnet|mainnet}    switch CESS network profile, testnet for default
    tools {...}                         use 'cess tools help' for more details
EOF
}

load_profile

case "$1" in
  version)
    version
    ;;
  install)
    shift
    install $@
    ;;
  stop)
    stop $2
    ;;
  restart)
    shift
    reload $@
    ;;
  reload)
    shift
    reload $@
    ;;
  down)
    down
    ;;
  status)
    status $2
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
    set_profile $2
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
