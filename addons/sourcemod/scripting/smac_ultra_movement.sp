#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC Ultr@ R52 port: movement detectors.
 *
 * Rewritten from 001_SMAC_Global.smx of SMAC Ultr@ R52 as decompiled with
 * tools/r52re/decomp.py (docs/R52_SPEC.md §4, §5; docs/ULTRA_MOVEMENT.md).
 * No Ultr@ code and no Ultr@Tools extension is used.
 *
 * Per usercmd:
 *   Fast Run            wishmove without the matching key (sidemove > 0 without +moveright, ...)
 *                       while |vel.x| or |vel.y| > 289; more than 22 such cmds (reset on death).
 *   Advanced BunnyHop   (R52 fn_344b08, on every +jump press on the ground)
 *                       n = +jump presses since the previous ground jump, ema = (9*ema + n) / 10.
 *                       ema < 1.1 (one press per jump) and horizontal speed >= 350 on 12 jumps.
 *                       Jumping in place (< sqrt(30) units) or a fast fall skips 2 jumps.
 *   AutoHotKeys, Auto-Jump  ema > 15 and n repeats exactly for more than 15 jumps.
 *   HaX2                perfect-hop EMA (+jump pressed on the very cmd the player landed)
 *                       reaches 0.8 (about 11 perfect hops in a row).
 * Every second:
 *   Airstuck: Fast Detect   velocity has no zero component and no component changed by 0.7,
 *                       flags exactly 0x10280/0x10282 (as R52); 3 hits, each decays in 420 s.
 *   BunnyHop: Fast Detect   |vel.x| or |vel.y| > 289.
 *   Teleport Hack       |vel.z| < 360 and the player moved more than |SpeedTeleport| units
 *                       in one second.
 *   Teleport Hack: Fast Detect  vel.z > 1250 (R52 uses |vel.z|; falling is left out here).
 *   Spinhack            sum of |dYaw| (wrapped) in one second > 420 * sensitivity or > 4096;
 *                       more than 5 such seconds in one life.
 *
 * All second checks need normal gravity (R52: entity gravity 0 or 1; here also no
 * m_flLaggedMovementValue change), are skipped on ladders, noclip and fly movetypes and
 * without a knife (R52), and after spawn / trigger_teleport (added for safety).
 *
 * Added in smac_v34 (not in R52), from the 420hook source (docs/HOOK_420.md). Per usercmd, walk
 * movetype only, admin notice by default:
 *   FastWalk            on the ground forwardmove or sidemove zigzags: the change flips sign on every
 *                       cmd with the same size (>= 100), 20 cmds in a row. Keys can't do that per tick.
 *   AutoStrafe          in the air sidemove = +-cl_sidespeed without +moveleft / +moveright, opposite
 *                       to the yaw turn; 60 such cmds in one life.
 *   CircleStrafe        forwardmove / sidemove above the client's cl_forwardspeed, cl_backspeed or
 *                       cl_sidespeed; 10 such cmds in one life.
 *   Move Fix            (log collection) on the ground one movement key is held, the other axis is not 0
 *                       and the vector keeps the key's full length: the wishmove was rotated to a
 *                       different view angle (silent aim / anti-aim). 30 such cmds within 60 s.
 *
 * Cvars keep the Ultr@ names. Defaults are admin-notice only.
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: Movement",
	author = SMAC_AUTHOR,
	description = "Fast Run, Advanced BunnyHop, HaX2, Teleport, Airstuck and Spinhack from SMAC Ultr@ R52; FastWalk, AutoStrafe, CircleStrafe, Move Fix",
	version = SMAC_VERSION,
	url = SMAC_URL
};

/* Checks (index into g_sCheck). */
#define M_FASTRUN		0
#define M_EYE04			1		/* Eye Angles 04 moved to smac_eyetest; index kept */
#define M_ADVBHOP		2
#define M_AUTOJUMP		3
#define M_HAX2			4
#define M_AIRSTUCK		5
#define M_BHOPFAST		6
#define M_TELEPORT		7
#define M_TELEFAST		8
#define M_SPIN			9
#define M_FASTWALK		10
#define M_AUTOSTRAFE	11
#define M_CIRCLE		12
#define M_MOVEFIX		13
#define M_COUNT			14

new String:g_sCheck[M_COUNT][] =
{
	"Fast Run",
	"Eye Angles 04",
	"Advanced BunnyHop",
	"AutoHotKeys, Auto-Jump",
	"HaX2",
	"Airstuck: Fast Detect",
	"BunnyHop: Fast Detect",
	"Teleport Hack",
	"Teleport Hack: Fast Detect",
	"Spinhack",
	"FastWalk",
	"AutoStrafe",
	"CircleStrafe",
	"Move Fix"
};

#define MAX_RUN_SPEED		289.0
#define FASTRUN_CMDS		22
#define FASTRUN_AFTER		-264


