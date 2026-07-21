#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Strafe Detector
 *
 * Original module by Danyas for SMAC v34.
 * Ideas loosely inspired by public/GPL movement checks seen in CowAC
 * (silent / perfect strafe streaks) and Bash (buttons vs sidemove,
 * impossible CSS sidemove magnitudes) via Cheat-Acid GRAB — rewritten
 * from scratch for old SourcePawn / CSS v34, not a line-for-line port.
 */

public Plugin:myinfo =
{
	name = "SMAC: Strafe Detector",
	author = SMAC_AUTHOR,
	description = "Detects silent/perfect strafe and illegal sidemove patterns",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define CSS_MAX_MOVE		400.0
#define SILENT_WINDOW		50

new Handle:g_hCvarSilentBan = INVALID_HANDLE;
new Handle:g_hCvarSilentStreak = INVALID_HANDLE;
new Handle:g_hCvarPerfectBan = INVALID_HANDLE;
new Handle:g_hCvarPerfectStreak = INVALID_HANDLE;
new Handle:g_hCvarIllegalBan = INVALID_HANDLE;
new Handle:g_hCvarIllegalStreak = INVALID_HANDLE;
new Handle:g_hCvarBlockIllegal = INVALID_HANDLE;

new Float:g_fPrevSide[MAXPLAYERS+1];
new g_iSilentStreak[MAXPLAYERS+1];
new g_iSilentDetects[MAXPLAYERS+1];
new g_iCmdNum[MAXPLAYERS+1];

new Float:g_fPrevYaw[MAXPLAYERS+1];
new bool:g_bHaveYaw[MAXPLAYERS+1];
new bool:g_bTurnRight[MAXPLAYERS+1];
new g_iPerfectStreak[MAXPLAYERS+1];
new g_iPerfectDetects[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];

new g_iIllegalStreak[MAXPLAYERS+1];
new g_iIllegalDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarSilentBan = SMAC_CreateConVar("smac_strafe_silent_ban", "0", "Silent-strafe detections before ban. (0 = Never ban)", _, true, 0.0);
	g_hCvarSilentStreak = SMAC_CreateConVar("smac_strafe_silent_streak", "14", "Consecutive opposite sidemove flips in a window before one detection.", _, true, 6.0);
	g_hCvarPerfectBan = SMAC_CreateConVar("smac_strafe_perfect_ban", "0", "Perfect-strafe detections before ban. (0 = Never ban)", _, true, 0.0);
	g_hCvarPerfectStreak = SMAC_CreateConVar("smac_strafe_perfect_streak", "18", "Consecutive turn+key syncs before one detection.", _, true, 8.0);
	g_hCvarIllegalBan = SMAC_CreateConVar("smac_strafe_illegal_ban", "0", "Illegal sidemove detections before ban. (0 = Never ban; default off — can FP on controllers)", _, true, 0.0);
	g_hCvarIllegalStreak = SMAC_CreateConVar("smac_strafe_illegal_streak", "12", "Consecutive illegal button/sidemove ticks before one detection.", _, true, 4.0);
	g_hCvarBlockIllegal = SMAC_CreateConVar("smac_strafe_block_illegal", "0", "Zero vel when illegal sidemove streak is active.", _, true, 0.0, true, 1.0);
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
	g_fPrevSide[client] = 0.0;
	g_iSilentStreak[client] = 0;
	g_iSilentDetects[client] = 0;
	g_iCmdNum[client] = 0;
	g_fPrevYaw[client] = 0.0;
	g_bHaveYaw[client] = false;
	g_bTurnRight[client] = false;
	g_iPerfectStreak[client] = 0;
	g_iPerfectDetects[client] = 0;
	g_iPrevButtons[client] = 0;
	g_iIllegalStreak[client] = 0;
	g_iIllegalDetects[client] = 0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	g_iCmdNum[client]++;

	CheckSilentStrafe(client, vel[1]);
	CheckPerfectStrafe(client, angles[1], buttons);
	new bool:changed = CheckIllegalSidemove(client, vel, buttons);

	g_iPrevButtons[client] = buttons;
	return changed ? Plugin_Changed : Plugin_Continue;
}

