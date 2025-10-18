#!/bin/bash

# Bot PaaS Manager Setup Script
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     Bot PaaS Manager Installation     ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}\n"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root (use sudo)${NC}"
    exit 1
fi

# Get domain
read -p "Enter your domain (e.g., servx.pgwiz.us.kg): " DOMAIN
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Domain cannot be empty${NC}"
    exit 1
fi

# Set admin password
read -sp "Set admin password: " ADMIN_PASSWORD
echo
read -sp "Confirm admin password: " ADMIN_PASSWORD_CONFIRM
echo

if [ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]; then
    echo -e "${RED}Passwords do not match${NC}"
    exit 1
fi

echo -e "\n${GREEN}[1/6] Installing Python and dependencies...${NC}"
apt update
apt install -y python3 python3-pip python3-venv nginx

echo -e "${GREEN}[2/6] Creating application directory...${NC}"
APP_DIR="/opt/bot-paas"
mkdir -p $APP_DIR
cd $APP_DIR

# Create virtual environment
python3 -m venv venv
source venv/bin/activate

# Install Flask
pip install flask gunicorn

echo -e "${GREEN}[3/6] Creating application files...${NC}"

# Download app.py from the first artifact or paste it here
# For now, we'll create a simple download mechanism
wget -O app.py https://raw.githubusercontent.com/pgwiz/botPaas/main/app.py 2>/dev/null || \
cat > app.py << 'APPPY'
from flask import Flask, render_template, request, jsonify, session, redirect, url_for
import os
import subprocess
import json
import secrets
from functools import wraps
from pathlib import Path

app = Flask(__name__)
app.secret_key = os.environ.get('SECRET_KEY', secrets.token_hex(32))

BOTS_DIR = Path.home() / 'bots'
BOTS_DIR.mkdir(exist_ok=True)

def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'authenticated' not in session:
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

def run_command(cmd, cwd=None):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd, timeout=300)
        return {'success': result.returncode == 0, 'output': result.stdout, 'error': result.stderr}
    except Exception as e:
        return {'success': False, 'error': str(e)}

def check_requirements():
    requirements = {
        'git': run_command('which git')['success'],
        'node': run_command('which node')['success'],
        'npm': run_command('which npm')['success'],
        'yarn': run_command('which yarn')['success'],
        'pm2': run_command('which pm2')['success'],
        'ffmpeg': run_command('which ffmpeg')['success']
    }
    return requirements

def install_requirements():
    commands = [
        'sudo apt update && sudo apt upgrade -y',
        'sudo apt install git ffmpeg curl -y',
        'curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -',
        'sudo apt install nodejs -y',
        'sudo npm install -g yarn',
        'yarn global add pm2'
    ]
    results = []
    for cmd in commands:
        result = run_command(cmd)
        results.append(result)
        if not result['success']:
            return {'success': False, 'results': results}
    return {'success': True, 'results': results}

