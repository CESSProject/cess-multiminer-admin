#!/bin/bash

no_rmi=0
keep_running=0
case "$1" in
  --no-rmi)
    no_rmi=1
    ;;
esac

case "$2" in
  --keep-running)
    keep_running=1
    ;;
esac

install_dir=/opt/cess/mineradm
compose_yaml=$install_dir/build/docker-compose.yaml
bin_file=/usr/bin/mineradm

if [ $(id -u) -ne 0 ]; then
    echo "Please run with sudo!"
    exit 1
fi

if [[ -f "$compose_yaml" ]] && [[ $keep_running -eq 0 ]]; then
    docker compose -f $compose_yaml rm -sf
    rmi_opt="--rmi all"
    if [[ $no_rmi -eq 1 ]]; then
        rmi_opt=""
    fi
    docker compose -f $compose_yaml down -v --remove-orphans $rmi_opt
fi

if [ -f "$bin_file" ]; then
    rm /usr/bin/mineradm
fi

rm -rf $install_dir
