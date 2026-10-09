#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC Ultr@ R52 port: client input rate and settings.
 *
 * Rewritten from 001_SMAC_Global.smx of SMAC Ultr@ R52 as decompiled with
 * tools/r52re/decomp.py (docs/R52_SPEC.md §0.1, §5, §8a; docs/ULTRA_CLIENT.md).
 * No Ultr@ code and no Ultr@Tools extension is used.
 *
 *   Impulse spam      more than smac_css_Impulse cmds with an impulse in one second.
 *   Sensitivity       outside [1; 20] (R52 kicks), and more than |smac_antispam_Mouse_Sensitivity|
 *                     changes in one map (queried once a minute).
 *   FakeSendPacket[Max]  more than ceil(tickrate * smac_SpeedUp) usercmds per second (counts 4
 *                     for >= 2x tickrate) for more than |smac_SpeedLimitDetect| seconds in a row.
 *   FakeSendPacket[Min]  fewer than round(tickrate * 0.2) usercmds per second for more than
 *                     2 * |smac_SpeedLimitDetect| seconds in a row.
 *                     Both are ignored when the client sends <= 25 packets/s either way, or when
 *                     its outgoing data and packets are both > 2.9x the incoming (R52 gates).
 *
 * Signed cvars keep the R52 meaning (+N ban, -N kick); smac_ultra_client_notice_only (default 1)
 * turns every punishment of this module into an admin notice.
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: Client",
	author = SMAC_AUTHOR,
	description = "Impulse spam, sensitivity checks and FakeSendPacket (usercmd rate) from SMAC Ultr@ R52",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define SENS_MIN			1.0
#define SENS_MAX			20.0
#define QUERY_INTERVAL		60.0

#define RATE_MIN_FRAC		0.2
#define RATE_HEAVY_FRAC		2.0
#define RATE_HEAVY_ADD		3
#define GATE_MIN_PACKETS	25.0
#define GATE_ASYMMETRY		2.9

#define MAX_PING			0.15
#define MIN_PACKET_FRAC		0.7

new Handle:g_hCvarImpulse = INVALID_HANDLE;
new Handle:g_hCvarSensLimits = INVALID_HANDLE;
new Handle:g_hCvarSensChanges = INVALID_HANDLE;
new Handle:g_hCvarSpeedUp = INVALID_HANDLE;
new Handle:g_hCvarSpeedLimit = INVALID_HANDLE;
new Handle:g_hCvarNoticeOnly = INVALID_HANDLE;
new Handle:g_hCvarAdminImmune = INVALID_HANDLE;

new g_iImpulses[MAXPLAYERS+1];
new g_iCmds[MAXPLAYERS+1];
new g_iRateHigh[MAXPLAYERS+1];
new g_iRateLow[MAXPLAYERS+1];

new Float:g_fSens[MAXPLAYERS+1];
new g_iSensChanges[MAXPLAYERS+1];
new bool:g_bSensReported[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarImpulse = SMAC_CreateConVar("smac_css_Impulse", "12", "Max cmds with an impulse (flashlight, spray, ...) per second before a kick. (0 = off)", _, true, 0.0, true, 100.0);
	g_hCvarSensLimits = SMAC_CreateConVar("smac_ultra_sensitivity_limits", "1", "Sensitivity outside [1; 20]: 0=off, 1=admin notice, 2=kick (R52: kick)", _, true, 0.0, true, 2.0);
	g_hCvarSensChanges = SMAC_CreateConVar("smac_antispam_Mouse_Sensitivity", "-5", "Sensitivity changes per map: +N = ban, -N = kick after more than N changes, 0 = off", _, true, -100.0, true, 100.0);
	g_hCvarSpeedUp = SMAC_CreateConVar("smac_SpeedUp", "1.2", "FakeSendPacket[Max]: allowed usercmds per second as a multiple of the tickrate. (0 = off)", _, true, 0.0, true, 3.0);
	g_hCvarSpeedLimit = SMAC_CreateConVar("smac_SpeedLimitDetect", "-7", "FakeSendPacket: +N = ban, -N = kick after more than N seconds over the limit (2N seconds under it), 0 = off", _, true, -100.0, true, 100.0);
	g_hCvarNoticeOnly = SMAC_CreateConVar("smac_ultra_client_notice_only", "1", "Only notify admins instead of the kick/ban set by the cvars of smac_ultra_client.", _, true, 0.0, true, 1.0);
	g_hCvarAdminImmune = SMAC_CreateConVar("smac_ultra_admin_immune", "1", "Never kick/ban admins with ban/root flag (detections are still logged).", _, true, 0.0, true, 1.0);

	CreateTimer(1.0, Timer_Second, _, TIMER_REPEAT);
	CreateTimer(QUERY_INTERVAL, Timer_QueryAll, _, TIMER_REPEAT);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
}

