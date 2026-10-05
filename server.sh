#!/bin/sh
set -eu
export LD_LIBRARY_PATH="/app:${LD_LIBRARY_PATH:-}"
model_dir=${MODEL_DIR:-/models}
spec=${SPEC_DRAFT_N_MAX:-0}
set --
if [ "$spec" -gt 0 ]; then set -- --spec-type draft-mtp --spec-draft-n-max "$spec"; fi
# Explicit full offload and fixed context: fail on OOM instead of silently moving layers to CPU.
/app/llama-server --model "$model_dir/$MODEL_FILE" \
    --alias qwen3.8-27b-uncensored-q4_k_m \
    --host 0.0.0.0 --port 8080 --n-gpu-layers 999 --fit off \
    --override-tensor '.*=CUDA0' \
    --ctx-size 8192 --parallel 1 --batch-size 512 --ubatch-size 128 \
    --flash-attn on --cache-type-k q8_0 --cache-type-v q8_0 \
    --jinja --reasoning off --no-reasoning-preserve --log-verbosity 4 \
    --no-webui "$@" > "$model_dir/server.log" 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' INT TERM EXIT
# Copy startup evidence to RunPod logs, and reject partial GPU offload.
while kill -0 "$server_pid" 2>/dev/null; do
    if curl --silent --fail http://127.0.0.1:8080/health >/dev/null; then
        cat "$model_dir/server.log"
        if ! sed -n 's/.*offloaded \([0-9][0-9]*\)\/\([0-9][0-9]*\) layers to GPU.*/\1 \2/p' "$model_dir/server.log" | awk '$1 == $2 && $1 > 0 { ok=1 } END { exit !ok }'; then
            echo 'Full GPU offload was not confirmed; stopping inference.' >&2
            exit 1
        fi
        if sed -n 's/.*CPU[^ ]* model buffer size = *\([0-9.]*\) MiB.*/\1/p' "$model_dir/server.log" | awk '$1 > 0 { found=1 } END { exit !found }'; then
            echo 'Model weights were allocated on CPU; stopping inference.' >&2
            exit 1
        fi
        echo 'FULL_GPU_OFFLOAD_VERIFIED'
        break
    fi
    sleep 2
done
if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$model_dir/server.log"
    exit 1
fi
if wait "$server_pid"; then
    exit 0
else
    status=$?
    echo 'INFERENCE_SERVER_EXITED'
    tail -n 200 "$model_dir/server.log"
    exit "$status"
fi