#define BHOP_EMA_SINGLE		1.1
#define BHOP_EMA_SCROLL		15.0
#define BHOP_SPEED			350.0
#define BHOP_JUMPS			12
#define BHOP_REPEATS		15
#define BHOP_STUCK_DIST2	30.0
#define BHOP_FALL_SPEED		-269.7
#define HAX2_EMA			0.8

#define AIRSTUCK_DELTA		0.7
#define AIRSTUCK_HITS		2
#define AIRSTUCK_DECAY		420.0

#define TELEPORT_MAX_VZ		360.0
#define TELEFAST_VZ			1250.0

#define SPIN_PER_SENS		420.0
#define SPIN_MAX			4096.0
#define SPIN_SECONDS		5

#define SPAWN_GRACE			2.0
#define TELEPORT_GRACE		2.0
#define NOTICE_COOLDOWN		30.0
#define QUERY_INTERVAL		60.0

#define FASTWALK_MIN_STEP	100.0
#define FASTWALK_CMDS		20
#define AUTOSTRAFE_CMDS		60
#define CIRCLE_CMDS			10
#define MOVEFIX_CMDS		30
#define MOVEFIX_WINDOW		60.0
#define MOVEFIX_LEN_TOL		0.01
#define SPEED_KEY_SCALE		0.52	/* cl_movespeedkey default */

#define MAX_PING			0.15
#define MIN_PACKET_FRAC		0.7

new Handle:g_hCvarFastRun = INVALID_HANDLE;
new Handle:g_hCvarAutoTrigger = INVALID_HANDLE;
new Handle:g_hCvarAirstuck = INVALID_HANDLE;
new Handle:g_hCvarTeleport = INVALID_HANDLE;
new Handle:g_hCvarTeleportNotice = INVALID_HANDLE;
new Handle:g_hCvarSpin = INVALID_HANDLE;
new Handle:g_hCvarAdminImmune = INVALID_HANDLE;
new Handle:g_hCvarFastWalk = INVALID_HANDLE;
new Handle:g_hCvarAutoStrafe = INVALID_HANDLE;
new Handle:g_hCvarCircle = INVALID_HANDLE;
new Handle:g_hCvarMoveFix = INVALID_HANDLE;

new Float:g_fSens[MAXPLAYERS+1];

/* Client move speeds (cl_forwardspeed, cl_backspeed, cl_sidespeed); 0.0 = not known yet. */
new Float:g_fMoveSpeed[MAXPLAYERS+1][3];

/* FastWalk, AutoStrafe, CircleStrafe, Move Fix */
new Float:g_fPrevMove[MAXPLAYERS+1][2];
new Float:g_fPrevMoveDelta[MAXPLAYERS+1][2];
new bool:g_bHasPrevMove[MAXPLAYERS+1];
new g_iFastWalk[MAXPLAYERS+1];
new g_iAutoStrafe[MAXPLAYERS+1];
new g_iCircle[MAXPLAYERS+1];
new g_iMoveFix[MAXPLAYERS+1];
new Float:g_fMoveFixStart[MAXPLAYERS+1];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1][M_COUNT];
new Float:g_fNextNotice[MAXPLAYERS+1][M_COUNT];

/* Fast Run */
new g_iFastRun[MAXPLAYERS+1];

/* Advanced BunnyHop (R52 fn_344b08 state) */
new g_iJumpPresses[MAXPLAYERS+1];
new Float:g_fPressEma[MAXPLAYERS+1];
new g_iRepeat[MAXPLAYERS+1];
new g_iRepeatN[MAXPLAYERS+1];
new bool:g_bAutoJump[MAXPLAYERS+1];
new bool:g_bBhopSeen[MAXPLAYERS+1];
new g_iStuck[MAXPLAYERS+1];
new g_iFastJumps[MAXPLAYERS+1];
new Float:g_fJumpOrigin[MAXPLAYERS+1][3];
new Float:g_fPerfectEma[MAXPLAYERS+1];
new bool:g_bJumpHeld[MAXPLAYERS+1];
new bool:g_bPrevOnGround[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];

/* Second ticker */
new Float:g_fPrevVel[MAXPLAYERS+1][3];
new Float:g_fPrevPos[MAXPLAYERS+1][3];
new g_iAirstuck[MAXPLAYERS+1];

