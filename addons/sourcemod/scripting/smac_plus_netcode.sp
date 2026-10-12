#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

public Plugin:myinfo =
{
	name = "SMAC Plus: Netcode",
	author = SMAC_AUTHOR,
	description = "Airstuck, Lag Exploit, Backtrack A/B, PSilent and Changer Player Status; CmdNum Jump, Tick Ahead",
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

#define CMDJUMP_MIN			90
#define CMDJUMP_EVENTS		3
#define CMDJUMP_WINDOW		10.0

#define TICKAHEAD_SECONDS	1.0
#define TICKAHEAD_CMDS		3

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
new Handle:g_hCvarBtPatch = INVALID_HANDLE;
new Handle:g_hCvarBtPatchTime = INVALID_HANDLE;

new g_iHistCmd[MAXPLAYERS+1][4];
new g_iHistTick[MAXPLAYERS+1][4];
new g_iHistSrv[MAXPLAYERS+1][4];
new g_iHistLen[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];
new Float:g_fPrevAng[MAXPLAYERS+1][2];
new Float:g_fDYaw[MAXPLAYERS+1];
new g_iMouseSum[MAXPLAYERS+1][2];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];

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

new Float:g_fBtPatchUntil[MAXPLAYERS+1];

new g_iPSilentState[MAXPLAYERS+1];
new g_iPSilentDetects[MAXPLAYERS+1];
new Float:g_fPSilentTime[MAXPLAYERS+1];

