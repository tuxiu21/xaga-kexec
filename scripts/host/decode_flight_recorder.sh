#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <pmsg-ramoops-file>" >&2
  exit 2
fi

input="$1"
[ -f "$input" ] || {
  echo "missing pmsg file: $input" >&2
  exit 2
}

LC_ALL=C strings -a -n 8 "$input" |
  sed -n 's/^.*\(XFR1 seq=.*\)$/\1/p' |
  awk '!seen[$0]++'
