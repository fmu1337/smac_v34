#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Triggerbot Detector
 *
 * Original module by Danyas for SMAC v34.
 * Idea inspired by CowAC's "tick-perfect shot on target acquire"
 * check (Cheat-Acid GRAB / Cow Anti Cheat) — rewritten from scratch
 * with clearer first-tick logic for old SourcePawn / CSS v34.
 */

public Plugin:myinfo =
{
	name = "SMAC: Triggerbot Detector",
	author = SMAC_AUTHOR,
	description = "Detects tick-perfect triggerbot fire on target acquire",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarBan = INVALID_HANDLE;
new Handle:g_hCvarThreshold = INVALID_HANDLE;

new g_iTicksOnTarget[MAXPLAYERS+1];
new g_iPerfectShots[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarBan = SMAC_CreateConVar("smac_triggerbot_ban", "0", "Triggerbot detections before ban. (0 = Never ban)", _, true, 0.0);
	g_hCvarThreshold = SMAC_CreateConVar("smac_triggerbot_shots", "8", "Tick-perfect first-contact shots needed for one detection.", _, true, 4.0);

	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);
}

public OnClientPutInServer(client)
{
	g_iTicksOnTarget[client] = 0;
	g_iPerfectShots[client] = 0;
	g_iDetects[client] = 0;
	g_iPrevButtons[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_iTicksOnTarget[client] = 0;
		g_fIgnoreUntil[client] = GetGameTime() + 1.5;
	}
}

public Teleport_OnEndTouch(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator) && IsClientConnected(activator))
	{
		g_iTicksOnTarget[activator] = 0;
		g_fIgnoreUntil[activator] = GetGameTime() + 0.5 + delay;
	}
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	if (GetGameTime() < g_fIgnoreUntil[client])
	{
		g_iPrevButtons[client] = buttons;
		g_iTicksOnTarget[client] = 0;
		return Plugin_Continue;
	}

	new bool:onEnemy = false;
	decl Float:eyePos[3];
	GetClientEyePosition(client, eyePos);

	new Handle:trace = TR_TraceRayFilterEx(eyePos, angles, MASK_SHOT, RayType_Infinite, TraceFilter_Triggerbot, client);
	if (TR_DidHit(trace))
	{
		new target = TR_GetEntityIndex(trace);
		if (IS_CLIENT(target) && IsClientInGame(target) && IsPlayerAlive(target)
			&& GetClientTeam(target) != GetClientTeam(client)
			&& GetClientTeam(client) > 1)
		{
			onEnemy = true;
		}
	}
	CloseHandle(trace);

	if (onEnemy)
	{
		g_iTicksOnTarget[client]++;

		/* Fire rising-edge on the first tick of contact = classic TB tell. */
		if ((buttons & IN_ATTACK) && !(g_iPrevButtons[client] & IN_ATTACK)
			&& g_iTicksOnTarget[client] == 1)
		{
			g_iPerfectShots[client]++;
			new need = GetConVarInt(g_hCvarThreshold);
			if (g_iPerfectShots[client] >= need)
			{
				new shots = g_iPerfectShots[client];
				g_iPerfectShots[client] = 0;
				g_iDetects[client]++;

				new Handle:info = CreateKeyValues("");
				KvSetNum(info, "detection", g_iDetects[client]);
				KvSetNum(info, "shots", shots);

				if (SMAC_CheatDetected(client, Detection_TriggerBot, info) == Plugin_Continue)
				{
					SMAC_PrintAdminNotice("%t", "SMAC_TriggerBotDetected", client, g_iDetects[client]);
					SMAC_LogAction(client, "triggerbot / tick-perfect shots (Detection #%i | shots=%i)", g_iDetects[client], shots);

					new banAt = GetConVarInt(g_hCvarBan);
					if (banAt && g_iDetects[client] >= banAt)
					{
						SMAC_LogAction(client, "was banned for triggerbot.");
						SMAC_Ban(client, "Triggerbot Detection");
					}
				}
				CloseHandle(info);
			}
		}
	}
	else
	{
		/* Break streaks when the player stops snapping perfect first-ticks. */
		if (!(buttons & IN_ATTACK) && g_iPerfectShots[client] > 0
			&& g_iTicksOnTarget[client] == 0)
		{
			/* keep count across brief off-target frames */
		}
		g_iTicksOnTarget[client] = 0;
	}

	g_iPrevButtons[client] = buttons;
	return Plugin_Continue;
}

public bool:TraceFilter_Triggerbot(entity, mask, any:data)
{
	if (entity == data)
		return false;
	if (IS_CLIENT(entity))
		return true;
	return true;
}
