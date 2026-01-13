#!/usr/bin/env bash

# Save caller's shell options to restore later
_profile_old_opts="$(set +o)"

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This script must be sourced: source plans/profile.sh <fast|thorough|audit|max>" >&2
  exit 1
fi

profile="${1:-}"

unset RPH_PROFILE
unset RPH_VERIFY_MODE
unset RPH_ITER_TIMEOUT_SECS
unset RPH_SELF_HEAL
unset RPH_AGENT_MODEL
unset RPH_RATE_LIMIT_PER_HOUR

case "$profile" in
  fast)
    export RPH_PROFILE="fast"
    export RPH_VERIFY_MODE="quick"
    export RPH_ITER_TIMEOUT_SECS="1200"
    ;;
  thorough)
    export RPH_PROFILE="thorough"
    export RPH_VERIFY_MODE="full"
    export RPH_ITER_TIMEOUT_SECS="3600"
    ;;
  audit)
    export RPH_PROFILE="audit"
    export RPH_VERIFY_MODE="full"
    export RPH_SELF_HEAL="0"
    ;;
  max)
    export RPH_PROFILE="max"
    export RPH_VERIFY_MODE="full"
    export RPH_ITER_TIMEOUT_SECS="7200"
    export RPH_AGENT_MODEL="gpt-5.2-codex"
    export RPH_RATE_LIMIT_PER_HOUR="40"
    ;;
  *)
    echo "Unknown profile: ${profile:-<empty>} (expected fast|thorough|audit|max)" >&2
    eval "$_profile_old_opts"
    return 2
    ;;
esac

# Restore caller's shell options
eval "$_profile_old_opts"
