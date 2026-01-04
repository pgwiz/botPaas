#!/bin/bash
set -euo pipefail

CONFIG_DIR="/etc/ms-server"
INSTANCES_FILE="$CONFIG_DIR/pm2_instances.csv"
CONF_FILE="$CONFIG_DIR/follow_up.conf"
LOG_FILE="/var/log/ms-follow-up.log"
IPV6_SCRIPT="/usr/local/bin/setup-ipv6-dns.sh"
PM2_BIN="$(command -v pm2 2>/dev/null || true)"

# Defaults (can be overridden by /etc/ms-server/follow_up.conf)
FOLLOWUP_MIN_DELAY_SEC_DEFAULT=300   # 5 minutes
FOLLOWUP_EXTRA_DELAY_IF_MIN_ABOVE_SEC=60
FOLLOWUP_FIRST_START_GAP_SEC_DEFAULT=30
FOLLOWUP_BETWEEN_START_GAP_SEC_DEFAULT=90
PM2_USER_DEFAULT="root"

FOLLOWUP_DELAY_OVERRIDE_SEC=0
FOLLOWUP_AUTO_UPDATE=0
FOLLOWUP_SETUP_URL=""
FOLLOWUP_SCRIPT_URL=""
PM2_USER="$PM2_USER_DEFAULT"

log() {
    local msg="$*"
    printf "[%s] %s\n" "$(date '+%F %T')" "$msg" | tee -a "$LOG_FILE" >/dev/null
}

# Load config (if present)
if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE" 2>/dev/null || true
fi

# Arg parsing
DELAY_OVERRIDE_ARG=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --delay)
            DELAY_OVERRIDE_ARG="${2:-}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --help|-h)
            cat <<EOF
follow_up.sh - PM2 follow-up watchdog

Usage:
  sudo /usr/local/bin/follow_up.sh [--delay <seconds>] [--dry-run]

Behavior:
  - Wait until at least 5 minutes after boot (or computed delay).
  - If no PM2 process is online:
      1) run IPv6 DNS setup twice
      2) wait 30s
      3) try pm2 resurrect
      4) start configured instances (main first), waiting 90s between starts
EOF
            exit 0
            ;;
        *)
            log "Unknown argument: $1"
            shift
            ;;
    esac
done

# Determine minimum saved delay from instances file
min_saved_delay=""
if [ -f "$INSTANCES_FILE" ]; then
    while IFS=',' read -r name dir delay is_main; do
        # skip header or empty lines
        [ "$name" = "name" ] && continue
        [ -z "${name:-}" ] && continue
        if [[ "${delay:-}" =~ ^[0-9]+$ ]]; then
            if [ -z "$min_saved_delay" ] || [ "$delay" -lt "$min_saved_delay" ]; then
                min_saved_delay="$delay"
            fi
        fi
    done < "$INSTANCES_FILE"
fi

min_delay="${FOLLOWUP_MIN_DELAY_SEC:-$FOLLOWUP_MIN_DELAY_SEC_DEFAULT}"
extra_if_min_above="${FOLLOWUP_EXTRA_DELAY_IF_MIN_ABOVE_SEC:-$FOLLOWUP_EXTRA_DELAY_IF_MIN_ABOVE_SEC}"
delay_override="${FOLLOWUP_DELAY_OVERRIDE_SEC:-0}"
first_gap="${FOLLOWUP_FIRST_START_GAP_SEC:-$FOLLOWUP_FIRST_START_GAP_SEC_DEFAULT}"
between_gap="${FOLLOWUP_BETWEEN_START_GAP_SEC:-$FOLLOWUP_BETWEEN_START_GAP_SEC_DEFAULT}"
pm2_user="${PM2_USER:-$PM2_USER_DEFAULT}"

# delay override via arg beats config
if [ -n "$DELAY_OVERRIDE_ARG" ] && [[ "$DELAY_OVERRIDE_ARG" =~ ^[0-9]+$ ]]; then
    delay_override="$DELAY_OVERRIDE_ARG"
fi

computed_delay="$min_delay"
if [ "$delay_override" != "0" ] && [[ "$delay_override" =~ ^[0-9]+$ ]]; then
    computed_delay="$delay_override"
else
    if [ -n "$min_saved_delay" ] && [ "$min_saved_delay" -gt "$min_delay" ]; then
        computed_delay=$((min_saved_delay + extra_if_min_above))
    fi
fi

uptime_sec=0
if [ -r /proc/uptime ]; then
    uptime_sec="$(awk '{print int($1)}' /proc/uptime)"
fi

if [ "$uptime_sec" -lt "$computed_delay" ]; then
    sleep_for=$((computed_delay - uptime_sec))
    log "Waiting ${sleep_for}s (uptime=${uptime_sec}s, target=${computed_delay}s)..."
    if [ "$DRY_RUN" -eq 0 ]; then
        sleep "$sleep_for"
    fi
else
    log "No wait needed (uptime=${uptime_sec}s, target=${computed_delay}s)."
fi

