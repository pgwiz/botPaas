#!/usr/bin/env bash
# ms-manager updater helper
# Enables:
#   ms-manager -update                 (update ms-manager only)
#   ms-manager -update --zip           (update full package from zip)
#   ms-manager -update --zip-menu      (update menus only from zip)
# Optional:
#   --url <URL> (override config)

ms__update_conf_file="/etc/ms-server/update.conf"

ms__update__usage() {
  cat <<'EOF'
ms-manager updater

Usage:
  ms-manager -update
  ms-manager -update --zip
  ms-manager -update --zip-menu

Options:
  --url <URL>     Override the configured URL for this update run

Config file:
  /etc/ms-server/update.conf

Expected variables in update.conf:
  MS_MANAGER_URL="https://.../ms-manager"
  PACKAGE_ZIP_URL="https://.../ms-manager-package.zip"
  MENUS_ZIP_URL="https://.../menus-only.zip"
EOF
}

ms__update__need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "⚠️  Update requires root. Run with: sudo ms-manager -update ..."
    exit 1
  fi
}

ms__update__load_conf() {
  if [[ ! -f "$ms__update_conf_file" ]]; then
    mkdir -p /etc/ms-server
    cat > "$ms__update_conf_file" <<'EOF'
# ms-manager update sources
MS_MANAGER_URL=""
PACKAGE_ZIP_URL=""
MENUS_ZIP_URL=""
EOF
  fi
  # shellcheck disable=SC1090
  source "$ms__update_conf_file" 2>/dev/null || true
  : "${MS_MANAGER_URL:=}"
  : "${PACKAGE_ZIP_URL:=}"
  : "${MENUS_ZIP_URL:=}"
}

ms__update__download() {
  local url="$1"
  local out="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
    return $?
  fi
  echo "❌ Neither curl nor wget found."
  return 1
}

ms__update__ensure_unzip() {
  if command -v unzip >/dev/null 2>&1; then
    return 0
  fi
  echo "ℹ️  unzip not found. Trying to install..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y unzip
    return $?
  fi
  if command -v yum >/dev/null 2>&1; then
    yum install -y unzip
    return $?
  fi
  echo "❌ Please install 'unzip' and retry."
  return 1
}

ms__update__backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    cp -a "$f" "${f}.bak.${ts}"
  fi
}

ms__update__ensure_sources() {
  # Ensure ms-manager sources plugin_menu + updater right after shebang
  local ms="/usr/local/bin/ms-manager"
  [[ -f "$ms" ]] || return 0
  if grep -q "menus/plugin_menu.sh" "$ms" && grep -q "menus/updater.sh" "$ms"; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  awk 'NR==1{print; print "[ -f /usr/local/bin/menus/plugin_menu.sh ] && source /usr/local/bin/menus/plugin_menu.sh"; print "[ -f /usr/local/bin/menus/updater.sh ] && source /usr/local/bin/menus/updater.sh"; next} {print}'     "$ms" > "$tmp"
  mv "$tmp" "$ms"
  chmod +x "$ms"
}

