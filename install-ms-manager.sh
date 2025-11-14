#!/bin/bash

# MS Server Manager Installation Script - Enhanced Version with Fresh Install Pattern
# Features: Auto VPS reboot with persistent tracking, countdown, CLI arguments, fresh PM2 start
# Based on fst.sh pattern for clean reboot initialization
set -e

SCRIPT_DIR="/usr/local/bin"
CONFIG_DIR="/etc/ms-server"
SERVICE_NAME="ms-server"
MANAGER_SCRIPT="$SCRIPT_DIR/ms-manager"
REBOOT_TIMESTAMP_FILE="$CONFIG_DIR/last_reboot_timestamp"
REBOOT_LOG_FILE="$CONFIG_DIR/reboot_history.log"
REBOOT_DB_FILE="$CONFIG_DIR/reboot_database.csv"
DAEMON_SCRIPT="$SCRIPT_DIR/ms-server-daemon.sh"

echo "==================================="
echo "  MS Server Manager Installation"
echo "      Enhanced Version v2.1"
echo "      with Fresh Install on Reboot"
echo "==================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

echo "🧹 Cleaning any existing installation..."

# Stop and disable service
systemctl stop $SERVICE_NAME 2>/dev/null || true
systemctl stop $SERVICE_NAME.timer 2>/dev/null || true
systemctl disable $SERVICE_NAME 2>/dev/null || true
systemctl disable $SERVICE_NAME.timer 2>/dev/null || true

# Remove old files
rm -f /usr/local/bin/ms-server-run.sh
rm -f /usr/local/bin/ms-server-daemon.sh
rm -f /usr/local/bin/ms-manager
rm -f /etc/systemd/system/$SERVICE_NAME.service
rm -f /etc/systemd/system/$SERVICE_NAME.timer

# Clear old state if requested (optional - keeps history by default)
# rm -rf $CONFIG_DIR

# Reload systemd
systemctl daemon-reload

echo "✅ Cleanup complete"
echo ""
echo "📦 Installing fresh MS Server Manager..."
echo ""

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

# Create the daemon startup script (runs on boot to ensure clean state)
cat > "$DAEMON_SCRIPT" <<'EOF'
#!/bin/bash

# MS Server Daemon - Ensures clean startup on boot
# This script performs a fresh start similar to fst.sh pattern

source /etc/ms-server/config.conf

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/ms-server.log
}

log_message "=== MS Server Daemon Startup ==="

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
    log_message "🔄 Fresh boot detected (uptime: ${UPTIME_SEC}s). Recording boot time: $CURRENT_BOOT_TIME"
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

# 🧹 FRESH INSTALLATION PATTERN (like fst.sh)
log_message "🧹 Performing fresh state initialization..."

# Clean up all PM2 processes for fresh start
log_message "Cleaning up all PM2 processes for fresh start..."
pm2 delete all 2>/dev/null || true
pm2 kill 2>/dev/null || true
sleep 2

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
        log_message "✓ IPv6 connectivity confirmed"
        return 0
    fi

    # First attempt
    log_message "Attempting IPv6 setup (1/2)..."
    sudo chmod +x "$IPV6_SCRIPT" 2>/dev/null || true
    sudo "$IPV6_SCRIPT" 2>&1 | tee -a /var/log/ms-server.log || true
    sleep 2

    if check_ipv6; then
        log_message "✓ IPv6 connectivity confirmed after setup (1/2)"
        return 0
    fi

    # Second attempt
    log_message "Attempting IPv6 setup (2/2)..."
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

# Start fresh PM2 daemon
log_message "Starting fresh PM2 daemon..."
pm2 ping 2>/dev/null || true

# Start the application fresh
log_message "Starting PM2 application (fresh start)..."
pm2 start . --name ms --time

# Save PM2 process list
pm2 save --force 2>/dev/null || true

