#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC Ultr@ R52 port: usercmd / netcode detectors.
 *
 * Rewritten from the logic recovered from 001_SMAC_Global.smx of SMAC Ultr@ R52
 * (docs/ULTRA_NETCODE.md). No Ultr@ code and no Ultr@Tools extension is used.
 *
 *   Airstuck        - cmdnum advances by 1 but the client tickcount repeats while the
 *                     player is active (buttons / mouse / angles). 6 in a row = stage,
 *                     2 stages within 5 s = detection.
 *   Lag Exploit     - the server processes one cmd per tick and cmdnum advances
 *                     normally (+1..11), but the client tickcount jumps forward > 11.
 *                     More than 5 jumps (gaps < 5 s) = detection.
 *   Backtrack B     - cmdnum goes backwards (out-of-order / replayed usercmds).
 *                     More than 22 (gaps < 10 s) = detection.
 *   PSilent Active  - the shot usercmd was choked: it is processed in the same server
 *                     frame as the next cmd, while the cmd before it was not.
 *                     3 shots in a row = detection.
 *
 * Common R52 rules:
 *   - nothing is judged right after spawn / trigger_teleport, while the client has
 *     loss/choke/ping spikes or while the server itself hitches;
 *   - kick/ban only with ping < 150 ms and > 70% of tickrate packets from the client
 *     (R52: 46.2 pkt/s on 66 tick); otherwise the detection is only logged;
 *   - admins with ban/root flag are never punished (still logged).
 *
 * Cvars keep the Ultr@ names. Defaults are admin-notice only.
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: Netcode",
	author = SMAC_AUTHOR,
	description = "Airstuck, Lag Exploit, Backtrack B and PSilent (choke-on-shot) from SMAC Ultr@ R52",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define AIRSTUCK_STREAK		6
#define AIRSTUCK_STAGES		2
#define AIRSTUCK_STAGE_TTL	5.0

#define LAG_MAX_CMD_STEP	11
#define LAG_MIN_TICK_STEP	11
#define LAG_EVENTS			5
#define LAG_EVENT_TTL		5.0

#define BACKTRACK_EVENTS	22
#define BACKTRACK_EVENT_TTL	10.0

#define PSILENT_STREAK		3
#define BATCH_EMA_ALPHA		0.02
#define BATCH_EMA_MAX		0.05
#define BATCH_EMA_START		0.1

#define SPAWN_GRACE			1.0
#define TELEPORT_GRACE		0.5

#define MAX_PING			0.15
#define MIN_PACKET_FRAC		0.7

#define LAG_MAX_LOSS		0.05
#define LAG_MAX_CHOKE		0.30
#define LAG_MAX_PING_SPIKE	0.10

new Handle:g_hCvarAirstuck = INVALID_HANDLE;
new Handle:g_hCvarLag = INVALID_HANDLE;
new Handle:g_hCvarBacktrack = INVALID_HANDLE;
new Handle:g_hCvarPSilentWarn = INVALID_HANDLE;
new Handle:g_hCvarPSilentBan = INVALID_HANDLE;
new Handle:g_hCvarAdminImmune = INVALID_HANDLE;

/* Previous usercmd. */
new bool:g_bHasPrev[MAXPLAYERS+1];
new g_iPrevCmd[MAXPLAYERS+1];
new g_iPrevTick[MAXPLAYERS+1];
new Float:g_fPrevAng[MAXPLAYERS+1][2];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];

/* Server tick at which each of the last three cmds was processed ([0] = newest). */
new g_iSrvHist[MAXPLAYERS+1][3];
new Float:g_fBatchEma[MAXPLAYERS+1];

new g_iAirStreak[MAXPLAYERS+1];
new g_iAirStage[MAXPLAYERS+1];
new Float:g_fAirStageTime[MAXPLAYERS+1];
new g_iAirDetects[MAXPLAYERS+1];

new g_iLagEvents[MAXPLAYERS+1];
new Float:g_fLagLast[MAXPLAYERS+1];
new g_iLagDetects[MAXPLAYERS+1];

new g_iBtEvents[MAXPLAYERS+1];
new Float:g_fBtLast[MAXPLAYERS+1];
new g_iBtDetects[MAXPLAYERS+1];

new bool:g_bShotArmed[MAXPLAYERS+1];
new g_iPSilentStreak[MAXPLAYERS+1];
new g_iPSilentDetects[MAXPLAYERS+1];

