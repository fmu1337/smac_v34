#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Teleport / Tick-Move / Fast Detect
 *
 * Original module by Danyas for SMAC v34.
 * Ultr@ smac_SpeedTeleport: signed dist ( -N kick / +N ban / 0 off ).
 * Fast Detect uses a lower distance streak counter.
 */

public Plugin:myinfo =
{
	name = "SMAC: Teleport Detector",
	author = SMAC_AUTHOR,
	description = "Detects impossible per-tick origin jumps (Ultr@ SpeedTeleport)",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarDist = INVALID_HANDLE;
new Handle:g_hCvarFast = INVALID_HANDLE;

new Float:g_vPrevOrigin[MAXPLAYERS+1][3];
new bool:g_bHaveOrigin[MAXPLAYERS+1];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];
new g_iFastStreak[MAXPLAYERS+1];
new g_iFastDet[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	/* Ultr@ signed float: abs=threshold units/tick; sign selects kick/ban. */
	g_hCvarDist = SMAC_CreateConVar("smac_SpeedTeleport", "0.0", "Teleport dist. 0=off, -1500=kick@1500u, +1500=ban@1500u", _, true, -50000.0, true, 50000.0);
	g_hCvarFast = SMAC_CreateConVar("smac_SpeedTeleport_fast", "0", "Fast Detect: streak of mid jumps (400-999u). 0=off, -N=kick, +N=ban", _, true, -100.0, true, 100.0);

	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);
}

public OnClientPutInServer(client)
{
	g_bHaveOrigin[client] = false;
	g_iDetects[client] = 0;
	g_iFastStreak[client] = 0;
	g_iFastDet[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_bHaveOrigin[client] = false;
		g_iFastStreak[client] = 0;
		g_fIgnoreUntil[client] = GetGameTime() + 2.0;
	}
}

public Teleport_OnEndTouch(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator) && IsClientConnected(activator))
	{
		g_bHaveOrigin[activator] = false;
		g_iFastStreak[activator] = 0;
		g_fIgnoreUntil[activator] = GetGameTime() + 0.75 + delay;
	}
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	new Float:signedLimit = GetConVarFloat(g_hCvarDist);
	new fastReact = GetConVarInt(g_hCvarFast);
	if (signedLimit == 0.0 && fastReact == 0)
		return Plugin_Continue;
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;
	if (GetGameTime() < g_fIgnoreUntil[client])
	{
		g_bHaveOrigin[client] = false;
		return Plugin_Continue;
	}

	new MoveType:mt = GetEntityMoveType(client);
	if (mt == MOVETYPE_NOCLIP || mt == MOVETYPE_LADDER || mt == MOVETYPE_OBSERVER)
	{
		g_bHaveOrigin[client] = false;
		return Plugin_Continue;
	}

	decl Float:origin[3];
	GetClientAbsOrigin(client, origin);

	if (!g_bHaveOrigin[client])
	{
		g_vPrevOrigin[client][0] = origin[0];
		g_vPrevOrigin[client][1] = origin[1];
		g_vPrevOrigin[client][2] = origin[2];
		g_bHaveOrigin[client] = true;
		return Plugin_Continue;
	}

	new Float:dist = GetVectorDistance(origin, g_vPrevOrigin[client]);
	g_vPrevOrigin[client][0] = origin[0];
	g_vPrevOrigin[client][1] = origin[1];
	g_vPrevOrigin[client][2] = origin[2];

	new Float:limit = FloatAbs(signedLimit);

	/* Hard teleport */
	if (signedLimit != 0.0 && dist >= limit)
	{
		g_iDetects[client]++;
		new reactN = (signedLimit > 0.0) ? 1 : -1;
		new Handle:info = CreateKeyValues("");
		KvSetNum(info, "detection", g_iDetects[client]);
		KvSetFloat(info, "distance", dist);
		if (SMAC_CheatDetected(client, Detection_TeleportHack, info) == Plugin_Continue)
		{
			SMAC_PrintAdminNotice("%t", "SMAC_TeleportDetected", client, g_iDetects[client]);
			SMAC_LogAction(client, "teleport (Detection #%i | dist=%.1f limit=%.1f)", g_iDetects[client], dist, limit);
			SMAC_UltraReact(client, 1, reactN, "Teleport Hack Detection", "SMAC_TeleportKick");
		}
		CloseHandle(info);
		g_bHaveOrigin[client] = false;
		return Plugin_Continue;
	}

	/* Fast Detect: repeated mid-range jumps (grenade boost / micro-tp). */
	if (fastReact != 0 && dist >= 400.0 && dist < 1000.0)
	{
		g_iFastStreak[client]++;
		if (g_iFastStreak[client] >= 3)
		{
			g_iFastStreak[client] = 0;
			g_iFastDet[client]++;
			new Handle:info = CreateKeyValues("");
			KvSetNum(info, "detection", g_iFastDet[client]);
			KvSetFloat(info, "distance", dist);
			if (SMAC_CheatDetected(client, Detection_TeleportFast, info) == Plugin_Continue)
			{
				SMAC_PrintAdminNotice("%t", "SMAC_TeleportFastDetected", client, g_iFastDet[client]);
				SMAC_LogAction(client, "teleport fast-detect (Detection #%i | dist=%.1f)", g_iFastDet[client], dist);
				SMAC_UltraReact(client, g_iFastDet[client], fastReact, "Teleport Fast Detect", "SMAC_TeleportKick");
			}
			CloseHandle(info);
		}
	}
	else if (dist < 200.0)
	{
		g_iFastStreak[client] = 0;
	}

	return Plugin_Continue;
}
