#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smac>

/*
 * SMAC: Simple Sanity Checks
 *
 * Original module by Danyas for SMAC v34.
 * Ideas rewritten from SSAC v2 (null138 / hlmod SSAC Anti-Cheat) —
 * timed bhop, airstuck tick reuse, magic-angle fast ladder, magic wish
 * velocity, cmdnum lag exploit, and PreThink↔cmd mouse-less aim.
 * Not a 1:1 port; soft ban defaults for high-FP checks.
 */

public Plugin:myinfo =
{
	name = "SMAC: Simple Sanity Checks",
	author = SMAC_AUTHOR,
	description = "SSAC-style bhop/airstuck/ladder/fastrun/lag/aim checks",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define MAX_JUMPS_ROW		30
#define MAX_AIR_ROW			4
#define MAX_AIR_ROW_FAST	2
#define BHOP_WINDOW			0.18
#define BHOP_MIN_SPEED		280.0
#define LAG_CMD_JUMP		200
#define AIM_CHECK_NEED		2

new Handle:g_hCvarBhopBan = INVALID_HANDLE;
new Handle:g_hCvarAirBan = INVALID_HANDLE;
new Handle:g_hCvarAirReact = INVALID_HANDLE;
new Handle:g_hCvarLadderBan = INVALID_HANDLE;
new Handle:g_hCvarRunBan = INVALID_HANDLE;
new Handle:g_hCvarLagBan = INVALID_HANDLE;
new Handle:g_hCvarAimBan = INVALID_HANDLE;

new Float:g_fLastJumpTime[MAXPLAYERS+1];
new Float:g_fThinkAngles[MAXPLAYERS+1][3];
new bool:g_bHaveThinkAng[MAXPLAYERS+1];
new bool:g_bAliveAim[MAXPLAYERS+1];
new bool:g_bLadderWarned[MAXPLAYERS+1];

new g_iJumpsRow[MAXPLAYERS+1];
new g_iLastTickCount[MAXPLAYERS+1];
new g_iAirRow[MAXPLAYERS+1];
new g_iAimTicks[MAXPLAYERS+1];
new g_iLastButtons[MAXPLAYERS+1];
new g_iLastCmdNum[MAXPLAYERS+1];

new g_iBhopDet[MAXPLAYERS+1];
new g_iAirDet[MAXPLAYERS+1];
new g_iAirFastDet[MAXPLAYERS+1];
new g_iLadderDet[MAXPLAYERS+1];
new g_iRunDet[MAXPLAYERS+1];
new g_iLagDet[MAXPLAYERS+1];
new g_iAimDet[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarBhopBan = SMAC_CreateConVar("smac_ssac_bhop_ban", "0", "Timed-bhop detections before ban. (0 = Never; surf FP)", _, true, 0.0);
	g_hCvarAirBan = SMAC_CreateConVar("smac_ssac_airstuck_ban", "0", "Airstuck detections before ban. (0 = Never)", _, true, 0.0);
	/* Ultr@ 0=off 1=notice 2=kick 3=ban — gates both Airstuck and Fast Detect. Soft default 1 (observe). */
	g_hCvarAirReact = SMAC_CreateConVar("smac_Airstuck_reaction", "1", "Ultr@ Airstuck/FD: 0=off, 1=notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarLadderBan = SMAC_CreateConVar("smac_ssac_ladder_ban", "0", "Fast-ladder detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarRunBan = SMAC_CreateConVar("smac_ssac_fastrun_ban", "0", "Magic wishspeed detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarLagBan = SMAC_CreateConVar("smac_ssac_lag_ban", "0", "Cmdnum lag-exploit detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarAimBan = SMAC_CreateConVar("smac_ssac_aim_ban", "0", "Mouse-less aim detections before ban. (0 = Never; lag FP)", _, true, 0.0);
}

public OnClientPutInServer(client)
{
	ResetClient(client);
	if (!IsFakeClient(client))
		SDKHook(client, SDKHook_PreThink, OnClientPreThink);
}

public OnClientDisconnect(client)
{
	ResetClient(client);
}

ResetClient(client)
{
	g_fLastJumpTime[client] = 0.0;
	g_bHaveThinkAng[client] = false;
	g_bAliveAim[client] = false;
	g_bLadderWarned[client] = false;
	g_iJumpsRow[client] = 0;
	g_iLastTickCount[client] = 0;
	g_iAirRow[client] = 0;
	g_iAimTicks[client] = 0;
	g_iLastButtons[client] = 0;
	g_iLastCmdNum[client] = 0;
	g_iBhopDet[client] = 0;
	g_iAirDet[client] = 0;
	g_iAirFastDet[client] = 0;
	g_iLadderDet[client] = 0;
	g_iRunDet[client] = 0;
	g_iLagDet[client] = 0;
	g_iAimDet[client] = 0;
}

public OnClientPreThink(client)
{
	if (IsClientInGame(client) && IsPlayerAlive(client))
	{
		GetClientEyeAngles(client, g_fThinkAngles[client]);
		g_bHaveThinkAng[client] = true;
	}
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	CheckLagExploit(client, cmdnum);

	if (IsPlayerAlive(client))
	{
		CheckTimedBhop(client, buttons);
		CheckAirStuck(client, tickcount);
		CheckFastLadder(client, buttons, angles);
		CheckFastRun(client, buttons, vel);
		CheckMouselessAim(client, buttons, angles, mouse);
	}
	else
	{
		g_bAliveAim[client] = false;
		g_iAirRow[client] = 0;
	}

	g_iLastButtons[client] = buttons;
	return Plugin_Continue;
}

CheckTimedBhop(client, buttons)
{
	if (!((buttons & IN_JUMP) && !(g_iLastButtons[client] & IN_JUMP)))
		return;

	decl Float:fVel[3];
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", fVel);
	new Float:speed = SquareRoot((fVel[0] * fVel[0]) + (fVel[1] * fVel[1]));
	new Float:timeDiff = GetGameTime() - g_fLastJumpTime[client];

	if (g_fLastJumpTime[client] <= 0.0 || timeDiff < 0.0 || timeDiff >= BHOP_WINDOW || speed < BHOP_MIN_SPEED)
	{
		g_fLastJumpTime[client] = GetGameTime();
		g_iJumpsRow[client] = 0;
		return;
	}

	g_iJumpsRow[client]++;
	g_fLastJumpTime[client] = GetGameTime();

	if (g_iJumpsRow[client] >= MAX_JUMPS_ROW)
	{
		g_iJumpsRow[client] = 0;
		g_iBhopDet[client]++;
		FireDetect(client, Detection_TimedBhop, g_iBhopDet[client], g_hCvarBhopBan,
			"SMAC_TimedBhopDetected", "timed perfect bhop streak");
	}
}

CheckAirStuck(client, tickcount)
{
	new react = GetConVarInt(g_hCvarAirReact);
	if (react <= 0)
	{
		g_iLastTickCount[client] = tickcount;
		g_iAirRow[client] = 0;
		return;
	}

	if (tickcount == g_iLastTickCount[client] && tickcount > 0)
	{
		g_iAirRow[client]++;

		/* Fast Detect: shorter reuse streak. */
		if (g_iAirRow[client] == MAX_AIR_ROW_FAST)
		{
			g_iAirFastDet[client]++;
			FireAirReact(client, Detection_AirStuckFast, g_iAirFastDet[client], react,
				"SMAC_AirStuckFastDetected", "airstuck fast-detect (tick reuse)");
		}

		if (g_iAirRow[client] > MAX_AIR_ROW)
		{
			g_iAirRow[client] = 0;
			g_iAirDet[client]++;
			FireAirReact(client, Detection_AirStuck, g_iAirDet[client], react,
				"SMAC_AirStuckDetected", "airstuck (repeated tickcount)");
		}
	}
	else
	{
		g_iAirRow[client] = 0;
	}
	g_iLastTickCount[client] = tickcount;
}

FireAirReact(client, DetectionType:type, detects, react, const String:phrase[], const String:logTag[])
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", detects);
	if (SMAC_CheatDetected(client, type, info) == Plugin_Continue)
	{
		if (react >= 1)
			SMAC_PrintAdminNotice("%t", phrase, client, detects);
		SMAC_LogAction(client, "%s (Detection #%i)", logTag, detects);
		if (react == 2 && SMAC_MayEnforce(type))
			KickClient(client, "%t", "SMAC_AirStuckKick");
		else if (react == 3)
			SMAC_Ban(client, "Airstuck Detection");
		/* react==1: notice/log only */
	}
	CloseHandle(info);
}

CheckFastLadder(client, buttons, const Float:angles[3])
{
	if (!(buttons & (IN_MOVELEFT | IN_MOVERIGHT)))
		return;
	if (GetEntityMoveType(client) != MOVETYPE_LADDER)
		return;

	/* Cheat magic yaws from SSAC / common ladder scripts. */
	new Float:yaw = angles[1];
	if (yaw != -89.0 && yaw != 89.20 && yaw != 179.150 && yaw != 0.20
		&& yaw != 89.022 && yaw != 270.977984)
		return;

	if (g_bLadderWarned[client])
		return;

	g_bLadderWarned[client] = true;
	g_iLadderDet[client]++;
	FireDetect(client, Detection_FastLadder, g_iLadderDet[client], g_hCvarLadderBan,
		"SMAC_FastLadderDetected", "fast ladder magic yaw");
}

CheckFastRun(client, buttons, const Float:vel[3])
{
	if (!(buttons & (IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT)))
		return;

	/* Magic wishspeeds used by some run/speed scripts (SSAC).
	 * Original negative-range test was inverted; corrected here. */
	if (vel[0] == 194.3998 || vel[1] == 194.3998
		|| vel[0] == -194.3998 || vel[1] == -194.3998
		|| (vel[0] > 204.60018 && vel[0] < 206.60018)
		|| (vel[1] > 204.60018 && vel[1] < 206.60018)
		|| (vel[0] < -204.60018 && vel[0] > -206.60018)
		|| (vel[1] < -204.60018 && vel[1] > -206.60018))
	{
		g_iRunDet[client]++;
		FireDetect(client, Detection_FastRun, g_iRunDet[client], g_hCvarRunBan,
			"SMAC_FastRunDetected", "magic wishspeed values");
	}
}

CheckLagExploit(client, cmdnum)
{
	if (cmdnum <= 0)
	{
		g_iLastCmdNum[client] = cmdnum;
		return;
	}

	if (IsPlayerAlive(client) && g_iLastCmdNum[client] > 0
		&& (cmdnum - g_iLastCmdNum[client]) > LAG_CMD_JUMP)
	{
		g_iLagDet[client]++;
		FireDetect(client, Detection_LagExploit, g_iLagDet[client], g_hCvarLagBan,
			"SMAC_LagExploitDetected", "cmdnum lag exploit");
	}

	g_iLastCmdNum[client] = cmdnum;
}

CheckMouselessAim(client, buttons, const Float:angles[3], mouse[2])
{
	if (!g_bAliveAim[client])
	{
		g_bAliveAim[client] = true;
		g_iAimTicks[client] = 0;
		return;
	}

	if (!g_bHaveThinkAng[client])
		return;

	if ((buttons & IN_LEFT) || (buttons & IN_RIGHT))
	{
		g_iAimTicks[client] = 0;
		return;
	}

	new Float:diff = GetAngleDiff(g_fThinkAngles[client], angles);
	if (diff > 0.1 && diff < 2.0
		&& mouse[0] >= -5 && mouse[0] <= 5
		&& mouse[1] >= -5 && mouse[1] <= 5)
	{
		if (mouse[0] == 0 && mouse[1] == 0)
			g_iAimTicks[client]++;
		if (g_iAimTicks[client] > AIM_CHECK_NEED)
		{
			g_iAimTicks[client] = 0;
			g_iAimDet[client]++;
			FireDetect(client, Detection_MouselessAim, g_iAimDet[client], g_hCvarAimBan,
				"SMAC_MouselessAimDetected", "mouse-less aim (PreThink vs cmd)");
		}
	}
	else
	{
		g_iAimTicks[client] = 0;
	}
}

Float:GetAngleDiff(const Float:a[3], const Float:b[3])
{
	decl Float:v1[3], Float:v2[3];
	GetAngleVectors(a, v1, NULL_VECTOR, NULL_VECTOR);
	GetAngleVectors(b, v2, NULL_VECTOR, NULL_VECTOR);
	new Float:dot = (v1[0] * v2[0]) + (v1[1] * v2[1]) + (v1[2] * v2[2]);
	if (dot > 1.0) dot = 1.0;
	if (dot < -1.0) dot = -1.0;
	return RadToDeg(ArcCosine(dot));
}

FireDetect(client, DetectionType:type, detects, Handle:hBanCvar, const String:phrase[], const String:logTag[])
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", detects);
	if (SMAC_CheatDetected(client, type, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", phrase, client, detects);
		SMAC_LogAction(client, "%s (Detection #%i)", logTag, detects);
		new banAt = GetConVarInt(hBanCvar);
		if (banAt && detects >= banAt)
		{
			SMAC_LogAction(client, "was banned for %s.", logTag);
			SMAC_Ban(client, "SSAC Sanity Detection");
		}
	}
	CloseHandle(info);
}
