#!/bin/bash

source /opt/cess/mineradm/scripts/utils.sh

mode=$(yq eval ".node.mode" $config_path)
if [ x"$mode" != x"miners" ]; then
  log_info "The mode in $config_path is invalid, set value to: miners"
  yq -i eval ".node.mode=\"miners\"" $config_path
  mode=$(yq eval ".node.mode" $config_path)
fi

config_help() {
  cat <<EOF
cess config usage:
    -h | help                    show help information
    -s | show                    show configurations
    -g | generate                generate docker-compose.yaml by config.yaml
EOF
}

config_show() {
  local keys=('"node"' '"miners"')
  local use_external_chain=$(yq eval ".node.externalChain //0" $config_path)
  if [[ $use_external_chain -eq 0 ]]; then
    keys+=('"chain"')
  fi
  local ss=$(join_by , ${keys[@]})
  yq eval ". |= pick([$ss])" $config_path -o json
}

# generate each miner config.yaml and docker-compose.yaml
config_generate() {
  is_cfgfile_valid

  # if user just wanna upgrade mineradm and do not want to stop miners, skip check port
  if ! docker ps --format '{{.Image}}' | grep -q 'cesslab/cess-miner'; then
    is_ports_valid
  fi

  is_workpaths_valid

  log_info "Start generate miners configurations and docker-compose file"

  rm -rf $build_dir
  mkdir -p $build_dir/.tmp

  local cidfile=$(mktemp)
  rm $cidfile

  pullimg

  local cg_image="cesslab/config-gen:$profile"
  docker run --cidfile $cidfile -v $base_dir/etc:/opt/app/etc -v $build_dir/.tmp:/opt/app/.tmp -v $config_path:/opt/app/config.yaml $cg_image

  local res="$?"
  local cid=$(cat $cidfile)
  docker rm $cid

  if [ "$res" -ne "0" ]; then
    log_err "Failed to generate configurations, please check your config.yaml"
    exit 1
  fi

  mk_workdir

  cp -r $build_dir/.tmp/* $build_dir/

  # change '["CMD", "nc", "-zv", "127.0.0.1", "15001"]'   to   ["CMD", "nc", "-zv", "127.0.0.1", "15001"] in docker-compose.yaml
  yq eval '.' $build_dir/docker-compose.yaml | grep -n "test: " | awk '{print $1}' | cut -d':' -f1 | xargs -I {} sed -i "{}s/'//;{}s/\(.*\)'/\1/" $build_dir/docker-compose.yaml

  rm -rf $build_dir/.tmp
  local base_mode_path=/opt/cess/data/$mode

  if [[ "$mode" == "miners" ]]; then
    if [ ! -d $base_mode_path/miners/ ]; then
      log_info "mkdir : $base_mode_path/miners/"
      mkdir -p $base_mode_path/miners/
    fi
    cp $build_dir/miners/* $base_mode_path/miners/

    if [ ! -d $base_mode_path/chain/ ]; then
      log_info "mkdir : $base_mode_path/chain/"
      mkdir -p $base_mode_path/chain/
    fi
    cp $build_dir/chain/* $base_mode_path/chain/
  else
    log_err "Invalid mode value: $mode"
    exit 1
  fi
  chown -R root:root $build_dir
  #chmod -R 0600 $build_dir
  #chmod 0600 $config_path

  split_miners_config

  log_success "docker-compose.yaml generated at: $build_dir"
}

config() {
  case "$1" in
  -s | show)
    config_show
    ;;
  -g | generate)
    shift
    config_generate
    ;;
  *)
    config_help
    ;;
  esac
}