/* Spinhack */
new Float:g_fPrevYaw[MAXPLAYERS+1];
new bool:g_bHasPrevYaw[MAXPLAYERS+1];
new Float:g_fSpinSum[MAXPLAYERS+1];
new g_iSpinSeconds[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarFastRun = SMAC_CreateConVar("smac_FD_BHOP", "1", "Fast Run and BunnyHop: Fast Detect (speed > 289): 0=off, 1=admin notice, 2=kick, 3=ban (R52: 2)", _, true, 0.0, true, 3.0);
	g_hCvarAutoTrigger = SMAC_CreateConVar("smac_autotrigger_ban", "0", "AutoTrigger (Auto-Fire/Strafe/Duck/Scroll), Advanced BunnyHop, HaX2, Auto-Jump: -1=off, 0=admin notice, 1=kick, 2=ban, 3/4=kick/ban for Auto-Fire only (R52: 2)", _, true, -1.0, true, 4.0);
	g_hCvarAirstuck = SMAC_CreateConVar("smac_Airstuck_reaction", "1", "Airstuck: 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarTeleport = SMAC_CreateConVar("smac_SpeedTeleport", "-1500.0", "Teleport Hack: max distance per second, +N = ban, -N = kick, 0 = off (also Teleport Hack: Fast Detect)", _, true, -50000.0, true, 50000.0);
	g_hCvarTeleportNotice = SMAC_CreateConVar("smac_SpeedTeleport_notice_only", "1", "Teleport Hack: only notify admins instead of the kick/ban set by smac_SpeedTeleport.", _, true, 0.0, true, 1.0);
	g_hCvarSpin = SMAC_CreateConVar("smac_ultra_spinhack_reaction", "1", "Spinhack (R52 per-second yaw sum): 0=off, 1=admin notice, 2=kick, 3=ban (R52: kick)", _, true, 0.0, true, 3.0);
	g_hCvarFastWalk = SMAC_CreateConVar("smac_FastWalk_reaction", "1", "FastWalk (on-ground move zigzag every cmd, 420hook): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarAutoStrafe = SMAC_CreateConVar("smac_AutoStrafe_reaction", "1", "AutoStrafe (air sidemove without strafe keys, following the turn): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarCircle = SMAC_CreateConVar("smac_CircleStrafe_reaction", "1", "CircleStrafe (wishmove above the client's cl_forwardspeed/cl_backspeed/cl_sidespeed): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarMoveFix = SMAC_CreateConVar("smac_MoveFix_reaction", "1", "Move Fix (wishmove rotated to another view angle, silent aim / anti-aim; log collection): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarAdminImmune = SMAC_CreateConVar("smac_ultra_admin_immune", "1", "Never kick/ban admins with ban/root flag (detections are still logged).", _, true, 0.0, true, 1.0);

	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnStartTouch", Output_Teleport);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Output_Teleport);

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
	g_fSens[client] = 0.0;
	g_fMoveSpeed[client][0] = g_fMoveSpeed[client][1] = g_fMoveSpeed[client][2] = 0.0;
	g_fIgnoreUntil[client] = 0.0;
	g_iMoveFix[client] = 0;
	g_fMoveFixStart[client] = 0.0;
	for (new i = 0; i < M_COUNT; i++)
	{
		g_iDetects[client][i] = 0;
		g_fNextNotice[client][i] = 0.0;
	}

	g_iAirstuck[client] = -1;

	g_iJumpPresses[client] = 0;
	g_fPressEma[client] = 0.0;
	g_iRepeat[client] = 0;
	g_iRepeatN[client] = 0;
	g_bAutoJump[client] = false;
	g_bBhopSeen[client] = false;
	g_iStuck[client] = 0;
	g_iFastJumps[client] = 0;
	g_fPerfectEma[client] = 0.0;
	g_bJumpHeld[client] = false;
	g_bPrevOnGround[client] = false;
	g_iPrevButtons[client] = 0;
	ZeroVector(g_fJumpOrigin[client]);

	ResetLife(client);

	if (!IsFakeClient(client))
		QueryClient(client);
}

QueryClient(client)
{
	QueryClientConVar(client, "sensitivity", Query_Sensitivity);
	QueryClientConVar(client, "cl_forwardspeed", Query_MoveSpeed, 0);
	QueryClientConVar(client, "cl_backspeed", Query_MoveSpeed, 1);
	QueryClientConVar(client, "cl_sidespeed", Query_MoveSpeed, 2);
}

public Query_MoveSpeed(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[], any:axis)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || result != ConVarQuery_Okay || axis < 0 || axis > 2)
		return;

	g_fMoveSpeed[client][axis] = FloatAbs(StringToFloat(cvarValue));
}

/* State R52 clears on death / while not in game. */
ResetLife(client)
{
	g_iFastRun[client] = 0;
	g_iFastWalk[client] = 0;
	g_iAutoStrafe[client] = 0;
	g_iCircle[client] = 0;
	g_bHasPrevMove[client] = false;
	g_iSpinSeconds[client] = 0;
	g_fSpinSum[client] = 0.0;
	g_bHasPrevYaw[client] = false;
	ResetPrev(client);
}

/* R52 fn_180078. */
ResetPrev(client)
{
	ZeroVector(g_fPrevVel[client]);
	ZeroVector(g_fPrevPos[client]);
}

public Action:Timer_QueryAll(Handle:timer)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			QueryClient(i);
	}
	return Plugin_Continue;
}

