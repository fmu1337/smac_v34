#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: No Spam Weapon (drop spam)
 *
 * Original module by Danyas for SMAC v34.
 * Ultr@ smac_NoSpamWeapon_MaxW: count weapon drops; signed reaction
 * (0=off, -N=kick after N, +N=ban after N). Soft default 0.
 */

public Plugin:myinfo =
{
	name = "SMAC: No Spam Weapon",
	author = SMAC_AUTHOR,
	description = "Ultr@ weapon-drop spam control",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarMaxW = INVALID_HANDLE;

new g_iDrops[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarMaxW = SMAC_CreateConVar("smac_NoSpamWeapon_MaxW", "0", "Weapon drop spam. 0=off, -N=kick after N, +N=ban after N", _, true, -100.0, true, 100.0);

	AddCommandListener(Command_Drop, "drop");
}

public OnClientPutInServer(client)
{
	g_iDrops[client] = 0;
	g_iDetects[client] = 0;
}

public OnClientDisconnect(client)
{
	g_iDrops[client] = 0;
	g_iDetects[client] = 0;
}

public Action:Command_Drop(client, const String:command[], argc)
{
	if (IS_CLIENT(client) && IsClientInGame(client) && !IsFakeClient(client) && IsPlayerAlive(client))
		NoteDrop(client);
	return Plugin_Continue;
}

NoteDrop(client)
{
	new signedMax = GetConVarInt(g_hCvarMaxW);
	if (signedMax == 0)
		return;

	new need = signedMax;
	if (need < 0)
		need = -need;
	if (need < 2)
		need = 2;

	g_iDrops[client]++;
	if (g_iDrops[client] < need)
		return;

	g_iDrops[client] = 0;
	g_iDetects[client]++;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iDetects[client]);
	KvSetNum(info, "threshold", need);
	if (SMAC_CheatDetected(client, Detection_WeaponSpam, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_WeaponSpamDetected", client, g_iDetects[client]);
		SMAC_LogAction(client, "weapon-drop spam (Detection #%i | need=%i)", g_iDetects[client], need);
		SMAC_UltraReact(client, g_iDetects[client], signedMax, "Weapon Spam Detection", "SMAC_WeaponSpamKick");
	}
	CloseHandle(info);
}
