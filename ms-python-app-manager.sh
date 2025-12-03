#!/bin/bash

# Bot PaaS Manager Setup Script - Updated Version
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO_GIT_URL="https://github.com/pgwiz/botPaas.git"
REPO_ZIP_URL="https://github.com/pgwiz/botPaas/archive/refs/heads/main.zip"
REPO_RAW_BASE="https://raw.githubusercontent.com/pgwiz/botPaas/main"

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Bot PaaS Manager Installation     ║${NC}"
echo -e "${BLUE}║            Updated Version             ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}\n"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root (use sudo)${NC}"
    exit 1
fi

# Detect server's IPv6 address
IPV6_ADDR=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d'/' -f1 | head -n1 || true)
if [ -z "$IPV6_ADDR" ]; then
    echo -e "${YELLOW}Warning: No IPv6 address detected${NC}"
fi

echo -e "${CYAN}Detected IPv6 Address: ${GREEN}$IPV6_ADDR${NC}\n"

# Check if domain is already configured
EXISTING_DOMAINS=$(nginx -T 2>/dev/null | grep "server_name" | grep -v "#" | awk '{for(i=2;i<=NF;i++) print $i}' | grep -v "^$" | sort -u | tr '\n' ' ' || true)

if [ ! -z "$EXISTING_DOMAINS" ]; then
    echo -e "${GREEN}Found existing domain(s):${NC} ${CYAN}$EXISTING_DOMAINS${NC}\n"
    read -p "Do you want to use an existing domain? (y/n): " USE_EXISTING
    
    if [ "$USE_EXISTING" = "y" ] || [ "$USE_EXISTING" = "Y" ]; then
        echo -e "\n${YELLOW}Available domains:${NC}"
        select DOMAIN in $EXISTING_DOMAINS "Enter new domain"; do
            if [ "$DOMAIN" = "Enter new domain" ]; then
                read -p "Enter your domain: " DOMAIN
                break
            elif [ ! -z "$DOMAIN" ]; then
                break
            fi
        done
    else
        read -p "Enter your domain: " DOMAIN
    fi
else
    echo -e "${YELLOW}No existing domains found.${NC}"
    read -p "Enter your domain (e.g., servx.pgwiz.us.kg): " DOMAIN
fi

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Domain cannot be empty${NC}"
    exit 1
fi

echo -e "\n${CYAN}Selected domain: ${GREEN}$DOMAIN${NC}\n"

# Check if Nginx config exists for this domain
NGINX_CONFIG="/etc/nginx/sites-available/$DOMAIN"
NGINX_EXISTS=false

if [ -f "$NGINX_CONFIG" ]; then
    echo -e "${GREEN}Found existing Nginx configuration for $DOMAIN${NC}"
    NGINX_EXISTS=true
else
    echo -e "${YELLOW}No existing Nginx configuration found for $DOMAIN${NC}"
    read -p "Do you want to create a basic Nginx configuration? (y/n): " CREATE_NGINX
fi

# Set admin password
echo -e "\n${CYAN}Set up admin credentials:${NC}"
read -sp "Set admin password: " ADMIN_PASSWORD
echo
read -sp "Confirm admin password: " ADMIN_PASSWORD_CONFIRM
echo

if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
    echo -e "${RED}Passwords do not match${NC}"
    exit 1
fi

echo -e "\n${GREEN}[1/8] Checking system requirements...${NC}"

# Check if already installed
ALREADY_INSTALLED=false
if [ -d "/opt/bot-paas" ]; then
    echo -e "${YELLOW}Bot PaaS is already installed!${NC}"
    read -p "Do you want to reinstall? This will keep your bots but update the application (y/n): " REINSTALL
    if [ "$REINSTALL" != "y" ] && [ "$REINSTALL" != "Y" ]; then
        echo -e "${RED}Installation cancelled${NC}"
        exit 0
    fi
    ALREADY_INSTALLED=true
fi

echo -e "${GREEN}[2/8] Installing Python and dependencies...${NC}"
apt update
# include git and unzip so we can fetch repo, and curl already used elsewhere
apt install -y python3 python3-pip python3-venv nginx curl git unzip

echo -e "${GREEN}[3/8] Setting up application directory...${NC}"
APP_DIR="/opt/bot-paas"

