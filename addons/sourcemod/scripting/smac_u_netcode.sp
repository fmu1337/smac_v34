#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>
#include <smac_ultra>

/*
 * SMAC Ultr@ R52 port: usercmd / netcode detectors.
 *
 * Logic recovered from 001_SMAC_Global.smx R52 (docs/R52_DECODED.md §2, §4):
 *   Airstuck        - cmdnum advances by 1 but the client tickcount repeats while the
 *                     player is active (buttons / mouse / angles). 6 in a row = stage,
 *                     2 stages = detection.
 *   Lag Exploit     - the server processes one cmd per tick and cmdnum advances
 *                     normally (<= 11), but the client tickcount jumps forward > 11.
 *                     More than 5 such jumps = detection.
 *   Backtrack B     - cmdnum goes backwards (out-of-order / replayed usercmds).
 *                     More than 22 = detection.
 *   PSilent Active  - the shot usercmd was choked: it is processed in the same server
 *                     frame as the next cmd, while the cmd before it was not.
 *                     3 shots in a row = detection. R52 only gates this by packet rate;
 *                     here it is also skipped for clients that batch cmds anyway.
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

new Handle:g_hCvarAirstuck = INVALID_HANDLE;
new Handle:g_hCvarLag = INVALID_HANDLE;
new Handle:g_hCvarBacktrack = INVALID_HANDLE;
new Handle:g_hCvarPSilentWarn = INVALID_HANDLE;
new Handle:g_hCvarPSilentBan = INVALID_HANDLE;

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

public OnPluginStart()
{
	Ultra_OnPluginStart();

	g_hCvarAirstuck = SMAC_CreateConVar("smac_Airstuck_reaction", "3", "Airstuck: 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarLag = SMAC_CreateConVar("smac_LagExploit_reaction", "2", "Lag Exploit (tickcount shift): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarBacktrack = SMAC_CreateConVar("smac_eyetest_reaction_Advanced", "3", "Backtrack Exploit (cmdnum rollback): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarPSilentWarn = SMAC_CreateConVar("smac_PSilent_Warning", "10", "PSilent [Active Mode] detections before admins are notified. (0 = never)", _, true, 0.0);
	g_hCvarPSilentBan = SMAC_CreateConVar("smac_PSilent_Ban", "-12", "PSilent [Active Mode] detections before punish: -N kick, +N ban, 0 = off", _, true, -100.0, true, 100.0);

	HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
}

public OnGameFrame()
{
	SMAC_ServerLagSample();
}

public OnClientPutInServer(client)
{
	Ultra_ResetClient(client);

	g_iSrvHist[client][0] = g_iSrvHist[client][1] = g_iSrvHist[client][2] = 0;
	g_fBatchEma[client] = 0.1;

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
	if (!Ultra_IsPlaying(client))
	{
		g_bUHasPrev[client] = false;
		g_bShotArmed[client] = false;
		return Plugin_Continue;
	}

	new srvTick = GetGameTickCount();
	new bool:bBatched = (g_bUHasPrev[client] && srvTick == g_iSrvHist[client][0]);
	new bool:bUsable = g_bUHasPrev[client] && !Ultra_IsIgnored(client) && !Ultra_IsLagging(client);

	if (bUsable)
	{
		CheckPSilent(client, srvTick, bBatched);
		CheckAirstuck(client, buttons, angles, cmdnum, tickcount, mouse);
		CheckLagExploit(client, cmdnum, tickcount);
		CheckBacktrack(client, cmdnum);
	}
	else
	{
		g_bShotArmed[client] = false;
		g_iAirStreak[client] = 0;
	}

	/* Baseline: how often this client's cmds share a server frame anyway
	   (low cl_cmdrate / fps, jitter). */
	if (g_bUHasPrev[client])
		g_fBatchEma[client] += ((bBatched ? 1.0 : 0.0) - g_fBatchEma[client]) * BATCH_EMA_ALPHA;

	g_iSrvHist[client][2] = g_iSrvHist[client][1];
	g_iSrvHist[client][1] = g_iSrvHist[client][0];
	g_iSrvHist[client][0] = srvTick;

	Ultra_StoreCmd(client, buttons, angles, cmdnum, tickcount);
	return Plugin_Continue;
}

CheckAirstuck(client, buttons, const Float:angles[3], cmdnum, tickcount, const mouse[2])
{
	new level = GetConVarInt(g_hCvarAirstuck);
	if (level <= 0)
		return;

	if (cmdnum != g_iUPrevCmd[client] + 1 || tickcount != g_iUPrevTick[client])
	{
		g_iAirStreak[client] = 0;
		return;
	}

	new bool:bActive = (buttons != 0 || mouse[0] != 0 || mouse[1] != 0
		|| angles[0] != g_fUPrevAng[client][0] || angles[1] != g_fUPrevAng[client][1]);
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
	Ultra_ReportLevel(client, Detection_AirStuck, info, g_iAirDetects[client], level, "Airstuck", sDetail);
	CloseHandle(info);
}

CheckLagExploit(client, cmdnum, tickcount)
{
	new level = GetConVarInt(g_hCvarLag);
	if (level <= 0)
		return;

	/* Server processed this client's cmds one per tick (stable stream). */
	new srvTick = GetGameTickCount();
	if (srvTick - g_iSrvHist[client][0] != 1
		|| g_iSrvHist[client][0] - g_iSrvHist[client][1] != 1
		|| g_iSrvHist[client][1] - g_iSrvHist[client][2] != 1)
		return;

	new cmdStep = cmdnum - g_iUPrevCmd[client];
	new tickStep = tickcount - g_iUPrevTick[client];
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
	Ultra_ReportLevel(client, Detection_LagExploit, info, g_iLagDetects[client], level, "Lag Exploit", sDetail);
	CloseHandle(info);
}

CheckBacktrack(client, cmdnum)
{
	new level = GetConVarInt(g_hCvarBacktrack);
	if (level <= 0 || cmdnum >= g_iUPrevCmd[client])
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
	KvSetNum(info, "prev_cmdnum", g_iUPrevCmd[client]);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "cmdnum %i after %i", cmdnum, g_iUPrevCmd[client]);
	Ultra_ReportLevel(client, Detection_Backtrack, info, g_iBtDetects[client], level, "Backtrack Exploit-Mode:B", sDetail);
	CloseHandle(info);
}

CheckPSilent(client, srvTick, bool:bBatched)
{
	if (!g_bShotArmed[client])
		return;

	g_bShotArmed[client] = false;

	new ban = GetConVarInt(g_hCvarPSilentBan);
	if (ban == 0)
		return;

	/* Clients that routinely send several cmds per packet are not judged. */
	if (g_fBatchEma[client] > BATCH_EMA_MAX)
		return;

	/* Shot cmd arrived together with this one, while the cmd before the shot
	   came in its own frame: the shot was choked. */
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
	Ultra_Report(client, Detection_UltraPSilent, info, g_iPSilentDetects[client],
		GetConVarInt(g_hCvarPSilentWarn), ban, "PSilent [Active Mode]", sDetail);
	CloseHandle(info);
}
