#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>
#include <smac_ultra>

/*
 * SMAC Ultr@ R52 port: aimbot detectors that work on raw usercmds.
 *
 * Logic recovered from 001_SMAC_Global.smx R52 (docs/R52_DECODED.md §1).
 * Both detectors need the aim pre-filter (sequential cmdnum, tickcount moved,
 * no +use, on ground) and a usercmd with mouse[0] == mouse[1] == 0, i.e. the
 * view moved without any mouse input:
 *
 *   PRG Pass.Mode:301/302 - yaw jumps by more than 100° in one cmd without mouse
 *                           input. 301: the new view is on an enemy. 302: no
 *                           target, but it repeats for more than 5 cmds (spin).
 *   AGTNL Mode:200/201    - micro step 0.005°..0.007° in yaw (200) or pitch (201)
 *                           without mouse input while the view is on an enemy,
 *                           two cmds in a row (an m_filter residual lasts one cmd).
 *
 * Keyboard turning is bounded by cl_yawspeed; it is queried and clients whose
 * key turn per tick could reach the PRG threshold, or that use a joystick, are
 * skipped. R52 instead kicks for cl_yawspeed != 210 in its cvar checker.
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: Aimbot",
	author = SMAC_AUTHOR,
	description = "AimBot PRG 301/302 and AGTNL 200/201 from SMAC Ultr@ R52",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define PRG_MIN_YAW			100.0
#define PRG_SPIN_STREAK		5

#define AGTNL_MIN_STEP		0.005
#define AGTNL_MAX_STEP		0.007
#define AGTNL_STREAK		1

#define SERVER_SNAP_TOL		1.0
#define QUERY_INTERVAL		60.0

new Handle:g_hCvarPrgWarn = INVALID_HANDLE;
new Handle:g_hCvarPrgBan = INVALID_HANDLE;
new Handle:g_hCvarNlWarn = INVALID_HANDLE;
new Handle:g_hCvarNlBan = INVALID_HANDLE;

new g_iVAngleOffset = -1;

new bool:g_bKeyTurnSafe[MAXPLAYERS+1];
new bool:g_bJoystick[MAXPLAYERS+1];

new g_iSpinStreak[MAXPLAYERS+1];
new g_iPrgDetects[MAXPLAYERS+1];

new g_iNlStreak[MAXPLAYERS+1][2];
new g_iNlDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	Ultra_OnPluginStart();

	g_hCvarPrgWarn = SMAC_CreateConVar("smac_aimbot_Advanced_Warning_PRG", "3", "AimBot PRG Pass.Mode:301/302 detections before admins are notified. (0 = never)", _, true, 0.0);
	g_hCvarPrgBan = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_PRG", "5", "AimBot PRG Pass.Mode:301/302 detections before punish: -N kick, +N ban, 0 = off", _, true, -100.0, true, 100.0);
	g_hCvarNlWarn = SMAC_CreateConVar("smac_aimbot_Advanced_Warning_AGTNL", "1", "AimBot AGTNL Mode:200/201 detections before admins are notified. (0 = never)", _, true, 0.0);
	g_hCvarNlBan = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_AGTNL", "3", "AimBot AGTNL Mode:200/201 detections before punish: -N kick, +N ban, 0 = off (R52 default: 1)", _, true, -100.0, true, 100.0);

	CreateTimer(QUERY_INTERVAL, Timer_QueryAll, _, TIMER_REPEAT);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
}

public OnMapStart()
{
	g_iVAngleOffset = -1;
}

public OnGameFrame()
{
	SMAC_ServerLagSample();
}

public OnClientPutInServer(client)
{
	Ultra_ResetClient(client);

	/* Unknown until the queries answer. */
	g_bKeyTurnSafe[client] = false;
	g_bJoystick[client] = false;

	g_iSpinStreak[client] = 0;
	g_iPrgDetects[client] = 0;
	g_iNlStreak[client][0] = g_iNlStreak[client][1] = 0;
	g_iNlDetects[client] = 0;

	if (!IsFakeClient(client))
		QueryClient(client);
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

QueryClient(client)
{
	QueryClientConVar(client, "cl_yawspeed", Query_YawSpeed);
	QueryClientConVar(client, "joystick", Query_Joystick);
}

public Query_YawSpeed(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[])
{
	if (!IS_CLIENT(client) || !IsClientInGame(client))
		return;

	if (result != ConVarQuery_Okay)
	{
		g_bKeyTurnSafe[client] = false;
		return;
	}

	/* Max key turn per tick: cl_yawspeed * cl_anglespeedkey(<=1 when slowed) * interval.
	   Allow +speed factor up to 2 to stay safe. */
	g_bKeyTurnSafe[client] = (StringToFloat(cvarValue) * 2.0 * GetTickInterval() < PRG_MIN_YAW * 0.5);
}

public Query_Joystick(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[])
{
	if (!IS_CLIENT(client) || !IsClientInGame(client))
		return;

	/* A missing cvar means no joystick support at all. */
	g_bJoystick[client] = (result == ConVarQuery_Okay && StringToInt(cvarValue) != 0);
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!Ultra_IsPlaying(client))
	{
		g_bUHasPrev[client] = false;
		return Plugin_Continue;
	}

	if (PassesAimFilter(client, buttons, cmdnum, tickcount) && mouse[0] == 0 && mouse[1] == 0)
	{
		CheckPRG(client, angles);
		CheckAGTNL(client, angles);
	}
	else
	{
		g_iSpinStreak[client] = 0;
		g_iNlStreak[client][0] = g_iNlStreak[client][1] = 0;
	}

	Ultra_StoreCmd(client, buttons, angles, cmdnum, tickcount);
	return Plugin_Continue;
}

