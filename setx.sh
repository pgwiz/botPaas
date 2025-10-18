#!/bin/bash

# PM2 Manager Lightweight Installer (setx.sh)
# Maximum RAM usage: 100MB
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

clear
echo -e "${GREEN}"
cat << "EOF"
╔═══════════════════════════════════════╗
║    PM2 MANAGER - LIGHTWEIGHT SETUP    ║
║           MAX RAM: 100MB              ║
╚═══════════════════════════════════════╝
EOF
echo -e "${NC}\n"

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}[!] ROOT ACCESS REQUIRED${NC}"
    exit 1
fi

# GitHub repository details
GITHUB_USER="pgwiz"
GITHUB_REPO="botPaas"
GITHUB_BRANCH="main"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

echo -e "${CYAN}[*] DETECTING SYSTEM...${NC}"

# Detect IPv6
IPV6_ADDR=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d'/' -f1 | head -n1)
if [ -z "$IPV6_ADDR" ]; then
    echo -e "${YELLOW}[!] NO IPv6 DETECTED${NC}"
else
    echo -e "${GREEN}[+] IPv6: $IPV6_ADDR${NC}"
fi

# Check existing domains
EXISTING_DOMAINS=$(nginx -T 2>/dev/null | grep "server_name" | grep -v "#" | awk '{for(i=2;i<=NF;i++) print $i}' | grep -v "^$" | sort -u | tr '\n' ' ' || echo "")

if [ ! -z "$EXISTING_DOMAINS" ]; then
    echo -e "${GREEN}[+] FOUND DOMAINS: ${CYAN}$EXISTING_DOMAINS${NC}\n"
    read -p "$(echo -e ${YELLOW}'[?] USE EXISTING DOMAIN? (y/n): '${NC})" USE_EXISTING
    
    if [ "$USE_EXISTING" = "y" ] || [ "$USE_EXISTING" = "Y" ]; then
        echo -e "\n${CYAN}AVAILABLE:${NC}"
        select DOMAIN in $EXISTING_DOMAINS "ENTER_NEW"; do
            if [ "$DOMAIN" = "ENTER_NEW" ]; then
                read -p "$(echo -e ${CYAN}'[>] DOMAIN: '${NC})" DOMAIN
                break
            elif [ ! -z "$DOMAIN" ]; then
                break
            fi
        done
    else
        read -p "$(echo -e ${CYAN}'[>] DOMAIN: '${NC})" DOMAIN
    fi
else
    read -p "$(echo -e ${CYAN}'[>] DOMAIN: '${NC})" DOMAIN
fi

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}[!] DOMAIN REQUIRED${NC}"
    exit 1
fi

echo -e "${GREEN}[+] DOMAIN: $DOMAIN${NC}\n"

# Password setup
read -sp "$(echo -e ${CYAN}'[>] ADMIN PASSWORD: '${NC})" ADMIN_PASSWORD
echo
read -sp "$(echo -e ${CYAN}'[>] CONFIRM PASSWORD: '${NC})" ADMIN_PASSWORD_CONFIRM
echo

if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
    echo -e "${RED}[!] PASSWORD MISMATCH${NC}"
    exit 1
fi

# Check if already installed
APP_DIR="/opt/pm2-mgr"
if [ -d "$APP_DIR" ]; then
    echo -e "\n${YELLOW}[!] EXISTING INSTALLATION FOUND${NC}"
    read -p "$(echo -e ${YELLOW}'[?] REMOVE AND REINSTALL? (y/n): '${NC})" REINSTALL
    if [ "$REINSTALL" = "y" ] || [ "$REINSTALL" = "Y" ]; then
        echo -e "${CYAN}[*] STOPPING SERVICE...${NC}"
        systemctl stop pm2-mgr 2>/dev/null || true
        echo -e "${CYAN}[*] REMOVING OLD INSTALLATION...${NC}"
        rm -rf $APP_DIR
        rm -f /etc/systemd/system/pm2-mgr.service
        rm -f /etc/pm2-mgr.env
        systemctl daemon-reload
        echo -e "${GREEN}[+] CLEANUP COMPLETE${NC}"
    else
        echo -e "${RED}[!] INSTALLATION CANCELLED${NC}"
        exit 0
    fi
fi

echo -e "\n${CYAN}[1/6] INSTALLING MINIMAL DEPENDENCIES...${NC}"
apt update -qq
apt install -y python3-pip nginx curl git >/dev/null 2>&1

