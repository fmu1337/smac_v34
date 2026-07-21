#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Fire Macro / Fast AIM
 *
 * Original module by Danyas for SMAC v34.
 * Inspired by SMAC Ultra smac_method_2X_* and smac_Fast_AIM_Detect_* —
 * ATTACK2 spam on weapons that should not fire with +attack2, and
 * blink-aim snaps immediately followed by a shot.
 */

public Plugin:myinfo =
{
	name = "SMAC: Fire Macro / Fast AIM",
	author = SMAC_AUTHOR,
	description = "Detects +attack2 fire macros and snap-to-fire aim",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define ATK2_NEED		24
#define SNAP_DEG		40.0
#define SNAP_TICKS		4

new Handle:g_hCvarAtk2Ban = INVALID_HANDLE;
new Handle:g_hCvarFastBan = INVALID_HANDLE;
new Handle:g_hCvarAtk2 = INVALID_HANDLE;
new Handle:g_hCvarFast = INVALID_HANDLE;

new g_iAtk2Edges[MAXPLAYERS+1];
new Float:g_fAtk2Window[MAXPLAYERS+1];
new g_iAtk2Det[MAXPLAYERS+1];

new Float:g_fPrevAng[MAXPLAYERS+1][3];
new bool:g_bHaveAng[MAXPLAYERS+1];
new g_iSnapLeft[MAXPLAYERS+1];
new g_iFastDet[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];

new Handle:g_hZoomWeapons = INVALID_HANDLE;

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarAtk2 = SMAC_CreateConVar("smac_fire_attack2", "1", "Detect +attack2 spam on non-zoom weapons (Ultra 2X).", _, true, 0.0, true, 1.0);
	g_hCvarAtk2Ban = SMAC_CreateConVar("smac_fire_attack2_ban", "0", "2X detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarFast = SMAC_CreateConVar("smac_fast_aim", "1", "Detect large aim snaps followed by fire.", _, true, 0.0, true, 1.0);
	g_hCvarFastBan = SMAC_CreateConVar("smac_fast_aim_ban", "0", "Fast-AIM detections before ban. (0 = Never)", _, true, 0.0);

	g_hZoomWeapons = CreateTrie();
	SetTrieValue(g_hZoomWeapons, "weapon_awp", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_scout", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_sg550", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_g3sg1", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_knife", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_usp", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_m4a1", 1); /* silencer */
	SetTrieValue(g_hZoomWeapons, "weapon_hegrenade", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_flashbang", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_smokegrenade", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_c4", 1);
}

public OnClientPutInServer(client)
{
	ResetClient(client);
}

public OnClientDisconnect(client)
{
	ResetClient(client);
}

ResetClient(client)
{
	g_iAtk2Edges[client] = 0;
	g_fAtk2Window[client] = 0.0;
	g_iAtk2Det[client] = 0;
	g_bHaveAng[client] = false;
	g_iSnapLeft[client] = 0;
	g_iFastDet[client] = 0;
	g_iPrevButtons[client] = 0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	if (GetConVarBool(g_hCvarAtk2))
		CheckAttack2Macro(client, buttons);

	if (GetConVarBool(g_hCvarFast))
		CheckFastAim(client, buttons, angles);

	g_iPrevButtons[client] = buttons;
	return Plugin_Continue;
}

CheckAttack2Macro(client, buttons)
{
	if (!((buttons & IN_ATTACK2) && !(g_iPrevButtons[client] & IN_ATTACK2)))
		return;

	new ent = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (ent <= MaxClients || !IsValidEdict(ent))
		return;

	decl String:cls[64], dummy;
	GetEdictClassname(ent, cls, sizeof(cls));
	if (GetTrieValue(g_hZoomWeapons, cls, dummy))
		return;

	new Float:now = GetGameTime();
	if (g_fAtk2Window[client] <= 0.0 || now - g_fAtk2Window[client] > 1.0)
	{
		g_fAtk2Window[client] = now;
		g_iAtk2Edges[client] = 0;
	}

	g_iAtk2Edges[client]++;
	if (g_iAtk2Edges[client] < ATK2_NEED)
		return;

	g_iAtk2Edges[client] = 0;
	g_iAtk2Det[client]++;
	FireDetect(client, Detection_Attack2Macro, g_iAtk2Det[client], g_hCvarAtk2Ban,
		"SMAC_Attack2MacroDetected", "attack2 fire macro (2X)");
}

CheckFastAim(client, buttons, const Float:angles[3])
{
	if (!g_bHaveAng[client])
	{
		g_fPrevAng[client][0] = angles[0];
		g_fPrevAng[client][1] = angles[1];
		g_bHaveAng[client] = true;
		return;
	}

	/* Dropped usercmds concatenate view movement into one big delta —
	   legit flick during a rate dip reads as a snap. Skip while lagging. */
	if (SMAC_IsClientLagging(client))
	{
		g_fPrevAng[client][0] = angles[0];
		g_fPrevAng[client][1] = angles[1];
		g_iSnapLeft[client] = 0;
		return;
	}

	new Float:dpitch = FloatAbs(angles[0] - g_fPrevAng[client][0]);
	new Float:dyaw = FloatAbs(angles[1] - g_fPrevAng[client][1]);
	if (dyaw > 180.0)
		dyaw = 360.0 - dyaw;

	g_fPrevAng[client][0] = angles[0];
	g_fPrevAng[client][1] = angles[1];

	if (dyaw >= SNAP_DEG || dpitch >= SNAP_DEG)
		g_iSnapLeft[client] = SNAP_TICKS;
	else if (g_iSnapLeft[client] > 0)
		g_iSnapLeft[client]--;

	if (g_iSnapLeft[client] <= 0)
		return;
	if (!((buttons & IN_ATTACK) && !(g_iPrevButtons[client] & IN_ATTACK)))
		return;

	g_iSnapLeft[client] = 0;
	g_iFastDet[client]++;
	FireDetect(client, Detection_FastAim, g_iFastDet[client], g_hCvarFastBan,
		"SMAC_FastAimDetected", "fast aim snap-to-fire");
}

FireDetect(client, DetectionType:type, detects, Handle:hBanCvar, const String:phrase[], const String:logTag[])
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", detects);
	if (SMAC_CheatDetected(client, type, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", phrase, client, detects);
		SMAC_LogAction(client, "%s (Detection #%i)", logTag, detects);
		new banAt = GetConVarInt(hBanCvar);
		if (banAt && detects >= banAt)
		{
			SMAC_LogAction(client, "was banned for %s.", logTag);
			SMAC_Ban(client, "Fire Macro / Fast AIM Detection");
		}
	}
	CloseHandle(info);
}