public Query_Sensitivity(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[])
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || result != ConVarQuery_Okay)
		return;

	/* R52 kicks for sensitivity outside [1; 20]; here it is clamped instead. */
	new Float:sens = StringToFloat(cvarValue);
	if (sens < 1.0)
		sens = 1.0;
	else if (sens > 20.0)
		sens = 20.0;

	g_fSens[client] = sens;
}

public Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		ResetLife(client);
		IgnoreClient(client, SPAWN_GRACE);
	}
}

public Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
		ResetLife(client);
}

public Output_Teleport(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator))
	{
		ResetPrev(activator);
		IgnoreClient(activator, TELEPORT_GRACE + delay);
	}
}

/**
 * Usercmd analysis
 */
public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!IsPlaying(client))
	{
		g_bHasPrevYaw[client] = false;
		g_bHasPrevMove[client] = false;
		return Plugin_Continue;
	}

	new flags = GetEntityFlags(client);

	CheckFastRun(client, buttons, vel);
	CheckJump(client, buttons, flags);
	CheckMoveInput(client, buttons, flags, vel, angles);

	/* Spinhack: sum of wrapped |dYaw| for the second ticker. */
	if (g_bHasPrevYaw[client])
	{
		new Float:d = FloatAbs(angles[1] - g_fPrevYaw[client]);
		if (d > 180.0)
			d = 360.0 - d;
		g_fSpinSum[client] += d;
	}
	g_fPrevYaw[client] = angles[1];
	g_bHasPrevYaw[client] = true;

	g_iPrevButtons[client] = buttons;
	return Plugin_Continue;
}

CheckFastRun(client, buttons, const Float:vel[3])
{
	if (GetConVarInt(g_hCvarFastRun) <= 0)
		return;

	/* Wishmove the keys cannot produce. */
	if (!((vel[1] > 0.0 && !(buttons & IN_MOVERIGHT))
		|| (vel[1] < 0.0 && !(buttons & IN_MOVELEFT))
		|| (vel[0] > 0.0 && !(buttons & IN_FORWARD))
		|| (vel[0] < 0.0 && !(buttons & IN_BACK))))
		return;

	decl Float:velocity[3];
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
	if (FloatAbs(velocity[0]) <= MAX_RUN_SPEED && FloatAbs(velocity[1]) <= MAX_RUN_SPEED)
		return;

	if (!IsNormalGravity(client) || IsIgnored(client))
		return;

	if (++g_iFastRun[client] <= FASTRUN_CMDS)
		return;

	g_iFastRun[client] = FASTRUN_AFTER;

	decl String:sDetail[128];
	FormatEx(sDetail, sizeof(sDetail), "wishmove %.0f %.0f without keys, speed %.0f %.0f",
		vel[0], vel[1], velocity[0], velocity[1]);
	React(client, M_FASTRUN, GetConVarInt(g_hCvarFastRun), sDetail);
}

/* R52 smac_autotrigger_ban: -1 off, 0 notice, 1 kick, 2 ban; 3 and more skip these checks. */
AutoTriggerLevel()
{
	new value = GetConVarInt(g_hCvarAutoTrigger);
	if (value < 0 || value >= 3)
		return 0;
	return value + 1;
}

CheckJump(client, buttons, flags)
{
	if (AutoTriggerLevel() <= 0)
		return;

	new bool:bOnGround = (flags & FL_ONGROUND) != 0;
	new bool:bJump = (buttons & IN_JUMP) != 0;

	/* +jump pressed on the ground. */
	if (bJump && !(g_iPrevButtons[client] & IN_JUMP) && bOnGround)
		AnalyzeJump(client);

	if (!bJump)
	{
		g_bJumpHeld[client] = false;
	}
	else if (!g_bJumpHeld[client])
	{
		g_bJumpHeld[client] = true;
		g_iJumpPresses[client]++;

		/* Pressed on the very cmd the player landed: a perfect hop. */
		if (bOnGround)
		{
			if (g_bPrevOnGround[client])
				g_fPerfectEma[client] = g_fPerfectEma[client] * 9.0 / 10.0;
			else
				g_fPerfectEma[client] = (g_fPerfectEma[client] * 9.0 + 1.2) / 10.0;
		}
	}
	g_bPrevOnGround[client] = bOnGround;

	/* A fast fall makes the next landing speed meaningless. */
	if (g_bBhopSeen[client])
	{
		decl Float:velocity[3];
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
		if (velocity[2] < BHOP_FALL_SPEED)
			g_iStuck[client] = 2;
	}
}

