#!/bin/bash

# MS Server Manager Installation Script
# This script sets up a systemd service and management tool

set -e

SCRIPT_DIR="/usr/local/bin"
CONFIG_DIR="/etc/ms-server"
SERVICE_NAME="ms-server"
MANAGER_SCRIPT="$SCRIPT_DIR/ms-manager"

echo "==================================="
echo "  MS Server Manager Installation"
echo "==================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

# Create config directory
mkdir -p "$CONFIG_DIR"

# Create default configuration file
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

# Create the main service script
cat > "$SCRIPT_DIR/ms-server-run.sh" <<'EOF'
#!/bin/bash

# Load configuration
source /etc/ms-server/config.conf

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/ms-server.log
}

log_message "=== MS Server Starting ==="

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
    # Quick IPv6 checks to common GitHub endpoints
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

# Stop existing pm2 process if any
pm2 stop ms 2>/dev/null || true
pm2 delete ms 2>/dev/null || true

# Start the application
log_message "Starting PM2 application..."
pm2 start . --name ms --time

log_message "=== MS Server Started Successfully ==="

# On-boot self-update (optional)
if [ "${ENABLE_UPDATE_ON_BOOT}" = "true" ]; then
    # Determine system uptime in seconds
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

# Conditionally reboot VPS if enabled
if [ "${ENABLE_VPS_REBOOT}" = "true" ]; then
    log_message "VPS reboot flag is enabled. Rebooting system now..."
    # Flush logs to disk before reboot
    sync
    /usr/bin/systemctl reboot
fi

# Exit after successful startup - systemd timer will handle restarts
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

# Create the management script
cat > "$MANAGER_SCRIPT" <<'MANAGER_EOF'
#!/bin/bash

CONFIG_FILE="/etc/ms-server/config.conf"
SERVICE_NAME="ms-server"
LOG_FILE="/var/log/ms-server.log"
UPDATE_URL="https://raw.githubusercontent.com/pgwiz/botPaas/refs/heads/main/install-ms-manager.sh"

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
NC='\033[0m' # No Color