public OnClientPutInServer(client)
{
	g_iImpulses[client] = 0;
	g_iCmds[client] = 0;
	g_iRateHigh[client] = 0;
	g_iRateLow[client] = 0;
	g_fSens[client] = 0.0;
	g_iSensChanges[client] = 0;
	g_bSensReported[client] = false;

	if (!IsFakeClient(client))
		QueryClientConVar(client, "sensitivity", Query_Sensitivity);
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (IsFakeClient(client))
		return Plugin_Continue;

	g_iCmds[client]++;

	new limit = GetConVarInt(g_hCvarImpulse);
	if (impulse > 0 && limit > 0 && ++g_iImpulses[client] > limit)
	{
		g_iImpulses[client] = 0;

		decl String:sDetail[64];
		FormatEx(sDetail, sizeof(sDetail), "more than %i impulses in 1 s (last %i)", limit, impulse);
		React(client, "Impulse Spam", -1, sDetail);
	}

	return Plugin_Continue;
}

/**
 * Sensitivity (R52 query callback).
 */
public Action:Timer_QueryAll(Handle:timer)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			QueryClientConVar(i, "sensitivity", Query_Sensitivity);
	}
	return Plugin_Continue;
}

public Query_Sensitivity(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[])
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || result != ConVarQuery_Okay)
		return;

	new Float:sens = StringToFloat(cvarValue);
	decl String:sDetail[64];

	if (sens < SENS_MIN || sens > SENS_MAX)
	{
		/* Reported once per connection; the value is queried every minute. */
		new level = GetConVarInt(g_hCvarSensLimits);
		if (level > 0 && !g_bSensReported[client])
		{
			g_bSensReported[client] = true;
			FormatEx(sDetail, sizeof(sDetail), "sensitivity %.3f outside [%.0f; %.0f]", sens, SENS_MIN, SENS_MAX);
			React(client, "Sensitivity", (level >= 2) ? -1 : 0, sDetail);
		}
		return;
	}

	/* R52 counts every value that differs from the previous answer. */
	new changes = GetConVarInt(g_hCvarSensChanges);
	if (g_fSens[client] > 0.0 && sens != g_fSens[client] && changes != 0)
	{
		if (++g_iSensChanges[client] > AbsValue(changes))
		{
			g_iSensChanges[client] = 0;
			FormatEx(sDetail, sizeof(sDetail), "sensitivity changed more than %i times (%.3f -> %.3f)", AbsValue(changes), g_fSens[client], sens);
			g_fSens[client] = sens;
			React(client, "Sensitivity Change Spam", changes, sDetail);
			return;
		}
	}
	g_fSens[client] = sens;
}

/**
 * Usercmd rate (R52 OnTimerUp: SpeedLimit / FakeSendPacket).
 */
