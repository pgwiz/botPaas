#!/bin/bash

# MS Server Manager Installation Script - Enhanced Version (multi-PM2 instance support + SIGHUP-aware reboot daemon)
# v3.3
set -e

SCRIPT_DIR="/usr/local/bin"
CONFIG_DIR="/etc/ms-server"
SERVICE_NAME="ms-server"
MANAGER_SCRIPT="$SCRIPT_DIR/ms-manager"
REBOOT_TIMESTAMP_FILE="$CONFIG_DIR/last_reboot_timestamp"
REBOOT_LOG_FILE="$CONFIG_DIR/reboot_history.log"
REBOOT_DB_FILE="$CONFIG_DIR/reboot_database.csv"
REBOOT_DAEMON="$SCRIPT_DIR/ms-reboot-daemon.sh"
REBOOT_SERVICE="ms-reboot.service"
REBOOT_VAR_DIR="/var/lib/ms-manager"
PM2_INSTANCES_FILE="$CONFIG_DIR/pm2_instances.csv"

echo "==================================="
echo "  MS Server Manager Installation"
echo "      Enhanced Version v3.3"
echo "==================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Create config directory
mkdir -p "$CONFIG_DIR"

# Initialize reboot tracking files
touch "$REBOOT_LOG_FILE"
chmod 644 "$REBOOT_LOG_FILE"

# Initialize reboot database with header if it doesn't exist
if [ ! -f "$REBOOT_DB_FILE" ]; then
    echo "timestamp,datetime,uptime_before,reason,interval_seconds,elapsed_since_last" > "$REBOOT_DB_FILE"
    chmod 644 "$REBOOT_DB_FILE"
fi

# Create default configuration file (only if it doesn't exist)
if [ ! -f "$CONFIG_DIR/config.conf" ]; then
    cat > "$CONFIG_DIR/config.conf" <<'EOF'
# MS Server Configuration
RESTART_INTERVAL=7200
WORKING_DIR=/root/ms
IPV6_SCRIPT=/root/ipv6.sh
ENABLE_AUTO_RESTART=true
CUSTOM_COMMANDS=""
ENABLE_VPS_REBOOT=false
ENABLE_UPDATE_ON_BOOT=true
# Default delay for non-main PM2 instances (seconds)
PM2_INSTANCES_DELAY_DEFAULT=300
EOF
    echo "✓ Configuration file created at $CONFIG_DIR/config.conf"
else
    echo "✓ Configuration file already exists, preserving settings"
fi

# Ensure pm2 instances file exists (CSV header)
if [ ! -f "$PM2_INSTANCES_FILE" ]; then
    echo "name,working_dir,delay_seconds,is_main" > "$PM2_INSTANCES_FILE"
    chmod 644 "$PM2_INSTANCES_FILE"
    echo "✓ PM2 instances file created at $PM2_INSTANCES_FILE"
else
    echo "✓ PM2 instances file already exists, preserving entries"
fi

# Ensure var dir for reboot daemon exists
mkdir -p "$REBOOT_VAR_DIR"
chmod 755 "$REBOOT_VAR_DIR"

#
# Create the main service script (ms-server-run.sh)
#
cat > "$SCRIPT_DIR/ms-server-run.sh" <<'EOF'
#!/bin/bash

# Load configuration
source /etc/ms-server/config.conf

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/ms-server.log
}

log_reboot() {
    local timestamp=$(date +%s)
    local datetime=$(date '+%Y-%m-%d %H:%M:%S')
    local uptime_sec=0
    local reason="$1"
    local interval="$2"
    local elapsed="$3"

    if command -v awk >/dev/null 2>&1 && [ -r /proc/uptime ]; then
        uptime_sec=$(awk '{print int($1)}' /proc/uptime)
    fi

    echo "[$datetime] REBOOT TRIGGERED - Reason: $reason | Uptime before: ${uptime_sec}s | Interval: ${interval}s | Elapsed: ${elapsed}s" >> /etc/ms-server/reboot_history.log
    echo "$timestamp,$datetime,$uptime_sec,$reason,$interval,$elapsed" >> /etc/ms-server/reboot_database.csv
    log_message "Reboot logged to database: $reason (uptime: ${uptime_sec}s)"
}

log_message "=== MS Server Starting ==="

# Record actual boot time (when system came back up)
BOOT_TIMESTAMP_FILE="/etc/ms-server/actual_boot_timestamp"
CURRENT_BOOT_TIME=$(date +%s)

if command -v awk >/dev/null 2>&1 && [ -r /proc/uptime ]; then
    UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
else
    UPTIME_SEC=0
fi

if [ "$UPTIME_SEC" -lt 120 ]; then
    log_message "Fresh boot detected (uptime: ${UPTIME_SEC}s). Recording boot time: $CURRENT_BOOT_TIME"
    echo "$CURRENT_BOOT_TIME" > "$BOOT_TIMESTAMP_FILE"

    if [ -f "/etc/ms-server/last_reboot_timestamp" ]; then
        LAST_REBOOT_TRIGGER=$(cat "/etc/ms-server/last_reboot_timestamp" 2>/dev/null || echo "0")
        if [ "$LAST_REBOOT_TRIGGER" != "0" ]; then
            BOOT_DURATION=$((CURRENT_BOOT_TIME - LAST_REBOOT_TRIGGER))
            log_message "System was down for ${BOOT_DURATION}s (reboot duration)"
        fi
    fi
fi

# Change to root directory
cd /root

# Check if IPv6 script exists, if not download it
if [ ! -f "$IPV6_SCRIPT" ]; then
    log_message "IPv6 script not found at $IPV6_SCRIPT, downloading..."
    if wget -O "$IPV6_SCRIPT" "https://raw.githubusercontent.com/pgwiz/ipv6-vps-dns-resolver/refs/heads/main/ip6res.sh" 2>&1 | tee -a /var/log/ms-server.log; then
        chmod +x "$IPV6_SCRIPT"
        log_message "✓ IPv6 script downloaded successfully"
    else
        log_message "⚠ Failed to download IPv6 script, attempting with curl..."
        if curl -o "$IPV6_SCRIPT" "https://raw.githubusercontent.com/pgwiz/ipv6-vps-dns-resolver/refs/heads/main/ip6res.sh" 2>&1 | tee -a /var/log/ms-server.log; then
            chmod +x "$IPV6_SCRIPT"
            log_message "✓ IPv6 script downloaded successfully with curl"
        else
            log_message "✗ Failed to download IPv6 script"
            log_message "Please manually download from: https://raw.githubusercontent.com/pgwiz/ipv6-vps-dns-resolver/refs/heads/main/ip6res.sh"
        fi
    fi
fi

# IPv6 connectivity check helpers
check_ipv6() {
    ping6 -c 2 -w 5 github.com >/dev/null 2>&1 && \
    ping6 -c 2 -w 5 gist.github.com >/dev/null 2>&1
}

ensure_ipv6() {
    if check_ipv6; then
        log_message "✓ IPv6 connectivity confirmed (github.com & gist.github.com)"
        return 0
    fi

    log_message "Attempting IPv6 setup (1/2) via $IPV6_SCRIPT..."
    sudo chmod +x "$IPV6_SCRIPT" 2>/dev/null || true
    sudo "$IPV6_SCRIPT" 2>&1 | tee -a /var/log/ms-server.log || true
    sleep 2

    if check_ipv6; then
        log_message "✓ IPv6 connectivity confirmed after setup (1/2)"
        return 0
    fi

    log_message "Attempting IPv6 setup (2/2) via $IPV6_SCRIPT..."
    sudo chmod +x "$IPV6_SCRIPT" 2>/dev/null || true
    sudo "$IPV6_SCRIPT" 2>&1 | tee -a /var/log/ms-server.log || true
    sleep 2

    if check_ipv6; then
        log_message "✓ IPv6 connectivity confirmed after setup (2/2)"
        return 0
    else
        log_message "⚠ IPv6 still not confirmed after two setup attempts; proceeding anyway"
        return 1
    fi
}

# Ensure IPv6 connectivity before starting application
ensure_ipv6

# Run custom commands if any
if [ -n "$CUSTOM_COMMANDS" ]; then
    log_message "Running custom commands..."
    eval "$CUSTOM_COMMANDS" 2>&1 | tee -a /var/log/ms-server.log
fi

# Attempt to read pm2 instances configuration
PM2_INSTANCES_FILE="/etc/ms-server/pm2_instances.csv"

# Fresh PM2 start - stop and delete all instances
log_message "Cleaning up all PM2 processes for fresh start..."
pm2 delete all 2>/dev/null || true
pm2 kill 2>/dev/null || true
sleep 2

log_message "Starting fresh PM2 daemon..."
pm2 ping 2>/dev/null || true

# Load PM2 instances and start them properly:
if [ -f "$PM2_INSTANCES_FILE" ]; then
    # Read CSV (skip header)
    mapfile -t lines < <(tail -n +2 "$PM2_INSTANCES_FILE" 2>/dev/null | sed '/^\s*$/d')

    if [ "${#lines[@]}" -eq 0 ]; then
        # No instances configured: fallback to working dir
        log_message "No PM2 instances configured. Starting default app in $WORKING_DIR"
        cd "$WORKING_DIR" 2>/dev/null || true
        pm2 start . --name ms --time 2>&1 | tee -a /var/log/ms-server.log || true
        pm2 save --force 2>/dev/null || true
    else
        # Parse entries into arrays
        names=()
        dirs=()
        delays=()
        is_main_idx=-1
        for i in "${!lines[@]}"; do
            IFS=',' read -r name dir delay is_main <<< "${lines[$i]}"
            # trim whitespace
            name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            dir=$(echo "$dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            delay=$(echo "$delay" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            is_main=$(echo "$is_main" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

            # default delay fallback
            if [ -z "$delay" ] || ! [[ "$delay" =~ ^[0-9]+$ ]]; then
                delay="$PM2_INSTANCES_DELAY_DEFAULT"
            fi

            names+=("$name")
            dirs+=("$dir")
            delays+=("$delay")

            if [ "$is_main" = "true" ] || [ "$is_main" = "1" ] || [ "$is_main" = "yes" ]; then
                is_main_idx=$i
            fi
        done

        # If no main specified, use first
        if [ "$is_main_idx" -lt 0 ]; then
            is_main_idx=0
        fi

        # Start main immediately
        MAIN_NAME="${names[$is_main_idx]}"
        MAIN_DIR="${dirs[$is_main_idx]}"
        if [ -d "$MAIN_DIR" ]; then
            log_message "Starting MAIN PM2 instance: $MAIN_NAME in $MAIN_DIR"
            cd "$MAIN_DIR" || true
            pm2 start . --name "$MAIN_NAME" --time 2>&1 | tee -a /var/log/ms-server.log || true
            pm2 save --force 2>/dev/null || true
        else
            log_message "⚠ MAIN PM2 dir not found: $MAIN_DIR - skipping MAIN instance"
        fi

        # Start other instances with their configured delays (in background)
        for i in "${!names[@]}"; do
            if [ "$i" -eq "$is_main_idx" ]; then
                continue
            fi
            NAME="${names[$i]}"
            DIR="${dirs[$i]}"
            DELAY="${delays[$i]}"

            if [ ! -d "$DIR" ]; then
                log_message "⚠ PM2 instance dir not found: $DIR - skipping $NAME"
                continue
            fi

            log_message "Scheduling PM2 instance '$NAME' to start in ${DELAY}s (dir: $DIR)"
            (
                sleep "$DELAY"
                cd "$DIR" || exit 0
                log_message "Starting delayed PM2 instance: $NAME (after ${DELAY}s)"
                pm2 start . --name "$NAME" --time 2>&1 | tee -a /var/log/ms-server.log || true
                pm2 save --force 2>/dev/null || true
            ) &
        done
    fi
else
    # fallback behavior
    log_message "No PM2 instances configuration file found - starting default app in $WORKING_DIR"
    cd "$WORKING_DIR" 2>/dev/null || true
    pm2 start . --name ms --time 2>&1 | tee -a /var/log/ms-server.log || true
    pm2 save --force 2>/dev/null || true
fi

log_message "=== MS Server Started Successfully (Fresh Start) ==="

# On-boot self-update (optional)
if [ "${ENABLE_UPDATE_ON_BOOT}" = "true" ]; then
    if command -v awk >/dev/null 2>&1 && [ -r /proc/uptime ]; then
        UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
    else
        UPTIME_SEC=0
    fi

    if [ "$UPTIME_SEC" -lt 600 ]; then
        log_message "Update on boot enabled and uptime=${UPTIME_SEC}s (<600). Attempting update..."
        UPDATE_URL="https://raw.githubusercontent.com/pgwiz/botPaas/refs/heads/main/install-ms-manager.sh"
        TMP_FILE="/tmp/install-ms-manager.sh"
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL "$UPDATE_URL" -o "$TMP_FILE"; then
                chmod +x "$TMP_FILE"
                log_message "Running on-boot update script..."
                bash "$TMP_FILE" || log_message "On-boot update script exited with non-zero status"
            else
                log_message "Failed to download update via curl"
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -qO "$TMP_FILE" "$UPDATE_URL"; then
                chmod +x "$TMP_FILE"
                log_message "Running on-boot update script..."
                bash "$TMP_FILE" || log_message "On-boot update script exited with non-zero status"
            else
                log_message "Failed to download update via wget"
            fi
        else
            log_message "Neither curl nor wget available for on-boot update"
        fi
    else
        log_message "Update on boot enabled but uptime=${UPTIME_SEC}s (>=600); skipping"
    fi
fi

log_message "Service startup completed, exiting..."
exit 0
EOF

chmod +x "$SCRIPT_DIR/ms-server-run.sh"
echo "✓ Service script created at $SCRIPT_DIR/ms-server-run.sh"

#
# Create the systemd service & timer
#
cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=MS Server with Auto-restart
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/ms-server-run.sh
User=root
WorkingDirectory=/root
StandardOutput=append:/var/log/ms-server.log
StandardError=append:/var/log/ms-server.log

[Install]
WantedBy=multi-user.target
EOF

echo "✓ Systemd service created"

cat > "/etc/systemd/system/$SERVICE_NAME.timer" <<EOF
[Unit]
Description=MS Server Restart Timer
Requires=$SERVICE_NAME.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=7200s
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "✓ Systemd timer created"

#
# Create the reboot daemon (botpas-style) with SIGHUP support
#
cat > "$REBOOT_DAEMON" <<'DAEMON_EOF'
#!/bin/bash

# ms-reboot-daemon - persistent reboot daemon (botpas-style)
INTERVAL_FILE="/var/lib/ms-manager/interval"
START_TIME_FILE="/var/lib/ms-manager/start_time"
REBOOT_TS_FILE="/etc/ms-server/last_reboot_timestamp"
REBOOT_LOG_FILE="/etc/ms-server/reboot_history.log"
REBOOT_DB_FILE="/etc/ms-server/reboot_database.csv"
CONFIG_FILE="/etc/ms-server/config.conf"
DEFAULT_INTERVAL=7200  # 2 hours

mkdir -p /var/lib/ms-manager
chmod 755 /var/lib/ms-manager

touch "$REBOOT_LOG_FILE" 2>/dev/null || true
touch "$REBOOT_DB_FILE" 2>/dev/null || true
chmod 644 "$REBOOT_LOG_FILE" "$REBOOT_DB_FILE" || true

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> /var/log/ms-reboot-daemon.log
}

