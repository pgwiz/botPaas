#!/bin/bash
set -euo pipefail

CONFIG_DIR="/etc/ms-server"
INSTANCES_FILE="$CONFIG_DIR/pm2_instances.csv"
CONF_FILE="$CONFIG_DIR/follow_up.conf"
INSTANCE_GAPS_FILE="$CONFIG_DIR/follow_up_instances.conf"

LOG_FILE="/var/log/ms-follow-up.log"
IPV6_SCRIPT="/usr/local/bin/setup-ipv6-dns.sh"
PM2_BIN="$(command -v pm2 2>/dev/null || true)"

# Defaults (can be overridden by /etc/ms-server/follow_up.conf)
FOLLOWUP_MIN_DELAY_SEC_DEFAULT=300   # 5 minutes
FOLLOWUP_EXTRA_DELAY_IF_MIN_ABOVE_SEC_DEFAULT=60
FOLLOWUP_FIRST_START_GAP_SEC_DEFAULT=30
FOLLOWUP_BETWEEN_START_GAP_SEC_DEFAULT=90
PM2_USER_DEFAULT="root"

FOLLOWUP_DELAY_OVERRIDE_SEC=0
FOLLOWUP_AUTO_UPDATE=0
FOLLOWUP_SETUP_URL=""
FOLLOWUP_SCRIPT_URL=""
PM2_USER="$PM2_USER_DEFAULT"

# Per-instance gaps
declare -A FOLLOWUP_GAP_AFTER=()

log() {
    local msg="$*"
    printf "[%s] %s\n" "$(date '+%F %T')" "$msg" | tee -a "$LOG_FILE" >/dev/null
}

# Load config (if present)
if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE" 2>/dev/null || true
fi
if [ -f "$INSTANCE_GAPS_FILE" ]; then
    # shellcheck disable=SC1090
    source "$INSTANCE_GAPS_FILE" 2>/dev/null || true
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
      4) start/restart configured instances (main first), using per-instance gaps if configured
Safety:
  - Does NOT delete PM2 processes.
  - Avoids overwriting PM2 dump with an empty list.
EOF
            exit 0
            ;;
        *)
            log "Unknown argument: $1"
            shift
            ;;
    esac
done

run_as_pm2_user() {
    local cmd="$*"
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] $cmd"
        return 0
    fi

    if [ "${PM2_USER:-root}" = "root" ]; then
        bash -lc "$cmd"
    else
        if command -v sudo >/dev/null 2>&1; then
            sudo -u "${PM2_USER}" bash -lc "$cmd"
        else
            su - "${PM2_USER}" -c "bash -lc \"$cmd\""
        fi
    fi
}

pm2_online_count() {
    [ -z "$PM2_BIN" ] && { echo 0; return; }
    if command -v jq >/dev/null 2>&1; then
        run_as_pm2_user "$PM2_BIN jlist" | jq 'map(select(.pm2_env.status == "online")) | length' 2>/dev/null || echo 0
    else
        run_as_pm2_user "$PM2_BIN list" 2>/dev/null | grep -iE "\bonline\b" | wc -l | tr -d ' '
    fi
}

pm2_total_count() {
    [ -z "$PM2_BIN" ] && { echo 0; return; }
    if command -v jq >/dev/null 2>&1; then
        run_as_pm2_user "$PM2_BIN jlist" | jq 'length' 2>/dev/null || echo 0
    else
        # crude fallback: count lines with a pipe-delimited row (pm2 list table)
        run_as_pm2_user "$PM2_BIN list" 2>/dev/null | grep -E '^│' | grep -vE 'status|App name|id' | wc -l | tr -d ' '
    fi
}

pm2_has_process() {
    local name="$1"
    [ -z "$PM2_BIN" ] && return 1
    run_as_pm2_user "$PM2_BIN describe \"$name\"" >/dev/null 2>&1
}

pm2_is_online() {
    local name="$1"
    [ -z "$PM2_BIN" ] && return 1
    run_as_pm2_user "$PM2_BIN describe \"$name\"" 2>/dev/null | grep -qiE 'status\s*: *online'
}

pm2_home_dir() {
    [ -z "$PM2_BIN" ] && { echo ""; return; }
    run_as_pm2_user 'echo "${PM2_HOME:-$HOME/.pm2}"' 2>/dev/null | tail -n1
}

backup_pm2_dump() {
    local home dump
    home="$(pm2_home_dir || true)"
    [ -z "$home" ] && return 0
    dump="${home%/}/dump.pm2"
    if [ -f "$dump" ]; then
        local b="${dump}.backup.$(date +%Y%m%d_%H%M%S)"
        log "Backing up PM2 dump: $dump -> $b"
        [ "$DRY_RUN" -eq 0 ] && cp -a "$dump" "$b" || true
    fi
}

