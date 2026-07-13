#!/usr/bin/env bash
set -euo pipefail

# Share the autosplit lock so a manual toggle cannot race a window callback.
if [ "${AEROSPACE_AUTOSPLIT_LOCKED:-}" != "1" ]; then
  export AEROSPACE_AUTOSPLIT_LOCKED=1
  exec lockf -k -s -t 5 "${TMPDIR:-/tmp}/aerospace-autosplit-${UID}.lock" "$0" "$@"
fi

# Take one snapshot up front and reuse it to choose and execute the toggle.
focused_line="$(
  aerospace list-windows --focused \
    --format '%{window-id}|%{workspace}|%{workspace-root-container-layout}' \
    2>/dev/null || true
)"
IFS='|' read -r original focused_ws root_layout <<< "$focused_line"

if [ -z "$focused_ws" ]; then
  workspace_line="$(
    aerospace list-workspaces --focused \
      --format '%{workspace}|%{workspace-root-container-layout}'
  )"
  IFS='|' read -r focused_ws root_layout <<< "$workspace_line"
fi

workspace_windows="$(
  aerospace list-windows --workspace focused \
    --format '%{window-id}|%{window-parent-container-layout}'
)"
read -r tiled_count total_windows has_nested <<< "$(
  printf '%s\n' "$workspace_windows" |
    awk -F '|' '
      $1 != "" {
        total++
        if ($2 != "floating") {
          tiled++
          if ($2 != "h_tiles") nested = 1
        }
      }
      END { print tiled + 0, total + 0, nested + 0 }
    '
)"

flatten_in_current_order() {
  local line id layout i
  local -a windows

  # Flattening already preserves DFS order. Only the 2x2 autosplit grid needs
  # an explicit row-major conversion before becoming one horizontal row.
  if [ "$tiled_count" -ne 4 ]; then
    aerospace eval 'flatten-workspace-tree; layout --root h_tiles; balance-sizes'
    return
  fi

  # Walk the current AeroSpace tree order. Keep each focus in a separate
  # session because batching DFS focus commands can corrupt AeroSpace 0.21.2's
  # tree when floating windows exist. Pair each focus with its read to avoid
  # an extra CLI round trip.
  windows=()

  for ((i = 0; i < total_windows; i++)); do
    line="$(
      aerospace eval "focus --dfs-index $i; list-windows --focused --format '%{window-id} %{window-parent-container-layout}'" \
        2>/dev/null || true
    )"
    id="${line%% *}"
    layout="${line#* }"

    if [ -n "$id" ] && [ "$id" != "$line" ] && [ "$layout" != "floating" ]; then
      windows+=("$id")
    fi
  done

  if [ "${#windows[@]}" -ne "$tiled_count" ]; then
    aerospace eval 'flatten-workspace-tree; layout --root h_tiles; balance-sizes'
    if [ -n "$original" ]; then
      aerospace focus --window-id "$original" >/dev/null 2>&1 || true
    fi
    return
  fi

  # The 4-window autosplit tree is column-major in DFS order. Flattening
  # yields [A D B C]. Move D to the far right to get row-major [A B C D]
  # without moving any window through a temporary workspace.
  aerospace eval "flatten-workspace-tree --workspace $focused_ws; layout --workspace $focused_ws --root h_tiles; swap --window-id ${windows[1]} right; swap --window-id ${windows[1]} right; balance-sizes --workspace $focused_ws"

  if [ -n "$original" ]; then
    aerospace focus --window-id "$original" || true
  fi
}

if [ "$root_layout" = "h_tiles" ] && [ "$has_nested" -eq 0 ]; then
  "$HOME/.config/aerospace/scripts/autosplit.sh"
else
  flatten_in_current_order
fi
