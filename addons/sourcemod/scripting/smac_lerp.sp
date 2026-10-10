#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * Interpolation (lerp) checks, after Little Anti-Cheat (lilac_nolerp, lilac_max_lerp).
 *
 * The server keeps every player's interpolation time in m_fLerpTime and lag compensation
 * rewinds targets by tickcount - lerp. So:
 *
 *   NoLerp   - m_fLerpTime below one update interval (1 / sv_maxupdaterate). A normal client
 *              cannot get there (cl_interp_ratio >= 1 keeps lerp >= 1 / cl_updaterate), so it
 *              means a tampered client. LilAC bans on the first one.
 *   Max lerp - m_fLerpTime above smac_lerp_max ms. That is a legit setting (cl_interp 0.2+),
 *              but it widens the lag compensation window: the player shoots where enemies were.
 *              LilAC kicks for it; here it is notice or kick, never ban.
 *
 * smac_lerp_fix clamps m_fLerpTime into [1 / sv_maxupdaterate, smac_lerp_max] on every
 * attack cmd, before lag compensation reads it. The engine only rewrites m_fLerpTime when
 * the client changes its settings, and the client's own interpolation is not touched.
 *
 * Defaults: admin notice only, fix on.
 */

public Plugin:myinfo =
{
	name = "SMAC: Lerp Checks",
	author = SMAC_AUTHOR,
	description = "NoLerp and max lerp checks and lerp clamp, after Little Anti-Cheat",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define CHECK_INTERVAL	2.0
#define MIN_LERP_BUFFER	0.95

new Handle:g_hCvarNoLerp = INVALID_HANDLE;
new Handle:g_hCvarMaxLerp = INVALID_HANDLE;
new Handle:g_hCvarMaxLerpReaction = INVALID_HANDLE;
new Handle:g_hCvarFix = INVALID_HANDLE;
new Handle:g_hCvarAdminImmune = INVALID_HANDLE;
new Handle:g_hCvarMaxUpdateRate = INVALID_HANDLE;

new Float:g_fReportedNoLerp[MAXPLAYERS+1];
new Float:g_fReportedMaxLerp[MAXPLAYERS+1];
new g_iNoLerpDetects[MAXPLAYERS+1];
new g_iMaxLerpDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarNoLerp = SMAC_CreateConVar("smac_lerp_reaction", "1", "NoLerp (m_fLerpTime below 1 / sv_maxupdaterate, a tampered client): 0=off, 1=admin notice, 2=kick, 3=ban (LilAC: ban)", _, true, 0.0, true, 3.0);
	g_hCvarMaxLerp = SMAC_CreateConVar("smac_lerp_max", "105", "Max lerp in ms. Above it the player gets the lag compensation of this value. (0 = no limit)", _, true, 0.0, true, 1000.0);
	g_hCvarMaxLerpReaction = SMAC_CreateConVar("smac_lerp_max_reaction", "1", "Lerp above smac_lerp_max: 0=off, 1=admin notice, 2=kick (LilAC: kick)", _, true, 0.0, true, 2.0);
	g_hCvarFix = SMAC_CreateConVar("smac_lerp_fix", "1", "Clamp m_fLerpTime into [1 / sv_maxupdaterate, smac_lerp_max] before lag compensation. 0=off, 1=on", _, true, 0.0, true, 1.0);
	g_hCvarAdminImmune = SMAC_CreateConVar("smac_ultra_admin_immune", "1", "Never kick/ban admins with ban/root flag (detections are still logged).", _, true, 0.0, true, 1.0);

	g_hCvarMaxUpdateRate = FindConVar("sv_maxupdaterate");

	CreateTimer(CHECK_INTERVAL, Timer_Check, _, TIMER_REPEAT);
}

public OnClientPutInServer(client)
{
	g_fReportedNoLerp[client] = -1.0;
	g_fReportedMaxLerp[client] = -1.0;
	g_iNoLerpDetects[client] = 0;
	g_iMaxLerpDetects[client] = 0;
}

