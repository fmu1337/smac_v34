#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * Optional strafe-hack module. Ships in plugins/disabled; move it to plugins/ to use it.
 *
 * Ported ideas (GPLv3 sources, rewritten for SourceMod 1.6 / CSS v34):
 *   Oryx AC strafe module (Rusty, shavit) - BASH remake, perfect turn rate, steady turn;
 *   Cow Anti-Cheat (Eric Edson) - silent strafe, AHK strafe.
 *
 *   Strafe Sync    - in the air, for every strafe: the tick the A/D (W/S) key changed minus the
 *                    tick the mouse changed direction. Humans scatter around a few ticks; a
 *                    strafe hack or a sync script hits 0 again and again. Every 30 strafes:
 *                    sum |offset| < 15 low, < 9 medium; zeroes > 18 low, > 22 medium, > 25 high.
 *   Perfect Turn   - the yaw change per tick equals the optimal air-strafe angle
 *                    asin(30 / speed) of the previous tick within 1/128 of it.
 *                    10 ticks in a row low, 33 medium, 48 high.
 *   Steady Turn    - the same yaw change (within 1/128) for 50 ticks without +left / +right:
 *                    a forged constant turn. Low. Oryx also had a ground-only "prestrafe tool"
 *                    variant tied to 1.2 deg/tick; this one covers it without the constant.
 *   Silent Strafe  - sidemove changes sign on every cmd. Keys cannot do that (one cmd per tick,
 *                    keys change once per frame), a strafe hack does. 10 in a row medium,
 *                    20 high.
 *   AHK Mouse      - in the air, while above the jump height, the same |mouse dx| >= 10 for 25
 *                    cmds in a row (a script moving the mouse). 10 such runs medium.
 *
 * Low is logged only, medium also notifies admins, high also kicks/bans when the check's
 * cvar is 2/3. Defaults: 1 (log and notice, never punish). Nothing is judged for 60 ticks after
 * a spawn, a trigger_teleport or a position jump, on ladders / noclip or in water.
 *
 * sm_strafe_stats <target> prints the last 30 strafe offsets.
 */