echo -e "${GREEN}[+] DEPENDENCIES INSTALLED${NC}"

echo -e "${CYAN}[2/6] CREATING APPLICATION STRUCTURE...${NC}"
mkdir -p $APP_DIR/templates
cd $APP_DIR

echo -e "${CYAN}[*] DOWNLOADING FILES FROM GITHUB...${NC}"

# Download app.py
curl -sL "$GITHUB_RAW/app.py" -o app.py || {
    echo -e "${YELLOW}[!] GITHUB DOWNLOAD FAILED, USING EMBEDDED VERSION${NC}"
    
    # Embedded minimal app.py
    cat > app.py << 'APPPY'
from flask import Flask, render_template, request, jsonify, session, redirect, url_for
import os, subprocess, json, secrets
from functools import wraps
from pathlib import Path
from werkzeug.middleware.proxy_fix import ProxyFix

app = Flask(__name__)
app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)
app.secret_key = os.environ.get('SECRET_KEY', secrets.token_hex(32))
URL_PREFIX = '/bot'

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'authenticated' not in session:
            return redirect(URL_PREFIX + '/login')
        return f(*args, **kwargs)
    return decorated_function

def run_command(cmd, cwd=None):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd, timeout=300)
        return {'success': result.returncode == 0, 'output': result.stdout, 'error': result.stderr}
    except Exception as e:
        return {'success': False, 'error': str(e)}

def get_process_cwd(pid):
    try:
        result = subprocess.run(f'readlink -f /proc/{pid}/cwd', shell=True, capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    except:
        pass
    return None

def find_config_file(cwd):
    if not cwd:
        return None
    path = Path(cwd)
    config_file = path / 'config.env'
    if config_file.exists():
        return str(config_file)
    return None

@app.route(URL_PREFIX + '/')
def index():
    if 'authenticated' not in session:
        return redirect(URL_PREFIX + '/login')
    return redirect(URL_PREFIX + '/dashboard')

@app.route(URL_PREFIX + '/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        password = request.form.get('password')
        stored_password = os.environ.get('ADMIN_PASSWORD', 'admin')
        if password == stored_password:
            session['authenticated'] = True
            return redirect(URL_PREFIX + '/dashboard')
        return render_template('login.html', error='ACCESS_DENIED')
    return render_template('login.html')

@app.route(URL_PREFIX + '/logout')
def logout():
    session.clear()
    return redirect(URL_PREFIX + '/login')

@app.route(URL_PREFIX + '/dashboard')
@login_required
def dashboard():
    return render_template('dashboard.html')

@app.route(URL_PREFIX + '/api/pm2/list')
@login_required
def pm2_list():
    result = run_command('pm2 jlist')
    if result['success']:
        try:
            processes = json.loads(result['output'])
            for proc in processes:
                pid = proc.get('pid')
                if pid:
                    cwd = get_process_cwd(pid)
                    proc['cwd'] = cwd
                    proc['config_file'] = find_config_file(cwd)
            return jsonify({'success': True, 'processes': processes})
        except Exception as e:
            return jsonify({'success': False, 'error': str(e)})
    return jsonify(result)

@app.route(URL_PREFIX + '/api/pm2/command', methods=['POST'])
@login_required
def pm2_command():
    command = request.json.get('command')
    if not command:
        return jsonify({'success': False, 'error': 'COMMAND_REQUIRED'})
    if not command.strip().startswith('pm2'):
        command = f'pm2 {command}'
    result = run_command(command)
    return jsonify(result)

@app.route(URL_PREFIX + '/api/process/<process_id>/logs')
@login_required
def process_logs(process_id):
    lines = request.args.get('lines', 100)
    result = run_command(f'pm2 logs {process_id} --lines {lines} --nostream')
    return jsonify(result)

@app.route(URL_PREFIX + '/api/process/<process_id>/restart', methods=['POST'])
@login_required
def restart_process(process_id):
    result = run_command(f'pm2 restart {process_id}')
    return jsonify(result)

@app.route(URL_PREFIX + '/api/process/<process_id>/stop', methods=['POST'])
@login_required
def stop_process(process_id):
    result = run_command(f'pm2 stop {process_id}')
    return jsonify(result)

@app.route(URL_PREFIX + '/api/process/<process_id>/delete', methods=['POST'])
@login_required
def delete_process(process_id):
    result = run_command(f'pm2 delete {process_id}')
    return jsonify(result)

@app.route(URL_PREFIX + '/api/config/read', methods=['POST'])
@login_required
def read_config():
    config_path = request.json.get('path')
    if not config_path:
        return jsonify({'success': False, 'error': 'PATH_REQUIRED'})
    try:
        path = Path(config_path)
        if not path.exists():
            return jsonify({'success': False, 'error': 'FILE_NOT_FOUND'})
        content = path.read_text()
        return jsonify({'success': True, 'content': content})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

@app.route(URL_PREFIX + '/api/config/write', methods=['POST'])
@login_required
def write_config():
    config_path = request.json.get('path')
    content = request.json.get('content')
    if not config_path or content is None:
        return jsonify({'success': False, 'error': 'MISSING_PARAMS'})
    try:
        path = Path(config_path)
        path.write_text(content)
        return jsonify({'success': True, 'message': 'CONFIG_SAVED'})
    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000, debug=False)
APPPY
}

