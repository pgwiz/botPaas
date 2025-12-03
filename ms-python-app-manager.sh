#!/usr/bin/env bash
#
# ms-python-app-manager.sh
# Terminal-based Python Gunicorn app manager + nginx /bot proxy
#
# Usage: sudo /usr/local/bin/ms-python-app-manager.sh
#
set -u

CONFIG_DIR="/etc/ms-server"
CONFIG_FILE="$CONFIG_DIR/python-app-config.json"
SERVICE_NAME="ms-gunicorn.service"
NGINX_SITE="/etc/nginx/sites-available/ms-gunicorn"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/ms-gunicorn"
DEFAULT_PYTHON="$(command -v python3 || echo /usr/bin/python3)"

mkdir -p "$CONFIG_DIR"
touch "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# ---------- helpers ----------
err() { echo "✗ $*" >&2; }
ok()  { echo "✓ $*"; }

pause() {
  echo
  read -r -p "Press Enter to continue..."
}

json_read() {
  python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null
import json,sys
try:
    with open(sys.argv[1]) as f:
        data=json.load(f)
        print(json.dumps(data))
except Exception:
    print("{}")
PY
}

hash_password() {
  # uses pbkdf2_hmac sha256, 200000 iterations, salt base64
  local pw="$1"
  python3 - <<PY
import sys,os,hashlib,base64
pw = sys.stdin.read().strip()
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha256', pw.encode(), salt, 200000)
print('pbkdf2_sha256$200000$' + base64.b64encode(salt).decode() + '$' + base64.b64encode(dk).decode())
PY
}

verify_password() {
  local pw="$1"; local hash="$2"
  python3 - <<PY
import sys,hashlib,base64
pw=sys.stdin.read().strip()
hash_str=sys.argv[1]
try:
    algo,iterations,salt_b64,dk_b64 = hash_str.split('$')
    salt=base64.b64decode(salt_b64)
    dk_stored=base64.b64decode(dk_b64)
    dk=hashlib.pbkdf2_hmac('sha256', pw.encode(), salt, int(iterations))
    print('1' if dk==dk_stored else '0')
except Exception:
    print('0')
PY
}

load_config() {
  if [ -s "$CONFIG_FILE" ]; then
    eval "$(python3 - <<PY
import json,sys
data={}
try:
  with open(sys.argv[1]) as f: data=json.load(f)
except Exception: pass
for k,v in data.items():
  # print shell-safe assignment
  print("%s=%r" % (k, v))
PY
 "$CONFIG_FILE")"
  else
    # defaults
    admin_password_hash=""
    python_path="$DEFAULT_PYTHON"
    app_dir="/root/ms"
    app_module="myapp:app"
    app_port="8000"
    run_as_user="root"
  fi
}

save_config() {
  python3 - <<PY
import json,sys
d = {
  "admin_password_hash": "$admin_password_hash",
  "python_path": "$python_path",
  "app_dir": "$app_dir",
  "app_module": "$app_module",
  "app_port": "$app_port",
  "run_as_user": "$run_as_user"
}
with open("$CONFIG_FILE","w") as f:
    json.dump(d,f)
PY
  chmod 600 "$CONFIG_FILE"
}

ensure_python() {
  if [ ! -x "$python_path" ]; then
    err "Python interpreter $python_path not found/executable."
    return 1
  fi
  return 0
}

create_system_user_if_needed() {
  if [ "$run_as_user" != "root" ]; then
    if ! id -u "$run_as_user" >/dev/null 2>&1; then
      read -r -p "User $run_as_user doesn't exist. Create it as system user? (yes/no) [no]: " c
      c=${c:-no}
      if [ "$c" = "yes" ] || [ "$c" = "y" ]; then
        useradd --system --create-home --shell /usr/sbin/nologin "$run_as_user" || { err "failed to create user"; return 1; }
        ok "Created user $run_as_user"
      else
        err "User missing; aborting."
        return 1
      fi
    fi
  fi
  return 0
}

create_venv_and_install() {
  VENV="$app_dir/venv"
  mkdir -p "$app_dir"
  chown -R "${run_as_user:-root}":"${run_as_user:-root}" "$app_dir" 2>/dev/null || true
  if ! "$python_path" -m venv "$VENV"; then
    err "Failed to create venv at $VENV"
    return 1
  fi
  PIP_BIN="$VENV/bin/pip"
  if [ -x "$PIP_BIN" ]; then
    "$PIP_BIN" install --upgrade pip >/dev/null 2>&1 || true
    ok "Installing gunicorn into venv..."
    "$PIP_BIN" install gunicorn >/dev/null 2>&1 || err "gunicorn install finished (may have warnings)."
  else
    err "pip not found in venv. You may need to bootstrap ensurepip."
    return 1
  fi

  if [ -f "$app_dir/requirements.txt" ]; then
    read -r -p "requirements.txt found in $app_dir. Install into venv? (yes/no) [yes]: " ir
    ir=${ir:-yes}
    if [ "$ir" = "yes" ] || [ "$ir" = "y" ]; then
      "$PIP_BIN" install -r "$app_dir/requirements.txt" || err "requirements install returned nonzero"
    fi
  fi
  ok "Venv ready: $VENV"
  return 0
}