/* R52 fn_344b08. */
AnalyzeJump(client)
{
	new n = g_iJumpPresses[client];
	g_fPressEma[client] = (g_fPressEma[client] * 9.0 + float(n)) / 10.0;

	if (g_fPressEma[client] > BHOP_EMA_SCROLL)
	{
		/* Scrolling: a script repeats exactly the same number of presses. */
		if (g_iRepeat[client] > 0 && g_iRepeatN[client] == n)
		{
			if (++g_iRepeat[client] > BHOP_REPEATS && !g_bAutoJump[client])
			{
				decl String:sDetail[96];
				FormatEx(sDetail, sizeof(sDetail), "%i presses per jump repeated %i times", n, g_iRepeat[client]);
				JumpReact(client, M_AUTOJUMP, sDetail);
				g_bAutoJump[client] = true;
			}
		}
		else if (g_iRepeat[client] > 0)
		{
			g_iRepeat[client] -= 2;
		}
		else
		{
			g_iRepeatN[client] = n;
			g_iRepeat[client] = 2;
		}
	}
	else if (n > 1)
	{
		g_iFastJumps[client] = 0;
	}
	else if (!g_bAutoJump[client] && g_fPressEma[client] < BHOP_EMA_SINGLE)
	{
		g_bBhopSeen[client] = true;

		if (g_iStuck[client] > 0)
			g_iStuck[client]--;

		if (g_iStuck[client] == 0)
		{
			decl Float:velocity[3];
			GetEntPropVector(client, Prop_Data, "m_vecVelocity", velocity);
			velocity[2] = 0.0;
			new Float:speed = GetVectorLength(velocity);

			if (speed >= BHOP_SPEED)
			{
				if (++g_iFastJumps[client] >= BHOP_JUMPS)
				{
					decl String:sDetail[96];
					FormatEx(sDetail, sizeof(sDetail), "%i single-press jumps at %.0f u/s (press ema %.2f)",
						g_iFastJumps[client], speed, g_fPressEma[client]);
					JumpReact(client, M_ADVBHOP, sDetail);
				}
			}
			else if (g_iFastJumps[client] > 0)
			{
				g_iFastJumps[client]--;
			}
		}
		else if (g_iFastJumps[client] > 0)
		{
			g_iFastJumps[client]--;
		}
	}

	g_iJumpPresses[client] = 0;

	/* Jumping in place: skip the next two jumps. */
	decl Float:origin[3];
	GetEntPropVector(client, Prop_Data, "m_vecOrigin", origin);
	if (GetVectorDistance(g_fJumpOrigin[client], origin, true) < BHOP_STUCK_DIST2)
		g_iStuck[client] = 2;
	CopyVector(origin, g_fJumpOrigin[client]);

	if (!g_bAutoJump[client] && g_fPerfectEma[client] >= HAX2_EMA)
	{
		decl String:sDetail[64];
		FormatEx(sDetail, sizeof(sDetail), "perfect hop ema %.2f", g_fPerfectEma[client]);
		JumpReact(client, M_HAX2, sDetail);
	}
}

JumpReact(client, check, const String:detail[])
{
	if (!IsIgnored(client))
		React(client, check, AutoTriggerLevel(), detail);
}

/**
 * Second ticker (R52 OnTimerUp)
 */
public Action:Timer_Second(Handle:timer)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsPlaying(i))
		{
			if (IS_CLIENT(i))
				g_fSpinSum[i] = 0.0;
			continue;
		}

		CheckSpin(i);
		CheckMotion(i);
	}
	return Plugin_Continue;
}

CheckSpin(client)
{
	new Float:sum = g_fSpinSum[client];
	g_fSpinSum[client] = 0.0;

	new level = GetConVarInt(g_hCvarSpin);
	if (level <= 0 || g_fSens[client] <= 0.0)
		return;

	if (sum <= SPIN_PER_SENS * g_fSens[client] && sum <= SPIN_MAX)
		return;

	if (++g_iSpinSeconds[client] <= SPIN_SECONDS)
		return;

	g_iSpinSeconds[client] = 0;

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "%.0f deg/s for %i s (sensitivity %.2f)", sum, SPIN_SECONDS + 1, g_fSens[client]);
	React(client, M_SPIN, level, sDetail);
}

