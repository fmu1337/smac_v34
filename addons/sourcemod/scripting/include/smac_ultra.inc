#if defined _smac_ultra_included
  #endinput
#endif
#define _smac_ultra_included

/*
 * Shared framework for the SMAC Ultr@ R52 ports (smac_u_*.sp).
 *
 * Mirrors the common logic recovered from 001_SMAC_Global.smx (docs/R52_DECODED.md §0):
 *   - per-client usercmd history: cmdnum, client tickcount, server tick, buttons, angles;
 *   - pre-filter for angle/tick detectors: cmdnum is sequential, tickcount moved,
 *     no +use, not just spawned/teleported, connection and server not lagging;
 *   - punishment gate: latency < 150 ms and avg incoming packets > 70% of tickrate
 *     (R52: 46.2 pkt/s on 66 tick). Below that, detections are logged but never punished;
 *   - admins with ADMFLAG_BAN/ROOT are never punished (R52: GetUserFlagBits >= 8);
 *   - Ultr@ cvar semantics: Warning N = notify admins from the N-th detection,
 *     Ban +N = ban after N, -N = kick after N, 0 = detector disabled;
 *     reaction cvars: 0 = off, 1 = notice, 2 = kick, 3 = ban.
 *
 * Every plugin that includes this file gets its own copy of the state below.
 * Call Ultra_OnPluginStart() from OnPluginStart() and Ultra_ResetClient() from
 * OnClientPutInServer(); call Ultra_StoreCmd() at the end of OnPlayerRunCmd().
 */

#include <sdktools>

#define ULTRA_MAX_PING			0.15
#define ULTRA_MIN_PACKET_FRAC	0.7
#define ULTRA_SPAWN_GRACE		1.0
#define ULTRA_TELEPORT_GRACE	0.5

new g_iUPrevCmd[MAXPLAYERS+1];
new g_iUPrevTick[MAXPLAYERS+1];
new g_iUPrevSrvTick[MAXPLAYERS+1];
new g_iUPrevButtons[MAXPLAYERS+1];
new Float:g_fUPrevAng[MAXPLAYERS+1][3];
new bool:g_bUHasPrev[MAXPLAYERS+1];
new Float:g_fUIgnoreUntil[MAXPLAYERS+1];

new Handle:g_hUltraAdminImmune = INVALID_HANDLE;

stock Ultra_OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hUltraAdminImmune = SMAC_CreateConVar("smac_ultra_admin_immune", "1", "Ultr@ ports: never kick/ban admins with ban/root flag (still logged).", _, true, 0.0, true, 1.0);

	HookEvent("player_spawn", Ultra_Event_PlayerSpawn, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnStartTouch", Ultra_Output_Teleport);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Ultra_Output_Teleport);
}

public Ultra_Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_bUHasPrev[client] = false;
		Ultra_Ignore(client, ULTRA_SPAWN_GRACE);
	}
}

public Ultra_Output_Teleport(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator))
	{
		Ultra_Ignore(activator, ULTRA_TELEPORT_GRACE + delay);
	}
}

stock Ultra_ResetClient(client)
{
	g_iUPrevCmd[client] = 0;
	g_iUPrevTick[client] = 0;
	g_iUPrevSrvTick[client] = 0;
	g_iUPrevButtons[client] = 0;
	g_fUPrevAng[client][0] = 0.0;
	g_fUPrevAng[client][1] = 0.0;
	g_fUPrevAng[client][2] = 0.0;
	g_bUHasPrev[client] = false;
	g_fUIgnoreUntil[client] = 0.0;
}

stock Ultra_Ignore(client, Float:seconds)
{
	new Float:until = GetGameTime() + seconds;
	if (until > g_fUIgnoreUntil[client])
		g_fUIgnoreUntil[client] = until;
}

stock bool:Ultra_IsIgnored(client)
{
	return GetGameTime() < g_fUIgnoreUntil[client];
}

/* Alive human player that is actually playing (not spectating). */
stock bool:Ultra_IsPlaying(client)
{
	return IS_CLIENT(client) && IsClientInGame(client) && !IsFakeClient(client)
		&& IsPlayerAlive(client) && !IsClientObserver(client);
}

/* R52 pre-filter: previous cmd known, cmdnum strictly sequential, tickcount moved. */
stock bool:Ultra_IsSequential(client, cmdnum, tickcount)
{
	return g_bUHasPrev[client]
		&& cmdnum == g_iUPrevCmd[client] + 1
		&& tickcount != g_iUPrevTick[client];
}

/* Movement types where player angles/velocity are not under normal control. */
stock bool:Ultra_IsSpecialMove(client)
{
	new MoveType:mt = GetEntityMoveType(client);
	if (mt == MOVETYPE_NOCLIP || mt == MOVETYPE_LADDER || mt == MOVETYPE_NONE || mt == MOVETYPE_OBSERVER)
		return true;

	new flags = GetEntityFlags(client);
	return (flags & (FL_FROZEN | FL_ATCONTROLS)) != 0;
}

