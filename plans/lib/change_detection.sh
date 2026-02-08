#!/usr/bin/env bash

if [[ -n "${__CHANGE_DETECTION_SOURCED:-}" ]]; then
  return 0
fi
__CHANGE_DETECTION_SOURCED=1

: "${CHANGE_DETECTION_OK:=0}"
: "${CHANGED_FILES:=}"
: "${MODE:=}"
: "${WORKFLOW_ACCEPTANCE_POLICY:=auto}"

if ! declare -f warn >/dev/null 2>&1; then
  warn() { :; }
fi
if ! declare -f is_ci >/dev/null 2>&1; then
  is_ci() { return 1; }
fi
if ! declare -f is_workflow_file >/dev/null 2>&1; then
  is_workflow_file() { return 1; }
fi

files_match_any() {
  local matcher="$1"
  local f
  if [[ -z "$CHANGED_FILES" ]]; then
    return 1
  fi
  while IFS= read -r f; do
    if "$matcher" "$f"; then
      return 0
    fi
  done <<< "$CHANGED_FILES"
  return 1
}

is_rust_affecting_file() {
  case "$1" in
    *.rs|Cargo.toml|Cargo.lock|rust-toolchain|rust-toolchain.toml|rustfmt.toml|clippy.toml|.cargo/*) return 0 ;;
    */Cargo.toml|*/Cargo.lock|*/rust-toolchain|*/rust-toolchain.toml|*/rustfmt.toml|*/clippy.toml) return 0 ;;
    *) return 1 ;;
  esac
}

is_python_affecting_file() {
  case "$1" in
    *.py|*.pyi|pyproject.toml|requirements*.txt|setup.cfg|setup.py|tox.ini|mypy.ini|pytest.ini|.mypy.ini|.pytest.ini) return 0 ;;
    poetry.lock|uv.lock|ruff.toml|.ruff.toml|Pipfile|Pipfile.lock|.python-version) return 0 ;;
    */pyproject.toml|*/requirements*.txt|*/setup.cfg|*/setup.py|*/tox.ini|*/mypy.ini|*/pytest.ini) return 0 ;;
    */poetry.lock|*/uv.lock|*/ruff.toml|*/.ruff.toml|*/Pipfile|*/Pipfile.lock|*/.python-version) return 0 ;;
    *) return 1 ;;
  esac
}

is_node_affecting_file() {
  case "$1" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) return 0 ;;
    package.json|pnpm-lock.yaml|package-lock.json|yarn.lock|.nvmrc|.node-version) return 0 ;;
    tsconfig.json|tsconfig.*.json|eslint.config.*|.eslintrc*|.prettierrc*|prettier.config.*) return 0 ;;
    jest.config.*|vitest.config.*|babel.config.*|vite.config.*|next.config.*) return 0 ;;
    webpack.config.*|rollup.config.*) return 0 ;;
    */package.json|*/pnpm-lock.yaml|*/package-lock.json|*/yarn.lock|*/.nvmrc|*/.node-version) return 0 ;;
    */tsconfig.json|*/tsconfig.*.json|*/eslint.config.*|*/.eslintrc*|*/.prettierrc*|*/prettier.config.*) return 0 ;;
    */jest.config.*|*/vitest.config.*|*/babel.config.*|*/vite.config.*|*/next.config.*) return 0 ;;
    */webpack.config.*|*/rollup.config.*) return 0 ;;
    *) return 1 ;;
  esac
}

is_contract_coverage_input_file() {
  case "$1" in
    plans/prd.json|docs/contract_anchors.md|docs/validation_rules.md|plans/contract_coverage_matrix.py) return 0 ;;
    *) return 1 ;;
  esac
}

workflow_files_changed() {
  files_match_any is_workflow_file
}

should_run_contract_coverage() {
  if [[ "${MODE:-}" == "full" ]]; then
    return 0
  fi
  if [[ "${CHANGE_DETECTION_OK:-0}" != "1" ]]; then
    return 0
  fi
  files_match_any is_contract_coverage_input_file
}

should_run_rust_gates() {
  if [[ "${CHANGE_DETECTION_OK:-0}" != "1" ]]; then
    return 0
  fi
  files_match_any is_rust_affecting_file
}

should_run_python_gates() {
  if [[ "${CHANGE_DETECTION_OK:-0}" != "1" ]]; then
    return 0
  fi
  files_match_any is_python_affecting_file
}

should_run_node_gates() {
  if [[ "${CHANGE_DETECTION_OK:-0}" != "1" ]]; then
    return 0
  fi
  files_match_any is_node_affecting_file
}

should_run_workflow_acceptance() {
  if is_ci; then
    return 0
  fi

  case "${WORKFLOW_ACCEPTANCE_POLICY:-auto}" in
    always) return 0 ;;
    never) return 1 ;;
    auto) ;;
    *) warn "Unknown WORKFLOW_ACCEPTANCE_POLICY=${WORKFLOW_ACCEPTANCE_POLICY} (expected auto|always|never); defaulting to auto" ;;
  esac

  if [[ "${CHANGE_DETECTION_OK:-0}" != "1" ]]; then
    warn "change detection unavailable; running workflow acceptance to be safe"
    return 0
  fi

  if [[ -z "${CHANGED_FILES:-}" ]]; then
    return 1
  fi

  local f
  while IFS= read -r f; do
    if is_workflow_file "$f"; then
      echo "workflow acceptance required: changed workflow file: $f"
      return 0
    fi
  done <<< "$CHANGED_FILES"

  return 1
}

workflow_acceptance_mode() {
  if [[ "${CHANGE_DETECTION_OK:-0}" != "1" ]]; then
    echo "full"
    return 0
  fi
  if workflow_files_changed; then
    echo "full"
    return 0
  fi
  if is_ci; then
    echo "quick"
    return 0
  fi
  if [[ "${MODE:-}" == "full" ]]; then
    echo "full"
    return 0
  fi
  echo "quick"
}
