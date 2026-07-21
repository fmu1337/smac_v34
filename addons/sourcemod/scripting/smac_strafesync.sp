#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Strafe Sync
 *
 * Original module by Danyas for SMAC v34.
 * Optional high-threshold detector inspired by Ash (moved-first / turned-first
 * tick deltas) and Bash/Oryx (start/end strafe sync, low deviation).
 * Default ban is OFF — for pub CSS use as admin signal only.
 */

public Plugin:myinfo =
{
	name = "SMAC: Strafe Sync",
	author = SMAC_AUTHOR,
	description = "Optional high-threshold air strafe sync detector",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define SAMPLE_SIZE		40
#define PERFECT_NEED	30
#define MAX_DIFF		15

new Handle:g_hCvarEnabled = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;
new Handle:g_hCvarPerfect = INVALID_HANDLE;

new Float:g_fPrevYaw[MAXPLAYERS+1];
new bool:g_bHaveYaw[MAXPLAYERS+1];
new bool:g_bTurnRight[MAXPLAYERS+1];
new g_iLastTurnTick[MAXPLAYERS+1];
new g_iLastMoveTick[MAXPLAYERS+1];
new bool:g_bLastMoveRight[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];
new g_iCmd[MAXPLAYERS+1];

new g_iDiffs[MAXPLAYERS+1][SAMPLE_SIZE];
new g_iDiffCount[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarEnabled = SMAC_CreateConVar("smac_strafesync_enabled", "1", "Enable optional strafe-sync sampling.", _, true, 0.0, true, 1.0);
	g_hCvarBan = SMAC_CreateConVar("smac_strafesync_ban", "0", "Detections before ban. (0 = Never — recommended for pub)", _, true, 0.0);
	g_hCvarPerfect = SMAC_CreateConVar("smac_strafesync_perfect", "30", "Perfect (|diff|<=1) samples in a 40-window to detect.", _, true, 20.0, true, 40.0);

	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);
}

public OnClientPutInServer(client)
{
	ResetClient(client);
}

public OnClientDisconnect(client)
{
	ResetClient(client);
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_bHaveYaw[client] = false;
		g_iDiffCount[client] = 0;
		g_fIgnoreUntil[client] = GetGameTime() + 2.0;
	}
}

public Teleport_OnEndTouch(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator) && IsClientConnected(activator))
	{
		g_bHaveYaw[activator] = false;
		g_iDiffCount[activator] = 0;
		g_fIgnoreUntil[activator] = GetGameTime() + 0.75 + delay;
	}
}

ResetClient(client)
{
	g_bHaveYaw[client] = false;
	g_bTurnRight[client] = false;
	g_iLastTurnTick[client] = 0;
	g_iLastMoveTick[client] = 0;
	g_bLastMoveRight[client] = false;
	g_iPrevButtons[client] = 0;
	g_iCmd[client] = 0;
	g_iDiffCount[client] = 0;
	g_iDetects[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!GetConVarBool(g_hCvarEnabled))
		return Plugin_Continue;
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;
	if (GetGameTime() < g_fIgnoreUntil[client])
	{
		g_iPrevButtons[client] = buttons;
		return Plugin_Continue;
	}
	if (GetEntityFlags(client) & FL_ONGROUND || GetEntityMoveType(client) != MOVETYPE_WALK)
	{
		g_iPrevButtons[client] = buttons;
		g_bHaveYaw[client] = false;
		return Plugin_Continue;
	}

	g_iCmd[client]++;

	/* Key switch tick */
	new bool:moveRight = false;
	new bool:moved = false;
	if ((buttons & IN_MOVERIGHT) && !(g_iPrevButtons[client] & IN_MOVERIGHT) && !(buttons & IN_MOVELEFT))
	{
		moveRight = true;
		moved = true;
	}
	else if ((buttons & IN_MOVELEFT) && !(g_iPrevButtons[client] & IN_MOVELEFT) && !(buttons & IN_MOVERIGHT))
	{
		moveRight = false;
		moved = true;
	}
	if (moved)
	{
		g_iLastMoveTick[client] = g_iCmd[client];
		g_bLastMoveRight[client] = moveRight;
		TryRecord(client);
	}

	/* Turn direction change via yaw */
	if (!g_bHaveYaw[client])
	{
		g_fPrevYaw[client] = angles[1];
		g_bHaveYaw[client] = true;
		g_iPrevButtons[client] = buttons;
		return Plugin_Continue;
	}

	new Float:delta = angles[1] - g_fPrevYaw[client];
	while (delta > 180.0) delta -= 360.0;
	while (delta < -180.0) delta += 360.0;
	g_fPrevYaw[client] = angles[1];

	if (FloatAbs(delta) >= 0.5)
	{
		new bool:turnRight = (delta > 0.0);
		if (turnRight != g_bTurnRight[client] || g_iLastTurnTick[client] == 0)
		{
			g_bTurnRight[client] = turnRight;
			g_iLastTurnTick[client] = g_iCmd[client];
			TryRecord(client);
		}
	}

	g_iPrevButtons[client] = buttons;
	return Plugin_Continue;
}

