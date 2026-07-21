#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC Testbench — admin-only cheat pattern injector for live CSS34 tests.
 *
 * Filename starts with 0_ so SourceMod loads it BEFORE smac_* detectors;
 * OnPlayerRunCmd angle/button/tick edits are then visible to them.
 *
 * Aim scenarios plant you in front of a live enemy, freeze movement, and
 * snap/lock onto their head — not "walk sideways shooting nowhere".
 *
 * Usage:
 *   sm_smactest soft | bots | setup | stop | status | fire <name>
 *   sm_smactest flick | lock | silent | trigger | autofire | ...
 *
 * Remove/disable this plugin on production.
 */

public Plugin:myinfo =
{
	name = "SMAC: Testbench",
	author = SMAC_AUTHOR,
	description = "Admin cheat-pattern injector for detector QA",
	version = SMAC_VERSION,
	url = SMAC_URL
};

enum
{
	Mode_None = 0,
	Mode_Trigger,
	Mode_AutoFire,
	Mode_PSilent,
	Mode_AimSnap,
	Mode_Flick,
	Mode_Lock,
	Mode_Silent,
	Mode_Bhop,
	Mode_FastRun,
	Mode_Teleport,
	Mode_TpFast,
	Mode_NoRecoilA,
	Mode_NoRecoilB,
	Mode_Wish,
	Mode_Backtrack,
	Mode_CmdSpike,
	Mode_FastShoot,
	Mode_Cycle
};

new Handle:g_hCvarEnable = INVALID_HANDLE;
new Handle:g_hCvarMaxTime = INVALID_HANDLE;

new g_iMode[MAXPLAYERS+1];
new g_iPhase[MAXPLAYERS+1];
new g_iTick[MAXPLAYERS+1];
new g_iReps[MAXPLAYERS+1];
new Float:g_fUntil[MAXPLAYERS+1];
new Float:g_fBaseAng[MAXPLAYERS+1][2];
new Float:g_fAimAng[MAXPLAYERS+1][2];
new g_iAimTarget[MAXPLAYERS+1];
new g_iCycleIdx[MAXPLAYERS+1];
new bool:g_bSoftApplied;
new Float:g_fPrevPunchPitch[MAXPLAYERS+1];
new Float:g_fPlantGrace[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarEnable = CreateConVar("smac_testbench", "1", "Allow SMAC testbench commands.", _, true, 0.0, true, 1.0);
	g_hCvarMaxTime = CreateConVar("smac_testbench_maxtime", "25", "Auto-stop scenario after N seconds.", _, true, 5.0, true, 120.0);

	RegAdminCmd("sm_smactest", Command_Test, ADMFLAG_ROOT, "SMAC detector testbench");
	RegAdminCmd("sm_smactest_stop", Command_Stop, ADMFLAG_ROOT, "Stop active SMAC test");
}

public OnClientDisconnect(client)
{
	ClearMode(client);
	g_fPlantGrace[client] = 0.0;
}

/* Swallow teleport detections caused by our own plant teleport. Intentional
   teleport scenarios (Mode_Teleport/TpFast) use DoTeleportJump which does not
   arm the grace, so they still register. */
