#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="${ROOT_DIR}/app/Info.plist"

update_plist_value() {
  local key="$1"
  local value="$2"
  local temp_file
  temp_file="$(mktemp "${TMPDIR:-/tmp}/typeflux-info-plist.XXXXXX")"

  if ! /usr/bin/perl -0pe '
    BEGIN {
      ($key, $value) = splice @ARGV, 0, 2;
      $changed = 0;
    }
    $changed = s{(<key>\Q$key\E</key>\s*<string>)[^<]*(</string>)}{$1$value$2}s;
    END {
      exit($changed ? 0 : 2);
    }
  ' "$key" "$value" "$INFO_PLIST" >"$temp_file"; then
    rm -f "$temp_file"
    echo "Error: key not found in Info.plist: $key" >&2
    exit 1
  fi

  mv "$temp_file" "$INFO_PLIST"
}

usage() {
  echo "Usage: $0 <version> [build]"
  echo
  echo "Examples:"
  echo "  $0 0.1.0"
  echo "  $0 0.1.0 42"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 1
fi

VERSION="$1"
BUILD="${2:-$VERSION}"

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "Error: version must use numeric major.minor or major.minor.patch format." >&2
  exit 1
fi

if [[ ! "$BUILD" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "Error: build must be a numeric value with up to three dot-separated components." >&2
  exit 1
fi

if [[ ! -f "$INFO_PLIST" ]]; then
  echo "Error: Info.plist not found at $INFO_PLIST" >&2
  exit 1
fi

update_plist_value "CFBundleShortVersionString" "$VERSION"
update_plist_value "CFBundleVersion" "$BUILD"

plutil -lint "$INFO_PLIST" >/dev/null

echo "Updated app/Info.plist"
echo "CFBundleShortVersionString=$VERSION"
echo "CFBundleVersion=$BUILD"