if [ "$ALREADY_INSTALLED" = true ]; then
    echo -e "${YELLOW}Backing up existing installation...${NC}"
    systemctl stop bot-paas 2>/dev/null || true
    cp -r "$APP_DIR" "${APP_DIR}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
fi

mkdir -p "$APP_DIR"
cd "$APP_DIR"

# Create virtual environment if it doesn't exist
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi

# Use venv pip from absolute path to avoid sourcings that can be shell-specific
"$APP_DIR/venv/bin/python" -m ensurepip --upgrade >/dev/null 2>&1 || true
"$APP_DIR/venv/bin/pip" install --upgrade pip setuptools wheel >/dev/null 2>&1 || true

# Ensure gunicorn and flask present
"$APP_DIR/venv/bin/pip" install --upgrade flask gunicorn >/dev/null 2>&1 || {
    echo -e "${YELLOW}Warning: pip install returned non-zero; rerun installation manually to see errors${NC}"
}

echo -e "${GREEN}[4/8] Creating/Updating application files...${NC}"

# --------- Copy app.py and templates from local repo / working dir / upstream repo ----------
# Priority:
# 1) If installer run from a directory containing app.py/templates (local dev), use them.
# 2) Else git clone repo and copy files.
# 3) Else curl download repo zip and extract.

install_from_local() {
    echo -e "${GREEN}Using local files from current directory${NC}"
    # copy app.py
    if [ -f "./app.py" ]; then
        cp -f "./app.py" "$APP_DIR/app.py"
        echo -e "${GREEN}Copied local app.py -> $APP_DIR/app.py${NC}"
    fi
    # copy templates dir if present
    if [ -d "./templates" ]; then
        rm -rf "$APP_DIR/templates" 2>/dev/null || true
        cp -a "./templates" "$APP_DIR/templates"
        echo -e "${GREEN}Copied local templates/ -> $APP_DIR/templates${NC}"
    fi
}

install_from_git() {
    echo -e "${GREEN}Cloning repository to fetch app.py/templates...${NC}"
    TMPDIR="$(mktemp -d)"
    git clone --depth 1 "$REPO_GIT_URL" "$TMPDIR" >/dev/null 2>&1 || {
        echo -e "${YELLOW}git clone failed${NC}"
        rm -rf "$TMPDIR"
        return 1
    }
    if [ -f "$TMPDIR/app.py" ]; then
        cp -f "$TMPDIR/app.py" "$APP_DIR/app.py"
        echo -e "${GREEN}Copied $TMPDIR/app.py -> $APP_DIR/app.py${NC}"
    fi
    if [ -d "$TMPDIR/templates" ]; then
        rm -rf "$APP_DIR/templates" 2>/dev/null || true
        cp -a "$TMPDIR/templates" "$APP_DIR/templates"
        echo -e "${GREEN}Copied $TMPDIR/templates -> $APP_DIR/templates${NC}"
    fi
    rm -rf "$TMPDIR"
    return 0
}

install_from_zip() {
    echo -e "${GREEN}Downloading repo zip to fetch app.py/templates...${NC}"
    TMPZIP="$(mktemp)"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$REPO_ZIP_URL" -o "$TMPZIP" || { echo -e "${YELLOW}zip download failed${NC}"; rm -f "$TMPZIP"; return 1; }
    else
        echo -e "${RED}curl not available to download repo zip${NC}"
        return 1
    fi
    TMPDIR="$(mktemp -d)"
    unzip -q "$TMPZIP" -d "$TMPDIR" || { echo -e "${YELLOW}unzip failed${NC}"; rm -f "$TMPZIP"; rm -rf "$TMPDIR"; return 1; }
    EXTRACTED_DIR="$(find "$TMPDIR" -maxdepth 1 -type d -name "*botPaas-main" -print -quit || true)"
    if [ -z "$EXTRACTED_DIR" ]; then
        # fallback: try to find app.py anywhere inside
        EXTRACTED_DIR="$(find "$TMPDIR" -type f -name app.py -print -quit 2>/dev/null | xargs -r dirname || true)"
    fi
    if [ -n "$EXTRACTED_DIR" ] && [ -f "$EXTRACTED_DIR/app.py" ]; then
        cp -f "$EXTRACTED_DIR/app.py" "$APP_DIR/app.py"
        echo -e "${GREEN}Copied $EXTRACTED_DIR/app.py -> $APP_DIR/app.py${NC}"
    fi
    if [ -n "$EXTRACTED_DIR" ] && [ -d "$EXTRACTED_DIR/templates" ]; then
        rm -rf "$APP_DIR/templates" 2>/dev/null || true
        cp -a "$EXTRACTED_DIR/templates" "$APP_DIR/templates"
        echo -e "${GREEN}Copied $EXTRACTED_DIR/templates -> $APP_DIR/templates${NC}"
    fi
    rm -f "$TMPZIP"
    rm -rf "$TMPDIR"
    return 0
}

