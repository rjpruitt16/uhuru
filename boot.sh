#!/usr/bin/env bash
set -e

# Granville is optional at the image level: this same image runs either
# Together-only (today's deploy) or with a bundled local model, controlled
# entirely by whether GRANVILLE_MODEL_URL is set -- no separate Dockerfile
# needed for the two modes.
if [ -n "$GRANVILLE_MODEL_URL" ]; then
  GRANVILLE_MODEL_PATH="${GRANVILLE_MODEL_PATH:-/data/model.gguf}"
  GRANVILLE_SOCKET="${GRANVILLE_SOCKET:-/tmp/granville.sock}"

  if [ ! -f "$GRANVILLE_MODEL_PATH" ]; then
    echo "boot: downloading model from $GRANVILLE_MODEL_URL"
    mkdir -p "$(dirname "$GRANVILLE_MODEL_PATH")"
    curl -fL -o "${GRANVILLE_MODEL_PATH}.partial" "$GRANVILLE_MODEL_URL"
    mv "${GRANVILLE_MODEL_PATH}.partial" "$GRANVILLE_MODEL_PATH"
  else
    echo "boot: model already present at $GRANVILLE_MODEL_PATH, skipping download"
  fi

  echo "boot: starting granville serve"
  /app/bin/granville serve "$GRANVILLE_MODEL_PATH" --socket "$GRANVILLE_SOCKET" &

  echo "boot: waiting for granville socket at $GRANVILLE_SOCKET"
  for _ in $(seq 1 60); do
    [ -S "$GRANVILLE_SOCKET" ] && break
    sleep 1
  done

  if [ ! -S "$GRANVILLE_SOCKET" ]; then
    echo "boot: granville socket not ready after 60s, continuing anyway -- requests will surface the failure"
  fi
else
  echo "boot: GRANVILLE_MODEL_URL not set, running Together-only"
fi

exec /bin/bash /app/bin/litestream.sh "$@"
