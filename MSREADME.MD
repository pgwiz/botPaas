# ⚡ MS Server Manager

A comprehensive systemd service manager for automated server restarts with IPv6 setup and PM2 process management.

## 📋 Features

- 🔄 **Auto-restart** - Configurable restart intervals (default: 2 hours)
- 🌐 **IPv6 Setup** - Automatic IPv6 configuration on boot and restart
- 📊 **PM2 Integration** - Seamless PM2 process management
- 🎨 **Beautiful CLI Interface** - 3-column interactive menu
- 📝 **Comprehensive Logging** - All operations logged to `/var/log/ms-server.log`
- ⚙️ **Fully Configurable** - Change any setting through the menu
- 🚀 **Boot Auto-start** - Optional auto-start on system boot

## 🚀 Installation

### Prerequisites

- Debian-based Linux system (Ubuntu, Debian, etc.)
- Root access (sudo)
- PM2 installed globally (`npm install -g pm2`)
- Node.js application in `/root/ms` directory

### Install Steps

1. **Download the installation script:**
```bash
wget https://github.com/pgwiz/botPaas/blob/main/install-ms-manager.sh
# or
curl -O https://github.com/pgwiz/botPaas/blob/main/install-ms-manager.sh
```

2. **Make it executable:**
```bash
chmod +x install-ms-manager.sh
```

3. **Run the installer:**
```bash
sudo bash install-ms-manager.sh
```

The installer will:
- ✅ Create systemd service files
- ✅ Set up configuration directory at `/etc/ms-server/`
- ✅ Install management script at `/usr/local/bin/ms-manager`
- ✅ Create log file at `/var/log/ms-server.log`
- ✅ Launch the interactive manager

## 🎯 Usage

### Interactive Manager

Launch the beautiful 3-column interface:

```bash
ms-manager
```

### Menu Options

#### 📦 Service Control (Column 1)
- **1)** Start Service - Start the MS server
- **2)** Stop Service - Stop the MS server
- **3)** Restart Service - Restart the MS server immediately
- **4)** Service Status - View detailed systemd status
- **5)** Enable Auto-start - Enable service on system boot
- **6)** Disable Auto-start - Disable auto-start

#### ⚙️ Configuration (Column 2)
- **7)** Restart Interval - Change hours between auto-restarts
- **8)** Working Directory - Change application directory (default: `/root/ms`)
- **9)** IPv6 Script Path - Change IPv6 setup script location
- **10)** Custom Commands - Add commands to run before PM2 start
- **11)** View Full Config - Display all configuration settings

#### 📊 Logs & Monitoring (Column 3)
- **12)** Live Logs - Real-time log streaming (Ctrl+C to exit)
- **13)** Last 50 Lines - View recent log entries
- **14)** Clear Logs - Clear the log file
- **15)** Check PM2 Status - View PM2 process information

### Quick Commands

```bash
# Open the manager anytime
ms-manager

# Manual service control
systemctl start ms-server
systemctl stop ms-server
systemctl restart ms-server
systemctl status ms-server

# Enable on boot
systemctl enable ms-server

# Disable auto-start
systemctl disable ms-server

# View logs
tail -f /var/log/ms-server.log

# Check if service is running
systemctl is-active ms-server
```

## 🔄 How It Works

### Boot/Restart Sequence

The service automatically executes the following sequence:

1. **IPv6 Setup (1st run)**
   ```bash
   chmod +x /root/ipv6.sh
   /root/ipv6.sh
   ```

2. **IPv6 Setup (2nd run)**
   ```bash
   chmod +x /root/ipv6.sh
   /root/ipv6.sh
   ```

3. **IPv6 Connectivity Test**
   ```bash
   ping6 -c 4 github.com
   ```

4. **Custom Commands** (if configured)
   - Runs any custom commands you've added

5. **PM2 Application Start**
   ```bash
   cd /root/ms
   pm2 stop ms
   pm2 delete ms
   pm2 start . --name ms --time
   ```

6. **Auto-restart**
   - Waits for configured interval (default: 2 hours)
   - Repeats the entire sequence

### Files & Directories

```
/etc/ms-server/
├── config.conf                    # Main configuration file

/usr/local/bin/
├── ms-manager                     # Interactive management script
└── ms-server-run.sh              # Service execution script

/etc/systemd/system/
└── ms-server.service             # Systemd service definition

/var/log/
└── ms-server.log                 # Service logs
```

## ⚙️ Configuration

### Configuration File Location
`/etc/ms-server/config.conf`

