# Select the identity before building. Never fall back to the system-wide keychain search.
select_signing_identity() {
  local mode="$1" requested="$2" explicit="$3"
  local -a chains
  local chain pattern line hash name
  local login="$HOME/Library/Keychains/login.keychain-db"
  if [[ -n "$explicit" ]]; then
    chains=("$explicit")
  elif [[ "$mode" == release ]]; then
    chains=("$HOME/Library/Keychains/typeflux-release.keychain-db" "$login")
  else
    chains=("$login" "$HOME/Library/Keychains/typeflux-dev.keychain-db")
  fi
  pattern='^[[:space:]]*[0-9]+\) ([0-9A-Fa-f]{40}) "(.*)"$'
  for chain in "${chains[@]}"; do
    [[ -f "$chain" ]] || continue
    while IFS= read -r line; do
      [[ "$line" =~ $pattern ]] || continue
      hash="${BASH_REMATCH[1]}"
      name="${BASH_REMATCH[2]}"
      if [[ -n "$requested" ]]; then
        [[ "$requested" == "$name" || "$requested" == "$hash" ]] || continue
      elif [[ "$mode" == dev ]]; then
        [[ "$name" == "Apple Development:"* || "$name" == "Typeflux Dev" ]] || continue
      fi
      if [[ "$mode" == release && "$name" != "Developer ID Application:"* ]]; then
        continue
      fi
      signing_keychain="$chain"
      signing_name="$name"
      signing_hash="$hash"
      return 0
    done < <(security find-identity -v -p codesigning "$chain")
  done
  if [[ "$mode" == release ]]; then
    echo "No matching Developer ID Application identity in the selected user keychain. Use the Release workflow or set TYPEFLUX_CODESIGN_KEYCHAIN to a configured signing keychain." >&2
  else
    echo "No matching development identity. Run scripts/setup_dev_cert.sh or set TYPEFLUX_DEV_CODESIGN_KEYCHAIN to your signing keychain." >&2
  fi
  return 1
}

# A private pointer file opts local builds into the same credentials as CI.
# The re-executed script and nested packaging steps share one temporary keychain.
use_local_release_credentials() {
  [[ -z "${TYPEFLUX_CODESIGN_KEYCHAIN:-}" ]] || return 0
  local pointer="${XDG_CONFIG_HOME:-$HOME/.config}/typeflux/release-credentials-path"
  local credentials="${TYPEFLUX_RELEASE_CREDENTIALS_FILE:-}"
  if [[ -z "$credentials" && -f "$pointer" ]]; then
    credentials="$(cat "$pointer")"
  fi
  [[ -n "$credentials" ]] || return 0
  exec python3 "$ROOT_DIR/scripts/with_release_keychain.py" "$credentials" "$@"
}
