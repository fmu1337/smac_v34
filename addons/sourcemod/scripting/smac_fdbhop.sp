#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: BunnyHop Fast Detect / Fast Run
 *
 * Original module by Danyas for SMAC v34.
 * From Ultr@ smac_FD_BHOP: "Fast Detect" catches scripted bhop with or
 * without Jump trigger, plus sustained overspeed (Fast Run). Soft default 0.
 */

public Plugin:myinfo =
{
	name = "SMAC: BunnyHop Fast Detect",
	author = SMAC_AUTHOR,
	description = "Ultr@ FD_BHOP / Fast Run detectors",
	version = SMAC_VERSION,
	url = SMAC_URL
};

/* Land → leave-ground window (~5 ticks @ 66). Script hops rejump instantly. */
#define BHOP_LEAVE_WINDOW	0.08
#define BHOP_MIN_SPEED		250.0
#define BHOP_STREAK_NEED	12
#define FASTRUN_SPEED		320.0
#define FASTRUN_STREAK		40

new Handle:g_hCvarFd = INVALID_HANDLE;

new bool:g_bWasOnGround[MAXPLAYERS+1];
new Float:g_fLastLand[MAXPLAYERS+1];
new g_iPerfectHops[MAXPLAYERS+1];
new g_iBhopDet[MAXPLAYERS+1];
new g_iRunStreak[MAXPLAYERS+1];
new g_iRunDet[MAXPLAYERS+1];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	/* 0=off, 1=notice, 2=kick, 3=ban — mirrors Ultr@ smac_FD_BHOP. Default off (surf). */
	g_hCvarFd = SMAC_CreateConVar("smac_FD_BHOP", "0", "Fast Bhop/Run: 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);

	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
}

public OnClientPutInServer(client)
{
	ResetClient(client);
}

public OnClientDisconnect(client)
{
	ResetClient(client);
}

ResetClient(client)
{
	g_bWasOnGround[client] = false;
	g_fLastLand[client] = 0.0;
	g_iPerfectHops[client] = 0;
	g_iBhopDet[client] = 0;
	g_iRunStreak[client] = 0;
	g_iRunDet[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_iPerfectHops[client] = 0;
		g_iRunStreak[client] = 0;
		g_fIgnoreUntil[client] = GetGameTime() + 2.0;
	}
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	new mode = GetConVarInt(g_hCvarFd);
	if (mode <= 0)
		return Plugin_Continue;
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;
	if (GetGameTime() < g_fIgnoreUntil[client])
		return Plugin_Continue;

	new MoveType:mt = GetEntityMoveType(client);
	if (mt == MOVETYPE_NOCLIP || mt == MOVETYPE_LADDER || mt == MOVETYPE_OBSERVER)
	{
		g_bWasOnGround[client] = false;
		g_iPerfectHops[client] = 0;
		g_iRunStreak[client] = 0;
		return Plugin_Continue;
	}

	new bool:onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;
	decl Float:v[3];
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", v);
	new Float:speed = SquareRoot((v[0] * v[0]) + (v[1] * v[1]));
	new Float:now = GetGameTime();

	/* Fast Detect: land then leave ground in a tiny window at speed (jump optional). */
	if (onGround && !g_bWasOnGround[client])
	{
		g_fLastLand[client] = now;
	}
	else if (!onGround && g_bWasOnGround[client])
	{
		if (g_fLastLand[client] > 0.0
			&& (now - g_fLastLand[client]) <= BHOP_LEAVE_WINDOW
			&& speed >= BHOP_MIN_SPEED)
		{
			g_iPerfectHops[client]++;
			if (g_iPerfectHops[client] >= BHOP_STREAK_NEED)
			{
				g_iPerfectHops[client] = 0;
				g_iBhopDet[client]++;
				ReactBhop(client, mode);
			}
		}
		else
		{
			g_iPerfectHops[client] = 0;
		}
		g_fLastLand[client] = 0.0;
	}
	else if (onGround && g_fLastLand[client] > 0.0
		&& (now - g_fLastLand[client]) > BHOP_LEAVE_WINDOW)
	{
		/* Stood / walked after landing — break perfect-hop streak. */
		g_iPerfectHops[client] = 0;
		g_fLastLand[client] = 0.0;
	}

	if (onGround && speed < 200.0)
		g_iPerfectHops[client] = 0;

	/* Fast Run: sustained XY speed above CSS walk+sprint ceiling. */
	if (onGround && speed >= FASTRUN_SPEED)
	{
		g_iRunStreak[client]++;
		if (g_iRunStreak[client] >= FASTRUN_STREAK)
		{
			g_iRunStreak[client] = 0;
			g_iRunDet[client]++;
			ReactRun(client, mode, speed);
		}
	}
	else
	{
		g_iRunStreak[client] = 0;
	}

	g_bWasOnGround[client] = onGround;
	return Plugin_Continue;
}

ReactBhop(client, mode)
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iBhopDet[client]);
	if (SMAC_CheatDetected(client, Detection_FastBhop, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_FastBhopDetected", client, g_iBhopDet[client]);
		SMAC_LogAction(client, "bunnyhop fast-detect (Detection #%i)", g_iBhopDet[client]);
		if (mode == 2)
			KickClient(client, "%t", "SMAC_FastBhopKick");
		else if (mode == 3)
			SMAC_Ban(client, "BunnyHop Fast Detect");
	}
	CloseHandle(info);
}

ReactRun(client, mode, Float:speed)
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iRunDet[client]);
	KvSetFloat(info, "speed", speed);
	if (SMAC_CheatDetected(client, Detection_FdFastRun, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_FastRunDetected", client, g_iRunDet[client]);
		SMAC_LogAction(client, "fd fast-run (Detection #%i | speed=%.1f)", g_iRunDet[client], speed);
		if (mode == 2)
			KickClient(client, "%t", "SMAC_FastRunKick");
		else if (mode == 3)
			SMAC_Ban(client, "Fast Run Cheat Detect");
	}
	CloseHandle(info);
}