bool:PassesAimFilter(client, buttons, cmdnum, tickcount)
{
	if (!g_bKeyTurnSafe[client] || g_bJoystick[client])
		return false;

	if (!Ultra_IsSequential(client, cmdnum, tickcount))
		return false;

	if ((buttons & IN_USE) || !(GetEntityFlags(client) & FL_ONGROUND))
		return false;

	return !Ultra_IsIgnored(client) && !Ultra_IsLagging(client) && !Ultra_IsSpecialMove(client);
}

/* Server-forced view change (teleport with angles, fixangle): pl.v_angle already
   holds the new angles before the client's cmd runs. */
bool:IsServerSnap(client, const Float:angles[3])
{
	if (g_iVAngleOffset == -1)
	{
		#if SOURCEMOD_V_MAJOR >= 1 && SOURCEMOD_V_MINOR >= 7
		g_iVAngleOffset = FindDataMapInfo(client, "v_angle");
		#else
		g_iVAngleOffset = FindDataMapOffs(client, "v_angle");
		#endif
		if (g_iVAngleOffset == -1)
			g_iVAngleOffset = -2;
	}

	if (g_iVAngleOffset < 0)
		return false;

	decl Float:vAng[3];
	GetEntDataVector(client, g_iVAngleOffset, vAng);
	return Ultra_AngleDiff(vAng[1], angles[1]) < SERVER_SNAP_TOL
		&& Ultra_AngleDiff(vAng[1], g_fUPrevAng[client][1]) > SERVER_SNAP_TOL;
}

bool:IsEnemy(client, target)
{
	return target > 0 && IsClientInGame(target) && IsPlayerAlive(target)
		&& GetClientTeam(target) != GetClientTeam(client);
}

CheckPRG(client, const Float:angles[3])
{
	new ban = GetConVarInt(g_hCvarPrgBan);
	if (ban == 0)
		return;

	new Float:dYaw = Ultra_AngleDiff(angles[1], g_fUPrevAng[client][1]);
	if (dYaw <= PRG_MIN_YAW || IsServerSnap(client, angles))
	{
		g_iSpinStreak[client] = 0;
		return;
	}

	new target = Ultra_TraceAimTarget(client, angles);
	new mode;
	if (IsEnemy(client, target))
	{
		mode = 301;
		g_iSpinStreak[client] = 0;
	}
	else
	{
		if (++g_iSpinStreak[client] <= PRG_SPIN_STREAK)
			return;
		g_iSpinStreak[client] = 0;
		mode = 302;
	}

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "mode", mode);
	KvSetFloat(info, "yaw_delta", dYaw);
	KvSetNum(info, "target", target);

	decl String:sWeapon[32], String:sDetail[128];
	GetClientWeapon(client, sWeapon, sizeof(sWeapon));
	if (mode == 301)
		FormatEx(sDetail, sizeof(sDetail), "Mode:%i | Weapon:%s | yaw %.1f° without mouse onto %N", mode, sWeapon, dYaw, target);
	else
		FormatEx(sDetail, sizeof(sDetail), "Mode:%i | Weapon:%s | yaw %.1f° without mouse, %i cmds", mode, sWeapon, dYaw, PRG_SPIN_STREAK + 1);

	Ultra_Report(client, Detection_UltraPRG, info, g_iPrgDetects[client],
		GetConVarInt(g_hCvarPrgWarn), ban, "AimBot (Passive Route Guidance)", sDetail);
	CloseHandle(info);
}

CheckAGTNL(client, const Float:angles[3])
{
	new ban = GetConVarInt(g_hCvarNlBan);
	if (ban == 0)
		return;

	new Float:dPitch = Ultra_AngleDiff(angles[0], g_fUPrevAng[client][0]);
	new Float:dYaw = Ultra_AngleDiff(angles[1], g_fUPrevAng[client][1]);

	new bool:bYaw = (dYaw > AGTNL_MIN_STEP && dYaw < AGTNL_MAX_STEP);
	new bool:bPitch = (dPitch > AGTNL_MIN_STEP && dPitch < AGTNL_MAX_STEP);
	if (!bYaw && !bPitch)
	{
		g_iNlStreak[client][0] = g_iNlStreak[client][1] = 0;
		return;
	}

	new target = Ultra_TraceAimTarget(client, angles);
	if (!IsEnemy(client, target))
	{
		g_iNlStreak[client][0] = g_iNlStreak[client][1] = 0;
		return;
	}

	g_iNlStreak[client][0] = bYaw ? g_iNlStreak[client][0] + 1 : 0;
	g_iNlStreak[client][1] = bPitch ? g_iNlStreak[client][1] + 1 : 0;

	new axis;
	if (g_iNlStreak[client][0] > AGTNL_STREAK)
		axis = 0;
	else if (g_iNlStreak[client][1] > AGTNL_STREAK)
		axis = 1;
	else
		return;

	g_iNlStreak[client][axis] = 0;

	new mode = 200 + axis;
	new Float:dStep = (axis == 0) ? dYaw : dPitch;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "mode", mode);
	KvSetFloat(info, "step", dStep);
	KvSetNum(info, "target", target);

	decl String:sWeapon[32], String:sDetail[128];
	GetClientWeapon(client, sWeapon, sizeof(sWeapon));
	FormatEx(sDetail, sizeof(sDetail), "Mode:%i | Weapon:%s | step %.4f° without mouse on %N", mode, sWeapon, dStep, target);

	Ultra_Report(client, Detection_UltraNullAim, info, g_iNlDetects[client],
		GetConVarInt(g_hCvarNlWarn), ban, "AimBot (Automatic Route - Null Level)", sDetail);
	CloseHandle(info);
}
