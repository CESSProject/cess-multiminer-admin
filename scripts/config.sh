#!/bin/bash

source /opt/cess/multibucket-admin/scripts/utils.sh

mode=$(yq eval ".node.mode" $config_path)
if [ $? -ne 0 ]; then
  log_err "the config file: $config_path may be invalid, please reconfig again"
  exit 1
fi

config_help() {
  cat <<EOF
cess config usage:
    -h | help                    show help information
    -s | show                    show configurations
    -g | generate                generate docker-compose.yaml by config.yaml
    -p | pull-image              download corresponding images after set config
EOF
}

config_show() {
  local keys=('"node"' '"buckets"')
  local use_external_chain=$(yq eval ".node.externalChain //0" $config_path)
  if [[ $use_external_chain -eq 0 ]]; then
    keys+=('"chain"')
  fi
  local ss=$(join_by , ${keys[@]})
  yq eval ". |= pick([$ss])" $config_path -o json
}

try_pull_image() {
  local img_name=$1
  local img_tag=$2

  local org_name="cesslab"
  if [ x"$region" == x"cn" ]; then
    org_name=$aliyun_address/$org_name
  fi
  if [ -z $img_tag ]; then
    img_tag="$profile"
  fi
  local img_id="$org_name/$img_name:$img_tag"
  log_info "download image: $img_id"
  docker pull $img_id
  if [ $? -ne 0 ]; then
    log_err "download image $img_id failed, try again later"
    exit 1
  fi
  return 0
}

pull_images_by_mode() {
  log_info "try pull images, node mode: $mode"
  if [ x"$mode" == x"multibucket" ]; then
    try_pull_image cess-chain
    try_pull_image cess-bucket
  else
    log_err "the node mode must be multibucket, please config again"
    return 1
  fi
  log_info "pull images finished"
  return 0
}



config_generate() {
  # generate each bucket config.yaml and docker-compose.yaml
  is_cfgfile_valid

  is_ports_valid

  is_workpaths_valid

  log_info "Start generate configurations and docker compose file"

  rm -rf $build_dir
  mkdir -p $build_dir/.tmp

  local cidfile=$(mktemp)
  rm $cidfile

  local cg_image="cesslab/config-gen:$profile"
  docker run --cidfile $cidfile -v $base_dir/etc:/opt/app/etc -v $build_dir/.tmp:/opt/app/.tmp -v $config_path:/opt/app/config.yaml $cg_image

  local res="$?"
  local cid=$(cat $cidfile)
  docker rm $cid

  if [ "$res" -ne "0" ]; then
    log_err "Failed to generate application configs, please check your config.yaml"
    exit 1
  fi

  cp -r $build_dir/.tmp/* $build_dir/
  rm -rf $build_dir/.tmp
  local base_mode_path=/opt/cess/$mode

  if [[ "$mode" == "multibucket" ]]; then
    if [ ! -d $base_mode_path/buckets/ ]; then
      log_info "mkdir : $base_mode_path/buckets/"
      mkdir -p $base_mode_path/buckets/
    fi
    cp $build_dir/buckets/* $base_mode_path/buckets/

    if [ ! -d $base_mode_path/rpcnode/ ]; then
      log_info "mkdir : $base_mode_path/rpcnode/"
      mkdir -p $base_mode_path/rpcnode/
    fi
    cp $build_dir/rpcnode/* $base_mode_path/rpcnode/
  else
    log_err "Invalid mode value: $mode"
    exit 1
  fi
  chown -R root:root $build_dir
  #chmod -R 0600 $build_dir
  #chmod 0600 $config_path

  split_buckets_config

  log_success "Configurations generated at: $build_dir"
}

config() {
  case "$1" in
    -s | show)
      config_show
      ;;
    -g | generate)
      shift
      config_generate $@
      ;;
    -p | pull-image)
      pull_images_by_mode
      ;;
    *)
      config_help
      ;;
  esac
}