ms__update__copy_menus_from_dir() {
  local src="$1"
  local dest="/usr/local/bin/menus"
  mkdir -p "$dest"
  # Copy scripts, preserve existing ref.sh if src doesn't provide it
  cp -a "$src"/. "$dest"/
  chmod +x "$dest"/*.sh 2>/dev/null || true
}

ms__update__find_first() {
  # find first match under directory
  local dir="$1"
  local pat="$2"
  find "$dir" -type f -name "$pat" -print | head -n 1
}

ms__update__update_from_zip() {
  local url="$1"
  ms__update__need_root
  ms__update__ensure_unzip

  local tmpzip tmpdir
  tmpzip="$(mktemp --suffix=.zip)"
  tmpdir="$(mktemp -d)"

  echo "⬇️  Downloading package zip..."
  ms__update__download "$url" "$tmpzip"

  echo "📦 Extracting..."
  unzip -qq "$tmpzip" -d "$tmpdir"

  # If the zip includes an installer, run it
  local installer
  installer="$(ms__update__find_first "$tmpdir" "install-ms-manager.sh")"
  if [[ -n "$installer" ]]; then
    echo "▶ Running installer from zip: $installer"
    chmod +x "$installer" 2>/dev/null || true
    bash "$installer"
  else
    echo "ℹ️  No installer found in zip. Trying direct file copy..."
    local ms
    ms="$(ms__update__find_first "$tmpdir" "ms-manager")"
    if [[ -n "$ms" ]]; then
      ms__update__backup_file "/usr/local/bin/ms-manager"
      install -m 755 "$ms" /usr/local/bin/ms-manager
    fi
    local menus
    menus="$(find "$tmpdir" -type d -name "menus" -print | head -n 1)"
    if [[ -n "$menus" ]]; then
      ms__update__copy_menus_from_dir "$menus"
    fi
  fi

  ms__update__ensure_sources

  rm -f "$tmpzip"
  rm -rf "$tmpdir"
  echo "✅ Update (--zip) complete."
}

ms__update__update_menus_from_zip() {
  local url="$1"
  ms__update__need_root
  ms__update__ensure_unzip

  local tmpzip tmpdir
  tmpzip="$(mktemp --suffix=.zip)"
  tmpdir="$(mktemp -d)"

  echo "⬇️  Downloading menus zip..."
  ms__update__download "$url" "$tmpzip"

  echo "📦 Extracting..."
  unzip -qq "$tmpzip" -d "$tmpdir"

  local menus
  menus="$(find "$tmpdir" -type d -name "menus" -print | head -n 1)"
  if [[ -z "$menus" ]]; then
    echo "❌ Zip doesn't contain a 'menus/' directory."
    rm -f "$tmpzip"; rm -rf "$tmpdir"
    exit 1
  fi

  ms__update__copy_menus_from_dir "$menus"
  ms__update__ensure_sources

  rm -f "$tmpzip"
  rm -rf "$tmpdir"
  echo "✅ Update (--zip-menu) complete."
}

ms__update__update_ms_only() {
  local url="$1"
  ms__update__need_root

  local tmp
  tmp="$(mktemp)"
  echo "⬇️  Downloading ms-manager..."
  ms__update__download "$url" "$tmp"

  # sanity: ensure it looks like a shell script
  if ! head -n 1 "$tmp" | grep -qE '^#!.*/(ba)?sh'; then
    echo "❌ Download doesn't look like a shell script (missing shebang)."
    rm -f "$tmp"
    exit 1
  fi

  ms__update__backup_file "/usr/local/bin/ms-manager"
  install -m 755 "$tmp" /usr/local/bin/ms-manager
  rm -f "$tmp"

  ms__update__ensure_sources
  echo "✅ Update (ms-manager only) complete."
}

ms__update_dispatch() {
  ms__update__load_conf

  local mode="ms"
  local url_override=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        ms__update__usage
        return 0
        ;;
      --zip)
        mode="zip"
        shift
        ;;
      --zip-menu)
        mode="zip-menu"
        shift
        ;;
      --url)
        url_override="${2:-}"
        shift 2
        ;;
      *)
        echo "❌ Unknown update option: $1"
        ms__update__usage
        return 1
        ;;
    esac
  done

  case "$mode" in
    zip)
      local url="${url_override:-$PACKAGE_ZIP_URL}"
      if [[ -z "$url" ]]; then
        echo "❌ PACKAGE_ZIP_URL is empty. Set it in $ms__update_conf_file or use --url."
        return 1
      fi
      ms__update__update_from_zip "$url"
      ;;
    zip-menu)
      local url="${url_override:-$MENUS_ZIP_URL}"
      if [[ -z "$url" ]]; then
        echo "❌ MENUS_ZIP_URL is empty. Set it in $ms__update_conf_file or use --url."
        return 1
      fi
      ms__update__update_menus_from_zip "$url"
      ;;
    ms)
      local url="${url_override:-$MS_MANAGER_URL}"
      if [[ -z "$url" ]]; then
        # fallback: if PACKAGE_ZIP_URL set, use it to update ms-manager via zip
        if [[ -n "$PACKAGE_ZIP_URL" ]]; then
          ms__update__update_from_zip "$PACKAGE_ZIP_URL"
          return 0
        fi
        echo "❌ MS_MANAGER_URL is empty. Set it in $ms__update_conf_file or use --url."
        return 1
      fi
      ms__update__update_ms_only "$url"
      ;;
  esac
}

ms__maybe_run_update() {
  if [[ "${1:-}" == "-update" ]]; then
    shift
    ms__update_dispatch "$@"
    exit $?
  fi
}

# If this file is sourced from ms-manager, $@ is ms-manager arguments.
ms__maybe_run_update "$@"