/* Server hitch detector: a stalled server batches/replays everyone's usercmds. */
new Float:g_fPrevFrameTime;
new Float:g_fFrameEma;
new Float:g_fServerLagUntil;

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarAirstuck = SMAC_CreateConVar("smac_Airstuck_reaction", "1", "Airstuck: 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarLag = SMAC_CreateConVar("smac_LagExploit_reaction", "1", "Lag Exploit (tickcount shift): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarBacktrack = SMAC_CreateConVar("smac_eyetest_reaction_Advanced", "1", "Backtrack Exploit-Mode:B (cmdnum rollback): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarPSilentWarn = SMAC_CreateConVar("smac_PSilent_Warning", "1", "PSilent [Active Mode] detections before admins are notified. (0 = never)", _, true, 0.0);
	g_hCvarPSilentBan = SMAC_CreateConVar("smac_PSilent_Ban", "0", "PSilent [Active Mode] detections before punish: -N = kick, +N = ban, 0 = never (R52: -12)", _, true, -100.0, true, 100.0);
	g_hCvarAdminImmune = SMAC_CreateConVar("smac_ultra_admin_immune", "1", "Never kick/ban admins with ban/root flag (detections are still logged).", _, true, 0.0, true, 1.0);

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnStartTouch", Output_Teleport);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Output_Teleport);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
}

public OnClientPutInServer(client)
{
	g_bHasPrev[client] = false;
	g_iPrevCmd[client] = 0;
	g_iPrevTick[client] = 0;
	g_fPrevAng[client][0] = g_fPrevAng[client][1] = 0.0;
	g_fIgnoreUntil[client] = 0.0;

	g_iSrvHist[client][0] = g_iSrvHist[client][1] = g_iSrvHist[client][2] = 0;
	g_fBatchEma[client] = BATCH_EMA_START;

	g_iAirStreak[client] = 0;
	g_iAirStage[client] = 0;
	g_fAirStageTime[client] = 0.0;
	g_iAirDetects[client] = 0;

	g_iLagEvents[client] = 0;
	g_fLagLast[client] = 0.0;
	g_iLagDetects[client] = 0;

	g_iBtEvents[client] = 0;
	g_fBtLast[client] = 0.0;
	g_iBtDetects[client] = 0;

	g_bShotArmed[client] = false;
	g_iPSilentStreak[client] = 0;
	g_iPSilentDetects[client] = 0;
}

public OnGameFrame()
{
	new Float:now = GetEngineTime();
	if (g_fPrevFrameTime > 0.0)
	{
		new Float:dt = now - g_fPrevFrameTime;
		if (g_fFrameEma <= 0.0)
			g_fFrameEma = dt;

		/* Only a spike relative to the usual frame time is a hitch; a server that
		   is steadily slow must not switch detection off for the whole map. */
		if (dt > 0.050 && dt > g_fFrameEma * 3.0)
			g_fServerLagUntil = GetGameTime() + 0.5;

		if (dt > g_fFrameEma * 4.0)
			dt = g_fFrameEma * 4.0;
		g_fFrameEma += (dt - g_fFrameEma) * 0.0625;
	}
	g_fPrevFrameTime = now;
}

public Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_bHasPrev[client] = false;
		IgnoreClient(client, SPAWN_GRACE);
	}
}

public Output_Teleport(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator))
		IgnoreClient(activator, TELEPORT_GRACE + delay);
}

public Event_WeaponFire(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client) && IsClientInGame(client) && !IsFakeClient(client))
	{
		/* weapon_fire is raised while the shot cmd runs, i.e. right after its
		   OnPlayerRunCmd: g_iSrvHist[client][0] is the shot cmd. */
		g_bShotArmed[client] = true;
	}
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!IsPlaying(client))
	{
		g_bHasPrev[client] = false;
		g_bShotArmed[client] = false;
		return Plugin_Continue;
	}

	new srvTick = GetGameTickCount();
	new bool:bBatched = (g_bHasPrev[client] && srvTick == g_iSrvHist[client][0]);

	if (g_bHasPrev[client] && GetGameTime() >= g_fIgnoreUntil[client] && !IsLagging(client))
	{
		CheckPSilent(client, srvTick, bBatched);
		CheckAirstuck(client, buttons, angles, cmdnum, tickcount, mouse);
		CheckLagExploit(client, srvTick, cmdnum, tickcount);
		CheckBacktrack(client, cmdnum);
	}
	else
	{
		g_bShotArmed[client] = false;
		g_iAirStreak[client] = 0;
	}

	/* Baseline: how often this client's cmds share a server frame anyway
	   (low cl_cmdrate / fps, jitter). */
	if (g_bHasPrev[client])
		g_fBatchEma[client] += ((bBatched ? 1.0 : 0.0) - g_fBatchEma[client]) * BATCH_EMA_ALPHA;

	g_iSrvHist[client][2] = g_iSrvHist[client][1];
	g_iSrvHist[client][1] = g_iSrvHist[client][0];
	g_iSrvHist[client][0] = srvTick;

	g_iPrevCmd[client] = cmdnum;
	g_iPrevTick[client] = tickcount;
	g_fPrevAng[client][0] = angles[0];
	g_fPrevAng[client][1] = angles[1];
	g_bHasPrev[client] = true;

	return Plugin_Continue;
}

