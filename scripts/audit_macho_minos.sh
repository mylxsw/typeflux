#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 3 ]]; then
  echo "Usage: $0 <app-bundle-or-folder> [max-macos-minos] [required-arch]" >&2
  exit 1
fi

SCAN_ROOT="$1"
MAX_MACOS_MINOS="${2:-${TYPEFLUX_MAX_MACHO_MINOS:-13.4}}"
REQUIRED_ARCH="${3:-${TYPEFLUX_REQUIRED_MACHO_ARCH:-}}"

if [[ ! -d "$SCAN_ROOT" ]]; then
  echo "Error: scan root does not exist: $SCAN_ROOT" >&2
  exit 1
fi

if ! command -v vtool >/dev/null 2>&1 && ! command -v otool >/dev/null 2>&1; then
  echo "Error: vtool or otool is required to audit Mach-O minimum OS versions" >&2
  exit 1
fi

if [[ -n "$REQUIRED_ARCH" ]] && ! command -v lipo >/dev/null 2>&1; then
  echo "Error: lipo is required to audit Mach-O architecture slices" >&2
  exit 1
fi

case "$REQUIRED_ARCH" in
  ""|native|arm64|x86_64|universal)
    ;;
  *)
    echo "Error: unsupported required Mach-O architecture: ${REQUIRED_ARCH}" >&2
    exit 1
    ;;
esac

version_gt() {
  local lhs="$1"
  local rhs="$2"
  local lhs_major lhs_minor lhs_patch rhs_major rhs_minor rhs_patch

  IFS=. read -r lhs_major lhs_minor lhs_patch <<<"$lhs"
  IFS=. read -r rhs_major rhs_minor rhs_patch <<<"$rhs"
  lhs_minor="${lhs_minor:-0}"
  lhs_patch="${lhs_patch:-0}"
  rhs_minor="${rhs_minor:-0}"
  rhs_patch="${rhs_patch:-0}"

  if (( lhs_major != rhs_major )); then
    (( lhs_major > rhs_major ))
    return
  fi
  if (( lhs_minor != rhs_minor )); then
    (( lhs_minor > rhs_minor ))
    return
  fi
  (( lhs_patch > rhs_patch ))
}

minos_versions_for_file() {
  local file_path="$1"
  local versions=""

  if command -v vtool >/dev/null 2>&1; then
    versions="$(
      vtool -show-build "$file_path" 2>/dev/null \
        | awk '/^[[:space:]]*minos[[:space:]]/ { print $2 }' \
        || true
    )"
  fi

  if [[ -z "$versions" ]] && command -v otool >/dev/null 2>&1; then
    versions="$(
      otool -l "$file_path" 2>/dev/null \
        | awk '
          /^[[:space:]]*cmd LC_BUILD_VERSION/ { in_build = 1; next }
          in_build && /^[[:space:]]*minos[[:space:]]/ { print $2; in_build = 0; next }
          /^[[:space:]]*cmd LC_VERSION_MIN_MACOSX/ { in_version_min = 1; next }
          in_version_min && /^[[:space:]]*version[[:space:]]/ { print $2; in_version_min = 0; next }
        ' \
        || true
    )"
  fi

  printf '%s\n' "$versions" | sed '/^$/d'
}

file_has_required_architecture() {
  local file_path="$1"
  local required_arch="${2:-$REQUIRED_ARCH}"
  local archs

  [[ -z "$required_arch" || "$required_arch" == "native" ]] && return 0

  archs="$(lipo -archs "$file_path" 2>/dev/null || true)"
  case "$required_arch" in
    arm64|x86_64)
      [[ " ${archs} " == *" ${required_arch} "* ]]
      ;;
    universal)
      [[ " ${archs} " == *" arm64 "* && " ${archs} " == *" x86_64 "* ]]
      ;;
  esac
}

echo "Auditing Mach-O minos under ${SCAN_ROOT}"
echo "Maximum allowed macOS minos: ${MAX_MACOS_MINOS}"
if [[ -n "$REQUIRED_ARCH" && "$REQUIRED_ARCH" != "native" ]]; then
  echo "Required Mach-O architecture: ${REQUIRED_ARCH}"
fi

minos_offenders=()
arch_offenders=()
scanned_count=0

while IFS= read -r -d '' candidate; do
  [[ -L "$candidate" ]] && continue
  if ! file "$candidate" 2>/dev/null | grep -q "Mach-O"; then
    continue
  fi

  scanned_count=$((scanned_count + 1))
  candidate_minos="$MAX_MACOS_MINOS"
  candidate_arch="$REQUIRED_ARCH"
  # This optional subprocess is gated to Apple Silicon/macOS 14 by SemanticFilePolicy.
  # Its deployment target must not raise the host app's macOS 13 minimum.
  if [[ "${candidate#$SCAN_ROOT/}" == "Contents/Resources/LocalRuntimes/SemanticSearch/TypefluxSemanticHelper" \
    && "$REQUIRED_ARCH" != "x86_64" ]]; then
    candidate_minos="14.0"
    candidate_arch="arm64"
  fi
  while IFS= read -r minos; do
    if version_gt "$minos" "$candidate_minos"; then
      minos_offenders+=("${candidate#$SCAN_ROOT/}: minos ${minos}")
    fi
  done < <(minos_versions_for_file "$candidate")

  if ! file_has_required_architecture "$candidate" "$candidate_arch"; then
    arch_offenders+=("${candidate#$SCAN_ROOT/}: missing ${candidate_arch}")
  fi
done < <(find "$SCAN_ROOT" -type f -print0)

if (( ${#minos_offenders[@]} > 0 )); then
  echo "Error: Mach-O files exceed allowed macOS minos ${MAX_MACOS_MINOS}:" >&2
  printf '  %s\n' "${minos_offenders[@]}" >&2
fi

if (( ${#arch_offenders[@]} > 0 )); then
  echo "Error: Mach-O files are missing required architecture ${REQUIRED_ARCH}:" >&2
  printf '  %s\n' "${arch_offenders[@]}" >&2
fi

if (( ${#minos_offenders[@]} > 0 || ${#arch_offenders[@]} > 0 )); then
  exit 1
fi

echo "Mach-O minos audit passed (${scanned_count} files scanned)"
