#!/bin/zsh
# ip [filter]: this Mac's network addresses as a list. Return copies the chosen one,
# Option-Return types it into the app the launcher came from.
emulate -L zsh

# A JSON string, with the characters JSON needs escaped.
json() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  print -rn -- "\"$s\""
}

# Device → hardware port ("en0" → "Wi-Fi"), from networksetup.
typeset -A ports
port=""
networksetup -listallhardwareports 2>/dev/null | while IFS= read -r line; do
  case $line in
    "Hardware Port: "*) port=${line#Hardware Port: } ;;
    "Device: "*) ports[${line#Device: }]=$port ;;
  esac
done

filter=${(L)1}
items=()

add() { # title subtitle symbol uid
  [[ -n $filter && ${(L)1} != *$filter* && ${(L)2} != *$filter* ]] && return
  items+=("{\"uid\": $(json $4), \"title\": $(json $1), \"subtitle\": $(json $2), \"arg\": $(json $1), \"icon\": $(json "sf:$3"), \"action\": \"copy\"}")
}

for device in $(ifconfig -l 2>/dev/null); do
  [[ $device == lo* ]] && continue
  name=${ports[$device]:-$device}
  case $name in
    Wi-Fi*) symbol=wifi ;;
    *Ethernet*|*LAN*|*Thunderbolt*) symbol=cable.connector ;;
    *) symbol=network ;;
  esac
  ifconfig $device 2>/dev/null | while read -r family address rest; do
    if [[ $family == inet ]]; then
      add $address "$name · $device · IPv4" $symbol "$device-$address"
    elif [[ $family == inet6 && $address != fe80:* && $rest != *temporary* && $rest != *deprecated* ]]; then
      add ${address%%\%*} "$name · $device · IPv6" $symbol "$device-$address"
    fi
  done
done

host=$(scutil --get LocalHostName 2>/dev/null)
[[ -n $host ]] && add "$host.local" "Local host name" desktopcomputer "hostname"

if (( ${#items} == 0 )); then
  items=("{\"title\": \"No network address\", \"subtitle\": \"This Mac is not connected to a network\", \"valid\": false}")
fi
print -r -- "{\"items\": [${(j:, :)items}]}"
