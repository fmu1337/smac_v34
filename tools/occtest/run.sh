#!/usr/bin/env bash
# Checks the smac_wallhack occluder loader (SourcePawn) against the Python reference on .bsp files.
# Usage: SPCOMP=.../oldspcomp SPSHELL=.../spshell SP_ROOT=<sourcepawn checkout> ./run.sh map1.bsp [map2.bsp ...]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
INC="$HERE/../../addons/sourcemod/scripting/include"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp "$HERE/test.sp" "$WORK/"
for map in "$@"; do
	echo "== $map"
	python3 -I "$HERE/gen_harness.py" "$map" "$WORK/data.inc" "$HERE"
	"$SPCOMP" "-i$SP_ROOT/tests" "-i$SP_ROOT/include" "-i$INC" "$WORK/test.sp" "-o$WORK/test.smx" >/dev/null
	"$SPSHELL" "$WORK/test.smx"
done
