#!/bin/bash

source /opt/cess/mineradm/scripts/utils.sh

version() {
  printf "mineradm version: %s\n" "$mineradm_version"
  printf "Mode: %s\n" ${mode}
  printf "Profile: %s\n" ${profile}
  inner_docker_version

  if [[ -f $config_path ]]; then
    local ss=$(yq eval '.node.noWatchContainers //[] | join(", ")' $config_path)
    if [[ -n ${ss// /} ]]; then
      log_info "No auto upgrade service(s): $ss"
    fi
  fi
}

inner_docker_version() {
  echo "----------------------------------------------------------------"
  printf "Docker images:\n"
  printf "%-20s %-30s %-20s\n" "Image" "Version" "Image ID"
  show_version "config-gen" "cesslab/config-gen" "version"
  show_version "chain" "cesslab/cess-chain" "--version"
  show_version "miner" "cesslab/cess-miner" "version"
}

show_version() {
  local prog_name=$1
  local image_name=$2
  local image_tag=$profile
  local version_cmd=$3
  local extra_docker_opts=$4
  local image_info=$(docker images | grep '^\b'$image_name'\b ' | grep $image_tag)
  local image_id=$(echo $image_info | awk '{printf $3}')
  local version=$(docker run --rm $extra_docker_opts $image_name:$image_tag $version_cmd)
  printf "%-20s %-30s %-20s\n" "$prog_name" "$version" "$image_id"
}
