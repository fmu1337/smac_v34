#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smac>

/*
 * SMAC Ultr@ R52 port: server-side protections from 001_SMAC_Global.
 *
 * Rewritten from the R52 decompile (tools/r52re/decomp.py; docs/ULTRA_PROTECT.md).
 * No Ultr@ code and no Ultr@Tools extension is used.
 *
 *   No_Team_Flash   1 = a flashbang does not blind the thrower's teammates;
 *                   2 / 3 = players of team 2 (T) / 3 (CT) are never blinded.
 *                   R52 remembers the thrower on flashbang_detonate and, 0.005 s after
 *                   player_blind, sets m_flFlashMaxAlpha to 0.5 (the blind is not drawn).
 *   Control_Entity  1 = when an entity with index > 2003 is created (the engine limit is 2048),
 *                   log it and reload the map before the server crashes.
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: Protect",
	author = SMAC_AUTHOR,
	description = "No_Team_Flash and Control_Entity from SMAC Ultr@ R52",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define FLASH_DELAY			0.005
#define FLASH_NO_ALPHA		0.5
#define ENTITY_LIMIT		2003
#define MAX_EDICTS_INDEX	2048
#define RESTART_DELAY		1.0

new Handle:g_hCvarNoTeamFlash = INVALID_HANDLE;
new Handle:g_hCvarControlEntity = INVALID_HANDLE;

new g_iFlashThrower = -1;
new g_iMaxEntity;
new bool:g_bRestarting;

public OnPluginStart()
{
	g_hCvarNoTeamFlash = SMAC_CreateConVar("smac_No_Team_Flash", "0", "Flashbangs: 0=normal, 1=do not blind the thrower's teammates, 2=team T is never blinded, 3=team CT is never blinded (R52: 0)", _, true, 0.0, true, 3.0);
	g_hCvarControlEntity = SMAC_CreateConVar("smac_Control_Entity", "1", "Reload the map when an entity index above 2003 is created (the limit is 2048): 0=off, 1=on (R52: 1)", _, true, 0.0, true, 1.0);

	HookEvent("flashbang_detonate", Event_FlashDetonate, EventHookMode_Post);
	HookEvent("player_blind", Event_PlayerBlind, EventHookMode_Post);
}

public OnMapStart()
{
	g_iFlashThrower = -1;
	g_iMaxEntity = 0;
	g_bRestarting = false;
}

/**
 * No_Team_Flash
 */
public Event_FlashDetonate(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	g_iFlashThrower = (IS_CLIENT(client) && IsClientInGame(client)) ? client : -1;
}

public Event_PlayerBlind(Handle:event, const String:name[], bool:dontBroadcast)
{
	new mode = GetConVarInt(g_hCvarNoTeamFlash);
	if (mode <= 0)
		return;

	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (!IS_CLIENT(client) || !IsClientInGame(client))
		return;

	/* 2 / 3: that team is never blinded. */
	if (mode >= 2 && GetClientTeam(client) != mode)
		return;

	/* player_blind can come before flashbang_detonate; R52 judges a moment later. */
	CreateTimer(FLASH_DELAY, Timer_Unblind, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_Unblind(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (!IS_CLIENT(client) || !IsClientInGame(client))
		return Plugin_Stop;

	new mode = GetConVarInt(g_hCvarNoTeamFlash);
	if (mode == 1)
	{
		new thrower = g_iFlashThrower;
		if (thrower == -1 || thrower == client || !IsClientInGame(thrower) || GetClientTeam(thrower) != GetClientTeam(client))
			return Plugin_Stop;
	}
	else if (mode < 2 || GetClientTeam(client) != mode)
	{
		return Plugin_Stop;
	}

	SetEntPropFloat(client, Prop_Send, "m_flFlashMaxAlpha", FLASH_NO_ALPHA);
	return Plugin_Stop;
}

/**
 * Control_Entity
 */
public OnEntityCreated(entity, const String:classname[])
{
	if (entity <= MaxClients || entity >= MAX_EDICTS_INDEX || entity <= g_iMaxEntity)
		return;

	g_iMaxEntity = entity;
	if (g_iMaxEntity <= ENTITY_LIMIT || g_bRestarting || !GetConVarBool(g_hCvarControlEntity))
		return;

	g_bRestarting = true;
	SMAC_Log("Reached a maximum in the creation of entity, Max:%i, Already Created:%i! Map restart!", MAX_EDICTS_INDEX, g_iMaxEntity);
	CreateTimer(RESTART_DELAY, Timer_Restart, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_Restart(Handle:timer)
{
	decl String:sMap[PLATFORM_MAX_PATH];
	GetCurrentMap(sMap, sizeof(sMap));
	ForceChangeLevel(sMap, "SMAC: entity limit reached");
	return Plugin_Stop;
}
