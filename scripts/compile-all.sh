#!/usr/bin/env bash
# Compile all SMAC plugins.
#
# Expected environment (set by CI or locally after extracting SourceMod):
#   SPCOMP   - path to spcomp (default: addons/sourcemod/scripting/spcomp)
#   SM_INCLUDE - SourceMod include dir (optional; defaults next to SPCOMP)
#   OUT_DIR  - output directory for .smx (default: addons/sourcemod/plugins)
#
# Project includes (smac.inc, etc.) are always taken from
# addons/sourcemod/scripting/include.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTING="$ROOT/addons/sourcemod/scripting"
PROJECT_INCLUDE="$SCRIPTING/include"

SPCOMP="${SPCOMP:-$SCRIPTING/spcomp}"
OUT_DIR="${OUT_DIR:-$ROOT/addons/sourcemod/plugins}"

if [[ -n "${SM_INCLUDE:-}" ]]; then
	SM_INCLUDE_DIR="$SM_INCLUDE"
else
	SM_INCLUDE_DIR="$(cd "$(dirname "$SPCOMP")" && pwd)/include"
fi

if [[ ! -x "$SPCOMP" ]]; then
	# Windows / no +x bit
	if [[ ! -f "$SPCOMP" ]]; then
		echo "error: spcomp not found at: $SPCOMP" >&2
		exit 1
	fi
fi

PLUGINS=(
	smac.sp
	smac_aimbot.sp
	smac_antiaim.sp
	smac_autotrigger.sp
	smac_client.sp
	smac_commands.sp
	smac_css_antiflash.sp
	smac_css_antismoke.sp
	smac_css_smokefix.sp
	smac_css_fixes.sp
	smac_cvars.sp
	smac_eyetest.sp
	smac_lerp.sp
	smac_rcon.sp
	smac_speedhack.sp
	smac_spinhack.sp
	smac_status.sp
	smac_wallhack.sp
	smac_ultra_netcode.sp
	smac_ultra_aimbot.sp
	smac_ultra_movement.sp
	smac_ultra_input.sp
	smac_ultra_client.sp
	smac_ultra_server.sp
	smac_ultra_aimkill.sp
	smac_ultra_protect.sp
	smac_ultra_diag_norecoil.sp
)

# Optional modules: compiled into plugins/disabled, so SourceMod does not load them
# until they are moved to plugins/.
OPTIONAL_PLUGINS=(
	smac_strafe.sp
)

mkdir -p "$OUT_DIR"

echo "Using spcomp: $SPCOMP"
"$SPCOMP" || true
echo "Project include: $PROJECT_INCLUDE"
echo "SM include:      $SM_INCLUDE_DIR"
echo "Output:          $OUT_DIR"
echo

mkdir -p "$OUT_DIR/disabled"

failed=0
for plugin in "${PLUGINS[@]}" "${OPTIONAL_PLUGINS[@]}"; do
	src="$SCRIPTING/$plugin"
	out="$OUT_DIR/${plugin%.sp}.smx"
	for optional in "${OPTIONAL_PLUGINS[@]}"; do
		if [[ "$plugin" == "$optional" ]]; then
			out="$OUT_DIR/disabled/${plugin%.sp}.smx"
		fi
	done
	echo "Compiling $plugin ..."
	if ! "$SPCOMP" \
		"-i$PROJECT_INCLUDE" \
		"-i$SM_INCLUDE_DIR" \
		"-o$out" \
		"$src"
	then
		echo "FAILED: $plugin" >&2
		failed=$((failed + 1))
	fi
done

if [[ "$failed" -ne 0 ]]; then
	echo "$failed plugin(s) failed to compile." >&2
	exit 1
fi

echo "All $(( ${#PLUGINS[@]} + ${#OPTIONAL_PLUGINS[@]} )) plugins compiled successfully."
