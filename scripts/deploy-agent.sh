#!/bin/bash
# ============================================================
# FalconAI Deploy Agent
# Run this DIRECTLY ON THE HOST (not inside any Docker container).
# It watches for a trigger file and runs deployment on the host machine,
# writing output to files that the NestJS container can read via the
# shared /opt/FalconAI volume mount.
#
# Modes (FALCON_DEPLOY_MODE):
#   git  — default: git fetch/reset + docker compose up --build
#   ghcr — pull pre-built images from GHCR (no source on client)
#
# Setup:
#   chmod +x /opt/FalconAI/scripts/deploy-agent.sh
#   sudo cp /opt/FalconAI/scripts/deploy-agent.service /etc/systemd/system/
#   sudo systemctl daemon-reload
#   sudo systemctl enable --now falcon-deploy-agent
# ============================================================

set -euo pipefail

PROJECT_DIR="${FALCON_PROJECT_DIR:-/opt/FalconAI}"
DEPLOY_DIR="${FALCON_DEPLOY_DIR:-$PROJECT_DIR/.deploy}"
TRIGGER_FILE="$DEPLOY_DIR/trigger"
DEPLOY_MODE="${FALCON_DEPLOY_MODE:-git}"
GHCR_IMAGE_PREFIX="${GHCR_IMAGE_PREFIX:-}"
FALCON_IMAGE_TAG="${FALCON_IMAGE_TAG:-latest}"
COMPOSE_BASE=(docker-compose.yml docker-compose.prod.yml)
COMPOSE_GHCR=(docker-compose.ghcr.yml)

# Status files read by falcon-core NestJS service
STATUS_FILE="$DEPLOY_DIR/status"
OUTPUT_FILE="$DEPLOY_DIR/output"
ERROR_FILE="$DEPLOY_DIR/error"
STARTED_AT_FILE="$DEPLOY_DIR/started_at"
COMPLETED_AT_FILE="$DEPLOY_DIR/completed_at"

# Manual command execution files
CMD_TRIGGER_FILE="$DEPLOY_DIR/cmd_trigger"
CMD_KILL_FILE="$DEPLOY_DIR/cmd_kill"
CMD_PID_FILE="$DEPLOY_DIR/cmd_pid"
CMD_STATUS_FILE="$DEPLOY_DIR/cmd_status"
CMD_OUTPUT_FILE="$DEPLOY_DIR/cmd_output"
CMD_ERROR_FILE="$DEPLOY_DIR/cmd_error"
CMD_STARTED_AT_FILE="$DEPLOY_DIR/cmd_started_at"
CMD_COMPLETED_AT_FILE="$DEPLOY_DIR/cmd_completed_at"

clean_excludes=(
  -e .deploy
  -e .deploy/
  -e apps/scrapers/worker-fb/facebook_vnc_profile/
  -e apps/scrapers/worker-search/brave_profile/
)

# Ensure deploy dir exists
mkdir -p "$DEPLOY_DIR"

# Initialize status if not set
if [ ! -f "$STATUS_FILE" ]; then
  echo "idle" > "$STATUS_FILE"
fi

echo "[deploy-agent] Started. Watching $TRIGGER_FILE ..."
echo "[deploy-agent] Project dir: $PROJECT_DIR"
echo "[deploy-agent] Deploy mode: $DEPLOY_MODE"

compose_args() {
  local args=()
  for file in "${COMPOSE_BASE[@]}"; do
    args+=(-f "$PROJECT_DIR/$file")
  done
  if [[ "$DEPLOY_MODE" == "ghcr" ]]; then
    args+=(-f "$PROJECT_DIR/${COMPOSE_GHCR[0]}")
  fi
  printf '%s\n' "${args[@]}"
}

run_prisma_db_push() {
  echo "" >> "$OUTPUT_FILE"
  log "[PRISMA DB PUSH] Running prisma db push --skip-generate in falcon-core..."
  if docker exec -w /app/libs/database falcon-core npx prisma db push --skip-generate 2>&1 | tee -a "$OUTPUT_FILE"; then
    log "[PRISMA DB PUSH] prisma db push succeeded"
  else
    fail_deployment "prisma db push failed"
    return 1
  fi
}

ensure_deploy_dir() {
  mkdir -p "$DEPLOY_DIR"
}

log() {
  ensure_deploy_dir
  echo "$*" | tee -a "$OUTPUT_FILE"
}

fail_deployment() {
  local message="$1"
  ensure_deploy_dir
  log "[deploy-agent] FAILED: $message"
  echo "$message" > "$ERROR_FILE"
  echo "failed" > "$STATUS_FILE"
  date -u +"%Y-%m-%dT%H:%M:%S.000Z" > "$COMPLETED_AT_FILE"
}

