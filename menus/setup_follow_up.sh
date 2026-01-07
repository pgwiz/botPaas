#!/bin/bash
set -euo pipefail

MENUS_DIR="/usr/local/bin/menus"
CONFIG_DIR="/etc/ms-server"
CONF_FILE="$CONFIG_DIR/follow_up.conf"
INSTANCE_GAPS_FILE="$CONFIG_DIR/follow_up_instances.conf"

FOLLOWUP_SCRIPT="/usr/local/bin/follow_up.sh"
IPV6_SCRIPT="/usr/local/bin/setup-ipv6-dns.sh"
SERVICE_FILE="/etc/systemd/system/ms-follow-up.service"
TIMER_FILE="/etc/systemd/system/ms-follow-up.timer"

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
# ms-follow-up config
FOLLOWUP_ENABLED=1

# Delay logic:
FOLLOWUP_MIN_DELAY_SEC=300
FOLLOWUP_EXTRA_DELAY_IF_MIN_ABOVE_SEC=60

# Override delay (0 means "use computed")
FOLLOWUP_DELAY_OVERRIDE_SEC=0

# Staggering for recovery starts:
FOLLOWUP_FIRST_START_GAP_SEC=30
FOLLOWUP_BETWEEN_START_GAP_SEC=90

# PM2 user context
PM2_USER=root

# Auto-update (optional)
FOLLOWUP_AUTO_UPDATE=0
FOLLOWUP_SETUP_URL=""
FOLLOWUP_SCRIPT_URL=""
EOF
        chmod 644 "$CONF_FILE"
    fi
}

ensure_instance_gaps() {
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$INSTANCE_GAPS_FILE" ]; then
        cat > "$INSTANCE_GAPS_FILE" <<'EOF'
# ms-follow-up per-instance start gaps (seconds)
# This controls the *pause after starting/restarting an instance* before moving to the next one.
# If an app isn't listed here, FOLLOWUP_BETWEEN_START_GAP_SEC is used.
#
# Example:
# declare -A FOLLOWUP_GAP_AFTER=(
#   ["api"]=30
#   ["worker"]=90
# )
declare -A FOLLOWUP_GAP_AFTER=()
EOF
        chmod 644 "$INSTANCE_GAPS_FILE"
    fi
}

