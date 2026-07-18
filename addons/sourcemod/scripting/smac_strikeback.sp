#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>
#undef REQUIRE_PLUGIN
#include <smac_wallhack>
#define REQUIRE_PLUGIN

/*
 * SMAC: Strike Back
 *
 * Original module by Danyas for SMAC v34.
 * Idea from SMAC Ultra (Ultr@) "Strike Back" detectors that only arm when
 * anti-wallhack is active: knife/gun damage against a victim the wallhack
 * currently hides from the attacker. Algorithms reconstructed from Ultra
 * R51/R52 configs + phrases (no Ultra source available — packed .smx).
 */

public Plugin:myinfo =
{
	name = "SMAC: Strike Back",
	author = SMAC_AUTHOR,
	description = "Detects knife/aim through SMAC wallhack hide (Ultra-inspired)",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarKnifeBan = INVALID_HANDLE;
new Handle:g_hCvarKnifeWarn = INVALID_HANDLE;
new Handle:g_hCvarAimBan = INVALID_HANDLE;
new Handle:g_hCvarAimWarn = INVALID_HANDLE;
new Handle:g_hCvarMinDist = INVALID_HANDLE;

new bool:g_bWallhackNative = false;
new g_iKnifeDet[MAXPLAYERS+1];
new g_iAimDet[MAXPLAYERS+1];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarKnifeWarn = SMAC_CreateConVar("smac_knifebot_wh_warn", "1", "KnifeBot-through-WH detections before admin notice. (0 = silent)", _, true, 0.0);
	g_hCvarKnifeBan = SMAC_CreateConVar("smac_knifebot_wh_ban", "2", "KnifeBot-through-WH detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarAimWarn = SMAC_CreateConVar("smac_aim_wh_warn", "5", "Aim-through-WH detections before admin notice. (0 = silent)", _, true, 0.0);
	g_hCvarAimBan = SMAC_CreateConVar("smac_aim_wh_ban", "10", "Aim-through-WH detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarMinDist = SMAC_CreateConVar("smac_strikeback_mindist", "80.0", "Min attacker→victim distance for gun Strike Back (skip point-blank).", _, true, 0.0);

	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
}

public OnAllPluginsLoaded()
{
	g_bWallhackNative = (GetFeatureStatus(FeatureType_Native, "SMAC_IsClientVisible") == FeatureStatus_Available);
}

public OnLibraryAdded(const String:name[])
{
	if (StrEqual(name, "smac_wallhack"))
		g_bWallhackNative = (GetFeatureStatus(FeatureType_Native, "SMAC_IsClientVisible") == FeatureStatus_Available);
}

public OnLibraryRemoved(const String:name[])
{
	if (StrEqual(name, "smac_wallhack"))
		g_bWallhackNative = false;
}

public OnClientPutInServer(client)
{
	g_iKnifeDet[client] = 0;
	g_iAimDet[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
		g_fIgnoreUntil[client] = GetGameTime() + 1.5;
}

public Event_PlayerHurt(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (!g_bWallhackNative)
		return;

	new victim = GetClientOfUserId(GetEventInt(event, "userid"));
	new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	if (!IS_CLIENT(victim) || !IS_CLIENT(attacker) || victim == attacker)
		return;
	if (!IsClientInGame(victim) || !IsClientInGame(attacker) || IsFakeClient(attacker))
		return;
	if (GetGameTime() < g_fIgnoreUntil[attacker] || GetGameTime() < g_fIgnoreUntil[victim])
		return;
	if (GetClientTeam(victim) == GetClientTeam(attacker))
		return;

	/* If wallhack already transmits the victim, no Strike Back signal. */
	if (SMAC_IsClientVisible(attacker, victim))
		return;

	decl String:weapon[32];
	GetEventString(event, "weapon", weapon, sizeof(weapon));

	if (StrContains(weapon, "knife", false) != -1)
	{
		g_iKnifeDet[attacker]++;
		MaybeFire(attacker, Detection_KnifeBotWH, g_iKnifeDet[attacker],
			g_hCvarKnifeWarn, g_hCvarKnifeBan,
			"SMAC_KnifeBotWHDetected", "knifebot through wallhack");
		return;
	}

	/* Guns / other weapons: require distance so we don't flag smoke fights. */
	if (StrEqual(weapon, "hegrenade", false) || StrEqual(weapon, "flashbang", false)
		|| StrEqual(weapon, "smokegrenade", false))
		return;

	decl Float:vA[3], Float:vV[3];
	GetClientAbsOrigin(attacker, vA);
	GetClientAbsOrigin(victim, vV);
	if (GetVectorDistance(vA, vV) < GetConVarFloat(g_hCvarMinDist))
		return;

	g_iAimDet[attacker]++;
	MaybeFire(attacker, Detection_AimThroughWH, g_iAimDet[attacker],
		g_hCvarAimWarn, g_hCvarAimBan,
		"SMAC_AimThroughWHDetected", "aim/damage through wallhack");
}

MaybeFire(client, DetectionType:type, detection, Handle:hWarn, Handle:hBan, const String:phrase[], const String:logName[])
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", detection);

	if (SMAC_CheatDetected(client, type, info) == Plugin_Continue)
	{
		new warnAt = GetConVarInt(hWarn);
		if (warnAt && detection >= warnAt)
			SMAC_PrintAdminNotice("%t", phrase, client, detection);

		SMAC_LogAction(client, "%s (Detection #%i)", logName, detection);

		new banAt = GetConVarInt(hBan);
		if (banAt && detection >= banAt)
		{
			SMAC_LogAction(client, "was banned for %s.", logName);
			SMAC_Ban(client, "%s Detection", logName);
		}
	}
	CloseHandle(info);
}
