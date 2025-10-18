from flask import Flask, render_template, request, jsonify, session, redirect, url_for
import os, subprocess, json, secrets, signal
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
        # Use Popen for better process control
        import subprocess
        process = subprocess.Popen(
            cmd, 
            shell=True, 
            stdout=subprocess.PIPE, 
            stderr=subprocess.PIPE, 
            text=True, 
            cwd=cwd,
            preexec_fn=None if os.name == 'nt' else os.setsid  # Create new process group
        )
        
        # Wait for completion with timeout
        try:
            stdout, stderr = process.communicate(timeout=30)  # 30 second timeout
            return {'success': process.returncode == 0, 'output': stdout, 'error': stderr}
        except subprocess.TimeoutExpired:
            # Kill the process group to clean up subprocesses
            if os.name != 'nt':
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
            else:
                process.terminate()
            process.wait()
            return {'success': False, 'error': 'COMMAND_TIMEOUT'}
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
    
    # Auto-protect pm2 logs commands
    if 'pm2 logs' in command and '--nostream' not in command:
        if '--lines' not in command:
            command += ' --lines 50'
        command += ' --nostream'
    
    result = run_command(command)
    return jsonify(result)

@app.route(URL_PREFIX + '/api/process/<process_id>/logs')
@login_required
def process_logs(process_id):
    lines = request.args.get('lines', 100)
    # Use --nostream to avoid persistent processes
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