# Download login.html
curl -sL "$GITHUB_RAW/templates/login.html" -o templates/login.html || {
    echo -e "${YELLOW}[!] DOWNLOADING EMBEDDED LOGIN${NC}"
    cat > templates/login.html << 'LOGINHTML'
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>PM2 - AUTH</title><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Courier New',monospace;background:#0a0a0a;color:#00ff00;min-height:100vh;display:flex;align-items:center;justify-content:center}.terminal{background:rgba(0,0,0,.9);border:2px solid #00ff00;padding:30px;max-width:500px;width:90%;box-shadow:0 0 50px rgba(0,255,0,.3)}.terminal-header{border-bottom:1px solid #00ff00;padding-bottom:10px;margin-bottom:20px;font-size:14px}h1{font-size:20px;margin-bottom:20px;letter-spacing:2px}.error{background:rgba(255,0,0,.2);border:1px solid #f00;color:#f00;padding:10px;margin-bottom:20px;font-size:12px}.input-line{margin-bottom:20px}.prompt{color:#00ff00;margin-bottom:5px}input{width:100%;background:#000;border:1px solid #00ff00;color:#00ff00;padding:10px;font-family:'Courier New',monospace;font-size:14px;outline:0}input:focus{box-shadow:0 0 10px rgba(0,255,0,.5)}button{width:100%;background:#000;border:2px solid #00ff00;color:#00ff00;padding:12px;font-family:'Courier New',monospace;font-size:14px;cursor:pointer;letter-spacing:2px}button:hover{background:#00ff00;color:#000}</style></head><body><div class="terminal"><div class="terminal-header">[PM2_MANAGER] - AUTH_REQUIRED</div><h1>[ SYSTEM_ACCESS ]</h1>{% if error %}<div class="error">> ERROR: {{ error }}</div>{% endif %}<form method="POST" action="/bot/login"><div class="input-line"><div class="prompt">> PASSWORD:</div><input type="password" name="password" required autofocus></div><button type="submit">[ AUTHENTICATE ]</button></form></div></body></html>
LOGINHTML
}

