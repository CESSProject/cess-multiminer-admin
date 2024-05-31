#!/bin/bash

source /opt/cess/mineradm/scripts/utils.sh
source /opt/cess/mineradm/scripts/config.sh

tools_help() {
  cat <<EOF
cess tools usage:
    rotate-keys                                            generate session key of chain node
    space-info                                             show information about miner disk
    no-watch                                               do not auto-update container: {autoheal/chain/miner1/miner2...}
    set
      option:
        use-space                                          change miner's use-space to n GiB
    help                                                   show help information
EOF
}

space_info() {
  echo "Filesystem       Size  Used Avail Use% Mounted on"
  local disk_path=$(yq eval ".miners[].diskPath" $config_path | xargs)
  read -a disk_path_arr <<<"$disk_path"
  for disk_path in "${disk_path_arr[@]}"; do
    df -h $disk_path | tail -n+2
  done
}

set() {
  local miner_names=$(yq eval '.services | keys | map(select(. == "miner*" )) | join(" ")' $compose_yaml)
  local volumes=$(yq eval '.services | to_entries | map(select(.key | test("^miner.*"))) | from_entries | .[] | .volumes' $compose_yaml | xargs | sed "s/['\"]//g" | sed "s/- /-v /g" | xargs -n 4 echo)
  readarray -t volumes_array <<<"$volumes" # read array split with /n
  read -a names_array <<<"$miner_names"    # read array split with " "
  local miner_image="cesslab/cess-miner:$profile"
  local -r cfg_arg="-c /opt/miner/config.yaml"

  case "$1" in
  use-space)
    is_cfgfile_valid
    # mineradm tools set use-space 500  (unit: GiB)
    if [ $# -eq 2 ]; then
      log_info "WARNING: This operation will set all of miners UseSpace to $2 GiB and restart services"
      printf "Press \033[0;33mY\033[0m to continue: "
      local y=""
      read y
      if [ x"$y" != x"Y" ]; then
        exit 1
      fi
      is_num $2
      for i in "${!volumes_array[@]}"; do
        local tmp_file=$(mktemp)
        local cmd="docker run --rm --network=host ${volumes_array[$i]} $miner_image"
        if $cmd "stat" $cfg_arg >$tmp_file; then
          # transfer current_used_num to unit: GiB
          local current_used_num=$(get_current_used_space $tmp_file)
          local now_use_space_config=$(yq eval ".miners[$i].UseSpace" $config_path)
          local now_disk_path_config=$(yq eval ".miners[$i].diskPath" $config_path)
          if [ $2 -gt $now_use_space_config ]; then # increase UseSpace operation
            # get current disk total size
            local disk_size=$(get_disk_size $now_disk_path_config)
            if [ $2 -gt $disk_size ]; then # request bigger than actual disk size: insufficient disk space
              log_err "Current disk only $disk_size in total, but set $2 for UseSpace, ${names_array[$i]} increase UseSpace operation failed"
            else
              yq -i eval ".miners[$i].UseSpace=$2" $config_path
            fi
          else # decrease UseSpace operation
            # 88.88 > 8.88, return 1
            # 88.88 > 188.88, return 0
            result1=$(echo "$now_use_space_config > $current_used_num" | bc)
            result2=$(echo "$2 > $current_used_num" | bc)
            if [ "$result1" -eq 1 ] && [ "$result2" -eq 1 ]; then
              yq -i eval ".miners[$i].UseSpace=$2" $config_path
            else
              log_err "${names_array[$i]} use $current_used_num GB currently, change useSpace from $now_use_space_config to $2 failed"
            fi
          fi
        else
          log_err "Query miner stat failed, please check miner:${names_array[$i]} status"
        fi
        rm -f $tmp_file
      done
      backup_config
      config_generate
      mineradm down
      mineradm restart
    # mineradm tools set use-space miner1 500  (unit: GiB)
    elif [ $# -eq 3 ]; then
      is_match_regex "miner" $2
      is_num $3
      local index=99999
      for i in "${!names_array[@]}"; do
        if [ ${names_array[$i]} == $2 ]; then
          index=$i
          break
        fi
      done
      if [ $index -eq 99999 ]; then
        log_err "Can not find miner:$2"
        exit 1
      fi

      local tmp_file=$(mktemp)
      local cmd=$(gen_miner_cmd $2 $miner_image)

      if $cmd "stat" $cfg_arg >$tmp_file; then
        local current_used_num=$(get_current_used_space $tmp_file)
        local now_use_space_config=$(yq eval ".miners[$index].UseSpace" $config_path)
        local now_disk_path_config=$(yq eval ".miners[$index].diskPath" $config_path)
        if [ $3 -gt $now_use_space_config ]; then # increase operation
          # get current disk total size
          local disk_size=$(get_disk_size $now_disk_path_config)
          if [ $3 -gt $disk_size ]; then # request bigger than actual disk size: insufficient disk space
            log_err "Current disk only $disk_size in total, but set $3 for UseSpace"
            rm -f $cidfile
            exit 1
          else
            yq -i eval ".miners[$index].UseSpace=$3" $config_path
          fi
        else # decrease operation
          result1=$(echo "$now_use_space_config > $current_used_num" | bc)
          result2=$(echo "$3 > $current_used_num" | bc)
          if [ "$result1" -eq 1 ] && [ "$result2" -eq 1 ]; then
            yq -i eval ".miners[$index].UseSpace=$3" $config_path
          else
            log_err "$2 use $current_used_num GB currently, change useSpace from $now_use_space_config to $3 failed"
          fi
        fi
        backup_config
        config_generate
        mineradm down $2
        mineradm restart $2
      else
        log_err "Query miner stat failed, please check miner:$2 status"
      fi
      rm -f $cidfile
    else
      log_err "Parameters Error"
      tools_help
      exit 1
    fi
    ;;
  *)
    tools_help
    exit 0
    ;;
  esac
}

rotate_keys() {
  if check_docker_status chain; then
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
  local names=("$@")
  local quoted_names=()
  for idx in ${!names[*]}; do
    quoted_names+=(\""${names[$idx]}"\")
  done
  local ss=$(join_by , "${quoted_names[@]}")
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
  no-watchs)
    shift
    set_no_watch_containers "$@"
    ;;
  set)
    shift
    set "$@"
    ;;
  *)
    tools_help
    ;;
  esac
}
