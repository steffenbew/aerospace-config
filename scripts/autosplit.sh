#!/usr/bin/env bash
set -euo pipefail

# AeroSpace can detect several restored windows at once during startup. Run
# one layout update at a time so concurrent scripts cannot mutate its tree.
if [ "${AEROSPACE_AUTOSPLIT_LOCKED:-}" != "1" ]; then
  export AEROSPACE_AUTOSPLIT_LOCKED=1
  exec lockf -k -s -t 5 "${TMPDIR:-/tmp}/aerospace-autosplit-${UID}.lock" "$0" "$@"
fi

original="${AEROSPACE_WINDOW_ID:-}"
is_window_callback="false"
[ -z "$original" ] || is_window_callback="true"

# One snapshot supplies triggering-window metadata, counts, and fallback order.
all_windows="$(
  aerospace list-windows --all \
    --format '%{window-id}|%{workspace}|%{window-parent-container-layout}|%{workspace-root-container-layout}|%{workspace-is-focused}'
)"

window_line=""
if [ "$is_window_callback" = "true" ]; then
  window_line="$(
    printf '%s\n' "$all_windows" |
      awk -F '|' -v id="$original" '$1 == id { print; exit }'
  )"

  # A queued callback can outlive its window. Do not apply it to whichever
  # workspace happens to be focused by the time the lock becomes available.
  [ -n "$window_line" ] || exit 0
else
  window_line="$(
    aerospace list-windows --focused \
      --format '%{window-id}|%{workspace}|%{window-parent-container-layout}|%{workspace-root-container-layout}|%{workspace-is-focused}' \
      2>/dev/null || true
  )"
fi

ws=""
original_layout=""
root_layout=""
workspace_is_focused="false"
window_id=""

if [ -n "$window_line" ]; then
  IFS='|' read -r window_id ws original_layout root_layout workspace_is_focused <<< "$window_line"
  [ -n "$original" ] || original="$window_id"
fi

# A focused workspace can be empty during a manual run, so keep a small
# fallback for the case where there was no focused window to provide metadata.
if [ -z "$ws" ]; then
  workspace_line="$(
    aerospace list-workspaces --focused \
      --format '%{workspace}|%{workspace-root-container-layout}'
  )"
  IFS='|' read -r ws root_layout <<< "$workspace_line"
  workspace_is_focused="true"
fi

# If the workspace is currently in accordion mode, leave it alone.
if [[ "$root_layout" == *accordion ]]; then
  exit 0
fi

# If the triggering window is floating, leave the tiled layout alone.
if [ "$original_layout" = "floating" ]; then
  exit 0
fi

# Reuse the all-window snapshot for both counts and the order fallback.
workspace_windows="$(
  printf '%s\n' "$all_windows" |
    awk -F '|' -v ws="$ws" '$2 == ws { print $1 "|" $3 }'
)"
read -r count total_windows <<< "$(
  printf '%s\n' "$workspace_windows" |
    awk -F '|' '$1 != "" { total++; if ($2 != "floating") tiled++ } END { print tiled + 0, total + 0 }'
)"

windows=()

# Manual 3- and 4-window rebuilds need exact tree order. Window callbacks know
# which window is new and can place it without cycling focus through the tree.
did_focus_scan="false"
focused_before=""
if [ "$is_window_callback" = "false" ] && { [ "$count" -eq 3 ] || [ "$count" -eq 4 ]; }; then
  # `list-windows` is stable by window creation order, not by the current tree
  # order. For the focused workspace, walk AeroSpace's DFS order instead so
  # manual move/swap operations are respected before we rebuild the layout.
  # Keep each focus in a separate session: batching several DFS focus commands
  # in one `eval` can corrupt AeroSpace 0.21.2's tree when floating windows exist.
  # Pair each focus with its read to avoid an extra CLI round trip.
  if [ "$workspace_is_focused" = "true" ]; then
    focused_before="$(aerospace list-windows --focused --format '%{window-id}' 2>/dev/null || true)"
    did_focus_scan="true"

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
  fi

  # Fallback for non-focused workspaces, or if DFS collection was incomplete.
  if [ "${#windows[@]}" -ne "$count" ]; then
    windows=()
    while IFS='|' read -r id layout; do
      if [ -n "$id" ] && [ "$layout" != "floating" ]; then
        windows+=("$id")
      fi
    done <<< "$workspace_windows"
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
    # Desired visual order when C is the newly opened window:
    # [ A ][ B ]
    #       [ C ]
    if [ "$is_window_callback" = "true" ]; then
      # Keep A and B in their current order and place C at the far right. Move
      # C next to B, group both vertically, then swap C down. ID-targeted
      # commands avoid focus blinking while keeping C at the bottom right.
      aerospace eval "flatten-workspace-tree --workspace $ws; layout --workspace $ws --root h_tiles; move --window-id $original right; swap --window-id $original left; join-with --window-id $original right; swap --window-id $original down; balance-sizes --workspace $ws"
    else
      # Manual runs have no known new window, so use the DFS order collected
      # above and group the last two windows in place.
      aerospace eval "flatten-workspace-tree --workspace $ws; layout --workspace $ws --root h_tiles; join-with --window-id ${windows[1]} right; balance-sizes --workspace $ws"
    fi
    ;;

  4)
    # Desired visual order when D is the newly opened window:
    # [ A ][ B ]
    # [ D ][ C ]
    if [ "$is_window_callback" = "true" ]; then
      # In the existing 3-window tree, A is the root-level tiled window while
      # B and C share a vertical container. If D was inserted into that right
      # column, move it out first; then group A and D without disturbing B/C.
      left_window="$(
        printf '%s\n' "$workspace_windows" |
          awk -F '|' -v id="$original" '$1 != id && $2 == "h_tiles" { print $1; exit }'
      )"

      if [ -n "$left_window" ]; then
        expr=""
        if [ "$original_layout" != "h_tiles" ]; then
          expr+="move --window-id $original left; "
        fi
        expr+="join-with --window-id $left_window right; "
        expr+="balance-sizes --workspace $ws"
        aerospace eval "$expr"
      else
        # A custom pre-existing tree may not expose the expected anchor. Keep
        # it intact rather than guessing an order or cycling focus.
        aerospace balance-sizes --workspace "$ws"
      fi
    else
      # A manual rebuild starts from the flat row [A B C D]. Move D beside A,
      # then build both columns directly without a temporary workspace.
      aerospace eval "flatten-workspace-tree --workspace $ws; layout --workspace $ws --root h_tiles; swap --window-id ${windows[3]} left; swap --window-id ${windows[3]} left; join-with --window-id ${windows[0]} right; join-with --window-id ${windows[1]} right; balance-sizes --workspace $ws"
    fi
    ;;

  *)
    # For 5+ tiled windows, keep AeroSpace's current tree. Flattening here
    # destroys the existing autosplit shape and turns everything into one row.
    aerospace balance-sizes --workspace "$ws"
    ;;
esac

# Only DFS collection changes focus. ID-targeted callback layouts leave the
# user's focus untouched and need no extra socket round trip.
if [ "$did_focus_scan" = "true" ] && [ -n "$focused_before" ]; then
  aerospace focus --window-id "$focused_before" || true
fi
