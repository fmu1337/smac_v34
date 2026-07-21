#pragma semicolon 1
#include <sourcemod>
#include <smac>

/*
 * SMAC Immunity
 * Original: GoD-Tony — SMAC Official _unsupported/smac_immunity.sp
 * Via Cheat-Acid GRAB: https://github.com/DJPlaya/Cheat-Acid
 * Adapted for SMAC v34 (old syntax, 4-arg SMAC_OnCheatDetected forward).
 */

public Plugin:myinfo =
{
	name = "SMAC: Immunity",
	author = "GoD-Tony, Danyas",
	description = "Grants immunity from SMAC detections to privileged players",
	version = SMAC_VERSION,
	url = SMAC_URL
};

public Action:SMAC_OnCheatDetected(client, const String:module[], DetectionType:type, Handle:info)
{
	/* ADMFLAG_CUSTOM1 = "o" flag by default. */
	if (IS_CLIENT(client) && CheckCommandAccess(client, "smac_immunity", ADMFLAG_CUSTOM1, true))
	{
		return Plugin_Handled;
	}

	return Plugin_Continue;
}
