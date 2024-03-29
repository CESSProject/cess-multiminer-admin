#!/bin/bash

source /opt/cess/multibucket-admin/scripts/utils.sh

tools_help() {
  cat <<EOF
cess tools usage:
    rotate-keys                                            generate session key of chain node
    space-info                                             show information about bucket disk
    help                                                   show help information
EOF
}

space_info() {
  if [ x"$mode" != x"multibucket" ]; then
    log_info "Only on multibucket mode"
    exit 1
  fi
  echo "Filesystem       Size  Used Avail Use% Mounted on"
  local disk_path=$(yq eval ".buckets[].diskPath" $config_path | xargs)
  read -a disk_path_arr <<<"$disk_path"
  for disk_path in "${disk_path_arr[@]}"; do
    df -h $disk_path | tail -n+2
  done
}

rotate_keys() {
  check_docker_status chain
  if [ $? -ne 0 ]; then
    log_info "Service chain is not started or exited now"
    return 0
  fi
  local res=$(docker exec chain curl -H 'Content-Type: application/json' -d '{"id":1, "jsonrpc":"2.0", "method": "author_rotateKeys", "params":[]}' http://localhost:9944 2>/dev/null)
  session_key=$(echo $res | jq .result)
  if [ x"$session_key" = x"" ]; then
    log_err "Generate session key failed"
    return 1
  fi
  echo $session_key
}

set_no_watch_containers() {
  local names=($@)
  local quoted_names=()
  for ix in ${!names[*]}; do
    quoted_names+=(\"${names[$ix]}\")
  done
  local ss=$(join_by , ${quoted_names[@]})
  yq -i eval ".node.noWatchContainers=[$ss]" $config_path
}

tools() {
  case "$1" in
    rotate-keys)
      rotate_keys
      ;;
    -s | space-info)
      space_info
      ;;
    no_watchs)
      shift
      set_no_watch_containers $@
      ;;
    *)
      tools_help
      ;;
  esac
}