# Download dashboard.html  
curl -sL "$GITHUB_RAW/templates/dashboard.html" -o templates/dashboard.html || {
    echo -e "${YELLOW}[!] DOWNLOADING EMBEDDED DASHBOARD${NC}"
    # If GitHub fails, use embedded minified version
    cat > templates/dashboard.html << 'DASHHTML'
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>PM2 - CONSOLE</title><style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Courier New',monospace;background:#0a0a0a;color:#00ff00;font-size:13px}.header{background:#000;border-bottom:2px solid #00ff00;padding:15px 20px;display:flex;justify-content:space-between;align-items:center}.header h1{font-size:16px;letter-spacing:3px}.header a{color:#f00;text-decoration:none;border:1px solid #f00;padding:5px 15px}.header a:hover{background:#f00;color:#000}.container{padding:20px;max-width:1600px;margin:0 auto}.section{background:rgba(0,0,0,.8);border:1px solid #00ff00;margin-bottom:20px;padding:15px}.section-title{border-bottom:1px solid #00ff00;padding-bottom:8px;margin-bottom:15px;font-size:14px;letter-spacing:2px}.cmd-input{display:flex;gap:10px;margin-bottom:15px}.cmd-input input{flex:1;background:#000;border:1px solid #00ff00;color:#00ff00;padding:8px;font-family:'Courier New',monospace;outline:0}.btn{background:#000;border:1px solid #00ff00;color:#00ff00;padding:8px 15px;font-family:'Courier New',monospace;cursor:pointer;font-size:12px}.btn:hover{background:#00ff00;color:#000}.btn-danger{border-color:#f00;color:#f00}.btn-danger:hover{background:#f00;color:#000}.btn-warn{border-color:#ff0;color:#ff0}.btn-warn:hover{background:#ff0;color:#000}table{width:100%;border-collapse:collapse;font-size:12px}th,td{text-align:left;padding:10px;border-bottom:1px solid #030}th{background:#010;color:#00ff00}tr:hover{background:rgba(0,255,0,.05)}.status-online{color:#00ff00}.status-offline{color:#f00}.process-actions{display:flex;gap:5px}.process-actions button{padding:4px 8px;font-size:11px}pre{background:#000;color:#00ff00;padding:15px;overflow-x:auto;border:1px solid #030;max-height:400px;overflow-y:auto;font-size:11px}.modal{display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,.95);z-index:1000;align-items:center;justify-content:center}.modal.active{display:flex}.modal-content{background:#0a0a0a;border:2px solid #00ff00;padding:20px;width:90%;max-width:800px;max-height:80vh;overflow-y:auto}.modal-title{border-bottom:1px solid #00ff00;padding-bottom:10px;margin-bottom:15px;font-size:14px}textarea{width:100%;background:#000;border:1px solid #00ff00;color:#00ff00;padding:10px;font-family:'Courier New',monospace;font-size:12px;min-height:400px;outline:0}.loading{text-align:center;padding:20px;opacity:.7}.no-config{color:#666;font-style:italic}</style></head><body><div class="header"><h1>[ PM2_MANAGER ]</h1><a href="/bot/logout">[ DISCONNECT ]</a></div><div class="container"><div class="section"><div class="section-title">> COMMAND_EXECUTOR</div><div class="cmd-input"><input type="text" id="customCmd" placeholder="pm2 list | save | monit..."/><button class="btn" onclick="runCommand()">[ EXECUTE ]</button><button class="btn" onclick="refreshProcesses()">[ REFRESH ]</button></div><pre id="cmdOutput" style="display:none"></pre></div><div class="section"><div class="section-title">> ACTIVE_PROCESSES</div><div id="processList" class="loading">LOADING...</div></div></div><div id="logsModal" class="modal"><div class="modal-content"><div class="modal-title" id="logsTitle">> LOGS</div><pre id="logsContent">LOADING...</pre><button class="btn btn-danger" onclick="closeModal('logsModal')" style="margin-top:10px">[ CLOSE ]</button></div></div><div id="configModal" class="modal"><div class="modal-content"><div class="modal-title" id="configTitle">> CONFIG</div><textarea id="configContent"></textarea><div style="margin-top:10px;display:flex;gap:10px"><button class="btn" onclick="saveConfig()">[ SAVE ]</button><button class="btn btn-danger" onclick="closeModal('configModal')">[ CANCEL ]</button></div></div></div><script>let currentConfigPath=null;async function runCommand(){const cmd=document.getElementById('customCmd').value;if(!cmd)return;const output=document.getElementById('cmdOutput');output.style.display='block';output.textContent='> '+cmd+'\n\n';const res=await fetch('/bot/api/pm2/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({command:cmd})});const data=await res.json();output.textContent+=data.success?data.output:'[ERROR] '+data.error;if(cmd.includes('restart')||cmd.includes('stop')||cmd.includes('start')||cmd.includes('delete')){setTimeout(refreshProcesses,1000)}}async function refreshProcesses(){const container=document.getElementById('processList');container.innerHTML='<div class="loading">LOADING...</div>';const res=await fetch('/bot/api/pm2/list');const data=await res.json();if(!data.success||data.processes.length===0){container.innerHTML='<div class="loading">NO_PROCESSES</div>';return}let html='<table><thead><tr><th>ID</th><th>NAME</th><th>STATUS</th><th>CPU</th><th>MEM</th><th>UP</th><th>RST</th><th>PATH</th><th>ACT</th></tr></thead><tbody>';data.processes.forEach(proc=>{const status=proc.pm2_env?.status==='online'?'online':'offline';const uptime=proc.pm2_env?.pm_uptime?Math.floor((Date.now()-proc.pm2_env.pm_uptime)/60000)+'m':'-';const cpu=proc.monit?.cpu||0;const mem=Math.round((proc.monit?.memory||0)/1048576);const hasConfig=proc.config_file?'✓':'';html+=`<tr><td>${proc.pm_id}</td><td><strong>${proc.name}</strong></td><td class="status-${status}">${status.toUpperCase()}</td><td>${cpu}%</td><td>${mem}MB</td><td>${uptime}</td><td>${proc.pm2_env?.restart_time||0}</td><td>${proc.cwd||'-'} ${hasConfig?'<span style="color:#0f0">[CFG]</span>':'<span class="no-config">[NO]</span>'}</td><td class="process-actions"><button class="btn" onclick="restartProcess('${proc.name}')">RST</button><button class="btn btn-warn" onclick="stopProcess('${proc.name}')">STP</button><button class="btn" onclick="viewLogs('${proc.name}')">LOG</button>${proc.config_file?`<button class="btn" onclick="editConfig('${proc.config_file}','${proc.name}')">CFG</button>`:''}<button class="btn btn-danger" onclick="deleteProcess('${proc.name}')">DEL</button></td></tr>`});html+='</tbody></table>';container.innerHTML=html}async function restartProcess(name){if(!confirm(`RESTART ${name}?`))return;const res=await fetch(`/bot/api/process/${name}/restart`,{method:'POST'});const data=await res.json();alert(data.success?'RESTARTED':'ERROR: '+data.error);refreshProcesses()}async function stopProcess(name){if(!confirm(`STOP ${name}?`))return;const res=await fetch(`/bot/api/process/${name}/stop`,{method:'POST'});const data=await res.json();alert(data.success?'STOPPED':'ERROR: '+data.error);refreshProcesses()}async function deleteProcess(name){if(!confirm(`DELETE ${name}?`))return;const res=await fetch(`/bot/api/process/${name}/delete`,{method:'POST'});const data=await res.json();alert(data.success?'DELETED':'ERROR: '+data.error);refreshProcesses()}async function viewLogs(name){document.getElementById('logsTitle').textContent=`> LOGS: ${name}`;document.getElementById('logsContent').textContent='LOADING...';document.getElementById('logsModal').classList.add('active');const res=await fetch(`/bot/api/process/${name}/logs?lines=200`);const data=await res.json();document.getElementById('logsContent').textContent=data.success?data.output:'ERROR: '+data.error}async function editConfig(path,name){currentConfigPath=path;document.getElementById('configTitle').textContent=`> CONFIG: ${name}`;document.getElementById('configContent').value='LOADING...';document.getElementById('configModal').classList.add('active');const res=await fetch('/bot/api/config/read',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path})});const data=await res.json();if(data.success){document.getElementById('configContent').value=data.content}else{document.getElementById('configContent').value='ERROR: '+data.error}}async function saveConfig(){if(!currentConfigPath)return;const content=document.getElementById('configContent').value;const res=await fetch('/bot/api/config/write',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:currentConfigPath,content})});const data=await res.json();alert(data.success?'SAVED':'ERROR: '+data.error);if(data.success){closeModal('configModal')}}function closeModal(id){document.getElementById(id).classList.remove('active')}document.getElementById('customCmd').addEventListener('keypress',function(e){if(e.key==='Enter'){runCommand()}});refreshProcesses();setInterval(refreshProcesses,5000)</script></body></html>
DASHHTML
}