Float:GetMinLerp()
{
	if (g_hCvarMaxUpdateRate == INVALID_HANDLE)
		return 0.0;

	new Float:rate = GetConVarFloat(g_hCvarMaxUpdateRate);
	if (rate <= 0.0)
		return 0.0;

	return 1.0 / rate;
}

Float:GetMaxLerp()
{
	return GetConVarFloat(g_hCvarMaxLerp) / 1000.0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!(buttons & (IN_ATTACK | IN_ATTACK2)) || !GetConVarBool(g_hCvarFix))
		return Plugin_Continue;

	if (!IS_CLIENT(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	new Float:lerp = GetEntPropFloat(client, Prop_Data, "m_fLerpTime");
	new Float:minLerp = GetMinLerp();
	new Float:maxLerp = GetMaxLerp();

	if (minLerp > 0.0 && lerp < minLerp * MIN_LERP_BUFFER)
		SetEntPropFloat(client, Prop_Data, "m_fLerpTime", minLerp);
	else if (maxLerp > 0.0 && lerp > maxLerp)
		SetEntPropFloat(client, Prop_Data, "m_fLerpTime", maxLerp);

	return Plugin_Continue;
}

public Action:Timer_Check(Handle:timer)
{
	new Float:minLerp = GetMinLerp();
	new Float:maxLerp = GetMaxLerp();
	new noLerpLevel = GetConVarInt(g_hCvarNoLerp);
	new maxLerpLevel = GetConVarInt(g_hCvarMaxLerpReaction);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		new Float:lerp = GetEntPropFloat(i, Prop_Data, "m_fLerpTime");

		/* LilAC skips a minimum below 5 ms (sv_maxupdaterate > 200): too close to call. */
		if (noLerpLevel > 0 && minLerp >= 0.005 && lerp < minLerp * MIN_LERP_BUFFER)
		{
			if (lerp != g_fReportedNoLerp[i])
			{
				g_fReportedNoLerp[i] = lerp;

				new Handle:info = CreateKeyValues("");
				KvSetFloat(info, "lerp", lerp);
				KvSetFloat(info, "min", minLerp);

				decl String:sDetail[96];
				FormatEx(sDetail, sizeof(sDetail), "lerp %.1f ms, min %.1f ms", lerp * 1000.0, minLerp * 1000.0);
				Report(i, info, g_iNoLerpDetects[i], noLerpLevel, "NoLerp", sDetail);
				CloseHandle(info);
			}
		}
		else if (maxLerpLevel > 0 && maxLerp > 0.0 && lerp > maxLerp)
		{
			if (lerp != g_fReportedMaxLerp[i])
			{
				g_fReportedMaxLerp[i] = lerp;

				new Handle:info = CreateKeyValues("");
				KvSetFloat(info, "lerp", lerp);
				KvSetFloat(info, "max", maxLerp);

				decl String:sDetail[96];
				FormatEx(sDetail, sizeof(sDetail), "lerp %.1f ms, max %.1f ms", lerp * 1000.0, maxLerp * 1000.0);
				Report(i, info, g_iMaxLerpDetects[i], maxLerpLevel, "Max Lerp", sDetail);
				CloseHandle(info);
			}
		}
	}

	return Plugin_Continue;
}

bool:IsImmune(client)
{
	return GetConVarBool(g_hCvarAdminImmune) && (GetUserFlagBits(client) & (ADMFLAG_BAN | ADMFLAG_ROOT)) != 0;
}

/* level: 1 = notice, 2 = kick, 3 = ban. */
Report(client, Handle:info, &count, level, const String:name[], const String:detail[])
{
	count++;
	KvSetNum(info, "detection", count);

	if (SMAC_CheatDetected(client, Detection_Lerp, info) != Plugin_Continue)
		return;

	SMAC_LogAction(client, "%s (Detection #%i) %s", name, count, detail);
	SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, name, count);

	if (level < 2 || IsImmune(client))
		return;

	if (level >= 3)
	{
		SMAC_LogAction(client, "was banned for %s.", name);
		SMAC_Ban(client, "%s Detection", name);
	}
	else
	{
		SMAC_LogAction(client, "was kicked for %s.", name);
		KickClient(client, "%t", "SMAC_LerpKick");
	}
}