CheckSilentStrafe(client, Float:sidemove)
{
	new bool:flipped = false;
	if (sidemove > 0.0 && g_fPrevSide[client] < 0.0)
		flipped = true;
	else if (sidemove < 0.0 && g_fPrevSide[client] > 0.0)
		flipped = true;

	if (flipped)
	{
		g_iSilentStreak[client]++;
		if ((g_iCmdNum[client] % SILENT_WINDOW) == 1)
			MaybeSilentDetect(client);
	}
	else if (sidemove == 0.0 || (sidemove > 0.0) == (g_fPrevSide[client] > 0.0))
	{
		if (g_iSilentStreak[client] >= GetConVarInt(g_hCvarSilentStreak))
			MaybeSilentDetect(client);
		g_iSilentStreak[client] = 0;
	}

	g_fPrevSide[client] = sidemove;
}

MaybeSilentDetect(client)
{
	new need = GetConVarInt(g_hCvarSilentStreak);
	if (g_iSilentStreak[client] < need)
	{
		g_iSilentStreak[client] = 0;
		return;
	}

	new streak = g_iSilentStreak[client];
	g_iSilentStreak[client] = 0;
	g_iSilentDetects[client]++;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iSilentDetects[client]);
	KvSetNum(info, "streak", streak);

	if (SMAC_CheatDetected(client, Detection_SilentStrafe, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_SilentStrafeDetected", client, g_iSilentDetects[client]);
		SMAC_LogAction(client, "silent strafe (Detection #%i | streak=%i)", g_iSilentDetects[client], streak);

		new banAt = GetConVarInt(g_hCvarSilentBan);
		if (banAt && g_iSilentDetects[client] >= banAt)
		{
			SMAC_LogAction(client, "was banned for silent strafe.");
			SMAC_Ban(client, "Silent Strafe Detection");
		}
	}
	CloseHandle(info);
}

CheckPerfectStrafe(client, Float:yaw, buttons)
{
	if (!g_bHaveYaw[client])
	{
		g_fPrevYaw[client] = yaw;
		g_bHaveYaw[client] = true;
		return;
	}

	new Float:delta = yaw - g_fPrevYaw[client];
	while (delta > 180.0) delta -= 360.0;
	while (delta < -180.0) delta += 360.0;
	g_fPrevYaw[client] = yaw;

	/* Ignore tiny noise; need a clear turn direction. */
	if (FloatAbs(delta) < 0.5)
		return;

	new bool:turningRight = (delta > 0.0);
	new bool:dirChanged = (turningRight != g_bTurnRight[client]);
	g_bTurnRight[client] = turningRight;

	if (!dirChanged)
		return;

	new bool:synced = false;
	if (turningRight
		&& (buttons & IN_MOVERIGHT)
		&& !(g_iPrevButtons[client] & IN_MOVERIGHT)
		&& !(buttons & IN_MOVELEFT))
	{
		synced = true;
	}
	else if (!turningRight
		&& (buttons & IN_MOVELEFT)
		&& !(g_iPrevButtons[client] & IN_MOVELEFT)
		&& !(buttons & IN_MOVERIGHT))
	{
		synced = true;
	}

	if (synced)
	{
		g_iPerfectStreak[client]++;
		new need = GetConVarInt(g_hCvarPerfectStreak);
		if (g_iPerfectStreak[client] >= need)
		{
			new streak = g_iPerfectStreak[client];
			g_iPerfectStreak[client] = 0;
			g_iPerfectDetects[client]++;

			new Handle:info = CreateKeyValues("");
			KvSetNum(info, "detection", g_iPerfectDetects[client]);
			KvSetNum(info, "streak", streak);

			if (SMAC_CheatDetected(client, Detection_PerfectStrafe, info) == Plugin_Continue)
			{
				SMAC_PrintAdminNotice("%t", "SMAC_PerfectStrafeDetected", client, g_iPerfectDetects[client]);
				SMAC_LogAction(client, "perfect strafe sync (Detection #%i | streak=%i)", g_iPerfectDetects[client], streak);

				new banAt = GetConVarInt(g_hCvarPerfectBan);
				if (banAt && g_iPerfectDetects[client] >= banAt)
				{
					SMAC_LogAction(client, "was banned for perfect strafe.");
					SMAC_Ban(client, "Perfect Strafe Detection");
				}
			}
			CloseHandle(info);
		}
	}
	else
	{
		g_iPerfectStreak[client] = 0;
	}
}

