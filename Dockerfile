# syntax=docker/dockerfile:1
FROM ubuntu:24.04 AS splitter
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates curl git cmake build-essential && rm -rf /var/lib/apt/lists/*
RUN git init /src && cd /src && git remote add origin https://github.com/ggml-org/llama.cpp.git && git fetch --depth 1 origin 11fe02151f79c41d0d4af7da708755d73b9c0da6 && git checkout FETCH_HEAD
RUN cmake -S /src -B /build -DBUILD_SHARED_LIBS=OFF -DGGML_CUDA=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF && cmake --build /build --target llama-gguf-split -j 4
FROM splitter AS weights
COPY download.sh /download.sh
RUN sh /download.sh && mkdir /out && /build/bin/llama-gguf-split --split --split-max-size 6G /download/Qwen3.8-27B-Uncensored-Q4_K_M.gguf /out/model && rm -rf /download && test "$(find /out -name '*.gguf' | wc -l)" -eq 3 && cd /out && sha256sum *.gguf > preloaded.sha256
RUN cp /src/LICENSE /out/LLAMA-LICENSE && curl -fsSL https://www.apache.org/licenses/LICENSE-2.0.txt -o /out/MODEL-LICENSE && curl -fsSL https://huggingface.co/JonathanColetti/Qwen3.8-27B-Uncensored-GGUF/raw/45d0fc0ad6cfcf9eeee6008ddaea925536409b18/README.md -o /out/MODEL-CARD.txt
FROM ghcr.io/ggml-org/llama.cpp@sha256:e8318a7b3988f9ca57b28c03486569e60def08f2b7b060550ebfa046e175e6cb
LABEL org.opencontainers.image.source="https://github.com/RunningWithOscar/runpod-qwen-image"
LABEL org.opencontainers.image.description="Pinned Qwen3.8 27B Uncensored Q4_K_M; runtime keys only"
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
# One shard per layer: GHCR permits at most 10GB per layer.
COPY --from=weights /out/model-00001-of-00003.gguf /models/
COPY --from=weights /out/model-00002-of-00003.gguf /models/
COPY --from=weights /out/model-00003-of-00003.gguf /models/
COPY --from=weights /out/preloaded.sha256 /out/LLAMA-LICENSE /out/MODEL-LICENSE /out/MODEL-CARD.txt /models/
COPY bootstrap.sh server.sh benchmark.py provenance.json /opt/qwen/
ENV MODEL_DIR=/models MODEL_FILE=model-00001-of-00003.gguf SOURCE_MODEL_FILE=Qwen3.8-27B-Uncensored-Q4_K_M.gguf MODEL_SHA256=4c5e2db039e9325ac7724c8846c71356a24ad1cdfa28002d73ecb6be645f9675 SERVER_PATH=/opt/qwen/server.sh BENCHMARK_PATH=/opt/qwen/benchmark.py SPEC_DRAFT_N_MAX=2
EXPOSE 8080
ENTRYPOINT ["/bin/sh", "/opt/qwen/bootstrap.sh"]