# Initialize interval if not set
if [ ! -f "$INTERVAL_FILE" ]; then
    echo "$DEFAULT_INTERVAL" > "$INTERVAL_FILE"
fi

# Keep track of sleep PID for SIGHUP handling
SLEEP_PID=""

handle_sighup() {
    log "ms-reboot-daemon: SIGHUP received - reloading interval and restarting countdown"
    if [ -f "$INTERVAL_FILE" ]; then
        NEW_INTERVAL=$(cat "$INTERVAL_FILE" 2>/dev/null || echo "$DEFAULT_INTERVAL")
    else
        NEW_INTERVAL=$DEFAULT_INTERVAL
    fi
    INTERVAL="$NEW_INTERVAL"
    date +%s > "$START_TIME_FILE"
    chmod 644 "$START_TIME_FILE"
    # Interrupt the current sleep so we pick up new interval immediately
    if [ -n "$SLEEP_PID" ]; then
        kill "$SLEEP_PID" 2>/dev/null || true
    fi
}

# Arrange SIGHUP trap
trap 'handle_sighup' SIGHUP

while true; do
    if [ -f "$INTERVAL_FILE" ]; then
        INTERVAL=$(cat "$INTERVAL_FILE" 2>/dev/null || echo "$DEFAULT_INTERVAL")
    else
        INTERVAL=$DEFAULT_INTERVAL
    fi

    # Write start time for countdown tools
    date +%s > "$START_TIME_FILE"
    chmod 644 "$START_TIME_FILE"

    minutes=$((INTERVAL / 60))
    log "ms-reboot-daemon: Starting countdown for ${INTERVAL}s (${minutes}m)"

    # Start sleep in background so SIGHUP handler can kill it
    sleep "$INTERVAL" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""

    # After sleep completes (or was killed), check config to see if reboot is enabled
    ENABLE_REBOOT="false"
    if [ -f "$CONFIG_FILE" ]; then
        ENABLE_REBOOT=$(awk -F= '/^ENABLE_VPS_REBOOT/ { gsub(/"/,"",$2); print $2 }' "$CONFIG_FILE" 2>/dev/null | tr -d ' ')
    fi

    if [ "$ENABLE_REBOOT" = "true" ]; then
        CURRENT_TIME=$(date +%s)
        LAST_REBOOT_TIME=$(cat "$REBOOT_TS_FILE" 2>/dev/null || echo "0")
        if [ "$LAST_REBOOT_TIME" = "" ]; then LAST_REBOOT_TIME=0; fi
        ELAPSED=$((CURRENT_TIME - LAST_REBOOT_TIME))

        DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
        if [ -r /proc/uptime ]; then
            UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
        else
            UPTIME_SEC=0
        fi

        echo "[$DATETIME] REBOOT TRIGGERED - Reason: Scheduled periodic reboot | Uptime before: ${UPTIME_SEC}s | Interval: ${INTERVAL}s | Elapsed: ${ELAPSED}s" >> "$REBOOT_LOG_FILE"
        echo "${CURRENT_TIME},${DATETIME},${UPTIME_SEC},Scheduled periodic reboot,${INTERVAL},${ELAPSED}" >> "$REBOOT_DB_FILE"

        echo "$CURRENT_TIME" > "$REBOOT_TS_FILE"
        chmod 644 "$REBOOT_TS_FILE"
        sync

        log "ms-reboot-daemon: Rebooting system now (scheduled). Interval=${INTERVAL}s, elapsed=${ELAPSED}s"

        sync
        sleep 1
        sync

        (sleep 2 && /sbin/reboot) &

        # Sleep a bit so logs can be written before the system reboots
        sleep 5
    else
        log "ms-reboot-daemon: Reboot disabled in config, skipping reboot"
    fi
done
DAEMON_EOF

chmod +x "$REBOOT_DAEMON"
echo "✅ Reboot daemon created at $REBOOT_DAEMON"

cat > "/etc/systemd/system/$REBOOT_SERVICE" <<EOF
[Unit]
Description=MS Reboot Daemon (persistent scheduled reboot)
After=network.target

[Service]
Type=simple
ExecStart=$REBOOT_DAEMON
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

echo "✅ Reboot service created: $REBOOT_SERVICE"

#
# Create the management script (ms-manager) with PM2 instance management features + Start Now + Start Last Added
#
cat > "$MANAGER_SCRIPT" <<'MANAGER_EOF'
#!/bin/bash

CONFIG_FILE="/etc/ms-server/config.conf"
SERVICE_NAME="ms-server"
TIMER_NAME="ms-server.timer"
REBOOT_SERVICE="ms-reboot.service"
LOG_FILE="/var/log/ms-server.log"
UPDATE_URL="https://raw.githubusercontent.com/pgwiz/botPaas/refs/heads/main/install-ms-manager.sh"
# Dynamic plugin menus
MENUS_DIR="/usr/local/bin/menus"
MENUS_REGISTRY="$MENUS_DIR/ref.sh"
FOLLOWUP_CONF="/etc/ms-server/follow_up.conf"

REBOOT_TIMESTAMP_FILE="/etc/ms-server/last_reboot_timestamp"
BOOT_TIMESTAMP_FILE="/etc/ms-server/actual_boot_timestamp"
REBOOT_LOG_FILE="/etc/ms-server/reboot_history.log"
REBOOT_DB_FILE="/etc/ms-server/reboot_database.csv"
PM2_INSTANCES_FILE="/etc/ms-server/pm2_instances.csv"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Helpers for PM2 instances CSV
ensure_instances_file() {
    if [ ! -f "$PM2_INSTANCES_FILE" ]; then
        echo "name,working_dir,delay_seconds,is_main" > "$PM2_INSTANCES_FILE"
        chmod 644 "$PM2_INSTANCES_FILE"
    fi
}

list_instances() {
    ensure_instances_file
    echo ""
    echo -e "${BLUE}=== PM2 Instances ===${NC}"
    printf "%-4s %-20s %-30s %-8s %-8s\n" "ID" "NAME" "WORKING_DIR" "DELAY(s)" "MAIN"
    echo "--------------------------------------------------------------------------------------------"
    idx=0
    tail -n +2 "$PM2_INSTANCES_FILE" | sed '/^\s*$/d' | while IFS=',' read -r name dir delay is_main; do
        idx=$((idx+1))
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        dir=$(echo "$dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        delay=$(echo "$delay" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        is_main=$(echo "$is_main" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        printf "%-4s %-20s %-30s %-8s %-8s\n" "$idx" "$name" "$dir" "${delay:-N/A}" "${is_main:-}"
    done
    echo ""
}

# Parse human-friendly durations like 5m, 30s, 1h30m into seconds
parse_duration() {
    local s input total num unit rest v
    input=$(echo "$1" | tr -d '[:space:]')
    if [ -z "$input" ]; then
        echo ""
        return
    fi
    # If it's a plain integer, treat as seconds
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
        return
    fi
    total=0
    # loop extracting pairs like 1h 30m 20s
    while [[ "$input" =~ ^([0-9]+)([smhSMH])(.*)$ ]]; do
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        rest="${BASH_REMATCH[3]}"
        case "$unit" in
            s|S) v=$num ;;
            m|M) v=$((num*60)) ;;
            h|H) v=$((num*3600)) ;;
            *) v=0 ;;
        esac
        total=$((total + v))
        input="$rest"
    done
    if [ "$total" -gt 0 ]; then
        echo "$total"
    else
        echo ""
    fi
}

