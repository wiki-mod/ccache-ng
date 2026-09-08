#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  printf '%s\n' "$*"
}

memory_limit_bytes() {
  local value
  if [ -r /sys/fs/cgroup/memory.max ]; then
    value="$(cat /sys/fs/cgroup/memory.max)"
    if [ "$value" != "max" ] && [ "$value" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  if [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    value="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    if [ "$value" -gt 0 ] 2>/dev/null; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  free -b | awk '/^Mem:/ { print $2; exit }'
}

status_report() {
  log "redis-cache: system status"
  lscpu || true
  free -g || true
}

main() {
  local limit_bytes maxmemory ratio port
  ratio="${REDIS_CACHE_MEMORY_RATIO:-75}"
  port="${REDIS_PORT:-6379}"
  limit_bytes="$(memory_limit_bytes)"
  maxmemory="$((limit_bytes * ratio / 100))"

  status_report
  log "redis-cache: memory limit ${limit_bytes} bytes"
  log "redis-cache: maxmemory ${maxmemory} bytes (${ratio}%)"
  exec redis-server \
    --bind 0.0.0.0 \
    --protected-mode no \
    --port "$port" \
    --appendonly no \
    --save "" \
    --maxmemory "$maxmemory" \
    --maxmemory-policy "${REDIS_CACHE_EVICTION_POLICY:-allkeys-lru}" \
    "$@"
}

main "$@"