CheckMotion(client)
{
	new airstuck = GetConVarInt(g_hCvarAirstuck);
	new fastBhop = GetConVarInt(g_hCvarFastRun);
	new Float:teleport = GetConVarFloat(g_hCvarTeleport);
	if (teleport == 0.0 && fastBhop <= 0 && airstuck <= 0)
		return;

	new MoveType:movetype = GetEntityMoveType(client);
	if (movetype == MOVETYPE_FLY || movetype == MOVETYPE_NOCLIP || movetype == MOVETYPE_LADDER
		|| GetPlayerWeaponSlot(client, 2) == -1 || IsIgnored(client))
	{
		ResetPrev(client);
		return;
	}

	decl Float:vel[3], Float:pos[3];
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
	GetClientAbsOrigin(client, pos);

	decl String:sDetail[128];

	/* Airstuck: Fast Detect. */
	if (airstuck > 0 && vel[0] != 0.0 && vel[1] != 0.0 && vel[2] != 0.0)
	{
		if (IsVectorZero(g_fPrevVel[client]))
		{
			CopyVector(vel, g_fPrevVel[client]);
		}
		else if (FloatAbs(g_fPrevVel[client][0] - vel[0]) < AIRSTUCK_DELTA
			&& FloatAbs(g_fPrevVel[client][1] - vel[1]) < AIRSTUCK_DELTA
			&& FloatAbs(g_fPrevVel[client][2] - vel[2]) < AIRSTUCK_DELTA
			&& (GetEntityFlags(client) == 0x10280 || GetEntityFlags(client) == 0x10282))
		{
			if (IsNormalGravity(client))
			{
				if (++g_iAirstuck[client] >= AIRSTUCK_HITS)
				{
					g_iAirstuck[client] = 0;
					FormatEx(sDetail, sizeof(sDetail), "velocity %.1f %.1f %.1f frozen", vel[0], vel[1], vel[2]);
					React(client, M_AIRSTUCK, airstuck, sDetail);
				}
				else
				{
					ScheduleAirstuckDecay(client);
				}
			}
			ResetPrev(client);
			ZeroVector(vel);
		}
	}

	if (FloatAbs(vel[0]) > MAX_RUN_SPEED || FloatAbs(vel[1]) > MAX_RUN_SPEED)
	{
		/* BunnyHop: Fast Detect. */
		if (fastBhop > 0)
		{
			if (IsNormalGravity(client))
			{
				FormatEx(sDetail, sizeof(sDetail), "speed %.0f %.0f", vel[0], vel[1]);
				React(client, M_BHOPFAST, fastBhop, sDetail);
			}
			ResetPrev(client);
			ZeroVector(vel);
		}
	}
	else if (FloatAbs(vel[2]) < TELEPORT_MAX_VZ)
	{
		/* Teleport Hack. */
		if (teleport != 0.0)
		{
			if (IsVectorZero(g_fPrevPos[client]))
			{
				CopyVector(pos, g_fPrevPos[client]);
			}
			else
			{
				new Float:dist2 = GetVectorDistance(g_fPrevPos[client], pos, true);
				if (dist2 > teleport * teleport && IsNormalGravity(client))
				{
					FormatEx(sDetail, sizeof(sDetail), "moved %.0f units in 1 s (limit %.0f)", SquareRoot(dist2), FloatAbs(teleport));
					React(client, M_TELEPORT, TeleportLevel(teleport), sDetail);
					ResetPrev(client);
				}
			}
		}
	}
	else if (vel[2] > TELEFAST_VZ && teleport != 0.0)
	{
		/* Teleport Hack: Fast Detect. */
		FormatEx(sDetail, sizeof(sDetail), "vertical speed %.0f", vel[2]);
		React(client, M_TELEFAST, TeleportLevel(teleport), sDetail);
		ResetPrev(client);
	}

	CopyVector(vel, g_fPrevVel[client]);
	CopyVector(pos, g_fPrevPos[client]);
}

/**
 * FastWalk, AutoStrafe, CircleStrafe and Move Fix (smac_v34, from the 420hook source).
 */
CheckMoveInput(client, buttons, flags, const Float:vel[3], const Float:angles[3])
{
	if (GetEntityMoveType(client) != MOVETYPE_WALK || IsIgnored(client) || (flags & (FL_FROZEN | FL_ATCONTROLS)))
	{
		g_bHasPrevMove[client] = false;
		return;
	}

	new bool:bOnGround = (flags & FL_ONGROUND) != 0;

	if (g_bHasPrevMove[client])
	{
		if (bOnGround && !(buttons & IN_JUMP))
			CheckFastWalk(client, vel);
		else
			g_iFastWalk[client] = 0;

		if (!bOnGround && g_bHasPrevYaw[client])
			CheckAutoStrafe(client, buttons, vel, angles);
	}
	else
	{
		g_iFastWalk[client] = 0;
	}

	CheckCircleStrafe(client, vel);

	if (bOnGround)
		CheckMoveFix(client, buttons, vel);

	for (new i = 0; i < 2; i++)
	{
		g_fPrevMoveDelta[client][i] = g_bHasPrevMove[client] ? vel[i] - g_fPrevMove[client][i] : 0.0;
		g_fPrevMove[client][i] = vel[i];
	}
	g_bHasPrevMove[client] = true;
}