CheckAirstuck(client, buttons, const Float:angles[3], cmdnum, tickcount, const mouse[2])
{
	new level = GetConVarInt(g_hCvarAirstuck);
	if (level <= 0)
		return;

	if (cmdnum != g_iPrevCmd[client] + 1 || tickcount != g_iPrevTick[client])
	{
		g_iAirStreak[client] = 0;
		return;
	}

	new bool:bActive = (buttons != 0 || mouse[0] != 0 || mouse[1] != 0
		|| angles[0] != g_fPrevAng[client][0] || angles[1] != g_fPrevAng[client][1]);
	if (!bActive)
	{
		g_iAirStreak[client] = 0;
		return;
	}

	if (++g_iAirStreak[client] < AIRSTUCK_STREAK)
		return;

	g_iAirStreak[client] = 0;

	new Float:now = GetGameTime();
	if (now - g_fAirStageTime[client] > AIRSTUCK_STAGE_TTL)
		g_iAirStage[client] = 0;
	g_fAirStageTime[client] = now;

	if (++g_iAirStage[client] < AIRSTUCK_STAGES)
		return;

	g_iAirStage[client] = 0;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "tickcount", tickcount);
	KvSetNum(info, "cmdnum", cmdnum);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "tickcount %i frozen for %i cmds", tickcount, AIRSTUCK_STREAK * AIRSTUCK_STAGES);
	ReportLevel(client, Detection_AirStuck, info, g_iAirDetects[client], level, "Airstuck", sDetail);
	CloseHandle(info);
}

CheckLagExploit(client, srvTick, cmdnum, tickcount)
{
	new level = GetConVarInt(g_hCvarLag);
	if (level <= 0)
		return;

	/* The server processed this client's cmds one per tick (stable stream). */
	if (srvTick - g_iSrvHist[client][0] != 1
		|| g_iSrvHist[client][0] - g_iSrvHist[client][1] != 1
		|| g_iSrvHist[client][1] - g_iSrvHist[client][2] != 1)
		return;

	new cmdStep = cmdnum - g_iPrevCmd[client];
	new tickStep = tickcount - g_iPrevTick[client];
	if (cmdStep < 1 || cmdStep > LAG_MAX_CMD_STEP || tickStep <= LAG_MIN_TICK_STEP)
		return;

	new Float:now = GetGameTime();
	if (now - g_fLagLast[client] > LAG_EVENT_TTL)
		g_iLagEvents[client] = 0;
	g_fLagLast[client] = now;

	if (++g_iLagEvents[client] <= LAG_EVENTS)
		return;

	g_iLagEvents[client] = 0;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "cmd_step", cmdStep);
	KvSetNum(info, "tick_step", tickStep);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "tickcount +%i on cmdnum +%i", tickStep, cmdStep);
	ReportLevel(client, Detection_LagExploit, info, g_iLagDetects[client], level, "Lag Exploit", sDetail);
	CloseHandle(info);
}

CheckBacktrack(client, cmdnum)
{
	new level = GetConVarInt(g_hCvarBacktrack);
	if (level <= 0 || cmdnum >= g_iPrevCmd[client])
		return;

	if (GetEntityFlags(client) & (FL_FROZEN | FL_ATCONTROLS))
		return;

	new Float:now = GetGameTime();
	if (now - g_fBtLast[client] > BACKTRACK_EVENT_TTL)
		g_iBtEvents[client] = 0;
	g_fBtLast[client] = now;

	if (++g_iBtEvents[client] <= BACKTRACK_EVENTS)
		return;

	g_iBtEvents[client] = 0;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "cmdnum", cmdnum);
	KvSetNum(info, "prev_cmdnum", g_iPrevCmd[client]);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "cmdnum %i after %i", cmdnum, g_iPrevCmd[client]);
	ReportLevel(client, Detection_Backtrack, info, g_iBtDetects[client], level, "Backtrack Exploit-Mode:B", sDetail);
	CloseHandle(info);
}

