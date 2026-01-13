#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

command -v git >/dev/null 2>&1 || { echo "git is required"; exit 1; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty; commit or stash before pushing to main."
  exit 1
fi

if git worktree list --porcelain >/dev/null 2>&1; then
  current_wt="$ROOT"
  wt=""
  br=""
  other_main=""
  while IFS=' ' read -r key value; do
    case "$key" in
      worktree)
        wt="$value"
        br=""
        ;;
      branch)
        br="$value"
        if [[ "$br" == "refs/heads/main" && "$wt" != "$current_wt" ]]; then
          other_main="$wt"
          break
        fi
        ;;
    esac
  done < <(git worktree list --porcelain)

  if [[ -n "$other_main" ]]; then
    echo "main is checked out in another worktree: $other_main"
    echo "Run this script from that worktree or detach main there."
    exit 1
  fi
fi

git fetch origin main
git rebase origin/main
git push origin HEAD:main
