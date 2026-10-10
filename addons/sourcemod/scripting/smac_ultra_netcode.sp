#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC Ultr@ R52 port: usercmd / netcode detectors.
 *
 * Rewritten from 001_SMAC_Global.smx of SMAC Ultr@ R52 as decompiled with
 * tools/r52re/decomp.py (docs/R52_SPEC.md, docs/ULTRA_NETCODE.md). No Ultr@ code
 * and no Ultr@Tools extension is used.
 *
 *   Airstuck        - cmdnum advances by exactly 1 but the client tickcount repeats
 *                     while the player is active (buttons / mouse / angles). 6 such cmds
 *                     = stage (a tickcount change resets the streak), 2 stages = detection.
 *                     Stages decay by 1 every 420 s (R52 delayed check).
 *   Lag Exploit     - the server processed the last 4 cmds on consecutive ticks, cmdnum
 *                     advanced normally (+1..11) but the client tickcount jumped > 11.
 *                     More than 5 jumps (gaps < 5 s) = detection. R52 also counts cmdnum
 *                     jumps > 11 for the whole map; that is packet loss, so it is left out.
 *   Backtrack B     - cmdnum goes backwards. 23 rollbacks = stage, 2 stages = detection,
 *                     stages decay by 1 every 128 s.
 *   Backtrack A     - at the shot the client tickcount is lower than the previous cmd's (or the
 *                     previous one is negative). Counter from -1, each step decays in 300 s, the
 *                     4th such shot is a detection.
 *   Backtrack Patch - not a detector (from Little Anti-Cheat, lilac_backtrack_patch): when the
 *                     client tickcount stops following cmdnum (tickcount - prev != cmdnum - prev,
 *                     so packet loss does not count), for smac_backtrack_patch_time seconds every
 *                     cmd gets the tickcount the engine itself would fall back to in
 *                     CLagCompensationManager::StartLagCompensation (server tick - latency - lerp).
 *                     A backtrack cheat then rewinds nothing; a legit lossy player only loses
 *                     the (<= 200 ms) tickcount lag compensation for that time. Off by default.
 *                     Runs after the checks above, so they still see the raw tickcount.
 *   Changer Player Status - a client flagged as a bot (IsFakeClient) sends mouse input; real bots
 *                     never do. Reported once per connection.
 *   PSilent Active  - at the shot (weapon_fire = R52 FireBullets TE hook):
 *                       armed = 2 when the last 4 cmds have cmdnum and tickcount growing by
 *                       exactly 1, server ticks [0..2] consecutive, and the shot cmd arrived
 *                       after a server-tick gap (> 1) - i.e. it was choked - while the aim
 *                       moved (|dYaw| > 1.5*thr3 or |mouse| change > 1.5*thr4);
 *                       armed = 1 when only the aim moved.
 *                     While +attack is held, every cmd that shares its server tick with the
 *                     previous one (the two before did not) adds 1; > 2 = detection.
 *                     thr3 = min(sensitivity * 0.033 * 2.6, 0.7), thr4 = min(sensitivity * 15, 80).
 *
 * Common R52 rules:
 *   - nothing is judged right after spawn / trigger_teleport, while the client has
 *     loss/choke/ping spikes or while the server itself hitches (added for safety);
 *   - kick/ban is lowered by one step when the client ping is >= 150 ms and by one more
 *     when it sends <= 70% of tickrate packets (R52: 46.2 pkt/s on 66 tick);
 *   - admins with ban/root flag are never punished (still logged).
 *
 * Added in smac_v34 (not in R52), from the 420hook source (docs/HOOK_420.md):
 *   CmdNum Jump     - cmdnum jumps forward by more than MULTIPLAYER_BACKUP (90) commands.
 *                     A real outage does it once; 420hook Lag Exploit adds 450 to every
 *                     cmdnum. 3 jumps within 10 s = detection. Packet loss does not skip this
 *                     check and does not lower the action: the exploit itself fakes the loss.
 *   Tick Ahead      - the client tickcount is more than 1 s ahead of the server tick on
 *                     3 cmds in a row (420hook Airstuck sends INT_MAX). The client clock always
 *                     runs behind the server, so this is caught at once.
 *   Fake Lag        - (log + notice) the client sends >= 7 usercmds per packet on average for
 *                     5 seconds in a row, more than twice what its cl_cmdrate gives, without loss.
 *
 * Cvars keep the Ultr@ names. Defaults are admin-notice only, except CmdNum Jump and Tick Ahead (kick).
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: Netcode",
	author = SMAC_AUTHOR,
	description = "Airstuck, Lag Exploit, Backtrack A/B, PSilent and Changer Player Status from SMAC Ultr@ R52; CmdNum Jump, Tick Ahead, Fake Lag",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define AIRSTUCK_STREAK		6
#define AIRSTUCK_STAGES		2
#define AIRSTUCK_DECAY		420.0