public Plugin:myinfo =
{
	name = "SMAC: Strafe Checks",
	author = SMAC_AUTHOR,
	description = "Optional strafe sync, perfect/steady turn, silent strafe and AHK mouse checks, after Oryx AC and Cow AC",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define SAMPLE_SIZE			30
#define IGNORE_TICKS		60
#define MAX_STRAFE_OFFSET	25
#define BASH_COOLDOWN		35

#define MIN_DELTA			0.015625
#define MAX_SPEED			2560.0

#define STEADY_STREAK		50
#define SILENT_MEDIUM		10
#define SILENT_HIGH			20
#define AHK_MIN_DX			10
#define AHK_STREAK			25
#define AHK_RUNS			10

#define SEV_LOW				1
#define SEV_MEDIUM			2
#define SEV_HIGH			3

#define CHECK_SYNC			0
#define CHECK_TURN			1
#define CHECK_SILENT		2
#define CHECK_AHK			3
#define CHECK_COUNT			4

new Handle:g_hCvarCheck[CHECK_COUNT];
new Handle:g_hCvarAdminImmune = INVALID_HANDLE;
new bool:g_bMouse;

new g_iAbsTicks[MAXPLAYERS+1];
new g_iIgnoreUntil[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];
new Float:g_fPrevOrigin[MAXPLAYERS+1][3];
new bool:g_bHasPrevOrigin[MAXPLAYERS+1];

new Float:g_fPrevYaw[MAXPLAYERS+1];
new Float:g_fPrevDelta[MAXPLAYERS+1];
new Float:g_fPrevDeltaAbs[MAXPLAYERS+1];
new Float:g_fPrevOptimal[MAXPLAYERS+1];

new bool:g_bKeyChanged[MAXPLAYERS+1];
new bool:g_bDirChanged[MAXPLAYERS+1];
new g_iKeyTick[MAXPLAYERS+1];
new g_iAngTick[MAXPLAYERS+1];
new g_iStrafes[MAXPLAYERS+1][SAMPLE_SIZE];
new g_iStrafeCount[MAXPLAYERS+1];
new g_iBashCooldown[MAXPLAYERS+1];

new g_iPerfTurn[MAXPLAYERS+1];
new g_iSteadyTurn[MAXPLAYERS+1];

new Float:g_fPrevSide[MAXPLAYERS+1];
new g_iSideFlips[MAXPLAYERS+1];

new bool:g_bPrevOnGround[MAXPLAYERS+1];
new Float:g_fJumpZ[MAXPLAYERS+1];
new g_iAhkValue[MAXPLAYERS+1];
new g_iAhkStreak[MAXPLAYERS+1];
new g_iAhkRuns[MAXPLAYERS+1];

new g_iDetects[MAXPLAYERS+1][CHECK_COUNT];

public OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("smac.phrases");

	g_hCvarCheck[CHECK_SYNC] = SMAC_CreateConVar("smac_strafe_sync", "1", "Strafe Sync (key vs mouse direction change, Oryx/BASH): 0=off, 1=log/notice, 2=kick on high, 3=ban on high", _, true, 0.0, true, 3.0);
	g_hCvarCheck[CHECK_TURN] = SMAC_CreateConVar("smac_strafe_turn", "1", "Perfect Turn / Steady Turn (Oryx): 0=off, 1=log/notice, 2=kick on high, 3=ban on high", _, true, 0.0, true, 3.0);
	g_hCvarCheck[CHECK_SILENT] = SMAC_CreateConVar("smac_strafe_silent", "1", "Silent Strafe (sidemove flips every cmd, Cow AC): 0=off, 1=log/notice, 2=kick on high, 3=ban on high", _, true, 0.0, true, 3.0);
	g_hCvarCheck[CHECK_AHK] = SMAC_CreateConVar("smac_strafe_ahk", "1", "AHK Mouse (constant mouse dx in the air, Cow AC): 0=off, 1=log/notice", _, true, 0.0, true, 1.0);
	g_hCvarAdminImmune = SMAC_CreateConVar("smac_ultra_admin_immune", "1", "Never kick/ban admins with ban/root flag (detections are still logged).", _, true, 0.0, true, 1.0);

	// mouse[2] needs the 11-parameter OnPlayerRunCmd (SourceMod 1.5.0+); only AHK Mouse uses it.
	g_bMouse = (GetFeatureStatus(FeatureType_Capability, FEATURECAP_PLAYERRUNCMD_11PARAMS) == FeatureStatus_Available);

	RegAdminCmd("sm_strafe_stats", Command_StrafeStats, ADMFLAG_GENERIC, "sm_strafe_stats <target> - last strafe key/mouse offsets in ticks");

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
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
	g_iAbsTicks[client] = 0;
	g_iIgnoreUntil[client] = IGNORE_TICKS;
	g_iPrevButtons[client] = 0;
	g_bHasPrevOrigin[client] = false;

	g_fPrevYaw[client] = 0.0;
	g_fPrevDelta[client] = 0.0;
	g_fPrevDeltaAbs[client] = 0.0;
	g_fPrevOptimal[client] = -1.0;

	g_bKeyChanged[client] = false;
	g_bDirChanged[client] = false;
	g_iStrafeCount[client] = 0;
	g_iBashCooldown[client] = 0;

	g_iPerfTurn[client] = 0;
	g_iSteadyTurn[client] = 0;

	g_fPrevSide[client] = 0.0;
	g_iSideFlips[client] = 0;

	g_bPrevOnGround[client] = true;
	g_fJumpZ[client] = 0.0;
	g_iAhkValue[client] = 0;
	g_iAhkStreak[client] = 0;
	g_iAhkRuns[client] = 0;

	for (new i = 0; i < CHECK_COUNT; i++)
		g_iDetects[client][i] = 0;
}

public Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
		IgnoreClient(client);
}

public Output_Teleport(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator))
		IgnoreClient(activator);
}

IgnoreClient(client)
{
	g_iIgnoreUntil[client] = g_iAbsTicks[client] + IGNORE_TICKS;
	g_bKeyChanged[client] = false;
	g_bDirChanged[client] = false;
	g_iPerfTurn[client] = 0;
	g_iSteadyTurn[client] = 0;
	g_iSideFlips[client] = 0;
	g_iAhkStreak[client] = 0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!IS_CLIENT(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	g_iAbsTicks[client]++;

	new Float:delta = angles[1] - g_fPrevYaw[client];
	g_fPrevYaw[client] = angles[1];

	// A position jump bigger than the movement allows is a teleport we did not see.
	decl Float:vOrigin[3], Float:vVelocity[3];
	GetClientAbsOrigin(client, vOrigin);
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vVelocity);

	if (g_bHasPrevOrigin[client]
		&& GetVectorDistance(vOrigin, g_fPrevOrigin[client]) > GetVectorLength(vVelocity) * GetTickInterval() * 2.0 + 64.0)
	{
		IgnoreClient(client);
	}

	g_fPrevOrigin[client] = vOrigin;
	g_bHasPrevOrigin[client] = true;

	new flags = GetEntityFlags(client);
	new bool:bOnGround = (flags & FL_ONGROUND) != 0;

	if (GetEntityMoveType(client) != MOVETYPE_WALK || (flags & FL_INWATER))
	{
		IgnoreClient(client);
		Finish(client, buttons, vel, bOnGround, vOrigin, delta, vVelocity);
		return Plugin_Continue;
	}

	if (g_iAbsTicks[client] < g_iIgnoreUntil[client])
	{
		Finish(client, buttons, vel, bOnGround, vOrigin, delta, vVelocity);
		return Plugin_Continue;
	}

	if (GetConVarInt(g_hCvarCheck[CHECK_SILENT]) > 0)
		CheckSilentStrafe(client, vel[1]);

	if (g_bMouse && !bOnGround && GetConVarInt(g_hCvarCheck[CHECK_AHK]) > 0)
		CheckAhkMouse(client, mouse[0], vOrigin);

	if (delta > 180.0)
		delta -= 360.0;
	else if (delta < -180.0)
		delta += 360.0;

	new Float:deltaAbs = FloatAbs(delta);

	if (!bOnGround && GetConVarInt(g_hCvarCheck[CHECK_SYNC]) > 0)
		CheckSync(client, buttons, delta, deltaAbs);

	if (deltaAbs >= MIN_DELTA && GetConVarInt(g_hCvarCheck[CHECK_TURN]) > 0)
		CheckTurn(client, buttons, deltaAbs, bOnGround, vOrigin, vVelocity);

	Finish(client, buttons, vel, bOnGround, vOrigin, delta, vVelocity);
	return Plugin_Continue;
}

Finish(client, buttons, const Float:vel[3], bool:bOnGround, const Float:vOrigin[3], Float:delta, const Float:vVelocity[3])
{
	if (bOnGround)
	{
		g_bKeyChanged[client] = false;
		g_bDirChanged[client] = false;
	}

	if (g_bPrevOnGround[client] && !bOnGround)
		g_fJumpZ[client] = vOrigin[2];

	g_bPrevOnGround[client] = bOnGround;
	g_iPrevButtons[client] = buttons;
	g_fPrevSide[client] = vel[1];

	if (delta > 180.0)
		delta -= 360.0;
	else if (delta < -180.0)
		delta += 360.0;

	// Tiny deltas keep the previous turn (Oryx returns before storing them).
	if (FloatAbs(delta) >= MIN_DELTA)
	{
		g_fPrevDelta[client] = delta;
		g_fPrevDeltaAbs[client] = FloatAbs(delta);

		new Float:speed = SquareRoot(vVelocity[0] * vVelocity[0] + vVelocity[1] * vVelocity[1]);
		g_fPrevOptimal[client] = (speed > 30.0) ? RadToDeg(ArcSine(30.0 / speed)) : -1.0;
	}
}

