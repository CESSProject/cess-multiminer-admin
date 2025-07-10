#!/usr/bin/env bash

_mineradm_completions() {
  local cur prev prev2 opts
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"
  prev2="${COMP_WORDS[COMP_CWORD - 2]}"

  if [[ ${COMP_CWORD} -eq 1 ]]; then
    opts="miners cacher stop restart down status pullimg purge config profile tools version increase help"
  else
    case "$prev" in
    miners)
      opts="increase withdraw stat reward claim update"
      ;;
    cacher)
      opts="restart stop remove"
      ;;
    tools)
      opts="space-info no-watch set"
      ;;
    increase)
      opts="staking space"
      ;;
    config)
      opts="show generate help"
      ;;
    esac
  fi

  COMPREPLY=($(compgen -W "${opts}" -- ${cur}))
  return 0
}

complete -F _mineradm_completions mineradm