#define LAG_MAX_CMD_STEP	11
#define LAG_MIN_TICK_STEP	11
#define LAG_EVENTS			5
#define LAG_EVENT_TTL		5.0

#define BACKTRACK_EVENTS	22
#define BACKTRACK_STAGES	2
#define BACKTRACK_DECAY		128.0

#define BACKTRACK_A_EVENTS	2
#define BACKTRACK_A_DECAY	300.0

#define PSILENT_ARMED		2
#define PSILENT_DETECT		2
#define PSILENT_DECAY		420.0

#define SENS_UNKNOWN_THR3	100.0
#define SENS_UNKNOWN_THR4	10000.0
#define QUERY_INTERVAL		60.0

#define SPAWN_GRACE			1.0
#define TELEPORT_GRACE		0.5

#define MAX_PING			0.15
#define MIN_PACKET_FRAC		0.7

#define CMDJUMP_MIN			90		/* MULTIPLAYER_BACKUP */
#define CMDJUMP_EVENTS		3
#define CMDJUMP_WINDOW		10.0

#define TICKAHEAD_SECONDS	1.0
#define TICKAHEAD_CMDS		3

#define FAKELAG_MIN_BATCH	7.0
#define FAKELAG_RATE_MULT	2.0
#define FAKELAG_SECONDS		5
#define FAKELAG_COOLDOWN	25		/* seconds without a new report after one */

#define LAG_MAX_LOSS		0.05
#define LAG_MAX_CHOKE		0.30
#define LAG_MAX_PING_SPIKE	0.10

new Handle:g_hCvarAirstuck = INVALID_HANDLE;
new Handle:g_hCvarLag = INVALID_HANDLE;
new Handle:g_hCvarBacktrack = INVALID_HANDLE;
new Handle:g_hCvarPSilentWarn = INVALID_HANDLE;
new Handle:g_hCvarPSilentBan = INVALID_HANDLE;
new Handle:g_hCvarAdminImmune = INVALID_HANDLE;
new Handle:g_hCvarFakeStatus = INVALID_HANDLE;
new Handle:g_hCvarCmdJump = INVALID_HANDLE;
new Handle:g_hCvarTickAhead = INVALID_HANDLE;
new Handle:g_hCvarFakeLag = INVALID_HANDLE;
new Handle:g_hCvarMaxCmdRate = INVALID_HANDLE;
new Handle:g_hCvarBtPatch = INVALID_HANDLE;
new Handle:g_hCvarBtPatchTime = INVALID_HANDLE;

/* Last 4 cmds: [3] = newest. */
new g_iHistCmd[MAXPLAYERS+1][4];
new g_iHistTick[MAXPLAYERS+1][4];
new g_iHistSrv[MAXPLAYERS+1][4];
new g_iHistLen[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];
new Float:g_fPrevAng[MAXPLAYERS+1][2];
new Float:g_fDYaw[MAXPLAYERS+1];
new g_iMouseSum[MAXPLAYERS+1][2];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];

/* sensitivity-based thresholds (R52 sensThr[3], sensThr[4]). */
new Float:g_fThr3[MAXPLAYERS+1];
new Float:g_fThr4[MAXPLAYERS+1];

new g_iAirStreak[MAXPLAYERS+1];
new g_iAirStage[MAXPLAYERS+1];
new Float:g_fAirStageTime[MAXPLAYERS+1];
new g_iAirDetects[MAXPLAYERS+1];

new g_iLagEvents[MAXPLAYERS+1];
new Float:g_fLagLast[MAXPLAYERS+1];
new g_iLagDetects[MAXPLAYERS+1];

new g_iBtEvents[MAXPLAYERS+1];
new g_iBtStage[MAXPLAYERS+1];
new Float:g_fBtStageTime[MAXPLAYERS+1];
new g_iBtDetects[MAXPLAYERS+1];

new g_iBtaEvents[MAXPLAYERS+1];
new Float:g_fBtaTime[MAXPLAYERS+1];
new g_iBtaDetects[MAXPLAYERS+1];

new g_iFakeDetects[MAXPLAYERS+1];
new bool:g_bFakeReported[MAXPLAYERS+1];

new g_iCmdJumpEvents[MAXPLAYERS+1];
new Float:g_fCmdJumpFirst[MAXPLAYERS+1];
new g_iCmdJumpDetects[MAXPLAYERS+1];

new g_iTickAheadStreak[MAXPLAYERS+1];
new g_iTickAheadDetects[MAXPLAYERS+1];

new g_iFlCmds[MAXPLAYERS+1];
new g_iFlPackets[MAXPLAYERS+1];
new g_iFlMaxBatch[MAXPLAYERS+1];
new g_iFlBatch[MAXPLAYERS+1];
new g_iFlLastSrv[MAXPLAYERS+1];
new Float:g_fFlStart[MAXPLAYERS+1];
new g_iFlStreak[MAXPLAYERS+1];
new g_iFlDetects[MAXPLAYERS+1];

