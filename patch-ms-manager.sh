#!/usr/bin/env bash
set -euo pipefail

MS="/usr/local/bin/ms-manager"
MENUS_LIB="/usr/local/bin/menus/plugin_menu.sh"

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
    echo "ERROR: $MENUS_LIB missing."
    echo "Install menus/plugin_menu.sh first, then re-run this patch."
    exit 1
  fi
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
  source_plugin_menu
  add_mes_hook
  add_menu_label_67
  add_case_67

  echo "OK: Patched ms-manager"
  echo " -mes / --menus enabled"
  echo " option 67 added (best effort)"
}

main "$@"