safe_pm2_save() {
    [ -z "$PM2_BIN" ] && return 0
    local total
    total="$(pm2_total_count || echo 0)"
    if [ "${total:-0}" -ge 1 ]; then
        backup_pm2_dump || true
        log "Saving PM2 process list..."
        run_as_pm2_user "$PM2_BIN save" || true
    else
        log "Skipping pm2 save: PM2 list is empty (prevents overwriting dump with nothing)."
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

# Determine minimum saved delay from instances file
min_saved_delay=""
if [ -f "$INSTANCES_FILE" ]; then
    while IFS=',' read -r name dir delay is_main; do
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
extra_if_min_above="${FOLLOWUP_EXTRA_DELAY_IF_MIN_ABOVE_SEC:-$FOLLOWUP_EXTRA_DELAY_IF_MIN_ABOVE_SEC_DEFAULT}"
delay_override="${FOLLOWUP_DELAY_OVERRIDE_SEC:-0}"
first_gap="${FOLLOWUP_FIRST_START_GAP_SEC:-$FOLLOWUP_FIRST_START_GAP_SEC_DEFAULT}"
between_gap="${FOLLOWUP_BETWEEN_START_GAP_SEC:-$FOLLOWUP_BETWEEN_START_GAP_SEC_DEFAULT}"

# normalize numeric inputs (guard against bad config or CRLF)
if ! [[ "$min_delay" =~ ^[0-9]+$ ]]; then min_delay=0; fi
if ! [[ "$extra_if_min_above" =~ ^[0-9]+$ ]]; then extra_if_min_above=0; fi
if ! [[ "$delay_override" =~ ^[0-9]+$ ]]; then delay_override=0; fi
if ! [[ "$first_gap" =~ ^[0-9]+$ ]]; then first_gap=0; fi
if ! [[ "$between_gap" =~ ^[0-9]+$ ]]; then between_gap=0; fi

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

if ! [[ "$computed_delay" =~ ^[0-9]+$ ]]; then
    computed_delay=0
fi
if ! [[ "$uptime_sec" =~ ^[0-9]+$ ]]; then
    uptime_sec=0
fi

if [ "$uptime_sec" -lt "$computed_delay" ]; then
    sleep_for=$((computed_delay - uptime_sec))
    log "Waiting ${sleep_for}s (uptime=${uptime_sec}s, target=${computed_delay}s)..."
    [ "$DRY_RUN" -eq 0 ] && sleep "$sleep_for" || true
else
    log "No wait needed (uptime=${uptime_sec}s, target=${computed_delay}s)."
fi

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

log "Waiting ${first_gap}s before attempting PM2 recovery..."
[ "$DRY_RUN" -eq 0 ] && sleep "$first_gap" || true

changed=0

# Try pm2 resurrect first
if [ -n "$PM2_BIN" ]; then
    log "Attempting pm2 resurrect..."
    run_as_pm2_user "$PM2_BIN resurrect" || true
    changed=1
fi

online="$(pm2_online_count || echo 0)"
if [ "${online:-0}" -ge 1 ]; then
    log "OK: PM2 came online after resurrect (${online})."
    safe_pm2_save || true
    show_pm2_list
    exit 0
fi

# Start/restart instances from ms-manager CSV (main first)
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

log "Starting/restarting configured PM2 instances (main first)."
log "NOTE: This script will NOT delete any PM2 process. It only starts/restarts if needed."

for row in "${ordered[@]}"; do
    IFS='|' read -r main_key delay name dir is_main <<<"$row"
    [ -z "${name:-}" ] && continue
    [ -z "${dir:-}" ] && continue

    # determine per-instance gap after start/restart
    gap_after="$between_gap"
    if [ -n "${FOLLOWUP_GAP_AFTER[$name]:-}" ] && [[ "${FOLLOWUP_GAP_AFTER[$name]}" =~ ^[0-9]+$ ]]; then
        gap_after="${FOLLOWUP_GAP_AFTER[$name]}"
    fi

    if pm2_has_process "$name"; then
        if pm2_is_online "$name"; then
            log "SKIP: $name already exists and is online."
        else
            log "RESTART: $name exists but is not online."
            run_as_pm2_user "$PM2_BIN restart \"$name\" --update-env" || run_as_pm2_user "$PM2_BIN start \"$name\"" || true
            changed=1
        fi
    else
        if [ ! -d "$dir" ]; then
            log "SKIP: directory not found for $name: $dir"
            continue
        fi
        log "START: $name (dir=$dir, main=$is_main)"
        run_as_pm2_user "cd \"$dir\" && $PM2_BIN start . --name \"$name\" --time" || true
        changed=1
    fi

    log "Waiting ${gap_after}s before next instance..."
    [ "$DRY_RUN" -eq 0 ] && sleep "$gap_after" || true
done

if [ "$changed" -eq 1 ]; then
    safe_pm2_save || true
else
    log "No changes made; skipping pm2 save."
fi

online="$(pm2_online_count || echo 0)"
if [ "${online:-0}" -ge 1 ]; then
    log "OK: PM2 is online after follow-up (${online})."
    show_pm2_list
    exit 0
fi

log "FAIL: Still no PM2 online processes after follow-up actions."
show_pm2_list
exit 1
