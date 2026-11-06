#!/usr/bin/env bash
# Shared helpers for the one-command monitoring setup scripts (scaling plan P1.9).
# Sourced by monitoring-setup-storage.sh and monitoring-setup-app.sh.

MSL_DRY_RUN=0
MSL_ASSUME_YES=0
MSL_CHANGED=0
MSL_PLANNED=0
declare -A _MSL_BACKED_UP=()

# Exit codes (documented in docs/db/scaling/p1-9-monitoring-setup.md)
MSL_EXIT_PREFLIGHT=2
MSL_EXIT_GUARD=3
MSL_EXIT_VERIFY=4

msl_fail() {  # msl_fail <exit-code> <message>
  local code="$1"; shift
  echo "ERROR: $*" >&2
  exit "$code"
}

# One status line per step: changed | unchanged | planned
msl_step() {  # msl_step <name> <status> [detail]
  local name="$1" status="$2" detail="${3:-}"
  [[ "$status" == changed ]] && MSL_CHANGED=1
  [[ "$status" == planned ]] && MSL_PLANNED=1
  printf '[%-9s] %-9s %s\n' "$name" "$status" "$detail"
}

msl_require_root() {
  [[ "$(id -u)" -eq 0 ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "run as root (sudo bash $0 ...)"
}

msl_valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}

msl_confirm() {  # msl_confirm <question>
  [[ "$MSL_ASSUME_YES" -eq 1 ]] && return 0
  local answer=""
  read -r -p "$1 [y/N] " answer < /dev/tty || true
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes ]] || msl_fail "$MSL_EXIT_PREFLIGHT" "cancelled, nothing changed"
}

# Back a file up once per run, before its first change.
msl_backup_once() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  [[ -n "${_MSL_BACKED_UP[$f]:-}" ]] && return 0
  cp -p "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  _MSL_BACKED_UP[$f]=1
}

# Set KEY=VALUE in an env file without touching other lines.
# Sets MSL_RESULT to unchanged | changed | planned (dry-run). Call it directly, NOT in $(...):
# the once-per-run backup bookkeeping must survive. Never prints the value.
MSL_RESULT=""
msl_set_env_key() {  # msl_set_env_key <file> <key> <value>
  local f="$1" key="$2" value="$3" current=""
  if [[ -f "$f" ]] && grep -qE "^${key}=" "$f"; then
    current="$(msl_get_env_key "$f" "$key")"
    if [[ "$current" == "$value" ]]; then MSL_RESULT=unchanged; return 0; fi
  fi
  if [[ "$MSL_DRY_RUN" -eq 1 ]]; then MSL_RESULT=planned; return 0; fi
  msl_backup_once "$f"
  local tmp
  tmp="$(mktemp "${f}.XXXXXX")"
  if [[ -f "$f" ]] && grep -qE "^${key}=" "$f"; then
    K="$key" V="$value" awk 'BEGIN{k=ENVIRON["K"]; v=ENVIRON["V"]} index($0, k"=")==1 {print k"="v; next} {print}' "$f" > "$tmp"
  else
    { [[ -f "$f" ]] && cat "$f"; printf '%s=%s\n' "$key" "$value"; } > "$tmp"
  fi
  if [[ -f "$f" ]]; then
    chmod --reference="$f" "$tmp" 2>/dev/null || true
    chown --reference="$f" "$tmp" 2>/dev/null || true
  else chmod 600 "$tmp"; fi
  mv -f "$tmp" "$f"
  MSL_RESULT=changed
}

# Read KEY's value from an env file (no sourcing). Tolerates Windows line endings.
msl_get_env_key() {  # msl_get_env_key <file> <key>
  local line
  line="$(grep -E "^${2}=" "$1" 2>/dev/null | tail -1)" || true
  line="${line%$'\r'}"
  printf '%s' "${line#*=}"
}

msl_random_password() {
  openssl rand -base64 48 | tr -d '/+=\n' | cut -c1-40
}

# Hand-off line: FALCONMON1:<base64 of file>:<first 12 hex of its sha256>
msl_handoff_line() {  # msl_handoff_line <file>
  printf 'FALCONMON1:%s:%s\n' "$(base64 -w0 < "$1")" "$(sha256sum < "$1" | cut -c1-12)"
}
