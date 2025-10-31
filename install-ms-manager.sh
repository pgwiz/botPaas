#!/bin/bash

# MS Server Manager Installation Script - Enhanced Version
# Features: Auto VPS reboot with persistent tracking, countdown, CLI arguments, fresh PM2 start
set -e

SCRIPT_DIR="/usr/local/bin"
CONFIG_DIR="/etc/ms-server"
SERVICE_NAME="ms-server"
MANAGER_SCRIPT="$SCRIPT_DIR/ms-manager"
REBOOT_TIMESTAMP_FILE="$CONFIG_DIR/last_reboot_timestamp"
REBOOT_LOG_FILE="$CONFIG_DIR/reboot_history.log"
REBOOT_DB_FILE="$CONFIG_DIR/reboot_database.csv"

echo "==================================="
echo "  MS Server Manager Installation"
echo "      Enhanced Version v2.0"
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
EOF
    echo "✓ Configuration file created at $CONFIG_DIR/config.conf"
else
    echo "✓ Configuration file already exists, preserving settings"
fi

# Create the main service script
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

    # Get uptime in seconds
    if command -v awk >/dev/null 2>&1 && [ -r /proc/uptime ]; then
        uptime_sec=$(awk '{print int($1)}' /proc/uptime)
    fi

    # Append to log file
    echo "[$datetime] REBOOT TRIGGERED - Reason: $reason | Uptime before: ${uptime_sec}s | Interval: ${interval}s | Elapsed: ${elapsed}s" >> /etc/ms-server/reboot_history.log

    # Append to database CSV
    echo "$timestamp,$datetime,$uptime_sec,$reason,$interval,$elapsed" >> /etc/ms-server/reboot_database.csv

    log_message "Reboot logged to database: $reason (uptime: ${uptime_sec}s)"
}

log_message "=== MS Server Starting ==="

# Record actual boot time (when system came back up)
BOOT_TIMESTAMP_FILE="/etc/ms-server/actual_boot_timestamp"
CURRENT_BOOT_TIME=$(date +%s)

# Check system uptime to detect if this is a fresh boot
if command -v awk >/dev/null 2>&1 && [ -r /proc/uptime ]; then
    UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
else
    UPTIME_SEC=0
fi

# If uptime is less than 120 seconds, this is a fresh boot
if [ "$UPTIME_SEC" -lt 120 ]; then
    log_message "Fresh boot detected (uptime: ${UPTIME_SEC}s). Recording boot time: $CURRENT_BOOT_TIME"
    echo "$CURRENT_BOOT_TIME" > "$BOOT_TIMESTAMP_FILE"

    # Log to reboot database
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

    # First attempt
    log_message "Attempting IPv6 setup (1/2) via $IPV6_SCRIPT..."
    sudo chmod +x "$IPV6_SCRIPT" 2>/dev/null || true
    sudo "$IPV6_SCRIPT" 2>&1 | tee -a /var/log/ms-server.log || true
    sleep 2

    if check_ipv6; then
        log_message "✓ IPv6 connectivity confirmed after setup (1/2)"
        return 0
    fi

    # Second attempt
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

# Change to working directory
cd "$WORKING_DIR"
log_message "Changed to directory: $WORKING_DIR"

# FRESH PM2 START - Stop and delete all instances
log_message "Cleaning up all PM2 processes for fresh start..."
pm2 delete all 2>/dev/null || true
pm2 kill 2>/dev/null || true
sleep 2

# Start fresh PM2 daemon
log_message "Starting fresh PM2 daemon..."
pm2 ping 2>/dev/null || true

# Start the application fresh
log_message "Starting PM2 application (fresh start)..."
pm2 start . --name ms --time

# Save PM2 process list
pm2 save --force 2>/dev/null || true

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

