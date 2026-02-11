#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKPOINT_FILE="${VERIFY_CHECKPOINT_FILE:-$ROOT/.ralph/verify_checkpoint.json}"
LOCK_FILE="${VERIFY_CHECKPOINT_LOCK_FILE:-$(dirname "$CHECKPOINT_FILE")/verify_checkpoint.lock}"
LOCK_STALE_SECS="${VERIFY_CHECKPOINT_LOCK_STALE_SECS:-600}"
LOCK_FILE_EXPLICIT=0
FORCE=0
QUIET=0

usage() {
  cat <<'EOF'
Usage: ./plans/reset_verify_checkpoint.sh [options]

Options:
  --checkpoint <path>   Checkpoint file path override.
  --lock-file <path>    Lock file path override.
  --force               Remove lock even when held by a live process.
  --quiet               Suppress informational output.
  -h, --help            Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --checkpoint)
      CHECKPOINT_FILE="${2:-}"
      shift 2
      ;;
    --lock-file)
      LOCK_FILE="${2:-}"
      LOCK_FILE_EXPLICIT=1
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "FAIL: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$LOCK_FILE_EXPLICIT" != "1" ]]; then
  LOCK_FILE="$(dirname "$CHECKPOINT_FILE")/verify_checkpoint.lock"
fi

if [[ -z "$CHECKPOINT_FILE" ]]; then
  echo "FAIL: checkpoint path is empty" >&2
  exit 2
fi
if [[ -z "$LOCK_FILE" ]]; then
  echo "FAIL: lock-file path is empty" >&2
  exit 2
fi
if ! [[ "$LOCK_STALE_SECS" =~ ^[0-9]+$ ]]; then
  LOCK_STALE_SECS=600
fi
(( LOCK_STALE_SECS < 1 )) && LOCK_STALE_SECS=1

now_epoch() {
  local now="${VERIFY_CHECKPOINT_NOW_EPOCH:-}"
  if [[ "$now" =~ ^[0-9]+$ ]]; then
    echo "$now"
    return 0
  fi
  date +%s
}

is_lock_active() {
  local lock_file="$1"
  [[ -f "$lock_file" ]] || return 1
  local pid start now age
  pid="$(awk -F= '/^pid=/{print $2; exit}' "$lock_file" 2>/dev/null || true)"
  start="$(awk -F= '/^start_epoch=/{print $2; exit}' "$lock_file" 2>/dev/null || true)"
  [[ "$start" =~ ^[0-9]+$ ]] || start=0
  now="$(now_epoch)"
  if (( now < start )); then
    age=0
  else
    age=$(( now - start ))
  fi
  if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  if (( age >= LOCK_STALE_SECS )); then
    return 1
  fi
  return 1
}

if [[ -f "$LOCK_FILE" ]]; then
  if is_lock_active "$LOCK_FILE" && [[ "$FORCE" != "1" ]]; then
    echo "FAIL: active lock detected at $LOCK_FILE (use --force to override)" >&2
    exit 1
  fi
  rm -f "$LOCK_FILE"
fi

mkdir -p "$(dirname "$CHECKPOINT_FILE")"
backup_path=""
if [[ -f "$CHECKPOINT_FILE" ]]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_path="${CHECKPOINT_FILE}.bak.${stamp}"
  cp "$CHECKPOINT_FILE" "$backup_path"
  rm -f "$CHECKPOINT_FILE"
fi

if [[ "$QUIET" != "1" ]]; then
  echo "checkpoint_reset=ok"
  echo "checkpoint_file=$CHECKPOINT_FILE"
  if [[ -n "$backup_path" ]]; then
    echo "backup_file=$backup_path"
  else
    echo "backup_file=<none>"
  fi
  echo "lock_file_removed=$LOCK_FILE"
  echo "next=./plans/verify.sh quick"
fi
