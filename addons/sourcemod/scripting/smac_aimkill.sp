#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Aim-Kill escalate
 *
 * Original module by Danyas for SMAC v34.
 * Ultr@-style AIM_Kill idea: headshot/kill with almost zero track time
 * after a recent aim-perfect fire (escalate soft detections).
 */

public Plugin:myinfo =
{
	name = "SMAC: Aim Kill",
	author = SMAC_AUTHOR,
	description = "Escalate suspiciously instant aim kills",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarBan = INVALID_HANDLE;

new Float:g_fFirstSee[MAXPLAYERS+1];
new Float:g_fLastAimSnap[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];
new g_iTicksOnTarget[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");
	g_hCvarBan = SMAC_CreateConVar("smac_AIM_Kill", "0", "Aim-kill reaction. 0=notice-only path soft, -N=kick, +N=ban", _, true, -100.0, true, 100.0);

	HookEvent("player_death", Event_Death, EventHookMode_Post);
	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
}

public OnClientPutInServer(client)
{
	g_fFirstSee[client] = 0.0;
	g_fLastAimSnap[client] = 0.0;
	g_iDetects[client] = 0;
	g_iPrevButtons[client] = 0;
	g_iTicksOnTarget[client] = 0;
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_fFirstSee[client] = 0.0;
		g_iTicksOnTarget[client] = 0;
	}
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	decl Float:eyePos[3];
	GetClientEyePosition(client, eyePos);
	new Handle:trace = TR_TraceRayFilterEx(eyePos, angles, MASK_SHOT, RayType_Infinite, TraceFilter_AimKill, client);
	new bool:onEnemy = false;
	if (TR_DidHit(trace))
	{
		new target = TR_GetEntityIndex(trace);
		if (IS_CLIENT(target) && IsClientInGame(target) && IsPlayerAlive(target)
			&& GetClientTeam(target) != GetClientTeam(client) && GetClientTeam(client) > 1)
		{
			onEnemy = true;
		}
	}
	CloseHandle(trace);

	if (onEnemy)
	{
		if (g_iTicksOnTarget[client] == 0)
			g_fFirstSee[client] = GetGameTime();
		g_iTicksOnTarget[client]++;

		new bool:edge = (buttons & IN_ATTACK) && !(g_iPrevButtons[client] & IN_ATTACK);
		if (edge && g_iTicksOnTarget[client] <= 2)
			g_fLastAimSnap[client] = GetGameTime();
	}
	else
	{
		g_iTicksOnTarget[client] = 0;
		g_fFirstSee[client] = 0.0;
	}

	g_iPrevButtons[client] = buttons;
	return Plugin_Continue;
}

public bool:TraceFilter_AimKill(entity, contentsMask, any:client)
{
	return entity != client;
}

public Event_Death(Handle:event, const String:name[], bool:dontBroadcast)
{
	new victim = GetClientOfUserId(GetEventInt(event, "userid"));
	new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	if (!IS_CLIENT(attacker) || attacker == victim || !IsClientInGame(attacker) || IsFakeClient(attacker))
		return;

	new Float:now = GetGameTime();
	/* Instant kill after aim-snap fire within 150ms, first-see < 80ms. */
	if (g_fLastAimSnap[attacker] <= 0.0 || (now - g_fLastAimSnap[attacker]) > 0.15)
		return;
	if (g_fFirstSee[attacker] <= 0.0 || (now - g_fFirstSee[attacker]) > 0.08)
		return;

	g_iDetects[attacker]++;
	new reaction = GetConVarInt(g_hCvarBan);
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iDetects[attacker]);
	if (SMAC_CheatDetected(attacker, Detection_AimKill, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_AimKillDetected", attacker, g_iDetects[attacker]);
		SMAC_LogAction(attacker, "aim-kill (Detection #%i)", g_iDetects[attacker]);
		SMAC_UltraReact(attacker, g_iDetects[attacker], reaction, "Aim Kill Detection", "SMAC_AimKillKick");
	}
	CloseHandle(info);
}
