#!/bin/bash

multibucket_admin_version="v0.0.6"
skip_chain="false"
base_dir=/opt/cess/multibucket-admin
script_dir=$base_dir/scripts
config_path=$base_dir/config.yaml
build_dir=$base_dir/build
compose_yaml=$build_dir/docker-compose.yaml
profile="testnet"
kernel_ver_req="5.11"
docker_ver_req="20.10"
yq_ver_req="4.25"
cpu_req=4
ram_req=8
PM=""
DISTRO=""

each_bucket_ram_req=4  # at least 4GB RAM for each bucket
each_bucket_cpu_req=1  # at least 1 core for each bucket
each_rpcnode_ram_req=2 # at least 2GB RAM for each rpcnode
each_rpcnode_cpu_req=1 # at least 1 core for each rpcnode

function echo_c() {
  printf "\033[0;$1m$2\033[0m\n"
}

function log_info() {
  echo_c 33 "$1"
}

function log_success() {
  echo_c 32 "$1"
}

function log_err() {
  echo_c 35 "[ERROR] $1"
}

check_port() {
  local port=$1
  local grep_port=$(netstat -tlpn | grep "\b$port\b")
  if [ -n "$grep_port" ]; then
    log_err "please make sure port: $port is not occupied"
    exit 1
  fi
}

## 0 for running, 2 for error, 1 for stop
check_docker_status() {
  local exist=$(docker inspect --format '{{.State.Running}}' $1 2>/dev/null)
  if [ x"${exist}" == x"true" ]; then
    return 0
  elif [ "${exist}" == "false" ]; then
    return 2
  else
    return 1
  fi
}

## rnd=$(rand 1 50)
rand() {
  min=$1
  max=$(($2 - $min + 1))
  num=$(date +%s%N)
  echo $(($num % $max + $min))
}

ensure_root() {
  if [ $(id -u) -ne 0 ]; then
    log_err "Please run with sudo!"
    exit 1
  fi
}