# Conditionally reboot VPS if enabled (with persistent time tracking)
if [ "${ENABLE_VPS_REBOOT}" = "true" ]; then
    REBOOT_TIMESTAMP_FILE="/etc/ms-server/last_reboot_timestamp"
    CURRENT_TIME=$(date +%s)
    SHOULD_REBOOT=false

    # Check if timestamp file exists
    if [ -f "$REBOOT_TIMESTAMP_FILE" ]; then
        LAST_REBOOT_TIME=$(cat "$REBOOT_TIMESTAMP_FILE" 2>/dev/null || echo "0")
        TIME_SINCE_LAST_REBOOT=$((CURRENT_TIME - LAST_REBOOT_TIME))

        log_message "Time since last tracked reboot: ${TIME_SINCE_LAST_REBOOT}s (interval: ${RESTART_INTERVAL}s)"

        # Only reboot if enough time has passed
        if [ "$TIME_SINCE_LAST_REBOOT" -ge "$RESTART_INTERVAL" ]; then
            SHOULD_REBOOT=true
            log_message "Reboot interval reached. Proceeding with reboot..."
        else
            REMAINING=$((RESTART_INTERVAL - TIME_SINCE_LAST_REBOOT))
            log_message "Reboot not needed yet. Next reboot in ${REMAINING}s"
        fi
    else
        # First time - create timestamp file and reboot
        SHOULD_REBOOT=true
        log_message "First reboot - creating timestamp file"
    fi

    if [ "$SHOULD_REBOOT" = "true" ]; then
        # Log the reboot event
        if [ -f "$REBOOT_TIMESTAMP_FILE" ]; then
            ELAPSED_TIME=$((CURRENT_TIME - LAST_REBOOT_TIME))
            log_reboot "Scheduled periodic reboot" "$RESTART_INTERVAL" "$ELAPSED_TIME"
        else
            log_reboot "First scheduled reboot" "$RESTART_INTERVAL" "0"
        fi

        # Update timestamp before rebooting (persist to disk)
        echo "$CURRENT_TIME" > "$REBOOT_TIMESTAMP_FILE"
        chmod 644 "$REBOOT_TIMESTAMP_FILE"
        sync
        log_message "Reboot timestamp saved: $CURRENT_TIME ($(date -d "@$CURRENT_TIME" '+%Y-%m-%d %H:%M:%S'))"
        log_message "VPS reboot flag is enabled. Rebooting system now..."

        # Force filesystem sync to ensure timestamp is written
        sync
        sleep 1
        sync

        /usr/bin/systemctl reboot
    fi
fi

# Exit after successful startup
log_message "Service startup completed, exiting..."
exit 0
EOF

chmod +x "$SCRIPT_DIR/ms-server-run.sh"
echo "✓ Service script created at $SCRIPT_DIR/ms-server-run.sh"

# Create the systemd service file
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

# Create the systemd timer file for periodic restarts
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

# Create the management script with CLI arguments
cat > "$MANAGER_SCRIPT" <<'MANAGER_EOF'
#!/bin/bash

CONFIG_FILE="/etc/ms-server/config.conf"
SERVICE_NAME="ms-server"
LOG_FILE="/var/log/ms-server.log"
UPDATE_URL="https://raw.githubusercontent.com/pgwiz/botPaas/refs/heads/main/install-ms-manager.sh"
REBOOT_TIMESTAMP_FILE="/etc/ms-server/last_reboot_timestamp"
BOOT_TIMESTAMP_FILE="/etc/ms-server/actual_boot_timestamp"
REBOOT_LOG_FILE="/etc/ms-server/reboot_history.log"
REBOOT_DB_FILE="/etc/ms-server/reboot_database.csv"

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

# Show help
show_help() {
    cat << HELP
MS Server Manager - Enhanced Version v2.0

USAGE:
    ms-manager [OPTIONS]

OPTIONS:
    -h, --help              Show this help message
    -s, --status            Show service status
    -start                  Start the service
    -stop                   Stop the service
    -restart                Restart the service immediately
    -testm <minutes> [r]    Set test mode with custom interval
                            Add 'r' to enable reboot (e.g., -testm 5 r)
    -countdown              Show live restart countdown
    -logs [lines]           Show logs (default: 50 lines)
    -live                   Show live logs (tail -f)
    -interval <hours>       Set restart interval in hours
    -reboot-now             Reboot VPS immediately
    -reboot-on              Enable periodic VPS reboot
    -reboot-off             Disable periodic VPS reboot
    -reboot-status          Show reboot tracking status
    -reboot-reset           Reset reboot timer
    -reboot-history [n]     Show last n reboots (default: 10)
    -reboot-log [n]         Show last n lines of reboot log (default: 20)
    -reboot-stats           Show reboot statistics
    -update                 Update from GitHub
    -fresh-start            Force fresh PM2 start (delete all processes)
    -config                 View configuration

EXAMPLES:
    ms-manager                     # Open interactive menu
    ms-manager -testm 5            # Test mode: restart every 5 minutes
    ms-manager -testm 5 r          # Test mode with VPS reboot
    ms-manager -countdown          # Show live countdown
    ms-manager -interval 3         # Set restart every 3 hours
    ms-manager -logs 100           # Show last 100 log lines
    ms-manager -reboot-on          # Enable periodic reboots
    ms-manager -reboot-history 20  # Show last 20 reboots
    ms-manager -reboot-stats       # View reboot statistics
    ms-manager -fresh-start        # Fresh PM2 start now

HELP
}

