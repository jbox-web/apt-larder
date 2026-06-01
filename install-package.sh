#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <package> [package...]" >&2
  exit 1
fi

packages=("$@")

run_in_client() {
  local client=$1
  echo "==> [$client] starting..."
  docker compose exec -T "$client" bash -c \
    "apt-get update -qq && apt-get install -y --download-only ${packages[*]}" \
    2>&1 | sed "s/^/[$client] /"
  echo "==> [$client] done"
}

pids=()
for client in client1 client2 client3; do
  run_in_client "$client" &
  pids+=($!)
done

failed=0
for pid in "${pids[@]}"; do
  wait "$pid" || failed=1
done

exit "$failed"
