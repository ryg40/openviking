#!/bin/sh
# Offline public-tree checks. See docs/public-check.md.
set -eu
command -v python3 >/dev/null 2>&1 || { echo 'public-check: python3 is required' >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo 'public-check: git is required' >&2; exit 2; }
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$script_dir/public_check.py" "$@"
