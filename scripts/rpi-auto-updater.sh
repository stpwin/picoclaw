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

if ! systemctl --user is-active --quiet "$SERVICE"; then
  log "ERROR new binary failed to start — rolling back"
  cp -f "$PREV" "$BIN"
  systemctl --user start "$SERVICE"
  exit 1
fi
log "OK    $latest_tag running on $SERVICE"
echo "$latest_tag" > "$STATE"
