#!/bin/zsh
# uuid: a random UUID. pwd [length]: a random password, 20 characters by default.
# Nothing is shown: the workflow copies what it prints and says so in the launcher.
if [[ "$TYPEFLUX_OPTION_KIND" == "password" ]]; then
  length="${1:-20}"
  if [[ ! "$length" == <8-128> ]]; then
    print -r -- '{"error": "Length must be a number from 8 to 128"}'
    exit 1
  fi
  LC_ALL=C tr -dc 'A-Za-z0-9!@#%^*_-' < /dev/urandom | head -c "$length"
  print
else
  uuidgen | tr '[:upper:]' '[:lower:]'
fi