# Try local first
if [ -f "./app.py" ] || [ -d "./templates" ]; then
    install_from_local
else
    # Try git clone
    if command -v git >/dev/null 2>&1; then
        if install_from_git; then
            :
        else
            # git failed, try zip
            install_from_zip || echo -e "${YELLOW}Failed to fetch from repo via git or zip. Falling back to script defaults.${NC}"
        fi
    else
        # git missing -> try zip via curl
        if install_from_zip; then
            :
        else
            echo -e "${YELLOW}Could not fetch repo. Falling back to built-in defaults.${NC}"
        fi
    fi
fi

# If app.py still not present, write the builtin default
if [ ! -f "$APP_DIR/app.py" ]; then
    echo -e "${YELLOW}No app.py found in local or repo — writing default app.py${NC}"
    cat > "$APP_DIR/app.py" <<'APPPY'
# (default app.py content) - minimal version in case repo not available.
from flask import Flask, render_template, request, jsonify, session, redirect, url_for
import os, secrets
from functools import wraps
from pathlib import Path
from werkzeug.middleware.proxy_fix import ProxyFix

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)
app.secret_key = os.environ.get('SECRET_KEY', secrets.token_hex(32))
URL_PREFIX = '/bot'
BOTS_DIR = Path.home() / 'bots'
BOTS_DIR.mkdir(exist_ok=True)

def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'authenticated' not in session:
            return redirect(URL_PREFIX + '/login')
        return f(*args, **kwargs)
    return decorated

@app.route(URL_PREFIX + '/')
def index():
    return redirect(URL_PREFIX + '/dashboard')

@app.route(URL_PREFIX + '/login', methods=['GET','POST'])
def login():
    if request.method == 'POST':
        if request.form.get('password') == os.environ.get('ADMIN_PASSWORD','admin'):
            session['authenticated'] = True
            return redirect(URL_PREFIX + '/dashboard')
        return "Invalid", 403
    return render_template('login.html')

@app.route(URL_PREFIX + '/dashboard')
@login_required
def dashboard():
    return render_template('dashboard.html')

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000)
APPPY
fi

# If templates missing, create minimal templates unless we copied them from repo or local
if [ ! -d "$APP_DIR/templates" ]; then
    echo -e "${YELLOW}No templates found in local or repo — creating simple templates${NC}"
    mkdir -p "$APP_DIR/templates"
    cat > "$APP_DIR/templates/login.html" <<'LOGINHTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Login</title></head>
<body>
<form method="post">
  <input type="password" name="password" placeholder="Password"/>
  <button type="submit">Login</button>
</form>
</body></html>
LOGINHTML

    cat > "$APP_DIR/templates/dashboard.html" <<'DASHHTML'
<!doctype html>
<html><head><meta charset="utf-8"><title>Dashboard</title></head>
<body>
<h1>Bot PaaS Dashboard</h1>
<p>Minimal dashboard: implement your templates in the repo.</p>
</body></html>
DASHHTML
fi

# Ensure correct ownership and permissions
chown -R root:root "$APP_DIR"
chmod -R u+rwX "$APP_DIR"

echo -e "${GREEN}[5/8] Creating systemd service...${NC}"

# Create environment file
cat > /etc/bot-paas.env << ENVFILE
SECRET_KEY=$(openssl rand -hex 32)
ADMIN_PASSWORD=$ADMIN_PASSWORD
ENVFILE

# Create systemd service (use python -m gunicorn for robustness)
cat > /etc/systemd/system/bot-paas.service << SERVICEEOF
[Unit]
Description=Bot PaaS Manager
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=/etc/bot-paas.env
ExecStart=$APP_DIR/venv/bin/python -m gunicorn --bind 127.0.0.1:5000 --workers 2 app:app
Restart=always

