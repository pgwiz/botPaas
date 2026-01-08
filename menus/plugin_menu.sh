#!/usr/bin/env bash
# ms-manager plugin menu UI
# Provides: ms__plugin_menu_ui

ms__plugin_menu_ui() {
  local MENUDIR="/usr/local/bin/menus"
  local REG="$MENUDIR/ref.sh"

  mkdir -p "$MENUDIR"

  # Create registry if missing (does NOT overwrite)
  if [[ ! -f "$REG" ]]; then
    cat > "$REG" <<'EOF'
# ms-manager menus registry
# Format: "scriptFile.sh|Menu title"
MS_MENU_REGISTRY=(
  "templateMenu.sh|Template menu (copy me)"
)
EOF
  fi

  # Load registry (don't die if it has minor issues)
  # shellcheck disable=SC1090
  source "$REG" 2>/dev/null || true

  # Build title mapping from registry
  declare -A title_by_file=()
  local entry file title
  for entry in "${MS_MENU_REGISTRY[@]:-}"; do
    file="${entry%%|*}"
    title="${entry#*|}"
    [[ -n "$file" ]] && title_by_file["$file"]="$title"
  done

  # Build list: registered first (in order), then unregistered *.sh
  local -a files=()
  local -a titles=()

  for entry in "${MS_MENU_REGISTRY[@]:-}"; do
    file="${entry%%|*}"
    title="${entry#*|}"
    if [[ -f "$MENUDIR/$file" ]]; then
      files+=("$file")
      titles+=("$title")
    fi
  done

  local f base
  while IFS= read -r f; do
    base="$(basename "$f")"
    if [[ "$base" = "ref.sh" ]]; then
      continue
    fi
    if [[ -z "${title_by_file[$base]+x}" ]]; then
      files+=("$base")
      titles+=("$base (unregistered)")
    fi
  done < <(find "$MENUDIR" -maxdepth 1 -type f -name "*.sh" -print | sort)

  if [[ "${#files[@]}" -eq 0 ]]; then
    echo "INFO: No menu plugins found in $MENUDIR"
    echo "      Put *.sh files there or register them in $REG"
    return 0
  fi

  while true; do
    echo "===================================="
    echo " Extra Menus (plugins)"
    echo " Dir: $MENUDIR"
    echo "===================================="
    local i=1 idx
    for ((idx=0; idx<${#files[@]}; idx++)); do
      printf " %2d) %s\n" "$i" "${titles[$idx]}"
      ((i++))
    done
    echo "  0) Back"

    read -rp "Select plugin: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if [[ "$choice" -eq 0 ]]; then
        return 0
      fi
      if [[ "$choice" -ge 1 && "$choice" -le "${#files[@]}" ]]; then
        local sel="${files[$((choice-1))]}"
        echo ""
        echo "-> Running: $sel"
        echo "------------------------------------"
        chmod +x "$MENUDIR/$sel" 2>/dev/null || true
        bash "$MENUDIR/$sel"
        echo "------------------------------------"
        read -rp "Press Enter to return..." _
        clear 2>/dev/null || true
      fi
    fi
  done
}