# Load configuration
load_config() {
    source "$CONFIG_FILE"
}

# Save configuration
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
CONF_EOF
    
    sudo sed -i "s/^OnUnitActiveSec=.*/OnUnitActiveSec=${RESTART_INTERVAL}s/" /etc/systemd/system/$SERVICE_NAME.timer
    sudo systemctl daemon-reload
}

# Handle command-line arguments
if [ $# -gt 0 ]; then
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -s|--status)
            systemctl status $SERVICE_NAME.timer
            systemctl status $SERVICE_NAME
            exit 0
            ;;
        -start)
            echo -e "${CYAN}Starting MS Server...${NC}"
            sudo systemctl start $SERVICE_NAME.timer
            sudo systemctl enable $SERVICE_NAME.timer
            echo -e "${GREEN}Service started and enabled${NC}"
            exit 0
            ;;
        -stop)
            echo -e "${CYAN}Stopping MS Server...${NC}"
            sudo systemctl stop $SERVICE_NAME.timer
            sudo systemctl disable $SERVICE_NAME.timer
            echo -e "${YELLOW}Service stopped and disabled${NC}"
            exit 0
            ;;
        -restart)
            echo -e "${CYAN}Restarting MS Server...${NC}"
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
            
            # Check if reboot flag is present
            if [ "$3" = "r" ] || [ "$3" = "R" ]; then
                ENABLE_VPS_REBOOT=true
                echo -e "${YELLOW}Test mode: ${MINUTES} minutes with VPS REBOOT${NC}"
            else
                ENABLE_VPS_REBOOT=false
                echo -e "${YELLOW}Test mode: ${MINUTES} minutes (no reboot)${NC}"
            fi
            
            save_config
            sudo systemctl restart $SERVICE_NAME.timer
            echo -e "${GREEN}Test mode activated!${NC}"
            echo -e "Restart interval: ${CYAN}${MINUTES} minutes${NC}"
            echo -e "VPS reboot: ${CYAN}${ENABLE_VPS_REBOOT}${NC}"
            exit 0
            ;;
        -countdown)
            # Show countdown - will implement below
            shift
            exec "$0" --countdown-internal "$@"
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
            sudo systemctl restart $SERVICE_NAME.timer
            echo -e "${GREEN}Restart interval set to $2 hours${NC}"
            exit 0
            ;;
        -reboot-now)
            echo -e "${RED}Rebooting VPS NOW...${NC}"
            sync
            sudo systemctl reboot
            exit 0
            ;;
        -reboot-on)
            load_config
            ENABLE_VPS_REBOOT=true
            save_config
            echo -e "${GREEN}Periodic VPS reboot ENABLED${NC}"
            exit 0
            ;;
        -reboot-off)
            load_config
            ENABLE_VPS_REBOOT=false
            save_config
            echo -e "${YELLOW}Periodic VPS reboot DISABLED${NC}"
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

            # Show last reboot trigger time
            if [ -f "$REBOOT_TIMESTAMP_FILE" ]; then
                LAST_REBOOT_TS=$(cat "$REBOOT_TIMESTAMP_FILE" 2>/dev/null || echo "0")
                if [ "$LAST_REBOOT_TS" != "0" ]; then
                    echo -e "${GREEN}Last Reboot Triggered:${NC} $(date -d "@$LAST_REBOOT_TS" '+%Y-%m-%d %H:%M:%S')"
                    echo -e "${GREEN}Timestamp:${NC} $LAST_REBOOT_TS"
                fi
            fi

            # Show actual boot time
            if [ -f "$BOOT_TIMESTAMP_FILE" ]; then
                ACTUAL_BOOT_TS=$(cat "$BOOT_TIMESTAMP_FILE" 2>/dev/null || echo "0")
                if [ "$ACTUAL_BOOT_TS" != "0" ]; then
                    echo -e "${GREEN}Actual System Boot:${NC} $(date -d "@$ACTUAL_BOOT_TS" '+%Y-%m-%d %H:%M:%S')"
                    echo -e "${GREEN}Timestamp:${NC} $ACTUAL_BOOT_TS"

                    # Show boot duration
                    if [ -f "$REBOOT_TIMESTAMP_FILE" ] && [ "$LAST_REBOOT_TS" != "0" ]; then
                        BOOT_DURATION=$((ACTUAL_BOOT_TS - LAST_REBOOT_TS))
                        if [ "$BOOT_DURATION" -gt 0 ]; then
                            echo -e "${CYAN}Boot Duration:${NC} ${BOOT_DURATION}s"
                        fi
                    fi
                fi
            fi

            # Calculate next reboot time
            if [ -f "$REBOOT_TIMESTAMP_FILE" ] && [ "$LAST_REBOOT_TS" != "0" ]; then
                CURRENT_TS=$(date +%s)
                TIME_SINCE_REBOOT=$((CURRENT_TS - LAST_REBOOT_TS))
                NEXT_REBOOT_IN=$((RESTART_INTERVAL - TIME_SINCE_REBOOT))

                echo ""
                echo -e "${YELLOW}Time Since Last Reboot:${NC} $((TIME_SINCE_REBOOT / 3600))h $((TIME_SINCE_REBOOT % 3600 / 60))m $((TIME_SINCE_REBOOT % 60))s"

                if [ "$NEXT_REBOOT_IN" -gt 0 ]; then
                    echo -e "${YELLOW}Next Reboot In:${NC} $((NEXT_REBOOT_IN / 3600))h $((NEXT_REBOOT_IN % 3600 / 60))m $((NEXT_REBOOT_IN % 60))s"
                    NEXT_REBOOT_TS=$((LAST_REBOOT_TS + RESTART_INTERVAL))
                    echo -e "${YELLOW}Next Reboot Time:${NC} $(date -d "@$NEXT_REBOOT_TS" '+%Y-%m-%d %H:%M:%S')"
                else
                    echo -e "${RED}Next Reboot:${NC} Overdue (will reboot on next service trigger)"
                fi
            else
                echo ""
                echo -e "${YELLOW}Reboot Tracking:${NC} Not yet initialized"
            fi

            echo ""
            exit 0
            ;;
        -reboot-reset)
            echo -e "${YELLOW}Resetting reboot timer...${NC}"
            if [ -f "$REBOOT_TIMESTAMP_FILE" ]; then
                sudo rm -f "$REBOOT_TIMESTAMP_FILE"
                echo -e "${GREEN}Reboot timer reset. Next service trigger will reboot if enabled.${NC}"
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

            # Count total reboots (excluding header)
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
                # Convert uptime to readable format
                uptime_h=$((uptime / 3600))
                uptime_m=$(((uptime % 3600) / 60))
                uptime_readable="${uptime_h}h ${uptime_m}m"

                # Convert elapsed to readable format
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

            tail -n "$LINES" "$REBOOT_LOG_FILE"
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

            # Count total reboots (excluding header)
            TOTAL_REBOOTS=$(($(wc -l < "$REBOOT_DB_FILE") - 1))

            if [ "$TOTAL_REBOOTS" -eq 0 ]; then
                echo -e "${YELLOW}No reboots recorded yet${NC}"
                exit 0
            fi

            echo -e "${GREEN}Total Reboots:${NC} $TOTAL_REBOOTS"

            # Get first and last reboot
            FIRST_REBOOT=$(tail -n +2 "$REBOOT_DB_FILE" | head -n 1 | cut -d',' -f2)
            LAST_REBOOT=$(tail -n 1 "$REBOOT_DB_FILE" | cut -d',' -f2)

            echo -e "${GREEN}First Reboot:${NC} $FIRST_REBOOT"
            echo -e "${GREEN}Last Reboot:${NC} $LAST_REBOOT"
            echo ""

            # Calculate average uptime before reboot
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

            # Calculate average elapsed time between reboots
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
            exit 0
            ;;
        --countdown-internal)
            # Internal countdown implementation
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
            
            clear
            echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${MAGENTA}║${NC} ${BOLD}${WHITE}🚀 RESTART COUNTDOWN MONITOR 🚀${NC} ${MAGENTA}║${NC}"
            echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${GREEN}┌─────────────────────────────────────────────────────────────────────────────────┐${NC}"
            echo -e "${GREEN}│${NC} ${BOLD}${WHITE}📊 STATUS INFO${NC} ${GREEN}│${NC}"
            echo -e "${GREEN}├─────────────────────────────────────────────────────────────────────────────────┤${NC}"
            echo -e "${GREEN}│${NC} ${MAGENTA}🔄 Interval:${NC} ${WHITE}$((RESTART_INTERVAL / 3600))h${NC} ${GREEN}│${NC} ${BLUE}📅 Last trigger:${NC} ${WHITE}$(date -d "$LAST_TRIGGER" '+%H:%M:%S' 2>/dev/null || echo 'N/A')${NC} ${GREEN}│${NC}"
            echo -e "${GREEN}│${NC} ${YELLOW}🖥️  VPS Reboot:${NC} ${WHITE}${ENABLE_VPS_REBOOT}${NC} ${GREEN}│${NC}"

            # Show reboot tracking info if reboot is enabled
            if [ "$ENABLE_VPS_REBOOT" = "true" ] && [ -f "$REBOOT_TIMESTAMP_FILE" ]; then
                LAST_REBOOT_TS=$(cat "$REBOOT_TIMESTAMP_FILE" 2>/dev/null || echo "0")
                if [ "$LAST_REBOOT_TS" != "0" ]; then
                    CURRENT_TS=$(date +%s)
                    TIME_SINCE_REBOOT=$((CURRENT_TS - LAST_REBOOT_TS))
                    NEXT_REBOOT_IN=$((RESTART_INTERVAL - TIME_SINCE_REBOOT))

                    if [ "$NEXT_REBOOT_IN" -lt 0 ]; then
                        NEXT_REBOOT_IN=0
                    fi

                    echo -e "${GREEN}│${NC} ${CYAN}🔄 Last Reboot:${NC} ${WHITE}$(date -d "@$LAST_REBOOT_TS" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'N/A')${NC} ${GREEN}│${NC}"
                    echo -e "${GREEN}│${NC} ${CYAN}⏰ Next Reboot In:${NC} ${WHITE}$((NEXT_REBOOT_IN / 3600))h $((NEXT_REBOOT_IN % 3600 / 60))m${NC} ${GREEN}│${NC}"
                else
                    echo -e "${GREEN}│${NC} ${CYAN}🔄 Reboot Status:${NC} ${YELLOW}Waiting for first cycle${NC} ${GREEN}│${NC}"
                fi
            fi

            echo -e "${GREEN}└─────────────────────────────────────────────────────────────────────────────────┘${NC}"
            echo ""
            echo -e "${DIM}Press Ctrl+C to exit countdown${NC}"
            echo ""
            
            # Dynamic lines
            printf "\033[s"
            echo ""
            echo ""
            
            while true; do
                CURRENT_EPOCH=$(date +%s)
                ELAPSED=$((CURRENT_EPOCH - LAST_TRIGGER_EPOCH))
                REMAINING=$((RESTART_INTERVAL - ELAPSED))
                
                if [ $REMAINING -le 0 ]; then
                    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
                    if [ "$ENABLE_VPS_REBOOT" = "true" ]; then
                        echo -e "${GREEN}║${NC} ${RED}🚀 TIMER TRIGGERED! VPS REBOOTING NOW! 🚀${NC} ${GREEN}║${NC}"
                    else
                        echo -e "${GREEN}║${NC} ${YELLOW}🚀 TIMER TRIGGERED! RESTARTING SERVICE! 🚀${NC} ${GREEN}║${NC}"
                    fi
                    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
                    
                    # Wait for new trigger
                    PREV_TRIGGER_EPOCH=$LAST_TRIGGER_EPOCH
                    ATTEMPTS=0
                    while [ $ATTEMPTS -lt 120 ]; do
                        sleep 1
                        LAST_TRIGGER=$(systemctl show $SERVICE_NAME.timer --property=LastTriggerUSec --value)
                        NEW_TRIGGER_EPOCH=$(date -d "$LAST_TRIGGER" +%s 2>/dev/null)
                        if [ -n "$NEW_TRIGGER_EPOCH" ] && [ "$NEW_TRIGGER_EPOCH" -gt "$PREV_TRIGGER_EPOCH" ]; then
                            LAST_TRIGGER_EPOCH=$NEW_TRIGGER_EPOCH
                            break
                        fi
                        ATTEMPTS=$((ATTEMPTS + 1))
                    done
                    
                    if [ "$ATTEMPTS" -ge 120 ]; then
                        LAST_TRIGGER_EPOCH=$(date +%s)
                    fi
                    
                    sleep 1
                    continue
                fi
                
                # Calculate time
                HOURS=$((REMAINING / 3600))
                MINUTES=$(((REMAINING % 3600) / 60))
                SECONDS=$((REMAINING % 60))
                
                # Progress bar
                PROGRESS=$((ELAPSED * 100 / RESTART_INTERVAL))
                BAR_LENGTH=60
                FILLED=$((PROGRESS * BAR_LENGTH / 100))
                EMPTY=$((BAR_LENGTH - FILLED))
                
                BAR=""
                for ((i=0; i<FILLED; i++)); do 
                    POSITION=$((i * 100 / BAR_LENGTH))
                    if [ $POSITION -lt 25 ]; then
                        BAR+="█"
                    elif [ $POSITION -lt 50 ]; then
                        BAR+="▓"
                    elif [ $POSITION -lt 75 ]; then
                        BAR+="▒"
                    else
                        BAR+="░"
                    fi
                done
                for ((i=0; i<EMPTY; i++)); do BAR+=" "; done
                
                # Colors based on remaining time
                if [ $REMAINING -lt 300 ]; then
                    TIME_COLOR="${RED}"
                    BAR_COLOR="${RED}"
                    ASCII_ART="${RED}🔥${NC}"
                elif [ $REMAINING -lt 900 ]; then
                    TIME_COLOR="${YELLOW}"
                    BAR_COLOR="${YELLOW}"
                    ASCII_ART="${YELLOW}⚡${NC}"
                elif [ $REMAINING -lt 1800 ]; then
                    TIME_COLOR="${CYAN}"
                    BAR_COLOR="${CYAN}"
                    ASCII_ART="${CYAN}⏰${NC}"
                elif [ $REMAINING -lt 3600 ]; then
                    TIME_COLOR="${BLUE}"
                    BAR_COLOR="${BLUE}"
                    ASCII_ART="${BLUE}⏳${NC}"
                else
                    TIME_COLOR="${GREEN}"
                    BAR_COLOR="${GREEN}"
                    ASCII_ART="${GREEN}🕐${NC}"
                fi
                
                # Update display
                printf "\033[u"
                printf "\033[2K\r${CYAN}⏰ Remaining:${NC} ${TIME_COLOR}${BOLD}%02d:%02d:%02d${NC}  ${YELLOW}⏳ Elapsed:${NC} ${GREEN}%02dm%02ds${NC}\n" \
                    $HOURS $MINUTES $SECONDS $((ELAPSED/60)) $((ELAPSED%60))
                printf "\033[2K\r${ASCII_ART} ${BAR_COLOR}[%s]${NC} ${BAR_COLOR}%3d%%${NC}\n" "$BAR" $PROGRESS
                
                sleep 1
            done
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
fi

