#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Teleport / Tick-Move
 *
 * Original module by Danyas for SMAC v34.
 * Inspired by SMAC Ultra smac_SpeedTeleport — flags sudden origin jumps
 * larger than a threshold in one tick (teleport hacks / grenade boost abuse).
 */

public Plugin:myinfo =
{
	name = "SMAC: Teleport Detector",
	author = SMAC_AUTHOR,
	description = "Detects impossible per-tick origin jumps",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarDist = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;

new Float:g_vPrevOrigin[MAXPLAYERS+1][3];
new bool:g_bHaveOrigin[MAXPLAYERS+1];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	/* Negative = kick after abs value; positive = ban; 0 = off (Ultra style). Default off. */
	g_hCvarDist = SMAC_CreateConVar("smac_teleport_dist", "0.0", "Max units/tick before detect. 0=off. Use ~1000-1500 on pub CSS.", _, true, 0.0);
	g_hCvarBan = SMAC_CreateConVar("smac_teleport_ban", "2", "Detections before ban. (0 = Never ban, kick-only if dist set)", _, true, 0.0);

	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);
}

public OnClientPutInServer(client)
{
	g_bHaveOrigin[client] = false;
	g_iDetects[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_bHaveOrigin[client] = false;
		g_fIgnoreUntil[client] = GetGameTime() + 2.0;
	}
}

public Teleport_OnEndTouch(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator) && IsClientConnected(activator))
	{
		g_bHaveOrigin[activator] = false;
		g_fIgnoreUntil[activator] = GetGameTime() + 0.75 + delay;
	}
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	new Float:limit = GetConVarFloat(g_hCvarDist);
	if (limit <= 0.0)
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
		g_vPrevOrigin[client] = origin;
		g_bHaveOrigin[client] = true;
		return Plugin_Continue;
	}

	new Float:dist = GetVectorDistance(origin, g_vPrevOrigin[client]);
	g_vPrevOrigin[client] = origin;

	if (dist < limit)
		return Plugin_Continue;

	g_iDetects[client]++;
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iDetects[client]);
	KvSetFloat(info, "distance", dist);

	if (SMAC_CheatDetected(client, Detection_TeleportHack, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_TeleportDetected", client, g_iDetects[client]);
		SMAC_LogAction(client, "teleport / tick-move (Detection #%i | dist=%.1f limit=%.1f)", g_iDetects[client], dist, limit);

		new banAt = GetConVarInt(g_hCvarBan);
		if (banAt && g_iDetects[client] >= banAt)
		{
			SMAC_LogAction(client, "was banned for teleport hack.");
			SMAC_Ban(client, "Teleport Hack Detection");
		}
		else
		{
			KickClient(client, "%t", "SMAC_TeleportKick");
		}
	}
	CloseHandle(info);
	g_bHaveOrigin[client] = false;
	return Plugin_Continue;
}