new Float:g_fBtPatchUntil[MAXPLAYERS+1];

new g_iPSilentState[MAXPLAYERS+1];
new g_iPSilentDetects[MAXPLAYERS+1];
new Float:g_fPSilentTime[MAXPLAYERS+1];

/* Server hitch detector: a stalled server batches/replays everyone's usercmds. */
new Float:g_fPrevFrameTime;
new Float:g_fFrameEma;
new Float:g_fServerLagUntil;

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarAirstuck = SMAC_CreateConVar("smac_Airstuck_reaction", "1", "Airstuck: 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarLag = SMAC_CreateConVar("smac_LagExploit_reaction", "1", "Lag Exploit (tickcount shift): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarBacktrack = SMAC_CreateConVar("smac_eyetest_reaction_Advanced", "1", "Backtrack Exploit-Mode:A (tickcount rollback on a shot) and B (cmdnum rollback): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarPSilentWarn = SMAC_CreateConVar("smac_PSilent_Warning", "1", "PSilent [Active Mode] detections before admins are notified. (0 = never)", _, true, 0.0);
	g_hCvarPSilentBan = SMAC_CreateConVar("smac_PSilent_Ban", "0", "PSilent [Active Mode] detections before punish: -N = kick, +N = ban, 0 = never (R52: -12)", _, true, -100.0, true, 100.0);
	g_hCvarFakeStatus = SMAC_CreateConVar("smac_ultra_fake_status", "1", "Changer Player Status (a client flagged as a bot sends mouse input): 0=off, 1=admin notice, 2=kick, 3=ban (R52: ban)", _, true, 0.0, true, 3.0);
	g_hCvarCmdJump = SMAC_CreateConVar("smac_CmdNumJump_reaction", "2", "CmdNum Jump (cmdnum skips > 90 commands, 420hook Lag Exploit): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarTickAhead = SMAC_CreateConVar("smac_TickAhead_reaction", "2", "Tick Ahead (client tickcount > 1 s ahead of the server, 420hook Airstuck): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarFakeLag = SMAC_CreateConVar("smac_FakeLag_reaction", "1", "Fake Lag (usercmds held and sent in large packets, log collection): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarMaxCmdRate = FindConVar("sv_maxcmdrate");
	g_hCvarBtPatch = SMAC_CreateConVar("smac_backtrack_patch", "0", "Backtrack Patch (Little Anti-Cheat): replace a tampered client tickcount with the engine estimate for a while. Not a detector. 0=off, 1=on", _, true, 0.0, true, 1.0);
	g_hCvarBtPatchTime = SMAC_CreateConVar("smac_backtrack_patch_time", "5.0", "Seconds the Backtrack Patch stays on after the last tampered tickcount.", _, true, 0.5, true, 60.0);
	g_hCvarAdminImmune = SMAC_CreateConVar("smac_ultra_admin_immune", "1", "Never kick/ban admins with ban/root flag (detections are still logged).", _, true, 0.0, true, 1.0);

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnStartTouch", Output_Teleport);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Output_Teleport);

	CreateTimer(QUERY_INTERVAL, Timer_QueryAll, _, TIMER_REPEAT);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
}

public OnClientPutInServer(client)
{
	g_iHistLen[client] = 0;
	g_iPrevButtons[client] = 0;
	g_fPrevAng[client][0] = g_fPrevAng[client][1] = 0.0;
	g_fDYaw[client] = 0.0;
	g_iMouseSum[client][0] = g_iMouseSum[client][1] = 0;
	g_fIgnoreUntil[client] = 0.0;

	g_fThr3[client] = SENS_UNKNOWN_THR3;
	g_fThr4[client] = SENS_UNKNOWN_THR4;

	g_iAirStreak[client] = 0;
	g_iAirStage[client] = 0;
	g_fAirStageTime[client] = 0.0;
	g_iAirDetects[client] = 0;

	g_iLagEvents[client] = 0;
	g_fLagLast[client] = 0.0;
	g_iLagDetects[client] = 0;

	g_iBtEvents[client] = 0;
	g_iBtStage[client] = 0;
	g_fBtStageTime[client] = 0.0;
	g_iBtDetects[client] = 0;

	g_iBtaEvents[client] = -1;
	g_fBtaTime[client] = 0.0;
	g_iBtaDetects[client] = 0;

	g_iFakeDetects[client] = 0;
	g_bFakeReported[client] = false;

	g_iCmdJumpEvents[client] = 0;
	g_fCmdJumpFirst[client] = 0.0;
	g_iCmdJumpDetects[client] = 0;

	g_iTickAheadStreak[client] = 0;
	g_iTickAheadDetects[client] = 0;

	ResetFakeLag(client);
	g_iFlStreak[client] = 0;
	g_iFlDetects[client] = 0;
	g_fBtPatchUntil[client] = 0.0;

	g_iPSilentState[client] = 0;
	g_iPSilentDetects[client] = 0;
	g_fPSilentTime[client] = 0.0;

	if (!IsFakeClient(client))
		QueryClientConVar(client, "sensitivity", Query_Sensitivity);
}

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
	if (sens < 1.0)
		sens = 1.0;

	/* R52: thr2 = sens * 0.033; thr3 = min(thr2 * 2.6, 0.7); thr4 = min(sens * 15, 80). */
	g_fThr3[client] = sens * 0.033 * 2.6;
	if (g_fThr3[client] > 0.7)
		g_fThr3[client] = 0.7;

	g_fThr4[client] = sens * 15.0;
	if (g_fThr4[client] > 80.0)
		g_fThr4[client] = 80.0;
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
		g_iHistLen[client] = 0;
		IgnoreClient(client, SPAWN_GRACE);
	}
}

public Output_Teleport(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator))
		IgnoreClient(activator, TELEPORT_GRACE + delay);
}

