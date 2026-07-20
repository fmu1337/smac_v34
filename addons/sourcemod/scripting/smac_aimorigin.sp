#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Aim Origin Consistency
 *
 * Detection logic ported from "2x Anti-Aimbot Source" by simoneaolson
 * via Cheat-Acid GRAB: https://github.com/DJPlaya/Cheat-Acid
 *   → GRAB/2x Anti-Aimbot Source/sm_2x-AntiAimbot.sp
 * Flags clients whose bullet impact→victim origin distance stays
 * nearly identical across consecutive hits (classic aimbot pattern).
 * Time-between-victims check intentionally omitted (high FP).
 */

public Plugin:myinfo =
{
	name = "SMAC: Aim Origin Consistency",
	author = "simoneaolson, Danyas",
	description = "Detects consistent bullet-impact origin aimbots (from 2xAA via Cheat-Acid)",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarEnabled = INVALID_HANDLE;
new Handle:g_hCvarConsistency = INVALID_HANDLE;
new Handle:g_hCvarThreshold = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;

new Float:g_fDistanceFirst[MAXPLAYERS+1];
new g_iImpactPass[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarEnabled = SMAC_CreateConVar("smac_aimorigin_enabled", "1", "Enable consistent impact-origin aimbot detection.", _, true, 0.0, true, 1.0);
	g_hCvarConsistency = SMAC_CreateConVar("smac_aimorigin_consistency", "4", "Consecutive consistent hits required (MIN 3).", _, true, 3.0, true, 10.0);
	g_hCvarThreshold = SMAC_CreateConVar("smac_aimorigin_threshold", "1.98", "Max distance delta (inches) to count as consistent.", _, true, 0.1);
	g_hCvarBan = SMAC_CreateConVar("smac_aimorigin_ban", "0", "Detections before ban. (0 = Never ban)", _, true, 0.0);

	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
}

public OnClientPutInServer(client)
{
	g_fDistanceFirst[client] = 0.0;
	g_iImpactPass[client] = 0;
	g_iDetects[client] = 0;
}

public OnClientDisconnect(client)
{
	g_fDistanceFirst[client] = 0.0;
	g_iImpactPass[client] = 0;
}

public Event_PlayerHurt(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (!GetConVarBool(g_hCvarEnabled))
		return;

	new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	new victim = GetClientOfUserId(GetEventInt(event, "userid"));

	if (!IS_CLIENT(attacker) || !IS_CLIENT(victim) || attacker == victim)
		return;
	if (!IsClientInGame(attacker) || !IsClientInGame(victim) || IsFakeClient(attacker))
		return;

	decl String:weaponName[32];
	GetEventString(event, "weapon", weaponName, sizeof(weaponName));
	if (StrEqual(weaponName, "knife", false)
		|| StrEqual(weaponName, "hegrenade", false)
		|| StrEqual(weaponName, "flashbang", false)
		|| StrEqual(weaponName, "smokegrenade", false))
		return;

	decl Float:vOrigin[3], Float:vAngles[3], Float:impactOrigin[3], Float:victimOrigin[3];
	GetClientEyePosition(attacker, vOrigin);
	GetClientEyeAngles(attacker, vAngles);

	new Handle:trace = TR_TraceRayFilterEx(vOrigin, vAngles, MASK_SHOT, RayType_Infinite, TraceRayDontHitSelf, attacker);
	if (!TR_DidHit(trace))
	{
		CloseHandle(trace);
		return;
	}
	TR_GetEndPosition(impactOrigin, trace);
	CloseHandle(trace);

	GetClientAbsOrigin(victim, victimOrigin);
	new Float:distance = GetVectorDistance(impactOrigin, victimOrigin, false);
	new Float:distanceAbs = FloatAbs(distance - g_fDistanceFirst[attacker]);

	new Float:thresh = GetConVarFloat(g_hCvarThreshold);
	new need = GetConVarInt(g_hCvarConsistency);

	if (g_iImpactPass[attacker] == 0 || distanceAbs > thresh)
	{
		g_iImpactPass[attacker] = 1;
		g_fDistanceFirst[attacker] = distance;
		return;
	}

	g_iImpactPass[attacker]++;
	if (g_iImpactPass[attacker] < need)
		return;

	g_iImpactPass[attacker] = 0;
	g_fDistanceFirst[attacker] = distance;
	g_iDetects[attacker]++;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iDetects[attacker]);
	KvSetFloat(info, "distance", distance);
	KvSetFloat(info, "delta", distanceAbs);
	KvSetString(info, "weapon", weaponName);

	if (SMAC_CheatDetected(attacker, Detection_AimOriginConsistency, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_AimOriginDetected", attacker, g_iDetects[attacker]);
		SMAC_LogAction(attacker, "consistent bullet impact origin (Detection #%i | dist=%.2f delta=%.3f weapon=%s)", g_iDetects[attacker], distance, distanceAbs, weaponName);

		new banAt = GetConVarInt(g_hCvarBan);
		if (banAt && g_iDetects[attacker] >= banAt)
		{
			SMAC_LogAction(attacker, "was banned for aim origin consistency.");
			SMAC_Ban(attacker, "Aim Origin Consistency");
		}
	}
	CloseHandle(info);
}

public bool:TraceRayDontHitSelf(entity, mask, any:data)
{
	return entity != data;
}
