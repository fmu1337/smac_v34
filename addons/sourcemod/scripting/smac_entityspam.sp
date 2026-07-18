#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Entity Spam Control
 *
 * Original module by Danyas for SMAC v34.
 * Inspired by SMAC Ultra smac_Control_Entity — limits rapid entity creation
 * (weapon drop spam / crash entities).
 */

public Plugin:myinfo =
{
	name = "SMAC: Entity Spam",
	author = SMAC_AUTHOR,
	description = "Limits entity creation spam",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarMode = INVALID_HANDLE;
new Handle:g_hCvarMax = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;

new g_iCreated[MAXPLAYERS+1];
new Float:g_fWindowStart[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarMode = SMAC_CreateConVar("smac_entity_mode", "1", "0=off, 1=limit creation, 2=delete spam ents, 3=both", _, true, 0.0, true, 3.0);
	g_hCvarMax = SMAC_CreateConVar("smac_entity_max", "40", "Max tracked ents created per client per 2s window.", _, true, 5.0);
	g_hCvarBan = SMAC_CreateConVar("smac_entity_ban", "0", "Detections before ban. (0 = Never — kick only)", _, true, 0.0);
}

public OnClientPutInServer(client)
{
	g_iCreated[client] = 0;
	g_fWindowStart[client] = 0.0;
	g_iDetects[client] = 0;
}

public OnEntityCreated(entity, const String:classname[])
{
	new mode = GetConVarInt(g_hCvarMode);
	if (mode <= 0 || entity < 1 || !IsValidEdict(entity))
		return;

	/* Only care about spammy client-driven classes. */
	if (!(StrContains(classname, "weapon_", false) == 0
		|| StrEqual(classname, "hegrenade_projectile", false)
		|| StrEqual(classname, "flashbang_projectile", false)
		|| StrEqual(classname, "smokegrenade_projectile", false)
		|| StrEqual(classname, "prop_physics", false)
		|| StrEqual(classname, "prop_physics_multiplayer", false)))
		return;

	new owner = GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity");
	if (!IS_CLIENT(owner) || !IsClientInGame(owner) || IsFakeClient(owner))
		return;

	new Float:now = GetGameTime();
	if (g_fWindowStart[owner] <= 0.0 || now - g_fWindowStart[owner] > 2.0)
	{
		g_fWindowStart[owner] = now;
		g_iCreated[owner] = 0;
	}

	g_iCreated[owner]++;
	new max = GetConVarInt(g_hCvarMax);
	if (g_iCreated[owner] <= max)
		return;

	if (mode == 2 || mode == 3)
	{
		if (IsValidEdict(entity))
			AcceptEntityInput(entity, "Kill");
	}

	if (mode == 1 || mode == 3)
	{
		g_iCreated[owner] = 0;
		g_iDetects[owner]++;

		new Handle:info = CreateKeyValues("");
		KvSetNum(info, "detection", g_iDetects[owner]);
		KvSetString(info, "classname", classname);

		if (SMAC_CheatDetected(owner, Detection_EntitySpam, info) == Plugin_Continue)
		{
			SMAC_PrintAdminNotice("%t", "SMAC_EntitySpamDetected", owner, g_iDetects[owner]);
			SMAC_LogAction(owner, "entity spam (Detection #%i | class=%s)", g_iDetects[owner], classname);

			new banAt = GetConVarInt(g_hCvarBan);
			if (banAt && g_iDetects[owner] >= banAt)
			{
				SMAC_LogAction(owner, "was banned for entity spam.");
				SMAC_Ban(owner, "Entity Spam Detection");
			}
			else
			{
				KickClient(owner, "%t", "SMAC_EntitySpamKick");
			}
		}
		CloseHandle(info);
	}
}