# If no arguments, show interactive menu
# Helpers
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

# Main menu
show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                          ${GREEN}⚡ MS SERVER MANAGER v2.0 ⚡${BLUE}                            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    load_config
    
    # Status display
    echo -e "${YELLOW}┌─────────────────────────────────── STATUS ───────────────────────────────────────┐${NC}"
    if systemctl is-active --quiet $SERVICE_NAME.timer; then
        echo -e "  ${GREEN}●${NC} Timer Status: ${GREEN}RUNNING${NC}          "
    else
        echo -e "  ${RED}●${NC} Timer Status: ${RED}STOPPED${NC}          "
    fi
    
    if systemctl is-enabled --quiet $SERVICE_NAME.timer; then
        echo -e "  ${GREEN}●${NC} Auto-start: ${GREEN}ENABLED${NC}             "
    else
        echo -e "  ${YELLOW}●${NC} Auto-start: ${YELLOW}DISABLED${NC}            "
    fi
    
    echo -e "  ${BLUE}⏱${NC}  Restart Every: ${GREEN}$((RESTART_INTERVAL / 3600))h${NC} (${RESTART_INTERVAL}s)"
    echo -e "  ${BLUE}📁${NC} Working Dir: ${GREEN}$WORKING_DIR${NC}"
    echo -e "  ${BLUE}🖥️${NC} VPS Reboot: ${GREEN}$ENABLE_VPS_REBOOT${NC}"
    echo -e "  ${BLUE}⬇️${NC} Update on Boot: ${GREEN}$ENABLE_UPDATE_ON_BOOT${NC}"
    echo -e "${YELLOW}└──────────────────────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    # Three column menu
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
            sudo systemctl start $SERVICE_NAME.timer
            sudo systemctl enable $SERVICE_NAME.timer
            echo -e "${GREEN}Service and timer started${NC}"
            sleep 2
            ;;
        2)
            echo "Stopping service and timer..."
            sudo systemctl stop $SERVICE_NAME.timer
            sudo systemctl disable $SERVICE_NAME.timer
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
            sudo systemctl status $SERVICE_NAME.timer
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        5)
            sudo systemctl enable $SERVICE_NAME.timer
            echo -e "${GREEN}Auto-start enabled${NC}"
            sleep 2
            ;;
        6)
            sudo systemctl disable $SERVICE_NAME.timer
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
                echo -e "${CYAN}Restarting timer to apply new interval...${NC}"
                sudo systemctl restart $SERVICE_NAME.timer
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
                sudo systemctl restart $SERVICE_NAME.timer
                
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
            # Use the -countdown flag
            exec "$0" -countdown
            ;;
        18)
            echo -n "Are you sure you want to reboot the VPS now? (yes/no): "
            read confirm
            if [ "$confirm" = "yes" ]; then
                echo -e "${YELLOW}Rebooting VPS...${NC}"
                sudo systemctl reboot
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
            else
                ENABLE_VPS_REBOOT=true
                echo -e "${GREEN}Enabling periodic VPS reboot...${NC}"
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

            # Show last reboot trigger time
            if [ -f "$REBOOT_TIMESTAMP_FILE" ]; then
                LAST_REBOOT_TS=$(cat "$REBOOT_TIMESTAMP_FILE" 2>/dev/null || echo "0")
                if [ "$LAST_REBOOT_TS" != "0" ]; then
                    echo -e "${GREEN}Last Reboot Triggered:${NC} $(date -d "@$LAST_REBOOT_TS" '+%Y-%m-%d %H:%M:%S')"
                    echo -e "${GREEN}Trigger Timestamp:${NC} $LAST_REBOOT_TS"
                fi
            fi

            # Show actual boot time
            if [ -f "$BOOT_TIMESTAMP_FILE" ]; then
                ACTUAL_BOOT_TS=$(cat "$BOOT_TIMESTAMP_FILE" 2>/dev/null || echo "0")
                if [ "$ACTUAL_BOOT_TS" != "0" ]; then
                    echo -e "${GREEN}Actual System Boot:${NC} $(date -d "@$ACTUAL_BOOT_TS" '+%Y-%m-%d %H:%M:%S')"
                    echo -e "${GREEN}Boot Timestamp:${NC} $ACTUAL_BOOT_TS"

                    # Show boot duration
                    if [ -f "$REBOOT_TIMESTAMP_FILE" ] && [ "$LAST_REBOOT_TS" != "0" ]; then
                        BOOT_DURATION=$((ACTUAL_BOOT_TS - LAST_REBOOT_TS))
                        if [ "$BOOT_DURATION" -gt 0 ]; then
                            echo -e "${CYAN}Boot Duration:${NC} ${BOOT_DURATION}s"
                        fi
                    fi
                fi
            fi

            # Calculate next reboot time
            if [ -f "$REBOOT_TIMESTAMP_FILE" ] && [ "$LAST_REBOOT_TS" != "0" ]; then
                CURRENT_TS=$(date +%s)
                TIME_SINCE_REBOOT=$((CURRENT_TS - LAST_REBOOT_TS))
                NEXT_REBOOT_IN=$((RESTART_INTERVAL - TIME_SINCE_REBOOT))

                echo ""
                echo -e "${YELLOW}Time Since Last Reboot:${NC} $((TIME_SINCE_REBOOT / 3600))h $((TIME_SINCE_REBOOT % 3600 / 60))m $((TIME_SINCE_REBOOT % 60))s"

                if [ "$NEXT_REBOOT_IN" -gt 0 ]; then
                    echo -e "${YELLOW}Next Reboot In:${NC} $((NEXT_REBOOT_IN / 3600))h $((NEXT_REBOOT_IN % 3600 / 60))m $((NEXT_REBOOT_IN % 60))s"
                    NEXT_REBOOT_TS=$((LAST_REBOOT_TS + RESTART_INTERVAL))
                    echo -e "${YELLOW}Next Reboot Time:${NC} $(date -d "@$NEXT_REBOOT_TS" '+%Y-%m-%d %H:%M:%S')"
                else
                    echo -e "${RED}Next Reboot:${NC} Overdue (will reboot on next service trigger)"
                fi
            else
                echo ""
                echo -e "${YELLOW}Reboot Tracking:${NC} Not yet initialized"
                echo -e "First reboot will occur when service triggers with reboot enabled."
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

            # Count total reboots (excluding header)
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
                # Convert uptime to readable format
                uptime_h=$((uptime / 3600))
                uptime_m=$(((uptime % 3600) / 60))
                uptime_readable="${uptime_h}h ${uptime_m}m"

                # Convert elapsed to readable format
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

            # Count total reboots (excluding header)
            TOTAL_REBOOTS=$(($(wc -l < "$REBOOT_DB_FILE") - 1))

            if [ "$TOTAL_REBOOTS" -eq 0 ]; then
                echo -e "${YELLOW}No reboots recorded yet${NC}"
                echo ""
                echo "Press Enter to continue..."
                read
                continue
            fi

            echo -e "${GREEN}Total Reboots:${NC} $TOTAL_REBOOTS"

            # Get first and last reboot
            FIRST_REBOOT=$(tail -n +2 "$REBOOT_DB_FILE" | head -n 1 | cut -d',' -f2)
            LAST_REBOOT=$(tail -n 1 "$REBOOT_DB_FILE" | cut -d',' -f2)

            echo -e "${GREEN}First Reboot:${NC} $FIRST_REBOOT"
            echo -e "${GREEN}Last Reboot:${NC} $LAST_REBOOT"
            echo ""

            # Calculate average uptime before reboot
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

            # Calculate average elapsed time between reboots
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
            echo "  • Service scripts (/usr/local/bin/ms-server-run.sh)"
            echo "  • Management script (/usr/local/bin/ms-manager)"
            echo "  • Configuration directory (/etc/ms-server/)"
            echo "  • Log file (/var/log/ms-server.log)"
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
                sudo systemctl stop $SERVICE_NAME.timer 2>/dev/null || true
                
                echo "→ Disabling timer..."
                sudo systemctl disable $SERVICE_NAME.timer 2>/dev/null || true
                
                echo "→ Stopping service..."
                sudo systemctl stop $SERVICE_NAME 2>/dev/null || true
                
                echo "→ Disabling service..."
                sudo systemctl disable $SERVICE_NAME 2>/dev/null || true
                
                echo "→ Removing systemd service file..."
                sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
                
                echo "→ Removing systemd timer file..."
                sudo rm -f /etc/systemd/system/$SERVICE_NAME.timer
                
                echo "→ Removing service scripts..."
                sudo rm -f /usr/local/bin/ms-server-run.sh
                sudo rm -f /usr/local/bin/ms-manager
                
                echo "→ Removing configuration directory..."
                sudo rm -rf /etc/ms-server
                
                echo "→ Removing log file..."
                sudo rm -f /var/log/ms-server.log
                
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