/* 420hook FastWalk adds +-0.5065 * 400 to forwardmove / sidemove, flipping the sign every cmd. */
CheckFastWalk(client, const Float:vel[3])
{
	new level = GetConVarInt(g_hCvarFastWalk);
	if (level <= 0)
		return;

	new bool:bZigzag = false;
	for (new i = 0; i < 2; i++)
	{
		new Float:d = vel[i] - g_fPrevMove[client][i];
		new Float:pd = g_fPrevMoveDelta[client][i];
		if (FloatAbs(d) >= FASTWALK_MIN_STEP && d * pd < 0.0 && FloatAbs(FloatAbs(d) - FloatAbs(pd)) < 1.0)
			bZigzag = true;
	}

	if (!bZigzag)
	{
		g_iFastWalk[client] = 0;
		return;
	}

	if (++g_iFastWalk[client] < FASTWALK_CMDS)
		return;

	g_iFastWalk[client] = 0;

	decl String:sDetail[128];
	FormatEx(sDetail, sizeof(sDetail), "wishmove zigzag %.1f %.1f -> %.1f %.1f on %i cmds in a row",
		g_fPrevMove[client][0], g_fPrevMove[client][1], vel[0], vel[1], FASTWALK_CMDS);
	React(client, M_FASTWALK, level, sDetail);
}

/* 420hook AutoStrafe: sidemove = -400 while the yaw grows, +400 while it falls, no strafe keys. */
CheckAutoStrafe(client, buttons, const Float:vel[3], const Float:angles[3])
{
	new level = GetConVarInt(g_hCvarAutoStrafe);
	new Float:side = (g_fMoveSpeed[client][2] > 0.0) ? g_fMoveSpeed[client][2] : 400.0;
	if (level <= 0 || (buttons & (IN_MOVELEFT | IN_MOVERIGHT)) || FloatAbs(FloatAbs(vel[1]) - side) > 0.5)
		return;

	new Float:dYaw = angles[1] - g_fPrevYaw[client];
	if (dYaw > 180.0)
		dYaw -= 360.0;
	else if (dYaw < -180.0)
		dYaw += 360.0;

	if (dYaw == 0.0 || vel[1] * dYaw >= 0.0)
		return;

	if (++g_iAutoStrafe[client] < AUTOSTRAFE_CMDS)
		return;

	g_iAutoStrafe[client] = 0;

	decl String:sDetail[128];
	FormatEx(sDetail, sizeof(sDetail), "air sidemove %.0f without strafe keys against the turn (%.2f) on %i cmds",
		vel[1], dYaw, AUTOSTRAFE_CMDS);
	React(client, M_AUTOSTRAFE, level, sDetail);
}

/* 420hook CircleStrafe: forwardmove / sidemove = cos / sin * 450. */
CheckCircleStrafe(client, const Float:vel[3])
{
	new level = GetConVarInt(g_hCvarCircle);
	if (level <= 0 || g_fMoveSpeed[client][0] <= 0.0 || g_fMoveSpeed[client][1] <= 0.0 || g_fMoveSpeed[client][2] <= 0.0)
		return;

	if (vel[0] <= g_fMoveSpeed[client][0] + 1.0 && -vel[0] <= g_fMoveSpeed[client][1] + 1.0
		&& FloatAbs(vel[1]) <= g_fMoveSpeed[client][2] + 1.0)
		return;

	if (++g_iCircle[client] < CIRCLE_CMDS)
		return;

	g_iCircle[client] = 0;

	decl String:sDetail[160];
	FormatEx(sDetail, sizeof(sDetail), "wishmove %.1f %.1f above cl_forwardspeed %.0f / cl_backspeed %.0f / cl_sidespeed %.0f",
		vel[0], vel[1], g_fMoveSpeed[client][0], g_fMoveSpeed[client][1], g_fMoveSpeed[client][2]);
	React(client, M_CIRCLE, level, sDetail);
}

/* Keys give each axis 0 or the key speed; a movement fix rotates the vector and keeps its length. */
CheckMoveFix(client, buttons, const Float:vel[3])
{
	new level = GetConVarInt(g_hCvarMoveFix);
	if (level <= 0 || g_fMoveSpeed[client][0] <= 0.0 || g_fMoveSpeed[client][1] <= 0.0 || g_fMoveSpeed[client][2] <= 0.0)
		return;

	new kf = ((buttons & IN_FORWARD) ? 1 : 0) - ((buttons & IN_BACK) ? 1 : 0);
	new ks = ((buttons & IN_MOVERIGHT) ? 1 : 0) - ((buttons & IN_MOVELEFT) ? 1 : 0);
	new bool:bSideKeys = (buttons & (IN_MOVELEFT | IN_MOVERIGHT)) != 0;
	new bool:bFwdKeys = (buttons & (IN_FORWARD | IN_BACK)) != 0;

	new Float:keySpeed, Float:onAxis, Float:offAxis;
	if (kf != 0 && !bSideKeys)
	{
		keySpeed = (kf > 0) ? g_fMoveSpeed[client][0] : g_fMoveSpeed[client][1];
		onAxis = vel[0] * float(kf);
		offAxis = vel[1];
	}
	else if (ks != 0 && !bFwdKeys)
	{
		keySpeed = g_fMoveSpeed[client][2];
		onAxis = vel[1] * float(ks);
		offAxis = vel[0];
	}
	else
	{
		return;
	}

	if (FloatAbs(offAxis) < 1.0 || onAxis <= 0.0)
		return;

	new Float:len = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);
	if (FloatAbs(len - keySpeed) > keySpeed * MOVEFIX_LEN_TOL
		&& FloatAbs(len - keySpeed * SPEED_KEY_SCALE) > keySpeed * SPEED_KEY_SCALE * MOVEFIX_LEN_TOL)
		return;

	new Float:now = GetGameTime();
	if (g_iMoveFix[client] == 0 || now - g_fMoveFixStart[client] > MOVEFIX_WINDOW)
	{
		g_iMoveFix[client] = 0;
		g_fMoveFixStart[client] = now;
	}

	if (++g_iMoveFix[client] < MOVEFIX_CMDS)
		return;

	g_iMoveFix[client] = 0;

	decl String:sDetail[160];
	FormatEx(sDetail, sizeof(sDetail), "one key held, wishmove %.1f %.1f rotated (length %.1f, key speed %.0f), %i cmds in %.0f s",
		vel[0], vel[1], len, keySpeed, MOVEFIX_CMDS, now - g_fMoveFixStart[client]);
	React(client, M_MOVEFIX, level, sDetail);
}

