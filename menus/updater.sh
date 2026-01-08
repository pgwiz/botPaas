#!/usr/bin/env bash
# Provides: ms__update_cmd
# Reads: /etc/ms-server/update.conf

ms__update__load_conf() {
  local conf="/etc/ms-server/update.conf"
  if [[ -f "$conf" ]]; then
    # shellcheck disable=SC1090
    source "$conf" || true
  fi
}

ms__update__need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "⚠️  This command needs root. Try: sudo ms-manager -update ..."
    exit 1
  fi
}

ms__update__download() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "❌ Need curl or wget installed to download updates."
    exit 1
  fi
}

ms__update__backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  cp -a "$f" "$f.backup.$ts"
}

ms__update__ensure_hooks() {
  # Re-apply plugin menu + updater hooks into ms-manager (idempotent)
  local MS="/usr/local/bin/ms-manager"
  local MENUDIR="/usr/local/bin/menus"
  local LIB1="$MENUDIR/plugin_menu.sh"
  local LIB2="$MENUDIR/updater.sh"

  mkdir -p "$MENUDIR"

  # Ensure the ms-manager sources these libs right after the shebang
  if [[ -f "$MS" ]]; then
    if ! grep -q "/usr/local/bin/menus/plugin_menu.sh" "$MS"; then
      local tmp
      tmp="$(mktemp)"
      awk 'NR==1{print; print "[ -f /usr/local/bin/menus/plugin_menu.sh ] && source /usr/local/bin/menus/plugin_menu.sh"; next} {print}' \
        "$MS" > "$tmp"
      mv "$tmp" "$MS"
      chmod +x "$MS"
    fi
    if ! grep -q "/usr/local/bin/menus/updater.sh" "$MS"; then
      local tmp2
      tmp2="$(mktemp)"
      awk 'NR==1{print; next} NR==2{print "[ -f /usr/local/bin/menus/updater.sh ] && source /usr/local/bin/menus/updater.sh"; print; next} {print}' \
        "$MS" > "$tmp2"
      mv "$tmp2" "$MS"
      chmod +x "$MS"
    fi

    # Add early CLI handler block if missing
    if ! grep -q "MS_MANAGER_EARLY_HOOKS_BEGIN" "$MS"; then
      local tmp3
      tmp3="$(mktemp)"
      awk 'NR==1{print; next}
NR==2{
print "# MS_MANAGER_EARLY_HOOKS_BEGIN"
print "if [[ \"${1:-}\" == \"-mes\" || \"${1:-}\" == \"--menus\" ]]; then"
print "  command -v ms__plugin_menu_ui >/dev/null 2>&1 || { echo \"❌ menus/plugin_menu.sh missing\"; exit 1; }"
print "  ms__plugin_menu_ui"
print "  exit $?"
print "fi"
print "if [[ \"${1:-}\" == \"-update\" ]]; then"
print "  shift || true"
print "  command -v ms__update_cmd >/dev/null 2>&1 || { echo \"❌ menus/updater.sh missing\"; exit 1; }"
print "  ms__update_cmd \"$@\""
print "  exit $?"
print "fi"
print "# MS_MANAGER_EARLY_HOOKS_END"
print $0
next}
{print}' "$MS" > "$tmp3"
      mv "$tmp3" "$MS"
      chmod +x "$MS"
    fi
  fi
}

ms__update_cmd() {
  ms__update__need_root
  ms__update__load_conf

  local mode="${1:-}"
  local MS="/usr/local/bin/ms-manager"
  local MENUDIR="/usr/local/bin/menus"

  case "$mode" in
    --zip)
      if [[ -z "${PACKAGE_ZIP_URL:-}" ]]; then
        echo "❌ PACKAGE_ZIP_URL not set in /etc/ms-server/update.conf"
        exit 1
      fi
      local tmpzip="/tmp/ms-manager-package.zip"
      local tmpdir="/tmp/ms-manager-package"
      rm -rf "$tmpdir" "$tmpzip"
      echo "⬇️  Downloading package zip..."
      ms__update__download "$PACKAGE_ZIP_URL" "$tmpzip"
      mkdir -p "$tmpdir"
      unzip -oq "$tmpzip" -d "$tmpdir"
      # If installer present, run it; otherwise do a best-effort copy
      local installer
      installer="$(find "$tmpdir" -maxdepth 3 -type f -name "install-ms-manager.sh" | head -n 1 || true)"
      if [[ -n "$installer" ]]; then
        echo "🛠  Running package installer..."
        bash "$installer"
      else
        echo "ℹ️  No install-ms-manager.sh found in zip; copying ms-manager/menus best-effort..."
        if [[ -f "$tmpdir/ms-manager" ]]; then
          ms__update__backup_file "$MS"
          cp -f "$tmpdir/ms-manager" "$MS"
          chmod +x "$MS"
        fi
        if [[ -d "$tmpdir/menus" ]]; then
          mkdir -p "$MENUDIR"
          cp -n "$tmpdir/menus/"*.sh "$MENUDIR/" 2>/dev/null || true
          chmod +x "$MENUDIR/"*.sh 2>/dev/null || true
        fi
      fi
      ms__update__ensure_hooks
      echo "✅ Package update complete."
      ;;
    --zip-menu|--zip-menus|--menus-zip)
      if [[ -z "${MENUS_ZIP_URL:-}" ]]; then
        echo "❌ MENUS_ZIP_URL not set in /etc/ms-server/update.conf"
        exit 1
      fi
      local tmpzip="/tmp/ms-manager-menus.zip"
      local tmpdir="/tmp/ms-manager-menus"
      rm -rf "$tmpdir" "$tmpzip"
      echo "⬇️  Downloading menus zip..."
      ms__update__download "$MENUS_ZIP_URL" "$tmpzip"
      mkdir -p "$tmpdir"
      unzip -oq "$tmpzip" -d "$tmpdir"
      mkdir -p "$MENUDIR"
      # copy without deleting existing
      if [[ -d "$tmpdir/menus" ]]; then
        cp -n "$tmpdir/menus/"*.sh "$MENUDIR/" 2>/dev/null || true
      else
        cp -n "$tmpdir/"*.sh "$MENUDIR/" 2>/dev/null || true
      fi
      chmod +x "$MENUDIR/"*.sh 2>/dev/null || true
      ms__update__ensure_hooks
      echo "✅ Menus update complete (no deletes)."
      ;;
    ""|--ms|--script)
      if [[ -z "${MS_MANAGER_URL:-}" ]]; then
        echo "❌ MS_MANAGER_URL not set in /etc/ms-server/update.conf"
        exit 1
      fi
      echo "⬇️  Downloading ms-manager..."
      local tmp="/tmp/ms-manager.new"
      ms__update__download "$MS_MANAGER_URL" "$tmp"
      ms__update__backup_file "$MS"
      cp -f "$tmp" "$MS"
      chmod +x "$MS"
      ms__update__ensure_hooks
      echo "✅ ms-manager updated."
      ;;
    *)
      echo "Usage:"
      echo "  ms-manager -update              # update ms-manager only (MS_MANAGER_URL)"
      echo "  ms-manager -update --zip        # update full package (PACKAGE_ZIP_URL)"
      echo "  ms-manager -update --zip-menu   # update menus only (MENUS_ZIP_URL)"
      exit 2
      ;;
  esac
}