public Action:SMAC_OnCheatDetected(client, const String:module[], DetectionType:type, Handle:info)
{
	if ((type == Detection_TeleportHack || type == Detection_TeleportFast)
		&& IS_CLIENT(client) && GetGameTime() < g_fPlantGrace[client])
	{
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

ClearMode(client)
{
	g_iMode[client] = Mode_None;
	g_iPhase[client] = 0;
	g_iTick[client] = 0;
	g_iReps[client] = 0;
	g_fUntil[client] = 0.0;
	g_iCycleIdx[client] = 0;
	g_iAimTarget[client] = 0;
}

bool:IsTester(client)
{
	return (IS_CLIENT(client) && IsClientInGame(client) && !IsFakeClient(client)
		&& CheckCommandAccess(client, "sm_smactest", ADMFLAG_ROOT, true));
}

public Action:Command_Stop(client, args)
{
	if (client > 0)
	{
		ClearMode(client);
		ReplyToCommand(client, "[SMAC Test] stopped.");
	}
	return Plugin_Handled;
}

public Action:Command_Test(client, args)
{
	if (!GetConVarBool(g_hCvarEnable))
	{
		ReplyToCommand(client, "[SMAC Test] disabled (smac_testbench 0).");
		return Plugin_Handled;
	}
	if (client <= 0)
	{
		ReplyToCommand(client, "[SMAC Test] in-game only.");
		return Plugin_Handled;
	}

	if (args < 1)
	{
		PrintHelp(client);
		return Plugin_Handled;
	}

	decl String:arg[32];
	GetCmdArg(1, arg, sizeof(arg));

	if (StrEqual(arg, "help", false) || StrEqual(arg, "list", false))
	{
		PrintHelp(client);
		return Plugin_Handled;
	}
	if (StrEqual(arg, "stop", false))
	{
		ClearMode(client);
		ReplyToCommand(client, "[SMAC Test] stopped.");
		return Plugin_Handled;
	}
	if (StrEqual(arg, "status", false))
	{
		ReplyToCommand(client, "[SMAC Test] mode=%d phase=%d reps=%d target=%d soft=%d",
			g_iMode[client], g_iPhase[client], g_iReps[client], g_iAimTarget[client], g_bSoftApplied);
		return Plugin_Handled;
	}
	if (StrEqual(arg, "soft", false))
	{
		ApplySoftCvars(client);
		return Plugin_Handled;
	}
	if (StrEqual(arg, "bots", false))
	{
		SetupBots(client);
		return Plugin_Handled;
	}
	if (StrEqual(arg, "setup", false))
	{
		ApplySoftCvars(client);
		SetupBots(client);
		if (!IsPlayerAlive(client))
		{
			ReplyToCommand(client, "[SMAC Test] setup done — spawn first, then run a scenario.");
			return Plugin_Handled;
		}
		if (!PlantInFrontOfEnemy(client))
			ReplyToCommand(client, "[SMAC Test] setup done — no enemy yet; wait for bots then try again.");
		else
			ReplyToCommand(client, "[SMAC Test] setup done — planted on enemy. Try: sm_smactest flick");
		return Plugin_Handled;
	}
	if (StrEqual(arg, "fire", false))
	{
		if (args < 2)
		{
			ReplyToCommand(client, "Usage: sm_smactest fire <psilent|trigger|bhop|teleport|norecoil|aimsnap|...>");
			return Plugin_Handled;
		}
		decl String:name[32];
		GetCmdArg(2, name, sizeof(name));
		FirePipeline(client, name);
		return Plugin_Handled;
	}

	new mode = ModeFromName(arg);
	if (mode == Mode_None)
	{
		ReplyToCommand(client, "[SMAC Test] unknown scenario '%s'. Try sm_smactest help", arg);
		return Plugin_Handled;
	}

	if (!IsPlayerAlive(client))
	{
		ReplyToCommand(client, "[SMAC Test] must be alive.");
		return Plugin_Handled;
	}

	if (!g_bSoftApplied)
		ReplyToCommand(client, "[SMAC Test] tip: run sm_smactest soft (or setup) first.");

	StartMode(client, mode);
	return Plugin_Handled;
}

PrintHelp(client)
{
	ReplyToCommand(client, "[SMAC Test] realistic aim = flick | lock | silent (plant on enemy head)");
	ReplyToCommand(client, "  setup | soft | bots | stop | status | fire <name>");
	ReplyToCommand(client, "  flick lock silent trigger autofire psilent aimsnap");
	ReplyToCommand(client, "  bhop fastrun teleport tpfast norecoila norecoilb wish");
	ReplyToCommand(client, "  backtrack cmdspike fastshoot cycle");
}

ModeFromName(const String:arg[])
{
	if (StrEqual(arg, "trigger", false)) return Mode_Trigger;
	if (StrEqual(arg, "autofire", false)) return Mode_AutoFire;
	if (StrEqual(arg, "psilent", false)) return Mode_PSilent;
	if (StrEqual(arg, "aimsnap", false)) return Mode_AimSnap;
	if (StrEqual(arg, "flick", false)) return Mode_Flick;
	if (StrEqual(arg, "lock", false) || StrEqual(arg, "aimlock", false)) return Mode_Lock;
	if (StrEqual(arg, "silent", false)) return Mode_Silent;
	if (StrEqual(arg, "bhop", false)) return Mode_Bhop;
	if (StrEqual(arg, "fastrun", false)) return Mode_FastRun;
	if (StrEqual(arg, "teleport", false)) return Mode_Teleport;
	if (StrEqual(arg, "tpfast", false)) return Mode_TpFast;
	if (StrEqual(arg, "norecoila", false) || StrEqual(arg, "norecoil", false)) return Mode_NoRecoilA;
	if (StrEqual(arg, "norecoilb", false)) return Mode_NoRecoilB;
	if (StrEqual(arg, "wish", false)) return Mode_Wish;
	if (StrEqual(arg, "backtrack", false)) return Mode_Backtrack;
	if (StrEqual(arg, "cmdspike", false)) return Mode_CmdSpike;
	if (StrEqual(arg, "fastshoot", false)) return Mode_FastShoot;
	if (StrEqual(arg, "cycle", false) || StrEqual(arg, "all", false)) return Mode_Cycle;
	return Mode_None;
}

bool:IsAimMode(mode)
{
	return (mode == Mode_Trigger || mode == Mode_AutoFire || mode == Mode_PSilent
		|| mode == Mode_AimSnap || mode == Mode_Flick || mode == Mode_Lock
		|| mode == Mode_Silent || mode == Mode_NoRecoilA || mode == Mode_NoRecoilB);
}

StartMode(client, mode)
{
	ClearMode(client);
	g_iMode[client] = mode;
	g_fPrevPunchPitch[client] = 0.0;

	decl Float:ang[3];
	GetClientEyeAngles(client, ang);
	g_fBaseAng[client][0] = ang[0];
	g_fBaseAng[client][1] = ang[1];

	if (IsAimMode(mode) || mode == Mode_Cycle)
	{
		if (!PlantInFrontOfEnemy(client))
		{
			PrintToChat(client, "[SMAC Test] no live enemy — run sm_smactest bots / setup first.");
			ClearMode(client);
			return;
		}
		RefreshAim(client);
		/* Face the target so the first snap is a real whip, not a random angle. */
		FaceAim(client, false);
	}
	else
	{
		RefreshAim(client);
	}

	if (mode == Mode_Cycle)
	{
		g_iPhase[client] = Mode_Flick;
		g_fUntil[client] = GetGameTime() + 5.0;
		PrintToChat(client, "[SMAC Test] cycle → flick (5s each). Stand still, watch bots.");
		SMAC_LogAction(client, "testbench start mode=cycle");
		return;
	}

	g_fUntil[client] = GetGameTime() + GetConVarFloat(g_hCvarMaxTime);

	decl String:label[32];
	ModeLabel(mode, label, sizeof(label));
	if (g_iAimTarget[client] > 0)
		PrintToChat(client, "[SMAC Test] \x04%s\x01 → target %N for %.0fs",
			label, g_iAimTarget[client], GetConVarFloat(g_hCvarMaxTime));
	else
		PrintToChat(client, "[SMAC Test] running \x04%s\x01 for %.0fs",
			label, GetConVarFloat(g_hCvarMaxTime));
	SMAC_LogAction(client, "testbench start mode=%s", label);

	if (mode == Mode_Teleport)
	{
		DoTeleportJump(client, 1600.0);
		g_iReps[client]++;
	}
	else if (mode == Mode_TpFast)
	{
		CreateTimer(0.15, Timer_TpFastPulse, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

ModeLabel(mode, String:out[], maxlen)
{
	switch (mode)
	{
		case Mode_Trigger: strcopy(out, maxlen, "trigger");
		case Mode_AutoFire: strcopy(out, maxlen, "autofire");
		case Mode_PSilent: strcopy(out, maxlen, "psilent");
		case Mode_AimSnap: strcopy(out, maxlen, "aimsnap");
		case Mode_Flick: strcopy(out, maxlen, "flick");
		case Mode_Lock: strcopy(out, maxlen, "lock");
		case Mode_Silent: strcopy(out, maxlen, "silent");
		case Mode_Bhop: strcopy(out, maxlen, "bhop");
		case Mode_FastRun: strcopy(out, maxlen, "fastrun");
		case Mode_Teleport: strcopy(out, maxlen, "teleport");
		case Mode_TpFast: strcopy(out, maxlen, "tpfast");
		case Mode_NoRecoilA: strcopy(out, maxlen, "norecoila");
		case Mode_NoRecoilB: strcopy(out, maxlen, "norecoilb");
		case Mode_Wish: strcopy(out, maxlen, "wish");
		case Mode_Backtrack: strcopy(out, maxlen, "backtrack");
		case Mode_CmdSpike: strcopy(out, maxlen, "cmdspike");
		case Mode_FastShoot: strcopy(out, maxlen, "fastshoot");
		case Mode_Cycle: strcopy(out, maxlen, "cycle");
		default: strcopy(out, maxlen, "none");
	}
}

SetupBots(client)
{
	ServerCommand("bot_quota 6");
	ServerCommand("bot_quota_mode fill");
	ServerCommand("bot_stop 1");
	ServerCommand("bot_zombie 1");
	ServerCommand("bot_mimic 0");
	ServerCommand("mp_limitteams 0");
	ServerCommand("mp_autoteambalance 0");
	ReplyToCommand(client, "[SMAC Test] bots filled + stopped. Join opposite team, then: sm_smactest setup");
}

bool:PlantInFrontOfEnemy(client)
{
	new tgt = FindNearestEnemy(client);
	if (tgt <= 0)
		return false;

	g_iAimTarget[client] = tgt;

	decl Float:tOrigin[3], Float:tAng[3], Float:fwd[3], Float:plant[3], Float:look[3], Float:dir[3], Float:view[3];
	GetClientAbsOrigin(tgt, tOrigin);
	GetClientEyeAngles(tgt, tAng);
	tAng[0] = 0.0;
	GetAngleVectors(tAng, fwd, NULL_VECTOR, NULL_VECTOR);

	/* Stand ~200u in front of the bot, facing their chest/head. */
	plant[0] = tOrigin[0] + fwd[0] * 200.0;
	plant[1] = tOrigin[1] + fwd[1] * 200.0;
	plant[2] = tOrigin[2] + 8.0;

	GetClientEyePosition(tgt, look);
	look[2] -= 8.0; /* upper chest / head */
	GetClientEyePosition(client, dir);
	/* After teleport eye moves — compute from plant approx. */
	dir[0] = plant[0]; dir[1] = plant[1]; dir[2] = plant[2] + 64.0;
	MakeVectorFromPoints(dir, look, dir);
	GetVectorAngles(dir, view);

	decl Float:zeroVel[3];
	zeroVel[0] = 0.0; zeroVel[1] = 0.0; zeroVel[2] = 0.0;
	/* Our own plant teleport must not read as a teleport hack. */
	g_fPlantGrace[client] = GetGameTime() + 0.75;
	TeleportEntity(client, plant, view, zeroVel);
	g_fBaseAng[client][0] = view[0];
	g_fBaseAng[client][1] = view[1] + 70.0; /* resting look is off-target for flick tests */
	NormalizeYaw(g_fBaseAng[client][1]);

	/* Freeze the target bot so the lock is on a real body, not a moving ghost. */
	if (IsFakeClient(tgt))
	{
		SetEntityMoveType(tgt, MOVETYPE_NONE);
		TeleportEntity(tgt, NULL_VECTOR, NULL_VECTOR, zeroVel);
	}
	return true;
}

FaceAim(client, bool:offTarget)
{
	decl Float:view[3], Float:zeroVel[3];
	if (offTarget)
	{
		view[0] = g_fBaseAng[client][0];
		view[1] = g_fBaseAng[client][1];
	}
	else
	{
		view[0] = g_fAimAng[client][0];
		view[1] = g_fAimAng[client][1];
	}
	view[2] = 0.0;
	zeroVel[0] = 0.0; zeroVel[1] = 0.0; zeroVel[2] = 0.0;
	TeleportEntity(client, NULL_VECTOR, view, zeroVel);
}

NormalizeYaw(&Float:yaw)
{
	while (yaw > 180.0) yaw -= 360.0;
	while (yaw < -180.0) yaw += 360.0;
}

RefreshAim(client)
{
	new tgt = g_iAimTarget[client];
	if (tgt <= 0 || !IsClientInGame(tgt) || !IsPlayerAlive(tgt)
		|| GetClientTeam(tgt) == GetClientTeam(client))
	{
		tgt = FindNearestEnemy(client);
		g_iAimTarget[client] = tgt;
	}
	if (tgt <= 0)
	{
		g_fAimAng[client][0] = g_fBaseAng[client][0];
		g_fAimAng[client][1] = g_fBaseAng[client][1];
		return;
	}

	decl Float:eye[3], Float:tgtPos[3], Float:dir[3], Float:ang[3];
	GetClientEyePosition(client, eye);
	GetClientEyePosition(tgt, tgtPos);
	/* Aim at head (eye pos), not feet. */
	MakeVectorFromPoints(eye, tgtPos, dir);
	GetVectorAngles(dir, ang);
	g_fAimAng[client][0] = ang[0];
	g_fAimAng[client][1] = ang[1];
}

FindNearestEnemy(client)
{
	new best = 0;
	new Float:bestDist = 999999.0;
	decl Float:a[3], Float:b[3];
	GetClientAbsOrigin(client, a);
	new i;
	for (i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || !IsPlayerAlive(i))
			continue;
		if (GetClientTeam(i) == GetClientTeam(client) || GetClientTeam(i) <= 1)
			continue;
		GetClientAbsOrigin(i, b);
		new Float:d = GetVectorDistance(a, b);
		if (d < bestDist)
		{
			bestDist = d;
			best = i;
		}
	}
	return best;
}

/* Zero movement so aim tests don't look like strafing into the void. */
FreezeMove(&buttons, Float:vel[3])
{
	buttons &= ~(IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT | IN_JUMP | IN_DUCK);
	vel[0] = 0.0;
	vel[1] = 0.0;
	vel[2] = 0.0;
}

ApplySoftCvars(client)
{
	ServerCommand("smac_observe_new 1");
	ServerCommand("smac_log_verbose 1");
	ServerCommand("smac_AdvancedTrigger_Warning 1");
	ServerCommand("smac_AdvancedTrigger_Ban 0");
	ServerCommand("smac_AdvancedAutoFire_Warning 1");
	ServerCommand("smac_AdvancedAutoFire_Ban 0");
	ServerCommand("smac_FD_BHOP 1");
	ServerCommand("smac_SpeedTeleport -2000");
	ServerCommand("smac_SpeedTeleport_fast 4");
	ServerCommand("smac_SpeedLimitDetect 0");
	ServerCommand("smac_NoS_NoR 1");
	ServerCommand("smac_NoR_Ban 0");
	ServerCommand("smac_psilent_ban 0");
	ServerCommand("smac_psilent_ultra 1");
	ServerCommand("smac_aimsnap 1");
	ServerCommand("smac_aimsnap_ban 0");
	ServerCommand("smac_backtrack_ban 0");
	ServerCommand("smac_cmdspike_ban 0");
	ServerCommand("smac_fastreload_ban 0");
	ServerCommand("smac_fastshoot_ban 0");
	ServerCommand("smac_AIM_Kill 0");
	ServerCommand("smac_SoundESP 0");
	ServerCommand("smac_triggerbot_ban 0");
	ServerCommand("smac_move_wish_ban 0");
	ServerCommand("smac_aimbot_Advanced_Ban_AMSAF 0");
	ServerCommand("smac_ultra_aim 1");
	g_bSoftApplied = true;
	ReplyToCommand(client, "[SMAC Test] soft cvars applied (notice-first, verbose log).");
}

FirePipeline(client, const String:name[])
{
	new DetectionType:det = Detection_Unknown;
	if (StrEqual(name, "psilent", false)) det = Detection_pSilent;
	else if (StrEqual(name, "trigger", false)) det = Detection_AdvancedTrigger;
	else if (StrEqual(name, "autofire", false)) det = Detection_AdvancedAutoFire;
	else if (StrEqual(name, "bhop", false)) det = Detection_FastBhop;
	else if (StrEqual(name, "fastrun", false)) det = Detection_FdFastRun;
	else if (StrEqual(name, "teleport", false)) det = Detection_TeleportHack;
	else if (StrEqual(name, "tpfast", false)) det = Detection_TeleportFast;
	else if (StrEqual(name, "norecoil", false) || StrEqual(name, "norecoila", false)) det = Detection_NoRecoil;
	else if (StrEqual(name, "norecoilb", false)) det = Detection_NoRecoilB;
	else if (StrEqual(name, "aimsnap", false)) det = Detection_Aimsnap;
	else if (StrEqual(name, "aimkill", false)) det = Detection_AimKill;
	else if (StrEqual(name, "backtrack", false)) det = Detection_Backtrack;
	else if (StrEqual(name, "cmdspike", false)) det = Detection_CmdnumSpike;
	else if (StrEqual(name, "speedlimit", false)) det = Detection_SpeedLimit;
	else if (StrEqual(name, "soundesp", false)) det = Detection_SoundESP;
	else if (StrEqual(name, "wish", false)) det = Detection_WishVelocity;
	else if (StrEqual(name, "fastreload", false)) det = Detection_FastReload;
	else if (StrEqual(name, "fastshoot", false)) det = Detection_FastShoot;
	else
	{
		ReplyToCommand(client, "[SMAC Test] unknown fire name.");
		return;
	}

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", 1);
	KvSetString(info, "source", "testbench");
	if (SMAC_CheatDetected(client, det, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("[SMAC Test] pipeline fire %s on %N", name, client);
		SMAC_LogAction(client, "testbench pipeline fire name=%s", name);
		ReplyToCommand(client, "[SMAC Test] fired Detection pipeline: %s", name);
	}
	else
	{
		ReplyToCommand(client, "[SMAC Test] blocked by immunity/forward for %s", name);
	}
	CloseHandle(info);
}

DoTeleportJump(client, Float:dist)
{
	decl Float:origin[3], Float:ang[3], Float:fwd[3];
	GetClientAbsOrigin(client, origin);
	GetClientEyeAngles(client, ang);
	ang[0] = 0.0;
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	origin[0] += fwd[0] * dist;
	origin[1] += fwd[1] * dist;
	TeleportEntity(client, origin, NULL_VECTOR, NULL_VECTOR);
}

public Action:Timer_TpFastPulse(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (!IS_CLIENT(client) || g_iMode[client] != Mode_TpFast)
		return Plugin_Stop;
	if (GetGameTime() >= g_fUntil[client] || !IsPlayerAlive(client))
	{
		ClearMode(client);
		PrintToChat(client, "[SMAC Test] tpfast done.");
		return Plugin_Stop;
	}
	DoTeleportJump(client, 550.0);
	g_iReps[client]++;
	if (g_iReps[client] >= 4)
	{
		ClearMode(client);
		PrintToChat(client, "[SMAC Test] tpfast done (%d jumps).", g_iReps[client]);
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon,
	&subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (g_iMode[client] == Mode_None)
		return Plugin_Continue;
	if (!IsTester(client) || !IsPlayerAlive(client))
	{
		ClearMode(client);
		return Plugin_Continue;
	}
	if (GetGameTime() >= g_fUntil[client])
	{
		if (g_iMode[client] == Mode_Cycle)
		{
			AdvanceCycle(client);
			if (g_iMode[client] == Mode_None)
				return Plugin_Continue;
		}
		else
		{
			PrintToChat(client, "[SMAC Test] auto-stop (%d reps).", g_iReps[client]);
			ClearMode(client);
			return Plugin_Continue;
		}
	}

	new mode = g_iMode[client];
	new bool:changed = false;

	switch (mode)
	{
		case Mode_Cycle:
			changed = RunCycleChild(client, buttons, vel, angles, cmdnum, tickcount, mouse);
		case Mode_Trigger:
			changed = SimTrigger(client, buttons, vel, angles, mouse);
		case Mode_AutoFire:
			changed = SimAutoFire(client, buttons, vel, angles, mouse);
		case Mode_PSilent:
			changed = SimPSilent(client, buttons, vel, angles, mouse);
		case Mode_AimSnap:
			changed = SimAimSnap(client, buttons, vel, angles, mouse);
		case Mode_Flick:
			changed = SimFlick(client, buttons, vel, angles, mouse);
		case Mode_Lock:
			changed = SimLock(client, buttons, vel, angles, mouse);
		case Mode_Silent:
			changed = SimSilent(client, buttons, vel, angles, mouse);
		case Mode_Bhop:
			changed = SimBhop(client, buttons, vel);
		case Mode_FastRun:
			changed = SimFastRun(client, vel);
		case Mode_NoRecoilA:
			changed = SimNoRecoilA(client, buttons, vel, angles);
		case Mode_NoRecoilB:
			changed = SimNoRecoilB(client, buttons, vel, angles);
		case Mode_Wish:
			changed = SimWish(client, buttons, vel);
		case Mode_Backtrack:
			changed = SimBacktrack(client, tickcount);
		case Mode_CmdSpike:
			changed = SimCmdSpike(client, cmdnum);
		case Mode_FastShoot:
			changed = SimFastShoot(client, buttons);
		case Mode_Teleport, Mode_TpFast:
			return Plugin_Continue;
	}

	g_iTick[client]++;
	return changed ? Plugin_Changed : Plugin_Continue;
}

bool:RunCycleChild(client, &buttons, Float:vel[3], Float:angles[3], &cmdnum, &tickcount, mouse[2])
{
	new sub = g_iPhase[client];
	new bool:ch = false;
	switch (sub)
	{
		case Mode_Flick: ch = SimFlick(client, buttons, vel, angles, mouse);
		case Mode_Lock: ch = SimLock(client, buttons, vel, angles, mouse);
		case Mode_Silent: ch = SimSilent(client, buttons, vel, angles, mouse);
		case Mode_Trigger: ch = SimTrigger(client, buttons, vel, angles, mouse);
		case Mode_AimSnap: ch = SimAimSnap(client, buttons, vel, angles, mouse);
		case Mode_Wish: ch = SimWish(client, buttons, vel);
		case Mode_Backtrack: ch = SimBacktrack(client, tickcount);
		case Mode_CmdSpike: ch = SimCmdSpike(client, cmdnum);
	}
	return ch;
}

AdvanceCycle(client)
{
	new cur = g_iPhase[client];
	new next = Mode_None;
	if (cur == Mode_Flick) next = Mode_Lock;
	else if (cur == Mode_Lock) next = Mode_Silent;
	else if (cur == Mode_Silent) next = Mode_Trigger;
	else if (cur == Mode_Trigger) next = Mode_AimSnap;
	else if (cur == Mode_AimSnap) next = Mode_None;

	if (next == Mode_None)
	{
		PrintToChat(client, "[SMAC Test] cycle complete.");
		ClearMode(client);
		return;
	}

	g_iPhase[client] = next;
	g_iTick[client] = 0;
	g_iReps[client] = 0;
	g_fUntil[client] = GetGameTime() + 5.0;
	PlantInFrontOfEnemy(client);
	RefreshAim(client);

	decl String:label[32];
	ModeLabel(next, label, sizeof(label));
	PrintToChat(client, "[SMAC Test] cycle → %s", label);
}

/* ------------------------------------------------------------------ */
/* Realistic aim injectors — plant on enemy, freeze move, hit the head */
/* ------------------------------------------------------------------ */

bool:SimFlick(client, &buttons, Float:vel[3], Float:angles[3], mouse[2])
{
	/*
	 * Real aimbot flick: look 70° off target → calm ticks → one-tick snap
	 * onto head → fire → settle still on target → look away again.
	 */
	FreezeMove(buttons, vel);
	RefreshAim(client);
	new step = g_iTick[client] % 14;

	if (step < 6)
	{
		/* Resting off-target (client sees this via TeleportEntity). */
		angles[0] = g_fBaseAng[client][0];
		angles[1] = g_fBaseAng[client][1];
		buttons &= ~IN_ATTACK;
		mouse[0] = 0; mouse[1] = 0;
		if (step == 0)
			FaceAim(client, true);
	}
	else if (step == 6)
	{
		/* Isolated snap onto head — previous tick was calm. */
		angles[0] = g_fAimAng[client][0];
		angles[1] = g_fAimAng[client][1];
		buttons |= IN_ATTACK;
		mouse[0] = 0; mouse[1] = 0; /* silent snap */
		g_iReps[client]++;
		FaceAim(client, false);
	}
	else if (step < 11)
	{
		/* Settle on head (no overshoot). */
		angles[0] = g_fAimAng[client][0];
		angles[1] = g_fAimAng[client][1];
		buttons &= ~IN_ATTACK;
		mouse[0] = 0; mouse[1] = 0;
	}
	else
	{
		angles[0] = g_fBaseAng[client][0];
		angles[1] = g_fBaseAng[client][1];
		buttons &= ~IN_ATTACK;
		mouse[0] = 0; mouse[1] = 0;
		if (step == 13)
			FaceAim(client, true);
	}
	return true;
}

bool:SimLock(client, &buttons, Float:vel[3], Float:angles[3], mouse[2])
{
	/*
	 * Soft aimlock: view glued to enemy head every tick while firing.
	 * Target is nudged sideways so angular path is non-zero (autofire/lock).
	 */
	FreezeMove(buttons, vel);
	RefreshAim(client);

	new tgt = g_iAimTarget[client];
	if (IS_CLIENT(tgt) && IsClientInGame(tgt) && IsPlayerAlive(tgt) && IsFakeClient(tgt))
	{
		decl Float:o[3];
		GetClientAbsOrigin(tgt, o);
		o[0] += (g_iTick[client] % 2 == 0) ? 2.5 : -2.5;
		TeleportEntity(tgt, o, NULL_VECTOR, NULL_VECTOR);
		RefreshAim(client);
	}

	angles[0] = g_fAimAng[client][0];
	angles[1] = g_fAimAng[client][1];
	buttons |= IN_ATTACK;
	mouse[0] = 0;
	mouse[1] = 0;
	if ((g_iTick[client] % 5) == 0)
		FaceAim(client, false);
	g_iReps[client]++;
	return true;
}

bool:SimSilent(client, &buttons, Float:vel[3], Float:angles[3], mouse[2])
{
	/*
	 * pSilent / silent-aim: client view stays off-target (base), but the
	 * usercmd for the shot tick aims at the head with clean mouse[].
	 * Visually you keep looking aside while shots go into the bot.
	 */
	FreezeMove(buttons, vel);
	RefreshAim(client);
	new step = g_iTick[client] % 3;

	if (step == 1)
	{
		angles[0] = g_fAimAng[client][0];
		angles[1] = g_fAimAng[client][1];
		buttons |= IN_ATTACK;
		g_iReps[client]++;
	}
	else
	{
		angles[0] = g_fBaseAng[client][0];
		angles[1] = g_fBaseAng[client][1];
		buttons &= ~IN_ATTACK;
		if (step == 0)
			FaceAim(client, true); /* keep client view off-target */
	}
	mouse[0] = 0;
	mouse[1] = 0;
	return true;
}

bool:SimTrigger(client, &buttons, Float:vel[3], Float:angles[3], mouse[2])
{
	/* Off head → acquire+attack same tick (tick-perfect trigger). */
	FreezeMove(buttons, vel);
	RefreshAim(client);
	new step = g_iTick[client] % 10;
	if (step < 6)
	{
		angles[0] = g_fAimAng[client][0];
		angles[1] = g_fAimAng[client][1] + 40.0;
		buttons &= ~IN_ATTACK;
		if (step == 0)
			FaceAim(client, true);
	}
	else if (step == 6)
	{
		angles[0] = g_fAimAng[client][0];
		angles[1] = g_fAimAng[client][1];
		buttons |= IN_ATTACK;
		g_iReps[client]++;
		FaceAim(client, false);
	}
	else
	{
		angles[0] = g_fAimAng[client][0];
		angles[1] = g_fAimAng[client][1];
		buttons &= ~IN_ATTACK;
	}
	mouse[0] = 0; mouse[1] = 0;
	return true;
}

bool:SimAutoFire(client, &buttons, Float:vel[3], Float:angles[3], mouse[2])
{
	/* Hold fire off-target, then lock onto moving head while still holding. */
	FreezeMove(buttons, vel);
	RefreshAim(client);
	new step = g_iTick[client] % 50;
	buttons |= IN_ATTACK;
	mouse[0] = 0; mouse[1] = 0;

	if (step < 12)
	{
		angles[0] = g_fAimAng[client][0];
		angles[1] = g_fAimAng[client][1] + 45.0;
		if (step == 0)
			FaceAim(client, true);
	}
	else
	{
		new tgt = g_iAimTarget[client];
		if (IS_CLIENT(tgt) && IsClientInGame(tgt) && IsPlayerAlive(tgt) && IsFakeClient(tgt))
		{
			decl Float:o[3];
			GetClientAbsOrigin(tgt, o);
			o[1] += (step % 2 == 0) ? 3.0 : -3.0;
			TeleportEntity(tgt, o, NULL_VECTOR, NULL_VECTOR);
			RefreshAim(client);
		}
		angles[0] = g_fAimAng[client][0];
		angles[1] = g_fAimAng[client][1];
		if (step == 12)
			FaceAim(client, false);
		if (step == 49)
			g_iReps[client]++;
	}
	return true;
}

bool:SimPSilent(client, &buttons, Float:vel[3], Float:angles[3], mouse[2])
{
	return SimSilent(client, buttons, vel, angles, mouse);
}

bool:SimAimSnap(client, &buttons, Float:vel[3], Float:angles[3], mouse[2])
{
	/* Quiet → big snap onto head → quiet settle. */
	FreezeMove(buttons, vel);
	RefreshAim(client);
	new step = g_iTick[client] % 8;
	buttons |= IN_ATTACK;
	mouse[0] = 0; mouse[1] = 0;

	new Float:y = g_fBaseAng[client][1];
	new Float:p = g_fBaseAng[client][0];
	if (step <= 1)
	{
		angles[0] = p + (step * 0.05);
		angles[1] = y + (step * 0.05);
		if (step == 0)
			FaceAim(client, true);
	}
	else if (step == 2)
	{
		angles[0] = g_fAimAng[client][0];
		angles[1] = g_fAimAng[client][1];
		g_iReps[client]++;
		FaceAim(client, false);
	}
	else
	{
		angles[0] = g_fAimAng[client][0] + float(step - 2) * 0.04;
		angles[1] = g_fAimAng[client][1] + float(step - 2) * 0.03;
		g_fBaseAng[client][0] = angles[0];
		g_fBaseAng[client][1] = angles[1];
	}
	return true;
}

bool:SimBhop(client, &buttons, Float:vel[3])
{
	decl Float:v[3];
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", v);
	new Float:speed = SquareRoot((v[0] * v[0]) + (v[1] * v[1]));
	if (speed < 260.0)
	{
		decl Float:ang[3], Float:fwd[3];
		GetClientEyeAngles(client, ang);
		ang[0] = 0.0;
		GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
		v[0] = fwd[0] * 280.0;
		v[1] = fwd[1] * 280.0;
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, v);
	}

	new step = g_iTick[client] % 4;
	new flags = GetEntityFlags(client);
	if (step == 0 || step == 1)
	{
		SetEntityFlags(client, flags | FL_ONGROUND);
		buttons &= ~IN_JUMP;
	}
	else
	{
		SetEntityFlags(client, flags & ~FL_ONGROUND);
		buttons |= IN_JUMP;
		vel[2] = 300.0;
		g_iReps[client]++;
	}
	buttons |= IN_FORWARD;
	vel[0] = 400.0;
	return true;
}

bool:SimFastRun(client, Float:vel[3])
{
	decl Float:v[3], Float:ang[3], Float:fwd[3];
	GetClientEyeAngles(client, ang);
	ang[0] = 0.0;
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	v[0] = fwd[0] * 400.0;
	v[1] = fwd[1] * 400.0;
	v[2] = 0.0;
	TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, v);
	SetEntityFlags(client, GetEntityFlags(client) | FL_ONGROUND);
	vel[0] = 400.0;
	vel[1] = 0.0;
	g_iReps[client]++;
	return true;
}

bool:SimNoRecoilA(client, &buttons, Float:vel[3], Float:angles[3])
{
	FreezeMove(buttons, vel);
	RefreshAim(client);
	buttons |= IN_ATTACK;
	decl Float:zero[3];
	zero[0] = 0.0; zero[1] = 0.0; zero[2] = 0.0;
	SetEntPropVector(client, Prop_Send, "m_vecPunchAngle", zero);
	angles[0] = g_fAimAng[client][0];
	angles[1] = g_fAimAng[client][1];
	g_iReps[client]++;
	return true;
}

bool:SimNoRecoilB(client, &buttons, Float:vel[3], Float:angles[3])
{
	/*
	 * Perfect RCS: view pitch mirrors punch pitch * 2 every tick while
	 * spraying at the target head — matches the rewritten Mode B detector.
	 */
	FreezeMove(buttons, vel);
	RefreshAim(client);
	buttons |= IN_ATTACK;

	decl Float:punch[3];
	punch[0] = -1.8 - (float(g_iTick[client] % 8) * 0.35);
	punch[1] = 0.4;
	punch[2] = 0.0;
	SetEntPropVector(client, Prop_Send, "m_vecPunchAngle", punch);

	new Float:punchDelta = punch[0] - g_fPrevPunchPitch[client];
	if (g_iTick[client] == 0)
	{
		angles[0] = g_fAimAng[client][0];
		angles[1] = g_fAimAng[client][1];
	}
	else
	{
		/* angle -= punchDelta * 2  (CS:S classic norecoil) */
		angles[0] = g_fAimAng[client][0] - (punchDelta * 2.0);
		angles[1] = g_fAimAng[client][1];
		g_fAimAng[client][0] = angles[0];
	}
	g_fPrevPunchPitch[client] = punch[0];
	g_iReps[client]++;
	return true;
}

bool:SimWish(client, &buttons, Float:vel[3])
{
	buttons |= IN_FORWARD;
	vel[0] = 194.3998;
	vel[1] = 0.0;
	g_iReps[client]++;
	return true;
}

bool:SimBacktrack(client, &tickcount)
{
	tickcount = GetGameTickCount() - 64;
	g_iReps[client]++;
	return true;
}

bool:SimCmdSpike(client, &cmdnum)
{
	if (g_iTick[client] < 5)
		return false;
	cmdnum += 64;
	g_iReps[client]++;
	if (g_iReps[client] >= 3)
	{
		PrintToChat(client, "[SMAC Test] cmdspike pulses sent.");
		ClearMode(client);
	}
	return true;
}

bool:SimFastShoot(client, &buttons)
{
	new wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (wep > MaxClients && IsValidEntity(wep))
	{
		new Float:next = GetGameTime() + 1.0;
		SetEntPropFloat(wep, Prop_Send, "m_flNextPrimaryAttack", next);
	}
	if ((g_iTick[client] % 2) == 0)
		buttons |= IN_ATTACK;
	else
		buttons &= ~IN_ATTACK;
	g_iReps[client]++;
	return true;
}
