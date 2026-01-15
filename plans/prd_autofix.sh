#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

PRD_FILE="${1:-${PRD_FILE:-plans/prd.json}}"

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 2; }
[[ -f "$PRD_FILE" ]] || { echo "missing PRD file: $PRD_FILE" >&2; exit 1; }

CORE_HAS_SRC=0
INFRA_HAS_SRC=0
if [[ -d crates/soldier_core/src ]]; then CORE_HAS_SRC=1; fi
if [[ -d crates/soldier_infra/src ]]; then INFRA_HAS_SRC=1; fi

tmp="$(mktemp)"

jq --argjson core_has_src "$CORE_HAS_SRC" \
   --argjson infra_has_src "$INFRA_HAS_SRC" '
  def has_glob: test("[*?\\[\\]]");
  def is_fileish:
    test("\\.(rs|sh|md|json|toml|txt|py|ya?ml)$")
    or (startswith(".") and test("\\."));
  def norm_slash: sub("/+$";"");

  def ensure_glob:
    if has_glob then .
    else if is_fileish then .
    else (norm_slash + "/**")
    end end;

  def canon_paths:
    if $core_has_src == 1 then
      gsub("crates/soldier_core/execution/"; "crates/soldier_core/src/execution/")
      | gsub("crates/soldier_core/idempotency/"; "crates/soldier_core/src/idempotency/")
      | gsub("crates/soldier_core/recovery/"; "crates/soldier_core/src/recovery/")
      | gsub("crates/soldier_core/venue/"; "crates/soldier_core/src/venue/")
      | gsub("crates/soldier_core/risk/"; "crates/soldier_core/src/risk/")
      | gsub("crates/soldier_core/strategy/"; "crates/soldier_core/src/strategy/")
    else . end
    | if $infra_has_src == 1 then
        gsub("crates/soldier_infra/deribit/"; "crates/soldier_infra/src/deribit/")
        | gsub("crates/soldier_infra/store/"; "crates/soldier_infra/src/store/")
      else . end;

  def dedup: unique;

  def fix_story:
    .scope.touch = ((.scope.touch // []) | map(canon_paths) | map(ensure_glob) | dedup)
    | .scope.avoid = ((.scope.avoid // []) | map(canon_paths) | map(ensure_glob) | dedup)
    | .verify = ((.verify // []) | map(canon_paths) | (if index("./plans/verify.sh") == null then ["./plans/verify.sh"] + . else . end) | dedup)
    | .steps = ((.steps // []) | map(canon_paths))
    | .evidence = ((.evidence // []) | map(canon_paths) | dedup)
    | .dependencies = ((.dependencies // []) | dedup);

  .items = (.items // [] | map(fix_story))
' "$PRD_FILE" > "$tmp" && mv "$tmp" "$PRD_FILE"

echo "PRD autofix applied: $PRD_FILE"
