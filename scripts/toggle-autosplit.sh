#!/usr/bin/env bash
set -euo pipefail

is_flat_h_tiles() {
  [ "$(aerospace list-workspaces --focused --format '%{workspace-root-container-layout}')" = "h_tiles" ] &&
    aerospace list-windows --workspace focused \
      --format '%{window-parent-container-layout}' |
      awk '$0 != "floating" && $0 != "h_tiles" { found = 1 } END { exit found }'
}

flatten_in_current_order() {
  local original focused_ws tiled_count total_windows line id layout temp_ws expr
  local -a windows ordered

  original="$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null || true)"
  focused_ws="$(aerospace list-workspaces --focused)"
  tiled_count="$(
    aerospace list-windows --workspace focused \
      --format '%{window-parent-container-layout}' |
      awk '$1 != "floating" { count++ } END { print count + 0 }'
  )"

  # With 0-2 tiled windows, there is no custom autosplit tree to preserve.
  # For 3+ windows, keep the explicit order-preserving rebuild logic.
  if [ "$tiled_count" -le 2 ]; then
    aerospace eval 'flatten-workspace-tree; layout --root h_tiles; balance-sizes'
    return
  fi

  total_windows="$(aerospace list-windows --workspace focused --count)"

  # Walk the current AeroSpace tree order, but batch all focus/list commands
  # into one AeroSpace call. This keeps the correct behavior with much less
  # CLI overhead than one call per DFS index.
  windows=()
  expr=""

  for ((i = 0; i < total_windows; i++)); do
    expr+="focus --dfs-index $i; "
    expr+="list-windows --focused --format '%{window-id} %{window-parent-container-layout}'; "
  done

  if [ -n "$original" ]; then
    expr+="focus --window-id $original"
  fi

  while IFS= read -r line; do
    id="${line%% *}"
    layout="${line#* }"

    if [ -n "$id" ] && [ "$layout" != "floating" ]; then
      windows+=("$id")
    fi
  done < <(aerospace eval "$expr" 2>/dev/null || true)

  case "${#windows[@]}" in
    0)
      aerospace eval 'flatten-workspace-tree; layout --root h_tiles; balance-sizes'
      return
      ;;
    4)
      # The 4-window autosplit tree is column-major in DFS order:
      # [0][2]
      # [1][3]
      # Convert it back to the logical order autosplit expects, so toggling
      # flat -> autosplit preserves the same visual positions.
      ordered=("${windows[0]}" "${windows[2]}" "${windows[3]}" "${windows[1]}")
      ;;
    *)
      ordered=("${windows[@]}")
      ;;
  esac

  temp_ws="autosplit-temp-$$"
  expr=""

  for id in "${windows[@]}"; do
    expr+="move-node-to-workspace --window-id $id $temp_ws; "
  done

  for id in "${ordered[@]}"; do
    expr+="move-node-to-workspace --window-id $id $focused_ws; "
  done

  expr+="flatten-workspace-tree --workspace $focused_ws; "
  expr+="layout --workspace $focused_ws --root h_tiles; "
  expr+="balance-sizes --workspace $focused_ws"

  aerospace eval "$expr"

  if [ -n "$original" ]; then
    aerospace focus --window-id "$original" || true
  fi
}

if is_flat_h_tiles; then
  "$HOME/.config/aerospace/scripts/autosplit.sh"
else
  flatten_in_current_order
fi
