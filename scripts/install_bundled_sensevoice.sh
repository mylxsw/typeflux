#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <target-model-folder> [runtime-root-folder]" >&2
  exit 1
fi

TARGET_MODEL_FOLDER="$1"
RUNTIME_ROOT_FOLDER="${2:-}"
RUNTIME_ROOT_NAME="sherpa-onnx-v1.12.35-osx-universal2-shared-no-tts"
MODEL_ROOT="sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
MODEL_URL="https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx"
TOKENS_URL="https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt"

MAX_RETRIES=3
RETRY_DELAY_SECONDS=5

download_file() {
  local source_url="$1"
  local destination_path="$2"
  local attempt=1

  while true; do
    if curl --fail --location --silent --show-error "$source_url" --output "$destination_path"; then
      return 0
    fi

    if [[ $attempt -ge $MAX_RETRIES ]]; then
      echo "Error: failed to download ${source_url} after ${MAX_RETRIES} attempts" >&2
      return 1
    fi

    echo "Warning: download attempt ${attempt}/${MAX_RETRIES} failed for ${source_url}, retrying in ${RETRY_DELAY_SECONDS}s..." >&2
    sleep "$RETRY_DELAY_SECONDS"
    attempt=$((attempt + 1))
  done
}

echo "Bundling SenseVoice model assets into ${TARGET_MODEL_FOLDER}..."
echo "Max download retries: ${MAX_RETRIES}"

rm -rf "$TARGET_MODEL_FOLDER"
mkdir -p "${TARGET_MODEL_FOLDER}/${MODEL_ROOT}"

CACHE_DIR="${HOME}/.cache/typeflux-bundled-models"
mkdir -p "$CACHE_DIR"

cached_model_file="${CACHE_DIR}/sensevoice-model.int8.onnx"
if [[ ! -f "$cached_model_file" ]]; then
  download_file "$MODEL_URL" "$cached_model_file"
fi
cp "$cached_model_file" "${TARGET_MODEL_FOLDER}/${MODEL_ROOT}/model.int8.onnx"

cached_tokens_file="${CACHE_DIR}/sensevoice-tokens.txt"
if [[ ! -f "$cached_tokens_file" ]]; then
  download_file "$TOKENS_URL" "$cached_tokens_file"
fi
cp "$cached_tokens_file" "${TARGET_MODEL_FOLDER}/${MODEL_ROOT}/tokens.txt"

if [[ -n "$RUNTIME_ROOT_FOLDER" ]]; then
  test -d "$RUNTIME_ROOT_FOLDER" || {
    echo "Error: runtime root does not exist: $RUNTIME_ROOT_FOLDER" >&2
    exit 1
  }
  test "$(basename "$RUNTIME_ROOT_FOLDER")" = "$RUNTIME_ROOT_NAME" || {
    echo "Error: runtime root must end with ${RUNTIME_ROOT_NAME}" >&2
    exit 1
  }

  relative_runtime_root="$(
    perl -MFile::Spec -e 'print File::Spec->abs2rel($ARGV[0], $ARGV[1])' \
      "$RUNTIME_ROOT_FOLDER" "$TARGET_MODEL_FOLDER"
  )"
  ln -s "$relative_runtime_root" "${TARGET_MODEL_FOLDER}/${RUNTIME_ROOT_NAME}"
fi

test -f "${TARGET_MODEL_FOLDER}/${MODEL_ROOT}/model.int8.onnx" || {
  echo "Error: model.int8.onnx not found" >&2
  exit 1
}
test -f "${TARGET_MODEL_FOLDER}/${MODEL_ROOT}/tokens.txt" || {
  echo "Error: tokens.txt not found" >&2
  exit 1
}

echo "Bundled SenseVoice model assets are ready at ${TARGET_MODEL_FOLDER}"
