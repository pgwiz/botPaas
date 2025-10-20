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

# Run IPv6 setup twice
log_message "Running IPv6 setup (1/2)..."
sudo chmod +x "$IPV6_SCRIPT"
sudo "$IPV6_SCRIPT" 2>&1 | tee -a /var/log/ms-server.log

log_message "Running IPv6 setup (2/2)..."
sudo chmod +x "$IPV6_SCRIPT"
sudo "$IPV6_SCRIPT" 2>&1 | tee -a /var/log/ms-server.log

# Test IPv6 connectivity
log_message "Testing IPv6 connectivity to github.com..."
if ping6 -c 4 github.com 2>&1 | tee -a /var/log/ms-server.log | grep -q "bytes from"; then
    log_message "✓ IPv6 connectivity confirmed"
else
    log_message "⚠ IPv6 test completed (check logs for details)"
fi

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

# Keep the script running to maintain the service
# This allows systemd to manage the restart properly
tail -f /dev/null
EOF

chmod +x "$SCRIPT_DIR/ms-server-run.sh"
echo "✓ Service script created at $SCRIPT_DIR/ms-server-run.sh"

# Create the systemd service file
cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=MS Server with Auto-restart
After=network.target

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/ms-server-run.sh
Restart=always
RestartSec=7200
User=root
WorkingDirectory=/root
StandardOutput=append:/var/log/ms-server.log
StandardError=append:/var/log/ms-server.log
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

echo "✓ Systemd service created"

# Create the management script
cat > "$MANAGER_SCRIPT" <<'MANAGER_EOF'
#!/bin/bash

CONFIG_FILE="/etc/ms-server/config.conf"
SERVICE_NAME="ms-server"
LOG_FILE="/var/log/ms-server.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
EOF
    
    # Update systemd service with new restart interval
    sudo sed -i "s/^RestartSec=.*/RestartSec=$RESTART_INTERVAL/" /etc/systemd/system/$SERVICE_NAME.service
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
    if systemctl is-active --quiet $SERVICE_NAME; then
        echo -e "  ${GREEN}●${NC} Service Status: ${GREEN}RUNNING${NC}          "
    else
        echo -e "  ${RED}●${NC} Service Status: ${RED}STOPPED${NC}          "
    fi
    
    if systemctl is-enabled --quiet $SERVICE_NAME; then
        echo -e "  ${GREEN}●${NC} Auto-start: ${GREEN}ENABLED${NC}             "
    else
        echo -e "  ${YELLOW}●${NC} Auto-start: ${YELLOW}DISABLED${NC}            "
    fi
    
    echo -e "  ${BLUE}⏱${NC}  Restart Every: ${GREEN}$((RESTART_INTERVAL / 3600))h${NC} (${RESTART_INTERVAL}s)"
    echo -e "  ${BLUE}📁${NC} Working Dir: ${GREEN}$WORKING_DIR${NC}"
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
    printf "${BLUE}│${NC} ${GREEN}5${NC}) %-18s ${BLUE}│${NC} ${GREEN}11${NC}) %-17s ${BLUE}│${NC}                        ${BLUE}│${NC}\n" "Enable Auto-start" "View Full Config"
    printf "${BLUE}│${NC} ${GREEN}6${NC}) %-18s ${BLUE}│${NC}                        ${BLUE}│${NC}                        ${BLUE}│${NC}\n" "Disable Auto-start"
    echo -e "${BLUE}└────────────────────────┴────────────────────────┴────────────────────────┘${NC}"
    echo ""
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
            echo "Starting service..."
            sudo systemctl start $SERVICE_NAME
            echo -e "${GREEN}Service started${NC}"
            sleep 2
            ;;
        2)
            echo "Stopping service..."
            sudo systemctl stop $SERVICE_NAME
            echo -e "${YELLOW}Service stopped${NC}"
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
            echo "Press Enter to continue..."
            read
            ;;
        5)
            sudo systemctl enable $SERVICE_NAME
            echo -e "${GREEN}Auto-start enabled${NC}"
            sleep 2
            ;;
        6)
            sudo systemctl disable $SERVICE_NAME
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
echo "  • Start service: systemctl start $SERVICE_NAME"
echo "  • Enable on boot: systemctl enable $SERVICE_NAME"
echo "  • View logs: tail -f /var/log/ms-server.log"
echo ""
echo "Starting manager now..."
sleep 2

exec "$MANAGER_SCRIPT"