TeleportLevel(Float:teleport)
{
	if (GetConVarBool(g_hCvarTeleportNotice))
		return 1;
	return (teleport > 0.0) ? 3 : 2;
}

/**
 * Delayed decays (R52 SetBan -> OnBanReleased), postponed while the player is not on a team.
 */
ScheduleAirstuckDecay(client)
{
	CreateTimer(AIRSTUCK_DECAY, Timer_AirstuckDecay, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_AirstuckDecay(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (!IS_CLIENT(client) || !IsClientInGame(client) || g_iAirstuck[client] <= -1)
		return Plugin_Stop;

	if (GetClientTeam(client) > 1)
		g_iAirstuck[client]--;
	else
		ScheduleAirstuckDecay(client);
	return Plugin_Stop;
}

/**
 * Reaction: 1 = admin notice, 2 = kick, 3 = ban. Returns the action taken (0 = suppressed).
 * Notices for the same check are sent at most once per NOTICE_COOLDOWN seconds.
 */
React(client, check, level, const String:detail[])
{
	if (level <= 0)
		return 0;

	new action = level;
	if (action > 1 && IsImmune(client))
		action = 1;

	new lowered = LowerAction(client, action);
	if (lowered != action)
	{
		SMAC_LogAction(client, "%s: action lowered %i -> %i (avg ping %.0f ms, %.1f pkt/s).",
			g_sCheck[check], action, lowered,
			GetClientAvgLatency(client, NetFlow_Outgoing) * 1000.0,
			GetClientAvgPackets(client, NetFlow_Incoming));
		action = lowered;
	}

	new Float:now = GetGameTime();
	if (action == 1 && now < g_fNextNotice[client][check])
		return 0;

	new Handle:info = CreateKeyValues("");
	KvSetString(info, "check", g_sCheck[check]);
	KvSetString(info, "detail", detail);
	new Action:result = SMAC_CheatDetected(client, Detection_UltraMovement, info);
	CloseHandle(info);

	if (result != Plugin_Continue)
		return 0;

	g_iDetects[client][check]++;
	g_fNextNotice[client][check] = now + NOTICE_COOLDOWN;

	SMAC_LogAction(client, "%s (Detection #%i) %s", g_sCheck[check], g_iDetects[client][check], detail);
	SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, g_sCheck[check], g_iDetects[client][check]);

	if (action == 3)
	{
		SMAC_LogAction(client, "was banned for %s.", g_sCheck[check]);
		SMAC_Ban(client, "%s Detection", g_sCheck[check]);
	}
	else if (action == 2)
	{
		SMAC_LogAction(client, "was kicked for %s.", g_sCheck[check]);
		KickClient(client, "%t", "SMAC_UltraKick");
	}

	return action;
}

/**
 * Helpers
 */
bool:IsPlaying(client)
{
	return IS_CLIENT(client) && IsClientInGame(client) && !IsFakeClient(client)
		&& IsPlayerAlive(client) && !IsClientObserver(client);
}

/* R52 fn_146748 (entity gravity 0 or 1); a changed movement speed is treated the same. */
bool:IsNormalGravity(client)
{
	new Float:gravity = GetEntityGravity(client);
	if (gravity != 0.0 && gravity != 1.0)
		return false;

	return GetEntPropFloat(client, Prop_Data, "m_flLaggedMovementValue") == 1.0;
}

bool:IsIgnored(client)
{
	return GetGameTime() < g_fIgnoreUntil[client];
}

IgnoreClient(client, Float:seconds)
{
	new Float:until = GetGameTime() + seconds;
	if (until > g_fIgnoreUntil[client])
		g_fIgnoreUntil[client] = until;
}

CopyVector(const Float:src[3], Float:dst[3])
{
	dst[0] = src[0];
	dst[1] = src[1];
	dst[2] = src[2];
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