echo -e "${GREEN}[+] FILES DOWNLOADED${NC}"

echo -e "${CYAN}[3/6] INSTALLING LIGHTWEIGHT PYTHON PACKAGES...${NC}"
pip3 install --no-cache-dir Flask==3.0.0 gunicorn==21.2.0 Werkzeug==3.0.0 >/dev/null 2>&1
echo -e "${GREEN}[+] PACKAGES INSTALLED${NC}"

echo -e "${CYAN}[4/6] CREATING SYSTEMD SERVICE...${NC}"

# Create env file
cat > /etc/pm2-mgr.env << ENVFILE
SECRET_KEY=$(openssl rand -hex 16)
ADMIN_PASSWORD=$ADMIN_PASSWORD
ENVFILE

# Create lightweight systemd service
cat > /etc/systemd/system/pm2-mgr.service << SERVICEEOF
[Unit]
Description=PM2 Manager Lightweight
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
EnvironmentFile=/etc/pm2-mgr.env
ExecStart=/usr/bin/python3 -m gunicorn --bind 127.0.0.1:5000 --workers 1 --threads 2 --timeout 120 --max-requests 1000 --max-requests-jitter 50 app:app
Restart=always
RestartSec=3
StandardOutput=null
StandardError=journal

# Memory limits
MemoryMax=100M
MemoryHigh=80M