### Default Configuration

```bash
# MS Server Configuration
RESTART_INTERVAL=7200              # 2 hours in seconds
WORKING_DIR=/root/ms               # Application directory
IPV6_SCRIPT=/root/ipv6.sh          # IPv6 setup script
ENABLE_AUTO_RESTART=true           # Enable auto-restart
CUSTOM_COMMANDS=""                 # Custom commands to run
```

### Changing Settings

**Via Interactive Menu** (Recommended):
```bash
ms-manager
# Select option 7-11 to change settings
```

**Manual Edit**:
```bash
sudo nano /etc/ms-server/config.conf
# After editing, reload the service
sudo systemctl daemon-reload
sudo systemctl restart ms-server
```

## 📝 Examples

### Example 1: Change Restart Interval to 4 Hours

```bash
ms-manager
# Select option: 7
# Enter: 4
```

### Example 2: Add Custom Commands

```bash
ms-manager
# Select option: 10
# Enter: echo "Server starting..." && npm install
```

### Example 3: Change Working Directory

```bash
ms-manager
# Select option: 8
# Enter: /home/user/myapp
```

### Example 4: Monitor Logs in Real-time

```bash
ms-manager
# Select option: 12
# Press Ctrl+C to exit
```

## 🐛 Troubleshooting

### Service Won't Start

```bash
# Check service status
sudo systemctl status ms-server

# View logs
sudo tail -100 /var/log/ms-server.log

# Check if PM2 is installed
pm2 --version

# Verify working directory exists
ls -la /root/ms
```

### IPv6 Not Working

```bash
# Test IPv6 manually
ping6 github.com

# Check if IPv6 script exists
ls -la /root/ipv6.sh

# Run IPv6 script manually
sudo bash /root/ipv6.sh
```

### Service Keeps Restarting

```bash
# Check if application has errors
cd /root/ms
pm2 logs ms

# Disable auto-restart temporarily
ms-manager
# Select option: 6 (Disable auto-start)
```

### Permission Issues

```bash
# Ensure scripts are executable
sudo chmod +x /usr/local/bin/ms-server-run.sh
sudo chmod +x /usr/local/bin/ms-manager
sudo chmod +x /root/ipv6.sh
```

## 🔧 Advanced Usage

### Change Restart Interval via Command Line

```bash
# Edit config
sudo nano /etc/ms-server/config.conf
# Change RESTART_INTERVAL=7200 to desired seconds

# Update systemd
sudo sed -i 's/RestartSec=.*/RestartSec=14400/' /etc/systemd/system/ms-server.service
sudo systemctl daemon-reload
sudo systemctl restart ms-server
```

### Run Custom Pre-start Commands

Edit configuration to run commands before PM2 starts:

```bash
ms-manager
# Option 10: Add custom commands
# Example: cd /root && ./setup.sh && npm install
```

### View Systemd Journal

```bash
# View all journal entries for the service
sudo journalctl -u ms-server

# Follow journal in real-time
sudo journalctl -u ms-server -f

# View last 100 lines
sudo journalctl -u ms-server -n 100
```

## 🆘 Support

### Common Issues

| Issue | Solution |
|-------|----------|
| Service won't start | Check logs: `tail -f /var/log/ms-server.log` |
| PM2 not found | Install PM2: `npm install -g pm2` |
| Permission denied | Run with sudo or check file permissions |
| IPv6 script fails | Verify script exists and is executable |
| Config changes not applied | Restart service: `systemctl restart ms-server` |

### Log Analysis

```bash
# Check for errors in logs
grep -i error /var/log/ms-server.log

# Check last restart
grep "MS Server Starting" /var/log/ms-server.log | tail -1

# Check IPv6 test results
grep "IPv6 connectivity" /var/log/ms-server.log | tail -1
```

## 📄 Uninstallation

To completely remove MS Server Manager:

```bash
# Stop and disable service
sudo systemctl stop ms-server
sudo systemctl disable ms-server

# Remove service files
sudo rm /etc/systemd/system/ms-server.service
sudo rm /usr/local/bin/ms-server-run.sh
sudo rm /usr/local/bin/ms-manager

# Remove configuration
sudo rm -rf /etc/ms-server

# Remove logs
sudo rm /var/log/ms-server.log

# Reload systemd
sudo systemctl daemon-reload
```

## 📜 License

This project is provided as-is for managing server processes.

## 🤝 Contributing

Feel free to submit issues, fork the repository, and create pull requests for any improvements.

---
