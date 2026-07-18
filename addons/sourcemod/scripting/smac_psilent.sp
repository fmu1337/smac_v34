#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: pSilent / one-tick aim snap detector
 *
 * Algorithm ported from StAC (stephanie) via Cheat-Acid GRAB:
 *   https://github.com/DJPlaya/Cheat-Acid  → GRAB/StAC/scripting/stac.sp
 * Silent aim flips viewangles for 1 cmd then restores (A-B-A pattern).
 * Adapted to SMAC v34 / old SourcePawn / CSS v34 (TF2 gates removed).
 */

public Plugin:myinfo =
{
	name = "SMAC: pSilent Detector",
	author = "stephanie, Danyas",
	description = "Detects pSilent / one-tick aim snaps (from StAC via Cheat-Acid)",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define PSILENT_MIN_DEG		1.0
#define PSILENT_BAN_MIN		3

new Handle:g_hCvarBan = INVALID_HANDLE;
new g_iBanAt = 0;

new Float:g_fAngCur[MAXPLAYERS+1][2];
new Float:g_fAngPrev1[MAXPLAYERS+1][2];
new Float:g_fAngPrev2[MAXPLAYERS+1][2];
new g_iDetects[MAXPLAYERS+1];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");
	g_hCvarBan = SMAC_CreateConVar("smac_psilent_ban", "5", "pSilent detections before ban. Minimum 3. (0 = Never ban)", _, true, 0.0);
	OnBanChanged(g_hCvarBan, "", "");
	HookConVarChange(g_hCvarBan, OnBanChanged);

	HookEvent("player_spawn", Event_SpawnClear, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);
}

public OnBanChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	new v = GetConVarInt(convar);
	if (v > 0 && v < PSILENT_BAN_MIN)
	{
		SetConVarInt(convar, PSILENT_BAN_MIN);
		return;
	}
	g_iBanAt = v;
}

public OnClientPutInServer(client)
{
	g_iDetects[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
	ClearAngles(client);
}

public Event_SpawnClear(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		ClearAngles(client);
		g_fIgnoreUntil[client] = GetGameTime() + 1.0;
	}
}

public Teleport_OnEndTouch(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator) && IsClientConnected(activator))
	{
		ClearAngles(activator);
		g_fIgnoreUntil[activator] = GetGameTime() + 0.5 + delay;
	}
}

ClearAngles(client)
{
	g_fAngCur[client][0] = 0.0;
	g_fAngCur[client][1] = 0.0;
	g_fAngPrev1[client][0] = 0.0;
	g_fAngPrev1[client][1] = 0.0;
	g_fAngPrev2[client][0] = 0.0;
	g_fAngPrev2[client][1] = 0.0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	if (GetGameTime() < g_fIgnoreUntil[client])
	{
		g_fAngPrev2[client][0] = g_fAngPrev1[client][0];
		g_fAngPrev2[client][1] = g_fAngPrev1[client][1];
		g_fAngPrev1[client][0] = g_fAngCur[client][0];
		g_fAngPrev1[client][1] = g_fAngCur[client][1];
		g_fAngCur[client][0] = angles[0];
		g_fAngCur[client][1] = angles[1];
		return Plugin_Continue;
	}

	g_fAngPrev2[client][0] = g_fAngPrev1[client][0];
	g_fAngPrev2[client][1] = g_fAngPrev1[client][1];
	g_fAngPrev1[client][0] = g_fAngCur[client][0];
	g_fAngPrev1[client][1] = g_fAngCur[client][1];
	g_fAngCur[client][0] = angles[0];
	g_fAngCur[client][1] = angles[1];

	/* StAC pSilent: cur == prev2, but prev1 differs (A-B-A). */
	if (g_fAngCur[client][0] == g_fAngPrev2[client][0]
		&& g_fAngCur[client][1] == g_fAngPrev2[client][1]
		&& g_fAngPrev1[client][0] != g_fAngCur[client][0]
		&& g_fAngPrev1[client][1] != g_fAngCur[client][1]
		&& g_fAngPrev1[client][0] != g_fAngPrev2[client][0]
		&& g_fAngPrev1[client][1] != g_fAngPrev2[client][1]
		&& g_fAngCur[client][0] != 0.0
		&& g_fAngCur[client][1] != 0.0
		&& g_fAngPrev1[client][0] != 0.0
		&& g_fAngPrev1[client][1] != 0.0
		&& g_fAngPrev2[client][0] != 0.0
		&& g_fAngPrev2[client][1] != 0.0)
	{
		new Float:aDiff[2];
		aDiff[0] = FloatAbs(g_fAngCur[client][0] - g_fAngPrev1[client][0]);
		aDiff[1] = FloatAbs(g_fAngCur[client][1] - g_fAngPrev1[client][1]);
		if (aDiff[0] > 180.0) aDiff[0] = FloatAbs(aDiff[0] - 360.0);
		if (aDiff[1] > 180.0) aDiff[1] = FloatAbs(aDiff[1] - 360.0);

		if (aDiff[0] >= PSILENT_MIN_DEG || aDiff[1] >= PSILENT_MIN_DEG)
		{
			g_iDetects[client]++;
			CreateTimer(1200.0, Timer_Decr, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

			new Handle:info = CreateKeyValues("");
			KvSetNum(info, "detection", g_iDetects[client]);
			KvSetFloat(info, "pitch_diff", aDiff[0]);
			KvSetFloat(info, "yaw_diff", aDiff[1]);

			if (SMAC_CheatDetected(client, Detection_pSilent, info) == Plugin_Continue)
			{
				SMAC_PrintAdminNotice("%t", "SMAC_pSilentDetected", client, g_iDetects[client]);
				SMAC_LogAction(client, "pSilent / one-tick aim snap (Detection #%i | dP=%.2f° dY=%.2f°)", g_iDetects[client], aDiff[0], aDiff[1]);

				if (g_iBanAt && g_iDetects[client] >= g_iBanAt)
				{
					SMAC_LogAction(client, "was banned for pSilent / NoRecoil.");
					SMAC_Ban(client, "pSilent Detection");
				}
			}
			CloseHandle(info);
		}
	}

	return Plugin_Continue;
}

public Action:Timer_Decr(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (IS_CLIENT(client) && g_iDetects[client] > 0)
		g_iDetects[client]--;
	return Plugin_Stop;
}