write_env_file() {
  local envfile="$CONFIG_DIR/gunicorn_app.env"
  echo "# Environment for ms-gunicorn app" > "$envfile"
  chmod 640 "$envfile"
  chown root:root "$envfile"
  echo "Wrote $envfile"
}

create_systemd_service() {
  local venv="$app_dir/venv"
  local gun="$venv/bin/gunicorn"
  if [ ! -x "$gun" ]; then
    err "gunicorn not found at $gun"
  fi

  cat > "/etc/systemd/system/$SERVICE_NAME" <<UNIT
[Unit]
Description=MS Gunicorn App
After=network.target

[Service]
Type=simple
WorkingDirectory=${app_dir}
EnvironmentFile=${CONFIG_DIR}/gunicorn_app.env
ExecStart=${gun} -w 2 -b 127.0.0.1:${app_port} ${app_module}
Restart=always
RestartSec=3
User=${run_as_user:-root}
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNIT

  chmod 644 "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reload || true
  systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  ok "Systemd unit created and started (or enabled) as $SERVICE_NAME"
}

create_nginx_proxy() {
  # Make a minimal /bot proxy that expects other nginx sites — if no nginx, offer to install
  if ! command -v nginx >/dev/null 2>&1; then
    read -r -p "nginx is not installed. Install nginx now? (apt/yum will be used) (yes/no) [no]: " doinstall
    doinstall=${doinstall:-no}
    if [ "$doinstall" = "yes" ] || [ "$doinstall" = "y" ]; then
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y nginx
      elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release && yum install -y nginx
      else
        err "No package manager detected. Install nginx manually."
        return 1
      fi
      ok "nginx installed (attempting)."
    else
      err "Skipping nginx setup."
      return 1
    fi
  fi

  # Write nginx site that proxies /bot to the gunicorn service
  cat > "$NGINX_SITE" <<'NGCONF'
server {
    listen 80;
    server_name _;

    # Force /bot -> /bot/
    location = /bot {
        return 301 /bot/;
    }

    # Proxy /bot/ to the local gunicorn
    location /bot/ {
        proxy_pass http://127.0.0.1:__APP_PORT__/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }
}
NGCONF

  # Replace placeholder
  sed -i "s|__APP_PORT__|${app_port}|g" "$NGINX_SITE"

  ln -sf "$NGINX_SITE" "$NGINX_SITE_ENABLED" 2>/dev/null || true
  # remove default site if conflicting (optional)
  if [ -f /etc/nginx/sites-enabled/default ]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  nginx -t >/dev/null 2>&1 || { err "nginx config test failed; fix configuration before reloading."; return 1; }
  systemctl reload nginx || ok "nginx reloaded"
  ok "nginx configured: /bot -> 127.0.0.1:${app_port}"
  return 0
}

uninstall_all() {
  echo "This will stop and remove the systemd service, nginx site, venv, and config."
  read -r -p "Are you sure? Type UNINSTALL to proceed: " confirm
  if [ "$confirm" != "UNINSTALL" ]; then
    echo "Cancelled."
    return
  fi

  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reload || true
  rm -f "$NGINX_SITE" "$NGINX_SITE_ENABLED"
  if command -v nginx >/dev/null 2>&1; then systemctl reload nginx || true; fi

  if [ -n "$app_dir" ] && [ -d "$app_dir" ]; then
    read -r -p "Delete app directory $app_dir (including venv)? (yes/no) [no]: " del
    del=${del:-no}
    if [ "$del" = "yes" ] || [ "$del" = "y" ]; then
      rm -rf "$app_dir"
      ok "Deleted $app_dir"
    fi
  fi

  rm -f "$CONFIG_FILE" "${CONFIG_DIR}/gunicorn_app.env"
  ok "Uninstalled."
}

change_password() {
  echo -n "Enter new ADMIN password: "
  read -s new1; echo
  echo -n "Confirm new ADMIN password: "
  read -s new2; echo
  if [ "$new1" != "$new2" ]; then
    err "Passwords did not match."
    return 1
  fi
  newhash=$(hash_password "$new1")
  admin_password_hash="$newhash"
  save_config
  ok "Admin password updated."
}

show_status() {
  echo "Service: $SERVICE_NAME"
  systemctl status "$SERVICE_NAME" --no-pager || true
  echo
  if [ -f "${CONFIG_DIR}/gunicorn_app.env" ]; then
    echo "Env file: ${CONFIG_DIR}/gunicorn_app.env"
    sed -n '1,200p' "${CONFIG_DIR}/gunicorn_app.env"
  fi
}

# ---------- menu actions ----------
load_config

while true; do
  clear
  echo "================================="
  echo " MS Python App Manager (CLI)"
  echo "================================="
  echo
  echo "Current config:"
  echo "  Python:    ${python_path:-$DEFAULT_PYTHON}"
  echo "  App dir:   ${app_dir:-/root/ms}"
  echo "  Module:    ${app_module:-myapp:app}"
  echo "  Port:      ${app_port:-8000}"
  echo "  Run as:    ${run_as_user:-root}"
  echo
  echo "Menu:"
  echo "  1) Initialize / Create App (venv + gunicorn + service)"
  echo "  2) Edit basic config (python, app dir, module, port, run-as-user)"
  echo "  3) Edit environment variables (writes ${CONFIG_DIR}/gunicorn_app.env)"
  echo "  4) Create/Update systemd service (ms-gunicorn.service)"
  echo "  5) Configure nginx proxy for /bot (proxied to 127.0.0.1:port)"
  echo "  6) Start service"
  echo "  7) Stop service"
  echo "  8) Restart service"
  echo "  9) Show service status & logs"
  echo " 10) Change admin password"
  echo " 11) Uninstall / Remove"
  echo " 12) Exit"
  echo
  read -r -p "Choose an option: " opt

  case "$opt" in
    1)
      # run all: create user, venv, write env file, create service
      read -r -p "Run interactive setup now (create venv, install gunicorn, create service)? (yes/no) [yes]: " runit
      runit=${runit:-yes}
      if [ "$runit" != "yes" ] && [ "$runit" != "y" ]; then
        echo "Setup cancelled."
        pause
        continue
      fi
      # admin password
      if [ -z "${admin_password_hash:-}" ]; then
        echo -n "Enter ADMIN password (no-echo): "
        read -s pw1; echo
        echo -n "Confirm ADMIN password: "
        read -s pw2; echo
        if [ "$pw1" != "$pw2" ]; then err "Password mismatch"; pause; continue; fi
        admin_password_hash="$(hash_password "$pw1")"
      fi
      # ask for python, app dir, module, port, run user
      read -r -p "Python interpreter [$python_path]: " tpy; tpy=${tpy:-$python_path}
      python_path="$tpy"
      read -r -p "App working directory [$app_dir]: " tad; tad=${tad:-$app_dir}; app_dir="$tad"
      read -r -p "App module (e.g. myapp:app) [$app_module]: " tm; tm=${tm:-$app_module}; app_module="$tm"
      read -r -p "App port [$app_port]: " tp; tp=${tp:-$app_port}; app_port="$tp"
      read -r -p "Run service as user [${run_as_user:-root}]: " ru; ru=${ru:-$run_as_user}; run_as_user="$ru"

      save_config

      ensure_python || pause
      create_system_user_if_needed || pause
      create_venv_and_install || pause
      write_env_file
      create_systemd_service
      pause
      ;;
    2)
      echo "Edit basic settings."
      read -r -p "Python interpreter [$python_path]: " tpy; tpy=${tpy:-$python_path}; python_path="$tpy"
      read -r -p "App working directory [$app_dir]: " tad; tad=${tad:-$app_dir}; app_dir="$tad"
      read -r -p "App module [$app_module]: " tm; tm=${tm:-$app_module}; app_module="$tm"
      read -r -p "App port [$app_port]: " tp; tp=${tp:-$app_port}; app_port="$tp"
      read -r -p "Run service as user [$run_as_user]: " ru; ru=${ru:-$run_as_user}; run_as_user="$ru"
      save_config
      ok "Saved."
      pause
      ;;
    3)
      echo "Editing environment variables for the app."
      echo "Current env file: ${CONFIG_DIR}/gunicorn_app.env"
      echo "Enter new env lines (KEY=VALUE). End with an empty line."
      tmpfile="$(mktemp)"
      echo "# Environment for ms-gunicorn app" > "$tmpfile"
      while true; do
        read -r ev
        [ -z "$ev" ] && break
        if [[ "$ev" != *=* ]]; then
          echo "Ignoring invalid line (no =): $ev"
          continue
        fi
        echo "$ev" >> "$tmpfile"
      done
      mv "$tmpfile" "${CONFIG_DIR}/gunicorn_app.env"
      chmod 640 "${CONFIG_DIR}/gunicorn_app.env"
      chown root:root "${CONFIG_DIR}/gunicorn_app.env"
      ok "Saved env file."
      pause
      ;;
    4)
      create_systemd_service
      pause
      ;;
    5)
      create_nginx_proxy
      pause
      ;;
    6)
      systemctl start "$SERVICE_NAME" || err "Failed to start service"
      ok "Started (or attempted start). See logs with option 9."
      pause
      ;;
    7)
      systemctl stop "$SERVICE_NAME" || err "Failed to stop service (or not running)"
      ok "Stopped (or attempted stop)."
      pause
      ;;
    8)
      systemctl restart "$SERVICE_NAME" || err "Restart returned non-zero"
      ok "Restarted"
      pause
      ;;
    9)
      show_status
      echo
      read -r -p "Show last 200 lines of journal? (yes/no) [yes]: " sj; sj=${sj:-yes}
      if [ "$sj" = "yes" ] || [ "$sj" = "y" ]; then
        journalctl -u "$SERVICE_NAME" -n 200 --no-pager || true
      fi
      pause
      ;;
    10)
      change_password
      pause
      ;;
    11)
      uninstall_all
      pause
      ;;
    12)
      echo "Bye."
      exit 0
      ;;
    *)
      echo "Invalid option."
      pause
      ;;
  esac
done
