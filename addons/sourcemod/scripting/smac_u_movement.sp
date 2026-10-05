#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>
#include <smac_ultra>

/*
 * SMAC Ultr@ R52 port: movement detectors.
 *
 * Logic recovered from 001_SMAC_Global.smx R52 (docs/R52_DECODED.md §4):
 *   Fast Run Cheat    - wishmove contradicts the movement buttons (e.g. sidemove
 *                       without +moveleft/+moveright, which is what autostrafe does)
 *                       while horizontal speed > 289. More than 22 cmds in a row.
 *   Advanced BunnyHop - jump on the first ground tick after landing ("perfect" hop)
 *                       at >= 350 u/s. More than 12 perfect hops in a row.
 *   Eye Angles 04     - pitch outside [-89.9, 89.9] or roll outside [-30, 30].
 *                       Legacy smac_eyetest only reacts outside ±90.
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: Movement",
	author = SMAC_AUTHOR,
	description = "Fast Run, Advanced BunnyHop and Eye Angles test from SMAC Ultr@ R52",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define FASTRUN_SPEED		289.0
#define FASTRUN_STREAK		22

#define ADVBHOP_SPEED		350.0
#define ADVBHOP_STREAK		12
#define ADVBHOP_MAX_GROUND	1

#define EYE_MAX_PITCH		89.9
#define EYE_MAX_ROLL		30.0

new Handle:g_hCvarFastRun = INVALID_HANDLE;
new Handle:g_hCvarAdvBhop = INVALID_HANDLE;
new Handle:g_hCvarEyeTest = INVALID_HANDLE;

new g_iRunStreak[MAXPLAYERS+1];
new g_iRunDetects[MAXPLAYERS+1];

new g_iGroundTicks[MAXPLAYERS+1];
new g_iHopStreak[MAXPLAYERS+1];
new g_iHopDetects[MAXPLAYERS+1];

new Float:g_fEyeNext[MAXPLAYERS+1];
new g_iEyeDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	Ultra_OnPluginStart();

	g_hCvarFastRun = SMAC_CreateConVar("smac_FD_BHOP", "1", "Fast Run Cheat (wishmove without keys at > 289 u/s): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarAdvBhop = SMAC_CreateConVar("smac_AdvancedBhop_reaction", "1", "Advanced BunnyHop (12+ perfect hops at >= 350 u/s): 0=off, 1=admin notice, 2=kick, 3=ban. Set 0 on bhop/surf servers.", _, true, 0.0, true, 3.0);
	g_hCvarEyeTest = SMAC_CreateConVar("smac_eyetest_reaction", "1", "Eye Angles test 04 (pitch > 89.9 / roll > 30): 0=off, 1=admin notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);

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

	g_iRunStreak[client] = 0;
	g_iRunDetects[client] = 0;
	g_iGroundTicks[client] = 0;
	g_iHopStreak[client] = 0;
	g_iHopDetects[client] = 0;
	g_fEyeNext[client] = 0.0;
	g_iEyeDetects[client] = 0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!Ultra_IsPlaying(client))
	{
		g_bUHasPrev[client] = false;
		return Plugin_Continue;
	}

	if (g_bUHasPrev[client] && !Ultra_IsIgnored(client) && !Ultra_IsLagging(client) && !Ultra_IsSpecialMove(client))
	{
		decl Float:vVel[3];
		GetEntPropVector(client, Prop_Data, "m_vecVelocity", vVel);
		new Float:fSpeed = SquareRoot(vVel[0] * vVel[0] + vVel[1] * vVel[1]);

		CheckFastRun(client, buttons, vel, fSpeed);
		CheckAdvBhop(client, buttons, fSpeed);
		CheckEyeAngles(client, angles);
	}
	else
	{
		g_iRunStreak[client] = 0;
		g_iHopStreak[client] = 0;
		g_iGroundTicks[client] = 0;
	}

	Ultra_StoreCmd(client, buttons, angles, cmdnum, tickcount);
	return Plugin_Continue;
}

CheckFastRun(client, buttons, const Float:vel[3], Float:fSpeed)
{
	new level = GetConVarInt(g_hCvarFastRun);
	if (level <= 0)
		return;

	new bool:bMismatch = (vel[0] > 0.0 && !(buttons & IN_FORWARD))
		|| (vel[0] < 0.0 && !(buttons & IN_BACK))
		|| (vel[1] > 0.0 && !(buttons & IN_MOVERIGHT))
		|| (vel[1] < 0.0 && !(buttons & IN_MOVELEFT));

	if (!bMismatch || fSpeed <= FASTRUN_SPEED)
	{
		g_iRunStreak[client] = 0;
		return;
	}

	if (++g_iRunStreak[client] <= FASTRUN_STREAK)
		return;

	g_iRunStreak[client] = 0;

	new Handle:info = CreateKeyValues("");
	KvSetFloat(info, "forwardmove", vel[0]);
	KvSetFloat(info, "sidemove", vel[1]);
	KvSetFloat(info, "speed", fSpeed);

	decl String:sDetail[128];
	FormatEx(sDetail, sizeof(sDetail), "fwd %.0f side %.0f buttons %i at %.0f u/s", vel[0], vel[1], buttons, fSpeed);
	Ultra_ReportLevel(client, Detection_FastRun, info, g_iRunDetects[client], level, "Fast Run Cheat", sDetail);
	CloseHandle(info);
}

CheckAdvBhop(client, buttons, Float:fSpeed)
{
	new level = GetConVarInt(g_hCvarAdvBhop);
	if (level <= 0)
		return;

	if (!(GetEntityFlags(client) & FL_ONGROUND))
	{
		/* Ground counter restarts on the next landing. */
		g_iGroundTicks[client] = 0;
		return;
	}

	g_iGroundTicks[client]++;

	/* Not a jump this tick (jump needs a fresh +jump press in CS:S). */
	if (!(buttons & IN_JUMP) || (g_iUPrevButtons[client] & IN_JUMP))
	{
		if (g_iGroundTicks[client] > ADVBHOP_MAX_GROUND)
			g_iHopStreak[client] = 0;
		return;
	}

	if (g_iGroundTicks[client] > ADVBHOP_MAX_GROUND || fSpeed < ADVBHOP_SPEED)
	{
		g_iHopStreak[client] = 0;
		return;
	}

	if (++g_iHopStreak[client] <= ADVBHOP_STREAK)
		return;

	g_iHopStreak[client] = 0;

	new Handle:info = CreateKeyValues("");
	KvSetFloat(info, "speed", fSpeed);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "%i perfect hops in a row at %.0f u/s", ADVBHOP_STREAK + 1, fSpeed);
	Ultra_ReportLevel(client, Detection_UltraAdvBhop, info, g_iHopDetects[client], level, "Advanced BunnyHop", sDetail);
	CloseHandle(info);
}

CheckEyeAngles(client, const Float:angles[3])
{
	new level = GetConVarInt(g_hCvarEyeTest);
	if (level <= 0 || GetGameTime() < g_fEyeNext[client])
		return;

	new Float:fPitch = Ultra_NormalizeAngle(angles[0]);
	new Float:fRoll = Ultra_NormalizeAngle(angles[2]);
	if (FloatAbs(fPitch) <= EYE_MAX_PITCH && FloatAbs(fRoll) <= EYE_MAX_ROLL)
		return;

	/* One report per 30 s, like legacy eyetest. */
	g_fEyeNext[client] = GetGameTime() + 30.0;

	new Handle:info = CreateKeyValues("");
	KvSetFloat(info, "pitch", angles[0]);
	KvSetFloat(info, "yaw", angles[1]);
	KvSetFloat(info, "roll", angles[2]);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "angles %.2f %.2f %.2f", angles[0], angles[1], angles[2]);
	Ultra_ReportLevel(client, Detection_UltraEyeAngles, info, g_iEyeDetects[client], level, "Eye Angles", sDetail);
	CloseHandle(info);
}
