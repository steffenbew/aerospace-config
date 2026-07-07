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
  original_layout="$(
    aerospace list-windows --all --format '%{window-id} %{window-parent-container-layout}' |
      awk -v id="$original" '$1 == id { print $2; exit }'
  )"

  if [ "$original_layout" = "floating" ]; then
    exit 0
  fi
fi

windows=()
while IFS= read -r id; do
  windows+=("$id")
done < <(
  aerospace list-windows --workspace "$ws" \
    --format '%{window-id} %{window-parent-container-layout}' |
    awk '$2 != "floating" { print $1 }' |
    sort -n
)

count="${#windows[@]}"

case "$count" in
  0|1)
    aerospace flatten-workspace-tree --workspace "$ws"
    aerospace layout --workspace "$ws" --root h_tiles
    ;;

  2)
    aerospace flatten-workspace-tree --workspace "$ws"
    aerospace layout --workspace "$ws" --root h_tiles
    aerospace balance-sizes --workspace "$ws"
    ;;

  3)
    # Reinsert windows in creation order first. Without this, creating the
    # third window while the first window is focused can leave the second
    # window at the far right, so join-with has no right-hand neighbor.
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
    # Reinsert windows in the order we want before grouping them.
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
    aerospace flatten-workspace-tree --workspace "$ws"
    aerospace layout --workspace "$ws" --root h_tiles
    aerospace balance-sizes --workspace "$ws"
    ;;
esac

# Restore focus to the triggering window when possible.
if [ -n "$original" ]; then
  aerospace focus --window-id "$original" || true
fi
