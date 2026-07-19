#!/usr/bin/env bash
# Strip Windows CRLF from deploy files (run once if bash reports pipefail or $'\r' errors).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

strip_file() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    return 0
  fi
  if grep -q $'\r' "${file}" 2>/dev/null; then
    tr -d '\r' < "${file}" > "${file}.tmp"
    mv "${file}.tmp" "${file}"
    echo "fixed: ${file}"
    return 0
  fi
  return 1
}

fixed=0
while IFS= read -r -d '' file; do
  strip_file "${file}" && fixed=$((fixed + 1)) || true
done < <(find "${ROOT_DIR}/scripts" -type f -name '*.sh' -print0)

for file in Makefile .env.app .env.storage .env.app.example .env.storage.example; do
  strip_file "${ROOT_DIR}/${file}" && fixed=$((fixed + 1)) || true
done

if (( fixed == 0 )); then
  echo "No CRLF found — files already use Unix line endings."
else
  echo "Fixed ${fixed} file(s). Re-run: make deploy-storage or make deploy-ghcr"
fi