@app.route('/')
def index():
    if 'authenticated' not in session:
        return redirect(url_for('login'))
    return redirect(url_for('dashboard'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        password = request.form.get('password')
        stored_password = os.environ.get('ADMIN_PASSWORD', 'admin')
        if password == stored_password:
            session['authenticated'] = True
            return redirect(url_for('dashboard'))
        return render_template('login.html', error='Invalid password')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.clear()
    return redirect(url_for('login'))

@app.route('/dashboard')
@login_required
def dashboard():
    return render_template('dashboard.html')

@app.route('/api/requirements/check')
@login_required
def check_req():
    return jsonify(check_requirements())

@app.route('/api/requirements/install', methods=['POST'])
@login_required
def install_req():
    result = install_requirements()
    return jsonify(result)

@app.route('/api/bots')
@login_required
def list_bots():
    bots = []
    for bot_dir in BOTS_DIR.iterdir():
        if bot_dir.is_dir():
            config_file = bot_dir / 'config.env'
            bots.append({'name': bot_dir.name, 'path': str(bot_dir), 'has_config': config_file.exists()})
    return jsonify(bots)

@app.route('/api/bots/create', methods=['POST'])
@login_required
def create_bot():
    data = request.json
    bot_name = data.get('name')
    repo_url = data.get('repo', 'https://github.com/lyfe00011/levanter')
    if not bot_name:
        return jsonify({'success': False, 'error': 'Bot name is required'})
    bot_path = BOTS_DIR / bot_name
    if bot_path.exists():
        return jsonify({'success': False, 'error': 'Bot already exists'})
    result = run_command(f'git clone {repo_url} {bot_name}', cwd=BOTS_DIR)
    if not result['success']:
        return jsonify(result)
    result = run_command('yarn install', cwd=bot_path)
    if not result['success']:
        return jsonify(result)
    default_config = """SESSION_ID=your_session_id_here
PREFIX=.
STICKER_PACKNAME=LyFE
ALWAYS_ONLINE=false
RMBG_KEY=null
LANGUAG=en
BOT_LANG=en
WARN_LIMIT=3
FORCE_LOGOUT=false
BRAINSHOP=159501,6pq8dPiYt7PdqHz3
MAX_UPLOAD=200
REJECT_CALL=false
SUDO=989876543210
TZ=Asia/Kolkata
VPS=true
AUTO_STATUS_VIEW=true
SEND_READ=true
AJOIN=true
DISABLE_START_MESSAGE=false
PERSONAL_MESSAGE=null"""
    config_file = bot_path / 'config.env'
    config_file.write_text(default_config)
    return jsonify({'success': True, 'message': f'Bot {bot_name} created successfully'})

@app.route('/api/bots/<bot_name>/config', methods=['GET', 'POST'])
@login_required
def bot_config(bot_name):
    bot_path = BOTS_DIR / bot_name
    config_file = bot_path / 'config.env'
    if not bot_path.exists():
        return jsonify({'success': False, 'error': 'Bot not found'})
    if request.method == 'GET':
        if config_file.exists():
            content = config_file.read_text()
            return jsonify({'success': True, 'config': content})
        return jsonify({'success': False, 'error': 'Config file not found'})
    if request.method == 'POST':
        config_content = request.json.get('config')
        config_file.write_text(config_content)
        return jsonify({'success': True, 'message': 'Config saved successfully'})

@app.route('/api/bots/<bot_name>/start', methods=['POST'])
@login_required
def start_bot(bot_name):
    bot_path = BOTS_DIR / bot_name
    if not bot_path.exists():
        return jsonify({'success': False, 'error': 'Bot not found'})
    result = run_command(f'pm2 start . --name {bot_name}', cwd=bot_path)
    return jsonify(result)

@app.route('/api/bots/<bot_name>/stop', methods=['POST'])
@login_required
def stop_bot(bot_name):
    result = run_command(f'pm2 stop {bot_name}')
    return jsonify(result)

@app.route('/api/bots/<bot_name>/restart', methods=['POST'])
@login_required
def restart_bot(bot_name):
    result = run_command(f'pm2 restart {bot_name}')
    return jsonify(result)

@app.route('/api/bots/<bot_name>/delete', methods=['POST'])
@login_required
def delete_bot(bot_name):
    bot_path = BOTS_DIR / bot_name
    run_command(f'pm2 delete {bot_name}')
    if bot_path.exists():
        run_command(f'rm -rf {bot_path}')
        return jsonify({'success': True, 'message': f'Bot {bot_name} deleted'})
    return jsonify({'success': False, 'error': 'Bot not found'})

@app.route('/api/bots/<bot_name>/logs')
@login_required
def bot_logs(bot_name):
    lines = request.args.get('lines', 100)
    result = run_command(f'pm2 logs {bot_name} --lines {lines} --nostream')
    return jsonify(result)

@app.route('/api/pm2/list')
@login_required
def pm2_list():
    result = run_command('pm2 jlist')
    if result['success']:
        try:
            processes = json.loads(result['output'])
            return jsonify({'success': True, 'processes': processes})
        except:
            return jsonify({'success': False, 'error': 'Failed to parse PM2 output'})
    return jsonify(result)

@app.route('/api/pm2/command', methods=['POST'])
@login_required
def pm2_command():
    command = request.json.get('command')
    if not command:
        return jsonify({'success': False, 'error': 'Command is required'})
    if not command.startswith('pm2'):
        command = f'pm2 {command}'
    result = run_command(command)
    return jsonify(result)

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000, debug=False)
APPPY

# Create templates directory
mkdir -p templates

# Create login.html
cat > templates/login.html << 'LOGINHTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Bot PaaS - Login</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .login-container {
            background: white;
            padding: 40px;
            border-radius: 20px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            width: 100%;
            max-width: 400px;
        }
        h1 {
            color: #667eea;
            margin-bottom: 30px;
            text-align: center;
            font-size: 28px;
        }
        .input-group {
            margin-bottom: 20px;
        }
        label {
            display: block;
            margin-bottom: 8px;
            color: #333;
            font-weight: 500;
        }
        input {
            width: 100%;
            padding: 12px;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            font-size: 16px;
            transition: border 0.3s;
        }
        input:focus {
            outline: none;
            border-color: #667eea;
        }
        button {
            width: 100%;
            padding: 14px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            border-radius: 8px;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            transition: transform 0.2s;
        }
        button:hover {
            transform: translateY(-2px);
        }
        .error {
            background: #fee;
            color: #c33;
            padding: 12px;
            border-radius: 8px;
            margin-bottom: 20px;
            border-left: 4px solid #c33;
        }
        .logo {
            text-align: center;
            font-size: 48px;
            margin-bottom: 20px;
        }
    </style>
