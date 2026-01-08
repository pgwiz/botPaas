#!/usr/bin/env bash
set -euo pipefail

MENUDIR="/usr/local/bin/menus"
REG="$MENUDIR/ref.sh"
CONF_DIR="/etc/ms-server"
REFS_JSON="$CONF_DIR/menus-refs.json"
DEFAULT_GROUP="default"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "This menu needs root. Run: sudo bash $0"
    exit 1
  fi
}

ensure_registry() {
  mkdir -p "$MENUDIR"
  if [[ ! -f "$REG" ]]; then
    cat > "$REG" <<'EOF'
# ms-manager menus registry
# Format: "scriptFile.sh|Menu title"
MS_MENU_REGISTRY=(
  "templateMenu.sh|Template menu (copy me)"
)
EOF
    chmod 644 "$REG"
  fi
}

ensure_refs_file() {
  mkdir -p "$CONF_DIR"
  if [[ ! -f "$REFS_JSON" ]]; then
    : > "$REFS_JSON"
    chmod 644 "$REFS_JSON"
  fi
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_unescape() {
  printf '%s' "$1" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

registry_upsert() {
  local file="$1"
  local title="$2"

  ensure_registry

  if grep -q "\"$file|\"" "$REG"; then
    awk -v f="$file" -v t="$title" '
      { if ($0 ~ "\"" f "\\|") { print "  \"" f "|" t "\""; next } print }
    ' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
  else
    awk -v f="$file" -v t="$title" '
      /^\)/ && !added { print "  \"" f "|" t "\""; added=1 }
      { print }
    ' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
  fi
  chmod 644 "$REG"
}

registry_remove() {
  local file="$1"
  ensure_registry
  awk -v f="$file" '
    $0 ~ "\"" f "\\|" { next }
    { print }
  ' "$REG" > "$REG.tmp" && mv "$REG.tmp" "$REG"
  chmod 644 "$REG"
}

registry_list() {
  local -a files=()
  local -a titles=()

  ensure_registry
  # shellcheck disable=SC1090
  source "$REG" 2>/dev/null || true

  if declare -p MS_MENU_REGISTRY >/dev/null 2>&1; then
    local entry file title
    for entry in "${MS_MENU_REGISTRY[@]}"; do
      file="${entry%%|*}"
      title="${entry#*|}"
      [[ -z "$file" ]] && continue
      [[ "$title" = "$entry" ]] && title="$file"
      files+=("$file")
      titles+=("$title")
    done
  fi

  local i
  for i in "${!files[@]}"; do
    printf "%2d) %-32s %s\n" "$((i + 1))" "${files[$i]}" "${titles[$i]}"
  done
}

refs_upsert() {
  local file="$1"
  local title="$2"
  local url="$3"
  local group="${4:-$DEFAULT_GROUP}"
  local esc_file esc_title esc_url esc_group

  ensure_refs_file

  esc_file="$(json_escape "$file")"
  esc_title="$(json_escape "$title")"
  esc_url="$(json_escape "$url")"
  esc_group="$(json_escape "$group")"

  local tmp
  tmp="$(mktemp)"
  if [[ -s "$REFS_JSON" ]]; then
    while IFS= read -r line; do
      if echo "$line" | grep -q "\"file\":\"$esc_file\""; then
        continue
      fi
      echo "$line" >> "$tmp"
    done < "$REFS_JSON"
  fi

  printf '{"file":"%s","title":"%s","url":"%s","group":"%s"}\n' "$esc_file" "$esc_title" "$esc_url" "$esc_group" >> "$tmp"
  mv "$tmp" "$REFS_JSON"
  chmod 644 "$REFS_JSON"
}

refs_remove() {
  local file="$1"
  local esc_file

  ensure_refs_file
  esc_file="$(json_escape "$file")"

  local tmp
  tmp="$(mktemp)"
  if [[ -s "$REFS_JSON" ]]; then
    while IFS= read -r line; do
      if echo "$line" | grep -q "\"file\":\"$esc_file\""; then
        continue
      fi
      echo "$line" >> "$tmp"
    done < "$REFS_JSON"
  fi

  mv "$tmp" "$REFS_JSON"
  chmod 644 "$REFS_JSON"
}

refs_list() {
  ensure_refs_file
  if [[ ! -s "$REFS_JSON" ]]; then
    return 0
  fi

  while IFS= read -r line; do
    local file title url group
    file="$(printf '%s' "$line" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')"
    title="$(printf '%s' "$line" | sed -n 's/.*"title":"\([^"]*\)".*/\1/p')"
    url="$(printf '%s' "$line" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')"
    group="$(printf '%s' "$line" | sed -n 's/.*"group":"\([^"]*\)".*/\1/p')"
    [[ -z "$file" || -z "$url" ]] && continue
    if [[ -z "$group" ]]; then
      group="$(json_escape "$DEFAULT_GROUP")"
    fi
    printf "%s|%s|%s|%s\n" "$(json_unescape "$file")" "$(json_unescape "$title")" "$(json_unescape "$url")" "$(json_unescape "$group")"
  done < "$REFS_JSON"
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

add_plugin() {
  local url file title clean default_file

  read -rp "Plugin URL: " url
  if [[ -z "${url:-}" ]]; then
    echo "No URL provided."
    return 1
  fi

  clean="${url%%\?*}"
  default_file="$(basename "$clean")"
  if [[ -z "$default_file" || "$default_file" = "." || "$default_file" = "/" ]]; then
    default_file="menu-plugin.sh"
  fi
  if [[ "$default_file" != *.sh ]]; then
    default_file="${default_file}.sh"
  fi

  read -rp "Save as [$default_file]: " file
  file="${file:-$default_file}"
  if [[ "$file" = *"/"* || "$file" = *"\\"* ]]; then
    echo "Invalid file name: $file"
    return 1
  fi

  read -rp "Menu title [$file]: " title
  title="${title:-$file}"
  read -rp "Group [$DEFAULT_GROUP]: " group
  group="${group:-$DEFAULT_GROUP}"

  mkdir -p "$MENUDIR"
  if download_url "$url" "$MENUDIR/$file"; then
    chmod +x "$MENUDIR/$file" 2>/dev/null || true
    registry_upsert "$file" "$title"
    refs_upsert "$file" "$title" "$url" "$group"
    echo "Added: $file"
  else
    echo "Download failed."
    return 1
  fi
}

update_from_refs() {
  local updated=0
  local missing=0

  while IFS='|' read -r file title url group; do
    [[ -z "$file" || -z "$url" ]] && continue
    echo "Updating: $file"
    if download_url "$url" "$MENUDIR/$file"; then
      chmod +x "$MENUDIR/$file" 2>/dev/null || true
      registry_upsert "$file" "${title:-$file}"
      updated=$((updated + 1))
    else
      echo "Failed: $file"
      missing=$((missing + 1))
    fi
  done < <(refs_list)

  echo "Update done. Updated: $updated, Failed: $missing"
}

update_from_refs_by_group() {
  local group="$1"
  local updated=0
  local missing=0

  while IFS='|' read -r file title url ref_group; do
    [[ -z "$file" || -z "$url" ]] && continue
    [[ "$ref_group" != "$group" ]] && continue
    echo "Updating: $file"
    if download_url "$url" "$MENUDIR/$file"; then
      chmod +x "$MENUDIR/$file" 2>/dev/null || true
      registry_upsert "$file" "${title:-$file}"
      updated=$((updated + 1))
    else
      echo "Failed: $file"
      missing=$((missing + 1))
    fi
  done < <(refs_list)

  echo "Update done. Updated: $updated, Failed: $missing"
}

remove_plugin() {
  local -a files=()
  local -a titles=()

  ensure_registry
  # shellcheck disable=SC1090
  source "$REG" 2>/dev/null || true
  if declare -p MS_MENU_REGISTRY >/dev/null 2>&1; then
    local entry file title
    for entry in "${MS_MENU_REGISTRY[@]}"; do
      file="${entry%%|*}"
      title="${entry#*|}"
      [[ -z "$file" ]] && continue
      [[ "$title" = "$entry" ]] && title="$file"
      files+=("$file")
      titles+=("$title")
    done
  fi

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "No registered plugins."
    return 0
  fi

  local i
  for i in "${!files[@]}"; do
    printf "%2d) %-32s %s\n" "$((i + 1))" "${files[$i]}" "${titles[$i]}"
  done
  echo " 0) Cancel"

  read -rp "Remove which plugin: " pick
  if [[ "$pick" = "0" ]]; then
    return 0
  fi
  if ! [[ "$pick" =~ ^[0-9]+$ ]]; then
    echo "Invalid selection."
    return 1
  fi

  local idx=$((pick - 1))
  if [[ "$idx" -lt 0 || "$idx" -ge "${#files[@]}" ]]; then
    echo "Invalid selection."
    return 1
  fi

  local sel="${files[$idx]}"
  rm -f "$MENUDIR/$sel" 2>/dev/null || true
  registry_remove "$sel"
  refs_remove "$sel"
  echo "Removed: $sel"
}

show_refs() {
  ensure_refs_file
  if [[ ! -s "$REFS_JSON" ]]; then
    echo "No stored plugin refs at $REFS_JSON"
    return 0
  fi

  echo "Stored plugin refs ($REFS_JSON):"
  while IFS='|' read -r file title url group; do
    group="${group:-$DEFAULT_GROUP}"
    printf "- %-28s | %s\n  %s\n  group: %s\n" "$file" "$title" "$url" "$group"
  done < <(refs_list)
}

list_groups() {
  local any=0
  while IFS='|' read -r file title url group; do
    [[ -z "$file" || -z "$url" ]] && continue
    group="${group:-$DEFAULT_GROUP}"
    echo "$group"
    any=1
  done < <(refs_list) | sort -u
  if [[ "$any" -eq 0 ]]; then
    echo "No groups found."
  fi
}

auto_register_new_files() {
  ensure_registry
  local added=0
  local f base
  while IFS= read -r f; do
    base="$(basename "$f")"
    if grep -q "\"$base|\"" "$REG"; then
      continue
    fi
    if [[ "$base" = "ref.sh" ]]; then
      continue
    fi
    registry_upsert "$base" "$base"
    added=$((added + 1))
  done < <(find "$MENUDIR" -maxdepth 1 -type f -name "*.sh" -print | sort)

  echo "Auto-registered: $added"
}

main() {
  need_root
  ensure_registry
  ensure_refs_file

  while true; do
    echo "===================================="
    echo " Plugin Setup"
    echo "===================================="
    echo "  1) List plugins (registry)"
    echo "  2) Add plugin from URL"
    echo "  3) Update plugins from saved refs"
    echo "  4) Update plugins by group"
    echo "  5) Remove plugin"
    echo "  6) Show stored refs"
    echo "  7) List groups"
    echo "  8) Auto-register new files"
    echo "  0) Back"
    echo ""
    read -rp "Choose: " choice
    case "$choice" in
      1) registry_list ;;
      2) add_plugin ;;
      3) update_from_refs ;;
      4)
        read -rp "Group: " group
        group="${group:-$DEFAULT_GROUP}"
        update_from_refs_by_group "$group"
        ;;
      5) remove_plugin ;;
      6) show_refs ;;
      7) list_groups ;;
      8) auto_register_new_files ;;
      0) return 0 ;;
      *) echo "Invalid option." ;;
    esac
    echo ""
    read -rp "Press Enter to continue..." _
    clear 2>/dev/null || true
  done
}

main "$@"