# Create log file
touch /var/log/ms-server.log
chmod 644 /var/log/ms-server.log

# Reload systemd
systemctl daemon-reload
echo "✓ Systemd daemon reloaded"

echo ""
echo "==================================="
echo "  Installation Complete!"
echo "==================================="
echo ""
echo "Enhanced Features:"
echo "  ✓ Automatic VPS reboot with persistent time tracking"
echo "  ✓ Live countdown display with reboot status"
echo "  ✓ Reboot history logging with database tracking"
echo "  ✓ Reboot statistics and analytics"
echo "  ✓ Command-line arguments"
echo "  ✓ Fresh PM2 start on each restart"
echo "  ✓ Test mode with custom intervals"
echo "  ✓ Reboot persistence across system reboots"
echo ""
echo "CLI Usage Examples:"
echo "  ms-manager                    # Interactive menu"
echo "  ms-manager -h                 # Show help"
echo "  ms-manager -testm 5           # Test mode: 5 min restart"
echo "  ms-manager -testm 5 r         # Test mode with VPS reboot"
echo "  ms-manager -countdown         # Live countdown display"
echo "  ms-manager -interval 3        # Set 3 hour intervals"
echo "  ms-manager -reboot-on         # Enable periodic reboots"
echo "  ms-manager -reboot-status     # View reboot tracking status"
echo "  ms-manager -reboot-history    # View reboot history"
echo "  ms-manager -reboot-stats      # View reboot statistics"
echo "  ms-manager -reboot-log        # View reboot log"
echo "  ms-manager -reboot-reset      # Reset reboot timer"
echo "  ms-manager -fresh-start       # Force fresh PM2 start now"
echo ""
echo "Quick Start:"
echo "  1. Run: ms-manager"
echo "  2. Or use CLI: ms-manager -h"
echo ""
echo "Starting manager now..."
sleep 2

exec "$MANAGER_SCRIPT"
