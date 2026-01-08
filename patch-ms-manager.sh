#!/usr/bin/env bash
set -euo pipefail

MS="/usr/local/bin/ms-manager"
MENUS_LIB="/usr/local/bin/menus/plugin_menu.sh"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/pgwiz/botPaas/refs/heads/main}"
PLUGIN_MENU_URL="$BASE_URL/menus/plugin_menu.sh"
SETUP_FOLLOWUP_URL="$BASE_URL/menus/setup_follow_up.sh"
SETUP_REBOOT_OPS_URL="$BASE_URL/menus/setup_reboot_ops_timer.sh"
PLUGIN_SETUP_URL="$BASE_URL/menus/plugin-setup.sh"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: This patch needs root. Run: sudo bash $0"
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

ensure_menus_lib() {
  if [[ ! -f "$MENUS_LIB" ]]; then
    echo "WARN: $MENUS_LIB missing; attempting download from $PLUGIN_MENU_URL"
    mkdir -p "$(dirname "$MENUS_LIB")"
    if download_url "$PLUGIN_MENU_URL" "$MENUS_LIB"; then
      chmod +x "$MENUS_LIB" 2>/dev/null || true
    else
      echo "ERROR: Failed to download $PLUGIN_MENU_URL"
      exit 1
    fi
  fi
}

move_setup_scripts() {
  local menus_dir="/usr/local/bin/menus"
  local setup_dir="$menus_dir/setups"
  mkdir -p "$setup_dir"

  shopt -s nullglob
  local f base
  for f in "$menus_dir"/setup_*.sh "$menus_dir"/setup-*.sh "$menus_dir"/plugin-setup.sh; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    mv "$f" "$setup_dir/$base"
    chmod +x "$setup_dir/$base" 2>/dev/null || true
  done
  shopt -u nullglob
}

install_setup_scripts() {
  local menus_dir="/usr/local/bin/menus"
  local setup_dir="$menus_dir/setups"
  mkdir -p "$setup_dir"

  download_url "$SETUP_FOLLOWUP_URL" "$setup_dir/setup_follow_up.sh" && chmod +x "$setup_dir/setup_follow_up.sh" 2>/dev/null || true
  download_url "$SETUP_REBOOT_OPS_URL" "$setup_dir/setup_reboot_ops_timer.sh" && chmod +x "$setup_dir/setup_reboot_ops_timer.sh" 2>/dev/null || true
  download_url "$PLUGIN_SETUP_URL" "$setup_dir/plugin-setup.sh" && chmod +x "$setup_dir/plugin-setup.sh" 2>/dev/null || true
}

download_url() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
    return $?
  fi
  echo "ERROR: curl or wget is required to download plugins."
  return 1
}

remove_internal_plugin_ui() {
  if ! grep -q "^ms__ensure_followup_setup_menu()" "$MS"; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  awk '
    BEGIN{skip=0}
    /^ms__ensure_followup_setup_menu\(\)/{skip=1; next}
    skip==1 && /^show_menu\(\)[[:space:]]*\{/ {skip=0; print; next}
    skip==0 {print}
  ' "$MS" > "$tmp"
  mv "$tmp" "$MS"
  chmod +x "$MS"
}

source_plugin_menu() {
  if ! grep -q "$MENUS_LIB" "$MS"; then
    local tmp
    tmp="$(mktemp)"
    awk 'NR==1{print; print "[ -f /usr/local/bin/menus/plugin_menu.sh ] && source /usr/local/bin/menus/plugin_menu.sh"; next} {print}' \
      "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi
}

add_mes_hook() {
  if ! grep -q "MS_MANAGER_EARLY_HOOKS_BEGIN" "$MS"; then
    local tmp
    tmp="$(mktemp)"
    awk 'NR==1{print; next}
NR==2{
print "# MS_MANAGER_EARLY_HOOKS_BEGIN"
print "if [[ \"${1:-}\" == \"-mes\" || \"${1:-}\" == \"--menus\" ]]; then"
print "  command -v ms__plugin_menu_ui >/dev/null 2>&1 || { echo \"ERROR: menus/plugin_menu.sh missing\"; exit 1; }"
print "  ms__plugin_menu_ui"
print "  exit $?"
print "fi"
print "# MS_MANAGER_EARLY_HOOKS_END"
print $0
next}
{print}' "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi
}

add_menu_label_67() {
  if ! grep -q "67) Extra menus" "$MS"; then
    local tmp
    tmp="$(mktemp)"
    awk '
      {
        if ($0 ~ /Update from GitHub/ && inserted==0) {
          print "  67) Extra menus (plugins)"
          inserted=1
        }
        print
      }
    ' "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi
}

add_case_67() {
  if ! grep -qE "^[[:space:]]*67\)" "$MS"; then
    local tmp
    tmp="$(mktemp)"
    awk '
      {
        if ($0 ~ /^[[:space:]]*99\)[[:space:]]/ && inserted==0) {
          print "  67) ms__plugin_menu_ui ;;"
          inserted=1
        }
        print
      }
    ' "$MS" > "$tmp"
    mv "$tmp" "$MS"
    chmod +x "$MS"
  fi
}

main() {
  need_root
  ensure_menus_lib
  if [[ ! -f "$MS" ]]; then
    echo "ERROR: ms-manager not found at $MS"
    exit 1
  fi

  backup_file "$MS"
  move_setup_scripts
  install_setup_scripts
  remove_internal_plugin_ui
  source_plugin_menu
  add_mes_hook
  add_menu_label_67
  add_case_67

  echo "OK: Patched ms-manager"
  echo " -mes / --menus enabled"
  echo " option 67 added (best effort)"
}

main "$@"
