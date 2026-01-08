#!/usr/bin/env bash
set -euo pipefail

MS="/usr/local/bin/ms-manager"
MENUDIR="/usr/local/bin/menus"
ETCDIR="/etc/ms-server"
CONF="$ETCDIR/update.conf"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "⚠️  This installer needs root. Run: sudo bash $0"
    exit 1
  fi
}

backup_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  cp -a "$f" "$f.backup.$ts"
}

install_menus_libs() {
  mkdir -p "$MENUDIR"
  # These files ship with the installer zip (same folder as this script)
  local SRC_DIR
  SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

  install -m 0755 "$SRC_DIR/menus/plugin_menu.sh" "$MENUDIR/plugin_menu.sh"
  install -m 0755 "$SRC_DIR/menus/updater.sh" "$MENUDIR/updater.sh"

  # Registry + template should not overwrite user customizations
  if [[ ! -f "$MENUDIR/ref.sh" ]]; then
    install -m 0644 "$SRC_DIR/menus/ref.sh" "$MENUDIR/ref.sh"
  fi
  if [[ ! -f "$MENUDIR/templateMenu.sh" ]]; then
    install -m 0755 "$SRC_DIR/menus/templateMenu.sh" "$MENUDIR/templateMenu.sh"
  fi

  # Optional bundled plugins (only create if missing)
  if [[ ! -f "$MENUDIR/setup_follow_up.sh" ]]; then
    install -m 0755 "$SRC_DIR/menus/setup_follow_up.sh" "$MENUDIR/setup_follow_up.sh"
  fi
  if [[ ! -f "$MENUDIR/setup_reboot_ops_timer.sh" ]]; then
    install -m 0755 "$SRC_DIR/menus/setup_reboot_ops_timer.sh" "$MENUDIR/setup_reboot_ops_timer.sh"
  fi
}

ensure_update_conf() {
  mkdir -p "$ETCDIR"
  if [[ ! -f "$CONF" ]]; then
    cat > "$CONF" <<'EOF'
# ms-manager updater config
# Fill these with your own URLs (GitHub Releases, raw file links, etc.)
MS_MANAGER_URL=""
PACKAGE_ZIP_URL=""
MENUS_ZIP_URL=""
EOF
    chmod 0644 "$CONF"
  fi
}

patch_ms_manager() {
  if [[ ! -f "$MS" ]]; then
    echo "❌ ms-manager not found at $MS"
    echo "    Install your base ms-manager first, then re-run this installer to patch it."
    exit 1
  fi

  backup_file "$MS"

  # 1) Source plugin_menu + updater libs early
  if ! grep -q "/usr/local/bin/menus/plugin_menu.sh" "$MS"; then
    tmp="$(mktemp)"
    awk 'NR==1{print; print "[ -f /usr/local/bin/menus/plugin_menu.sh ] && source /usr/local/bin/menus/plugin_menu.sh"; next} {print}' \
      "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi

  if ! grep -q "/usr/local/bin/menus/updater.sh" "$MS"; then
    tmp="$(mktemp)"
    awk 'NR==1{print; next} NR==2{print "[ -f /usr/local/bin/menus/updater.sh ] && source /usr/local/bin/menus/updater.sh"; print; next} {print}' \
      "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi

  # 2) Add early hooks for -mes and -update
  if ! grep -q "MS_MANAGER_EARLY_HOOKS_BEGIN" "$MS"; then
    tmp="$(mktemp)"
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
{print}' "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi

  # 3) Re-add Option 67 in printed menu (best-effort)
  if ! grep -q "67) Extra Menus" "$MS"; then
    tmp="$(mktemp)"
    # First try: insert before the printed "Update from GitHub" line
    awk '
      {
        if ($0 ~ /Update from GitHub/ && inserted_menu==0) {
          print "  67) Extra Menus (plugins)"
          inserted_menu=1
        }
        print
      }
    ' "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi

  # Fallback insert locations if still missing
  if ! grep -q "67) Extra Menus" "$MS"; then
    tmp="$(mktemp)"
    awk '
      {
        if ($0 ~ /Uninstall Service/ && inserted_menu==0) {
          print "  67) Extra Menus (plugins)"
          inserted_menu=1
        }
        print
      }
    ' "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi

  if ! grep -q "67) Extra Menus" "$MS"; then
    tmp="$(mktemp)"
    awk '
      {
        if ($0 ~ /Exit Manager/ && inserted_menu==0) {
          print "  67) Extra Menus (plugins)"
          inserted_menu=1
        }
        print
      }
    ' "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi

  # 4) Re-add case handler for 67) in the main option case statement (best-effort)
  if ! grep -qE "^[[:space:]]*67\)" "$MS"; then
    tmp="$(mktemp)"
    awk '
      {
        if ($0 ~ /^[[:space:]]*91\)[[:space:]]/ && inserted_case==0) {
          print "  67) ms__plugin_menu_ui ;;"
          inserted_case=1
        }
        print
      }
    ' "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi

  if ! grep -qE "^[[:space:]]*67\)" "$MS"; then
    tmp="$(mktemp)"
    awk '
      {
        if ($0 ~ /^[[:space:]]*99\)[[:space:]]/ && inserted_case==0) {
          print "  67) ms__plugin_menu_ui ;;"
          inserted_case=1
        }
        print
      }
    ' "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi

  if ! grep -qE "^[[:space:]]*67\)" "$MS"; then
    tmp="$(mktemp)"
    awk '
      {
        if ($0 ~ /^[[:space:]]*0\)[[:space:]]/ && inserted_case==0) {
          print "  67) ms__plugin_menu_ui ;;"
          inserted_case=1
        }
        print
      }
    ' "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi


  echo "✅ Patched ms-manager:"
  echo "   -mes works"
  echo "   -update works"
  echo "   option 67 restored (best-effort)"
}

main() {
  need_root
  install_menus_libs
  ensure_update_conf
  patch_ms_manager
  echo ""
  echo "Done."
  echo "Try:"
  echo "  ms-manager -mes"
  echo "  ms-manager -update"
}

main "$@"