# Start all configured PM2 instances now (main first, then others), with small stagger for others
start_instances_now() {
    ensure_instances_file
    if [ ! -f "$PM2_INSTANCES_FILE" ]; then
        echo -e "${YELLOW}No PM2 instances configured.${NC}"
        return 1
    fi

    mapfile -t lines < <(tail -n +2 "$PM2_INSTANCES_FILE" 2>/dev/null | sed '/^\s*$/d')
    if [ "${#lines[@]}" -eq 0 ]; then
        echo -e "${YELLOW}No PM2 instances configured.${NC}"
        return 1
    fi

    names=(); dirs=(); delays=(); main_idx=-1
    for i in "${!lines[@]}"; do
        IFS=',' read -r name dir delay is_main <<< "${lines[$i]}"
        name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        dir=$(echo "$dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        delay=$(echo "$delay" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        is_main=$(echo "$is_main" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -z "$delay" ] || ! [[ "$delay" =~ ^[0-9]+$ ]]; then
            source "$CONFIG_FILE"
            delay="$PM2_INSTANCES_DELAY_DEFAULT"
        fi
        names+=("$name")
        dirs+=("$dir")
        delays+=("$delay")
        if [ "$is_main" = "true" ] || [ "$is_main" = "1" ] || [ "$is_main" = "yes" ]; then
            main_idx=$i
        fi
    done

    if [ "$main_idx" -lt 0 ]; then
        main_idx=0
    fi

    # Start main instance immediately
    MAIN_NAME="${names[$main_idx]}"
    MAIN_DIR="${dirs[$main_idx]}"
    if [ -d "$MAIN_DIR" ]; then
        echo -e "${CYAN}Starting MAIN PM2 instance: $MAIN_NAME in $MAIN_DIR...${NC}"
        cd "$MAIN_DIR" || true
        pm2 start . --name "$MAIN_NAME" --time 2>&1 | sed 's/^/  /'
    else
        echo -e "${YELLOW}MAIN dir not found: $MAIN_DIR - skipping MAIN${NC}"
    fi

    # Start other instances sequentially with small random gaps (2-5s) to reduce memory spikes
    for i in "${!names[@]}"; do
        if [ "$i" -eq "$main_idx" ]; then continue; fi
        NAME="${names[$i]}"
        DIR="${dirs[$i]}"
        if [ ! -d "$DIR" ]; then
            echo -e "${YELLOW}Dir not found for $NAME ($DIR) - skipping${NC}"
            continue
        fi
        echo -e "${CYAN}Starting PM2 instance: $NAME in $DIR...${NC}"
        cd "$DIR" || true
        pm2 start . --name "$NAME" --time 2>&1 | sed 's/^/  /'
        pm2 save --force 2>/dev/null || true
        # random sleep 2..5 seconds
        gap=$((2 + RANDOM % 4))
        sleep "$gap"
    done

    pm2 save --force 2>/dev/null || true
    echo -e "${GREEN}All configured PM2 instances started (main first, others staggered).${NC}"
}

# Start a single instance now (used after add)
start_single_instance_now() {
    local name="$1"
    local dir="$2"
    if [ -z "$name" ] || [ -z "$dir" ]; then
        echo -e "${RED}Missing name or dir for single start${NC}"
        return 1
    fi
    if [ ! -d "$dir" ]; then
        echo -e "${RED}Directory not found: $dir${NC}"
        return 1
    fi
    echo -e "${CYAN}Starting PM2 instance: $name in $dir...${NC}"
    cd "$dir" || true
    pm2 start . --name "$name" --time 2>&1 | sed 's/^/  /'
    pm2 save --force 2>/dev/null || true
    echo -e "${GREEN}Instance $name started now.${NC}"
}

# Start the last-added instance immediately
start_last_instance_now() {
    ensure_instances_file
    last_line=$(tail -n +2 "$PM2_INSTANCES_FILE" | sed '/^\s*$/d' | tail -n 1)
    if [ -z "$last_line" ]; then
        echo -e "${YELLOW}No PM2 instances found.${NC}"
        return 1
    fi
    IFS=',' read -r name dir delay is_main <<< "$last_line"
    name=$(echo "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    dir=$(echo "$dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$name" ] || [ -z "$dir" ]; then
        echo -e "${RED}Invalid last entry.${NC}"
        return 1
    fi
    echo -e "${CYAN}Starting last-added instance: $name in $dir...${NC}"
    start_single_instance_now "$name" "$dir"
}

add_instance_interactive() {
    ensure_instances_file
    echo -e -n "${YELLOW}Add PM2 instance - Please specify the working directory: ${NC}"
    read -r input_dir
    # Expand ~
    if [[ "$input_dir" == "~"* ]]; then
        input_dir="${input_dir/#\~/$HOME}"
    fi
    input_dir=$(echo "$input_dir" | sed 's:/*$::') # trim trailing slashes
    if [ -z "$input_dir" ]; then
        echo -e "${RED}No directory entered. Cancelled.${NC}"
        return 1
    fi

    if [ ! -d "$input_dir" ]; then
        echo -n "Directory does not exist. Create it? (yes/no): "
        read -r create_confirm
        if [ "$create_confirm" = "yes" ]; then
            mkdir -p "$input_dir" || { echo -e "${RED}Failed to create directory${NC}"; return 1; }
        else
            echo -e "${YELLOW}Cancelled.${NC}"
            return 1
        fi
    fi

    # Suggest name from basename
    default_name=$(basename "$input_dir")
    echo -n "Enter instance name (default: $default_name): "
    read -r inst_name
    if [ -z "$inst_name" ]; then
        inst_name="$default_name"
    fi

    # Ensure unique name
    ensure_instances_file
    if tail -n +2 "$PM2_INSTANCES_FILE" | cut -d',' -f1 | grep -xq "$inst_name"; then
        # append numeric suffix
        suffix=2
        while tail -n +2 "$PM2_INSTANCES_FILE" | cut -d',' -f1 | grep -xq "${inst_name}-${suffix}"; do
            suffix=$((suffix+1))
        done
        inst_name="${inst_name}-${suffix}"
    fi

    # Load default delay from config
    source "$CONFIG_FILE"
    default_delay=${PM2_INSTANCES_DELAY_DEFAULT:-300}

    echo -n "Delay before starting this instance after main (e.g., 5m, 30s, 1h30m) [default: ${default_delay}s]: "
    read -r input_delay_str
    if [ -z "$input_delay_str" ]; then
        input_delay="$default_delay"
    else
        parsed=$(parse_duration "$input_delay_str")
        if [ -z "$parsed" ]; then
            # if parse failed and it's numeric fallback
            if [[ "$input_delay_str" =~ ^[0-9]+$ ]]; then
                input_delay="$input_delay_str"
            else
                echo -e "${YELLOW}Could not parse delay; using default ${default_delay}s${NC}"
                input_delay="$default_delay"
            fi
        else
            input_delay="$parsed"
        fi
    fi

    echo -n "Make this instance the MAIN (starts immediately)? (yes/no) [no]: "
    read -r main_choice
    is_main="false"
    if [ "$main_choice" = "yes" ] || [ "$main_choice" = "y" ]; then
        is_main="true"
        # unset previous main
        if [ -f "$PM2_INSTANCES_FILE" ]; then
            tmpf="$(mktemp)"
            awk -F, 'NR==1{print $0; next} { $4="false"; print $0 }' "$PM2_INSTANCES_FILE" > "$tmpf"
            mv "$tmpf" "$PM2_INSTANCES_FILE"
        fi
    fi

    # Append new entry
    echo "${inst_name},${input_dir},${input_delay},${is_main}" >> "$PM2_INSTANCES_FILE"
    chmod 644 "$PM2_INSTANCES_FILE"

    # Feedback scheduled
    if [ "$input_delay" -ge 60 ]; then
        mins=$((input_delay/60))
        echo -e "${GREEN}Success: instance will start in ${mins} minute(s) (=${input_delay}s)${NC}"
    else
        echo -e "${GREEN}Success: instance will start in ${input_delay} second(s)${NC}"
    fi

    # Prompt to start now
    echo -n "Start this instance now (ignore delay)? (yes/no): "
    read -r start_now
    if [ "$start_now" = "yes" ] || [ "$start_now" = "y" ]; then
        start_single_instance_now "$inst_name" "$input_dir"
    fi
}

remove_instance() {
    ensure_instances_file
    list_instances
    echo -n "Enter ID of instance to remove: "
    read -r rem_id
    if ! [[ "$rem_id" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid ID${NC}"
        return 1
    fi
    total=$(($(wc -l < "$PM2_INSTANCES_FILE") - 1))
    if [ "$rem_id" -lt 1 ] || [ "$rem_id" -gt "$total" ]; then
        echo -e "${RED}ID out of range${NC}"
        return 1
    fi
    tmpf=$(mktemp)
    head -n 1 "$PM2_INSTANCES_FILE" > "$tmpf"
    awk -v id="$rem_id" 'NR>1{ if(NR-1!=id) print $0 }' "$PM2_INSTANCES_FILE" >> "$tmpf"
    mv "$tmpf" "$PM2_INSTANCES_FILE"
    echo -e "${GREEN}Instance removed${NC}"
}

edit_instance_delay() {
    ensure_instances_file
    list_instances
    echo -n "Enter ID of instance to edit delay: "
    read -r eid
    if ! [[ "$eid" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid ID${NC}"
        return 1
    fi
    total=$(($(wc -l < "$PM2_INSTANCES_FILE") - 1))
    if [ "$eid" -lt 1 ] || [ "$eid" -gt "$total" ]; then
        echo -e "${RED}ID out of range${NC}"
        return 1
    fi
    current_delay=$(tail -n +"$((eid+1))" "$PM2_INSTANCES_FILE" | head -n 1 | cut -d',' -f3)
    echo -n "Current delay is ${current_delay}s. Enter new delay (e.g., 5m, 30s or seconds): "
    read -r newdelay_str
    if [ -z "$newdelay_str" ]; then
        echo -e "${YELLOW}No input; cancelled${NC}"
        return 1
    fi
    parsed=$(parse_duration "$newdelay_str")
    if [ -z "$parsed" ]; then
        if [[ "$newdelay_str" =~ ^[0-9]+$ ]]; then
            newdelay="$newdelay_str"
        else
            echo -e "${RED}Invalid delay${NC}"
            return 1
        fi
    else
        newdelay="$parsed"
    fi
    tmpf=$(mktemp)
    awk -v id="$eid" -v nd="$newdelay" 'BEGIN{OFS=FS=","} NR==1{print $0; next} { if(NR-1==id) {$3=nd; print $0} else print $0 }' "$PM2_INSTANCES_FILE" > "$tmpf"
    mv "$tmpf" "$PM2_INSTANCES_FILE"
    echo -e "${GREEN}Delay updated${NC}"
}

set_main_instance() {
    ensure_instances_file
    list_instances
    echo -n "Enter ID of instance to set as MAIN: "
    read -r mid
    if ! [[ "$mid" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid ID${NC}"
        return 1
    fi
    total=$(($(wc -l < "$PM2_INSTANCES_FILE") - 1))
    if [ "$mid" -lt 1 ] || [ "$mid" -gt "$total" ]; then
        echo -e "${RED}ID out of range${NC}"
        return 1
    fi
    tmpf=$(mktemp)
    awk -v id="$mid" 'BEGIN{OFS=FS=","} NR==1{print $0; next} { if(NR-1==id) $4="true"; else $4="false"; print $0 }' "$PM2_INSTANCES_FILE" > "$tmpf"
    mv "$tmpf" "$PM2_INSTANCES_FILE"
    echo -e "${GREEN}MAIN instance set${NC}"
}

edit_default_pm2_delay() {
    source "$CONFIG_FILE"
    current=${PM2_INSTANCES_DELAY_DEFAULT:-300}
    echo -n "Current default delay for other PM2 instances: ${current}s. Enter new default in seconds: "
    read -r nd
    if ! [[ "$nd" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Invalid value${NC}"
        return 1
    fi
    # Persist to config
    sed -i "/^PM2_INSTANCES_DELAY_DEFAULT=/d" "$CONFIG_FILE"
    echo "PM2_INSTANCES_DELAY_DEFAULT=$nd" >> "$CONFIG_FILE"
    echo -e "${GREEN}Default delay updated to ${nd}s${NC}"
}

# Show help
show_help() {
    cat << HELP
MS Server Manager - Enhanced Version v3.3

USAGE:
    ms-manager [OPTIONS]

PM2 instance management:
    -add-instance           Add PM2 instance (specify working dir)
    -list-instances         List configured PM2 instances
    -rm-instance            Remove PM2 instance by ID
    -edit-instance-delay    Edit per-instance delay by ID (accepts 5m/30s/etc)
    -set-main               Set which instance is MAIN by ID
    -set-default-delay      Set default delay (seconds) for other instances
    -start-instances-now    Start all configured PM2 instances immediately (main first, others staggered)
    -start-last-instance-now [--no-confirm|-y] Start only the last-added PM2 instance immediately (optional no-confirm for scripting)

Other options:
    -h, --help              Show this help message
    -mes, --menus            Open dynamic plugin menus (/usr/local/bin/menus)
    -s, --status            Show service status
    -start                  Start the service and timer
    -stop                   Stop the service and timer
    -restart                Restart the service immediately
    -testm <minutes> [r]    Set test mode with custom interval
    -countdown              Show live restart countdown (daemon or timer)
    -logs [lines]           Show logs (default: 50 lines)
    -live                   Show live logs (tail -f)
    -interval <hours>       Set restart interval in hours
    -reboot-now             Reboot VPS immediately
    -reboot-on              Enable periodic VPS reboot (starts reboot daemon)
    -reboot-off             Disable periodic VPS reboot (stops reboot daemon)
    -reboot-status          Show reboot tracking status
    -reboot-reset           Reset reboot timer
    -reboot-history [n]     Show last n reboots (default: 10)
    -reboot-log [n]         Show last n lines of reboot log (default: 20)
    -reboot-stats           Show reboot statistics
    -update                 Update from GitHub
    -fresh-start            Force fresh PM2 start (delete all processes)
    -config                 View configuration
HELP
}

# Load configuration
load_config() {
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
}

# Save configuration and update timer + reboot daemon interval file
save_config() {
    cat > "$CONFIG_FILE" <<CONF_EOF
# MS Server Configuration
RESTART_INTERVAL=$RESTART_INTERVAL
WORKING_DIR=$WORKING_DIR
IPV6_SCRIPT=$IPV6_SCRIPT
ENABLE_AUTO_RESTART=$ENABLE_AUTO_RESTART
CUSTOM_COMMANDS="$CUSTOM_COMMANDS"
ENABLE_VPS_REBOOT=$ENABLE_VPS_REBOOT
ENABLE_UPDATE_ON_BOOT=$ENABLE_UPDATE_ON_BOOT
PM2_INSTANCES_DELAY_DEFAULT=${PM2_INSTANCES_DELAY_DEFAULT:-300}
CONF_EOF

    # Update the systemd timer interval (OnUnitActiveSec)
    if [ -f "/etc/systemd/system/$TIMER_NAME" ]; then
        sudo sed -i "s/^OnUnitActiveSec=.*/OnUnitActiveSec=${RESTART_INTERVAL}s/" /etc/systemd/system/$TIMER_NAME
    fi

    # Update reboot daemon interval file
    mkdir -p /var/lib/ms-manager
    echo "$RESTART_INTERVAL" > /var/lib/ms-manager/interval
    chmod 644 /var/lib/ms-manager/interval

    # Signal the reboot daemon to reload the interval without restarting the service
    sudo systemctl kill -s HUP $REBOOT_SERVICE >/dev/null 2>&1 || true

    sudo systemctl daemon-reload
}

# Parse CLI args (extended for PM2 instance management)
if [ $# -gt 0 ]; then
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;

-mes|--menus)
    ms__plugin_menu_ui
    exit 0
    ;;
        -add-instance)
            add_instance_interactive
            exit 0
            ;;
        -list-instances)
            list_instances
            exit 0
            ;;
        -rm-instance)
            remove_instance
            exit 0
            ;;
        -edit-instance-delay)
            edit_instance_delay
            exit 0
            ;;
        -set-main)
            set_main_instance
            exit 0
            ;;
        -set-default-delay)
            edit_default_pm2_delay
            exit 0
            ;;
        -start-instances-now)
            start_instances_now
            exit 0
            ;;
        -start-last-instance-now)
            # optional --no-confirm or -y
            if [ "$2" = "--no-confirm" ] || [ "$2" = "-y" ]; then
                start_last_instance_now
            else
                echo -n "Start last-added PM2 instance NOW? (yes/no): "
                read -r sconfirm
                if [ "$sconfirm" = "yes" ] || [ "$sconfirm" = "y" ]; then
                    start_last_instance_now
                else
                    echo -e "${YELLOW}Cancelled.${NC}"
                fi
            fi
            exit 0
            ;;
        -s|--status)
            systemctl status $TIMER_NAME
            systemctl status $SERVICE_NAME
            systemctl status $REBOOT_SERVICE
            exit 0
            ;;
        -start)
            echo -e "${CYAN}Starting MS Server timer and (optionally) reboot daemon...${NC}"
            sudo systemctl start $TIMER_NAME
            sudo systemctl enable $TIMER_NAME
            source "$CONFIG_FILE"
            if [ "$ENABLE_VPS_REBOOT" = "true" ]; then
                sudo systemctl start $REBOOT_SERVICE
                sudo systemctl enable $REBOOT_SERVICE
            fi
            echo -e "${GREEN}Service started and enabled${NC}"
            exit 0
            ;;
        -stop)
            echo -e "${CYAN}Stopping MS Server timer and reboot daemon...${NC}"
            sudo systemctl stop $TIMER_NAME
            sudo systemctl disable $TIMER_NAME
            sudo systemctl stop $REBOOT_SERVICE || true
            sudo systemctl disable $REBOOT_SERVICE || true
            echo -e "${YELLOW}Services stopped and disabled${NC}"
            exit 0
            ;;
        -restart)
            echo -e "${CYAN}Restarting MS Server service...${NC}"
            sudo systemctl restart $SERVICE_NAME
            echo -e "${GREEN}Service restarted${NC}"
            exit 0
            ;;
        -testm)
            if [ -z "$2" ]; then
                echo -e "${RED}Error: Please specify minutes${NC}"
                echo "Usage: ms-manager -testm <minutes> [r]"
                exit 1
            fi

            load_config
            MINUTES=$2
            RESTART_INTERVAL=$((MINUTES * 60))

            if [ "$3" = "r" ] || [ "$3" = "R" ]; then
                ENABLE_VPS_REBOOT=true
                echo -e "${YELLOW}Test mode: ${MINUTES} minutes with VPS REBOOT${NC}"
            else
                ENABLE_VPS_REBOOT=false
                echo -e "${YELLOW}Test mode: ${MINUTES} minutes (no reboot)${NC}"
            fi

            save_config
            sudo systemctl restart $TIMER_NAME || true

            if [ "$ENABLE_VPS_REBOOT" = "true" ]; then
                sudo systemctl restart $REBOOT_SERVICE || sudo systemctl start $REBOOT_SERVICE
            else
                sudo systemctl stop $REBOOT_SERVICE || true
            fi

            echo -e "${GREEN}Test mode activated!${NC}"
            echo -e "Restart interval: ${CYAN}${MINUTES} minutes${NC}"
            echo -e "VPS reboot: ${CYAN}${ENABLE_VPS_REBOOT}${NC}"
            exit 0
            ;;
        -countdown)
            # Countdown logic (prefer reboot daemon if running)
            if systemctl is-active --quiet $REBOOT_SERVICE; then
                RESTART_INTERVAL_FILE="/var/lib/ms-manager/interval"
                START_FILE="/var/lib/ms-manager/start_time"
                if [ ! -f "$RESTART_INTERVAL_FILE" ] || [ ! -f "$START_FILE" ]; then
                    echo -e "${YELLOW}Reboot daemon running but interval/start files missing.${NC}"
                    exit 1
                fi
                INTERVAL=$(cat "$RESTART_INTERVAL_FILE")
                START_TIME=$(cat "$START_FILE")
                while true; do
                    NOW=$(date +%s)
                    ELAPSED=$((NOW - START_TIME))
                    REMAINING=$((INTERVAL - ELAPSED))
                    if [ $REMAINING -le 0 ]; then
                        echo -e "${RED}Reboot time reached or overdue.${NC}"
                        exit 0
                    fi
                    H=$((REMAINING / 3600))
                    M=$(((REMAINING % 3600) / 60))
                    S=$((REMAINING % 60))
                    printf "\rNext reboot in: %02dh %02dm %02ds (interval %ds)  " $H $M $S $INTERVAL
                    sleep 1
                done
            fi

            # Fallback to timer-based countdown
            if ! systemctl is-active --quiet $SERVICE_NAME.timer; then
                echo -e "${RED}Timer is not running!${NC}"
                exit 1
            fi

            load_config

            LAST_TRIGGER=$(systemctl show $SERVICE_NAME.timer --property=LastTriggerUSec --value)
            if [ "$LAST_TRIGGER" = "0" ]; then
                echo -e "${YELLOW}Timer has not triggered yet${NC}"
                exit 1
            fi

            LAST_TRIGGER_EPOCH=$(date -d "$LAST_TRIGGER" +%s 2>/dev/null)
            if [ -z "$LAST_TRIGGER_EPOCH" ]; then
                echo -e "${RED}Unable to determine last trigger time${NC}"
                exit 1
            fi

            while true; do
                CURRENT_EPOCH=$(date +%s)
                ELAPSED=$((CURRENT_EPOCH - LAST_TRIGGER_EPOCH))
                REMAINING=$((RESTART_INTERVAL - ELAPSED))

                if [ $REMAINING -le 0 ]; then
                    echo -e "\n${GREEN}TIMER TRIGGERED!${NC}"
                    sleep 2
                    LAST_TRIGGER=$(systemctl show $SERVICE_NAME.timer --property=LastTriggerUSec --value)
                    LAST_TRIGGER_EPOCH=$(date -d "$LAST_TRIGGER" +%s 2>/dev/null)
                    continue
                fi

                HOURS=$((REMAINING / 3600))
                MINUTES=$(((REMAINING % 3600) / 60))
                SECONDS=$((REMAINING % 60))

                printf "\rNext restart in: %02d:%02d:%02d  " $HOURS $MINUTES $SECONDS
                sleep 1
            done
            ;;
        -logs)
            LINES=${2:-50}
            echo -e "${BLUE}=== Last $LINES Log Lines ===${NC}"
            sudo tail -n $LINES "$LOG_FILE"
            exit 0
            ;;
        -live)
            echo -e "${BLUE}=== Live Logs (Ctrl+C to exit) ===${NC}"
            sudo tail -f "$LOG_FILE"
            exit 0
            ;;
        -interval)
            if [ -z "$2" ]; then
                echo -e "${RED}Error: Please specify hours${NC}"
                echo "Usage: ms-manager -interval <hours>"
                exit 1
            fi

            load_config
            RESTART_INTERVAL=$(($2 * 3600))
            save_config
            sudo systemctl restart $TIMER_NAME || true
            sudo systemctl restart $REBOOT_SERVICE || true
            echo -e "${GREEN}Restart interval set to $2 hours${NC}"
            exit 0
            ;;
        -reboot-now)
            echo -e "${RED}Rebooting VPS NOW...${NC}"
            sync
            /sbin/reboot
            exit 0
            ;;
        -reboot-on)
            load_config
            ENABLE_VPS_REBOOT=true
            save_config
            sudo systemctl restart $REBOOT_SERVICE || sudo systemctl start $REBOOT_SERVICE
            sudo systemctl enable $REBOOT_SERVICE
            echo -e "${GREEN}Periodic VPS reboot ENABLED and daemon started${NC}"
            exit 0
            ;;
        -reboot-off)
            load_config
            ENABLE_VPS_REBOOT=false
            save_config
            sudo systemctl stop $REBOOT_SERVICE || true
            sudo systemctl disable $REBOOT_SERVICE || true
            echo -e "${YELLOW}Periodic VPS reboot DISABLED and daemon stopped${NC}"
            exit 0
            ;;
        -reboot-status)
            load_config
            echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       VPS REBOOT STATUS                                            ║${NC}"
            echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${CYAN}Periodic Reboot:${NC} ${ENABLE_VPS_REBOOT}"
            echo -e "${CYAN}Restart Interval:${NC} $((RESTART_INTERVAL / 3600))h ($RESTART_INTERVAL seconds)"
            echo ""

            if [ -f "$REBOOT_TIMESTAMP_FILE" ]; then
                LAST_REBOOT_TS=$(cat "$REBOOT_TIMESTAMP_FILE" 2>/dev/null || echo "0")
                if [ "$LAST_REBOOT_TS" != "0" ]; then
                    echo -e "${GREEN}Last Reboot Triggered:${NC} $(date -d "@$LAST_REBOOT_TS" '+%Y-%m-%d %H:%M:%S')"
                    echo -e "${GREEN}Timestamp:${NC} $LAST_REBOOT_TS"
                fi
            fi

            if [ -f "$BOOT_TIMESTAMP_FILE" ]; then
                ACTUAL_BOOT_TS=$(cat "$BOOT_TIMESTAMP_FILE" 2>/dev/null || echo "0")
                if [ "$ACTUAL_BOOT_TS" != "0" ]; then
                    echo -e "${GREEN}Actual System Boot:${NC} $(date -d "@$ACTUAL_BOOT_TS" '+%Y-%m-%d %H:%M:%S')"
                    echo -e "${GREEN}Boot Timestamp:${NC} $ACTUAL_BOOT_TS"

                    if [ -f "$REBOOT_TIMESTAMP_FILE" ] && [ "$LAST_REBOOT_TS" != "0" ]; then
                        BOOT_DURATION=$((ACTUAL_BOOT_TS - LAST_REBOOT_TS))
                        if [ "$BOOT_DURATION" -gt 0 ]; then
                            echo -e "${CYAN}Boot Duration:${NC} ${BOOT_DURATION}s"
                        fi
                    fi
                fi
            fi

            if systemctl is-active --quiet $REBOOT_SERVICE; then
                if [ -f "/var/lib/ms-manager/interval" ] && [ -f "/var/lib/ms-manager/start_time" ]; then
                    INTERVAL=$(cat /var/lib/ms-manager/interval)
                    START=$(cat /var/lib/ms-manager/start_time)
                    NOW=$(date +%s)
                    TIME_SINCE=$((NOW - START))
                    NEXT_REBOOT_IN=$((INTERVAL - TIME_SINCE))
                    if [ "$NEXT_REBOOT_IN" -gt 0 ]; then
                        echo ""
                        echo -e "${YELLOW}Time Since Daemon Start:${NC} $((TIME_SINCE / 3600))h $((TIME_SINCE % 3600 / 60))m $((TIME_SINCE % 60))s"
                        echo -e "${YELLOW}Next Reboot In:${NC} $((NEXT_REBOOT_IN / 3600))h $((NEXT_REBOOT_IN % 3600 / 60))m $((NEXT_REBOOT_IN % 60))s"
                    else
                        echo -e "${RED}Daemon scheduled reboot: Overdue or happening now${NC}"
                    fi
                fi
            fi

            echo ""
            exit 0
            ;;
        -reboot-reset)
            echo -e "${YELLOW}Resetting reboot timer...${NC}"
            if [ -f "$REBOOT_TIMESTAMP_FILE" ]; then
                sudo rm -f "$REBOOT_TIMESTAMP_FILE"
                echo -e "${GREEN}Reboot timer reset!${NC}"
                echo -e "Next service trigger will reboot if periodic reboot is enabled."
            else
                echo -e "${YELLOW}No reboot timestamp file found.${NC}"
            fi
            exit 0
            ;;
        -reboot-history)
            LINES=${2:-10}
            echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       REBOOT HISTORY (Last $LINES entries)                              ║${NC}"
            echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""

            if [ ! -f "$REBOOT_DB_FILE" ]; then
                echo -e "${YELLOW}No reboot database found${NC}"
                exit 0
            fi

            TOTAL_REBOOTS=$(($(wc -l < "$REBOOT_DB_FILE") - 1))

            if [ "$TOTAL_REBOOTS" -eq 0 ]; then
                echo -e "${YELLOW}No reboots recorded yet${NC}"
                exit 0
            fi

            echo -e "${GREEN}Total reboots recorded: $TOTAL_REBOOTS${NC}"
            echo ""
            printf "${CYAN}%-20s %-20s %-12s %-15s %s${NC}\n" "Timestamp" "Date/Time" "Uptime" "Elapsed" "Reason"
            echo "─────────────────────────────────────────────────────────────────────────────────────────"

            tail -n "$LINES" "$REBOOT_DB_FILE" | tail -n +2 | while IFS=',' read -r timestamp datetime uptime reason interval elapsed; do
                uptime_h=$((uptime / 3600))
                uptime_m=$(((uptime % 3600) / 60))
                uptime_readable="${uptime_h}h ${uptime_m}m"
                elapsed_h=$((elapsed / 3600))
                elapsed_m=$(((elapsed % 3600) / 60))
                elapsed_readable="${elapsed_h}h ${elapsed_m}m"
                printf "%-20s %-20s %-12s %-15s %s\n" "$timestamp" "$datetime" "$uptime_readable" "$elapsed_readable" "$reason"
            done

            echo ""
            exit 0
            ;;
        -reboot-log)
            LINES=${2:-20}
            echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       REBOOT LOG (Last $LINES lines)                                    ║${NC}"
            echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""

            if [ ! -f "$REBOOT_LOG_FILE" ]; then
                echo -e "${YELLOW}No reboot log found${NC}"
                exit 0
            fi

            if [ ! -s "$REBOOT_LOG_FILE" ]; then
                echo -e "${YELLOW}Reboot log is empty${NC}"
                exit 0
            fi

            tail -n $LINES "$REBOOT_LOG_FILE"
            echo ""
            exit 0
            ;;
        -reboot-stats)
            echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       REBOOT STATISTICS                                            ║${NC}"
            echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""

            if [ ! -f "$REBOOT_DB_FILE" ]; then
                echo -e "${YELLOW}No reboot database found${NC}"
                exit 0
            fi

            TOTAL_REBOOTS=$(($(wc -l < "$REBOOT_DB_FILE") - 1))

            if [ "$TOTAL_REBOOTS" -eq 0 ]; then
                echo -e "${YELLOW}No reboots recorded yet${NC}"
                exit 0
            fi

            echo -e "${GREEN}Total Reboots:${NC} $TOTAL_REBOOTS"

            FIRST_REBOOT=$(tail -n +2 "$REBOOT_DB_FILE" | head -n 1 | cut -d',' -f2)
            LAST_REBOOT=$(tail -n 1 "$REBOOT_DB_FILE" | cut -d',' -f2)

            echo -e "${GREEN}First Reboot:${NC} $FIRST_REBOOT"
            echo -e "${GREEN}Last Reboot:${NC} $LAST_REBOOT"
            echo ""

            TOTAL_UPTIME=0
            COUNT=0
            while IFS=',' read -r timestamp datetime uptime reason interval elapsed; do
                if [ "$uptime" != "uptime_before" ] && [ -n "$uptime" ]; then
                    TOTAL_UPTIME=$((TOTAL_UPTIME + uptime))
                    COUNT=$((COUNT + 1))
                fi
            done < "$REBOOT_DB_FILE"

            if [ "$COUNT" -gt 0 ]; then
                AVG_UPTIME=$((TOTAL_UPTIME / COUNT))
                AVG_UPTIME_H=$((AVG_UPTIME / 3600))
                AVG_UPTIME_M=$(((AVG_UPTIME % 3600) / 60))
                echo -e "${CYAN}Average Uptime Before Reboot:${NC} ${AVG_UPTIME_H}h ${AVG_UPTIME_M}m"
            fi

            TOTAL_ELAPSED=0
            ELAPSED_COUNT=0
            while IFS=',' read -r timestamp datetime uptime reason interval elapsed; do
                if [ "$elapsed" != "elapsed_since_last" ] && [ -n "$elapsed" ] && [ "$elapsed" != "0" ]; then
                    TOTAL_ELAPSED=$((TOTAL_ELAPSED + elapsed))
                    ELAPSED_COUNT=$((ELAPSED_COUNT + 1))
                fi
            done < "$REBOOT_DB_FILE"

            if [ "$ELAPSED_COUNT" -gt 0 ]; then
                AVG_ELAPSED=$((TOTAL_ELAPSED / ELAPSED_COUNT))
                AVG_ELAPSED_H=$((AVG_ELAPSED / 3600))
                AVG_ELAPSED_M=$(((AVG_ELAPSED % 3600) / 60))
                echo -e "${CYAN}Average Time Between Reboots:${NC} ${AVG_ELAPSED_H}h ${AVG_ELAPSED_M}m"
            fi

            echo ""
            echo -e "${MAGENTA}Recent Reboot Reasons:${NC}"
            tail -n 6 "$REBOOT_DB_FILE" | tail -n +2 | cut -d',' -f4 | sort | uniq -c | sort -rn

            echo ""
            exit 0
            ;;
        -update)
            echo -e "${CYAN}Updating from GitHub...${NC}"
            TMP_FILE="/tmp/install-ms-manager.sh"
            if curl -fsSL "$UPDATE_URL" -o "$TMP_FILE"; then
                chmod +x "$TMP_FILE"
                sudo bash "$TMP_FILE"
                echo -e "${GREEN}Update complete${NC}"
            else
                echo -e "${RED}Update failed${NC}"
                exit 1
            fi
            exit 0
            ;;
        -fresh-start)
            echo -e "${CYAN}Forcing fresh PM2 start...${NC}"
            load_config
            cd "$WORKING_DIR" || exit 1
            pm2 delete all 2>/dev/null || true
            pm2 kill 2>/dev/null || true
            sleep 2
            pm2 start . --name ms --time
            pm2 save --force
            echo -e "${GREEN}Fresh PM2 start completed${NC}"
            exit 0
            ;;
        -config)
            echo -e "${BLUE}=== Current Configuration ===${NC}"
            cat "$CONFIG_FILE"
            echo ""
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
fi

