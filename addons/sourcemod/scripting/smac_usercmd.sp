#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * Usercmd consistency checks. Nothing is punished: a check that crosses its threshold within one
 * WINDOW (30 s) is logged and shown to admins (smac_usercmd_notify), and raw samples plus periodic
 * summaries go to logs/smac_usercmd_diag.log so thresholds can be tuned on real players.
 *
 * MoveGrid  The client builds forwardmove / sidemove from keys only:
 *               forwardmove = a * cl_forwardspeed - b * cl_backspeed,  sidemove = (c - d) * cl_sidespeed
 *           with a..d from KeyState (0, 0.25, 0.5, 0.75, 1); +speed, ducking and ScaleMovements
 *           (the clamp to maxspeed) scale both by the same factor. So |side / forward| always
 *           belongs to a small set of ratios. Cheats rotate the move vector after changing the
 *           angles (insomnia FixMove, pizzahook autostrafe, sega Correct_Movement) and get any
 *           ratio. Counted on cmds where both are non-zero. Joystick, +strafe with the mouse
 *           and cl_mouselook 0 also give other ratios; joystick 1 clients are skipped.
 *
 * SnapBack  The view jumps by >= SNAP_MIN degrees for exactly one cmd and the next cmd is back
 *           within SNAP_RETURN of where it was. A hand can't flick and return within one tick;
 *           silent aim (aim only on the shot cmd) and anti-aim jitter do exactly that.
 *           With +attack on the jump cmd it is counted as a silent shot, otherwise as jitter.
 *
 * FakeLag   Usercmds that arrive in the same server tick form a batch. A client that holds
 *           bSendPacket false (insomnia/pizzahook fakelag, sega Minimum/Maximum_Choked_Commands)
 *           delivers 8..15 cmds at once several times a second; a jitter or lag spike does that
 *           now and then. Only counted while the client's incoming loss is low.
 *
 * Roll      A client never puts roll into its view angles. pizzahook moves the spread
 *           compensation into viewangles.z with values below the +-30 smac_eyetest allows.
 *
 * Window thresholds (notice when reached):
 *   MoveGrid  >= 40 off-grid cmds and at least half of the cmds with both move axes
 *   SnapBack  >= 3 silent shots, or >= 20 jitter snaps
 *   FakeLag   >= 30 batches of >= 8 cmds
 *   Roll      >= 10 cmds with |roll| > 0.01
 */

