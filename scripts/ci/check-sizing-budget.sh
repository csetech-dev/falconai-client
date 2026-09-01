#!/usr/bin/env bash
# Assert a hardware sizing profile still fits the box it is named after.
#
# Renders docker-compose.app.yml (+ the ghcr overlay, which is what production
# actually runs) and sums the container memory limits. Catches the two ways this
# drifts: someone adds a service without a profile entry, or someone bumps a
# limit past the host's physical RAM.
#
# Two modes, chosen automatically:
#
#   CLIENT HOST (.env.app exists) — checks ONLY the profile that host has
#     selected, layering .env.app so per-knob overrides are included. This is the
#     honest answer to "does my configuration fit my box".
#
#   VENDOR / CI (no .env.app) — checks EVERY profile against .env.app.example.
#
# Usage: make sizing-check     (or: bash scripts/ci/check-sizing-budget.sh)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

# python3 on Linux/CI, python on a Windows dev checkout. Probe by running it —
# Windows ships a python3 "App Execution Alias" stub that exists on PATH but
# only prints a Microsoft Store advert.
PYTHON=""
for candidate in python3 python; do
  if "${candidate}" -c 'import sys' >/dev/null 2>&1; then
    PYTHON="${candidate}"
    break
  fi
done
[[ -n "${PYTHON}" ]] || { echo "python3 (or python) is required" >&2; exit 1; }

# profile:max_memory_limits_GiB:max_shm_GiB — headroom for the OS and page cache
# is already subtracted (test 32 GB physical, prod 495 GB physical).
BUDGETS=(
  "test:40:10"
  "prod:440:48"
)

# Which profiles to check, and what to layer on top of them.
OVERLAY_ENV="${ROOT_DIR}/.env.app.example"
ONLY_PROFILE=""

if [[ -f "${ROOT_DIR}/.env.app" ]]; then
  OVERLAY_ENV="${ROOT_DIR}/.env.app"
  ONLY_PROFILE="$(sed -n 's/^[[:space:]]*FALCON_SIZING_PROFILE[[:space:]]*=[[:space:]]*//p' \
    "${ROOT_DIR}/.env.app" | tr -d '"'\''[:space:]' | tail -1)"
  ONLY_PROFILE="${ONLY_PROFILE:-test}"

  # A typo'd profile must fail loudly here, not silently check nothing.
  known=0
  for entry in "${BUDGETS[@]}"; do
    [[ "${entry%%:*}" == "${ONLY_PROFILE}" ]] && known=1
  done
  if (( ! known )); then
    echo "FALCON_SIZING_PROFILE='${ONLY_PROFILE}' in .env.app is not a known profile." >&2
    echo "Expected one of: ${BUDGETS[*]%%:*}" >&2
    exit 1
  fi

  echo "Host profile: ${ONLY_PROFILE}  (from .env.app, including its overrides)"
  echo
fi

fail=0