# If no arguments, show interactive menu
pm2_is_ms_in_workdir() {
    local info
    info=$(pm2 info ms 2>/dev/null) || return 1
    echo "$info" | grep -q "status *: *online" || return 1
    echo "$info" | grep -q "cwd *: *$WORKING_DIR" || return 1
    return 0
}

run_ipv6_twice_and_verify() {
    echo -e "${BLUE}[*] Running IPv6 setup (1/2)...${NC}"
    sudo chmod +x "$IPV6_SCRIPT" 2>/dev/null || true
    sudo "$IPV6_SCRIPT" || true
    echo -e "${BLUE}[*] Running IPv6 setup (2/2)...${NC}"
    sudo chmod +x "$IPV6_SCRIPT" 2>/dev/null || true
    sudo "$IPV6_SCRIPT" || true
    echo -e "${BLUE}[*] Verifying IPv6 to github.com and gist.github.com...${NC}"
    if ping6 -c 2 -w 5 github.com >/dev/null 2>&1 && ping6 -c 2 -w 5 gist.github.com >/dev/null 2>&1; then
        echo -e "${GREEN}[✓] IPv6 OK${NC}"
        return 0
    else
        echo -e "${YELLOW}[!] IPv6 not confirmed; continuing${NC}"
        return 1
    fi
}