/* R52 arms PSilent in its FireBullets TE hook; weapon_fire fires at the same point,
   while the shot cmd runs, so the history [3] below is the shot cmd. */
public Event_WeaponFire(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client))
		return;

	g_iPSilentState[client] = 0;

	/* R52 Backtrack Exploit-Mode:A: on the shot the client tickcount went back (or the previous one
	   is negative). The FireBullets hook in R52; weapon_fire runs at the same point. */
	if (g_iHistLen[client] >= 2 && GetGameTime() >= g_fIgnoreUntil[client]
		&& (g_iHistTick[client][3] < g_iHistTick[client][2] || g_iHistTick[client][2] < 0))
	{
		CheckBacktrackA(client);
	}

	if (g_iHistLen[client] < 4 || GetGameTime() < g_fIgnoreUntil[client] || IsLagging(client))
		return;

	/* Both older and newer pairs batched: nothing to judge. */
	if (g_iHistSrv[client][2] == g_iHistSrv[client][3] && g_iHistSrv[client][0] == g_iHistSrv[client][1])
		return;

	if (!(GetEntityFlags(client) & FL_ONGROUND))
		return;

	new bool:bAimMoved = AimMoved(client);
	new step = AbsDiff(g_iHistCmd[client][3], g_iHistCmd[client][2]) + AbsDiff(g_iHistTick[client][3], g_iHistTick[client][2]);
	new srvGap = g_iHistSrv[client][3] - g_iHistSrv[client][2];

	if (step > 0 && step < 7 && srvGap <= step + 1)
	{
		if (bAimMoved
			&& AbsDiff(g_iHistCmd[client][3], g_iHistCmd[client][2]) == 1
			&& AbsDiff(g_iHistCmd[client][2], g_iHistCmd[client][1]) == 1
			&& AbsDiff(g_iHistCmd[client][1], g_iHistCmd[client][0]) == 1
			&& AbsDiff(g_iHistTick[client][3], g_iHistTick[client][2]) == 1
			&& AbsDiff(g_iHistTick[client][2], g_iHistTick[client][1]) == 1
			&& AbsDiff(g_iHistTick[client][1], g_iHistTick[client][0]) == 1
			&& g_iHistSrv[client][1] - g_iHistSrv[client][0] == 1
			&& g_iHistSrv[client][2] - g_iHistSrv[client][1] >= 0
			&& g_iHistSrv[client][2] - g_iHistSrv[client][1] <= 1
			&& srvGap > 1)
		{
			g_iPSilentState[client] = PSILENT_ARMED;
		}
	}
	else if (bAimMoved)
	{
		g_iPSilentState[client]++;
	}
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	/* R52 "Changer Player Status": bots never send mouse input. */
	if (IS_CLIENT(client) && IsFakeClient(client) && (mouse[0] != 0 || mouse[1] != 0))
		CheckFakeStatus(client, mouse);

	if (!IsPlaying(client))
	{
		g_iHistLen[client] = 0;
		g_iPSilentState[client] = 0;
		g_iTickAheadStreak[client] = 0;
		ResetFakeLag(client);
		return Plugin_Continue;
	}

	new bool:bHasPrev = (g_iHistLen[client] > 0);
	new prevCmd = g_iHistCmd[client][3];
	new prevTick = g_iHistTick[client][3];

	/* Shift history, [3] = this cmd. */
	for (new i = 0; i < 3; i++)
	{
		g_iHistCmd[client][i] = g_iHistCmd[client][i + 1];
		g_iHistTick[client][i] = g_iHistTick[client][i + 1];
		g_iHistSrv[client][i] = g_iHistSrv[client][i + 1];
	}
	g_iHistCmd[client][3] = cmdnum;
	g_iHistTick[client][3] = tickcount;
	g_iHistSrv[client][3] = GetGameTickCount();
	if (g_iHistLen[client] < 4)
		g_iHistLen[client]++;

	g_fDYaw[client] = bHasPrev ? FloatAbs(g_fPrevAng[client][1] - angles[1]) : 0.0;
	g_iMouseSum[client][0] = g_iMouseSum[client][1];
	g_iMouseSum[client][1] = AbsValue(mouse[0]) + AbsValue(mouse[1]);

	/* These run before the loss gate: the 420hook Lag Exploit makes the client look lossy. */
	if (GetGameTime() >= g_fIgnoreUntil[client] && !IsServerHitch() && !IsClientTimingOut(client))
	{
		if (bHasPrev)
			CheckCmdNumJump(client, buttons, cmdnum, prevCmd, tickcount, prevTick);
		CheckTickAhead(client, cmdnum, tickcount);
		CheckFakeLag(client);
	}
	else
	{
		ResetFakeLag(client);
	}

	if (bHasPrev && GetGameTime() >= g_fIgnoreUntil[client] && !IsLagging(client))
	{
		CheckAirstuck(client, buttons, angles, cmdnum, tickcount, mouse, prevCmd, prevTick);
		CheckLagExploit(client);
		CheckBacktrack(client, cmdnum, prevCmd);
		CheckPSilent(client, buttons);
	}
	else
	{
		g_iPSilentState[client] = 0;
	}

	g_iPrevButtons[client] = buttons;
	g_fPrevAng[client][0] = angles[0];
	g_fPrevAng[client][1] = angles[1];

	if (bHasPrev && PatchBacktrack(client, cmdnum, tickcount, prevCmd, prevTick))
		return Plugin_Changed;

	return Plugin_Continue;
}

