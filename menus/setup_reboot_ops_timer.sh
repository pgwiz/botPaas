#!/bin/bash
set -euo pipefail

# MS Manager - Reboot Ops Timer plugin
# A reliable systemd timer for periodic reboots.
# Time input supports: 30m, 2h, 1h30m (suffixes: h and m)

CONFIG_DIR="/etc/ms-server"
CONF_FILE="$CONFIG_DIR/reboot_ops.conf"
OPS_SCRIPT="/usr/local/bin/ms-reboot-ops.sh"
SERVICE_FILE="/etc/systemd/system/ms-reboot-ops.service"
TIMER_FILE="/etc/systemd/system/ms-reboot-ops.timer"
OLD_REBOOT_SERVICE="ms-reboot.service"

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "⚠️  This menu needs root. Run: sudo bash $0"
    exit 1
  fi
}

ensure_conf() {
  mkdir -p "$CONFIG_DIR"
  if [ ! -f "$CONF_FILE" ]; then
    cat > "$CONF_FILE" <<'EOF'
# ms-reboot-ops config
# REBOOT_OPS_ENABLED: 1/0 (timer enable/disable also controls execution)
REBOOT_OPS_ENABLED=0

# Interval in seconds (default 2 hours)
REBOOT_OPS_INTERVAL_SEC=7200
EOF
    chmod 644 "$CONF_FILE"
  fi
}

load_conf() {
  ensure_conf
  # shellcheck disable=SC1090
  source "$CONF_FILE" 2>/dev/null || true
}

save_conf_kv() {
  local key="$1"
  local value="$2"
  ensure_conf
  if grep -qE "^${key}=" "$CONF_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$CONF_FILE"
  else
    echo "${key}=${value}" >> "$CONF_FILE"
  fi
}

# Parse only h/m forms: 30m, 2h, 1h30m
parse_hm_to_seconds() {
  local s
  s="$(echo "${1:-}" | tr -d '[:space:]')"
  if [ -z "$s" ]; then
    return 1
  fi
  if [ "$s" = "0" ]; then
    echo 0
    return 0
  fi
  if [[ "$s" =~ ^([0-9]+)h([0-9]+)m$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 3600 + ${BASH_REMATCH[2]} * 60 ))
    return 0
  fi
  if [[ "$s" =~ ^([0-9]+)h$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 3600 ))
    return 0
  fi
  if [[ "$s" =~ ^([0-9]+)m$ ]]; then
    echo $(( ${BASH_REMATCH[1]} * 60 ))
    return 0
  fi
  return 1
}

warn_banner() {
  echo "============================================================"
  echo "  ⚠️  REBOOT OPS TIMER (systemd)"
  echo "------------------------------------------------------------"
  echo "  This feature can automatically REBOOT the server."
  echo "  Use a sensible interval (e.g. 6h, 12h, 24h)."
  echo "  Test mode is safe (no reboot)."
  echo "============================================================"
  echo ""
}

install_ops_files() {
  echo "Installing ms-reboot-ops script + systemd units..."

  # Main ops script (called by timer)
  cat > "$OPS_SCRIPT" <<'__MS_REBOOT_OPS_SH__'
#!/bin/bash
set -euo pipefail

CONFIG_DIR="/etc/ms-server"
MAIN_CONF="$CONFIG_DIR/config.conf"
OPS_CONF="$CONFIG_DIR/reboot_ops.conf"

REBOOT_TS_FILE="$CONFIG_DIR/last_reboot_timestamp"
REBOOT_LOG_FILE="$CONFIG_DIR/reboot_history.log"
REBOOT_DB_FILE="$CONFIG_DIR/reboot_database.csv"
LOG_FILE="/var/log/ms-reboot-ops.log"

INTERVAL_DEFAULT=7200
ENABLED_DEFAULT=0

REBOOT_OPS_ENABLED="$ENABLED_DEFAULT"
REBOOT_OPS_INTERVAL_SEC="$INTERVAL_DEFAULT"
ENABLE_VPS_REBOOT="false"

log() {
  printf "[%s] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >/dev/null
}

# Load configs (best-effort)
if [ -f "$MAIN_CONF" ]; then
  # shellcheck disable=SC1090
  source "$MAIN_CONF" 2>/dev/null || true
fi
if [ -f "$OPS_CONF" ]; then
  # shellcheck disable=SC1090
  source "$OPS_CONF" 2>/dev/null || true
fi

TEST=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --test) TEST=1; shift ;;
    --force) FORCE=1; shift ;;
    --help|-h)
      cat <<EOF
ms-reboot-ops.sh - timer-triggered reboot operation

Usage:
  sudo /usr/local/bin/ms-reboot-ops.sh [--test] [--force]

Notes:
  --test  : do everything except reboot (safe)
  --force : reboot even if uptime < interval (dangerous)
EOF
      exit 0
      ;;
    *) shift ;;
  esac
done

