#!/bin/sh
# IFNH uninstaller (k3s-style).
#   uninstall.sh           remove binary + state (keeps your config and API keys)
#   uninstall.sh --purge   also delete ~/.config/ifnh (config + stored API keys)
# Project-local .ifnh/ directories are never touched.
set -eu
PREFIX="${IFNH_PREFIX:-$HOME/.local/bin}"
CONFIG_DIR="$HOME/.config/ifnh"
STATE_DIR="$HOME/.local/state/ifnh"

purge=0
for arg in "$@"; do
  case "$arg" in
    --purge) purge=1 ;;
    *) echo "ifnh-uninstall: unknown option '$arg' (use --purge)" >&2; exit 1 ;;
  esac
done

echo "ifnh uninstall:"
removed=0
for f in "$PREFIX/ifnh" "$PREFIX/ifnh-uninstall.sh"; do
  if [ -f "$f" ]; then
    rm -f "$f"
    echo "  removed $f"
    removed=1
  fi
done

if [ -d "$STATE_DIR" ]; then
  rm -rf "$STATE_DIR"
  echo "  removed $STATE_DIR"
fi

if [ "$purge" = 1 ]; then
  if [ -d "$CONFIG_DIR" ]; then
    rm -rf "$CONFIG_DIR"
    echo "  removed $CONFIG_DIR (configuration and stored API keys)"
  fi
else
  if [ -d "$CONFIG_DIR" ]; then
    echo "  kept $CONFIG_DIR (configuration + API keys) — use --purge to delete"
  fi
fi

echo "  note: project-local .ifnh/ directories were left untouched."
if [ "$removed" = 1 ]; then
  echo "ifnh uninstalled."
else
  echo "ifnh was not found in $PREFIX (nothing to do)."
fi
