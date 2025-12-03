#!/usr/bin/env bash
#
# ms-python-app-manager.sh
# Terminal-based Python Gunicorn app manager + nginx/apache /bot proxy
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
  # usage: hash_password "cleartext-password"
  local pw="${1:-}"
  if [ -z "$pw" ]; then
    return 1
  fi

  python3 - "$pw" <<'PY'
import sys, os, hashlib, base64
pw = sys.argv[1]
iters = 200000
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha256', pw.encode(), salt, iters)
salt_b64 = base64.b64encode(salt).decode()
dk_b64 = base64.b64encode(dk).decode()
print(f"pbkdf2_sha256${iters}${salt_b64}${dk_b64}")
PY
}

verify_password() {
  # usage: verify_password "cleartext-password" "stored-hash"
  local pw="${1:-}"
  local hash_str="${2:-}"
  if [ -z "$pw" ] || [ -z "$hash_str" ]; then
    echo "0"
    return 0
  fi

  python3 - "$hash_str" "$pw" <<'PY'
import sys,hashlib,base64
hash_str = sys.argv[1]
pw = sys.argv[2]
try:
    algo, iterations, salt_b64, dk_b64 = hash_str.split('$')
    iterations = int(iterations)
    salt = base64.b64decode(salt_b64)
    dk_stored = base64.b64decode(dk_b64)
    dk = hashlib.pbkdf2_hmac('sha256', pw.encode(), salt, iterations)
    print('1' if dk == dk_stored else '0')
except Exception:
    print('0')
PY
}

# safe save_config (avoid heredoc expansion issues)
save_config() {
  # Pass values as argv to avoid any heredoc expansion pitfalls
  python3 - "$CONFIG_FILE" "$admin_password_hash" "$python_path" "$app_dir" "$app_module" "$app_port" "$run_as_user" <<'PY'
import json,sys
cfg = {
  "admin_password_hash": sys.argv[2],
  "python_path": sys.argv[3],
  "app_dir": sys.argv[4],
  "app_module": sys.argv[5],
  "app_port": sys.argv[6],
  "run_as_user": sys.argv[7]
}
with open(sys.argv[1],"w") as f:
    json.dump(cfg,f)
PY
  chmod 600 "$CONFIG_FILE"
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

# Smart reverse-proxy installer: chooses nginx or apache and configures /bot -> 127.0.0.1:<app_port>/

# Find HTTPS server blocks in nginx config files and print: filepath|block_index|server_names
_find_nginx_https_blocks() {
  local file
  # candidate files
  local -a files=(/etc/nginx/sites-available/* /etc/nginx/sites-enabled/* /etc/nginx/conf.d/* /etc/nginx/nginx.conf)
  for file in "${files[@]}"; do
    [ -f "$file" ] || continue
    awk '
    BEGIN { in=0; brace=0; server_count=0; is_https=0; names="" }
    FNR==1 { server_count=0; }
    /^[[:space:]]*server[[:space:]]*\{/ {
      in=1
      open = gsub(/\{/, "{")
      close = gsub(/\}/, "}")
      brace = open - close
      server_count++
      is_https = 0
      names = ""
      next
    }
    in==1 {
      # mark as https if listen contains 443 or mentions ssl
      if ($0 ~ /listen/ && ($0 ~ /443/ || $0 ~ /ssl/)) is_https=1
      if ($0 ~ /ssl/) is_https=1
      if ($0 ~ /server_name/) {
        s=$0
        sub(/.*server_name[[:space:]]+/, "", s)
        sub(/;.*/, "", s)
        gsub(/^[ \t]+|[ \t]+$/, "", s)
        if (names == "") names = s; else names = names " " s
      }
      open = gsub(/\{/, "{")
      close = gsub(/\}/, "}")
      brace += open - close
      if (brace <= 0) {
        if (is_https) {
          if (names == "") names = "-"
          print FILENAME "|" server_count "|" names
        }
        in = 0
        brace = 0
        is_https = 0
        names = ""
      }
      next
    }
    END { }
    ' "$file"
  done
}

