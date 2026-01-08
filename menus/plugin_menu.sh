#!/usr/bin/env bash
# ms-manager plugin menu UI
# Provides: ms__plugin_menu_ui

ms__plugin_menu_ui() {
  local MENUDIR="/usr/local/bin/menus"
  local SETUPDIR="$MENUDIR/setups"
  local REG="$MENUDIR/ref.sh"

  mkdir -p "$MENUDIR" "$SETUPDIR"

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

  is_setup_name() {
    case "$1" in
      setup_*|setup-*) return 0 ;;
      *) return 1 ;;
    esac
  }

  add_entry() {
    local kind="$1"
    local file="$2"
    local title="$3"
    local path="$4"
    if [[ "$kind" = "setup" ]]; then
      setup_files+=("$file")
      setup_titles+=("$title")
      setup_paths+=("$path")
    else
      main_files+=("$file")
      main_titles+=("$title")
      main_paths+=("$path")
    fi
  }

  # Build title mapping from registry
  declare -A title_by_file=()
  local entry file title
  for entry in "${MS_MENU_REGISTRY[@]:-}"; do
    file="${entry%%|*}"
    title="${entry#*|}"
    [[ -n "$file" ]] && title_by_file["$file"]="$title"
  done

  # Build list: registered first (in order), then unregistered *.sh
  local -a main_files=()
  local -a main_titles=()
  local -a main_paths=()
  local -a setup_files=()
  local -a setup_titles=()
  local -a setup_paths=()

  for entry in "${MS_MENU_REGISTRY[@]:-}"; do
    file="${entry%%|*}"
    title="${entry#*|}"
    local path=""
    if [[ -f "$MENUDIR/$file" ]]; then
      path="$MENUDIR/$file"
    elif [[ -f "$SETUPDIR/$file" ]]; then
      path="$SETUPDIR/$file"
    else
      continue
    fi
    if [[ "$path" == "$SETUPDIR/"* ]] || is_setup_name "$file"; then
      add_entry "setup" "$file" "$title" "$path"
    else
      add_entry "main" "$file" "$title" "$path"
    fi
  done

  local f base
  while IFS= read -r f; do
    base="$(basename "$f")"
    if [[ "$base" = "ref.sh" || "$base" = "plugin_menu.sh" ]]; then
      continue
    fi
    if [[ "$base" = "patch-ms-manager.sh" || "$base" = "ms-manager" ]]; then
      continue
    fi
    if [[ -z "${title_by_file[$base]+x}" ]]; then
      if is_setup_name "$base"; then
        add_entry "setup" "$base" "$base (unregistered)" "$MENUDIR/$base"
      else
        add_entry "main" "$base" "$base (unregistered)" "$MENUDIR/$base"
      fi
    fi
  done < <(find "$MENUDIR" -maxdepth 1 -type f -name "*.sh" -print | sort)

  while IFS= read -r f; do
    base="$(basename "$f")"
    if [[ "$base" = "ref.sh" || "$base" = "plugin_menu.sh" ]]; then
      continue
    fi
    if [[ "$base" = "patch-ms-manager.sh" || "$base" = "ms-manager" ]]; then
      continue
    fi
    if [[ -z "${title_by_file[$base]+x}" ]]; then
      add_entry "setup" "$base" "$base (unregistered)" "$SETUPDIR/$base"
    fi
  done < <(find "$SETUPDIR" -maxdepth 1 -type f -name "*.sh" -print | sort)

  local main_count="${#main_files[@]}"
  local setup_count="${#setup_files[@]}"
  local total=$((main_count + setup_count))
  if [[ "$total" -eq 0 ]]; then
    echo "INFO: No menu plugins found in $MENUDIR"
    echo "      Put *.sh files there or register them in $REG"
    return 0
  fi

  while true; do
    echo "===================================="
    echo " Extra Menus (plugins)"
    echo " Menus:  $MENUDIR"
    echo " Setups: $SETUPDIR"
    echo "===================================="
    local i=1 idx
    if [[ "$main_count" -gt 0 ]]; then
      echo "Main Menus:"
      for ((idx=0; idx<main_count; idx++)); do
        printf " %2d) %s\n" "$i" "${main_titles[$idx]}"
        ((i++))
      done
    fi
    if [[ "$setup_count" -gt 0 ]]; then
      echo "Setup Tools:"
      for ((idx=0; idx<setup_count; idx++)); do
        printf " %2d) %s\n" "$i" "${setup_titles[$idx]}"
        ((i++))
      done
    fi
    echo "  0) Back"

    read -rp "Select plugin: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      if [[ "$choice" -eq 0 ]]; then
        return 0
      fi
      if [[ "$choice" -ge 1 && "$choice" -le "$total" ]]; then
        local sel_path=""
        local sel_name=""
        local idx0=$((choice-1))
        if [[ "$idx0" -lt "$main_count" ]]; then
          sel_name="${main_files[$idx0]}"
          sel_path="${main_paths[$idx0]}"
        else
          local sidx=$((idx0-main_count))
          sel_name="${setup_files[$sidx]}"
          sel_path="${setup_paths[$sidx]}"
        fi
        echo ""
        echo "-> Running: $sel_name"
        echo "------------------------------------"
        chmod +x "$sel_path" 2>/dev/null || true
        bash "$sel_path"
        echo "------------------------------------"
        read -rp "Press Enter to return..." _
        clear 2>/dev/null || true
      fi
    fi
  done
}
