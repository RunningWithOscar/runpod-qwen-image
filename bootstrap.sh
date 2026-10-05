#!/bin/sh
set -eu
export LD_LIBRARY_PATH="/app:${LD_LIBRARY_PATH:-}"
model_dir=${MODEL_DIR:-/models}
mkdir -p "$model_dir"
cd "$model_dir"
if [ -f "$model_dir/preloaded.sha256" ]; then
    sha256sum -c "$model_dir/preloaded.sha256"
    echo "$SOURCE_MODEL_FILE: OK"
else
if [ ! -f "$MODEL_FILE" ] || ! printf '%s  %s\n' "$MODEL_SHA256" "$MODEL_FILE" | sha256sum -c - >/dev/null 2>&1; then
    echo 'Downloading the pinned Q4_K_M model.'
    rm -f "$MODEL_FILE"
    model_bytes=${MODEL_BYTES:?MODEL_BYTES must be set}
    chunk_bytes=$(((model_bytes + 7) / 8))
    download_pids=''
    trap 'kill $download_pids 2>/dev/null || true' INT TERM EXIT
    chunk_index=0
    while [ "$chunk_index" -lt 8 ]; do
        first=$((chunk_index * chunk_bytes))
        last=$((first + chunk_bytes - 1))
        [ "$last" -lt "$model_bytes" ] || last=$((model_bytes - 1))
        length=$((last - first + 1))
        part="$MODEL_FILE.part.$chunk_index"
        (
            if [ ! -f "$part" ] || [ "$(wc -c < "$part")" -ne "$length" ]; then
                # A server ignoring Range would return the full model: reject it
                # before filling the disk with eight complete copies.
                curl --fail --location --silent --show-error --retry 2 \
                    --connect-timeout 30 --speed-limit 1048576 --speed-time 60 --max-time 1200 \
                    --range "$first-$last" --max-filesize "$length" --output "$part" "$MODEL_URL"
            fi
            [ "$(wc -c < "$part")" -eq "$length" ]
        ) &
        download_pids="$download_pids $!"
        chunk_index=$((chunk_index + 1))
    done
    while :; do
        active=0
        for download_pid in $download_pids; do
            if kill -0 "$download_pid" 2>/dev/null; then active=1; fi
        done
        downloaded=0
        for part in "$MODEL_FILE".part.*; do
            [ -f "$part" ] || continue
            downloaded=$((downloaded + $(wc -c < "$part")))
        done
        echo "Downloaded $downloaded bytes of $model_bytes."
        [ "$active" -eq 1 ] || break
        sleep 10
    done
    for download_pid in $download_pids; do wait "$download_pid"; done
    trap - INT TERM EXIT
    # Append and delete each part in order; disk overhead is one chunk, not a
    # second complete model copy. Everything stays on the temporary disk.
    chunk_index=0
    while [ "$chunk_index" -lt 8 ]; do
        part="$MODEL_FILE.part.$chunk_index"
        cat "$part" >> "$MODEL_FILE"
        rm "$part"
        chunk_index=$((chunk_index + 1))
    done
    echo 'Checking the model SHA256.'
    printf '%s  %s\n' "$MODEL_SHA256" "$MODEL_FILE" | sha256sum -c -
fi
echo 'Loading the model onto the GPU.'
fi
# Explicit full offload is enforced by server.sh.
if [ -n "${SERVER_SCRIPT:-}" ]; then printf '%s' "$SERVER_SCRIPT" > /tmp/server.sh; fi
server_script=${SERVER_PATH:-/tmp/server.sh}
if [ "${BENCHMARK:-0}" = 1 ]; then
    if ! command -v python3 >/dev/null; then
        apt-get update -qq && apt-get install -y -qq --no-install-recommends python3
    fi
    if [ -n "${BENCHMARK_SCRIPT:-}" ]; then printf '%s' "$BENCHMARK_SCRIPT" > /tmp/benchmark.py; fi
    SERVER_PATH="$server_script" python3 "${BENCHMARK_PATH:-/tmp/benchmark.py}"
    . "$model_dir/speculation.env"
    export SPEC_DRAFT_N_MAX
fi
printf '%s  %s\n' "$MODEL_SHA256" "${SOURCE_MODEL_FILE:-$MODEL_FILE}" | sed 's/^[^ ]*  /SOURCE_VERIFIED /'
echo "${SOURCE_MODEL_FILE:-$MODEL_FILE}: OK"
exec sh "$server_script"
