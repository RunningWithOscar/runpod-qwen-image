Qwen3.8-27B-Uncensored Q4_K_M ready image

Exact source revision, original checksum and llama.cpp runtime digest are pinned in provenance.json.
The original GGUF is verified before splitting into three real GGUF shards (no requantization).
Each shard occupies a separate layer to meet GHCR's 10GB-per-layer limit.
Startup verifies all shards; llama.cpp loads the entire model from the first shard.

Runtime: pass LLAMA_API_KEY as an environment variable. Never pass provider or inference keys during build.
Expose port 8080. Default context 8192, full GPU offload required, 24GB GPU recommended.
Set BENCHMARK=1 to compare baseline / fused MTP one-token / fused MTP two-token before serving.
Two-token fused MTP is the default, measured on RTX 4090 at 91.79 tokens/sec versus 47.79 baseline.
Set SPEC_DRAFT_N_MAX=0 to disable MTP, or 1 to draft one token.

The Docker build context is allowlisted. It contains no .env, deployment state or user account metadata.
GitHub Actions authentication happens at the registry login step, outside the Docker build.
On first publish, GHCR package visibility must be changed to Public to allow anonymous RunPod pulls.

A cached image can reduce startup time. On a cache miss, the host must still download ~17GB of weights.
No claim is made that RunPod image-pull time is free. Use zero persistent volumes and terminate the pod
when finished to avoid paying for stored disks while idle.
