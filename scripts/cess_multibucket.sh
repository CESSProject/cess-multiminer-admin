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
    local services=$(yq eval '.services | keys | map(select(. != "chain")) | join(" ")' $compose_yaml)
  else
    local services=$(yq eval '.services | keys | join(" ")' $compose_yaml)
  fi

  docker compose -f $compose_yaml up -d $services

  return $?
}

stop() {
  if [ ! -f "$compose_yaml" ]; then
    log_err "No configuration file: docker-compose.yaml is not found in /opt/cess/multibucket-admin/build"
    exit 1
  fi
  docker compose -f $compose_yaml stop $1
  return $?
}

restart() {
  #  restart configuration from config.yaml and regenerate docker-compose.yaml
  if [ ! -f "$compose_yaml" ]; then
    log_err "No configuration file: docker-compose.yaml is not found in /opt/cess/multibucket-admin/build"
    exit 1
  fi

  if [ x"$1" = x"" ]; then
    log_info "Restart all service"
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
    log_err "No configuration file: docker-compose.yaml not found in /opt/cess/multibucket-admin/build"
    exit 1
  fi
  log_info "remove all services"
  docker compose -f $compose_yaml down -v
}

pullimg() {
  docker pull cesslab/config-gen:$profile
  if [ -f "$compose_yaml" ]; then
    docker compose -f $compose_yaml pull
  fi
}

status() {
  docker ps -a --filter "label=com.docker.compose.project=cess-multibucket" --format 'table {{.Names}}\t{{.Status}}' | sort
}

purge() {
  log_info "WARNING: this operation can remove all your data in /opt/cess/multibucket/* and can't revert."
  log_info "         Make sure you understand you do!"
  printf "Press \033[0;33mY\033[0m if you really want to do: "
  local y=""
  read y
  if [ x"$y" != x"Y" ]; then
    echo "purge operate cancel"
    return 1
  fi

  if [ x"$1" = x"" ]; then
    if [ x"$mode" == x"multibucket" ]; then
      purge_bucket
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
    log_success "purge chain data successfully"
  fi
}

