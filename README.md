# PM2 Manager - Lightweight Terminal UI

Ultra-lightweight PM2 process manager with hacker-themed terminal interface.

## Features

- 🎯 **Lightweight**: Maximum 100MB RAM usage
- 🖥️ **Terminal UI**: Green-on-black hacker aesthetic
- 🔧 **PM2 Control**: Full process management
- 📝 **Config Editor**: Auto-detects and edits config.env files
- 📊 **Real-time Stats**: CPU, memory, uptime monitoring
- ⚡ **Direct Commands**: Execute any PM2 command

## Quick Install

```bash
wget https://raw.githubusercontent.com/pgwiz/botPaas/main/setx.sh
chmod +x setx.sh
sudo ./setx.sh
```

## Requirements

- Ubuntu/Debian Linux
- IPv6 connectivity (for Cloudflare)
- Nginx
- Python 3.7+
- PM2 (for managing processes)

## Memory Usage

- Flask app: ~30MB
- Gunicorn worker: ~25MB
- Total: **~55-80MB** (max 100MB with limits)

## Configuration

The installer will:
1. Detect existing domains
2. Configure Nginx automatically
3. Set up systemd service with memory limits
4. Create admin password

## Access

After installation:
- URL: `https://yourdomain.com/bot`
- Login with your password
- Manage PM2 processes from terminal-style UI

## Screenshots

### Login Screen
```
╔════════════════════════════════════════╗
║    PM2 MANAGER - AUTHENTICATION        ║
╚════════════════════════════════════════╝

[SYSTEM_ACCESS]

> ENTER_PASSWORD: ████████
```

### Dashboard
```
> COMMAND_EXECUTOR
> pm2 list | pm2 save | pm2 monit...

> ACTIVE_PROCESSES
ID | NAME | STATUS | CPU | MEM | UPTIME | RESTARTS
```

## Commands

```bash
# Service management
systemctl status pm2-mgr
systemctl restart pm2-mgr
journalctl -u pm2-mgr -f

# Check memory usage
ps aux | grep pm2-mgr
```

## Update Configuration

Edit `/etc/pm2-mgr.env`:
```bash
SECRET_KEY=your_secret_key
ADMIN_PASSWORD=your_password
```

Then restart:
```bash
systemctl restart pm2-mgr
```

## Uninstall

```bash
systemctl stop pm2-mgr
systemctl disable pm2-mgr
rm -rf /opt/pm2-mgr
rm /etc/systemd/system/pm2-mgr.service
rm /etc/pm2-mgr.env
systemctl daemon-reload
```

## Security Notes

- Password-protected dashboard
- Runs on localhost:5000 (proxied through Nginx)
- Auto-detects config files in process directories
- Memory-limited to prevent resource abuse

## License

MIT

## Author

Built for lightweight VPS management
