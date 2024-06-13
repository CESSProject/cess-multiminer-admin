#!/bin/bash

local_base_dir=$(
  cd "$(dirname $0)" || exit
  pwd
)

skip_dep="false"
retain_config="false"
no_rmi=0
keep_running=0
local_script_dir=$local_base_dir/scripts
install_dir="/opt/cess/mineradm"
source $local_script_dir/utils.sh

help() {
  cat <<EOF
Usage:
    -h | --help                show help information
    -n | --no-rmi              do not remove the corresponding image when uninstalling the service
    -r | --retain-config       retain old config when update mineradm
    -s | --skip-dep            skip install the dependencies
    -k | --keep-running        do not docker compose down all services if there have previous cess services
EOF
  exit 0
}

install_dependencies() {
  if [ x"$skip_dep" == x"true" ]; then
    return 0
  fi

  if [ x"$DISTRO" == x"Ubuntu" ]; then
    log_info "------------Apt update--------------"
    if ! apt-get update; then
      log_err "Apt update failed"
      exit 1
    fi

    log_info "------------Install dependencies--------------"
    if ! apt-get install -y git jq curl wget net-tools netcat; then
      log_err "Install libs failed"
      exit 1
    fi

  elif [ x"$DISTRO" == x"CentOS" ]; then
    log_info "------------Yum update--------------"
    if ! yum update; then
      log_err "Yum update failed"
      exit 1
    fi
    log_info "------------Install dependencies--------------"

    if ! yum install -y git jq curl wget net-tools nmap-ncat; then
      log_err "Install libs failed"
      exit 1
    fi
  fi

  need_install_yq=1
  while [ $need_install_yq -eq 1 ]; do
    if command_exists yq; then
      yq_ver_cur=$(yq -V 2>/dev/null | awk '{print $NF}' | cut -d . -f 1,2 | sed -r 's/^[vV]//')
      if [ -n "$yq_ver_cur" ] && is_ver_a_ge_b $yq_ver_cur $yq_ver_req; then
        need_install_yq=0
      fi
    fi
    if [ $need_install_yq -eq 1 ]; then
      echo "Begin download yq ..."
      if wget https://github.com/mikefarah/yq/releases/download/v4.25.3/yq_linux_amd64 -O /tmp/yq && mv /tmp/yq /usr/bin/yq && chmod +x /usr/bin/yq; then
        log_success "yq is successfully installed!"
        yq -V
      fi
    fi
  done
  if ! command_exists yq; then
    log_err "Install yq failed"
    exit 1
  fi

  need_install_docker=1
  if command_exists docker && [ -e /var/run/docker.sock ]; then
    cur_docker_ver=$(docker version -f '{{.Server.Version}}')
    log_info "current docker version: $cur_docker_ver"
    cur_docker_ver=$(echo $cur_docker_ver | cut -d . -f 1,2)
    if is_ver_a_ge_b $cur_docker_ver $docker_ver_req; then
      need_install_docker=0
      log_info "don't need install or upgrade docker"
    fi
  fi

  if [ $need_install_docker -eq 1 ]; then
    # install or update docker
    if ! curl -fsSL https://get.docker.com | bash; then
      log_err "Install docker failed"
      exit 1
    fi
  fi

  # check docker-compose-plugin
  if [ x"$DISTRO" == x"Ubuntu" ]; then
    if ! dpkg -l | grep -q docker-compose-plugin; then
      add_docker_ubuntu_repo
      if ! apt-get install -y docker-compose-plugin; then
        log_err "Install docker-compose-plugin failed"
        exit 1
      fi
    fi
  elif [ x"$DISTRO" == x"CentOS" ]; then
    if ! rpm -qa | grep -q docker-compose-plugin; then
      add_docker_centos_repo
      if ! yum install -y docker-compose-plugin; then
        log_err "Install docker-compose-plugin failed"
        exit 1
      fi
    fi
  fi
  sysctl -w net.core.rmem_max=2500000
}

install_mineradm() {
  local dst_bin=/usr/bin/mineradm
  local dst_config=$install_dir/config.yaml           # /opt/cess/mineradm/config.yaml
  local dst_utils_sh=$install_dir/scripts/utils.sh    #/opt/cess/mineradm/scripts/utils.sh
  local src_utils_sh=$local_base_dir/scripts/utils.sh #/$pwd/scripts/utils.sh
  local old_version=""
  local new_version=""
  if [ -f "$dst_utils_sh" ]; then
    old_version=$(grep mineradm_version $dst_utils_sh | awk -F = '{gsub(/"/,"");print $2}')
  fi
  if [ -f "$src_utils_sh" ]; then
    new_version=$(grep mineradm_version $dst_utils_sh | awk -F = '{gsub(/"/,"");print $2}')
  fi

  echo "Begin install cess mineradm: $new_version"

  if [ -f "$dst_config" ] && [ x"$retain_config" != x"true" ]; then
    log_info "WARNING: It is detected that you may have previously installed cess mineradm: $old_version"
    log_info "         and that a new installation will overwrite the original configuration."
    log_info "         Request to make sure you have backed up the relevant important configuration data."
    printf "Press \033[0;33mY\033[0m to continue: "
    local y=""
    read y
    if [ x"$y" != x"Y" ]; then
      echo "install operate cancel"
      return 1
    fi
  fi

  local old_config="/tmp/.old_config.yaml"
  if [[ -f $dst_config ]] && [[ $retain_config = "true" ]]; then
    cp $dst_config $old_config
  fi

  if [ -f "$install_dir/scripts/uninstall.sh" ]; then
    echo "Uninstall old cess mineradm: $old_version"
    local opt=
    local keep=
    if [[ $no_rmi -eq 1 ]]; then
      opt="--no-rmi"
    fi
    if [[ $keep_running -eq 1 ]]; then
      keep="--keep-running"
    fi
    sudo bash $install_dir/scripts/uninstall.sh $opt $keep
  fi

  mkdir -p $install_dir

  cp $local_base_dir/config.yaml $dst_config

  if [ -f $old_config ]; then
    mv $old_config $install_dir
    log_info "Save old config in /opt/cess/mineradm: .old_config.yaml"
  fi
  chown root:root $install_dir/config.yaml
  chmod 0600 $install_dir/config.yaml

  cp -r $local_base_dir/scripts $install_dir/

  cp $local_script_dir/miner.sh $dst_bin
  chmod +x $dst_bin

  chmod +x $install_dir/scripts/*
  echo "source $install_dir/scripts/completion.sh" >> ~/.bashrc
  source $install_dir/scripts/completion.sh

  log_success "Install cess mineradm success"
}

while true; do
  case "$1" in
  -s | --skip-dep)
    skip_dep="true"
    shift 1
    ;;
  -r | --retain-config)
    retain_config="true"
    shift 1
    ;;
  -n | --no-rmi)
    no_rmi=1
    shift 1
    ;;
  -k | --keep-running)
    keep_running=1
    shift 1
    ;;
  "")
    shift
    break
    ;;
  *)
    help
    break
    ;;
  esac
done

ensure_root
get_distro_name

if [ x"$DISTRO" != x"Ubuntu" ] && [ x"$DISTRO" != x"CentOS" ]; then
  log_err "Only support Ubuntu or CentOS currently"
  exit 1
fi

if ! is_kernel_satisfied; then
  exit 1
fi

if ! is_base_hardware_satisfied; then
  exit 1
fi

install_dependencies
install_mineradm