/* Backtrack Patch (Little Anti-Cheat). The history above keeps the raw tickcount. */
bool:PatchBacktrack(client, cmdnum, &tickcount, prevCmd, prevTick)
{
	if (!GetConVarBool(g_hCvarBtPatch))
		return false;

	new Float:now = GetGameTime();

	/* Lost cmds move cmdnum and tickcount by the same step; a backtrack only moves tickcount.
	   Fake lag still triggers it, so client loss/choke is not a reason to skip (unlike the detectors). */
	if (cmdnum > prevCmd && tickcount - prevTick != cmdnum - prevCmd
		&& now >= g_fIgnoreUntil[client] && (g_fServerLagUntil <= 0.0 || now >= g_fServerLagUntil))
	{
		g_fBtPatchUntil[client] = now + GetConVarFloat(g_hCvarBtPatchTime);
	}

	if (now >= g_fBtPatchUntil[client])
		return false;

	/* CLagCompensationManager::StartLagCompensation fallback: target tick =
	   server tick - TIME_TO_TICKS(latency + lerp), tick_count = target + lerp ticks. */
	new iLerpTicks = TIME_TO_TICK(GetEntPropFloat(client, Prop_Data, "m_fLerpTime"));
	new Float:fCorrect = GetClientLatency(client, NetFlow_Outgoing) + TICK_TO_TIME(iLerpTicks);
	fCorrect = ClampValue(fCorrect, 0.0, 1.0);

	tickcount = GetGameTickCount() - TIME_TO_TICK(fCorrect) + iLerpTicks;
	return true;
}

