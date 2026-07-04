#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SP_DIR="${SCRIPT_DIR}/../addons/sourcemod/scripting"

if [[ ! -x "${SP_DIR}/spcomp" ]]; then
	echo "SourceMod compiler not found. Download and extract SourceMod before running this script." >&2
	exit 1
fi

cd "${SP_DIR}"
chmod +x spcomp compile.sh

PLUGINS=(
	smac.sp
	smac_aimbot.sp
	smac_antiaim.sp
	smac_autotrigger.sp
	smac_client.sp
	smac_commands.sp
	smac_css_antiflash.sp
	smac_css_antismoke.sp
	smac_css_fixes.sp
	smac_cvars.sp
	smac_eyetest.sp
	smac_rcon.sp
	smac_speedhack.sp
	smac_spinhack.sp
	smac_status.sp
	smac_wallhack.sp
)

for plugin in "${PLUGINS[@]}"; do
	./compile.sh "${plugin}"
done