[Install]
WantedBy=multi-user.target
SERVICEEOF

echo -e "${GREEN}[6/8] Configuring Nginx...${NC}"

# Handle Nginx configuration
if [ "$NGINX_EXISTS" = true ]; then
    echo -e "${YELLOW}Updating existing Nginx configuration...${NC}"
    
    # Remove old /bot location blocks if they exist
    sed -i '/# Bot PaaS Manager/,/^    }/d' "$NGINX_CONFIG" || true
    sed -i '/location \/bot/,/^    }/d' "$NGINX_CONFIG" || true
    
    # Add new /bot location block after error_log
    if grep -q "error_log" "$NGINX_CONFIG"; then
        sed -i '/error_log.*\.log;/a\
\
    # Bot PaaS Manager\
    location /bot {\
        proxy_pass http://127.0.0.1:5000;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\
        proxy_set_header X-Forwarded-Proto $scheme;\
    }' "$NGINX_CONFIG"
    else
        # If no error_log found, add before first location block
        sed -i '0,/location \//s//# Bot PaaS Manager\n    location \/bot {\n        proxy_pass http:\/\/127.0.0.1:5000;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n    }\n\n    location \//' "$NGINX_CONFIG"
    fi
    
    echo -e "${GREEN}Nginx configuration updated${NC}"
elif [ "$CREATE_NGINX" = "y" ] || [ "$CREATE_NGINX" = "Y" ]; then
    echo -e "${YELLOW}Creating new Nginx configuration...${NC}"
    
    # Check if SSL certificate exists
    if [ -f "/etc/ssl/certs/$DOMAIN-selfsigned.crt" ]; then
        SSL_CERT="/etc/ssl/certs/$DOMAIN-selfsigned.crt"
        SSL_KEY="/etc/ssl/private/$DOMAIN-selfsigned.key"
    else
        # Generate self-signed certificate
        echo -e "${YELLOW}Generating self-signed SSL certificate...${NC}"
        mkdir -p /etc/ssl/private /etc/ssl/certs
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /etc/ssl/private/$DOMAIN-selfsigned.key \
            -out /etc/ssl/certs/$DOMAIN-selfsigned.crt \
            -subj "/C=US/ST=State/L=City/O=Organization/CN=$DOMAIN"
        SSL_CERT="/etc/ssl/certs/$DOMAIN-selfsigned.crt"
        SSL_KEY="/etc/ssl/private/$DOMAIN-selfsigned.key"
    fi
    
    cat > "$NGINX_CONFIG" << NGINXEOF