CheckAirstuck(client, buttons, const Float:angles[3], cmdnum, tickcount, const mouse[2], prevCmd, prevTick)
{
	new level = GetConVarInt(g_hCvarAirstuck);
	if (level <= 0 || cmdnum - prevCmd != 1)
		return;

	if (tickcount != prevTick)
	{
		g_iAirStreak[client] = 0;
		return;
	}

	/* A completely idle cmd neither counts nor breaks the streak. */
	if (buttons == 0 && mouse[0] == 0 && mouse[1] == 0
		&& angles[0] == g_fPrevAng[client][0] && angles[1] == g_fPrevAng[client][1])
		return;

	if (++g_iAirStreak[client] < AIRSTUCK_STREAK)
		return;

	g_iAirStreak[client] = 0;
	g_iAirStage[client] = Decay(g_iAirStage[client], g_fAirStageTime[client], AIRSTUCK_DECAY) + 1;
	g_fAirStageTime[client] = GetGameTime();

	if (g_iAirStage[client] < AIRSTUCK_STAGES)
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

CheckLagExploit(client)
{
	new level = GetConVarInt(g_hCvarLag);
	if (level <= 0 || g_iHistLen[client] < 4)
		return;

	/* The server processed the last 4 cmds on consecutive ticks (stable stream). */
	if (g_iHistSrv[client][3] - g_iHistSrv[client][2] != 1
		|| g_iHistSrv[client][2] - g_iHistSrv[client][1] != 1
		|| g_iHistSrv[client][1] - g_iHistSrv[client][0] != 1)
		return;

	new cmdStep = g_iHistCmd[client][3] - g_iHistCmd[client][2];
	new tickStep = g_iHistTick[client][3] - g_iHistTick[client][2];
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

CheckCmdNumJump(client, buttons, cmdnum, prevCmd, tickcount, prevTick)
{
	new level = GetConVarInt(g_hCvarCmdJump);
	new jump = cmdnum - prevCmd;
	if (level <= 0 || jump <= CMDJUMP_MIN)
		return;

	new Float:now = GetGameTime();
	if (g_iCmdJumpEvents[client] == 0 || now - g_fCmdJumpFirst[client] > CMDJUMP_WINDOW)
	{
		g_iCmdJumpEvents[client] = 0;
		g_fCmdJumpFirst[client] = now;
	}

	if (++g_iCmdJumpEvents[client] < CMDJUMP_EVENTS)
		return;

	g_iCmdJumpEvents[client] = 0;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "cmdnum", cmdnum);
	KvSetNum(info, "prev_cmdnum", prevCmd);
	KvSetNum(info, "tickcount", tickcount);
	KvSetNum(info, "prev_tickcount", prevTick);

	decl String:sDetail[160];
	FormatEx(sDetail, sizeof(sDetail), "cmdnum +%i (tickcount +%i, attack %i), %i jumps > %i in %.1f s, loss %.0f%%",
		jump, tickcount - prevTick, (buttons & IN_ATTACK) ? 1 : 0, CMDJUMP_EVENTS, CMDJUMP_MIN,
		now - g_fCmdJumpFirst[client], GetClientAvgLoss(client, NetFlow_Incoming) * 100.0);
	ReportLevel(client, Detection_LagExploit, info, g_iCmdJumpDetects[client], level, "CmdNum Jump", sDetail, false);
	CloseHandle(info);
}

CheckTickAhead(client, cmdnum, tickcount)
{
	new level = GetConVarInt(g_hCvarTickAhead);
	if (level <= 0)
		return;

	new server = GetGameTickCount();
	new margin = RoundToCeil(TICKAHEAD_SECONDS / GetTickInterval());
	if (tickcount <= server + margin)
	{
		g_iTickAheadStreak[client] = 0;
		return;
	}

	if (++g_iTickAheadStreak[client] < TICKAHEAD_CMDS)
		return;

	g_iTickAheadStreak[client] = 0;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "cmdnum", cmdnum);
	KvSetNum(info, "tickcount", tickcount);
	KvSetNum(info, "server_tick", server);

	decl String:sDetail[128];
	FormatEx(sDetail, sizeof(sDetail), "client tickcount %i, server tick %i (+%i ticks) on %i cmds",
		tickcount, server, tickcount - server, TICKAHEAD_CMDS);
	ReportLevel(client, Detection_AirStuck, info, g_iTickAheadDetects[client], level, "Tick Ahead", sDetail, false);
	CloseHandle(info);
}

ResetFakeLag(client)
{
	g_iFlCmds[client] = 0;
	g_iFlPackets[client] = 0;
	g_iFlMaxBatch[client] = 0;
	g_iFlBatch[client] = 0;
	g_iFlLastSrv[client] = -1;
	g_fFlStart[client] = 0.0;
}

/* Every usercmd of one packet runs on the same server tick, so cmds per distinct tick = cmds per packet. */
CheckFakeLag(client)
{
	new level = GetConVarInt(g_hCvarFakeLag);
	if (level <= 0)
		return;

	new Float:now = GetGameTime();
	new srv = GetGameTickCount();

	if (g_fFlStart[client] <= 0.0)
		g_fFlStart[client] = now;

	if (srv != g_iFlLastSrv[client])
	{
		g_iFlPackets[client]++;
		g_iFlLastSrv[client] = srv;
		g_iFlBatch[client] = 0;
	}
	g_iFlCmds[client]++;
	if (++g_iFlBatch[client] > g_iFlMaxBatch[client])
		g_iFlMaxBatch[client] = g_iFlBatch[client];

	if (now - g_fFlStart[client] < 1.0)
		return;

	new cmds = g_iFlCmds[client];
	new packets = g_iFlPackets[client];
	new maxBatch = g_iFlMaxBatch[client];
	ResetFakeLag(client);
	g_iFlLastSrv[client] = srv;

	if (packets <= 0)
		return;

	new Float:batch = float(cmds) / float(packets);
	new Float:tickrate = 1.0 / GetTickInterval();
	new cmdrate = GetClientCmdRate(client);
	new Float:expected = (cmdrate > 0 && float(cmdrate) < tickrate) ? tickrate / float(cmdrate) : 1.0;

	new bool:bSuspect = (batch >= FAKELAG_MIN_BATCH && batch > expected * FAKELAG_RATE_MULT
		&& GetClientAvgLoss(client, NetFlow_Incoming) <= LAG_MAX_LOSS);

	if (g_iFlStreak[client] < 0)
	{
		g_iFlStreak[client]++;
		return;
	}

	if (!bSuspect)
	{
		g_iFlStreak[client] = 0;
		return;
	}

	if (++g_iFlStreak[client] < FAKELAG_SECONDS)
		return;

	g_iFlStreak[client] = -FAKELAG_COOLDOWN;

	new Handle:info = CreateKeyValues("");
	KvSetFloat(info, "cmds_per_packet", batch);
	KvSetNum(info, "max_batch", maxBatch);
	KvSetNum(info, "cl_cmdrate", cmdrate);

	decl String:sDetail[160];
	FormatEx(sDetail, sizeof(sDetail), "%.1f cmds per packet (max %i, %i pkt/s) for %i s, cl_cmdrate %i expects %.1f",
		batch, maxBatch, packets, FAKELAG_SECONDS, cmdrate, expected);
	ReportLevel(client, Detection_LagExploit, info, g_iFlDetects[client], level, "Fake Lag", sDetail);
	CloseHandle(info);
}