/* Oryx BASH remake: key transition tick minus mouse direction transition tick.
   Keys are tracked on every air tick, the mouse only when it moved. */
CheckSync(client, buttons, Float:delta, Float:deltaAbs)
{
	new prev = g_iPrevButtons[client];

	if ((buttons & (IN_MOVELEFT | IN_MOVERIGHT)) != (IN_MOVELEFT | IN_MOVERIGHT)
		&& (buttons & (IN_FORWARD | IN_BACK)) != (IN_FORWARD | IN_BACK))
	{
		if (((buttons & IN_MOVELEFT) && !(prev & IN_MOVELEFT))
			|| ((buttons & IN_MOVERIGHT) && !(prev & IN_MOVERIGHT))
			|| ((prev & IN_MOVELEFT) && (prev & IN_MOVERIGHT))
			|| ((buttons & IN_FORWARD) && !(prev & IN_FORWARD))
			|| ((buttons & IN_BACK) && !(prev & IN_BACK))
			|| ((prev & IN_FORWARD) && (prev & IN_BACK)))
		{
			g_bKeyChanged[client] = true;
			g_iKeyTick[client] = g_iAbsTicks[client];
		}
	}

	if (!g_bDirChanged[client] && deltaAbs >= MIN_DELTA
		&& ((delta < 0.0 && g_fPrevDelta[client] > 0.0)
		|| (delta > 0.0 && g_fPrevDelta[client] < 0.0)
		|| g_fPrevDeltaAbs[client] == 0.0))
	{
		g_bDirChanged[client] = true;
		g_iAngTick[client] = g_iAbsTicks[client];
	}

	if (!g_bKeyChanged[client] || !g_bDirChanged[client])
		return;

	g_bKeyChanged[client] = false;
	g_bDirChanged[client] = false;

	new offset = g_iKeyTick[client] - g_iAngTick[client];
	if (offset >= -MAX_STRAFE_OFFSET && offset <= MAX_STRAFE_OFFSET)
	{
		g_iStrafes[client][g_iStrafeCount[client] % SAMPLE_SIZE] = offset;

		if (++g_iStrafeCount[client] % SAMPLE_SIZE == 0)
			AnalyzeSync(client);
	}

	if (g_iBashCooldown[client] > 0)
		g_iBashCooldown[client]--;
}

AnalyzeSync(client)
{
	if (g_iBashCooldown[client] > 0)
		return;

	new sum, zeroes;
	for (new i = 0; i < SAMPLE_SIZE; i++)
	{
		new v = AbsValue(g_iStrafes[client][i]);
		sum += v;
		if (v == 0)
			zeroes++;
	}

	new severity = 0;
	decl String:sWhat[32];

	if (zeroes > 25)
	{
		severity = SEV_HIGH;
		strcopy(sWhat, sizeof(sWhat), "too many perfect strafes");
	}
	else if (sum < 9 || zeroes > 22)
	{
		severity = SEV_MEDIUM;
		strcopy(sWhat, sizeof(sWhat), (sum < 9) ? "average offset near 0" : "too many perfect strafes");
	}
	else if (sum < 15 || zeroes > 18)
	{
		severity = SEV_LOW;
		strcopy(sWhat, sizeof(sWhat), (sum < 15) ? "average offset near 0" : "too many perfect strafes");
	}

	if (!severity)
		return;

	g_iBashCooldown[client] = BASH_COOLDOWN;

	decl String:sStats[192], String:sDetail[256];
	FormatStrafeStats(client, sStats, sizeof(sStats));
	FormatEx(sDetail, sizeof(sDetail), "%s (sum %d, zeroes %d) %s", sWhat, sum, zeroes, sStats);
	Report(client, CHECK_SYNC, severity, "Strafe Sync", sDetail);
}