new Float:g_fPrevFrameTime;
new Float:g_fFrameEma;
new Float:g_fServerLagUntil;

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarAirstuck = SMAC_CreateConVar("smac_Airstuck_reaction", "1", "Airstuck: 0=off, 1=notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarLag = SMAC_CreateConVar("smac_LagExploit_reaction", "1", "Lag Exploit (tickcount shift): 0=off, 1=notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarBacktrack = SMAC_CreateConVar("smac_eyetest_reaction_Advanced", "1", "Backtrack A (tick on shot) / B (cmdnum): 0=off, 1=notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarPSilentWarn = SMAC_CreateConVar("smac_PSilent_Warning", "1", "PSilent: notify after N detections (0 = never)", _, true, 0.0);
	g_hCvarPSilentBan = SMAC_CreateConVar("smac_PSilent_Ban", "0", "PSilent: punish after |N| (+N ban, -N kick, 0 = never)", _, true, -100.0, true, 100.0);
	g_hCvarFakeStatus = SMAC_CreateConVar("smac_plus_fake_status", "1", "Fake bot that sends mouse: 0=off, 1=notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarCmdJump = SMAC_CreateConVar("smac_CmdNumJump_reaction", "2", "CmdNum Jump (skip > 90): 0=off, 1=notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarTickAhead = SMAC_CreateConVar("smac_TickAhead_reaction", "2", "Tick Ahead (>1 s ahead of server): 0=off, 1=notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarBtPatch = SMAC_CreateConVar("smac_backtrack_patch", "0", "Patch tampered tickcount with engine estimate: 0=off, 1=on", _, true, 0.0, true, 1.0);
	g_hCvarBtPatchTime = SMAC_CreateConVar("smac_backtrack_patch_time", "5.0", "Seconds the backtrack patch stays on after a bad tickcount", _, true, 0.5, true, 60.0);
	g_hCvarAdminImmune = SMAC_CreateConVar("smac_plus_admin_immune", "1", "Never kick/ban admins with ban/root (still logged): 0=off, 1=on", _, true, 0.0, true, 1.0);

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

public Event_WeaponFire(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client))
		return;

	g_iPSilentState[client] = 0;

	if (g_iHistLen[client] >= 2 && GetGameTime() >= g_fIgnoreUntil[client]
		&& (g_iHistTick[client][3] < g_iHistTick[client][2] || g_iHistTick[client][2] < 0))
	{
		CheckBacktrackA(client);
	}

	if (g_iHistLen[client] < 4 || GetGameTime() < g_fIgnoreUntil[client] || IsLagging(client))
		return;

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

	if (IS_CLIENT(client) && IsFakeClient(client) && (mouse[0] != 0 || mouse[1] != 0))
		CheckFakeStatus(client, mouse);

	if (!IsPlaying(client))
	{
		g_iHistLen[client] = 0;
		g_iPSilentState[client] = 0;
		g_iTickAheadStreak[client] = 0;
		return Plugin_Continue;
	}

	new bool:bHasPrev = (g_iHistLen[client] > 0);
	new prevCmd = g_iHistCmd[client][3];
	new prevTick = g_iHistTick[client][3];

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

	if (GetGameTime() >= g_fIgnoreUntil[client] && !IsServerHitch() && !IsClientTimingOut(client))
	{
		if (bHasPrev)
			CheckCmdNumJump(client, buttons, cmdnum, prevCmd, tickcount, prevTick);
		CheckTickAhead(client, cmdnum, tickcount);
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

bool:PatchBacktrack(client, cmdnum, &tickcount, prevCmd, prevTick)
{
	if (!GetConVarBool(g_hCvarBtPatch))
		return false;

	new Float:now = GetGameTime();

	if (cmdnum > prevCmd && tickcount - prevTick != cmdnum - prevCmd
		&& now >= g_fIgnoreUntil[client] && (g_fServerLagUntil <= 0.0 || now >= g_fServerLagUntil))
	{
		g_fBtPatchUntil[client] = now + GetConVarFloat(g_hCvarBtPatchTime);
	}

	if (now >= g_fBtPatchUntil[client])
		return false;

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

	if (!(buttons & IN_ATTACK) || !(g_iPrevButtons[client] & IN_ATTACK))
		return;

	new warn = GetConVarInt(g_hCvarPSilentWarn);
	new ban = GetConVarInt(g_hCvarPSilentBan);
	if (warn == 0 && ban == 0)
	{
		g_iPSilentState[client] = 0;
		return;
	}

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
	Report(client, Detection_PlusPSilent, info, g_iPSilentDetects[client], warn, ban, "PSilent [Active Mode]", sDetail);
	CloseHandle(info);
}

CheckBacktrackA(client)
{
	new level = GetConVarInt(g_hCvarBacktrack);
	if (level <= 0)
		return;

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

	decl String:sIP[32];
	if (level >= 3 && GetClientIP(client, sIP, sizeof(sIP)) && StrEqual(sIP, "127.0.0.1"))
		level = 2;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "mouse_x", mouse[0]);
	KvSetNum(info, "mouse_y", mouse[1]);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "client flagged as a bot sends mouse input %i %i", mouse[0], mouse[1]);
	ReportLevel(client, Detection_PlusFakeStatus, info, g_iFakeDetects[client], level, "Changer Player Status", sDetail);
	CloseHandle(info);
}

DecaySigned(value, Float:lastTime, Float:period)
{
	if (value <= -1 || lastTime <= 0.0)
		return value;

	new steps = RoundToFloor((GetGameTime() - lastTime) / period);
	value -= steps;
	return (value < -1) ? -1 : value;
}

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

LowerAction(client, action)
{
	if (action > 1 && GetClientAvgLatency(client, NetFlow_Outgoing) >= MAX_PING)
		action--;

	if (action > 1 && GetClientAvgPackets(client, NetFlow_Incoming) <= MIN_PACKET_FRAC / GetTickInterval())
		action--;

	return action;
}

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
			SMAC_PrintAdminNotice("%t", "SMAC_PlusNotice", client, name, count);
		return;
	}

	SMAC_PrintAdminNotice("%t", "SMAC_PlusNotice", client, name, count);

	if (action == 3)
	{
		SMAC_LogAction(client, "was banned for %s.", name);
		SMAC_Ban(client, "%s Detection", name);
	}
	else
	{
		SMAC_LogAction(client, "was kicked for %s.", name);
		KickClient(client, "%t", "SMAC_PlusKick");
	}
}

ReportLevel(client, DetectionType:type, Handle:info, &count, level, const String:name[], const String:detail[], bool:bLower=true)
{
	new ban = 0;
	if (level == 2)
		ban = -1;
	else if (level >= 3)
		ban = 1;

	Report(client, type, info, count, 1, ban, name, detail, bLower);
}