GetClientCmdRate(client)
{
	decl String:sRate[16];
	if (!GetClientInfo(client, "cl_cmdrate", sRate, sizeof(sRate)))
		return 0;

	new rate = StringToInt(sRate);
	if (g_hCvarMaxCmdRate != INVALID_HANDLE)
	{
		new maxRate = GetConVarInt(g_hCvarMaxCmdRate);
		if (maxRate > 0 && rate > maxRate)
			rate = maxRate;
	}
	return rate;
}

CheckBacktrack(client, cmdnum, prevCmd)
{
	new level = GetConVarInt(g_hCvarBacktrack);
	if (level <= 0 || cmdnum >= prevCmd)
		return;

	if (GetEntityFlags(client) & (FL_FROZEN | FL_ATCONTROLS))
		return;

	if (++g_iBtEvents[client] <= BACKTRACK_EVENTS)
		return;

	g_iBtEvents[client] = 0;
	g_iBtStage[client] = Decay(g_iBtStage[client], g_fBtStageTime[client], BACKTRACK_DECAY) + 1;
	g_fBtStageTime[client] = GetGameTime();

	if (g_iBtStage[client] < BACKTRACK_STAGES)
		return;

	g_iBtStage[client] = 0;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "cmdnum", cmdnum);
	KvSetNum(info, "prev_cmdnum", prevCmd);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "cmdnum rolled back %i times (last %i after %i)",
		(BACKTRACK_EVENTS + 1) * BACKTRACK_STAGES, cmdnum, prevCmd);
	ReportLevel(client, Detection_Backtrack, info, g_iBtDetects[client], level, "Backtrack Exploit-Mode:B", sDetail);
	CloseHandle(info);
}

CheckPSilent(client, buttons)
{
	if (g_iPSilentState[client] <= 0)
		return;

	/* R52 checks this while +attack is held (previous and current cmd). */
	if (!(buttons & IN_ATTACK) || !(g_iPrevButtons[client] & IN_ATTACK))
		return;

	new warn = GetConVarInt(g_hCvarPSilentWarn);
	new ban = GetConVarInt(g_hCvarPSilentBan);
	if (warn == 0 && ban == 0)
	{
		g_iPSilentState[client] = 0;
		return;
	}

	/* This cmd shares its server tick with the previous one, the two before did not. */
	if (g_iHistSrv[client][2] != g_iHistSrv[client][3] || g_iHistSrv[client][0] == g_iHistSrv[client][1])
	{
		g_iPSilentState[client] = 0;
		return;
	}

	if (++g_iPSilentState[client] <= PSILENT_DETECT)
		return;

	g_iPSilentState[client] = -1;
	g_iPSilentDetects[client] = Decay(g_iPSilentDetects[client], g_fPSilentTime[client], PSILENT_DECAY);
	g_fPSilentTime[client] = GetGameTime();

	new Handle:info = CreateKeyValues("");
	KvSetFloat(info, "dyaw", g_fDYaw[client]);
	KvSetFloat(info, "thr3", g_fThr3[client]);

	decl String:sDetail[128];
	FormatEx(sDetail, sizeof(sDetail), "choked shot followed by batched cmds (dYaw %.3f, thr %.3f)", g_fDYaw[client], g_fThr3[client]);
	Report(client, Detection_UltraPSilent, info, g_iPSilentDetects[client], warn, ban, "PSilent [Active Mode]", sDetail);
	CloseHandle(info);
}