/* Oryx: perfect turn rate and +left/right bypasser (steady turn). */
CheckTurn(client, buttons, Float:deltaAbs, bool:bOnGround, const Float:vOrigin[3], const Float:vVelocity[3])
{
	decl String:sDetail[96];

	new Float:speed = SquareRoot(vVelocity[0] * vVelocity[0] + vVelocity[1] * vVelocity[1]);

	new Float:optimal = g_fPrevOptimal[client];
	if (!bOnGround && optimal > 0.0 && speed < MAX_SPEED && FloatAbs(deltaAbs - optimal) <= optimal / 128.0)
	{
		new streak = ++g_iPerfTurn[client];
		new severity = (streak == 10) ? SEV_LOW : (streak == 33) ? SEV_MEDIUM : (streak == 48) ? SEV_HIGH : 0;

		if (severity)
		{
			FormatEx(sDetail, sizeof(sDetail), "%d ticks at the optimal angle (%.3f deg, %.0f u/s)", streak, optimal, speed);
			Report(client, CHECK_TURN, severity, "Perfect Turn", sDetail);
		}
	}
	else
	{
		g_iPerfTurn[client] = 0;
	}

	new lr = buttons & (IN_LEFT | IN_RIGHT);
	new Float:prevAbs = g_fPrevDeltaAbs[client];

	if ((lr == 0 || lr == (IN_LEFT | IN_RIGHT)) && prevAbs > 0.0 && FloatAbs(deltaAbs - prevAbs) <= prevAbs / 128.0
		&& (bOnGround || !IsSurfing(client, vOrigin)))
	{
		if (++g_iSteadyTurn[client] >= STEADY_STREAK)
		{
			g_iSteadyTurn[client] = 0;
			FormatEx(sDetail, sizeof(sDetail), "%d ticks at %.3f deg/tick without +left/+right%s", STEADY_STREAK, deltaAbs, bOnGround ? " (ground)" : "");
			Report(client, CHECK_TURN, SEV_LOW, "Steady Turn", sDetail);
		}
	}
	else
	{
		g_iSteadyTurn[client] = 0;
	}
}

/* Cow AC: sidemove changes sign on every cmd. */
CheckSilentStrafe(client, Float:side)
{
	new Float:prev = g_fPrevSide[client];

	if ((side > 0.0 && prev < 0.0) || (side < 0.0 && prev > 0.0))
	{
		new streak = ++g_iSideFlips[client];
		new severity = (streak == SILENT_MEDIUM) ? SEV_MEDIUM : (streak == SILENT_HIGH) ? SEV_HIGH : 0;

		if (severity)
		{
			decl String:sDetail[64];
			FormatEx(sDetail, sizeof(sDetail), "sidemove flipped on %d cmds in a row", streak);
			Report(client, CHECK_SILENT, severity, "Silent Strafe", sDetail);
		}
	}
	else
	{
		g_iSideFlips[client] = 0;
	}
}

/* Cow AC: the same |mouse dx| for many cmds while above the jump height. */
CheckAhkMouse(client, dx, const Float:vOrigin[3])
{
	if (AbsValue(dx) < AHK_MIN_DX || vOrigin[2] <= g_fJumpZ[client])
	{
		g_iAhkStreak[client] = 0;
		return;
	}

	if (AbsValue(dx) == AbsValue(g_iAhkValue[client]))
	{
		g_iAhkStreak[client]++;
	}
	else
	{
		g_iAhkValue[client] = dx;
		g_iAhkStreak[client] = 0;
	}

	if (g_iAhkStreak[client] < AHK_STREAK)
		return;

	g_iAhkStreak[client] = 0;

	if (++g_iAhkRuns[client] < AHK_RUNS)
		return;

	g_iAhkRuns[client] = 0;

	decl String:sDetail[64];
	FormatEx(sDetail, sizeof(sDetail), "%d runs of %d cmds at mouse dx %d", AHK_RUNS, AHK_STREAK, AbsValue(dx));
	Report(client, CHECK_AHK, SEV_MEDIUM, "AHK Mouse", sDetail);
}