[Install]
WantedBy=multi-user.target
SERVICEEOF

echo -e "${GREEN}[+] SERVICE CREATED${NC}"

echo -e "${CYAN}[5/6] CONFIGURING NGINX...${NC}"

NGINX_CONFIG="/etc/nginx/sites-available/$DOMAIN"

if [ -f "$NGINX_CONFIG" ]; then
    echo -e "${YELLOW}[*] UPDATING EXISTING CONFIG${NC}"
    
    # Remove old /bot blocks
    sed -i '/# PM2 Manager/,/^    }/d' $NGINX_CONFIG
    sed -i '/location \/bot/,/^    }/d' $NGINX_CONFIG
    
    # Add new block after error_log or before first location
    if grep -q "error_log" $NGINX_CONFIG; then
        sed -i '/error_log.*\.log;/a\
\
    # PM2 Manager\
    location /bot {\
        proxy_pass http://127.0.0.1:5000;\
        proxy_set_header Host $host;\
        proxy_set_header X-Real-IP $remote_addr;\
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\
        proxy_set_header X-Forwarded-Proto $scheme;\
        proxy_buffering off;\
    }' $NGINX_CONFIG
    else
        sed -i '0,/location \//s//# PM2 Manager\n    location \/bot {\n        proxy_pass http:\/\/127.0.0.1:5000;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n        proxy_buffering off;\n    }\n\n    location \//' $NGINX_CONFIG
    fi
else
    echo -e "${YELLOW}[*] CREATING NEW CONFIG${NC}"
    
    # Generate SSL if needed
    if [ ! -f "/etc/ssl/certs/$DOMAIN-selfsigned.crt" ]; then
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout /etc/ssl/private/$DOMAIN-selfsigned.key \
            -out /etc/ssl/certs/$DOMAIN-selfsigned.crt \
            -subj "/CN=$DOMAIN" >/dev/null 2>&1
    fi
    
    cat > $NGINX_CONFIG << 'NGINXEOF'
server {
    listen [::]:80;
    server_name DOMAIN_PLACEHOLDER;
    return 301 https://$server_name$request_uri;
}

server {
    listen [::]:443 ssl http2;
    server_name DOMAIN_PLACEHOLDER;
    
    ssl_certificate /etc/ssl/certs/DOMAIN_PLACEHOLDER-selfsigned.crt;
    ssl_certificate_key /etc/ssl/private/DOMAIN_PLACEHOLDER-selfsigned.key;
    
    location /bot {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_buffering off;
    }
    
    location / {
        return 404;
    }
}
NGINXEOF
    
    sed -i "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" $NGINX_CONFIG
    ln -sf $NGINX_CONFIG /etc/nginx/sites-enabled/
fi

nginx -t >/dev/null 2>&1 || {
    echo -e "${RED}[!] NGINX CONFIG ERROR${NC}"
    exit 1
}

echo -e "${GREEN}[+] NGINX CONFIGURED${NC}"

echo -e "${CYAN}[6/6] STARTING SERVICES...${NC}"

systemctl daemon-reload
systemctl enable pm2-mgr
systemctl start pm2-mgr
systemctl reload nginx

echo -e "\n${GREEN}╔═══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         INSTALLATION COMPLETE         ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════╝${NC}\n"

echo -e "${CYAN}[+] ACCESS URL: ${GREEN}https://$DOMAIN/bot${NC}"
echo -e "${CYAN}[+] ADMIN PASSWORD: ${GREEN}SET${NC}"
echo -e "${CYAN}[+] MEMORY LIMIT: ${GREEN}100MB${NC}"
echo -e "${CYAN}[+] SERVICE STATUS: ${GREEN}ACTIVE${NC}\n"

echo -e "${YELLOW}[*] SERVICE COMMANDS:${NC}"
echo -e "   systemctl status pm2-mgr"
echo -e "   systemctl restart pm2-mgr"
echo -e "   journalctl -u pm2-mgr -f\n"

echo -e "${GREEN}[+] PM2 MANAGER READY!${NC}"