CheckBacktrackA(client)
{
	new level = GetConVarInt(g_hCvarBacktrack);
	if (level <= 0)
		return;

	/* R52: -1, 0, 1, 2 decay in 300 s each; the 4th shot reacts and resets the counter to -2. */
	g_iBtaEvents[client] = DecaySigned(g_iBtaEvents[client], g_fBtaTime[client], BACKTRACK_A_DECAY) + 1;
	g_fBtaTime[client] = GetGameTime();
	if (g_iBtaEvents[client] <= BACKTRACK_A_EVENTS)
		return;

	g_iBtaEvents[client] = -2;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "tickcount", g_iHistTick[client][3]);
	KvSetNum(info, "prev_tickcount", g_iHistTick[client][2]);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "shot with tickcount %i after %i", g_iHistTick[client][3], g_iHistTick[client][2]);
	ReportLevel(client, Detection_Backtrack, info, g_iBtaDetects[client], level, "Backtrack Exploit-Mode:A", sDetail);
	CloseHandle(info);
}

CheckFakeStatus(client, const mouse[2])
{
	new level = GetConVarInt(g_hCvarFakeStatus);
	if (level <= 0 || g_bFakeReported[client] || !IsClientInGame(client))
		return;

	g_bFakeReported[client] = true;

	/* R52 kicks instead of banning a "bot" that connects from the server itself. */
	decl String:sIP[32];
	if (level >= 3 && GetClientIP(client, sIP, sizeof(sIP)) && StrEqual(sIP, "127.0.0.1"))
		level = 2;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "mouse_x", mouse[0]);
	KvSetNum(info, "mouse_y", mouse[1]);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "client flagged as a bot sends mouse input %i %i", mouse[0], mouse[1]);
	ReportLevel(client, Detection_UltraFakeStatus, info, g_iFakeDetects[client], level, "Changer Player Status", sDetail);
	CloseHandle(info);
}

/* Like Decay(), but for R52 counters that start at -1 (or -2 after a reaction). */
DecaySigned(value, Float:lastTime, Float:period)
{
	if (value <= -1 || lastTime <= 0.0)
		return value;

	new steps = RoundToFloor((GetGameTime() - lastTime) / period);
	value -= steps;
	return (value < -1) ? -1 : value;
}

/**
 * Helpers
 */
bool:AimMoved(client)
{
	if (g_fDYaw[client] > g_fThr3[client] * 1.5)
		return true;

	return float(g_iMouseSum[client][1] - g_iMouseSum[client][0]) > g_fThr4[client] * 1.5;
}

AbsDiff(a, b)
{
	return AbsValue(a) - AbsValue(b);
}

/* R52 decays counters by one per delayed check; applied lazily here. */
Decay(value, Float:lastTime, Float:period)
{
	if (value <= 0 || lastTime <= 0.0)
		return value;

	new steps = RoundToFloor((GetGameTime() - lastTime) / period);
	value -= steps;
	return (value < 0) ? 0 : value;
}

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
bool:IsServerHitch()
{
	return g_fServerLagUntil > 0.0 && GetGameTime() < g_fServerLagUntil;
}

bool:IsLagging(client)
{
	if (IsServerHitch())
		return true;

	if (IsClientTimingOut(client))
		return true;

	if (GetClientAvgLoss(client, NetFlow_Both) > LAG_MAX_LOSS)
		return true;

	if (GetClientAvgChoke(client, NetFlow_Both) > LAG_MAX_CHOKE)
		return true;

	return GetClientLatency(client, NetFlow_Outgoing) - GetClientAvgLatency(client, NetFlow_Outgoing) > LAG_MAX_PING_SPIKE;
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

/*
 * One detection with Ultr@ Warning/Ban semantics:
 *   warn - admins are notified from this detection on (0 = never)
 *   ban  - +N ban / -N kick after N detections (0 = never)
 */
Report(client, DetectionType:type, Handle:info, &count, warn, ban, const String:name[], const String:detail[], bool:bLower=true)
{
	count++;
	KvSetNum(info, "detection", count);

	if (SMAC_CheatDetected(client, type, info) != Plugin_Continue)
		return;

	SMAC_LogAction(client, "%s (Detection #%i) %s", name, count, detail);

	new action = 1;
	if (ban != 0 && count >= AbsValue(ban) && !IsImmune(client))
		action = (ban > 0) ? 3 : 2;

	new lowered = bLower ? LowerAction(client, action) : action;
	if (lowered != action)
	{
		SMAC_LogAction(client, "%s: action lowered %i -> %i (avg ping %.0f ms, %.1f pkt/s).",
			name, action, lowered,
			GetClientAvgLatency(client, NetFlow_Outgoing) * 1000.0,
			GetClientAvgPackets(client, NetFlow_Incoming));
		action = lowered;
	}

	if (action == 1)
	{
		if (warn > 0 && count >= warn)
			SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, name, count);
		return;
	}

	SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, name, count);

	if (action == 3)
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
ReportLevel(client, DetectionType:type, Handle:info, &count, level, const String:name[], const String:detail[], bool:bLower=true)
{
	new ban = 0;
	if (level == 2)
		ban = -1;
	else if (level >= 3)
		ban = 1;

	Report(client, type, info, count, 1, ban, name, detail, bLower);
}