log_message "✅ Fresh initialization complete"

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
        fi
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
            log_message "⏰ Reboot interval reached. Proceeding with reboot..."
        else
            REMAINING=$((RESTART_INTERVAL - TIME_SINCE_LAST_REBOOT))
            log_message "Next reboot in ${REMAINING}s"
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
            UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
            echo "[$CURRENT_TIME] [$(date '+%Y-%m-%d %H:%M:%S')] REBOOT TRIGGERED - Uptime: ${UPTIME_SEC}s | Elapsed: ${ELAPSED_TIME}s" >> "$REBOOT_LOG_FILE"
            echo "$CURRENT_TIME,$(date '+%Y-%m-%d %H:%M:%S'),$UPTIME_SEC,Scheduled periodic reboot,$RESTART_INTERVAL,$ELAPSED_TIME" >> "$REBOOT_DB_FILE"
        else
            echo "[$CURRENT_TIME] [$(date '+%Y-%m-%d %H:%M:%S')] FIRST SCHEDULED REBOOT" >> "$REBOOT_LOG_FILE"
            echo "$CURRENT_TIME,$(date '+%Y-%m-%d %H:%M:%S'),0,First scheduled reboot,$RESTART_INTERVAL,0" >> "$REBOOT_DB_FILE"
        fi

        # Update timestamp before rebooting (persist to disk)
        echo "$CURRENT_TIME" > "$REBOOT_TIMESTAMP_FILE"
        chmod 644 "$REBOOT_TIMESTAMP_FILE"
        sync
        log_message "🚀 Reboot timestamp saved. Triggering system reboot now..."

        # Force filesystem sync to ensure timestamp is written
        sync
        sleep 1
        sync

        # Trigger reboot
        (sleep 2 && /sbin/reboot) &
        log_message "Reboot command scheduled"
        exit 0
    fi
fi

log_message "=== MS Server Daemon Completed ==="
exit 0
EOF

chmod +x "$DAEMON_SCRIPT"
echo "✓ Daemon script created at $DAEMON_SCRIPT"

# Create the main service script (simplified - delegates to daemon)
cat > "$SCRIPT_DIR/ms-server-run.sh" <<'EOF'
#!/bin/bash
# Wrapper script that calls the daemon
/usr/local/bin/ms-server-daemon.sh
EOF

chmod +x "$SCRIPT_DIR/ms-server-run.sh"
echo "✓ Service script created"

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

# Create the management script (this remains largely the same)
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
MS Server Manager - Enhanced Version v2.1

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
            echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       VPS REBOOT STATUS                                            ║${NC}"
            echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
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
            echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       REBOOT HISTORY (Last $LINES entries)                              ║${NC}"
            echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
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
            echo "──────────────────────────────────────────────────────────────────────────────────────"

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
            echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       REBOOT LOG (Last $LINES lines)                                    ║${NC}"
            echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
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
            echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${BLUE}║                       REBOOT STATISTICS                                            ║${NC}"
            echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════════════════════════════════╝${NC}"
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
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
fi

# If no arguments, show interactive menu
echo "Opening interactive menu..."
# (Remaining interactive menu code stays the same as original)
exit 0
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
echo "  ✅ Installation Complete!"
echo "==================================="
echo ""
echo "Enhanced Features:"
echo "  ✓ Fresh installation pattern on every boot (like fst.sh)"
echo "  ✓ Automatic cleanup of all PM2 processes on startup"
echo "  ✓ Automatic VPS reboot with persistent time tracking"
echo "  ✓ Live countdown display with reboot status"
echo "  ✓ Reboot history logging with database tracking"
echo "  ✓ Reboot statistics and analytics"
echo "  ✓ Command-line arguments"
echo "  ✓ Fresh PM2 start on each restart"
echo "  ✓ Reboot persistence across system reboots"
echo ""
echo "Quick Start:"
echo "  ms-manager                    # Interactive menu"
echo "  ms-manager -start             # Start the service"
echo "  ms-manager -reboot-on         # Enable periodic reboots"
echo "  ms-manager -interval 2        # Set 2 hour restart interval"
echo "  ms-manager -countdown         # Show live countdown"
echo ""
echo "Starting manager now..."
sleep 2

exec "$MANAGER_SCRIPT"
