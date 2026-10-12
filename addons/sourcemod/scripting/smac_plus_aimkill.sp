#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

public Plugin:myinfo =
{
	name = "SMAC Plus: AIM_Kill",
	author = SMAC_AUTHOR,
	description = "Invisible anti-aimbot decoys (AIM_Kill) from SMAC Plus",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define SLOTS				2
#define CREATE_INTERVAL		5.0
#define COLLISION_GROUP_IN_VEHICLE	10
#define SOLID_BBOX			2
#define SOLID_VPHYSICS		6
#define DECOY_EXTENT		89.9

new String:g_sHeadModel[] = "models/props/de_dust/du_crate_64x64_stone.mdl";
new String:g_sPosModels[][] =
{
	"models/weapons/w_grenade.mdl",
	"models/weapons/w_eq_flashbang.mdl",
	"models/weapons/w_eq_fraggrenade.mdl",
	"models/weapons/w_eq_smokegrenade.mdl"
};

new Handle:g_hCvarAimKill = INVALID_HANDLE;
new g_iDecoy[MAXPLAYERS+1][SLOTS];

public OnPluginStart()
{
	g_hCvarAimKill = SMAC_CreateConVar("smac_AIM_Kill", "1", "Anti-aimbot decoys: 0=off, 1=box at the face, 2=also decoy at player origin", _, true, 0.0, true, 2.0);
	HookConVarChange(g_hCvarAimKill, OnAimKillChanged);

	HookEvent("player_spawn", Event_PlayerReset, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerReset, EventHookMode_Post);

	for (new i = 0; i <= MaxClients; i++)
	{
		for (new s = 0; s < SLOTS; s++)
			g_iDecoy[i][s] = INVALID_ENT_REFERENCE;
	}

	CreateTimer(CREATE_INTERVAL, Timer_Create, _, TIMER_REPEAT);
}

public OnPluginEnd()
{
	for (new i = 1; i <= MaxClients; i++)
		RemoveDecoys(i);
}

public OnMapStart()
{
	PrecacheModel(g_sHeadModel, true);
	for (new i = 0; i < sizeof(g_sPosModels); i++)
		PrecacheModel(g_sPosModels[i], true);

	for (new i = 0; i <= MaxClients; i++)
	{
		for (new s = 0; s < SLOTS; s++)
			g_iDecoy[i][s] = INVALID_ENT_REFERENCE;
	}
}

public OnClientDisconnect(client)
{
	RemoveDecoys(client);
}

public OnAimKillChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	new level = GetConVarInt(g_hCvarAimKill);
	for (new i = 1; i <= MaxClients; i++)
	{
		if (level <= 0)
			RemoveDecoys(i);
		else if (level < 2)
			RemoveDecoy(i, 1);
	}
}

public Event_PlayerReset(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
		RemoveDecoys(client);
}

public Action:Timer_Create(Handle:timer)
{
	new level = GetConVarInt(g_hCvarAimKill);
	if (level <= 0)
		return Plugin_Continue;

	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || IsClientObserver(i))
			continue;

		if (EntRefToEntIndex(g_iDecoy[i][0]) == -1)
			CreateDecoy(i, 0);

		if (level >= 2 && EntRefToEntIndex(g_iDecoy[i][1]) == -1)
			CreateDecoy(i, 1);
	}
	return Plugin_Continue;
}

CreateDecoy(client, slot)
{
	new ent = CreateEntityByName("prop_dynamic_override");
	if (ent <= MaxClients || !IsValidEntity(ent))
		return;

	DispatchKeyValue(ent, "model", (slot == 0) ? g_sHeadModel : g_sPosModels[GetRandomInt(0, sizeof(g_sPosModels) - 1)]);
	DispatchKeyValue(ent, "disablereceiveshadows", "1");
	DispatchKeyValue(ent, "disableshadows", "1");

	if (!DispatchSpawn(ent))
	{
		AcceptEntityInput(ent, "Kill");
		return;
	}

	SetEntProp(ent, Prop_Send, "m_nSolidType", (slot == 0) ? SOLID_VPHYSICS : SOLID_BBOX);
	SetEntProp(ent, Prop_Send, "m_CollisionGroup", COLLISION_GROUP_IN_VEHICLE);
	SetEntityRenderMode(ent, RENDER_NONE);
	SetEntityRenderColor(ent, 0, 0, 0, 0);
	SetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity", client);
	ActivateEntity(ent);

	decl Float:pos[3];
	if (slot == 0)
		pos[0] = pos[1] = pos[2] = 0.0;
	else
		GetClientAbsOrigin(client, pos);
	TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);

	decl Float:mins[3], Float:maxs[3];
	mins[0] = mins[1] = mins[2] = -DECOY_EXTENT;
	maxs[0] = maxs[1] = maxs[2] = DECOY_EXTENT;
	SetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
	SetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);

	if (slot == 0)
	{
		SetVariantString("!activator");
		AcceptEntityInput(ent, "SetParent", client, ent);

		SetVariantString("forward");
		AcceptEntityInput(ent, "SetParentAttachment", ent, ent);
		DispatchKeyValue(ent, "angles", "120 35 35");
	}

	g_iDecoy[client][slot] = EntIndexToEntRef(ent);
}

RemoveDecoys(client)
{
	for (new s = 0; s < SLOTS; s++)
		RemoveDecoy(client, s);
}

RemoveDecoy(client, slot)
{
	new ent = EntRefToEntIndex(g_iDecoy[client][slot]);
	if (ent > MaxClients && IsValidEntity(ent))
		AcceptEntityInput(ent, "Kill");
	g_iDecoy[client][slot] = INVALID_ENT_REFERENCE;
}
