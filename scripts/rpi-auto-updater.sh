#!/usr/bin/env bash
# Pi auto-updater for stpwin/picoclaw fork.
# Run via systemd user timer every N hours. Downloads latest release asset,
# verifies sha256, swaps binary atomically, restarts the gateway, rolls back
# if the new binary fails its post-start health check.
#
# Install path:   ~/.local/bin/picoclaw                (live)
# Backup path:    ~/.local/bin/picoclaw.prev           (one-step rollback)
# Staging path:   ~/.local/bin/picoclaw.new            (download target)
# State file:     ~/.picoclaw/.auto-updater-state      (tracks last tag)
# Log file:       ~/.picoclaw/logs/auto-updater.log

set -euo pipefail

REPO="stpwin/picoclaw"
ASSET="picoclaw-linux-arm64"
BIN="$HOME/.local/bin/picoclaw"
STAGE="$BIN.new"
PREV="$BIN.prev"
STATE="$HOME/.picoclaw/.auto-updater-state"
LOG_DIR="$HOME/.picoclaw/logs"
LOG="$LOG_DIR/auto-updater.log"
SERVICE="picoclaw-gateway.service"

mkdir -p "$LOG_DIR" "$(dirname "$STATE")"

log() {
  echo "[$(date -Is)] $*" | tee -a "$LOG"
}

# Fetch latest release metadata
meta=$(curl -fsSL -H 'Accept: application/vnd.github+json' \
  "https://api.github.com/repos/$REPO/releases/latest") || {
  log "WARN  cannot reach GitHub releases API — skipping run"
  exit 0
}

latest_tag=$(echo "$meta" | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"])')
asset_url=$(echo "$meta" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d.get('assets',[]):
    if a['name']=='$ASSET':
        print(a['browser_download_url']); break")
sha_url=$(echo "$meta" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for a in d.get('assets',[]):
    if a['name']=='$ASSET.sha256':
        print(a['browser_download_url']); break")

if [[ -z "$asset_url" || -z "$sha_url" ]]; then
  log "WARN  release $latest_tag is missing $ASSET or its sha256 — skipping"
  exit 0
fi

current_tag=$(cat "$STATE" 2>/dev/null || echo "none")
if [[ "$current_tag" == "$latest_tag" ]]; then
  log "OK    already on $latest_tag — no update"
  exit 0
fi

log "INFO  upgrade path: $current_tag -> $latest_tag"

# Download + verify
curl -fsSL "$asset_url" -o "$STAGE"
expected=$(curl -fsSL "$sha_url" | awk '{print $1}')
actual=$(sha256sum "$STAGE" | awk '{print $1}')
if [[ "$expected" != "$actual" ]]; then
  log "ERROR sha256 mismatch — expected=$expected actual=$actual — aborting"
  rm -f "$STAGE"
  exit 1
fi
log "OK    sha256 verified"

# Swap with atomic rename + rollback on failure
systemctl --user stop "$SERVICE" || true
cp -f "$BIN" "$PREV" 2>/dev/null || true
chmod +x "$STAGE"
mv -f "$STAGE" "$BIN"
systemctl --user start "$SERVICE"
sleep 4

# Health gate. `is-active` alone is not enough: a build can start cleanly and
# still be unusable. A stricter config parser, for example, rejects fields the
# running config already contains and the unit then restart-loops (reported as
# "activating", not "failed"), or the process listens but cannot serve. Check
# three things, cheapest first, and roll back on any of them.
rollback() {
  log "ERROR $1 — rolling back to previous binary"
  cp -f "$PREV" "$BIN"
  systemctl --user start "$SERVICE"
  exit 1
}

systemctl --user is-active --quiet "$SERVICE" || rollback "new binary failed to start"

# The gateway logs a explicit line when config validation fails, before exiting.
if journalctl --user -u "$SERVICE" --no-pager --since "1 min ago" 2>/dev/null \
     | grep -qE "Gateway startup failed|unknown field"; then
  rollback "new binary rejected the existing config"
fi

# Serving check — the port must actually answer.
PORT="${GATEWAY_PORT:-18789}"
if ! curl -fsS -m 10 -o /dev/null "http://127.0.0.1:${PORT}/health"; then
  rollback "gateway is up but /health does not answer on ${PORT}"
fi

log "OK    $latest_tag running on $SERVICE (start + config + /health verified)"
echo "$latest_tag" > "$STATE"