interval="${REBOOT_OPS_INTERVAL_SEC:-$INTERVAL_DEFAULT}"
enabled="${REBOOT_OPS_ENABLED:-$ENABLED_DEFAULT}"

# Also respect the existing ms-manager flag if present
if [ "${ENABLE_VPS_REBOOT:-false}" = "true" ]; then
  enabled=1
fi

# Ensure log/db files exist
mkdir -p "$CONFIG_DIR"
touch "$REBOOT_LOG_FILE" "$REBOOT_DB_FILE" 2>/dev/null || true
chmod 644 "$REBOOT_LOG_FILE" "$REBOOT_DB_FILE" 2>/dev/null || true

# Ensure DB header
if ! head -n 1 "$REBOOT_DB_FILE" 2>/dev/null | grep -q "timestamp,datetime"; then
  echo "timestamp,datetime,uptime_before,reason,interval_seconds,elapsed_since_last" > "$REBOOT_DB_FILE"
fi

if [ "$enabled" != "1" ] && [ "$enabled" != "true" ] && [ "$enabled" != "TRUE" ]; then
  log "Disabled (REBOOT_OPS_ENABLED=$enabled, ENABLE_VPS_REBOOT=${ENABLE_VPS_REBOOT:-false}). Exiting."
  exit 0
fi

uptime_sec=0
if [ -r /proc/uptime ]; then
  uptime_sec="$(awk '{print int($1)}' /proc/uptime)"
fi

# Guard against persistent timer catching up immediately after boot
if [ "$FORCE" -eq 0 ] && [ "$uptime_sec" -lt "$interval" ]; then
  log "Guard: uptime=${uptime_sec}s < interval=${interval}s. Skipping reboot."
  exit 0
fi

last_ts="$(cat "$REBOOT_TS_FILE" 2>/dev/null || echo "0")"
now="$(date +%s)"
elapsed=0
if [[ "$last_ts" =~ ^[0-9]+$ ]] && [ "$last_ts" -gt 0 ]; then
  elapsed=$((now - last_ts))
fi

reason="Scheduled reboot (systemd timer: ms-reboot-ops.timer)"
dt="$(date '+%Y-%m-%d %H:%M:%S')"

log "Reboot trigger: uptime=${uptime_sec}s interval=${interval}s elapsed_since_last=${elapsed}s test=${TEST}"

echo "[$dt] REBOOT TRIGGERED - Reason: $reason | Uptime before: ${uptime_sec}s | Interval: ${interval}s | Elapsed: ${elapsed}s" >> "$REBOOT_LOG_FILE"
echo "${now},${dt},${uptime_sec},${reason},${interval},${elapsed}" >> "$REBOOT_DB_FILE"
echo "$now" > "$REBOOT_TS_FILE"
chmod 644 "$REBOOT_TS_FILE" 2>/dev/null || true

if [ "$TEST" -eq 1 ]; then
  log "TEST mode: would reboot now, but exiting safely."
  exit 0
fi

log "Rebooting now..."
sync || true
sleep 2
/sbin/reboot
__MS_REBOOT_OPS_SH__
  chmod +x "$OPS_SCRIPT"

  # systemd service
  cat > "$SERVICE_FILE" <<'__MS_REBOOT_OPS_SERVICE__'
[Unit]
Description=MS Reboot Ops (timer-triggered reboot)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ms-reboot-ops.sh
User=root
Group=root
__MS_REBOOT_OPS_SERVICE__

  # timer (interval will be updated by menu; default 2h)
  load_conf
  local interval="${REBOOT_OPS_INTERVAL_SEC:-7200}"
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 300 ]; then
    interval=7200
  fi

  cat > "$TIMER_FILE" <<__MS_REBOOT_OPS_TIMER__
[Unit]
Description=MS Reboot Ops Timer

[Timer]
OnBootSec=${interval}s
OnUnitActiveSec=${interval}s
Persistent=true
Unit=ms-reboot-ops.service

[Install]
WantedBy=timers.target
__MS_REBOOT_OPS_TIMER__

  systemctl daemon-reload
  echo "✓ Installed ms-reboot-ops.service + ms-reboot-ops.timer"
}

set_interval() {
  load_conf
  echo ""
  echo "Enter interval like: 30m, 2h, 1h30m (only h/m supported)"
  echo "Enter 0 to disable timer + reboot ops."
  read -rp "Interval: " inp
  if ! secs="$(parse_hm_to_seconds "$inp")"; then
    echo "❌ Invalid format. Examples: 30m, 2h, 1h30m"
    return
  fi

  if [ "$secs" -eq 0 ]; then
    save_conf_kv "REBOOT_OPS_INTERVAL_SEC" "7200"
    save_conf_kv "REBOOT_OPS_ENABLED" "0"
    systemctl disable --now ms-reboot-ops.timer >/dev/null 2>&1 || true
    echo "✓ Disabled reboot ops."
    return
  fi

  # Safety floor: 5 minutes
  if [ "$secs" -lt 300 ]; then
    echo "⚠️  Too small. Minimum is 5m."
    return
  fi

  save_conf_kv "REBOOT_OPS_INTERVAL_SEC" "$secs"
  echo "✓ Saved interval: ${secs}s"

  # Rewrite timer with the new interval
  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=MS Reboot Ops Timer

[Timer]
OnBootSec=${secs}s
OnUnitActiveSec=${secs}s
Persistent=true
Unit=ms-reboot-ops.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  echo "✓ Updated ms-reboot-ops.timer interval"

  # If timer already enabled, restart to apply
  if systemctl is-enabled --quiet ms-reboot-ops.timer 2>/dev/null; then
    systemctl restart ms-reboot-ops.timer || true
  fi
}