purge_bucket() {
  stop bucket
  rm -rf /opt/cess/$mode/bucket/*
  if [ $? -eq 0 ]; then
    log_success "purge bucket data successfully"
  fi
}

bucket_ops() {
  if [ ! -f "$compose_yaml" ]; then
    log_err "No configuration file, please set config"
    return 1
  fi

  docker compose -f $compose_yaml config 1>/dev/null
  if [ ! $? -eq 0 ]; then
    log_err "docker-compose.yaml is not valid !"
  fi
  local bucket_names=$(yq eval '.services | keys | map(select(. == "'bucket'*" )) | join(" ")' $compose_yaml)
  local volumes=$(yq eval '.services | to_entries | map(select(.key | test("^bucket_.*"))) | from_entries | .[] | .volumes' $compose_yaml | xargs | sed "s/['\"]//g" | sed "s/- /-v /g" | xargs -n 4 echo)
  readarray -t volumes_array <<<"$volumes"
  read -a names_array <<<"$bucket_names"

  local bucket_image="cesslab/cess-bucket:$profile"
  local -r cfg_arg=" -c /opt/bucket/config.yaml"
  for i in "${!volumes_array[@]}"; do
    local cmd="docker run --rm --network=host ${volumes_array[$i]} $bucket_image"
    case "$1" in
    increase)
      if [ $# -eq 4 ]; then
        local bucket_i_volumes=$(docker inspect -f '{{.HostConfig.Binds}}' $3 | sed s/["["]/"-v "/g | sed s/":rw "/" -v "/g | sed s/":rw]"//g)
        local cmd="docker run --rm --network=host $bucket_i_volumes $bucket_image"
        $cmd $1 $2 $4 $cfg_arg
        return 1
      elif [ $# -eq 3 ]; then
        $cmd $1 $2 $3 $cfg_arg
      else
        log_err "Args Error"
      fi
      ;;
    exit)
      if [ $# -eq 2 ]; then
        local bucket_i_volumes=$(docker inspect -f '{{.HostConfig.Binds}}' $2 | sed s/["["]/"-v "/g | sed s/":rw "/" -v "/g | sed s/":rw]"//g)
        local cmd="docker run --rm --network=host $bucket_i_volumes $bucket_image"
        $cmd $1 $cfg_arg
        return 1
      elif [ $# -eq 1 ]; then
        $cmd $1 $cfg_arg
      else
        log_err "Args Error"
      fi
      ;;
    withdraw)
      if [ $# -eq 2 ]; then
        bucket_i_volumes=$(docker inspect -f '{{.HostConfig.Binds}}' $2 | sed s/["["]/"-v "/g | sed s/":rw "/" -v "/g | sed s/":rw]"//g)
        local cmd="docker run --rm --network=host $bucket_i_volumes $bucket_image"
        $cmd $1 $cfg_arg
        return 1
      elif [ $# -eq 1 ]; then
        $cmd $1 $cfg_arg
      else
        log_err "Args Error"
      fi
      ;;
    stat)
      $cmd $1 $cfg_arg
      ;;
    reward)
      $cmd $1 $2 $cfg_arg
      ;;
    claim)
      if [ $# -eq 2 ]; then
        bucket_i_volumes=$(docker inspect -f '{{.HostConfig.Binds}}' $2 | sed s/["["]/"-v "/g | sed s/":rw "/" -v "/g | sed s/":rw]"//g)
        local cmd="docker run --rm --network=host $bucket_i_volumes $bucket_image"
        $cmd $1 $cfg_arg
        return 1
      elif [ $# -eq 1 ]; then
        $cmd $1 $cfg_arg
      else
        log_err "Args Error"
      fi
      ;;
    update)
      if [ "$2" == "earnings" ]; then
        $cmd $1 $2 $3 $cfg_arg
      else
        bucket_ops_help
      fi
      ;;
    *)
      bucket_ops_help
      ;;
    esac
    log_info "----------------------------------------------------------------------------\n"
    log_info "----------------------------------------------------------------------------\n"
  done
}

bucket_ops_help() {
  cat <<EOF
cess bucket usage (only on storage mode):
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
    bucket                                      bucket operations
       option:
           increase [amount]                    Increase the stakes of storage miner
           exit                                 Unregister the storage miner role
           withdraw                             Withdraw stakes
           stat                                 Query storage miner information
           reward                               Query reward information
           claim                                Claim reward
           update earnings [wallet account]     Update earnings account
    stop                                        stop all or one cess service
       option:
           chain                                stop chain at localhost
           watchtower                           stop watchtower at localhost
           bucket_$i                            stop a specific storage node at localhost
    restart                                     restart all or one cess service
       option:
           chain                                restart chain at localhost
           watchtower                           restart watchtower at localhost
           bucket_$i                            restart a specific storage node at localhost
    down                                        down all or one cess service
       option:
           chain                                down chain at localhost
           watchtower                           down watchtower at localhost
           bucket_$i                            down a specific storage node at localhost
    status                                      check service status
    pullimg                                     update all service images
    purge {chain|bucket}                        remove datas regarding program, WARNING: this operate can't revert, make sure you understand you do
    config                                      configuration operations
       option:
           -s | show                            show configurations
           -g | generate                        generate configuration by default file: /opt/cess/multibucket-admin/config.yaml
           -p | pull-image                      download corresponding images after set config
    profile {devnet|testnet|mainnet}            switch CESS network profile, testnet for default
    tools                                       use 'cess-multibucket-admin tools help' for more details
       option:
           rotate-keys                          generate session key of chain node
           space-info                           show information about bucket disk
EOF
}

load_profile

case "$1" in
buckets)
  shift
  bucket_ops $@
  ;;
-v | version)
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
  restart $@
  ;;
down)
  down
  ;;
-s | status)
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