run_as_pm2_user() {
    local cmd="$*"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] $cmd"
        return 0
    fi

    if [ "$pm2_user" = "root" ]; then
        bash -lc "$cmd"
    else
        if command -v sudo >/dev/null 2>&1; then
            sudo -u "$pm2_user" bash -lc "$cmd"
        else
            su - "$pm2_user" -c "bash -lc \"$cmd\""
        fi
    fi
}

pm2_online_count() {
    [ -z "$PM2_BIN" ] && { echo 0; return; }

    if command -v jq >/dev/null 2>&1; then
        # pm2 jlist is JSON; count entries with status == online
        run_as_pm2_user "$PM2_BIN jlist" | jq 'map(select(.pm2_env.status == \"online\")) | length' 2>/dev/null || echo 0
    else
        # best-effort parse of pm2 list output
        run_as_pm2_user "$PM2_BIN list" 2>/dev/null | grep -iE "\bonline\b" | wc -l | tr -d ' '
    fi
}

show_pm2_list() {
    [ -z "$PM2_BIN" ] && { log "pm2 not found in PATH"; return; }
    log "PM2 list:"
    if [ "$DRY_RUN" -eq 0 ]; then
        run_as_pm2_user "$PM2_BIN list" | sed 's/^/[pm2] /' | tee -a "$LOG_FILE" >/dev/null || true
    else
        log "[dry-run] $PM2_BIN list"
    fi
}

online="$(pm2_online_count || echo 0)"
if [ "${online:-0}" -ge 1 ]; then
    log "OK: PM2 has at least one online process (${online})."
    show_pm2_list
    exit 0
fi

log "WARN: No PM2 online processes detected."

# Run IPv6 DNS setup twice (best effort)
if [ -x "$IPV6_SCRIPT" ]; then
    log "Running IPv6 DNS setup (1/2)..."
    [ "$DRY_RUN" -eq 0 ] && bash "$IPV6_SCRIPT" >>"$LOG_FILE" 2>&1 || log "[dry-run] bash $IPV6_SCRIPT"
    log "Running IPv6 DNS setup (2/2)..."
    [ "$DRY_RUN" -eq 0 ] && bash "$IPV6_SCRIPT" >>"$LOG_FILE" 2>&1 || log "[dry-run] bash $IPV6_SCRIPT"
else
    log "IPv6 script not found/executable at $IPV6_SCRIPT"
fi

log "Waiting ${first_gap}s before starting PM2 instances..."
[ "$DRY_RUN" -eq 0 ] && sleep "$first_gap" || true

# Try pm2 resurrect first
if [ -n "$PM2_BIN" ]; then
    log "Attempting pm2 resurrect..."
    run_as_pm2_user "$PM2_BIN resurrect" || true
fi

online="$(pm2_online_count || echo 0)"
if [ "${online:-0}" -ge 1 ]; then
    log "OK: PM2 came online after resurrect (${online})."
    show_pm2_list
    exit 0
fi

# Start instances from ms-manager CSV (main first)
if [ ! -f "$INSTANCES_FILE" ]; then
    log "No instances file found at $INSTANCES_FILE. Nothing to start."
    show_pm2_list
    exit 1
fi

tmp="/tmp/ms-follow-up.instances.$$"
rm -f "$tmp"
touch "$tmp"

# Build sortable list: mainKey|delay|name|dir|is_main
while IFS=',' read -r name dir delay is_main; do
    [ "$name" = "name" ] && continue
    [ -z "${name:-}" ] && continue
    delay="${delay:-0}"
    is_main="${is_main:-false}"
    main_key="1"
    if [ "$is_main" = "true" ] || [ "$is_main" = "TRUE" ]; then
        main_key="0"
    fi
    printf "%s|%s|%s|%s|%s\n" "$main_key" "$delay" "$name" "$dir" "$is_main" >> "$tmp"
done < "$INSTANCES_FILE"

# Sort by main then delay numeric
mapfile -t ordered < <(sort -t'|' -k1,1 -k2,2n "$tmp" 2>/dev/null || cat "$tmp")
rm -f "$tmp"

if [ "${#ordered[@]}" -eq 0 ]; then
    log "Instances file exists but contains no instances."
    exit 1
fi

log "Starting configured PM2 instances (main first)..."

idx=0
for row in "${ordered[@]}"; do
    IFS='|' read -r main_key delay name dir is_main <<<"$row"
    if [ -z "$name" ] || [ -z "$dir" ]; then
        continue
    fi

    if [ ! -d "$dir" ]; then
        log "SKIP: directory not found for $name: $dir"
        continue
    fi

    log "Starting: $name (dir=$dir, delay=$delay, main=$is_main)"
    run_as_pm2_user "cd \"$dir\" && $PM2_BIN start . --name \"$name\" --time" || true
    run_as_pm2_user "$PM2_BIN save --force" || true

    idx=$((idx + 1))
    log "Waiting ${between_gap}s before next instance..."
    [ "$DRY_RUN" -eq 0 ] && sleep "$between_gap" || true
done

online="$(pm2_online_count || echo 0)"
if [ "${online:-0}" -ge 1 ]; then
    log "OK: PM2 is online after follow-up (${online})."
    show_pm2_list
    exit 0
fi

log "FAIL: Still no PM2 online processes after follow-up actions."
show_pm2_list
exit 1