public Plugin:myinfo =
{
	name = "SMAC: Usercmd diagnostics",
	author = SMAC_AUTHOR,
	description = "MoveGrid, SnapBack, FakeLag and Roll checks: admin notices and logs, no punishment",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define RATIO_TOLERANCE		0.003	/* relative */
#define MAX_RATIOS			128
#define SNAP_MIN			2.0
#define SNAP_RETURN			0.1
#define SUMMARY_PERIOD		300.0
#define WINDOW				30.0
#define BATCH_BIG			8
#define BATCH_MAX_LOSS		0.02
#define ROLL_EPS			0.01

#define WIN_OFFGRID			40
#define WIN_SILENT			3
#define WIN_JITTER			20
#define WIN_FAKELAG			30
#define WIN_ROLL			10

enum {
	Win_Move2 = 0,
	Win_OffGrid,
	Win_Silent,
	Win_Jitter,
	Win_Batch,
	Win_Roll,
	Win_Count
};

new Handle:g_hCvarEnable = INVALID_HANDLE;
new Handle:g_hCvarSamples = INVALID_HANDLE;
new Handle:g_hCvarNotify = INVALID_HANDLE;
new String:g_sLog[PLATFORM_MAX_PATH];

new const String:g_sSpeedCvars[][] = { "cl_forwardspeed", "cl_backspeed", "cl_sidespeed", "joystick" };

/* Client move speeds; MoveGrid starts once all of them are known. */
new Float:g_fSpeed[MAXPLAYERS+1][3];
new g_iKnown[MAXPLAYERS+1];
new bool:g_bJoystick[MAXPLAYERS+1];
new Float:g_fRatios[MAXPLAYERS+1][MAX_RATIOS];
new g_iRatios[MAXPLAYERS+1];

/* SnapBack history: [0] = two cmds ago, [1] = previous cmd. */
new Float:g_fAng[MAXPLAYERS+1][2][2];
new g_iHist[MAXPLAYERS+1];
new g_iPrevCmd[MAXPLAYERS+1];
new bool:g_bPrevAttack[MAXPLAYERS+1];

/* Statistics since the last summary. */
new g_iCmds[MAXPLAYERS+1];
new g_iMove2[MAXPLAYERS+1];
new g_iOffGrid[MAXPLAYERS+1];
new g_iSilent[MAXPLAYERS+1];
new g_iJitter[MAXPLAYERS+1];
new g_iBigBatches[MAXPLAYERS+1];
new g_iRoll[MAXPLAYERS+1];
new g_iSamples[MAXPLAYERS+1];

/* FakeLag: the current batch. */
new g_iBatchTick[MAXPLAYERS+1];
new g_iBatchSize[MAXPLAYERS+1];

/* Counters of the current notice window. */
new g_iWin[MAXPLAYERS+1][Win_Count];

public OnPluginStart()
{
	g_hCvarEnable = CreateConVar("smac_usercmd_diag", "1", "Usercmd checks (MoveGrid, SnapBack, FakeLag, Roll): 0 = off, 1 = on (log to logs/smac_usercmd_diag.log)", _, true, 0.0, true, 1.0);
	g_hCvarSamples = CreateConVar("smac_usercmd_diag_samples", "20", "Raw samples logged per player and map.", _, true, 0.0, true, 1000.0);
	g_hCvarNotify = CreateConVar("smac_usercmd_notify", "1", "Notify admins (and log) when a check crosses its 30 s threshold: 0 = off, 1 = on. Nothing is punished.", _, true, 0.0, true, 1.0);

	LoadTranslations("smac.phrases");
	CreateTimer(WINDOW, Timer_Window, _, TIMER_REPEAT);

	BuildPath(Path_SM, g_sLog, sizeof(g_sLog), "logs/smac_usercmd_diag.log");

	RegAdminCmd("sm_usercmd_diag", Command_Diag, ADMFLAG_GENERIC, "Print the usercmd diagnostics of every player.");
	CreateTimer(SUMMARY_PERIOD, Timer_Summary, _, TIMER_REPEAT);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
}

public OnMapStart()
{
	for (new i = 1; i <= MaxClients; i++)
		g_iSamples[i] = 0;
}

public OnClientPutInServer(client)
{
	g_iKnown[client] = 0;
	g_bJoystick[client] = false;
	g_iRatios[client] = 0;
	g_iHist[client] = 0;
	g_iPrevCmd[client] = 0;
	g_iBatchTick[client] = -1;
	g_iBatchSize[client] = 0;
	ResetStats(client);
	ResetWindow(client);
	g_iSamples[client] = 0;

	if (IsFakeClient(client))
		return;

	for (new i = 0; i < sizeof(g_sSpeedCvars); i++)
		QueryClientConVar(client, g_sSpeedCvars[i], Query_Speed, (GetClientUserId(client) << 2) | i);
}

public OnClientDisconnect(client)
{
	if (IsClientInGame(client) && !IsFakeClient(client) && g_iCmds[client] > 0)
		WriteSummary(client, "disconnect");
}

ResetStats(client)
{
	g_iCmds[client] = 0;
	g_iMove2[client] = 0;
	g_iOffGrid[client] = 0;
	g_iSilent[client] = 0;
	g_iJitter[client] = 0;
	g_iBigBatches[client] = 0;
	g_iRoll[client] = 0;
}

ResetWindow(client)
{
	for (new i = 0; i < Win_Count; i++)
		g_iWin[client][i] = 0;
}

public Query_Speed(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[], any:data)
{
	if (GetClientOfUserId(data >> 2) != client)
		return;

	/* Every answer counts: a missing speed leaves 0 and MoveGrid stays off for this client. */
	new idx = data & 3;
	if (idx == 3)
		g_bJoystick[client] = (result == ConVarQuery_Okay && StringToInt(cvarValue) != 0);
	else
		g_fSpeed[client][idx] = (result == ConVarQuery_Okay) ? StringToFloat(cvarValue) : 0.0;

	if (++g_iKnown[client] == sizeof(g_sSpeedCvars))
		BuildRatios(client);
}

/*
 * All |side / forward| a keyboard can produce:
 *   forward in { |a * fwd - b * back| }, side in { |c - d| * side }, a..d in {0, .25, .5, .75, 1}.
 */
BuildRatios(client)
{
	new Float:fFwd = g_fSpeed[client][0], Float:fBack = g_fSpeed[client][1], Float:fSide = g_fSpeed[client][2];
	g_iRatios[client] = 0;

	if (fFwd <= 0.0 || fBack <= 0.0 || fSide <= 0.0)
		return;

	for (new a = 0; a <= 4; a++)
	{
		for (new b = 0; b <= 4; b++)
		{
			new Float:fMove = FloatAbs(float(a) * 0.25 * fFwd - float(b) * 0.25 * fBack);
			if (fMove < 0.01)
				continue;

			for (new c = 1; c <= 4; c++)
				AddRatio(client, float(c) * 0.25 * fSide / fMove);
		}
	}
}

AddRatio(client, Float:fRatio)
{
	for (new i = 0; i < g_iRatios[client]; i++)
	{
		if (FloatAbs(g_fRatios[client][i] - fRatio) <= fRatio * RATIO_TOLERANCE * 0.1)
			return;
	}

	if (g_iRatios[client] < MAX_RATIOS)
		g_fRatios[client][g_iRatios[client]++] = fRatio;
}

bool:IsOnGrid(client, Float:fRatio)
{
	for (new i = 0; i < g_iRatios[client]; i++)
	{
		if (FloatAbs(g_fRatios[client][i] - fRatio) <= g_fRatios[client][i] * RATIO_TOLERANCE)
			return true;
	}
	return false;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum)
{
	if (!GetConVarBool(g_hCvarEnable) || IsFakeClient(client) || cmdnum <= 0)
		return Plugin_Continue;

	if (!IsPlayerAlive(client) || (GetEntityFlags(client) & (FL_FROZEN|FL_ATCONTROLS)))
	{
		g_iHist[client] = 0;
		return Plugin_Continue;
	}

	g_iCmds[client]++;

	CheckBatch(client);
	CheckMoveGrid(client, vel, angles, cmdnum);
	CheckSnapBack(client, buttons, angles, cmdnum);
	CheckRoll(client, angles, cmdnum);

	return Plugin_Continue;
}

CheckMoveGrid(client, const Float:vel[3], const Float:angles[3], cmdnum)
{
	if (g_bJoystick[client] || g_iRatios[client] == 0 || vel[0] == 0.0 || vel[1] == 0.0)
		return;

	g_iMove2[client]++;
	g_iWin[client][Win_Move2]++;

	new Float:fRatio = FloatAbs(vel[1] / vel[0]);
	if (IsOnGrid(client, fRatio))
		return;

	g_iOffGrid[client]++;
	g_iWin[client][Win_OffGrid]++;

	if (g_iSamples[client] < GetConVarInt(g_hCvarSamples))
	{
		g_iSamples[client]++;
		LogToFileEx(g_sLog, "%L MoveGrid sample: cmd %d | forward %.3f side %.3f (ratio %.4f) | angles %.2f %.2f | speeds %.0f/%.0f/%.0f",
			client, cmdnum, vel[0], vel[1], fRatio, angles[0], angles[1],
			g_fSpeed[client][0], g_fSpeed[client][1], g_fSpeed[client][2]);
	}
}

CheckSnapBack(client, buttons, const Float:angles[3], cmdnum)
{
	/* Lost cmds would look like a jump: start over after a gap. */
	if (cmdnum != g_iPrevCmd[client] + 1)
		g_iHist[client] = 0;
	g_iPrevCmd[client] = cmdnum;

	if (g_iHist[client] >= 2)
	{
		new Float:fJump = AngleDist(g_fAng[client][0], g_fAng[client][1]);
		new Float:fBack = AngleDist(g_fAng[client][0], angles);

		if (fJump >= SNAP_MIN && fBack <= SNAP_RETURN)
		{
			new bool:bShot = g_bPrevAttack[client];
			if (bShot)
			{
				g_iSilent[client]++;
				g_iWin[client][Win_Silent]++;
			}
			else
			{
				g_iJitter[client]++;
				g_iWin[client][Win_Jitter]++;
			}

			if (g_iSamples[client] < GetConVarInt(g_hCvarSamples))
			{
				g_iSamples[client]++;
				LogToFileEx(g_sLog, "%L SnapBack sample (%s): cmd %d | %.2f %.2f -> %.2f %.2f -> %.2f %.2f | jump %.2f, back %.3f",
					client, bShot ? "silent shot" : "jitter", cmdnum,
					g_fAng[client][0][0], g_fAng[client][0][1], g_fAng[client][1][0], g_fAng[client][1][1],
					angles[0], angles[1], fJump, fBack);
			}
		}
	}

	g_fAng[client][0][0] = g_fAng[client][1][0];
	g_fAng[client][0][1] = g_fAng[client][1][1];
	g_fAng[client][1][0] = angles[0];
	g_fAng[client][1][1] = angles[1];
	g_bPrevAttack[client] = (buttons & IN_ATTACK) != 0;

	if (g_iHist[client] < 2)
		g_iHist[client]++;
}

/* Cmds processed in the same server tick came in one burst. */
CheckBatch(client)
{
	new tick = GetGameTickCount();
	if (tick == g_iBatchTick[client])
	{
		g_iBatchSize[client]++;
		return;
	}

	if (g_iBatchSize[client] >= BATCH_BIG && GetClientAvgLoss(client, NetFlow_Incoming) <= BATCH_MAX_LOSS)
	{
		g_iBigBatches[client]++;
		g_iWin[client][Win_Batch]++;
	}

	g_iBatchTick[client] = tick;
	g_iBatchSize[client] = 1;
}

CheckRoll(client, const Float:angles[3], cmdnum)
{
	if (FloatAbs(angles[2]) <= ROLL_EPS)
		return;

	g_iRoll[client]++;
	g_iWin[client][Win_Roll]++;

	if (g_iSamples[client] < GetConVarInt(g_hCvarSamples))
	{
		g_iSamples[client]++;
		LogToFileEx(g_sLog, "%L Roll sample: cmd %d | angles %.3f %.3f %.3f", client, cmdnum, angles[0], angles[1], angles[2]);
	}
}

/* Largest per-axis difference, yaw wrapped to +-180. */
Float:AngleDist(const Float:a[], const Float:b[])
{
	new Float:fPitch = FloatAbs(a[0] - b[0]);
	new Float:fYaw = FloatAbs(a[1] - b[1]);

	if (fYaw > 360.0)
		fYaw -= 360.0 * float(RoundToFloor(fYaw / 360.0));
	if (fYaw > 180.0)
		fYaw = 360.0 - fYaw;

	return (fPitch > fYaw) ? fPitch : fYaw;
}

public Action:Timer_Summary(Handle:timer)
{
	if (!GetConVarBool(g_hCvarEnable))
		return Plugin_Continue;

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && g_iCmds[i] > 0)
		{
			WriteSummary(i, "periodic");
			ResetStats(i);
		}
	}
	return Plugin_Continue;
}

