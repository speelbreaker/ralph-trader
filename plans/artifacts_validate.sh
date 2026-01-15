#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

file="${1:-}"
if [[ -z "$file" ]]; then
  echo "ERROR: missing artifact manifest path" >&2
  echo "Usage: $0 path/to/artifacts.json" >&2
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }

if [[ ! -f "$file" ]]; then
  echo "ERROR: artifact manifest not found: $file" >&2
  exit 1
fi

if ! jq -e . "$file" >/dev/null 2>&1; then
  echo "ERROR: invalid JSON in $file" >&2
  exit 1
fi

schema_file="${ARTIFACTS_SCHEMA:-docs/schemas/artifacts.schema.json}"
if [[ ! -f "$schema_file" ]]; then
  echo "ERROR: artifact manifest schema not found: $schema_file" >&2
  exit 1
fi

if ! jq -e . "$schema_file" >/dev/null 2>&1; then
  echo "ERROR: invalid JSON schema: $schema_file" >&2
  exit 1
fi

schema_get() {
  local jq_path="$1"
  local label="$2"
  local out
  out="$(jq -c "$jq_path" "$schema_file" 2>/dev/null || true)"
  if [[ -z "$out" || "$out" == "null" ]]; then
    echo "ERROR: schema missing $label ($jq_path)" >&2
    exit 1
  fi
  echo "$out"
}

root_required="$(schema_get '.required' 'root.required')"
root_props="$(schema_get '.properties | keys' 'root.properties')"
final_status_enum="$(schema_get '.properties.final_verify_status.enum' 'final_verify_status.enum')"
schema_version_enum="$(schema_get '.properties.schema_version.enum' 'schema_version.enum')"
skip_required="$(schema_get '.properties.skipped_checks.items.required' 'skipped_checks.items.required')"
skip_props="$(schema_get '.properties.skipped_checks.items.properties | keys' 'skipped_checks.items.properties')"

errors="$(
  jq -r \
    --argjson root_required "$root_required" \
    --argjson root_props "$root_props" \
    --argjson final_status_enum "$final_status_enum" \
    --argjson schema_version_enum "$schema_version_enum" \
    --argjson skip_required "$skip_required" \
    --argjson skip_props "$skip_props" \
    '
    def check(cond; msg): if cond then empty else msg end;
    def in_enum(val; options): val as $v | (options | index($v)) != null;
    def has_all(obj; reqs): (obj) as $o | reqs | all(. as $k | $o | has($k));
    def keys_ok(obj; allowed): (obj) as $o | (($o|keys) - allowed | length) == 0;
    def str_or_null(v): (v == null) or (v | type == "string");
    def int_or_null(v): (v == null) or (v | type == "number");
    [
      check(type=="object"; "root must be an object"),
      check(has_all(.; $root_required); "root missing required keys"),
      check(keys_ok(.; $root_props); "root has unknown keys"),

      check((.schema_version|type=="number") and (in_enum(.schema_version; $schema_version_enum)); "schema_version must match schema enum"),
      check(str_or_null(.run_id); "run_id must be string or null"),
      check(str_or_null(.iter_dir); "iter_dir must be string or null"),
      check(str_or_null(.head_before); "head_before must be string or null"),
      check(str_or_null(.head_after); "head_after must be string or null"),
      check(int_or_null(.commit_count); "commit_count must be number or null"),
      check(str_or_null(.verify_pre_log_path); "verify_pre_log_path must be string or null"),
      check(str_or_null(.verify_post_log_path); "verify_post_log_path must be string or null"),
      check(str_or_null(.final_verify_log_path); "final_verify_log_path must be string or null"),
      check((.final_verify_status == null) or (in_enum(.final_verify_status; $final_status_enum)); "final_verify_status must match schema enum"),
      check(str_or_null(.contract_review_path); "contract_review_path must be string or null"),
      check(str_or_null(.contract_check_report_path); "contract_check_report_path must be string or null"),
      check(str_or_null(.blocked_dir); "blocked_dir must be string or null"),
      check(str_or_null(.blocked_reason); "blocked_reason must be string or null"),
      check(str_or_null(.blocked_details); "blocked_details must be string or null"),
      check((.generated_at|type=="string" and length>0); "generated_at must be non-empty string"),

      check((.skipped_checks|type=="array"); "skipped_checks must be array"),
      check((.skipped_checks|all(.[]?; type=="object")); "skipped_checks entries must be objects"),
      check((.skipped_checks|all(.[]?; has_all(.; $skip_required))); "skipped_checks entries missing required keys"),
      check((.skipped_checks|all(.[]?; keys_ok(.; $skip_props))); "skipped_checks entries have unknown keys"),
      check((.skipped_checks|all(.[]?; (.name|type=="string" and length>0))); "skipped_checks.name must be non-empty string"),
      check((.skipped_checks|all(.[]?; (.reason|type=="string" and length>0))); "skipped_checks.reason must be non-empty string")
    ] | .[]?
    ' "$file"
)"

if [[ -n "$errors" ]]; then
  echo "ERROR: artifact manifest schema invalid: $file" >&2
  printf '%s\n' "$errors" | sed 's/^/- /' >&2
  exit 1
fi

exit 0