bool:IsSurfing(client, const Float:vOrigin[3])
{
	decl Float:vEnd[3], Float:vMins[3], Float:vMaxs[3];
	vEnd[0] = vOrigin[0];
	vEnd[1] = vOrigin[1];
	vEnd[2] = vOrigin[2] - 64.0;

	GetEntPropVector(client, Prop_Send, "m_vecMins", vMins);
	GetEntPropVector(client, Prop_Send, "m_vecMaxs", vMaxs);

	new Handle:hTrace = TR_TraceHullFilterEx(vOrigin, vEnd, vMins, vMaxs, MASK_PLAYERSOLID, Filter_NoPlayers, client);
	new bool:bSurf = false;

	if (TR_DidHit(hTrace))
	{
		decl Float:vNormal[3];
		TR_GetPlaneNormal(hTrace, vNormal);

		// A plane steeper than 0.7 is a surf ramp (physics_main.cpp).
		bSurf = (vNormal[2] >= -0.7 && vNormal[2] <= 0.7);
	}

	CloseHandle(hTrace);
	return bSurf;
}

public bool:Filter_NoPlayers(entity, contentsMask, any:data)
{
	return (entity != data && (entity < 1 || entity > MaxClients));
}

FormatStrafeStats(client, String:buffer[], maxlength)
{
	new count = g_iStrafeCount[client];
	new samples = (count < SAMPLE_SIZE) ? count : SAMPLE_SIZE;

	FormatEx(buffer, maxlength, "{");
	for (new i = 1; i <= samples; i++)
	{
		Format(buffer, maxlength, "%s%s%d", buffer, (i > 1) ? "," : "", g_iStrafes[client][(count - i) % SAMPLE_SIZE]);
	}
	StrCat(buffer, maxlength, "}");
}

public Action:Command_StrafeStats(client, args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "Usage: sm_strafe_stats <target>");
		return Plugin_Handled;
	}

	decl String:sTarget[MAX_TARGET_LENGTH];
	GetCmdArgString(sTarget, sizeof(sTarget));

	new target = FindTarget(client, sTarget, true, false);
	if (target == -1)
		return Plugin_Handled;

	if (g_iStrafeCount[target] == 0)
	{
		ReplyToCommand(client, "%N has no recorded strafes.", target);
		return Plugin_Handled;
	}

	decl String:sStats[192];
	FormatStrafeStats(target, sStats, sizeof(sStats));
	ReplyToCommand(client, "%N: %d strafes, last offsets (key tick - mouse tick): %s", target, g_iStrafeCount[target], sStats);
	return Plugin_Handled;
}

bool:IsImmune(client)
{
	return GetConVarBool(g_hCvarAdminImmune) && (GetUserFlagBits(client) & (ADMFLAG_BAN | ADMFLAG_ROOT)) != 0;
}

/* Low: log. Medium: log + admin notice. High: also kick (2) / ban (3) when the cvar says so. */
Report(client, check, severity, const String:name[], const String:detail[])
{
	new count = ++g_iDetects[client][check];

	new Handle:info = CreateKeyValues("");
	KvSetString(info, "check", name);
	KvSetNum(info, "severity", severity);
	KvSetNum(info, "detection", count);

	new Action:result = SMAC_CheatDetected(client, Detection_Strafe, info);
	CloseHandle(info);

	if (result != Plugin_Continue)
		return;

	static const String:sSeverity[][] = { "", "low", "medium", "high" };
	SMAC_LogAction(client, "%s [%s] (Detection #%i) %s", name, sSeverity[severity], count, detail);

	if (severity < SEV_MEDIUM)
		return;

	SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, name, count);

	new level = GetConVarInt(g_hCvarCheck[check]);
	if (severity < SEV_HIGH || level < 2 || IsImmune(client))
		return;

	if (level >= 3)
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