# HTTP Server Block - IPv6
server {
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

# HTTPS Server Block - IPv6
server {
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    
    root /var/www/$DOMAIN;
    index index.html index.htm;
    
    ssl_certificate $SSL_CERT;
    ssl_certificate_key $SSL_KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log /var/log/nginx/${DOMAIN}_error.log;
    
    # Bot PaaS Manager
    location /bot {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXEOF
    
    # Create web root
    mkdir -p "/var/www/$DOMAIN"
    echo "<h1>Welcome to $DOMAIN</h1><p>Bot PaaS is available at <a href='/bot'>/bot</a></p>" > "/var/www/$DOMAIN/index.html"
    
    # Enable site
    ln -sf "$NGINX_CONFIG" /etc/nginx/sites-enabled/
    
    echo -e "${GREEN}Nginx configuration created${NC}"
fi

# Test Nginx
nginx -t

echo -e "${GREEN}[7/8] Setting up DNS information...${NC}"

if [ ! -z "$IPV6_ADDR" ]; then
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}DNS Configuration Required:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Add this record to your DNS (e.g., Cloudflare):\n"
    echo -e "  ${GREEN}Type:${NC} AAAA"
    echo -e "  ${GREEN}Name:${NC} @ (or subdomain)"
    echo -e "  ${GREEN}Content:${NC} $IPV6_ADDR"
    echo -e "  ${GREEN}Proxy:${NC} Enabled (Orange Cloud) ✓"
    echo -e "  ${GREEN}TTL:${NC} Auto\n"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
fi

echo -e "${GREEN}[8/8] Starting services...${NC}"

# Reload systemd
systemctl daemon-reload

# Start and enable bot-paas service
systemctl restart bot-paas || systemctl start bot-paas || true
systemctl enable bot-paas

# Restart Nginx
systemctl restart nginx

# Wait for service to start
sleep 2

# Check if service is running
if systemctl is-active --quiet bot-paas; then
    SERVICE_STATUS="${GREEN}Running ✓${NC}"
else
    SERVICE_STATUS="${RED}Failed ✗${NC}"
fi

echo -e "\n${CYAN}════════════════════════════════════════${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}\n"

echo -e "${YELLOW}Service Status:${NC} $SERVICE_STATUS\n"

echo -e "${YELLOW}Access your Bot PaaS Manager:${NC}"
echo -e "${BLUE}https://$DOMAIN/bot${NC}\n"

echo -e "${YELLOW}Login Credentials:${NC}"
echo -e "Password: ${GREEN}[the password you set]${NC}\n"

echo -e "${YELLOW}Important Directories:${NC}"
echo -e "App Directory:  ${BLUE}$APP_DIR${NC}"
echo -e "Bots Directory: ${BLUE}$HOME/bots${NC}"
echo -e "Nginx Config:   ${BLUE}$NGINX_CONFIG${NC}\n"

echo -e "${YELLOW}Service Management:${NC}"
echo -e "Start:   ${BLUE}systemctl start bot-paas${NC}"
echo -e "Stop:    ${BLUE}systemctl stop bot-paas${NC}"
echo -e "Restart: ${BLUE}systemctl restart bot-paas${NC}"
echo -e "Status:  ${BLUE}systemctl status bot-paas${NC}"
echo -e "Logs:    ${BLUE}journalctl -u bot-paas -f${NC}\n"

echo -e "${YELLOW}Nginx Management:${NC}"
echo -e "Test:    ${BLUE}nginx -t${NC}"
echo -e "Reload:  ${BLUE}systemctl reload nginx${NC}"
echo -e "Logs:    ${BLUE}tail -f /var/log/nginx/${DOMAIN}_error.log${NC}\n"

if [ ! -z "$IPV6_ADDR" ]; then
    echo -e "${YELLOW}Server IPv6:${NC} ${GREEN}$IPV6_ADDR${NC}\n"
fi

echo -e "${CYAN}Features:${NC}"
echo -e "  ${GREEN}✓${NC} Beautiful modern UI with purple gradient"
echo -e "  ${GREEN}✓${NC} One-click bot deployment from GitHub"
echo -e "  ${GREEN}✓${NC} Browser-based config editor"
echo -e "  ${GREEN}✓${NC} Real-time PM2 monitoring"
echo -e "  ${GREEN}✓${NC} Live log viewer"
echo -e "  ${GREEN}✓${NC} Custom PM2 commands"
echo -e "  ${GREEN}✓${NC} Password-protected dashboard\n"

echo -e "${GREEN}Happy bot hosting! 🤖${NC}\n"

# Test local access
echo -e "${YELLOW}Testing local access...${NC}"
if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5000/bot/ | grep -q "200\|302"; then
    echo -e "${GREEN}✓ Local access working${NC}\n"
else
    echo -e "${RED}✗ Local access failed - check logs:${NC}"
    echo -e "  ${BLUE}journalctl -u bot-paas -n 20${NC}\n"
fi

# Create quick reference card
cat > /root/bot-paas-info.txt << INFOEOF
═══════════════════════════════════════════
    Bot PaaS Manager - Quick Reference
═══════════════════════════════════════════

Dashboard URL: https://$DOMAIN/bot
Service: bot-paas
Port: 5000 (localhost only)

Directories:
  - Application: $APP_DIR
  - Bots: $HOME/bots
  - Config: /etc/bot-paas.env

Commands:
  - Start:   systemctl start bot-paas
  - Stop:    systemctl stop bot-paas
  - Restart: systemctl restart bot-paas
  - Status:  systemctl status bot-paas
  - Logs:    journalctl -u bot-paas -f

Nginx:
  - Config: $NGINX_CONFIG
  - Test:   nginx -t
  - Reload: systemctl reload nginx

Server IPv6: $IPV6_ADDR

Installation Date: $(date)
═══════════════════════════════════════════
INFOEOF

echo -e "${GREEN}Quick reference saved to:${NC} ${BLUE}/root/bot-paas-info.txt${NC}\n"