run_deployment() {
  ensure_deploy_dir
  echo "running" > "$STATUS_FILE"
  date -u +"%Y-%m-%dT%H:%M:%S.000Z" > "$STARTED_AT_FILE"
  rm -f "$COMPLETED_AT_FILE" "$ERROR_FILE"
  > "$OUTPUT_FILE"

  log "[deploy-agent] === DEPLOYMENT STARTED ==="
  log "[deploy-agent] $(date)"

  cd "$PROJECT_DIR"

  if [[ -f "$PROJECT_DIR/.env.app" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$PROJECT_DIR/.env.app"
    set +a
  fi

  if [[ "$DEPLOY_MODE" == "ghcr" ]]; then
    # ---- GHCR client bundle: pull images + up (no git) ----
    [[ -n "${GHCR_IMAGE_PREFIX:-}" ]] || {
      fail_deployment "GHCR_IMAGE_PREFIX not set in .env.app or environment"
      return 1
    }

    export FALCON_DEPLOY_MODE=ghcr
    export FALCON_DEPLOY_DIR="${FALCON_DEPLOY_DIR:-$PROJECT_DIR}"
    export BUILD_FLAG=0

    echo "" >> "$OUTPUT_FILE"
    log "[GHCR DEPLOY] prefix=${GHCR_IMAGE_PREFIX} tag=${FALCON_IMAGE_TAG:-latest}"
    if ! bash "$PROJECT_DIR/scripts/deploy/deploy.sh" ghcr 2>&1 | tee -a "$OUTPUT_FILE"; then
      fail_deployment "scripts/deploy/deploy.sh ghcr failed"
      return 1
    fi
  else
    mapfile -t COMPOSE_FILE_ARGS < <(compose_args)
    # ---- Step 1: Sync repository to origin/main ----
    echo "" >> "$OUTPUT_FILE"
    log "[GIT SYNC]"
    git config --global --add safe.directory "$PROJECT_DIR" 2>&1 | tee -a "$OUTPUT_FILE" || true

    log "[GIT SYNC] Fetching origin/main..."
    if ! git fetch origin main 2>&1 | tee -a "$OUTPUT_FILE"; then
      fail_deployment "git fetch origin main failed. Check root SSH/GitHub access."
      return 1
    fi

    log "[GIT SYNC] Resetting worktree to origin/main..."
    if ! git reset --hard origin/main 2>&1 | tee -a "$OUTPUT_FILE"; then
      fail_deployment "git reset --hard origin/main failed"
      return 1
    fi

    ensure_deploy_dir
    log "[GIT SYNC] Cleaning untracked files while preserving deploy state and browser profiles..."
    if ! git clean -fd "${clean_excludes[@]}" 2>&1 | tee -a "$OUTPUT_FILE"; then
      ensure_deploy_dir
      fail_deployment "git clean failed"
      return 1
    fi

    ensure_deploy_dir
    log "[GIT SYNC] Done"

    # ---- Step 2: Docker Compose Up with Build ----
    echo "" >> "$OUTPUT_FILE"
    log "[DOCKER COMPOSE UP --BUILD]"
    if docker compose "${COMPOSE_FILE_ARGS[@]}" up -d --build 2>&1 | tee -a "$OUTPUT_FILE"; then
      ensure_deploy_dir
      log "[DOCKER COMPOSE UP --BUILD] Done"
    else
      ensure_deploy_dir
      fail_deployment "docker compose up --build failed"
      return 1
    fi

    # ---- Step 3: Apply Prisma schema changes ----
    echo "" >> "$OUTPUT_FILE"
    log "[PRISMA DB PUSH] Copying updated schema into falcon-core container..."
    if docker cp "$PROJECT_DIR/libs/database/prisma/schema.prisma" falcon-core:/app/libs/database/prisma/schema.prisma 2>&1 | tee -a "$OUTPUT_FILE"; then
      log "[PRISMA DB PUSH] schema.prisma copied successfully"
    else
      ensure_deploy_dir
      fail_deployment "docker cp schema.prisma to falcon-core failed"
      return 1
    fi

    run_prisma_db_push || return 1
  fi

  echo "" >> "$OUTPUT_FILE"
  log "[deploy-agent] === DEPLOYMENT COMPLETE ==="

  echo "success" > "$STATUS_FILE"
  date -u +"%Y-%m-%dT%H:%M:%S.000Z" > "$COMPLETED_AT_FILE"
  echo "[deploy-agent] SUCCESS"
}

run_command() {
  local cmd="$1"
  ensure_deploy_dir
  echo "running" > "$CMD_STATUS_FILE"
  date -u +"%Y-%m-%dT%H:%M:%S.000Z" > "$CMD_STARTED_AT_FILE"
  rm -f "$CMD_COMPLETED_AT_FILE" "$CMD_ERROR_FILE" "$CMD_KILL_FILE" "$CMD_PID_FILE"
  > "$CMD_OUTPUT_FILE"

  echo "[deploy-agent] === COMMAND STARTED ===" >> "$CMD_OUTPUT_FILE"
  echo "[deploy-agent] $(date)" >> "$CMD_OUTPUT_FILE"
  echo "[deploy-agent] CMD: $cmd" >> "$CMD_OUTPUT_FILE"
  echo "" >> "$CMD_OUTPUT_FILE"

  cd "$PROJECT_DIR"

  # setsid gives the child its own process group so we can kill the whole tree
  setsid bash -c "$cmd" >> "$CMD_OUTPUT_FILE" 2>&1 &
  local cmd_pid=$!
  echo "$cmd_pid" > "$CMD_PID_FILE"

  # Track elapsed time for 300s timeout
  local elapsed=0

  # Wait for process while checking for kill trigger every second
  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [ -f "$CMD_KILL_FILE" ]; then
      rm -f "$CMD_KILL_FILE"
      echo "" >> "$CMD_OUTPUT_FILE"
      echo "[deploy-agent] === TERMINATED BY USER ===" >> "$CMD_OUTPUT_FILE"
      # setsid makes cmd_pid the session leader — kill every process in that session
      pkill -KILL -s "$cmd_pid" 2>/dev/null || true
      # Fallback: kill process group and PID directly
      kill -KILL -"$cmd_pid" 2>/dev/null || true
      kill -KILL "$cmd_pid" 2>/dev/null || true
      # Walk and kill all descendants
      local descendants
      descendants=$(pgrep -P "$cmd_pid" 2>/dev/null || true)
      for dpid in $descendants; do
        kill -KILL "$dpid" 2>/dev/null || true
      done
      wait "$cmd_pid" 2>/dev/null || true
      rm -f "$CMD_PID_FILE"
      echo "terminated" > "$CMD_STATUS_FILE"
      echo "Terminated by user" > "$CMD_ERROR_FILE"
      date -u +"%Y-%m-%dT%H:%M:%S.000Z" > "$CMD_COMPLETED_AT_FILE"
      return 0
    fi
    if [ "$elapsed" -ge 300 ]; then
      echo "" >> "$CMD_OUTPUT_FILE"
      echo "[deploy-agent] === COMMAND TIMED OUT (300s) ===" >> "$CMD_OUTPUT_FILE"
      kill -TERM -"$cmd_pid" 2>/dev/null || kill -TERM "$cmd_pid" 2>/dev/null || true
      wait "$cmd_pid" 2>/dev/null || true
      rm -f "$CMD_PID_FILE"
      echo "Command timed out after 300 seconds" > "$CMD_ERROR_FILE"
      echo "failed" > "$CMD_STATUS_FILE"
      date -u +"%Y-%m-%dT%H:%M:%S.000Z" > "$CMD_COMPLETED_AT_FILE"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$cmd_pid"
  local exit_code=$?
  rm -f "$CMD_PID_FILE"

  ensure_deploy_dir
  if [ "$exit_code" -eq 0 ]; then
    echo "" >> "$CMD_OUTPUT_FILE"
    echo "[deploy-agent] === COMMAND COMPLETE ===" >> "$CMD_OUTPUT_FILE"
    echo "success" > "$CMD_STATUS_FILE"
  else
    echo "" >> "$CMD_OUTPUT_FILE"
    echo "[deploy-agent] === COMMAND FAILED (exit $exit_code) ===" >> "$CMD_OUTPUT_FILE"
    echo "Command failed with exit code $exit_code" > "$CMD_ERROR_FILE"
    echo "failed" > "$CMD_STATUS_FILE"
  fi

  date -u +"%Y-%m-%dT%H:%M:%S.000Z" > "$CMD_COMPLETED_AT_FILE"
}

# Main watch loop
while true; do
  if [ -f "$TRIGGER_FILE" ]; then
    rm -f "$TRIGGER_FILE"
    echo "[deploy-agent] Trigger detected — starting deployment..."
    run_deployment || true
  fi

  if [ -f "$CMD_TRIGGER_FILE" ]; then
    CMD="$(cat "$CMD_TRIGGER_FILE")"
    rm -f "$CMD_TRIGGER_FILE"
    echo "[deploy-agent] Command trigger detected — running command..."
    run_command "$CMD" || true
  fi

  sleep 2
done