load_conf() {
    ensure_conf
    ensure_instance_gaps
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

install_files() {
    echo "Installing follow-up scripts + systemd units..."

    # follow_up.sh
    cat > "$FOLLOWUP_SCRIPT" <<'__MS_FOLLOWUP_SH__'
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
    printf "[%s] %s
" "$(date '+%F %T')" "$msg" | tee -a "$LOG_FILE" >/dev/null
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
            su - "${PM2_USER}" -c "bash -lc "$cmd""
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
    run_as_pm2_user "$PM2_BIN describe "$name"" >/dev/null 2>&1
}

pm2_is_online() {
    local name="$1"
    [ -z "$PM2_BIN" ] && return 1
    run_as_pm2_user "$PM2_BIN describe "$name"" 2>/dev/null | grep -qiE 'status\s*: *online'
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
    printf "%s|%s|%s|%s|%s
" "$main_key" "$delay" "$name" "$dir" "$is_main" >> "$tmp"
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
            run_as_pm2_user "$PM2_BIN restart "$name" --update-env" || run_as_pm2_user "$PM2_BIN start "$name"" || true
            changed=1
        fi
    else
        if [ ! -d "$dir" ]; then
            log "SKIP: directory not found for $name: $dir"
            continue
        fi
        log "START: $name (dir=$dir, main=$is_main)"
        run_as_pm2_user "cd "$dir" && $PM2_BIN start . --name "$name" --time" || true
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
__MS_FOLLOWUP_SH__
    chmod +x "$FOLLOWUP_SCRIPT"

    # IPv6 script (unchanged)
    cat > "$IPV6_SCRIPT" <<'__MS_IPV6_SH__'
#!/bin/bash

# IPv6 DNS Resolver Setup Script
# Configures DNS for IPv6-only servers
# Usage: bash setup-ipv6-dns.sh

echo "===================================="
echo "IPv6 DNS Resolver Setup"
echo "===================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "⚠️  This script needs root privileges."
    echo "Please run with: sudo bash $0"
    exit 1
fi

# Backup existing resolv.conf
echo "📦 Backing up current /etc/resolv.conf..."
if [ -f /etc/resolv.conf ]; then
    cp /etc/resolv.conf /etc/resolv.conf.backup.$(date +%Y%m%d_%H%M%S)
    echo "✅ Backup created"
else
    echo "ℹ️  No existing resolv.conf found"
fi

# Configure DNS servers with NAT64/DNS64 for IPv4 connectivity
echo ""
echo "🔧 Configuring DNS64 servers (enables IPv4 site access via IPv6)..."
cat > /etc/resolv.conf <<EOF
# IPv6 DNS64 Configuration (NAT64 enabled)
# Generated by setup-ipv6-dns.sh on $(date)
# DNS64 allows IPv6-only servers to reach IPv4-only sites like GitHub

# DNS64 servers with NAT64 support
nameserver 2a01:4f8:c2c:123f::1
nameserver 2a00:1098:2b::1
nameserver 2a01:4f9:c010:3f02::1

# Fallback: Google Public DNS (IPv6)
nameserver 2001:4860:4860::8888
nameserver 2001:4860:4860::8844

# Fallback: Google Public DNS (IPv4)
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

echo "✅ DNS64 servers configured"

# Test DNS resolution
echo ""
echo "🧪 Testing DNS resolution..."
if ping -c 2 -W 3 google.com > /dev/null 2>&1; then
    echo "✅ DNS resolution working!"
else
    echo "⚠️  DNS test failed. Trying alternative configuration..."

    # Try with Cloudflare DNS
    cat > /etc/resolv.conf <<EOF
nameserver 2606:4700:4700::1111
nameserver 2606:4700:4700::1001
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF

    if ping -c 2 -W 3 google.com > /dev/null 2>&1; then
        echo "✅ DNS working with Cloudflare DNS"
    else
        echo "❌ DNS still not working. Check your network connectivity."
    fi
fi

# Make persistent (systemd-resolved)
echo ""
echo "🔒 Making DNS configuration persistent..."
if [ -f /etc/systemd/resolved.conf ]; then
    cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.backup.$(date +%Y%m%d_%H%M%S)

    cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=2001:4860:4860::8888 2001:4860:4860::8844 8.8.8.8
FallbackDNS=8.8.4.4 2606:4700:4700::1111
#DNSSEC=allow-downgrade
DNSOverTLS=no
EOF

    systemctl restart systemd-resolved 2>/dev/null
    echo "✅ systemd-resolved configured"
else
    echo "ℹ️  systemd-resolved not found, using /etc/resolv.conf only"
fi

# Prevent resolv.conf from being overwritten
if [ -L /etc/resolv.conf ]; then
    echo ""
    echo "🔗 /etc/resolv.conf is a symlink"
    echo "   Your system may overwrite DNS settings on reboot"
    echo "   To make permanent, consider unlinking:"
    echo "   sudo unlink /etc/resolv.conf"
    echo "   sudo systemctl restart systemd-resolved"
fi

echo ""
echo "===================================="
echo "✅ Setup Complete!"
echo "===================================="
echo ""
echo "Current DNS servers:"
cat /etc/resolv.conf | grep nameserver
echo ""
echo "Test your connection:"
echo "  apt-get update"
echo "  ping google.com"
echo ""
__MS_IPV6_SH__
    chmod +x "$IPV6_SCRIPT"

    # wrapper menu for IPv6
    mkdir -p "$MENUS_DIR"
    cat > "$MENUS_DIR/ipv6-dns.sh" <<'EOF'
#!/bin/bash
sudo bash /usr/local/bin/setup-ipv6-dns.sh
EOF
    chmod +x "$MENUS_DIR/ipv6-dns.sh"

    # systemd service + timer
    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=MS Manager PM2 Follow-up Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/follow_up.sh
User=root
Group=root

[Install]
WantedBy=multi-user.target
EOF

    cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=Run MS Manager PM2 Follow-up after boot

[Timer]
OnBootSec=30s
Persistent=true
Unit=ms-follow-up.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    echo "✓ Installed:"
    echo "  - $FOLLOWUP_SCRIPT"
    echo "  - $IPV6_SCRIPT"
    echo "  - $SERVICE_FILE"
    echo "  - $TIMER_FILE"
    echo "  - $INSTANCE_GAPS_FILE (per-instance gaps)"
    echo ""
}

enable_timer() {
    systemctl enable --now ms-follow-up.timer
    echo "✓ Enabled ms-follow-up.timer"
}

disable_timer() {
    systemctl disable --now ms-follow-up.timer || true
    echo "✓ Disabled ms-follow-up.timer"
}

status_timer() {
    echo ""
    systemctl status ms-follow-up.timer --no-pager || true
    echo ""
    systemctl status ms-follow-up.service --no-pager || true
    echo ""
    echo "Last log lines (/var/log/ms-follow-up.log):"
    tail -n 30 /var/log/ms-follow-up.log 2>/dev/null || true
    echo ""
}

auto_update_if_needed() {
    load_conf
    if [ "${FOLLOWUP_AUTO_UPDATE:-0}" != "1" ]; then
        return 0
    fi

    if [ -n "${FOLLOWUP_SCRIPT_URL:-}" ]; then
        echo "Auto-update: fetching follow_up.sh..."
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$FOLLOWUP_SCRIPT_URL" -o "$FOLLOWUP_SCRIPT" && chmod +x "$FOLLOWUP_SCRIPT" || true
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$FOLLOWUP_SCRIPT" "$FOLLOWUP_SCRIPT_URL" && chmod +x "$FOLLOWUP_SCRIPT" || true
        fi
    fi
}

run_followup_now() {
    echo ""
    echo "Running follow_up.sh now..."
    echo ""
    bash "$FOLLOWUP_SCRIPT" --delay 0 || true
    echo ""
    read -rp "Press Enter to continue..."
}

show_pm2_instances() {
    echo ""
    echo "Configured instances (ms-manager):"
    echo "  /etc/ms-server/pm2_instances.csv"
    echo ""
    if [ -f /etc/ms-server/pm2_instances.csv ]; then
        column -s, -t /etc/ms-server/pm2_instances.csv || cat /etc/ms-server/pm2_instances.csv
    else
        echo "(none yet)"
    fi
    echo ""
    echo "Current pm2 list:"
    pm2 list 2>/dev/null || echo "(pm2 not available or no processes)"
    echo ""
    echo "Per-instance gaps file:"
    echo "  $INSTANCE_GAPS_FILE"
    echo ""
    cat "$INSTANCE_GAPS_FILE" 2>/dev/null || true
    echo ""
    read -rp "Press Enter to continue..."
}

ms_manager_add_instance() { ms-manager -add-instance; }
ms_manager_rm_instance()  { ms-manager -rm-instance; }
ms_manager_list_instances(){ ms-manager -list-instances; read -rp "Press Enter to continue..."; }
ms_manager_start_now()     { ms-manager -start-instances-now; read -rp "Press Enter to continue..."; }

set_delay_override() {
    load_conf
    echo ""
    echo "Current override: ${FOLLOWUP_DELAY_OVERRIDE_SEC:-0} (0 = computed)"
    read -rp "Enter override delay in seconds (0 to disable override): " v
    if [[ "${v:-}" =~ ^[0-9]+$ ]]; then
        save_conf_kv "FOLLOWUP_DELAY_OVERRIDE_SEC" "$v"
        echo "✓ Saved"
    else
        echo "Invalid number."
    fi
    sleep 1
}

set_default_between_gap() {
    load_conf
    echo ""
    echo "Current default gap between instances: ${FOLLOWUP_BETWEEN_START_GAP_SEC:-90} seconds"
    read -rp "Enter new default gap in seconds: " v
    if [[ "${v:-}" =~ ^[0-9]+$ ]] && [ "$v" -ge 0 ]; then
        save_conf_kv "FOLLOWUP_BETWEEN_START_GAP_SEC" "$v"
        echo "✓ Saved"
    else
        echo "Invalid number."
    fi
    sleep 1
}

edit_instance_gap() {
    ensure_instance_gaps

    local f="/etc/ms-server/pm2_instances.csv"
    if [ ! -f "$f" ]; then
        echo ""
        echo "No instances file found at $f"
        echo "Add instances using ms-manager first."
        echo ""
        read -rp "Press Enter to continue..."
        return 0
    fi

    mapfile -t names < <(awk -F',' 'NR>1 && $1!="" {print $1}' "$f")
    if [ "${#names[@]}" -eq 0 ]; then
        echo ""
        echo "No instances found in $f"
        echo ""
        read -rp "Press Enter to continue..."
        return 0
    fi

    # load existing array
    declare -A FOLLOWUP_GAP_AFTER=()
    # shellcheck disable=SC1090
    source "$INSTANCE_GAPS_FILE" 2>/dev/null || true

    echo ""
    echo "Select instance to set the *gap after it starts/restarts*:"
    echo ""
    local i=1
    for n in "${names[@]}"; do
        local cur="${FOLLOWUP_GAP_AFTER[$n]:-}"
        if [ -z "$cur" ]; then cur="(default)"; else cur="${cur}s"; fi
        printf "  %s) %s  - current: %s
" "$i" "$n" "$cur"
        i=$((i+1))
    done
    echo ""
    read -rp "Enter number: " pick
    if ! [[ "${pick:-}" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#names[@]}" ]; then
        echo "Invalid selection."
        sleep 1
        return 0
    fi

    local sel="${names[$((pick-1))]}"
    echo ""
    echo "Selected: $sel"
    echo "Enter gap in seconds:"
    echo "  - 0 removes the per-instance override (uses default)"
    read -rp "Gap seconds: " sec

    if ! [[ "${sec:-}" =~ ^[0-9]+$ ]] || [ "$sec" -lt 0 ]; then
        echo "Invalid number."
        sleep 1
        return 0
    fi

    if [ "$sec" -eq 0 ]; then
        unset 'FOLLOWUP_GAP_AFTER[$sel]' || true
        echo "✓ Removed override for $sel"
    else
        FOLLOWUP_GAP_AFTER["$sel"]="$sec"
        echo "✓ Set $sel -> ${sec}s"
    fi

    # rewrite file
    {
        echo "# ms-follow-up per-instance start gaps (seconds)"
        echo "# Auto-generated by setup_follow_up.sh on $(date)"
        echo "declare -A FOLLOWUP_GAP_AFTER=("
        for k in $(printf '%s
' "${!FOLLOWUP_GAP_AFTER[@]}" | sort); do
            printf '  ["%s"]="%s"
' "$k" "${FOLLOWUP_GAP_AFTER[$k]}"
        done
        echo ")"
    } > "$INSTANCE_GAPS_FILE"
    chmod 644 "$INSTANCE_GAPS_FILE"

    sleep 1
}

toggle_auto_update() {
    load_conf
    if [ "${FOLLOWUP_AUTO_UPDATE:-0}" = "1" ]; then
        save_conf_kv "FOLLOWUP_AUTO_UPDATE" "0"
        echo "Auto-update: OFF"
    else
        save_conf_kv "FOLLOWUP_AUTO_UPDATE" "1"
        echo "Auto-update: ON"
    fi
    sleep 1
}

set_update_urls() {
    load_conf
    echo ""
    echo "Current FOLLOWUP_SETUP_URL : ${FOLLOWUP_SETUP_URL:-}"
    echo "Current FOLLOWUP_SCRIPT_URL: ${FOLLOWUP_SCRIPT_URL:-}"
    echo ""
    read -rp "Enter URL for setup_follow_up.sh (blank to keep): " u1
    read -rp "Enter URL for follow_up.sh (blank to keep): " u2
    if [ -n "${u1:-}" ]; then save_conf_kv "FOLLOWUP_SETUP_URL" ""$u1"" ; fi
    if [ -n "${u2:-}" ]; then save_conf_kv "FOLLOWUP_SCRIPT_URL" ""$u2"" ; fi
    echo "✓ Saved"
    sleep 1
}

main_menu() {
    while true; do
        clear
        echo "======================================="
        echo " MS Manager - PM2 Follow-up Watchdog"
        echo "======================================="
        echo ""
        echo "1) Install / Update follow-up (scripts + systemd)"
        echo "2) Enable follow-up timer (runs after reboot)"
        echo "3) Disable follow-up timer"
        echo "4) Status (timer + last run)"
        echo "5) Set boot delay override"
        echo "6) Set default gap between instance starts"
        echo "7) Set per-instance gap after start/restart"
        echo "8) Auto-update toggle"
        echo "9) Set auto-update URLs"
        echo "10) PM2 instances: add (ms-manager)"
        echo "11) PM2 instances: remove (ms-manager)"
        echo "12) PM2 instances: list (ms-manager)"
        echo "13) Start configured PM2 instances now (ms-manager)"
        echo "14) Show instances + pm2 list + per-instance gaps"
        echo "15) Run follow_up now"
        echo ""
        echo "0) Back"
        echo ""
        read -rp "Select option: " opt

        case "$opt" in
            1) install_files; ensure_conf; ensure_instance_gaps; read -rp "Press Enter to continue..." ;;
            2) enable_timer; sleep 1 ;;
            3) disable_timer; sleep 1 ;;
            4) status_timer; read -rp "Press Enter to continue..." ;;
            5) set_delay_override ;;
            6) set_default_between_gap ;;
            7) edit_instance_gap ;;
            8) toggle_auto_update ;;
            9) set_update_urls ;;
            10) ms_manager_add_instance ;;
            11) ms_manager_rm_instance ;;
            12) ms_manager_list_instances ;;
            13) ms_manager_start_now ;;
            14) show_pm2_instances ;;
            15) auto_update_if_needed; run_followup_now ;;
            0) exit 0 ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

need_root
ensure_conf
ensure_instance_gaps
auto_update_if_needed
main_menu