# Insert /bot location blocks into the given file's Nth https server block (1-based)
_insert_bot_into_nginx_block() {
  local file="$1"; local target_block="$2"; local port="$3"
  local tmp backup
  tmp="$(mktemp /tmp/nginx-msbot.XXXXXX)" || return 1
  backup="${file}.bak.$(date +%s)"
  cp -a "$file" "$backup"

  # Conservative existence check for any /bot location (covers = /bot and /bot/)
  if grep -qE 'location[[:space:]]*(=)?[[:space:]]*/bot' "$file"; then
    echo "⚠ This file already contains a location for /bot. Skipping insertion unless you confirm."
    read -r -p "Overwrite existing /bot block in $file? (yes/no) [no]: " ok
    ok=${ok:-no}
    if [[ ! "$ok" =~ ^(yes|y)$ ]]; then
      echo "Skipping insertion."
      rm -f "$tmp"
      return 2
    fi
  fi

  awk -v target="$target_block" -v app_port="$port" '
  BEGIN { server_count=0; in=0; brace=0; is_https=0; }
  /^[[:space:]]*server[[:space:]]*\{/ {
    in=1
    open = gsub(/\{/, "{")
    close = gsub(/\}/, "}")
    brace = open - close
    server_count++
    is_https=0
    print $0
    next
  }
  in==1 {
    # detect https listen or ssl
    if ($0 ~ /listen/ && ($0 ~ /443/ || $0 ~ /ssl/)) is_https=1
    if ($0 ~ /ssl/) is_https=1

    # calculate how this line changes brace depth
    open = gsub(/\{/, "{")
    close = gsub(/\}/, "}")
    new_brace = brace + open - close

    # If this line closes the server block (new_brace <= 0), we should insert before printing it
    if (new_brace <= 0) {
      if (is_https && server_count == target) {
        print ""
        print "    # Inserted by ms-python-app-manager: /bot proxy"
        print "    location = /bot {"
        print "        return 301 /bot/;"
        print "    }"
        print ""
        print "    location /bot/ {"
        print "        proxy_pass http://127.0.0.1:" app_port "/;"
        print "        proxy_set_header Host \\$host;"
        print "        proxy_set_header X-Real-IP \\$remote_addr;"
        print "        proxy_set_header X-Forwarded-For \\$proxy_add_x_forwarded_for;"
        print "        proxy_set_header X-Forwarded-Proto \\$scheme;"
        print "        proxy_redirect off;"
        print "    }"
        print ""
      }
      print $0
      in=0
      brace=0
      is_https=0
      next
    } else {
      # just print the line and update brace
      print $0
      brace = new_brace
      next
    }
  }
  {
    print $0
  }
  ' "$file" > "$tmp"

  # Move new file into place then test nginx config
  mv "$tmp" "$file"
  chmod 644 "$file"

  if ! nginx -t >/dev/null 2>&1; then
    echo "⚠ nginx test failed AFTER modification. Restoring backup and showing test output."
    mv "$backup" "$file"
    nginx -t || true
    return 3
  fi

  # If test OK, reload nginx
  if systemctl reload nginx >/dev/null 2>&1; then
    ok "Inserted /bot into $file (server block #$target) and reloaded nginx"
    rm -f "$backup" || true
    return 0
  else
    echo "⚠ nginx reload failed after modification; restoring backup."
    mv "$backup" "$file"
    nginx -t || true
    return 4
  fi
}

# New create_reverse_proxy(): offers to insert into existing HTTPS vhost or create a new vhost
create_reverse_proxy() {
  # find nginx first
  local nginx_bin
  nginx_bin="$(command -v nginx || true)"
  if [ -z "$nginx_bin" ]; then
    echo "nginx not found on the host. Please install nginx or use the Apache option in the main menu."
    return 1
  fi

  echo "Scanning nginx configs for HTTPS (listen 443 / ssl) server blocks..."
  mapfile -t found < <(_find_nginx_https_blocks 2>/dev/null || true)

  if [ "${#found[@]}" -eq 0 ]; then
    echo "No HTTPS vhosts found. I can create a catch-all vhost for /bot, or you can create one manually."
    read -r -p "Create a new catch-all /bot vhost now? (yes/no) [yes]: " create_now
    create_now=${create_now:-yes}
    if [[ "$create_now" =~ ^(yes|y)$ ]]; then
      cat > "$NGINX_SITE" <<NGCONF
server {
    listen 80;
    server_name _;

    # Force /bot -> /bot/
    location = /bot {
        return 301 /bot/;
    }

    location /bot/ {
        proxy_pass http://127.0.0.1:${app_port}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }

    client_max_body_size 20M;
}
NGCONF
      ln -sf "$NGINX_SITE" "$NGINX_SITE_ENABLED" 2>/dev/null || true
      nginx -t >/dev/null 2>&1 || { err "nginx config test failed; inspect $NGINX_SITE"; return 1; }
      systemctl reload nginx || ok "nginx reloaded"
      ok "Created catch-all /bot vhost in $NGINX_SITE"
      return 0
    else
      echo "Skipping proxy setup."
      return 1
    fi
  fi

  # We have found HTTPS blocks — present them to user
  echo ""
  echo "Discovered HTTPS vhosts:"
  local i=0
  local entry file block names
  for entry in "${found[@]}"; do
    ((i++))
    file="${entry%%|*}"
    rest="${entry#*|}"
    block="${rest%%|*}"
    names="${rest#*|}"
    printf "  %2d) %s    (%s)    file: %s\n" "$i" "$names" "block#${block}" "$file"
  done
  echo "  X) Create new catch-all vhost instead"
  echo ""

  # ask user to choose
  while true; do
    read -r -p "Select a vhost to insert /bot into (1-${#found[@]}) or X to create new: " sel
    sel=${sel:-}
    if [[ "$sel" =~ ^[Xx]$ ]]; then
      # create new catch-all (same as above)
      cat > "$NGINX_SITE" <<NGCONF
server {
    listen 80;
    server_name _;

    # Force /bot -> /bot/
    location = /bot {
        return 301 /bot/;
    }

    location /bot/ {
        proxy_pass http://127.0.0.1:${app_port}/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
    }

    client_max_body_size 20M;
}
NGCONF
      ln -sf "$NGINX_SITE" "$NGINX_SITE_ENABLED" 2>/dev/null || true
      nginx -t >/dev/null 2>&1 || { err "nginx config test failed; inspect $NGINX_SITE"; return 1; }
      systemctl reload nginx || ok "nginx reloaded"
      ok "Created catch-all /bot vhost in $NGINX_SITE"
      return 0
    fi

    if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#found[@]}" ]; then
      local chosen="${found[$((sel-1))]}"
      local chosen_file="${chosen%%|*}"
      local tmp="${chosen#*|}"
      local chosen_block="${tmp%%|*}"
      echo "You chose: file=$chosen_file, server-block#=$chosen_block"
      read -r -p "Insert /bot into that server block? (yes/no) [yes]: " confirm
      confirm=${confirm:-yes}
      if [[ "$confirm" =~ ^(yes|y)$ ]]; then
        _insert_bot_into_nginx_block "$chosen_file" "$chosen_block" "$app_port"
        return $?
      else
        echo "Cancelled. Choose again or press Ctrl+C to exit."
      fi
    else
      echo "Invalid selection."
    fi
  done
}


uninstall_all() {
  echo "This will stop and remove the systemd service, webserver site, venv, and config."
  read -r -p "Are you sure? Type UNINSTALL to proceed: " confirm
  if [ "$confirm" != "UNINSTALL" ]; then
    echo "Cancelled."
    return
  fi

  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reload || true

  # try to remove nginx/apache artifacts
  rm -f "$NGINX_SITE" "$NGINX_SITE_ENABLED"
  if command -v nginx >/dev/null 2>&1; then systemctl reload nginx || true; fi
  if command -v apache2ctl >/dev/null 2>&1 || command -v apachectl >/dev/null 2>&1 || command -v httpd >/dev/null 2>&1; then
    # don't attempt to remove apache vhost blindly if user used a custom name
    rm -f /etc/apache2/sites-available/ms-gunicorn.conf /etc/httpd/conf.d/ms-gunicorn.conf || true
    if command -v apache2ctl >/dev/null 2>&1; then systemctl reload apache2 || true; fi
    if command -v httpd >/dev/null 2>&1; then systemctl reload httpd || true; fi
  fi

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
  echo "  5) Configure webserver proxy for /bot (nginx or apache)"
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
      read -r -p "Python interpreter [${python_path:-$DEFAULT_PYTHON}]: " tpy
      tpy=${tpy:-${python_path:-$DEFAULT_PYTHON}}
      python_path="$tpy"

      read -r -p "App working directory [${app_dir:-/root/ms}]: " tad
      tad=${tad:-${app_dir:-/root/ms}}
      app_dir="$tad"

      read -r -p "App module (e.g. myapp:app) [${app_module:-myapp:app}]: " tm
      tm=${tm:-${app_module:-myapp:app}}
      app_module="$tm"

      read -r -p "App port [${app_port:-8000}]: " tp
      tp=${tp:-${app_port:-8000}}
      app_port="$tp"

      read -r -p "Run service as user [${run_as_user:-root}]: " ru
      ru=${ru:-${run_as_user:-root}}
      run_as_user="$ru"

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
      read -r -p "Python interpreter [${python_path:-$DEFAULT_PYTHON}]: " tpy
      tpy=${tpy:-${python_path:-$DEFAULT_PYTHON}}
      python_path="$tpy"

      read -r -p "App working directory [${app_dir:-/root/ms}]: " tad
      tad=${tad:-${app_dir:-/root/ms}}
      app_dir="$tad"

      read -r -p "App module [${app_module:-myapp:app}]: " tm
      tm=${tm:-${app_module:-myapp:app}}
      app_module="$tm"

      read -r -p "App port [${app_port:-8000}]: " tp
      tp=${tp:-${app_port:-8000}}
      app_port="$tp"

      read -r -p "Run service as user [${run_as_user:-root}]: " ru
      ru=${ru:-${run_as_user:-root}}
      run_as_user="$ru"
      
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
      create_reverse_proxy
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