get_distro_name() {
  if grep -Eqi "Ubuntu" /etc/issue || grep -Eq "Ubuntu" /etc/*-release; then
    DISTRO='Ubuntu'
    PM='apt'
  elif grep -Eqi "CentOS" /etc/issue || grep -Eq "CentOS" /etc/*-release; then
    DISTRO='CentOS'
    PM='yum'
  elif grep -Eqi "Red Hat Enterprise Linux Server" /etc/issue || grep -Eq "Red Hat Enterprise Linux Server" /etc/*-release; then
    DISTRO='RHEL'
    PM='yum'
  elif grep -Eqi "Aliyun" /etc/issue || grep -Eq "Aliyun" /etc/*-release; then
    DISTRO='Aliyun'
    PM='yum'
  elif grep -Eqi "Fedora" /etc/issue || grep -Eq "Fedora" /etc/*-release; then
    DISTRO='Fedora'
    PM='yum'
  elif grep -Eqi "Debian" /etc/issue || grep -Eq "Debian" /etc/*-release; then
    DISTRO='Debian'
    PM='apt'
  elif grep -Eqi "Raspbian" /etc/issue || grep -Eq "Raspbian" /etc/*-release; then
    DISTRO='Raspbian'
    PM='apt'
  else
    log_err 'unsupport linux distro'
    return 1
  fi
  return 0
}

set_profile() {
  local to_set=$1
  if [ -z $to_set ]; then
    log_info "current profile: $profile"
    return 0
  fi
  if [ x"$to_set" == x"devnet" ] || [ x"$to_set" == x"testnet" ] || [ x"$to_set" == x"mainnet" ]; then
    yq -i eval ".node.profile=\"$to_set\"" $config_path
    log_success "set profile to $to_set"
    return 0
  fi
  log_err "Invalid profile value in: devnet/testnet/mainnet"
  return 1
}

load_profile() {
  local p="$(yq eval ".node.profile" $config_path)"
  if [ x"$p" == x"devnet" ] || [ x"$p" == x"testnet" ] || [ x"$p" == x"mainnet" ]; then
    profile=$p
    return 0
  fi
  log_info "the profile: $p of config file is invalid, use default value: $profile"
  return 1
}

command_exists() {
  command -v "$@" >/dev/null 2>&1
}

# is_ver_a_ge_b compares two CalVer (YY.MM) version strings. returns 0 (success)
# if version A is newer or equal than version B, or 1 (fail) otherwise. Patch
# releases and pre-release (-alpha/-beta) are not taken into account
# compare docker version、linux-kernel version ...
#
# examples:
#
# is_ver_a_ge_b 20.10 19.03 // 0 (success)
# is_ver_a_ge_b 20.10 20.10 // 0 (success)
# is_ver_a_ge_b 19.03 20.10 // 1 (fail)
is_ver_a_ge_b() (
  set +x

  yy_a="$(echo "$1" | cut -d'.' -f1)"
  yy_b="$(echo "$2" | cut -d'.' -f1)"
  if [ "$yy_a" -lt "$yy_b" ]; then
    return 1
  fi
  if [ "$yy_a" -gt "$yy_b" ]; then
    return 0
  fi
  mm_a="$(echo "$1" | cut -d'.' -f2)"
  mm_b="$(echo "$2" | cut -d'.' -f2)"
  if [ "${mm_a}" -lt "${mm_b}" ]; then
    return 1
  fi

  return 0
)

join_by() {
  local d=$1
  shift
  printf '%s\n' "$@" | paste -sd "$d"
}

get_cpu_core_number() {
  local processors=$(grep -c ^processor /proc/cpuinfo)
  echo $processors # echo can run num > 255
}

get_buckets_num() {
  local bucket_port_str=$(yq eval '.buckets[].port' $config_path | xargs)
  read -a ports_arr <<<"$bucket_port_str"
  echo ${#ports_arr[@]}
}

is_cfgfile_valid() {
  log_info "Set Your Config Path"
  read -t 30 -p "Press enter or wait 30s for default, or customize your config path: " config_path_custom
  if [ -n "$config_path_custom" ]; then
    config_path=$config_path_custom/config.yaml
  fi

  log_info "Read Configuration from Path: $config_path"

  if [ ! -f "$config_path" ]; then
    log_err "Error: ConfigFileNotFoundException, config.yaml not found in $config_path"
    exit 1
  fi

  yq '.' "$config_path" >/dev/null
  if [ $? -ne 0 ]; then
    log_err "Config File: config.yaml Parse Error, Please Check Your File Format"
    exit 1
  fi
}

is_kernel_satisfied() {
  local kernal_version=$(uname -r | cut -d . -f 1,2)
  log_info "Linux kernel version: $kernal_version"
  if ! is_ver_a_ge_b $kernal_version $kernel_ver_req; then
    log_err "The kernel version must be greater than 5.11, current version is $kernal_version. Please upgrade the kernel first."
    exit 1
  fi
}

is_base_hardware_satisfied() {
  local cur_processors=$(get_cur_processorss)
  local cur_ram=$(get_cur_ram)
  if [ "$cur_processors" -lt $cpu_req ]; then
    log_err "Cpu processor must greater than $cpu_req"
    exit 1
  elif [ "$cur_ram" -lt $ram_req ]; then
    log_err "RAM must greater than $ram_req GB"
    exit 1
  else
    log_info "$cur_processors CPU processors and $cur_ram GB of RAM In Server"
  fi
  return $?
}

is_processors_satisfied() {
  local bucket_num=$(get_buckets_num)
  local basic_buckets_cpu_need=$(($bucket_num * $each_bucket_cpu_req))
  local basic_rpcnode_cpu_need=$([ $skip_chain == "false" ] && echo "$each_rpcnode_cpu_req" || echo "0")
  local buckets_cpu_req_in_cfg=$(yq eval '.buckets[].UseCpu' $config_path | xargs | awk '{ sum = 0; for (i = 1; i <= NF; i++) sum += $i; print sum }')
  local basic_cpu_req=$([ $skip_chain == "false" ] && echo $(($basic_buckets_cpu_need + $basic_rpcnode_cpu_need)) || echo $basic_buckets_cpu_need)
  local actual_cpu_req=$([ $skip_chain == "false" ] && echo $(($buckets_cpu_req_in_cfg + $basic_rpcnode_cpu_need)) || echo $basic_buckets_cpu_need)

  local cur_processors=$(get_cur_processorss)

  if [ $basic_cpu_req -gt $cur_processors ]; then
    log_info "Each bucket request $each_bucket_cpu_req processors at least, each chain request $each_rpcnode_cpu_req processors at least"
    log_info "Basic installation request: $basic_cpu_req processors in total, but $cur_processors in current"
    log_err "Please modify configuration in $config_path and execute: cess-multibucket-admin config generate again"
    exit 1
  fi

  if [ $actual_cpu_req -gt $cur_processors ]; then
    log_info "Totally request: $actual_cpu_req processors in $config_path, but $cur_processors in current"
    log_err "Please modify configuration in $config_path and execute: cess-multibucket-admin config generate again"
    exit 1
  fi
}

is_ram_satisfied() {
  local bucket_num=$(get_buckets_num)

  local base_buckets_ram_need=$(($bucket_num * $each_bucket_ram_req))

  local base_rpcnode_ram_need=$([ $skip_chain == "false" ] && echo "$each_rpcnode_ram_req" || echo "0")

  local total_ram_req=$([ $skip_chain == "false" ] && echo $(($base_buckets_ram_need + $base_rpcnode_ram_need)) || echo $base_buckets_ram_need)

  local cur_ram=$(get_cur_ram)

  if [ $total_ram_req -gt $cur_ram ]; then
    log_err "Each bucket request $each_bucket_ram_req GB ram at least, each chain request $each_rpcnode_ram_req GB ram at least"
    log_err "Installation request: $total_ram_req GB ram in total, but $cur_ram in current"
    exit 1
  fi
}

is_disk_satisfied() {
  local diskPath=$(yq eval '(.buckets | unique_by(.diskPath)) | .[].diskPath' $config_path)
  local useSpace=$(yq eval '(.buckets[].UseSpace' $config_path)

  readarray -t diskPath_arr <<<"$diskPath"
  readarray -t useSpace_arr <<<"$useSpace"

  local total_avail=0
  local total_req=0

  for i in "${!diskPath_arr[@]}"; do
    local path_i_availspace=$(df -h "${diskPath_arr[$i]}" | awk '{print $2}' | tail -n 1 | awk 'BEGIN{FS="G|T"} {print $1}')
    if df -h "${diskPath_arr[$i]}" | awk '{print $4}' | tail -n 1 | grep -i "t" >/dev/null; then
      path_i_availspace=$(($path_i_availspace * 1024))
    fi
    total_avail=$((total_avail + path_i_availspace))
  done

  for i in "${!useSpace_arr[@]}"; do
    total_req=$(($total_req + ${useSpace_arr[$i]}))
  done

  if [ $total_req -gt $total_avail ]; then
    log_info "Only $total_avail GB available in $(echo "$diskPath" | tr "\n" " "), but set $total_req GB UseSpace in total in: $config_path"
    log_info "This configuration can make your storage nodes be frozen after running"
    log_info "Please modify configuration in $config_path and execute: cess-multibucket-admin config generate again"
    exit 1
  fi
}

is_ports_valid() {
  local ports=$(yq eval '.buckets[].port' $config_path | xargs)
  for port in $ports; do
    check_port $port
  done
}

is_workpaths_valid() {
  local disk_path=$(yq eval '.buckets[].diskPath' $config_path | xargs)
  local each_space=$(yq eval '.buckets[].UseSpace' $config_path | xargs)
  read -a path_arr <<<"$disk_path"
  read -a space_arr <<<"$each_space"
  for i in "${!path_arr[@]}"; do
    if [ ! -d "${path_arr[$i]}" ]; then
      log_err "Path do not exist: ${path_arr[$i]}"
      exit 1
    fi
    local cur_avail=$(df -h ${path_arr[$i]} | awk '{print $2}' | tail -n 1 | awk 'BEGIN{FS="G|T"} {print $1}')
    if df -h ${path_arr[$i]} | awk '{print $2}' | tail -n 1 | grep -i "t" >/dev/null; then
      cur_avail=$((cur_avail * 1024))
    fi
    if [ $cur_avail -lt ${space_arr[$i]} ]; then
      log_info "This configuration can make your storage nodes be frozen after running"
      log_err "Only $cur_avail GB available in ${path_arr[$i]}, but set UseSpace: ${space_arr[$i]} GB in: $config_path"
      exit 1
    fi
  done
}

# https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
add_docker_ubuntu_repo() {
  # Add Docker's official GPG key:
  sudo apt-get update
  sudo apt-get install ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Add the repository to Apt sources:
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
}

# https://docs.docker.com/engine/install/centos/#set-up-the-repository
add_docker_centos_repo() {
  sudo yum install -y yum-utils
  sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
}

get_cur_ram() {
  local cur_ram=0
  local ram_unit=$(sudo dmidecode -t memory | grep -v "No Module Installed" | grep -i size | awk '{print $3}' | egrep "GB|MB" | head -n 1)
  if [ "$ram_unit" == "MB" ]; then
    for num in $(sudo dmidecode -t memory | grep -v "No Module Installed" | grep -i size | awk '{print $2}'); do cur_ram=$((cur_ram + $num / 1024)); done
  elif [ "$ram_unit" == "GB" ]; then
    for num in $(sudo dmidecode -t memory | grep -v "No Module Installed" | grep -i size | awk '{print $2}'); do cur_ram=$((cur_ram + $num)); done
  else
    log_err "RAM unit can not be recognized"
  fi
  echo $cur_ram # echo can return num > 255
}

get_cur_processorss() {
  local processors=$(grep -c ^processor /proc/cpuinfo)
  echo $processors # echo can return num > 255
}

mk_workdir() {
  local disk_paths=$(yq eval '.buckets[].diskPath' $config_path | xargs)
  for disk_path in $disk_paths; do
    sudo mkdir -p "$disk_path/bucket" "$disk_path/storage"
  done
}

split_buckets_config() {
  local buckets_num=$(get_buckets_num)
  for ((i = 0; i < buckets_num; i++)); do
    local get_bucket_config_by_index="yq eval '.[$i]' $build_dir/buckets/config.yaml"
    local get_disk_path_by_index="yq eval '.buckets[$i].diskPath' $config_path"
    local each_path="$(eval "$get_disk_path_by_index")/bucket/config.yaml"
    eval $get_bucket_config_by_index >$each_path
  done
}

is_uint() { case $1 in '' | *[!0-9]*) return 1 ;; esac }
is_int() { case ${1#[-+]} in '' | *[!0-9]*) return 1 ;; esac }
is_unum() { case $1 in '' | . | *[!0-9.]* | *.*.*) return 1 ;; esac }
is_num() { case ${1#[-+]} in '' | . | *[!0-9.]* | *.*.*) return 1 ;; esac }
