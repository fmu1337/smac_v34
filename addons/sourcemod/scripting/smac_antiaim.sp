#pragma semicolon 0
#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <smac>

// VZYATO IZ: https://hlmod.ru/threads/cs-s-blokirovka-trassirovok-chitov-otkljuchenie-aimov-i-triggerov.44343/

new String:SPAWN_MODEL_CSS[] = "models/props/de_dust/du_crate_128x128.mdl";

new iClientBlock[MAXPLAYERS];

public Plugin:myinfo =
{
	name = "SMAC: AntiAim",
	author = "Reg1oxeN & Danyas",
	description = "ТИХО ИНТЕГРИРОВАЛ И УШЕЛ - НАЗЫВАЕТЬСЯ НАШЕЛ",
	version = SMAC_VERSION,
	url = SMAC_URL
};
new iMode = -1;
new Handle:hAntiAimMode = INVALID_HANDLE;
public OnPluginStart()
{
	hAntiAimMode = SMAC_CreateConVar("smac_aimbot_killer", "1", "0 - off, 1 - on. Breaks GetClientAimTarget() when 1.", _, true, 0.0);
	OnModeChanged(hAntiAimMode, "", "");
	HookConVarChange(hAntiAimMode, OnModeChanged);
	HookEvent("round_start", Event_RoundStart, EventHookMode_Post);
	
	PrecacheModel(SPAWN_MODEL_CSS, true);
	ActivateBlocks(true);
}

ActivateBlocks(bool:plugin_start = false)
{
	for (new client = 1; client <= MaxClients; client++)
	{
		if (plugin_start && IsClientInGame(client))
			OnClientPutInServer(client);
		
		OnSpawnPlayer(client);
	}	
}

public OnModeChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	new PrevMode = iMode;
	iMode = GetConVarInt(convar);
	
	if (PrevMode == 0 && iMode > 0)
		ActivateBlocks();
}

public Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	for (new client = 1; client <= MaxClients; client++)
	{
		OnSpawnPlayer(client);
	}
}

public Action:OnTransmitBlock(Ent, client)
{
	if (iMode > 0 && iClientBlock[client] == Ent && IsPlayerAlive(client))	
		return Plugin_Continue;
		
	return Plugin_Handled;
}

public OnPluginEnd()
{
	for (new client = 1; client <= MaxClients; client++)
	{
		if (iClientBlock[client] != 0 && IsValidEntity(iClientBlock[client]))
			AcceptEntityInput(iClientBlock[client], "Kill");
	}
}

public OnMapStart()
{	
	PrecacheModel(SPAWN_MODEL_CSS, true);
}

public OnClientPutInServer(client)
{
	iClientBlock[client] = 0;
	if (!IsFakeClient(client))
		SDKHook(client, SDKHook_SpawnPost, OnSpawnPlayer);
}

public OnSpawnPlayer(client)
{
	if (iMode > 0 && IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) > 1 && IsPlayerAlive(client))
		CreateObject(client);
}

stock CreateObject(client)
{
	if (iClientBlock[client] != 0) return;
	
	new entity = CreateEntityByName("prop_dynamic_override");
	if (entity != -1)
	{
		DispatchKeyValue(entity, "model", SPAWN_MODEL_CSS);
		if (DispatchSpawn(entity))
		{
			SetEntityRenderMode(entity, RENDER_NONE);

			SetEntProp(entity, Prop_Send, "m_fEffects", 0x010 | 0x040 | 0x001 | 0x080 | 0x008);
			
			SetEntityMoveType(entity, MOVETYPE_NONE);
			SetEntProp(entity, Prop_Send, "m_nSolidType", 1, 1);
			SetEntProp(entity, Prop_Data, "m_usSolidFlags", 0, 2);
			SetEntProp(entity, Prop_Data, "m_CollisionGroup", 10);
			
			SetVariantString("!activator");
			AcceptEntityInput(entity, "SetParent", client, entity, 0);
			SDKHook(entity, SDKHook_SetTransmit, OnTransmitBlock);
			//SendProxyInit(entity);
			
			iClientBlock[client] = entity;
		}
	}
}

public OnEntityDestroyed(entity)
{
	if (entity == 0) return;
	for (new client = 1; client <= MaxClients; client++)
	{
		if (entity == iClientBlock[client])
			iClientBlock[client] = 0;
	}
}

/*#include <sendproxy>
new Float:Default_vecMin[3];
new Float:Default_vecMax[3];
new Float:Blank_Vector[3];
stock SendProxyInit(entity)
{
	static bool:do_once = true;
	if (do_once)
	{
		GetEntPropVector(entity, Prop_Data, "m_vecMins", Default_vecMin);
		GetEntPropVector(entity, Prop_Data, "m_vecMaxs", Default_vecMax);	
		do_once = false;
	}
	
	if (!SendProxy_IsHooked(entity, "m_vecMins") && !SendProxy_Hook(entity, "m_vecMins", Prop_Vector, Hook_vecMin)) LogError("m_vecMins not hooked");
	if (!SendProxy_IsHooked(entity, "m_vecMaxs") && !SendProxy_Hook(entity, "m_vecMaxs", Prop_Vector, Hook_vecMax)) LogError("m_vecMaxs not hooked");	
}

public Action Hook_vecMin(int ent, const char[] propName, float vecValues[3], int element) {
	if (vecValues[0] != 0.0 || vecValues[1] != 0.0 || vecValues[2] != 0.0)
		SetEntPropVector(ent, Prop_Send, propName, Blank_Vector);
	
	vecValues = Default_vecMin;
	return Plugin_Changed;
}
public Action Hook_vecMax(int ent, const char[] propName, float vecValues[3], int element) {
	if (vecValues[0] != 0.0 || vecValues[1] != 0.0 || vecValues[2] != 0.0)
		SetEntPropVector(ent, Prop_Send, propName, Blank_Vector);
	
	vecValues = Default_vecMax;
	return Plugin_Changed;
}*/