/* True while either side is lagging; angle/tick history is unreliable then. */
stock bool:Ultra_IsLagging(client)
{
	return SMAC_IsClientLagging(client);
}

stock Ultra_StoreCmd(client, buttons, const Float:angles[3], cmdnum, tickcount)
{
	g_iUPrevCmd[client] = cmdnum;
	g_iUPrevTick[client] = tickcount;
	g_iUPrevSrvTick[client] = GetGameTickCount();
	g_iUPrevButtons[client] = buttons;
	g_fUPrevAng[client][0] = angles[0];
	g_fUPrevAng[client][1] = angles[1];
	g_fUPrevAng[client][2] = angles[2];
	g_bUHasPrev[client] = true;
}

/* |a - b| wrapped into [0, 180]. */
stock Float:Ultra_AngleDiff(Float:a, Float:b)
{
	new Float:d = FloatAbs(a - b);
	while (d > 360.0)
		d -= 360.0;
	if (d > 180.0)
		d = 360.0 - d;
	return d;
}

/* Angle wrapped into [-180, 180). */
stock Float:Ultra_NormalizeAngle(Float:a)
{
	while (a >= 180.0)
		a -= 360.0;
	while (a < -180.0)
		a += 360.0;
	return a;
}

/* R52 punishment gate (network quality). */
stock bool:Ultra_NetOk(client)
{
	if (GetClientLatency(client, NetFlow_Outgoing) >= ULTRA_MAX_PING)
		return false;

	new Float:minPackets = ULTRA_MIN_PACKET_FRAC / GetTickInterval();
	return GetClientAvgPackets(client, NetFlow_Incoming) > minPackets;
}

stock bool:Ultra_IsImmune(client)
{
	if (g_hUltraAdminImmune == INVALID_HANDLE || !GetConVarBool(g_hUltraAdminImmune))
		return false;

	return (GetUserFlagBits(client) & (ADMFLAG_BAN | ADMFLAG_ROOT)) != 0;
}

/* Trace from the eyes along the cmd angles; returns the hit player or 0. */
stock Ultra_TraceAimTarget(client, const Float:angles[3])
{
	decl Float:vEye[3];
	GetClientEyePosition(client, vEye);

	new Handle:tr = TR_TraceRayFilterEx(vEye, angles, MASK_SHOT, RayType_Infinite, Ultra_TraceFilterSelf, client);
	new target = 0;
	if (TR_DidHit(tr))
	{
		new ent = TR_GetEntityIndex(tr);
		if (IS_CLIENT(ent) && ent != client)
			target = ent;
	}
	CloseHandle(tr);
	return target;
}

public bool:Ultra_TraceFilterSelf(entity, contentsMask, any:client)
{
	return entity != client;
}

/*
 * Report one detection with Ultr@ Warning/Ban semantics.
 *   count  - per-client detection counter (incremented here)
 *   warn   - admins are notified from this detection on (0 = never)
 *   ban    - +N ban / -N kick after N detections (0 = never punish)
 * Returns true if the client was kicked or banned.
 */
stock bool:Ultra_Report(client, DetectionType:type, Handle:info, &count, warn, ban, const String:name[], const String:detail[])
{
	count++;

	if (info != INVALID_HANDLE)
		KvSetNum(info, "detection", count);

	if (SMAC_CheatDetected(client, type, info) != Plugin_Continue)
		return false;

	SMAC_LogAction(client, "%s (Detection #%i) %s", name, count, detail);

	if (warn > 0 && count >= warn)
		SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, name, count);

	if (ban == 0 || Ultra_IsImmune(client))
		return false;

	if (!Ultra_NetOk(client))
	{
		SMAC_LogAction(client, "%s: punishment skipped (bad connection: ping %.0f ms, %.1f pkt/s).",
			name,
			GetClientLatency(client, NetFlow_Outgoing) * 1000.0,
			GetClientAvgPackets(client, NetFlow_Incoming));
		return false;
	}

	decl String:sReason[128];
	FormatEx(sReason, sizeof(sReason), "%s Detection", name);
	return SMAC_UltraReact(client, count, ban, sReason, "SMAC_UltraKick");
}

/*
 * Report with a reaction-level cvar (0 = off, 1 = notice, 2 = kick, 3 = ban),
 * acting on the first detection like R52 (Airstuck, Eyetest, FD_BHOP).
 */
stock bool:Ultra_ReportLevel(client, DetectionType:type, Handle:info, &count, level, const String:name[], const String:detail[])
{
	new ban = 0;
	if (level == 2)
		ban = -1;
	else if (level >= 3)
		ban = 1;

	return Ultra_Report(client, type, info, count, (level >= 1) ? 1 : 0, ban, name, detail);
}
