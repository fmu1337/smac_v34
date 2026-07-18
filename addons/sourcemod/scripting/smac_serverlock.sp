#pragma semicolon 1
#include <sourcemod>
#include <smac>

/*
 * SMAC: Server Lock
 *
 * Original module by Danyas for SMAC v34.
 * Idea inspired by Cheat-Acid CA-ServerProtect (force sv_allowupload off,
 * revert unexpected sv_cheats enable). Complements smac_rcon.sp.
 */

public Plugin:myinfo =
{
	name = "SMAC: Server Lock",
	author = SMAC_AUTHOR,
	description = "Locks dangerous server convars (upload / cheats)",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarUpload = INVALID_HANDLE;
new Handle:g_hCvarCheats = INVALID_HANDLE;
new Handle:g_hCvarLockUpload = INVALID_HANDLE;
new Handle:g_hCvarLockCheats = INVALID_HANDLE;
new bool:g_bReverting = false;

public OnPluginStart()
{
	g_hCvarLockUpload = SMAC_CreateConVar("smac_lock_allowupload", "1", "Force sv_allowupload to 0 (blocks upload exploits on older engines).", _, true, 0.0, true, 1.0);
	g_hCvarLockCheats = SMAC_CreateConVar("smac_lock_cheats", "1", "Force sv_cheats back to 0 if enabled at runtime.", _, true, 0.0, true, 1.0);

	g_hCvarUpload = FindConVar("sv_allowupload");
	g_hCvarCheats = FindConVar("sv_cheats");

	if (g_hCvarUpload != INVALID_HANDLE)
		HookConVarChange(g_hCvarUpload, OnUploadChanged);
	if (g_hCvarCheats != INVALID_HANDLE)
		HookConVarChange(g_hCvarCheats, OnCheatsChanged);

	HookConVarChange(g_hCvarLockUpload, OnLockFlagsChanged);
	HookConVarChange(g_hCvarLockCheats, OnLockFlagsChanged);
}

public OnConfigsExecuted()
{
	ApplyLocks();
}

public OnLockFlagsChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	ApplyLocks();
}

ApplyLocks()
{
	if (g_bReverting)
		return;

	if (GetConVarBool(g_hCvarLockUpload) && g_hCvarUpload != INVALID_HANDLE && GetConVarBool(g_hCvarUpload))
	{
		g_bReverting = true;
		SMAC_Log("sv_allowupload was enabled. Forcing 0 (smac_serverlock).");
		SetConVarBool(g_hCvarUpload, false);
		g_bReverting = false;
	}

	if (GetConVarBool(g_hCvarLockCheats) && g_hCvarCheats != INVALID_HANDLE && GetConVarBool(g_hCvarCheats))
	{
		/* Delay one frame so map-start scripts that need cheats can finish. */
		CreateTimer(0.1, Timer_DisableCheats, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public OnUploadChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (g_bReverting || !GetConVarBool(g_hCvarLockUpload))
		return;
	if (GetConVarBool(g_hCvarUpload))
	{
		g_bReverting = true;
		SMAC_Log("sv_allowupload changed to \"%s\". Reverting to 0.", newValue);
		SetConVarBool(g_hCvarUpload, false);
		g_bReverting = false;
	}
}

public OnCheatsChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (g_bReverting || !GetConVarBool(g_hCvarLockCheats))
		return;
	if (GetConVarBool(g_hCvarCheats))
		CreateTimer(0.1, Timer_DisableCheats, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_DisableCheats(Handle:timer)
{
	if (!GetConVarBool(g_hCvarLockCheats) || g_hCvarCheats == INVALID_HANDLE)
		return Plugin_Stop;
	if (!GetConVarBool(g_hCvarCheats))
		return Plugin_Stop;

	g_bReverting = true;
	SMAC_Log("sv_cheats was enabled. Forcing 0 (smac_serverlock).");
	SetConVarBool(g_hCvarCheats, false);
	g_bReverting = false;
	return Plugin_Stop;
}