</head>
<body>
    <div class="login-container">
        <div class="logo">🤖</div>
        <h1>Bot PaaS Manager</h1>
        {% if error %}
        <div class="error">{{ error }}</div>
        {% endif %}
        <form method="POST">
            <div class="input-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" required autofocus>
            </div>
            <button type="submit">Login</button>
        </form>
    </div>
</body>
</html>
LOGINHTML

# Create dashboard.html
cat > templates/dashboard.html << 'DASHHTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Bot PaaS - Dashboard</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #f5f7fa;
        }
        .navbar {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px 40px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        .navbar h1 { font-size: 24px; }
        .navbar a {
            color: white;
            text-decoration: none;
            padding: 8px 16px;
            border-radius: 6px;
            background: rgba(255,255,255,0.2);
            transition: background 0.3s;
        }
        .navbar a:hover { background: rgba(255,255,255,0.3); }
        .container {
            max-width: 1400px;
            margin: 40px auto;
            padding: 0 20px;
        }
        .card {
            background: white;
            border-radius: 12px;
            padding: 30px;
            margin-bottom: 30px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }
        .card h2 {
            color: #333;
            margin-bottom: 20px;
            font-size: 22px;
        }
        .btn {
            padding: 10px 20px;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            font-size: 14px;
            font-weight: 600;
            transition: all 0.3s;
            margin-right: 10px;
        }
        .btn-primary {
            background: #667eea;
            color: white;
        }
        .btn-primary:hover { background: #5568d3; }
        .btn-success {
            background: #48bb78;
            color: white;
        }
        .btn-success:hover { background: #38a169; }
        .btn-danger {
            background: #f56565;
            color: white;
        }
        .btn-danger:hover { background: #e53e3e; }
        .btn-warning {
            background: #ed8936;
            color: white;
        }
        .btn-warning:hover { background: #dd6b20; }
        .bot-list {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 20px;
        }
        .bot-card {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 20px;
            border-radius: 12px;
            box-shadow: 0 4px 12px rgba(0,0,0,0.15);
        }
        .bot-card h3 { margin-bottom: 15px; }
        .bot-actions {
            display: flex;
            gap: 8px;
            margin-top: 15px;
            flex-wrap: wrap;
        }
        .bot-actions button {
            flex: 1;
            min-width: 70px;
            padding: 8px;
            font-size: 12px;
        }
        .modal {
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: rgba(0,0,0,0.5);
            z-index: 1000;
            align-items: center;
            justify-content: center;
        }
        .modal.active { display: flex; }
        .modal-content {
            background: white;
            padding: 30px;
            border-radius: 12px;
            width: 90%;
            max-width: 600px;
            max-height: 80vh;
            overflow-y: auto;
        }
        .modal-content h2 {
            margin-bottom: 20px;
            color: #333;
        }
        .form-group {
            margin-bottom: 20px;
        }
        .form-group label {
            display: block;
            margin-bottom: 8px;
            color: #555;
            font-weight: 500;
        }
        .form-group input, .form-group textarea {
            width: 100%;
            padding: 10px;
            border: 2px solid #e0e0e0;
            border-radius: 6px;
            font-size: 14px;
        }
        .form-group textarea {
            font-family: 'Courier New', monospace;
            min-height: 300px;
        }
        .requirements {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 15px;
        }
        .req-item {
            padding: 15px;
            border-radius: 8px;
            text-align: center;
            font-weight: 600;
        }
        .req-item.installed {
            background: #c6f6d5;
            color: #22543d;
        }
        .req-item.missing {
            background: #fed7d7;
            color: #742a2a;
        }
        .pm2-list {
            overflow-x: auto;
        }
        table {
            width: 100%;
            border-collapse: collapse;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #e0e0e0;
        }
        th {
            background: #f7fafc;
            font-weight: 600;
            color: #2d3748;
        }
        .status-online { color: #48bb78; font-weight: 600; }
        .status-offline { color: #f56565; font-weight: 600; }
        pre {
            background: #1a202c;
            color: #48bb78;
            padding: 20px;
            border-radius: 8px;
            overflow-x: auto;
            font-size: 13px;
            line-height: 1.6;
        }
        .loading {
            text-align: center;
            padding: 40px;
            color: #667eea;
        }
    </style>
</head>
<body>
    <div class="navbar">
        <h1>🤖 Bot PaaS Manager</h1>
        <a href="/logout">Logout</a>
    </div>

    <div class="container">
        <!-- Requirements Check -->
        <div class="card">
            <h2>System Requirements</h2>
            <div id="requirements" class="requirements">
                <div class="loading">Checking...</div>
            </div>
            <button id="installReq" class="btn btn-primary" style="margin-top: 20px; display: none;">
                Install Missing Requirements
            </button>
        </div>

        <!-- Bot Management -->
        <div class="card">
            <h2>Your Bots</h2>
            <button class="btn btn-primary" onclick="showCreateBot()">+ Create New Bot</button>
            <div id="botList" class="bot-list" style="margin-top: 20px;">
                <div class="loading">Loading bots...</div>
            </div>
        </div>

        <!-- PM2 Status -->
        <div class="card">
            <h2>PM2 Process Manager</h2>
            <button class="btn btn-primary" onclick="refreshPM2()">Refresh</button>
            <button class="btn btn-warning" onclick="showCustomCommand()">Custom Command</button>
            <div id="pm2List" class="pm2-list" style="margin-top: 20px;">
                <div class="loading">Loading processes...</div>
            </div>
        </div>
    </div>

    <!-- Create Bot Modal -->
    <div id="createBotModal" class="modal">
        <div class="modal-content">
            <h2>Create New Bot</h2>
            <div class="form-group">
                <label>Bot Name</label>
                <input type="text" id="botName" placeholder="my-awesome-bot">
            </div>
            <div class="form-group">
                <label>Repository URL</label>
                <input type="text" id="repoUrl" value="https://github.com/lyfe00011/levanter">
            </div>
            <button class="btn btn-success" onclick="createBot()">Create</button>
            <button class="btn btn-danger" onclick="closeModal('createBotModal')">Cancel</button>
        </div>
    </div>

    <!-- Edit Config Modal -->
    <div id="configModal" class="modal">
        <div class="modal-content">
            <h2 id="configTitle">Edit Config</h2>
            <div class="form-group">
                <label>config.env</label>
                <textarea id="configContent"></textarea>
            </div>
            <button class="btn btn-success" onclick="saveConfig()">Save</button>
            <button class="btn btn-danger" onclick="closeModal('configModal')">Cancel</button>
        </div>
    </div>

    <!-- Logs Modal -->
    <div id="logsModal" class="modal">
        <div class="modal-content">
            <h2 id="logsTitle">Bot Logs</h2>
            <pre id="logsContent"></pre>
            <button class="btn btn-danger" onclick="closeModal('logsModal')">Close</button>
        </div>
    </div>

    <!-- Custom Command Modal -->
    <div id="commandModal" class="modal">
        <div class="modal-content">
            <h2>Run Custom PM2 Command</h2>
            <div class="form-group">
                <label>Command (e.g., "list", "save", "monit")</label>
                <input type="text" id="customCommand" placeholder="list">
            </div>
            <pre id="commandOutput" style="display: none;"></pre>
            <button class="btn btn-success" onclick="runCustomCommand()">Run</button>
            <button class="btn btn-danger" onclick="closeModal('commandModal')">Close</button>
        </div>
    </div>

    <script>
        let currentBot = null;

        // Load requirements
        async function loadRequirements() {
            const res = await fetch('/api/requirements/check');
            const data = await res.json();
            const container = document.getElementById('requirements');
            container.innerHTML = '';
            
            let allInstalled = true;
            for (const [name, installed] of Object.entries(data)) {
                const div = document.createElement('div');
                div.className = `req-item ${installed ? 'installed' : 'missing'}`;
                div.innerHTML = `${name}<br>${installed ? '✓' : '✗'}`;
                container.appendChild(div);
                if (!installed) allInstalled = false;
            }
            
            document.getElementById('installReq').style.display = allInstalled ? 'none' : 'inline-block';
        }

        // Install requirements
        document.getElementById('installReq')?.addEventListener('click', async function() {
            this.disabled = true;
            this.textContent = 'Installing...';
            const res = await fetch('/api/requirements/install', { method: 'POST' });
            const data = await res.json();
            if (data.success) {
                alert('Requirements installed successfully!');
                loadRequirements();
            } else {
                alert('Installation failed. Check console for details.');
            }
            this.disabled = false;
            this.textContent = 'Install Missing Requirements';
        });

        // Load bots
        async function loadBots() {
            const res = await fetch('/api/bots');
            const bots = await res.json();
            const container = document.getElementById('botList');
            
            if (bots.length === 0) {
                container.innerHTML = '<p style="text-align: center; color: #999; padding: 40px;">No bots created yet. Create your first bot!</p>';
                return;
            }
            
            container.innerHTML = '';
            bots.forEach(bot => {
                const card = document.createElement('div');
                card.className = 'bot-card';
                card.innerHTML = `
                    <h3>${bot.name}</h3>
                    <p style="font-size: 12px; opacity: 0.9;">📁 ${bot.path}</p>
                    <div class="bot-actions">
                        <button class="btn btn-success" onclick="startBot('${bot.name}')">▶ Start</button>
                        <button class="btn btn-warning" onclick="restartBot('${bot.name}')">🔄 Restart</button>
                        <button class="btn btn-danger" onclick="stopBot('${bot.name}')">⏸ Stop</button>
                        <button class="btn btn-primary" onclick="editConfig('${bot.name}')">⚙️ Config</button>
                        <button class="btn btn-primary" onclick="viewLogs('${bot.name}')">📋 Logs</button>
                        <button class="btn btn-danger" onclick="deleteBot('${bot.name}')">🗑️ Delete</button>
                    </div>
                `;
                container.appendChild(card);
            });
        }

        // Modal functions
        function showCreateBot() {
            document.getElementById('createBotModal').classList.add('active');
        }

        function closeModal(id) {
            document.getElementById(id).classList.remove('active');
        }

        async function createBot() {
            const name = document.getElementById('botName').value;
            const repo = document.getElementById('repoUrl').value;
            
            if (!name) {
                alert('Please enter a bot name');
                return;
            }
            
            const res = await fetch('/api/bots/create', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ name, repo })
            });
            
            const data = await res.json();
            if (data.success) {
                alert('Bot created successfully!');
                closeModal('createBotModal');
                loadBots();
            } else {
                alert('Error: ' + data.error);
            }
        }

        async function editConfig(botName) {
            currentBot = botName;
            const res = await fetch(`/api/bots/${botName}/config`);
            const data = await res.json();
            
            if (data.success) {
                document.getElementById('configTitle').textContent = `Edit Config - ${botName}`;
                document.getElementById('configContent').value = data.config;
                document.getElementById('configModal').classList.add('active');
            } else {
                alert('Error loading config: ' + data.error);
            }
        }

        async function saveConfig() {
            const config = document.getElementById('configContent').value;
            const res = await fetch(`/api/bots/${currentBot}/config`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ config })
            });
            
            const data = await res.json();
            if (data.success) {
                alert('Config saved!');
                closeModal('configModal');
            } else {
                alert('Error: ' + data.error);
            }
        }

        async function startBot(name) {
            const res = await fetch(`/api/bots/${name}/start`, { method: 'POST' });
            const data = await res.json();
            alert(data.success ? 'Bot started!' : 'Error: ' + data.error);
            refreshPM2();
        }

        async function stopBot(name) {
            const res = await fetch(`/api/bots/${name}/stop`, { method: 'POST' });
            const data = await res.json();
            alert(data.success ? 'Bot stopped!' : 'Error: ' + data.error);
            refreshPM2();
        }

        async function restartBot(name) {
            const res = await fetch(`/api/bots/${name}/restart`, { method: 'POST' });
            const data = await res.json();
            alert(data.success ? 'Bot restarted!' : 'Error: ' + data.error);
            refreshPM2();
        }

        async function deleteBot(name) {
            if (!confirm(`Delete bot "${name}"? This cannot be undone!`)) return;
            
            const res = await fetch(`/api/bots/${name}/delete`, { method: 'POST' });
            const data = await res.json();
            if (data.success) {
                alert('Bot deleted!');
                loadBots();
                refreshPM2();
            } else {
                alert('Error: ' + data.error);
            }
        }

        async function viewLogs(name) {
            currentBot = name;
            document.getElementById('logsTitle').textContent = `Logs - ${name}`;
            document.getElementById('logsContent').textContent = 'Loading...';
            document.getElementById('logsModal').classList.add('active');
            
            const res = await fetch(`/api/bots/${name}/logs`);
            const data = await res.json();
            document.getElementById('logsContent').textContent = data.success ? data.output : data.error;
        }

        async function refreshPM2() {
            const container = document.getElementById('pm2List');
            container.innerHTML = '<div class="loading">Loading...</div>';
            
            const res = await fetch('/api/pm2/list');
            const data = await res.json();
            
            if (!data.success || data.processes.length === 0) {
                container.innerHTML = '<p style="text-align: center; color: #999; padding: 40px;">No PM2 processes running</p>';
                return;
            }
            
            let html = '<table><thead><tr><th>Name</th><th>Status</th><th>CPU</th><th>Memory</th><th>Uptime</th><th>Restarts</th></tr></thead><tbody>';
            
            data.processes.forEach(proc => {
                const status = proc.pm2_env.status === 'online' ? 'online' : 'offline';
                const uptime = proc.pm2_env.pm_uptime ? Math.floor((Date.now() - proc.pm2_env.pm_uptime) / 1000 / 60) + 'm' : '-';
                html += `
                    <tr>
                        <td><strong>${proc.name}</strong></td>
                        <td class="status-${status}">${status.toUpperCase()}</td>
                        <td>${proc.monit?.cpu || 0}%</td>
                        <td>${Math.round((proc.monit?.memory || 0) / 1024 / 1024)}MB</td>
                        <td>${uptime}</td>
                        <td>${proc.pm2_env.restart_time || 0}</td>
                    </tr>
                `;
            });
            
            html += '</tbody></table>';
            container.innerHTML = html;
        }

        function showCustomCommand() {
            document.getElementById('commandOutput').style.display = 'none';
            document.getElementById('commandModal').classList.add('active');
        }

        async function runCustomCommand() {
            const cmd = document.getElementById('customCommand').value;
            if (!cmd) return;
            
            const output = document.getElementById('commandOutput');
            output.style.display = 'block';
            output.textContent = 'Running...';
            
            const res = await fetch('/api/pm2/command', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ command: cmd })
            });
            
            const data = await res.json();
            output.textContent = data.success ? data.output : data.error;
        }

        // Initialize
        loadRequirements();
        loadBots();
        refreshPM2();

        // Auto-refresh PM2 every 5 seconds
        setInterval(refreshPM2, 5000);
    </script>
