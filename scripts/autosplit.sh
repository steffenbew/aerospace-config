#!/usr/bin/env bash
set -euo pipefail

original="${AEROSPACE_WINDOW_ID:-}"

ws=""
if [ -n "$original" ]; then
  ws="$(
    aerospace list-windows --all --format '%{window-id} %{workspace}' |
      awk -v id="$original" '$1 == id { print $2; exit }'
  )"
fi

[ -n "$ws" ] || ws="$(aerospace list-workspaces --focused)"

# For keybinding-triggered runs there is no AEROSPACE_WINDOW_ID. Still keep
# track of the currently focused window so rebuilding the tree does not move
# focus unexpectedly. Read its layout in the same call to avoid another
# list-windows --all lookup below.
original_layout=""
if [ -z "$original" ]; then
  focused_window="$(aerospace list-windows --focused --format '%{window-id} %{window-parent-container-layout}' 2>/dev/null || true)"
  original="${focused_window%% *}"
  original_layout="${focused_window#* }"

  if [ "$original" = "$focused_window" ]; then
    original=""
    original_layout=""
  fi
fi

root_layout="$(
  aerospace list-workspaces --all --format '%{workspace} %{workspace-root-container-layout}' |
    awk -v ws="$ws" '$1 == ws { print $2; exit }'
)"

# If the workspace is currently in accordion mode, leave it alone.
if [[ "$root_layout" == *accordion ]]; then
  exit 0
fi

# If the triggering window is floating, leave the tiled layout alone.
if [ -n "$original" ]; then
  if [ -z "$original_layout" ]; then
    original_layout="$(
      aerospace list-windows --all --format '%{window-id} %{window-parent-container-layout}' |
        awk -v id="$original" '$1 == id { print $2; exit }'
    )"
  fi

  if [ "$original_layout" = "floating" ]; then
    exit 0
  fi
fi

count="$(
  aerospace list-windows --workspace "$ws" \
    --format '%{window-parent-container-layout}' |
    awk '$1 != "floating" { count++ } END { print count + 0 }'
)"

windows=()

# Only the 3- and 4-window autosplit layouts need exact window order. Simpler
# counts can skip the DFS walk entirely.
if [ "$count" -eq 3 ] || [ "$count" -eq 4 ]; then
  focused_ws="$(aerospace list-workspaces --focused)"

  # `list-windows` is stable by window creation order, not by the current tree
  # order. For the focused workspace, walk AeroSpace's DFS order instead so
  # manual move/swap operations are respected before we rebuild the layout.
  # Batch the focus/list commands into one AeroSpace call to keep this fast.
  if [ "$ws" = "$focused_ws" ]; then
    focused_before="$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null || true)"
    total_windows="$(aerospace list-windows --workspace "$ws" --count)"
    expr=""

    for ((i = 0; i < total_windows; i++)); do
      expr+="focus --dfs-index $i; "
      expr+="list-windows --focused --format '%{window-id} %{window-parent-container-layout}'; "
    done

    if [ -n "$focused_before" ]; then
      expr+="focus --window-id $focused_before"
    fi

    while IFS= read -r line; do
      id="${line%% *}"
      layout="${line#* }"

      if [ -n "$id" ] && [ "$layout" != "floating" ]; then
        windows+=("$id")
      fi
    done < <(aerospace eval "$expr" 2>/dev/null || true)
  fi

  # Fallback for non-focused workspaces, or if DFS collection failed.
  if [ "${#windows[@]}" -eq 0 ]; then
    while IFS= read -r id; do
      windows+=("$id")
    done < <(
      aerospace list-windows --workspace "$ws" \
        --format '%{window-id} %{window-parent-container-layout}' |
        awk '$2 != "floating" { print $1 }'
    )
  fi
fi

case "$count" in
  0|1)
    aerospace eval "flatten-workspace-tree --workspace $ws; layout --workspace $ws --root h_tiles"
    ;;

  2)
    aerospace eval "flatten-workspace-tree --workspace $ws; layout --workspace $ws --root h_tiles; balance-sizes --workspace $ws"
    ;;

  3)
    # Reinsert windows in the current AeroSpace order first. This preserves
    # manual reordering instead of falling back to window creation order.
    temp_ws="autosplit-temp-$$"
    expr=""

    for id in "${windows[@]}"; do
      expr+="move-node-to-workspace --window-id $id $temp_ws; "
    done

    # Desired visual order:
    # [ A ][ B ]
    #       [ C ]
    for id in "${windows[0]}" "${windows[1]}" "${windows[2]}"; do
      expr+="move-node-to-workspace --window-id $id $ws; "
    done

    expr+="flatten-workspace-tree --workspace $ws; "
    expr+="layout --workspace $ws --root h_tiles; "
    expr+="join-with --window-id ${windows[1]} right; "
    expr+="balance-sizes --workspace $ws"

    aerospace eval "$expr"
    ;;

  4)
    # Reinsert windows based on the current AeroSpace order before grouping them.
    # Batch everything into one AeroSpace eval call to reduce visible flicker.
    temp_ws="autosplit-temp-$$"
    expr=""

    for id in "${windows[@]}"; do
      expr+="move-node-to-workspace --window-id $id $temp_ws; "
    done

    # Desired visual order:
    # [ A ][ B ]
    # [ D ][ C ]
    for id in "${windows[0]}" "${windows[3]}" "${windows[1]}" "${windows[2]}"; do
      expr+="move-node-to-workspace --window-id $id $ws; "
    done

    expr+="flatten-workspace-tree --workspace $ws; "
    expr+="layout --workspace $ws --root h_tiles; "
    expr+="join-with --window-id ${windows[0]} right; "
    expr+="join-with --window-id ${windows[1]} right; "
    expr+="balance-sizes --workspace $ws"

    aerospace eval "$expr"
    ;;

  *)
    # For 5+ tiled windows, keep AeroSpace's current tree. Flattening here
    # destroys the existing autosplit shape and turns everything into one row.
    aerospace balance-sizes --workspace "$ws"
    ;;
esac

# Restore focus to the triggering window when possible.
if [ -n "$original" ]; then
  aerospace focus --window-id "$original" || true
fi
