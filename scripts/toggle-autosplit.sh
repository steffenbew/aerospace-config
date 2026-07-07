#!/usr/bin/env bash
set -euo pipefail

is_flat_h_tiles() {
  [ "$(aerospace list-workspaces --focused --format '%{workspace-root-container-layout}')" = "h_tiles" ] &&
    ! aerospace list-windows --workspace focused \
      --format '%{window-parent-container-layout}' |
      grep -v '^floating$' |
      grep -vq '^h_tiles$'
}

if is_flat_h_tiles; then
  "$HOME/.config/aerospace/scripts/autosplit.sh"
else
  aerospace eval 'flatten-workspace-tree; layout --root h_tiles; balance-sizes'
fi