bool:CheckIllegalSidemove(client, Float:vel[3], buttons)
{
	new reason = 0;
	new Float:side = vel[1];

	if (side > 0.0 && (buttons & IN_MOVELEFT))
		reason = 1;
	else if (side < 0.0 && (buttons & IN_MOVERIGHT))
		reason = 2;
	else if (side == 0.0 && ((buttons & IN_MOVELEFT) || (buttons & IN_MOVERIGHT))
		&& !((buttons & IN_MOVELEFT) && (buttons & IN_MOVERIGHT)))
		reason = 3;
	else if (side != 0.0 && !(buttons & IN_MOVELEFT) && !(buttons & IN_MOVERIGHT))
		reason = 4;
	else if ((FloatAbs(side) != CSS_MAX_MOVE && side != 0.0)
		|| (FloatAbs(vel[0]) != CSS_MAX_MOVE && vel[0] != 0.0))
	{
		/* Controllers / +strafe can legally produce odd values — only count if extreme. */
		if (FloatAbs(side) > CSS_MAX_MOVE + 1.0 || FloatAbs(vel[0]) > CSS_MAX_MOVE + 1.0)
			reason = 5;
		else if (FloatAbs(side) > 0.0 && FloatAbs(side) < 25.0)
			reason = 0; /* noise */
		else if (FloatAbs(side) != CSS_MAX_MOVE && side != 0.0
			&& FloatAbs(FloatAbs(side) - 112.5) > 0.1)
			reason = 6;
	}

	if (reason != 0)
		g_iIllegalStreak[client]++;
	else
		g_iIllegalStreak[client] = 0;

	new bool:changed = false;
	new need = GetConVarInt(g_hCvarIllegalStreak);
	if (GetConVarBool(g_hCvarBlockIllegal) && g_iIllegalStreak[client] >= 4)
	{
		vel[0] = 0.0;
		vel[1] = 0.0;
		vel[2] = 0.0;
		changed = true;
	}

	if (reason != 0 && g_iIllegalStreak[client] >= need)
	{
		new streak = g_iIllegalStreak[client];
		g_iIllegalStreak[client] = 0;
		g_iIllegalDetects[client]++;

		new Handle:info = CreateKeyValues("");
		KvSetNum(info, "detection", g_iIllegalDetects[client]);
		KvSetNum(info, "streak", streak);
		KvSetNum(info, "reason", reason);

		if (SMAC_CheatDetected(client, Detection_IllegalSidemove, info) == Plugin_Continue)
		{
			SMAC_PrintAdminNotice("%t", "SMAC_IllegalSidemoveDetected", client, g_iIllegalDetects[client]);
			SMAC_LogAction(client, "illegal sidemove (Detection #%i | streak=%i reason=%i)", g_iIllegalDetects[client], streak, reason);

			new banAt = GetConVarInt(g_hCvarIllegalBan);
			if (banAt && g_iIllegalDetects[client] >= banAt)
			{
				SMAC_LogAction(client, "was banned for illegal sidemove.");
				SMAC_Ban(client, "Illegal Sidemove Detection");
			}
		}
		CloseHandle(info);
	}

	return changed;
}
