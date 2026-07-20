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
	smac_aimlock.sp
	smac_aimorigin.sp
	smac_antiaim.sp
	smac_autotrigger.sp
	smac_client.sp
	smac_commands.sp
	smac_css_antiflash.sp
	smac_css_antismoke.sp
	smac_css_fixes.sp
	smac_cvars.sp
	smac_eyetest.sp
	smac_immunity.sp
	smac_psilent.sp
	smac_rcon.sp
	smac_serverlock.sp
	smac_speedhack.sp
	smac_spinhack.sp
	smac_status.sp
	smac_strafe.sp
	smac_strafesync.sp
	smac_triggerbot.sp
	smac_turncheck.sp
	smac_movesanity.sp
	smac_strikeback.sp
	smac_teleport.sp
	smac_entityspam.sp
	smac_ssac.sp
	smac_norecoil.sp
	smac_fakelag.sp
	smac_firemacro.sp
	smac_ultra_aim.sp
	smac_backtrack.sp
	smac_fastreload.sp
	smac_aimsnap.sp
	smac_advtrigger.sp
	smac_fdbhop.sp
	smac_speedlimit.sp
	smac_aimkill.sp
	smac_soundesp.sp
	smac_ultratools.sp
	smac_nospamweapon.sp
	smac_cheatcfg.sp
	smac_wallhack.sp
	0_smac_testbench.sp
)

mkdir -p "$OUT_DIR"

echo "Using spcomp: $SPCOMP"
"$SPCOMP" || true
echo "Project include: $PROJECT_INCLUDE"
echo "SM include:      $SM_INCLUDE_DIR"
echo "Output:          $OUT_DIR"
echo

failed=0
for plugin in "${PLUGINS[@]}"; do
	src="$SCRIPTING/$plugin"
	if [[ "$plugin" == "0_smac_testbench.sp" ]]; then
		mkdir -p "$OUT_DIR/disabled"
		out="$OUT_DIR/disabled/${plugin%.sp}.smx"
	else
		out="$OUT_DIR/${plugin%.sp}.smx"
	fi
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

echo "All ${#PLUGINS[@]} plugins compiled successfully."