for entry in "${BUDGETS[@]}"; do
  IFS=: read -r profile max_mem max_shm <<<"${entry}"

  # On a client host, only the selected profile is meaningful — .env.app
  # overrides would otherwise be applied to a profile that host never loads.
  if [[ -n "${ONLY_PROFILE}" && "${profile}" != "${ONLY_PROFILE}" ]]; then
    continue
  fi

  sizing="${ROOT_DIR}/.env.sizing.${profile}"

  if [[ ! -f "${sizing}" ]]; then
    echo "MISSING: ${sizing}" >&2
    fail=1
    continue
  fi

  # Current Compose tolerates CRLF, but older versions and plain `source` do not,
  # and these files ship to Linux client hosts. Keep them LF-only.
  if grep -q $'\r' "${sizing}"; then
    echo "CRLF in ${sizing##*/} — run: bash scripts/deploy/fix-crlf.sh" >&2
    fail=1
  fi

  # `docker compose config` omits services whose profile is inactive, so the
  # profile list has to be forced on here or the scrapers (and the core
  # automation plane) would simply be invisible to the budget.
  base_profiles="$(sed -n 's/^[[:space:]]*COMPOSE_PROFILES[[:space:]]*=[[:space:]]*//p' \
    "${OVERLAY_ENV}" | tr -d '"'\''[:space:]' | tail -1)"
  base_profiles="${base_profiles:-scrapers}"

  # core ships in two supported shapes, and BOTH have to fit the box:
  #
  #   all-in-one — one falcon-core carrying the API and every scheduler, queue
  #                consumer and AI loop. Sized by FALCON_SZ_CORE_*.
  #   split      — falcon-core (API only) + falcon-core-automation, which is
  #                what the `split` profile starts. Sized by the api-plane
  #                values plus FALCON_SZ_CORE_AUTO_*.
  #
  # Checking only the first would let the split blow the budget the day someone
  # enables it; checking only a naive "both profiles on, core still at its
  # all-in-one size" would measure a configuration nobody should ever run. So
  # each shape is rendered and checked on its own, and the split render pulls
  # the api-plane values from the FALCON_SZ_CORE_SPLIT_* / CORE_SPLIT_* keys in
  # the sizing file — which is what makes those documented numbers actually
  # verified rather than a comment nobody re-checks.
  split_overrides="$(mktemp)"
  sed -n 's/^FALCON_SZ_CORE_SPLIT_/FALCON_SZ_CORE_/p' "${sizing}" > "${split_overrides}"
  sed -n 's/^CORE_SPLIT_/CORE_/p' "${sizing}" >> "${split_overrides}"

  render() {
    # $1 = comma-separated profiles, $2 = optional extra --env-file (last wins)
    local extra=()
    [[ -n "${2:-}" ]] && extra=(--env-file "$2")
    COMPOSE_PROFILES="$1" docker compose \
      --env-file "${sizing}" \
      --env-file "${OVERLAY_ENV}" \
      "${extra[@]}" \
      -f "${ROOT_DIR}/docker-compose.app.yml" \
      -f "${ROOT_DIR}/docker-compose.ghcr.yml" \
      config --format json 2>/dev/null
  }

  for shape in all-in-one split; do
    if [[ "${shape}" == "split" ]]; then
      rendered="$(render "${base_profiles},split" "${split_overrides}")"
    else
      rendered="$(render "${base_profiles}")"
    fi

  # Also surfaces services that have no limits at all — an unbounded container
  # on the prod box can consume the whole 495 GB.
  if ! MAX_MEM="${max_mem}" MAX_SHM="${max_shm}" PROFILE="${profile}/${shape}" \
       "${PYTHON}" -c '
import json, os, sys

data = json.loads(sys.stdin.read())
profile = os.environ["PROFILE"]
mem = cpu = shm = 0
unbounded = []

for name, svc in data["services"].items():
    limits = svc.get("deploy", {}).get("resources", {}).get("limits", {})
    m = int(limits.get("memory") or 0)
    if not m:
        unbounded.append(name)
    mem += m
    cpu += float(limits.get("cpus") or 0)
    shm += int(svc.get("shm_size") or 0)

gib = 1024 ** 3
mem_g, shm_g = mem / gib, shm / gib
max_mem, max_shm = float(os.environ["MAX_MEM"]), float(os.environ["MAX_SHM"])

print("%-16s services=%-3d mem=%6.1f GiB (max %.0f)  cpus=%6.1f  shm=%5.1f GiB (max %.0f)"
      % (profile, len(data["services"]), mem_g, max_mem, cpu, shm_g, max_shm))

ok = True
if mem_g > max_mem:
    print("  FAIL: memory limits %.1f GiB exceed the %.0f GiB budget" % (mem_g, max_mem))
    ok = False
if shm_g > max_shm:
    print("  FAIL: shm_size total %.1f GiB exceeds the %.0f GiB budget" % (shm_g, max_shm))
    ok = False
if unbounded:
    # wireguard is a network sidecar with no workload; everything else must be capped.
    real = [n for n in unbounded if n != "wireguard"]
    if real:
        print("  FAIL: no memory limit on: %s" % ", ".join(sorted(real)))
        ok = False

sys.exit(0 if ok else 1)
' <<<"${rendered}"; then
      fail=1
    fi
  done

  rm -f "${split_overrides}"
done

if (( fail )); then
  echo
  echo "Sizing budget check FAILED — see scripts/deploy/common.sh (resolve_sizing_file)" >&2
  exit 1
fi

echo "Sizing budget check passed."
