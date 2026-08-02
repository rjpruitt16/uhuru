#!/usr/bin/env bash
set -e

# Granville is optional at the image level: this same image runs either
# Together-only (today's deploy) or with a bundled local model, controlled
# entirely by whether GRANVILLE_MODEL_URL is set -- no separate Dockerfile
# needed for the two modes.
#
# The whole download+serve sequence runs in a background subshell so Phoenix
# never waits on it -- a multi-GB download blocking the main boot sequence
# was failing Fly's health check outright (app never started listening
# within the check window). Uhuru.Providers.Granville already handles
# "not reachable yet" gracefully, so there's nothing to gain by blocking.
if [ -n "$GRANVILLE_MODEL_URL" ]; then
  (
    GRANVILLE_MODEL_PATH="${GRANVILLE_MODEL_PATH:-/data/model.gguf}"
    GRANVILLE_SOCKET="${GRANVILLE_SOCKET:-/tmp/granville.sock}"

    download_model() {
      # A real download that landed truncated/wrong content (seen: a 1052
      # byte response instead of ~2.5GB, HTTP 200 the whole time so -f
      # didn't catch it) is why this validates GGUF magic bytes rather
      # than trusting a 200 status alone, and retries rather than trusting
      # one attempt -- whatever caused it looked transient, not a dead URL.
      for attempt in 1 2 3 4 5; do
        echo "boot: downloading model from $GRANVILLE_MODEL_URL (attempt $attempt/5)"
        rm -f "${GRANVILLE_MODEL_PATH}.partial"
        curl -fL --retry 3 --retry-delay 2 \
          -A "Mozilla/5.0 (compatible; uhuru-boot/1.0)" \
          -o "${GRANVILLE_MODEL_PATH}.partial" "$GRANVILLE_MODEL_URL" || true

        if [ "$(head -c 4 "${GRANVILLE_MODEL_PATH}.partial" 2>/dev/null)" = "GGUF" ]; then
          mv "${GRANVILLE_MODEL_PATH}.partial" "$GRANVILLE_MODEL_PATH"
          echo "boot: model downloaded, $(wc -c < "$GRANVILLE_MODEL_PATH") bytes"
          return 0
        fi

        echo "boot: download attempt $attempt did not produce a valid GGUF file, retrying"
        sleep $((attempt * 5))
      done
      return 1
    }

    if [ -f "$GRANVILLE_MODEL_PATH" ]; then
      echo "boot: model already present at $GRANVILLE_MODEL_PATH, skipping download"
    elif ! download_model; then
      echo "boot: model download failed after 5 attempts, granville will not start"
      rm -f "${GRANVILLE_MODEL_PATH}.partial"
      exit 1
    fi

    echo "boot: starting granville serve"
    exec /app/bin/granville serve "$GRANVILLE_MODEL_PATH" --socket "$GRANVILLE_SOCKET"
  ) &
else
  echo "boot: GRANVILLE_MODEL_URL not set, running Together-only"
fi

exec /bin/bash /app/bin/litestream.sh "$@"
