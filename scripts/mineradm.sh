#!/bin/bash

case "$1" in
miners)
  case "$2" in
  increase)
    case "$3" in
    staking | space)
      echo "Executing miners increase $3"
      ;;
    *)
      echo "Invalid increase command"
      ;;
    esac
    ;;
  withdraw | stat | reward | claim | update)
    echo "Executing miners $2"
    ;;
  *)
    echo "Invalid miners command"
    ;;
  esac
  ;;
tools)
  case "$2" in
  space-info | no-watch | set)
    echo "Executing tools $2"
    ;;
  *)
    echo "Invalid tools command"
    ;;
  esac
  ;;
stop | restart | down | status | pullimg | purge | config | profile | help)
  echo "Executing $1"
  ;;
*)
  echo "Invalid command"
  ;;
esac