enable_timer() {
  load_conf
  echo ""
  echo "⚠️  Precaution:"
  echo "   - This will enable AUTOMATIC REBOOTS on the configured interval."
  echo "   - Make sure you've set the correct interval first."
  echo ""
  read -rp "Type YES to enable: " ans
  if [ "$ans" != "YES" ]; then
    echo "Cancelled."
    return
  fi
  save_conf_kv "REBOOT_OPS_ENABLED" "1"
  systemctl enable --now ms-reboot-ops.timer
  echo "✓ Enabled ms-reboot-ops.timer"
}

disable_timer() {
  save_conf_kv "REBOOT_OPS_ENABLED" "0"
  systemctl disable --now ms-reboot-ops.timer >/dev/null 2>&1 || true
  echo "✓ Disabled ms-reboot-ops.timer"
}

status_view() {
  load_conf
  echo ""
  echo "Config:"
  echo "  REBOOT_OPS_ENABLED=${REBOOT_OPS_ENABLED:-0}"
  echo "  REBOOT_OPS_INTERVAL_SEC=${REBOOT_OPS_INTERVAL_SEC:-7200}"
  echo ""
  echo "systemd:"
  systemctl is-enabled ms-reboot-ops.timer 2>/dev/null && systemctl is-active ms-reboot-ops.timer 2>/dev/null || true
  echo ""
  systemctl list-timers --no-pager 2>/dev/null | grep -E "ms-reboot-ops\.timer|NEXT|LEFT" || true
  echo ""
  systemctl status ms-reboot-ops.timer --no-pager 2>/dev/null || true
  echo ""
  systemctl status ms-reboot-ops.service --no-pager 2>/dev/null || true
}

test_dry_run() {
  load_conf
  echo ""
  echo "Running SAFE test (no reboot):"
  echo "  $OPS_SCRIPT --test"
  echo ""
  "$OPS_SCRIPT" --test || true
  echo ""
  echo "Tip: Check timers with: systemctl list-timers | grep ms-reboot-ops"
}

test_real_reboot() {
  echo ""
  echo "⚠️  THIS WILL REBOOT THE SERVER NOW."
  echo "   (It starts the service immediately.)"
  echo ""
  read -rp "Type REBOOT to continue: " ans
  if [ "$ans" != "REBOOT" ]; then
    echo "Cancelled."
    return
  fi
  systemctl start ms-reboot-ops.service
}

disable_old_daemon() {
  echo ""
  echo "Disabling old reboot daemon service ($OLD_REBOOT_SERVICE)..."
  systemctl disable --now "$OLD_REBOOT_SERVICE" >/dev/null 2>&1 || true
  echo "✓ Disabled $OLD_REBOOT_SERVICE (if it existed)."
}

enable_old_daemon() {
  echo ""
  echo "Enabling old reboot daemon service ($OLD_REBOOT_SERVICE)..."
  systemctl enable --now "$OLD_REBOOT_SERVICE" >/dev/null 2>&1 || true
  echo "✓ Enabled $OLD_REBOOT_SERVICE (if it existed)."
}

main_menu() {
  warn_banner
  while true; do
    load_conf
    echo "1) Install/Update reboot ops timer files"
    echo "2) Enable reboot ops timer"
    echo "3) Disable reboot ops timer"
    echo "4) Set reboot interval (30m / 2h / 1h30m)"
    echo "5) Test (SAFE dry-run)"
    echo "6) Test (REAL reboot now)"
    echo "7) Status"
    echo "8) Disable old reboot daemon (ms-reboot.service)"
    echo "9) Enable old reboot daemon (ms-reboot.service)"
    echo "0) Exit"
    echo ""
    read -rp "Choose: " c
    case "$c" in
      1) install_ops_files; ;;
      2) install_ops_files; enable_timer; ;;
      3) disable_timer; ;;
      4) install_ops_files; set_interval; ;;
      5) install_ops_files; test_dry_run; ;;
      6) install_ops_files; test_real_reboot; ;;
      7) status_view; ;;
      8) disable_old_daemon; ;;
      9) enable_old_daemon; ;;
      0) exit 0 ;;
      *) echo "Invalid option" ;;
    esac
    echo ""
    read -rp "Press Enter to continue..." _ || true
    clear || true
    warn_banner
  done
}

need_root
main_menu