# Helpers
pm2_is_ms_in_workdir() {
    # Returns 0 if a pm2 process named 'ms' exists and its cwd matches WORKING_DIR
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
    # Live PM2 monitor (press q to quit)
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

# Load current configuration
load_config() {
    source "$CONFIG_FILE"
}

# Save configuration
save_config() {
    cat > "$CONFIG_FILE" <<EOF
# MS Server Configuration
RESTART_INTERVAL=$RESTART_INTERVAL
WORKING_DIR=$WORKING_DIR
IPV6_SCRIPT=$IPV6_SCRIPT
ENABLE_AUTO_RESTART=$ENABLE_AUTO_RESTART
CUSTOM_COMMANDS="$CUSTOM_COMMANDS"
ENABLE_VPS_REBOOT=$ENABLE_VPS_REBOOT
ENABLE_UPDATE_ON_BOOT=$ENABLE_UPDATE_ON_BOOT
EOF
    
    # Update systemd timer with new restart interval
    sudo sed -i "s/^OnUnitActiveSec=.*/OnUnitActiveSec=${RESTART_INTERVAL}s/" /etc/systemd/system/$SERVICE_NAME.timer
    sudo systemctl daemon-reload
}

# Main menu
show_menu() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                          ${GREEN}⚡ MS SERVER MANAGER v1.0 ⚡${BLUE}                            ║${NC}"
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
    echo -e "  ${YELLOW}18${NC}) Reboot VPS Now"
    echo -e "  ${YELLOW}19${NC}) Toggle Periodic VPS Reboot"
    echo -e "  ${YELLOW}20${NC}) Toggle Update on Boot"
    echo -e "  ${YELLOW}21${NC}) Initialize now (IPv6 + PM2 start)"
    echo -e "  ${YELLOW}22${NC}) Start attached (from WORKING_DIR)"
    echo -e "  ${YELLOW}23${NC}) View memory usage"
    echo -e "  ${YELLOW}24${NC}) Live PM2 monitor"
    echo -e "  ${GREEN}91${NC}) Update from GitHub"
    echo -e "  ${RED}99${NC}) Uninstall Service"
    echo -e "  ${RED}0${NC}) Exit Manager"
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
                # Save current interval
                ORIGINAL_INTERVAL=$RESTART_INTERVAL
                
                # Set test interval (300 seconds = 5 minutes)
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
        21)
            clear
            echo -e "${BLUE}[ INIT ] IPv6 -> PM2 start${NC}"
            load_config
            run_ipv6_twice_and_verify
            echo -e "${BLUE}[*] Switching to: ${GREEN}$WORKING_DIR${NC}"
            cd "$WORKING_DIR" 2>/dev/null || { echo -e "${RED}[!] Cannot cd to $WORKING_DIR${NC}"; sleep 2; break; }
            echo -e "${BLUE}[*] Stopping previous pm2 'ms' (if any)...${NC}"
            pm2 stop ms 2>/dev/null || true
            pm2 delete ms 2>/dev/null || true
            echo -e "${BLUE}[*] Starting pm2 'ms'...${NC}"
            pm2 start . --name ms --time
            echo -e "${GREEN}[✓] pm2 'ms' started${NC}"
            echo ""
            echo "Press Enter to continue..."
            read
            ;;
        22)
            clear
            echo -e "${BLUE}[ ATTACH ] PM2 'ms' in ${GREEN}$WORKING_DIR${NC}"
            load_config
            if pm2_is_ms_in_workdir; then
                echo -e "${GREEN}[✓] 'ms' already running in $WORKING_DIR — attaching...${NC}"
                cd "$WORKING_DIR" 2>/dev/null || true
                pm2 logs ms --lines 50
            else
                echo -e "${YELLOW}[*] 'ms' not running from $WORKING_DIR — starting attached...${NC}"
                cd "$WORKING_DIR" 2>/dev/null || { echo -e "${RED}[!] Cannot cd to $WORKING_DIR${NC}"; sleep 2; break; }
                pm2 start . --name ms --attach --time
            fi
            ;;
        23)
            # Memory usage view
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
                # Reliable field list; trim command to 23 chars, convert RSS (KB) to MB
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
            echo -e "${DIM}Note: %MEM rounds to 0.0 for very small usage (e.g., PM2 daemons).${NC}"
            echo -e "${DIM}Press Enter to return to menu...${NC}"
            read
            ;;
        24)
            live_pm2_monitor
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
        17)
            clear
            echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${MAGENTA}║${NC} ${BOLD}${WHITE}🚀 RESTART COUNTDOWN MONITOR 🚀${NC} ${MAGENTA}║${NC}"
            echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────────────────┐${NC}"
            echo -e "${CYAN}│${NC} ${BOLD}${WHITE}Real-time countdown to next MS Server restart${NC} ${CYAN}│${NC}"
            echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────────────────┘${NC}"
            echo ""
            
            # Check if timer is running
            if ! systemctl is-active --quiet $SERVICE_NAME.timer; then
                echo -e "${RED}Timer is not running!${NC}"
                echo ""
                echo "Start the timer first (Option 1)"
                echo ""
                echo "Press Enter to continue..."
                read
            else
                # Get the last timer trigger time
                LAST_TRIGGER=$(systemctl show $SERVICE_NAME.timer --property=LastTriggerUSec --value)
                if [ "$LAST_TRIGGER" = "0" ]; then
                    echo -e "${YELLOW}Timer has not triggered yet${NC}"
                    echo "The timer will trigger every $((RESTART_INTERVAL / 60)) minutes"
                    echo ""
                    echo "Press Enter to continue..."
                    read
                else
                    # Convert to epoch time
                    LAST_TRIGGER_EPOCH=$(date -d "$LAST_TRIGGER" +%s 2>/dev/null)
                    
                    if [ -z "$LAST_TRIGGER_EPOCH" ]; then
                        echo -e "${RED}Unable to determine last trigger time${NC}"
                        echo ""
                        echo "Press Enter to continue..."
                        read
                    else
                        echo -e "${GREEN}Timer is running${NC}"
                        echo "Last trigger: $LAST_TRIGGER"
                        echo "Restart interval: $((RESTART_INTERVAL / 60)) minutes"
                        echo ""
                        echo "Press Ctrl+C to exit countdown"
                        echo ""
                        sleep 1
                        
                        # Prepare two dynamic lines for in-place updates
                        DYN_INIT=0
                        # Countdown loop with enhanced visuals
                        while true; do
                            CURRENT_EPOCH=$(date +%s)
                            ELAPSED=$((CURRENT_EPOCH - LAST_TRIGGER_EPOCH))
                            REMAINING=$((RESTART_INTERVAL - ELAPSED))
                            
                            if [ $REMAINING -le 0 ]; then
                                echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
                                echo -e "${GREEN}║${NC} ${YELLOW}🚀 TIMER TRIGGERED! RESTARTING NOW! 🚀${NC} ${GREEN}║${NC}"
                                echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"

                                # Wait until systemd updates LastTrigger to a newer value
                                PREV_TRIGGER_EPOCH=$LAST_TRIGGER_EPOCH
                                ATTEMPTS=0
                                MAX_ATTEMPTS=120  # up to ~120 seconds
                                while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
                                    sleep 1
                                    LAST_TRIGGER=$(systemctl show $SERVICE_NAME.timer --property=LastTriggerUSec --value)
                                    NEW_TRIGGER_EPOCH=$(date -d "$LAST_TRIGGER" +%s 2>/dev/null)
                                    if [ -n "$NEW_TRIGGER_EPOCH" ] && [ "$NEW_TRIGGER_EPOCH" -gt "$PREV_TRIGGER_EPOCH" ]; then
                                        LAST_TRIGGER_EPOCH=$NEW_TRIGGER_EPOCH
                                        break
                                    fi
                                    ATTEMPTS=$((ATTEMPTS + 1))
                                done

                                # Fallback: if LastTrigger didn't change, advance base to now
                                if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
                                    LAST_TRIGGER_EPOCH=$(date +%s)
                                fi

                                # Small pause before redrawing countdown
                                sleep 1
                                continue
                            fi
                            
                            # Calculate time components
                            HOURS=$((REMAINING / 3600))
                            MINUTES=$(((REMAINING % 3600) / 60))
                            SECONDS=$((REMAINING % 60))
                            
                            # Enhanced progress calculation
                            PROGRESS=$((ELAPSED * 100 / RESTART_INTERVAL))
                            BAR_LENGTH=60
                            FILLED=$((PROGRESS * BAR_LENGTH / 100))
                            EMPTY=$((BAR_LENGTH - FILLED))
                            
                            # Create enhanced progress bar with gradient effect
                            BAR=""
                            for ((i=0; i<FILLED; i++)); do 
                                # Create gradient effect based on position
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
                            
                            
                            # Color-coded progress based on remaining time
                            if [ $REMAINING -lt 300 ]; then  # Less than 5 minutes
                                TIME_COLOR="${RED}"
                                BAR_COLOR="${RED}"
                            elif [ $REMAINING -lt 900 ]; then  # Less than 15 minutes
                                TIME_COLOR="${YELLOW}"
                                BAR_COLOR="${YELLOW}"
                            else
                                TIME_COLOR="${GREEN}"
                                BAR_COLOR="${GREEN}"
                            fi
                            
                            # Simple ASCII art for progress bar (only this animates)
                            if [ $REMAINING -lt 60 ]; then
                                ASCII_ART="${RED}🔥${NC}"
                            elif [ $REMAINING -lt 300 ]; then
                                ASCII_ART="${YELLOW}⚡${NC}"
                            elif [ $REMAINING -lt 900 ]; then
                                ASCII_ART="${CYAN}⏰${NC}"
                            elif [ $REMAINING -lt 1800 ]; then
                                ASCII_ART="${BLUE}⏳${NC}"
                            else
                                ASCII_ART="${GREEN}🕐${NC}"
                            fi
                            
                            # Display static header (only once per view)
                            if [ $ELAPSED -eq 0 ] && [ $DYN_INIT -eq 0 ]; then
                                echo -e "${MAGENTA}╔════════════════════════════════════════════════════════════════════════════════════╗${NC}"
                                echo -e "${MAGENTA}║${NC} ${BOLD}${WHITE}🚀 RESTART COUNTDOWN MONITOR 🚀${NC} ${MAGENTA}║${NC}"
                                echo -e "${MAGENTA}╚════════════════════════════════════════════════════════════════════════════════════╝${NC}"
                                echo ""
                                echo -e "${GREEN}┌─────────────────────────────────────────────────────────────────────────────────┐${NC}"
                                echo -e "${GREEN}│${NC} ${BOLD}${WHITE}📊 STATUS INFO${NC} ${GREEN}│${NC}"
                                echo -e "${GREEN}├─────────────────────────────────────────────────────────────────────────────────┤${NC}"
                                echo -e "${GREEN}│${NC} ${MAGENTA}🔄 Interval:${NC} ${WHITE}$((RESTART_INTERVAL / 3600))h${NC} ${GREEN}│${NC} ${BLUE}📅 Last trigger:${NC} ${WHITE}$(date -d "$LAST_TRIGGER" '+%H:%M:%S' 2>/dev/null || echo 'N/A')${NC} ${GREEN}│${NC}"
                                echo -e "${GREEN}└─────────────────────────────────────────────────────────────────────────────────┘${NC}"
                                echo ""
                                echo -e "${DIM}Press Ctrl+C to exit countdown${NC}"
                                echo ""
                                # Allocate and mark two dynamic lines; save cursor at first line
                                printf "\033[s"
                                echo ""
                                echo ""
                                DYN_INIT=1
                            fi
                            
                            # Update only the two dynamic lines using saved cursor position
                            printf "\033[u"  # Restore to start of dynamic block
                            # Line 1: Remaining and Elapsed
                            printf "\033[2K\r${CYAN}⏰ Remaining:${NC} ${TIME_COLOR}${BOLD}%02d:%02d:%02d${NC}  ${YELLOW}⏳ Elapsed:${NC} ${GREEN}%02dm%02ds${NC}\n" \
                                $HOURS $MINUTES $SECONDS $((ELAPSED/60)) $((ELAPSED%60))
                            # Line 2: Progress bar
                            printf "\033[2K\r${ASCII_ART} ${BAR_COLOR}[%s]${NC} ${BAR_COLOR}%3d%%${NC}\n" "$BAR" $PROGRESS
                            
                            sleep 1
                        done
                    fi
                fi
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
                
                # Stop and disable service and timer
                echo "→ Stopping timer..."
                sudo systemctl stop $SERVICE_NAME.timer 2>/dev/null || true
                
                echo "→ Disabling timer..."
                sudo systemctl disable $SERVICE_NAME.timer 2>/dev/null || true
                
                echo "→ Stopping service..."
                sudo systemctl stop $SERVICE_NAME 2>/dev/null || true
                
                echo "→ Disabling service..."
                sudo systemctl disable $SERVICE_NAME 2>/dev/null || true
                
                # Remove service and timer files
                echo "→ Removing systemd service file..."
                sudo rm -f /etc/systemd/system/$SERVICE_NAME.service
                
                echo "→ Removing systemd timer file..."
                sudo rm -f /etc/systemd/system/$SERVICE_NAME.timer
                
                # Remove scripts
                echo "→ Removing service scripts..."
                sudo rm -f /usr/local/bin/ms-server-run.sh
                sudo rm -f /usr/local/bin/ms-manager
                
                # Remove configuration
                echo "→ Removing configuration directory..."
                sudo rm -rf /etc/ms-server
                
                # Remove logs
                echo "→ Removing log file..."
                sudo rm -f /var/log/ms-server.log
                
                # Reload systemd
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
echo "Usage:"
echo "  • Run manager: ms-manager"
echo "  • Start timer: systemctl start $SERVICE_NAME.timer"
echo "  • Enable on boot: systemctl enable $SERVICE_NAME.timer"
echo "  • View logs: tail -f /var/log/ms-server.log"
echo ""
echo "Starting manager now..."
sleep 2

exec "$MANAGER_SCRIPT"