</body>
</html>
DASHHTML

echo -e "${GREEN}[4/6] Creating systemd service...${NC}"

# Create environment file
cat > /etc/bot-paas.env << ENVFILE
SECRET_KEY=$(openssl rand -hex 32)
ADMIN_PASSWORD=$ADMIN_PASSWORD
ENVFILE

# Create systemd service
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
ExecStart=$APP_DIR/venv/bin/gunicorn --bind 127.0.0.1:5000 --workers 2 app:app
Restart=always

[Install]
WantedBy=multi-user.target
SERVICEEOF

echo -e "${GREEN}[5/6] Configuring Nginx...${NC}"

# Create Nginx configuration
cat > /etc/nginx/sites-available/bot-paas << NGINXEOF
server {
    listen [::]:80;
    server_name $DOMAIN;

    location /bot {
        rewrite ^/bot(/.*)$ \$1 break;
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /bot/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF

# Enable site
ln -sf /etc/nginx/sites-available/bot-paas /etc/nginx/sites-enabled/

# Test Nginx
nginx -t

echo -e "${GREEN}[6/6] Starting services...${NC}"

# Reload systemd
systemctl daemon-reload

# Start and enable bot-paas service
systemctl start bot-paas
systemctl enable bot-paas

# Restart Nginx
systemctl restart nginx

echo -e "\n${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}Installation Complete!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}\n"

echo -e "${YELLOW}Access your Bot PaaS Manager at:${NC}"
echo -e "${BLUE}https://$DOMAIN/bot${NC}\n"

echo -e "${YELLOW}Login Credentials:${NC}"
echo -e "Password: ${GREEN}[the password you set]${NC}\n"

echo -e "${YELLOW}Service Management:${NC}"
echo -e "Start:   ${BLUE}systemctl start bot-paas${NC}"
echo -e "Stop:    ${BLUE}systemctl stop bot-paas${NC}"
echo -e "Restart: ${BLUE}systemctl restart bot-paas${NC}"
echo -e "Status:  ${BLUE}systemctl status bot-paas${NC}"
echo -e "Logs:    ${BLUE}journalctl -u bot-paas -f${NC}\n"

echo -e "${YELLOW}Bots Directory:${NC} ${BLUE}$HOME/bots${NC}\n"

echo -e "${GREEN}Happy bot hosting! 🤖${NC}\n"
