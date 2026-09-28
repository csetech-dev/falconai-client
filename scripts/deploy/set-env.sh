#!/usr/bin/env bash
# Set KEY=VALUE pairs in an env file without opening an editor.
#
#   bash ./scripts/deploy/set-env.sh [--if-missing] <env-file> KEY=VALUE [KEY=VALUE ...]
#
# - Replaces an existing `KEY=` line (first match, commented-out `# KEY=` lines
#   are left alone) or appends `KEY=VALUE` when the key is absent.
# - --if-missing: only add keys that are absent or empty; never overwrite a value
#   that is already set. Use it for generated secrets so a re-run keeps them.
# - Keeps a timestamped backup next to the file (<env-file>.bak.<time>).
# - Never prints values (they may be secrets); prints only which keys changed.
#
# Examples:
#   bash ./scripts/deploy/set-env.sh --if-missing .env.app \
#     SEARCH_INTERNAL_API_KEY="$(openssl rand -hex 32)" METRICS_TOKEN="$(openssl rand -hex 32)"
#   bash ./scripts/deploy/set-env.sh .env.app PERFORMANCE_SCHEMA_MODE=verify
#   bash ./scripts/deploy/set-env.sh .env.app FALCON_IMAGE_TAG=stage
set -euo pipefail

if_missing=0
if [[ "${1:-}" == "--if-missing" ]]; then if_missing=1; shift; fi

file="${1:-}"
if [[ -z "${file}" || $# -lt 2 ]]; then
  echo "usage: bash ./scripts/deploy/set-env.sh [--if-missing] <env-file> KEY=VALUE [KEY=VALUE ...]" >&2
  exit 2
fi
shift
[[ -f "${file}" ]] || { echo "ERROR: ${file} not found (run from the deploy root, e.g. /opt/falconai-client)" >&2; exit 1; }

backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
cp -p "${file}" "${backup}"
tmp="$(mktemp "${file}.XXXXXX")"
trap 'rm -f "${tmp}"' EXIT

changed=()
for pair in "$@"; do
  if [[ "${pair}" != *=* ]]; then echo "ERROR: expected KEY=VALUE, got '${pair}'" >&2; exit 2; fi
  key="${pair%%=*}"
  value="${pair#*=}"
  if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then echo "ERROR: invalid key '${key}'" >&2; exit 2; fi
  if [[ "${value}" == *$'\n'* ]]; then echo "ERROR: value for ${key} contains a newline" >&2; exit 2; fi

  current="$(grep -m1 -E "^${key}=" "${file}" || true)"
  if [[ -n "${current}" ]]; then
    if [[ ${if_missing} -eq 1 && -n "${current#*=}" ]]; then
      echo "kept     ${key} (already set)"
      continue
    fi
    # Rewrite only the first KEY= line; awk avoids sed escaping of the value.
    KEY="${key}" VALUE="${value}" awk 'BEGIN{k=ENVIRON["KEY"]; v=ENVIRON["VALUE"]; done=0}
      { if (!done && index($0, k "=") == 1) { print k "=" v; done=1 } else print }' "${file}" > "${tmp}"
    cat "${tmp}" > "${file}"
    echo "updated  ${key}"
  else
    # Ensure the file ends with a newline before appending.
    [[ -s "${file}" && -n "$(tail -c1 "${file}")" ]] && echo >> "${file}"
    printf '%s=%s\n' "${key}" "${value}" >> "${file}"
    echo "added    ${key}"
  fi
  changed+=("${key}")
done

echo "Backup: ${backup}"
[[ ${#changed[@]} -gt 0 ]] && echo "Redeploy for the change to apply (make deploy-ghcr or make deploy-app)." || true