CheckPSilent(client, srvTick, bool:bBatched)
{
	if (!g_bShotArmed[client])
		return;

	g_bShotArmed[client] = false;

	new warn = GetConVarInt(g_hCvarPSilentWarn);
	new ban = GetConVarInt(g_hCvarPSilentBan);
	if (warn == 0 && ban == 0)
		return;

	/* Clients that routinely send several cmds per packet are not judged. */
	if (g_fBatchEma[client] > BATCH_EMA_MAX)
		return;

	/* The shot cmd arrived together with this one, while the cmd before the
	   shot came in its own frame: the shot was choked. */
	new bool:bChoked = bBatched && g_iSrvHist[client][0] != g_iSrvHist[client][1];
	if (!bChoked)
	{
		g_iPSilentStreak[client] = 0;
		return;
	}

	if (++g_iPSilentStreak[client] < PSILENT_STREAK)
		return;

	g_iPSilentStreak[client] = 0;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "server_tick", srvTick);
	KvSetFloat(info, "batch_rate", g_fBatchEma[client]);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "%i choked shots in a row, batch rate %.3f", PSILENT_STREAK, g_fBatchEma[client]);
	Report(client, Detection_UltraPSilent, info, g_iPSilentDetects[client], warn, ban, "PSilent [Active Mode]", sDetail);
	CloseHandle(info);
}

/**
 * Helpers
 */
IgnoreClient(client, Float:seconds)
{
	new Float:until = GetGameTime() + seconds;
	if (until > g_fIgnoreUntil[client])
		g_fIgnoreUntil[client] = until;
}

bool:IsPlaying(client)
{
	return IS_CLIENT(client) && IsClientInGame(client) && !IsFakeClient(client)
		&& IsPlayerAlive(client) && !IsClientObserver(client);
}

/* Lost/choked packets, ping spikes, timeouts or a server hitch make the
   cmd stream look like tampering. */
bool:IsLagging(client)
{
	if (g_fServerLagUntil > 0.0 && GetGameTime() < g_fServerLagUntil)
		return true;

	if (IsClientTimingOut(client))
		return true;

	if (GetClientAvgLoss(client, NetFlow_Both) > LAG_MAX_LOSS)
		return true;

	if (GetClientAvgChoke(client, NetFlow_Both) > LAG_MAX_CHOKE)
		return true;

	return GetClientLatency(client, NetFlow_Outgoing) - GetClientAvgLatency(client, NetFlow_Outgoing) > LAG_MAX_PING_SPIKE;
}

/* R52 punishment gate: stable connection only. */
bool:IsNetOk(client)
{
	if (GetClientLatency(client, NetFlow_Outgoing) >= MAX_PING)
		return false;

	return GetClientAvgPackets(client, NetFlow_Incoming) > MIN_PACKET_FRAC / GetTickInterval();
}

bool:IsImmune(client)
{
	return GetConVarBool(g_hCvarAdminImmune) && (GetUserFlagBits(client) & (ADMFLAG_BAN | ADMFLAG_ROOT)) != 0;
}

/*
 * One detection with Ultr@ Warning/Ban semantics:
 *   warn - admins are notified from this detection on (0 = never)
 *   ban  - +N ban / -N kick after N detections (0 = never)
 */
Report(client, DetectionType:type, Handle:info, &count, warn, ban, const String:name[], const String:detail[])
{
	count++;
	KvSetNum(info, "detection", count);

	if (SMAC_CheatDetected(client, type, info) != Plugin_Continue)
		return;

	SMAC_LogAction(client, "%s (Detection #%i) %s", name, count, detail);

	if (warn > 0 && count >= warn)
		SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, name, count);

	if (ban == 0 || count < AbsValue(ban) || IsImmune(client))
		return;

	if (!IsNetOk(client))
	{
		SMAC_LogAction(client, "%s: punishment skipped (connection: ping %.0f ms, %.1f pkt/s).",
			name,
			GetClientLatency(client, NetFlow_Outgoing) * 1000.0,
			GetClientAvgPackets(client, NetFlow_Incoming));
		return;
	}

	if (ban > 0)
	{
		SMAC_LogAction(client, "was banned for %s.", name);
		SMAC_Ban(client, "%s Detection", name);
	}
	else
	{
		SMAC_LogAction(client, "was kicked for %s.", name);
		KickClient(client, "%t", "SMAC_UltraKick");
	}
}

/* Reaction cvar (0 = off, 1 = notice, 2 = kick, 3 = ban), acting on the first detection. */
ReportLevel(client, DetectionType:type, Handle:info, &count, level, const String:name[], const String:detail[])
{
	new ban = 0;
	if (level == 2)
		ban = -1;
	else if (level >= 3)
		ban = 1;

	Report(client, type, info, count, 1, ban, name, detail);
}