WriteSummary(client, const String:reason[])
{
	LogToFileEx(g_sLog, "%L summary (%s): cmds %d | MoveGrid off-grid %d of %d (%.1f%%)%s | SnapBack silent shots %d, jitter %d | FakeLag big batches %d | Roll cmds %d",
		client, reason, g_iCmds[client],
		g_iOffGrid[client], g_iMove2[client], Percent(g_iOffGrid[client], g_iMove2[client]),
		g_bJoystick[client] ? " [joystick, skipped]" : (g_iRatios[client] == 0 ? " [speeds unknown]" : ""),
		g_iSilent[client], g_iJitter[client], g_iBigBatches[client], g_iRoll[client]);
}

/**
 * Admin notices: each check at most once per window.
 */
public Action:Timer_Window(Handle:timer)
{
	new bool:bNotify = GetConVarBool(g_hCvarEnable) && GetConVarBool(g_hCvarNotify);
	decl String:sDetail[128];

	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if (bNotify)
		{
			if (g_iWin[i][Win_OffGrid] >= WIN_OFFGRID && g_iWin[i][Win_OffGrid] * 2 >= g_iWin[i][Win_Move2])
			{
				FormatEx(sDetail, sizeof(sDetail), "%d of %d moving cmds off the keyboard grid in %.0f s", g_iWin[i][Win_OffGrid], g_iWin[i][Win_Move2], WINDOW);
				Notice(i, "MoveGrid (FixMove/autostrafe)", g_iWin[i][Win_OffGrid], sDetail);
			}
			if (g_iWin[i][Win_Silent] >= WIN_SILENT)
			{
				FormatEx(sDetail, sizeof(sDetail), "%d one-cmd snaps on +attack in %.0f s", g_iWin[i][Win_Silent], WINDOW);
				Notice(i, "SnapBack (silent aim)", g_iWin[i][Win_Silent], sDetail);
			}
			if (g_iWin[i][Win_Jitter] >= WIN_JITTER)
			{
				FormatEx(sDetail, sizeof(sDetail), "%d one-cmd snaps without +attack in %.0f s", g_iWin[i][Win_Jitter], WINDOW);
				Notice(i, "SnapBack (anti-aim jitter)", g_iWin[i][Win_Jitter], sDetail);
			}
			if (g_iWin[i][Win_Batch] >= WIN_FAKELAG)
			{
				FormatEx(sDetail, sizeof(sDetail), "%d bursts of >= %d cmds in %.0f s, loss %.1f%%", g_iWin[i][Win_Batch], BATCH_BIG, WINDOW, GetClientAvgLoss(i, NetFlow_Incoming) * 100.0);
				Notice(i, "FakeLag", g_iWin[i][Win_Batch], sDetail);
			}
			if (g_iWin[i][Win_Roll] >= WIN_ROLL)
			{
				FormatEx(sDetail, sizeof(sDetail), "%d cmds with roll in %.0f s", g_iWin[i][Win_Roll], WINDOW);
				Notice(i, "Roll (nospread)", g_iWin[i][Win_Roll], sDetail);
			}
		}

		ResetWindow(i);
	}
	return Plugin_Continue;
}

Notice(client, const String:name[], count, const String:detail[])
{
	new Handle:info = CreateKeyValues("");
	KvSetString(info, "check", name);
	KvSetString(info, "detail", detail);
	new Action:result = SMAC_CheatDetected(client, Detection_Usercmd, info);
	CloseHandle(info);

	if (result != Plugin_Continue)
		return;

	SMAC_LogAction(client, "%s | %s", name, detail);
	SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, name, count);
	LogToFileEx(g_sLog, "%L NOTICE %s | %s", client, name, detail);
}

Float:Percent(part, total)
{
	return (total > 0) ? 100.0 * float(part) / float(total) : 0.0;
}

public Action:Command_Diag(client, args)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		ReplyToCommand(client, "%N: cmds %d | off-grid %d/%d (%.1f%%) | silent %d, jitter %d | big batches %d | roll %d",
			i, g_iCmds[i], g_iOffGrid[i], g_iMove2[i], Percent(g_iOffGrid[i], g_iMove2[i]),
			g_iSilent[i], g_iJitter[i], g_iBigBatches[i], g_iRoll[i]);
	}
	return Plugin_Handled;
}
