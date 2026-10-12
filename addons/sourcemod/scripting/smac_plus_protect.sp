#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smac>

public Plugin:myinfo =
{
	name = "SMAC Plus: Protect",
	author = SMAC_AUTHOR,
	description = "No_Team_Flash and Control_Entity",
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
	g_hCvarNoTeamFlash = SMAC_CreateConVar("smac_No_Team_Flash", "0", "Flashbangs: 0=normal, 1=skip thrower's teammates, 2=T never blinded, 3=CT never blinded", _, true, 0.0, true, 3.0);
	g_hCvarControlEntity = SMAC_CreateConVar("smac_Control_Entity", "1", "Reload map if entity index > 2003 (engine limit 2048): 0=off, 1=on", _, true, 0.0, true, 1.0);

	HookEvent("flashbang_detonate", Event_FlashDetonate, EventHookMode_Post);
	HookEvent("player_blind", Event_PlayerBlind, EventHookMode_Post);
}

public OnMapStart()
{
	g_iFlashThrower = -1;
	g_iMaxEntity = 0;
	g_bRestarting = false;
}

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

	if (mode >= 2 && GetClientTeam(client) != mode)
		return;

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