live_pm2_monitor() {
    while true; do
        clear
        echo -e "${BLUE}╔════════════════════════════════ PM2 LIVE MONITOR ═══════════════════════════════╗${NC}"
        if command -v pm2 >/dev/null 2>&1; then
            pm2 list --no-color 2>/dev/null || pm2 ls --no-color 2>/dev/null || echo "pm2 list not available"
        else
            echo "pm2 not installed"
        fi
        echo -e "${BLUE}╟──────────────────────────────────────────────────────────────────────────────────╢${NC}"
        echo -e "${BLUE}║${NC} Top Node processes by memory ${BLUE}║${NC}"
        echo -e "${BLUE}╟────────┬─────────────────────────┬──────┬──────────╢${NC}"
        printf "${BLUE}║${NC} %-6s ${BLUE}│${NC} %-23s ${BLUE}│${NC} %-4s ${BLUE}│${NC} %-8s ${BLUE}║${NC}\n" "PID" "COMMAND" "%MEM" "RSS(MB)"
        echo -e "${BLUE}╟────────┼─────────────────────────┼──────┼──────────╢${NC}"
        if command -v ps >/dev/null 2>&1; then
            ps -C node -o pid=,comm=,pmem=,rss= --sort=-rss | head -n 10 | awk '{ rss_mb=($4+0)/1024.0; printf "║ %-6s │ %-23s │ %-4s │ %8.1f ║\n", $1,$2,$3,rss_mb }'
        else
            echo -e "${BLUE}║${NC} ps not available${BLUE}║${NC}"
        fi
        echo -e "${BLUE}╚────────┴─────────────────────────┴──────┴──────────╝${NC}"
        echo ""
        echo -e "${DIM}Press q to quit. Refreshing every 2s...${NC}"
        read -t 2 -n 1 key && { [ "$key" = "q" ] && break; }
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Plugin Menus (dynamic /usr/local/bin/menus/*.sh)
# ─────────────────────────────────────────────────────────────────────────────

ms__ensure_followup_setup_menu() {
    # If follow-up auto-update is enabled and setup_follow_up.sh is missing, try to fetch it.
    # (URL must be configured inside /etc/ms-server/follow_up.conf)
    local setup_path="$MENUS_DIR/setup_follow_up.sh"
    [ -f "$setup_path" ] && return 0

    if [ -f "$FOLLOWUP_CONF" ]; then
        # shellcheck disable=SC1090
        source "$FOLLOWUP_CONF" 2>/dev/null || true
    fi

    if [ "${FOLLOWUP_AUTO_UPDATE:-0}" = "1" ] && [ -n "${FOLLOWUP_SETUP_URL:-}" ]; then
        echo -e "${CYAN}Auto-update: downloading missing setup_follow_up.sh...${NC}"
        mkdir -p "$MENUS_DIR"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "$FOLLOWUP_SETUP_URL" -o "$setup_path" && chmod +x "$setup_path" || true
        elif command -v wget >/dev/null 2>&1; then
            wget -qO "$setup_path" "$FOLLOWUP_SETUP_URL" && chmod +x "$setup_path" || true
        fi
    fi
}

ms__load_menu_registry() {
    # Optional registry file: defines MS_MENU_REGISTRY=( "file.sh|Menu name" ... )
    if [ -f "$MENUS_REGISTRY" ]; then
        # shellcheck disable=SC1090
        source "$MENUS_REGISTRY" 2>/dev/null || true
    fi
}

ms__plugin_menu_ui() {
    mkdir -p "$MENUS_DIR"
    ms__ensure_followup_setup_menu
    ms__load_menu_registry

    local files=()
    local labels=()

    # registry first
    if declare -p MS_MENU_REGISTRY >/dev/null 2>&1; then
        local entry f label
        for entry in "${MS_MENU_REGISTRY[@]}"; do
            f="${entry%%|*}"
            label="${entry#*|}"
            # skip malformed
            [ -z "$f" ] && continue
            [ "$label" = "$entry" ] && label="$f"
            files+=("$f")
            labels+=("$label")
        done
    fi

    # then scan for any .sh not already in registry
    local fp base found i
    shopt -s nullglob
    for fp in "$MENUS_DIR"/*.sh; do
        base="$(basename "$fp")"
        [ "$base" = "ref.sh" ] && continue
        found=0
        for i in "${!files[@]}"; do
            if [ "${files[$i]}" = "$base" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 0 ]; then
            files+=("$base")
            labels+=("$base (unregistered)")
        fi
    done
    shopt -u nullglob

    while true; do
        clear
        echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║                 ${GREEN}EXTRA MENUS (PLUGINS)${BLUE}                ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${DIM}Folder:${NC} $MENUS_DIR"
        echo -e "${DIM}Registry:${NC} $MENUS_REGISTRY"
        echo ""

        if [ "${#files[@]}" -eq 0 ]; then
            echo -e "${YELLOW}No plugin menus found in $MENUS_DIR${NC}"
            echo ""
            echo -n "Press Enter to return..."
            read -r
            return 0
        fi

        local n=1
        for i in "${!files[@]}"; do
            printf "  %2d) %s\n" "$n" "${labels[$i]}"
            n=$((n + 1))
        done
        echo "   0) Back"
        echo ""
        echo -ne "${YELLOW}➜${NC} Select plugin: "
        read -r pick

        if [ "$pick" = "0" ]; then
            return 0
        fi

        if ! [[ "$pick" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Invalid selection${NC}"
            sleep 1
            continue
        fi

        local idx=$((pick - 1))
        if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#files[@]}" ]; then
            echo -e "${RED}Invalid selection${NC}"
            sleep 1
            continue
        fi

        local script_path="$MENUS_DIR/${files[$idx]}"
        if [ ! -f "$script_path" ]; then
            echo -e "${RED}Missing:${NC} $script_path"
            sleep 2
            continue
        fi

        echo ""
        echo -e "${CYAN}Running:${NC} ${labels[$idx]}"
        echo -e "${DIM}($script_path)${NC}"
        echo ""
        bash "$script_path" || true
        echo ""
        echo -n "Press Enter to return..."
        read -r
    done
}

show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                          ${GREEN}⚡ MS SERVER MANAGER v3.3 ⚡${BLUE}                            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    load_config
    ensure_instances_file

    echo -e "${YELLOW}┌─────────────────────────────────── STATUS ───────────────────────────────────────┐${NC}"
    if systemctl is-active --quiet $TIMER_NAME; then
        echo -e "  ${GREEN}●${NC} Timer Status: ${GREEN}RUNNING${NC}          "
    else
        echo -e "  ${RED}●${NC} Timer Status: ${RED}STOPPED${NC}          "
    fi

    if systemctl is-enabled --quiet $TIMER_NAME; then
        echo -e "  ${GREEN}●${NC} Auto-start: ${GREEN}ENABLED${NC}             "
    else
        echo -e "  ${YELLOW}●${NC} Auto-start: ${YELLOW}DISABLED${NC}            "
    fi

    if systemctl is-active --quiet $REBOOT_SERVICE; then
        echo -e "  ${GREEN}●${NC} Reboot Daemon: ${GREEN}RUNNING${NC}          "
    else
        echo -e "  ${YELLOW}●${NC} Reboot Daemon: ${YELLOW}STOPPED${NC}          "
    fi

    echo -e "  ${BLUE}⏱${NC}  Restart Every: ${GREEN}$((RESTART_INTERVAL / 3600))h${NC} (${RESTART_INTERVAL}s)"
    echo -e "  ${BLUE}📁${NC} Working Dir: ${GREEN}$WORKING_DIR${NC}"
    echo -e "  ${BLUE}🖥️${NC} VPS Reboot: ${GREEN}$ENABLE_VPS_REBOOT${NC}"
    echo -e "  ${BLUE}⬇️${NC} Update on Boot: ${GREEN}$ENABLE_UPDATE_ON_BOOT${NC}"
    echo -e "  ${BLUE}⚙️${NC} Default PM2 extra delay: ${GREEN}${PM2_INSTANCES_DELAY_DEFAULT:-300}s${NC}"
    echo -e "${YELLOW}└──────────────────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""

    echo -e "${BLUE}┌────────────────────────┬────────────────────────┬────────────────────────┐${NC}"
    echo -e "${BLUE}│${GREEN}    SERVICE CONTROL    ${BLUE}│${GREEN}    CONFIGURATION     ${BLUE}│${GREEN}   LOGS & MONITORING  ${BLUE}│${NC}"
    echo -e "${BLUE}├────────────────────────┼────────────────────────┼────────────────────────┤${NC}"
    printf "${BLUE}│${NC} ${GREEN}1${NC}) %-18s ${BLUE}│${NC} ${GREEN}7${NC}) %-18s ${BLUE}│${NC} ${GREEN}12${NC}) %-17s ${BLUE}│${NC}\n" "Start Service" "Restart Interval" "Live Logs"
    printf "${BLUE}│${NC} ${GREEN}2${NC}) %-18s ${BLUE}│${NC} ${GREEN}8${NC}) %-18s ${BLUE}│${NC} ${GREEN}13${NC}) %-17s ${BLUE}│${NC}\n" "Stop Service" "Working Directory" "Last 50 Lines"
    printf "${BLUE}│${NC} ${GREEN}3${NC}) %-18s ${BLUE}│${NC} ${GREEN}9${NC}) %-18s ${BLUE}│${NC} ${GREEN}14${NC}) %-17s ${BLUE}│${NC}\n" "Restart Service" "IPv6 Script Path" "Clear Logs"
    printf "${BLUE}│${NC} ${GREEN}4${NC}) %-18s ${BLUE}│${NC} ${GREEN}10${NC}) %-17s ${BLUE}│${NC} ${GREEN}15${NC}) %-17s ${BLUE}│${NC}\n" "Service Status" "Custom Commands" "Check PM2 Status"
    printf "${BLUE}│${NC} ${GREEN}5${NC}) %-18s ${BLUE}│${NC} ${GREEN}11${NC}) %-17s ${BLUE}│${NC} ${YELLOW}16${NC}) %-17s ${BLUE}│${NC}\n" "Enable Auto-start" "View Full Config" "Test Mode (5min)"
    printf "${BLUE}│${NC} ${GREEN}6${NC}) %-18s ${BLUE}│${NC}                        ${BLUE}│${NC} ${YELLOW}17${NC}) %-17s ${BLUE}│${NC}\n" "Disable Auto-start" "Restart Countdown"
    echo -e "${BLUE}└────────────────────────┴────────────────────────┴────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}┌──────────────────────── PM2 INSTANCES ────────────────────────────────────────────┐${NC}"
    echo -e "  ${GREEN}30${NC}) Add PM2 instance           ${GREEN}31${NC}) List PM2 instances"
    echo -e "  ${GREEN}32${NC}) Remove PM2 instance        ${GREEN}33${NC}) Edit instance delay"
    echo -e "  ${GREEN}34${NC}) Set MAIN instance          ${GREEN}35${NC}) Edit default PM2 delay"
    echo -e "  ${GREEN}36${NC}) Start PM2 instances NOW (ignore delays)"
    echo -e "  ${GREEN}37${NC}) Start last-added PM2 instance NOW"
    echo -e "${BLUE}└──────────────────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "${BLUE}┌──────────────────────── REBOOT MANAGEMENT ───────────────────────────────────────┐${NC}"
    echo -e "  ${YELLOW}18${NC}) Reboot VPS Now                 ${YELLOW}20${NC}) View Reboot Status"
    echo -e "  ${YELLOW}19${NC}) Toggle Periodic VPS Reboot     ${YELLOW}21${NC}) Reset Reboot Timer"
    echo -e "  ${CYAN}27${NC}) View Reboot History             ${CYAN}28${NC}) View Reboot Statistics"
    echo -e "  ${CYAN}29${NC}) View Reboot Log"
    echo -e "${BLUE}└──────────────────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${YELLOW}22${NC}) Toggle Update on Boot"
    echo -e "  ${YELLOW}23${NC}) Initialize now (IPv6 + PM2 fresh start)"
    echo -e "  ${YELLOW}24${NC}) Start attached (from WORKING_DIR)"
    echo -e "  ${YELLOW}25${NC}) View memory usage"
    echo -e "  ${YELLOW}26${NC}) Live PM2 monitor"
    echo -e "  ${YELLOW}67${NC}) Extra menus (plugins)"
    echo -e "  ${GREEN}91${NC}) Update from GitHub"
    echo -e "  ${RED}99${NC}) Uninstall Service"
    echo -e "  ${RED}0${NC}) Exit Manager"
    echo ""
    echo -e "${DIM}TIP: Use 'ms-manager -h' for CLI commands${NC}"
    echo ""
    echo -e -n "${YELLOW}➜${NC} Select option: "
}

# Menu actions
while true; do
    show_menu
    read -r choice

    case $choice in
        1)
            echo "Starting service and timer..."
            sudo systemctl start $TIMER_NAME
            sudo systemctl enable $TIMER_NAME
            load_config
            if [ "$ENABLE_VPS_REBOOT" = "true" ]; then
                sudo systemctl start $REBOOT_SERVICE
                sudo systemctl enable $REBOOT_SERVICE
            fi
            echo -e "${GREEN}Service and timer started${NC}"
            sleep 2
            ;;
        2)
            echo "Stopping service and timer..."
            sudo systemctl stop $TIMER_NAME
            sudo systemctl disable $TIMER_NAME
            sudo systemctl stop $REBOOT_SERVICE || true
            sudo systemctl disable $REBOOT_SERVICE || true
            echo -e "${YELLOW}Service and timer stopped${NC}"
            sleep 2
            ;;
        3)
            echo "Restarting service..."
            sudo systemctl restart $SERVICE_NAME
            echo -e "${GREEN}Service restarted${NC}"
            sleep 2
            ;;
        4)
            clear
            sudo systemctl status $SERVICE_NAME
            echo ""
            sudo systemctl status $TIMER_NAME
            echo ""
            sudo systemctl status $REBOOT_SERVICE
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        5)
            sudo systemctl enable $TIMER_NAME
            echo -e "${GREEN}Auto-start enabled${NC}"
            sleep 2
            ;;
        6)
            sudo systemctl disable $TIMER_NAME
            echo -e "${YELLOW}Auto-start disabled${NC}"
            sleep 2
            ;;
        7)
            echo ""
            echo "Current interval: $((RESTART_INTERVAL / 3600)) hours"
            echo -n "Enter new restart interval in hours: "
            read hours
            if [[ "$hours" =~ ^[0-9]+$ ]]; then
                RESTART_INTERVAL=$((hours * 3600))
                save_config
                echo -e "${GREEN}Restart interval updated to $hours hours${NC}"
                echo -e "${CYAN}Restarting timer and reboot daemon to apply new interval...${NC}"
                sudo systemctl restart $TIMER_NAME
                sudo systemctl restart $REBOOT_SERVICE || true
            else
                echo -e "${RED}Invalid input${NC}"
            fi
            sleep 2
            ;;
        8)
            echo ""
            echo "Current directory: $WORKING_DIR"
            echo -n "Enter new working directory: "
            read new_dir
            if [ -d "$new_dir" ]; then
                WORKING_DIR="$new_dir"
                save_config
                echo -e "${GREEN}Working directory updated${NC}"
            else
                echo -e "${RED}Directory does not exist${NC}"
            fi
            sleep 2
            ;;
        9)
            echo ""
            echo "Current script: $IPV6_SCRIPT"
            echo -n "Enter new IPv6 script path: "
            read new_script
            IPV6_SCRIPT="$new_script"
            save_config
            echo -e "${GREEN}IPv6 script path updated${NC}"
            sleep 2
            ;;
        10)
            echo ""
            echo "Current custom commands: $CUSTOM_COMMANDS"
            echo "Enter new custom commands (or leave empty to clear):"
            read -r new_commands
            CUSTOM_COMMANDS="$new_commands"
            save_config
            echo -e "${GREEN}Custom commands updated${NC}"
            sleep 2
            ;;
        11)
            clear
            echo -e "${BLUE}=== Current Configuration ===${NC}"
            cat "$CONFIG_FILE"
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        12)
            clear
            echo "Showing live logs (Ctrl+C to exit)..."
            echo ""
            sudo tail -f "$LOG_FILE"
            ;;
        13)
            clear
            echo -e "${BLUE}=== Last 50 Log Lines ===${NC}"
            sudo tail -n 50 "$LOG_FILE"
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        14)
            echo -n "Are you sure you want to clear logs? (yes/no): "
            read confirm
            if [ "$confirm" = "yes" ]; then
                sudo truncate -s 0 "$LOG_FILE"
                echo -e "${GREEN}Logs cleared${NC}"
            fi
            sleep 2
            ;;
        15)
            clear
            echo -e "${BLUE}=== PM2 Process Status ===${NC}"
            pm2 list
            echo ""
            pm2 info ms 2>/dev/null || echo "No PM2 process named 'ms' found"
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        16)
            echo ""
            echo -e "${YELLOW}╔════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║            TEST MODE - 5 MINUTE RESTART               ║${NC}"
            echo -e "${YELLOW}╚════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo "This will temporarily set the restart interval to 5 minutes"
            echo "for testing purposes. The service will restart every 300 seconds."
            echo ""
            echo -e "${RED}WARNING: This is for testing only!${NC}"
            echo "Remember to restore normal settings when done."
            echo ""
            echo -n "Continue with test mode? (yes/no): "
            read confirm

            if [ "$confirm" = "yes" ]; then
                ORIGINAL_INTERVAL=$RESTART_INTERVAL
                RESTART_INTERVAL=300
                save_config

                echo ""
                echo -e "${GREEN}✓ Test mode activated${NC}"
                echo "  Restart interval: 5 minutes (300 seconds)"
                echo ""
                echo "Restarting timer to apply test settings..."
                sudo systemctl restart $TIMER_NAME

                echo ""
                echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
                echo -e "${YELLOW}  Test mode is now active!${NC}"
                echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
                echo ""
                echo "The service will now restart every 5 minutes."
                echo ""
                echo "To monitor restarts in real-time:"
                echo "  Option 12) Live Logs"
                echo "  Option 17) Restart Countdown"
                echo ""
                echo "To restore normal settings:"
                echo "  Option 7) Change restart interval back to your preferred hours"
                echo ""
                echo "Original interval was: $((ORIGINAL_INTERVAL / 3600)) hours"
                echo ""
                echo "Press Enter to continue..."
                read
            else
                echo -e "${YELLOW}Test mode cancelled${NC}"
                sleep 2
            fi
            ;;
        17)
            exec "$0" -countdown
            ;;
        18)
            echo -n "Are you sure you want to reboot the VPS now? (yes/no): "
            read confirm
            if [ "$confirm" = "yes" ]; then
                echo -e "${YELLOW}Rebooting VPS...${NC}"
                sudo /sbin/reboot
            else
                echo -e "${GREEN}Reboot cancelled${NC}"
                sleep 2
            fi
            ;;
        19)
            echo "Current periodic VPS reboot: $ENABLE_VPS_REBOOT"
            if [ "$ENABLE_VPS_REBOOT" = "true" ]; then
                ENABLE_VPS_REBOOT=false
                echo -e "${YELLOW}Disabling periodic VPS reboot...${NC}"
                sudo systemctl stop $REBOOT_SERVICE || true
                sudo systemctl disable $REBOOT_SERVICE || true
            else
                ENABLE_VPS_REBOOT=true
                echo -e "${GREEN}Enabling periodic VPS reboot...${NC}"
                sudo systemctl restart $REBOOT_SERVICE || sudo systemctl start $REBOOT_SERVICE
                sudo systemctl enable $REBOOT_SERVICE
            fi
            save_config
            echo -e "${GREEN}Saved.${NC}"
            sleep 2
            ;;
        20)
            clear
            echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       VPS REBOOT TRACKING STATUS                                  ║${NC}"
            echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${CYAN}Periodic Reboot:${NC} ${ENABLE_VPS_REBOOT}"
            echo -e "${CYAN}Restart Interval:${NC} $((RESTART_INTERVAL / 3600))h ($RESTART_INTERVAL seconds)"
            echo ""

            if [ -f "$REBOOT_TIMESTAMP_FILE" ]; then
                LAST_REBOOT_TS=$(cat "$REBOOT_TIMESTAMP_FILE" 2>/dev/null || echo "0")
                if [ "$LAST_REBOOT_TS" != "0" ]; then
                    echo -e "${GREEN}Last Reboot Triggered:${NC} $(date -d "@$LAST_REBOOT_TS" '+%Y-%m-%d %H:%M:%S')"
                    echo -e "${GREEN}Trigger Timestamp:${NC} $LAST_REBOOT_TS"
                fi
            fi

            if [ -f "$BOOT_TIMESTAMP_FILE" ]; then
                ACTUAL_BOOT_TS=$(cat "$BOOT_TIMESTAMP_FILE" 2>/dev/null || echo "0")
                if [ "$ACTUAL_BOOT_TS" != "0" ]; then
                    echo -e "${GREEN}Actual System Boot:${NC} $(date -d "@$ACTUAL_BOOT_TS" '+%Y-%m-%d %H:%M:%S')"
                    echo -e "${GREEN}Boot Timestamp:${NC} $ACTUAL_BOOT_TS"

                    if [ -f "$REBOOT_TIMESTAMP_FILE" ] && [ "$LAST_REBOOT_TS" != "0" ]; then
                        BOOT_DURATION=$((ACTUAL_BOOT_TS - LAST_REBOOT_TS))
                        if [ "$BOOT_DURATION" -gt 0 ]; then
                            echo -e "${CYAN}Boot Duration:${NC} ${BOOT_DURATION}s"
                        fi
                    fi
                fi
            fi

            if [ -f "$PM2_INSTANCES_FILE" ]; then
                list_instances
            else
                echo -e "${YELLOW}No PM2 instances configured.${NC}"
            fi

            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        21)
            echo -e "${YELLOW}Resetting reboot timer...${NC}"
            if [ -f "$REBOOT_TIMESTAMP_FILE" ]; then
                sudo rm -f "$REBOOT_TIMESTAMP_FILE"
                echo -e "${GREEN}Reboot timer reset!${NC}"
                echo -e "Next service trigger will reboot if periodic reboot is enabled."
            else
                echo -e "${YELLOW}No reboot timestamp file found.${NC}"
            fi
            sleep 2
            ;;
        22)
            echo "Current Update on Boot: $ENABLE_UPDATE_ON_BOOT"
            if [ "$ENABLE_UPDATE_ON_BOOT" = "true" ]; then
                ENABLE_UPDATE_ON_BOOT=false
                echo -e "${YELLOW}Disabling update on boot...${NC}"
            else
                ENABLE_UPDATE_ON_BOOT=true
                echo -e "${GREEN}Enabling update on boot...${NC}"
            fi
            save_config
            echo -e "${GREEN}Saved.${NC}"
            sleep 2
            ;;
        23)
            clear
            echo -e "${BLUE}[ INIT ] IPv6 -> PM2 fresh start${NC}"
            load_config
            run_ipv6_twice_and_verify
            echo -e "${BLUE}[*] Switching to: ${GREEN}$WORKING_DIR${NC}"
            cd "$WORKING_DIR" 2>/dev/null || { echo -e "${RED}[!] Cannot cd to $WORKING_DIR${NC}"; sleep 2; continue; }
            echo -e "${BLUE}[*] Stopping and deleting all PM2 processes...${NC}"
            pm2 delete all 2>/dev/null || true
            pm2 kill 2>/dev/null || true
            sleep 2
            echo -e "${BLUE}[*] Starting fresh pm2 'ms'...${NC}"
            pm2 start . --name ms --time
            pm2 save --force
            echo -e "${GREEN}[✓] pm2 'ms' started fresh${NC}"
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        24)
            clear
            echo -e "${BLUE}[ ATTACH ] PM2 'ms' in ${GREEN}$WORKING_DIR${NC}"
            load_config
            if pm2_is_ms_in_workdir; then
                echo -e "${GREEN}[✓] 'ms' already running in $WORKING_DIR — attaching...${NC}"
                cd "$WORKING_DIR" 2>/dev/null || true
                pm2 logs ms --lines 50
            else
                echo -e "${YELLOW}[*] 'ms' not running from $WORKING_DIR — starting attached...${NC}"
                cd "$WORKING_DIR" 2>/dev/null || { echo -e "${RED}[!] Cannot cd to $WORKING_DIR${NC}"; sleep 2; continue; }
                pm2 start . --name ms --attach --time
            fi
            ;;
        25)
            clear
            echo -e "${BLUE}╔════════════════════════════════ MEMORY USAGE ════════════════════════════════╗${NC}"
            echo -e "${BLUE}║${NC} System ${BLUE}║${NC}"
            echo -e "${BLUE}╟──────────────────────────────────────────────────────────────────────────────╢${NC}"
            if command -v free >/dev/null 2>&1; then
                free -h
            else
                echo "free not available"
            fi
            echo -e "${BLUE}╟──────────────────────────────────────────────────────────────────────────────╢${NC}"
            echo -e "${BLUE}║${NC} Top processes by memory ${BLUE}║${NC}"
            echo -e "${BLUE}╟────────┬─────────────────────────┬──────┬──────────╢${NC}"
            printf "${BLUE}║${NC} %-6s ${BLUE}│${NC} %-23s ${BLUE}│${NC} %-4s ${BLUE}│${NC} %-8s ${BLUE}║${NC}\n" "PID" "COMMAND" "%MEM" "RSS(MB)"
            echo -e "${BLUE}╟────────┼─────────────────────────┼──────┼──────────╢${NC}"
            if command -v ps >/dev/null 2>&1; then
                ps -eo pid=,comm=,pmem=,rss= --sort=-pmem | head -n 20 | awk '
                {
                  pid=$1; cmd=$2; pmem=$3; rss_kb=$4+0;
                  rss_mb=rss_kb/1024.0;
                  if (length(cmd)>23) cmd=substr(cmd,1,23);
                  printf "║ %-6s │ %-23s │ %-4s │ %8.1f ║\n", pid, cmd, pmem, rss_mb
                }'
            else
                echo -e "${BLUE}║${NC} ps not available${BLUE}║${NC}"
            fi
            echo -e "${BLUE}╚────────┴─────────────────────────┴──────┴──────────╝${NC}"
            echo ""
            echo -e "${BLUE}╔════════════════════════════════ PM2 PROCESSES ═══════════════════════════════╗${NC}"
            if command -v pm2 >/dev/null 2>&1; then
                pm2 list --no-color || pm2 ls --no-color || echo "pm2 list not available"
            else
                echo "pm2 not installed"
            fi
            echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${DIM}Press Enter to return to menu...${NC}"
            read
            ;;
        26)
            live_pm2_monitor
            ;;
        27)
            clear
            echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       REBOOT HISTORY (Last 15 entries)                            ║${NC}"
            echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""

            if [ ! -f "$REBOOT_DB_FILE" ]; then
                echo -e "${YELLOW}No reboot database found${NC}"
                echo ""
                echo "Press Enter to continue..."
                read
                continue
            fi

            TOTAL_REBOOTS=$(($(wc -l < "$REBOOT_DB_FILE") - 1))

            if [ "$TOTAL_REBOOTS" -eq 0 ]; then
                echo -e "${YELLOW}No reboots recorded yet${NC}"
                echo ""
                echo "Press Enter to continue..."
                read
                continue
            fi

            echo -e "${GREEN}Total reboots recorded: $TOTAL_REBOOTS${NC}"
            echo ""
            printf "${CYAN}%-20s %-20s %-12s %-15s %s${NC}\n" "Timestamp" "Date/Time" "Uptime" "Elapsed" "Reason"
            echo "─────────────────────────────────────────────────────────────────────────────────────────"

            tail -n 16 "$REBOOT_DB_FILE" | tail -n +2 | while IFS=',' read -r timestamp datetime uptime reason interval elapsed; do
                uptime_h=$((uptime / 3600))
                uptime_m=$(((uptime % 3600) / 60))
                uptime_readable="${uptime_h}h ${uptime_m}m"
                elapsed_h=$((elapsed / 3600))
                elapsed_m=$(((elapsed % 3600) / 60))
                elapsed_readable="${elapsed_h}h ${elapsed_m}m"
                printf "%-20s %-20s %-12s %-15s %s\n" "$timestamp" "$datetime" "$uptime_readable" "$elapsed_readable" "$reason"
            done

            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        28)
            clear
            echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       REBOOT STATISTICS                                            ║${NC}"
            echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""

            if [ ! -f "$REBOOT_DB_FILE" ]; then
                echo -e "${YELLOW}No reboot database found${NC}"
                echo ""
                echo "Press Enter to continue..."
                read
                continue
            fi

            TOTAL_REBOOTS=$(($(wc -l < "$REBOOT_DB_FILE") - 1))

            if [ "$TOTAL_REBOOTS" -eq 0 ]; then
                echo -e "${YELLOW}No reboots recorded yet${NC}"
                echo ""
                echo "Press Enter to continue..."
                read
                continue
            fi

            echo -e "${GREEN}Total Reboots:${NC} $TOTAL_REBOOTS"

            FIRST_REBOOT=$(tail -n +2 "$REBOOT_DB_FILE" | head -n 1 | cut -d',' -f2)
            LAST_REBOOT=$(tail -n 1 "$REBOOT_DB_FILE" | cut -d',' -f2)

            echo -e "${GREEN}First Reboot:${NC} $FIRST_REBOOT"
            echo -e "${GREEN}Last Reboot:${NC} $LAST_REBOOT"
            echo ""

            TOTAL_UPTIME=0
            COUNT=0
            while IFS=',' read -r timestamp datetime uptime reason interval elapsed; do
                if [ "$uptime" != "uptime_before" ] && [ -n "$uptime" ]; then
                    TOTAL_UPTIME=$((TOTAL_UPTIME + uptime))
                    COUNT=$((COUNT + 1))
                fi
            done < "$REBOOT_DB_FILE"

            if [ "$COUNT" -gt 0 ]; then
                AVG_UPTIME=$((TOTAL_UPTIME / COUNT))
                AVG_UPTIME_H=$((AVG_UPTIME / 3600))
                AVG_UPTIME_M=$(((AVG_UPTIME % 3600) / 60))
                echo -e "${CYAN}Average Uptime Before Reboot:${NC} ${AVG_UPTIME_H}h ${AVG_UPTIME_M}m"
            fi

            TOTAL_ELAPSED=0
            ELAPSED_COUNT=0
            while IFS=',' read -r timestamp datetime uptime reason interval elapsed; do
                if [ "$elapsed" != "elapsed_since_last" ] && [ -n "$elapsed" ] && [ "$elapsed" != "0" ]; then
                    TOTAL_ELAPSED=$((TOTAL_ELAPSED + elapsed))
                    ELAPSED_COUNT=$((ELAPSED_COUNT + 1))
                fi
            done < "$REBOOT_DB_FILE"

            if [ "$ELAPSED_COUNT" -gt 0 ]; then
                AVG_ELAPSED=$((TOTAL_ELAPSED / ELAPSED_COUNT))
                AVG_ELAPSED_H=$((AVG_ELAPSED / 3600))
                AVG_ELAPSED_M=$(((AVG_ELAPSED % 3600) / 60))
                echo -e "${CYAN}Average Time Between Reboots:${NC} ${AVG_ELAPSED_H}h ${AVG_ELAPSED_M}m"
            fi

            echo ""
            echo -e "${MAGENTA}Reboot Reasons Summary:${NC}"
            tail -n +2 "$REBOOT_DB_FILE" | cut -d',' -f4 | sort | uniq -c | sort -rn | while read count reason; do
                echo -e "  ${count}x - ${reason}"
            done

            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        29)
            clear
            echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       REBOOT LOG (Last 30 lines)                                   ║${NC}"
            echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""

            if [ ! -f "$REBOOT_LOG_FILE" ]; then
                echo -e "${YELLOW}No reboot log found${NC}"
                echo ""
                echo "Press Enter to continue..."
                read
                continue
            fi

            if [ ! -s "$REBOOT_LOG_FILE" ]; then
                echo -e "${YELLOW}Reboot log is empty${NC}"
                echo ""
                echo "Press Enter to continue..."
                read
                continue
            fi

            tail -n 30 "$REBOOT_LOG_FILE"
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        30)
            add_instance_interactive
            sleep 2
            ;;
        31)
            list_instances
            echo "Press Enter to continue..."
            read
            ;;
        32)
            remove_instance
            sleep 2
            ;;
        33)
            edit_instance_delay
            sleep 2
            ;;
        34)
            set_main_instance
            sleep 2
            ;;
        35)
            edit_default_pm2_delay
            sleep 2
            ;;
        36)
            echo -n "Start all configured PM2 instances NOW (ignore per-instance delays)? (yes/no): "
            read -r sconfirm
            if [ "$sconfirm" = "yes" ] || [ "$sconfirm" = "y" ]; then
                start_instances_now
            else
                echo -e "${YELLOW}Cancelled.${NC}"
            fi
            sleep 2
            ;;
        37)
            echo -n "Start last-added PM2 instance NOW? (yes/no): "
            read -r s2
            if [ "$s2" = "yes" ] || [ "$s2" = "y" ]; then
                start_last_instance_now
            else
                echo -e "${YELLOW}Cancelled.${NC}"
            fi
            sleep 2
            ;;
        67)
            ms__plugin_menu_ui
            ;;
        91)
            clear
            echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║            UPDATE FROM GITHUB (OPTION 91)           ║${NC}"
            echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo "This will download and run the latest installer from:"
            echo "  $UPDATE_URL"
            echo ""
            echo -n "Proceed with update? (yes/no): "
            read confirm
            if [ "$confirm" != "yes" ]; then
                echo -e "${YELLOW}Update cancelled${NC}"
                sleep 2
                continue
            fi

            TMP_FILE="/tmp/install-ms-manager.sh"
            echo "Downloading installer..."
            if command -v curl >/dev/null 2>&1; then
                if ! curl -fsSL "$UPDATE_URL" -o "$TMP_FILE"; then
                    echo -e "${RED}Failed to download with curl${NC}"
                    sleep 2
                    continue
                fi
            elif command -v wget >/dev/null 2>&1; then
                if ! wget -qO "$TMP_FILE" "$UPDATE_URL"; then
                    echo -e "${RED}Failed to download with wget${NC}"
                    sleep 2
                    continue
                fi
            else
                echo -e "${RED}Neither curl nor wget is available${NC}"
                sleep 2
                continue
            fi

            chmod +x "$TMP_FILE"
            echo -e "${GREEN}Installer downloaded.${NC} Running update..."
            sudo bash "$TMP_FILE"
            echo -e "${GREEN}Update process finished.${NC}"
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
                88)
            clear
            echo -e "${CYAN}Launching Python App Manager...${NC}"
            PYAPP="/usr/local/bin/ms-python-app-manager.sh"
            RAW_URL="https://raw.githubusercontent.com/pgwiz/botPaas/refs/heads/main/ms-python-app-manager.sh"
            TMP="/tmp/ms-python-app-manager.sh.$$"

            # helper: download RAW_URL -> TMP
            download_tmp() {
                if command -v curl >/dev/null 2>&1; then
                    curl -fsSL "$RAW_URL" -o "$TMP"
                    return $?
                elif command -v wget >/dev/null 2>&1; then
                    wget -qO "$TMP" "$RAW_URL"
                    return $?
                else
                    return 2
                fi
            }

            # If not present, offer to install
            if [ ! -x "$PYAPP" ]; then
                echo "ms-python-app-manager not found at $PYAPP."
                read -r -p "Download & install from repo now? (yes/no) [yes]: " _resp
                _resp=${_resp:-yes}
                if [[ "$_resp" =~ ^(yes|y)$ ]]; then
                    if ! download_tmp; then
                        echo "⚠ Failed to download ms-python-app-manager (curl/wget missing or network issue)."
                        rm -f "$TMP" >/dev/null 2>&1 || true
                        sleep 2
                        continue
                    fi
                    # sanity check
                    if ! grep -m1 -E '^#!' "$TMP" >/dev/null 2>&1; then
                        echo "⚠ Downloaded file doesn't look like a script. Saved to $TMP for inspection."
                        sleep 2
                        continue
                    fi
                    mkdir -p "$(dirname "$PYAPP")"
                    mv "$TMP" "$PYAPP"
                    chmod 755 "$PYAPP"
                    echo "✓ Installed $PYAPP"
                else
                    echo "Skipping install of Python App Manager."
                    sleep 1
                    continue
                fi
            else
                # Offer to update if present
                read -r -p "ms-python-app-manager exists. Check for update from repo? (yes/no) [no]: " _upd
                _upd=${_upd:-no}
                if [[ "$_upd" =~ ^(yes|y)$ ]]; then
                    if ! download_tmp; then
                        echo "⚠ Failed to download update."
                        rm -f "$TMP" >/dev/null 2>&1 || true
                        sleep 2
                        continue
                    fi
                    if ! grep -m1 -E '^#!' "$TMP" >/dev/null 2>&1; then
                        echo "⚠ Downloaded file invalid. Saved to $TMP for inspection."
                        rm -f "$TMP" >/dev/null 2>&1 || true
                        sleep 2
                        continue
                    fi
                    if cmp -s "$TMP" "$PYAPP"; then
                        echo "✓ Already up-to-date."
                        rm -f "$TMP"
                    else
                        mv "$TMP" "$PYAPP"
                        chmod 755 "$PYAPP"
                        echo "✓ Updated $PYAPP"
                    fi
                fi
            fi

            # Run the manager (in a subshell so ms-manager returns after it finishes)
            if [ -x "$PYAPP" ]; then
                echo ""
                # run with bash to ensure consistent behavior
                bash -c "$PYAPP"
                echo ""
                echo -e "${GREEN}Returned from Python App Manager.${NC}"
                echo -n "Press Enter to continue..."
                read
            else
                echo "⚠ Python App Manager not installed/executable. Nothing to run."
                sleep 2
            fi
            ;;

        99)
            clear
            echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║              UNINSTALL MS SERVER MANAGER              ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}WARNING: This will completely remove MS Server Manager!${NC}"
            echo ""
            echo "The following will be removed:"
            echo "  • Systemd service (ms-server.service)"
            echo "  • Systemd timer (ms-server.timer)"
            echo "  • Reboot daemon (ms-reboot.service)"
            echo "  • Service scripts (/usr/local/bin/ms-server-run.sh)"
            echo "  • Management script (/usr/local/bin/ms-manager)"
            echo "  • Configuration directory (/etc/ms-server/)"
            echo "  • Log file (/var/log/ms-server.log)"
            echo "  • Reboot daemon state (/var/lib/ms-manager)"
            echo ""
            echo -e "${YELLOW}NOTE: Your application in /root/ms will NOT be deleted${NC}"
            echo -e "${YELLOW}NOTE: PM2 processes will NOT be stopped${NC}"
            echo ""
            echo -n "Type 'UNINSTALL' to confirm (or anything else to cancel): "
            read confirm

            if [ "$confirm" = "UNINSTALL" ]; then
                echo ""
                echo "Uninstalling MS Server Manager..."
                echo ""

                echo "→ Stopping timer..."
                sudo systemctl stop $TIMER_NAME 2>/dev/null || true

                echo "→ Disabling timer..."
                sudo systemctl disable $TIMER_NAME 2>/dev/null || true

                echo "→ Stopping service..."
                sudo systemctl stop $SERVICE_NAME 2>/dev/null || true

                echo "→ Disabling service..."
                sudo systemctl disable $SERVICE_NAME 2>/dev/null || true

                echo "→ Stopping reboot daemon..."
                sudo systemctl stop $REBOOT_SERVICE 2>/dev/null || true
                sudo systemctl disable $REBOOT_SERVICE 2>/dev/null || true

                echo "→ Removing systemd service file..."
                sudo rm -f /etc/systemd/system/$SERVICE_NAME.service

                echo "→ Removing systemd timer file..."
                sudo rm -f /etc/systemd/system/$TIMER_NAME

                echo "→ Removing reboot daemon service..."
                sudo rm -f /etc/systemd/system/$REBOOT_SERVICE

                echo "→ Removing service scripts..."
                sudo rm -f /usr/local/bin/ms-server-run.sh
                sudo rm -f /usr/local/bin/ms-manager
                sudo rm -f /usr/local/bin/ms-reboot-daemon.sh

                echo "→ Removing configuration directory..."
                sudo rm -rf /etc/ms-server

                echo "→ Removing log file..."
                sudo rm -f /var/log/ms-server.log
                sudo rm -f /var/log/ms-reboot-daemon.log

                echo "→ Removing reboot daemon state..."
                sudo rm -rf /var/lib/ms-manager

                echo "→ Reloading systemd daemon..."
                sudo systemctl daemon-reload

                echo ""
                echo -e "${GREEN}✓ MS Server Manager has been completely uninstalled${NC}"
                echo ""
                echo "Your application files in /root/ms are still intact."
                echo "PM2 processes are still running (use 'pm2 list' to check)."
                echo ""
                echo "Press Enter to exit..."
                read
                exit 0
            else
                echo ""
                echo -e "${YELLOW}Uninstall cancelled${NC}"
                sleep 2
            fi
            ;;
        0)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            sleep 2
            ;;
    esac
done
MANAGER_EOF

chmod +x "$MANAGER_SCRIPT"
echo "✓ Management script created at $MANAGER_SCRIPT"


# -----------------------------------------------------------------------------
# Dynamic menus/ plugin system + PM2 follow-up watchdog
# -----------------------------------------------------------------------------

MENUS_DIR="$SCRIPT_DIR/menus"
mkdir -p "$MENUS_DIR"

# Create registry + template only if missing (preserves user customizations)
if [ ! -f "$MENUS_DIR/ref.sh" ]; then
cat > "$MENUS_DIR/ref.sh" <<'__MS_MENUS_REF__'
# Registry for ms-manager plugin menus
# Format: "scriptFile.sh|Menu title"
MS_MENU_REGISTRY=(
  "setup_follow_up.sh|PM2 follow-up watchdog"
  "setup_reboot_ops_timer.sh|Reboot ops timer (systemd)"
  "ipv6-dns.sh|IPv6 DNS Resolver Setup"
  "templateMenu.sh|Template menu (copy me)"
)

__MS_MENUS_REF__
chmod 644 "$MENUS_DIR/ref.sh"
fi

# Ensure new plugins are registered (preserves user edits)
if [ -f "$MENUS_DIR/ref.sh" ] && ! grep -q "setup_reboot_ops_timer.sh" "$MENUS_DIR/ref.sh"; then
    awk 'BEGIN{added=0} /^[[:space:]]*\)[[:space:]]*$/ && !added {print "  \"setup_reboot_ops_timer.sh|Reboot ops timer (systemd)\""; added=1} {print}' "$MENUS_DIR/ref.sh" > "$MENUS_DIR/ref.sh.tmp" && mv "$MENUS_DIR/ref.sh.tmp" "$MENUS_DIR/ref.sh"
    chmod 644 "$MENUS_DIR/ref.sh"
fi

if [ ! -f "$MENUS_DIR/templateMenu.sh" ]; then
cat > "$MENUS_DIR/templateMenu.sh" <<'__MS_TEMPLATE_MENU__'
#!/bin/bash
# Template plugin menu for ms-manager dynamic menus/
# Copy this file, rename it, and register it in ref.sh (optional).

echo "=============================="
echo " Template Menu"
echo "=============================="
echo ""
echo "Put your menu logic here."
echo ""
read -rp "Press Enter to return..." _

__MS_TEMPLATE_MENU__
chmod +x "$MENUS_DIR/templateMenu.sh"
fi

# Always ensure these plugins exist (safe to overwrite)
cat > "$MENUS_DIR/ipv6-dns.sh" <<'__MS_IPV6_MENU__'
#!/bin/bash
sudo bash /usr/local/bin/setup-ipv6-dns.sh
__MS_IPV6_MENU__
chmod +x "$MENUS_DIR/ipv6-dns.sh"

cat > "$MENUS_DIR/setup_follow_up.sh" <<'__MS_SETUP_FOLLOWUP__'
#!/bin/bash
set -euo pipefail

MENUS_DIR="/usr/local/bin/menus"
CONFIG_DIR="/etc/ms-server"
CONF_FILE="$CONFIG_DIR/follow_up.conf"
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

install_files() {
    echo "Installing follow-up scripts + systemd units..."

    # follow_up.sh
    cat > "$FOLLOWUP_SCRIPT" <<'__MS_FOLLOWUP_SH__'
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

__MS_FOLLOWUP_SH__
    chmod +x "$FOLLOWUP_SCRIPT"

    # IPv6 script
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
    if [ -n "${u1:-}" ]; then save_conf_kv "FOLLOWUP_SETUP_URL" ""$u1""; fi
    if [ -n "${u2:-}" ]; then save_conf_kv "FOLLOWUP_SCRIPT_URL" ""$u2""; fi
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
        echo "6) Auto-update toggle"
        echo "7) Set auto-update URLs"
        echo "8) PM2 instances: add (ms-manager)"
        echo "9) PM2 instances: remove (ms-manager)"
        echo "10) PM2 instances: list (ms-manager)"
        echo "11) Start configured PM2 instances now (ms-manager)"
        echo "12) Show instances + pm2 list"
        echo "13) Run follow_up now"
        echo ""
        echo "0) Back"
        echo ""
        read -rp "Select option: " opt

        case "$opt" in
            1) install_files; ensure_conf; read -rp "Press Enter to continue..." ;;
            2) enable_timer; sleep 1 ;;
            3) disable_timer; sleep 1 ;;
            4) status_timer; read -rp "Press Enter to continue..." ;;
            5) set_delay_override ;;
            6) toggle_auto_update ;;
            7) set_update_urls ;;
            8) ms_manager_add_instance ;;
            9) ms_manager_rm_instance ;;
            10) ms_manager_list_instances ;;
            11) ms_manager_start_now ;;
            12) show_pm2_instances ;;
            13) auto_update_if_needed; run_followup_now ;;
            0) exit 0 ;;
            *) echo "Invalid option"; sleep 1 ;;
        esac
    done
}

need_root
ensure_conf
auto_update_if_needed
main_menu

__MS_SETUP_FOLLOWUP__
chmod +x "$MENUS_DIR/setup_follow_up.sh"

# Reboot ops timer plugin (safe to overwrite)
cat > "$MENUS_DIR/setup_reboot_ops_timer.sh" <<'__MS_SETUP_REBOOT_OPS_TIMER__'
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

__MS_SETUP_REBOOT_OPS_TIMER__
chmod +x "$MENUS_DIR/setup_reboot_ops_timer.sh"

# Install the underlying scripts used by the follow-up watchdog
cat > "/usr/local/bin/setup-ipv6-dns.sh" <<'__MS_IPV6_DNS__'
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

__MS_IPV6_DNS__
chmod +x "/usr/local/bin/setup-ipv6-dns.sh"

cat > "/usr/local/bin/follow_up.sh" <<'__MS_FOLLOWUP__'
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

__MS_FOLLOWUP__
chmod +x "/usr/local/bin/follow_up.sh"

# Follow-up config (only create if missing)
if [ ! -f "$CONFIG_DIR/follow_up.conf" ]; then
cat > "$CONFIG_DIR/follow_up.conf" <<'__MS_FOLLOWUP_CONF__'
# ms-follow-up config
FOLLOWUP_ENABLED=1
FOLLOWUP_MIN_DELAY_SEC=300
FOLLOWUP_EXTRA_DELAY_IF_MIN_ABOVE_SEC=60
FOLLOWUP_DELAY_OVERRIDE_SEC=0
FOLLOWUP_FIRST_START_GAP_SEC=30
FOLLOWUP_BETWEEN_START_GAP_SEC=90
PM2_USER=root

# Auto-update (optional)
FOLLOWUP_AUTO_UPDATE=0
FOLLOWUP_SETUP_URL=""
FOLLOWUP_SCRIPT_URL=""
__MS_FOLLOWUP_CONF__
chmod 644 "$CONFIG_DIR/follow_up.conf"
fi

# systemd unit + timer (installed but you can disable via menus/setup_follow_up.sh)
cat > "/etc/systemd/system/ms-follow-up.service" <<'__MS_FOLLOWUP_SERVICE__'
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
__MS_FOLLOWUP_SERVICE__

cat > "/etc/systemd/system/ms-follow-up.timer" <<'__MS_FOLLOWUP_TIMER__'
[Unit]
Description=Run MS Manager PM2 Follow-up after boot

[Timer]
OnBootSec=30s
Persistent=true
Unit=ms-follow-up.service

[Install]
WantedBy=timers.target
__MS_FOLLOWUP_TIMER__

sudo systemctl daemon-reload

# Enable by default (can be disabled from the setup_follow_up menu)
sudo systemctl enable --now ms-follow-up.timer >/dev/null 2>&1 || true

echo "✓ Menus plugin system installed at $MENUS_DIR"
echo "✓ Follow-up watchdog installed (ms-follow-up.timer)"




#

# Install ms-python-app-manager.sh from raw GitHub URL and wire option 88 into ms-manager

#

# This attempts to download the script, install it to /usr/local/bin, and add a menu entry

# and case handler (option 88) to the ms-manager script so users can launch the Python App Manager.

#

PYAPP_DEST="/usr/local/bin/ms-python-app-manager.sh"

PYAPP_TMP="/tmp/ms-python-app-manager.sh.$$"

RAW_PYAPP_URL="https://raw.githubusercontent.com/pgwiz/botPaas/refs/heads/main/ms-python-app-manager.sh"

echo "→ Attempting to fetch ms-python-app-manager.sh from $RAW_PYAPP_URL..."

downloaded="false"

if command -v curl >/dev/null 2>&1; then

    if curl -fsSL "$RAW_PYAPP_URL" -o "$PYAPP_TMP"; then

        downloaded="true"

    fi

elif command -v wget >/dev/null 2>&1; then

    if wget -qO "$PYAPP_TMP" "$RAW_PYAPP_URL"; then

        downloaded="true"

    fi

else

    echo "⚠ Neither curl nor wget is available to fetch ms-python-app-manager.sh"

fi

if [ "$downloaded" = "true" ]; then

    # basic sanity: require a shebang

    if ! grep -m1 -E '^#!' "$PYAPP_TMP" >/dev/null 2>&1; then

        echo "⚠ Downloaded file doesn't look like a script (no shebang). Saved to $PYAPP_TMP for inspection."

    else

        mkdir -p "$(dirname "$PYAPP_DEST")"

        if [ -f "$PYAPP_DEST" ]; then

            if cmp -s "$PYAPP_TMP" "$PYAPP_DEST"; then

                echo "✓ ms-python-app-manager.sh already up-to-date at $PYAPP_DEST"

                rm -f "$PYAPP_TMP"

            else

                mv "$PYAPP_TMP" "$PYAPP_DEST"

                chmod 755 "$PYAPP_DEST"

                echo "✓ Updated ms-python-app-manager.sh -> $PYAPP_DEST"

            fi

        else

            mv "$PYAPP_TMP" "$PYAPP_DEST"

            chmod 755 "$PYAPP_DEST"

            echo "✓ Installed ms-python-app-manager.sh -> $PYAPP_DEST"

        fi

    fi

else

    rm -f "$PYAPP_TMP" >/dev/null 2>&1 || true

    echo "⚠ Could not download ms-python-app-manager.sh from $RAW_PYAPP_URL (skipping)"

fi

# Wire the script into the ms-manager menu (option 88) if installed

if [ -x "$PYAPP_DEST" ] && [ -f "$MANAGER_SCRIPT" ]; then

    # Add a visible menu line under the PM2 INSTANCES section (if not already present)

    if ! grep -q "Python App Manager" "$MANAGER_SCRIPT"; then

        awk '{

            print $0

        }

        /PM2 INSTANCES/ && !x {

            print "  ${GREEN}88${NC}) Python App Manager"

            x=1

        }' "$MANAGER_SCRIPT" > "$MANAGER_SCRIPT.tmp" && mv "$MANAGER_SCRIPT.tmp" "$MANAGER_SCRIPT" || true

        echo "✓ Inserted menu label for option 88 in ms-manager"

    else

        echo "✓ ms-manager already contains a Python App Manager menu label"

    fi

    # Insert a case handler '88)' before option 0) (Exit) if not present

    if ! grep -qE '^[[:space:]]*88\)' "$MANAGER_SCRIPT"; then

        awk 'BEGIN{ins=0}

        {

            if(ins==0 && $0 ~ /^[[:space:]]*0\)/) {

                # Insert handler for 88) just before the "0) Exit" option

                print "        88)"

                print "            clear"

                print "            echo \"Launching Python App Manager...\""

                print "            /usr/local/bin/ms-python-app-manager.sh"

                print "            ;;"

                ins=1

            }

            print $0

        }' "$MANAGER_SCRIPT" > "$MANAGER_SCRIPT.tmp" && mv "$MANAGER_SCRIPT.tmp" "$MANAGER_SCRIPT" || true

        echo "✓ Added case handler 88) to ms-manager"

    else

        echo "✓ ms-manager already contains case handler for 88)"

    fi

    chmod +x "$MANAGER_SCRIPT" || true

fi
# Create log files
touch /var/log/ms-server.log
chmod 644 /var/log/ms-server.log
touch /var/log/ms-reboot-daemon.log
chmod 644 /var/log/ms-reboot-daemon.log

# Reload systemd
systemctl daemon-reload
echo "✓ Systemd daemon reloaded"

# Enable the timer by default (but not the reboot daemon unless configured)
systemctl enable $SERVICE_NAME.timer >/dev/null 2>&1 || true

# If config specifies ENABLE_VPS_REBOOT=true, enable and start the reboot daemon
source "$CONFIG_DIR/config.conf"
if [ "${ENABLE_VPS_REBOOT}" = "true" ]; then
    systemctl enable "$REBOOT_SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$REBOOT_SERVICE" >/dev/null 2>&1 || true
fi

echo ""
echo "==================================="
echo "  Installation Complete!"
echo "==================================="
echo ""
echo "Enhanced Features (summary):"
echo "  ✓ Multiple PM2 instances (per-instance working dir + delay)"
echo "  ✓ One MAIN PM2 instance starts immediately; others start after delay"
echo "  ✓ Default PM2 extra delay configurable (default 300s / 5m)"
echo "  ✓ Start PM2 instances NOW (menu + CLI) to immediately start configured instances (staggered 2–5s gaps)"
echo "  ✓ Start last-added instance NOW (menu + CLI, CLI supports --no-confirm|-y)"
echo "  ✓ Prompt to start newly added instance immediately"
echo "  ✓ Accepts human-friendly delay formats when adding/editing (e.g., 5m, 30s, 1h30m)"
echo "  ✓ Reboot daemon supports SIGHUP to reload /var/lib/ms-manager/interval without systemd restart"
echo "  ✓ Reboot logging, statistics, live countdown, etc."
echo ""
echo "PM2 instance notes:"
echo "  • Instances are stored in $PM2_INSTANCES_FILE (CSV: name,working_dir,delay_seconds,is_main)"
echo "  • Main instance = is_main=true will start immediately on boot"
echo "  • Other instances start after their delay_seconds (default from config)"
echo ""
echo "Quick Start:"
echo "  1. Run: ms-manager"
echo "  2. Or use CLI: ms-manager -add-instance  (or -list-instances, -start-instances-now, -start-last-instance-now --no-confirm)"
echo ""
echo "Starting manager now..."
sleep 2

exec "$MANAGER_SCRIPT"