public Action:Timer_Second(Handle:timer)
{
	new Float:speedUp = GetConVarFloat(g_hCvarSpeedUp);
	new limit = GetConVarInt(g_hCvarSpeedLimit);
	new Float:tickrate = 1.0 / GetTickInterval();
	new maxCmds = RoundToCeil(tickrate * speedUp);
	new minCmds = RoundToNearest(tickrate * RATE_MIN_FRAC);
	new heavyCmds = RoundToNearest(tickrate * RATE_HEAVY_FRAC);

	for (new i = 1; i <= MaxClients; i++)
	{
		new cmds = g_iCmds[i];
		g_iCmds[i] = 0;
		g_iImpulses[i] = 0;

		if (!IS_CLIENT(i) || !IsClientInGame(i) || IsFakeClient(i))
			continue;

		if (speedUp <= 0.0 || limit == 0 || IsClientTimingOut(i))
		{
			g_iRateHigh[i] = g_iRateLow[i] = 0;
			continue;
		}

		if (cmds > maxCmds)
		{
			g_iRateLow[i] = 0;
			if (cmds >= heavyCmds)
				g_iRateHigh[i] += RATE_HEAVY_ADD;

			if (++g_iRateHigh[i] > AbsValue(limit))
			{
				g_iRateHigh[i] = 0;
				CheckSendPacket(i, true, cmds, limit);
			}
		}
		else if (cmds < minCmds)
		{
			g_iRateHigh[i] = 0;
			if (++g_iRateLow[i] > 2 * AbsValue(limit))
			{
				g_iRateLow[i] = 0;
				CheckSendPacket(i, false, cmds, limit);
			}
		}
		else
		{
			g_iRateHigh[i] = g_iRateLow[i] = 0;
		}
	}
	return Plugin_Continue;
}

/* R52 fn_2d84: a real connection problem shows up in the packet and data rates. */
CheckSendPacket(client, bool:bMax, cmds, limit)
{
	new Float:dataOut = GetClientAvgData(client, NetFlow_Outgoing);
	new Float:dataIn = GetClientAvgData(client, NetFlow_Incoming);
	new Float:pktOut = GetClientAvgPackets(client, NetFlow_Outgoing);
	new Float:pktIn = GetClientAvgPackets(client, NetFlow_Incoming);

	if (dataIn > 0.0 && pktIn > 0.0 && dataOut / dataIn > GATE_ASYMMETRY && pktOut / pktIn > GATE_ASYMMETRY)
		return;

	if (pktOut <= GATE_MIN_PACKETS || pktIn <= GATE_MIN_PACKETS)
		return;

	decl String:sDetail[128];
	FormatEx(sDetail, sizeof(sDetail), "%i usercmds/s (packets in %.1f, out %.1f)", cmds, pktIn, pktOut);
	React(client, bMax ? "FakeSendPacket[Max]" : "FakeSendPacket[Min]", limit, sDetail);
}

/**
 * Reaction: sign > 0 ban, < 0 kick, 0 admin notice.
 */
React(client, const String:name[], sign, const String:detail[])
{
	new action = 1;
	if (sign > 0)
		action = 3;
	else if (sign < 0)
		action = 2;

	if (GetConVarBool(g_hCvarNoticeOnly) || (action > 1 && IsImmune(client)))
		action = 1;

	new lowered = LowerAction(client, action);
	if (lowered != action)
	{
		SMAC_LogAction(client, "%s: action lowered %i -> %i (avg ping %.0f ms, %.1f pkt/s).",
			name, action, lowered,
			GetClientAvgLatency(client, NetFlow_Outgoing) * 1000.0,
			GetClientAvgPackets(client, NetFlow_Incoming));
		action = lowered;
	}

	new Handle:info = CreateKeyValues("");
	KvSetString(info, "check", name);
	KvSetString(info, "detail", detail);
	new Action:result = SMAC_CheatDetected(client, Detection_UltraClient, info);
	CloseHandle(info);

	if (result != Plugin_Continue)
		return;

	SMAC_LogAction(client, "%s | %s", name, detail);
	SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, name, 1);

	if (action == 3)
	{
		SMAC_LogAction(client, "was banned for %s.", name);
		SMAC_Ban(client, "%s Detection", name);
	}
	else if (action == 2)
	{
		SMAC_LogAction(client, "was kicked for %s.", name);
		KickClient(client, "%t", "SMAC_UltraKick");
	}
}

bool:IsImmune(client)
{
	return GetConVarBool(g_hCvarAdminImmune) && (GetUserFlagBits(client) & (ADMFLAG_BAN | ADMFLAG_ROOT)) != 0;
}

/* R52 network gate: lower ban -> kick -> notice once for bad ping and once for few packets. */
LowerAction(client, action)
{
	if (action > 1 && GetClientAvgLatency(client, NetFlow_Outgoing) >= MAX_PING)
		action--;

	if (action > 1 && GetClientAvgPackets(client, NetFlow_Incoming) <= MIN_PACKET_FRAC / GetTickInterval())
		action--;

	return action;
}