TryRecord(client)
{
	if (g_iLastTurnTick[client] <= 0 || g_iLastMoveTick[client] <= 0)
		return;

	/* Only when turn dir matches move dir (A=left turn / D=right turn). */
	new bool:moveRight = g_bLastMoveRight[client];
	if (moveRight != g_bTurnRight[client])
		return;

	new diff = g_iLastMoveTick[client] - g_iLastTurnTick[client];
	if (diff < -MAX_DIFF || diff > MAX_DIFF)
		return;

	/* Avoid double-recording the same pair from both hooks in one tick. */
	static iLastRecorded[MAXPLAYERS+1];
	new pair = g_iLastMoveTick[client] + (g_iLastTurnTick[client] << 16);
	if (iLastRecorded[client] == pair)
		return;
	iLastRecorded[client] = pair;

	new idx = g_iDiffCount[client];
	if (idx >= SAMPLE_SIZE)
	{
		/* shift left */
		for (new i = 1; i < SAMPLE_SIZE; i++)
			g_iDiffs[client][i - 1] = g_iDiffs[client][i];
		idx = SAMPLE_SIZE - 1;
		g_iDiffCount[client] = SAMPLE_SIZE - 1;
	}
	g_iDiffs[client][idx] = diff;
	g_iDiffCount[client]++;

	if (g_iDiffCount[client] >= SAMPLE_SIZE)
		Evaluate(client);
}

Evaluate(client)
{
	new perfect = 0;
	new absSum = 0;
	for (new i = 0; i < SAMPLE_SIZE; i++)
	{
		new d = g_iDiffs[client][i];
		if (d < 0) d = -d;
		absSum += d;
		if (d <= 1)
			perfect++;
	}

	new need = GetConVarInt(g_hCvarPerfect);
	if (perfect < need)
		return;

	g_iDiffCount[client] = 0;
	g_iDetects[client]++;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iDetects[client]);
	KvSetNum(info, "perfect", perfect);
	KvSetNum(info, "abs_sum", absSum);

	if (SMAC_CheatDetected(client, Detection_StrafeSync, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_StrafeSyncDetected", client, g_iDetects[client]);
		SMAC_LogAction(client, "strafe sync (Detection #%i | perfect=%i/%i abs_sum=%i)", g_iDetects[client], perfect, SAMPLE_SIZE, absSum);

		new banAt = GetConVarInt(g_hCvarBan);
		if (banAt && g_iDetects[client] >= banAt)
		{
			SMAC_LogAction(client, "was banned for strafe sync.");
			SMAC_Ban(client, "Strafe Sync Detection");
		}
	}
	CloseHandle(info);
}
