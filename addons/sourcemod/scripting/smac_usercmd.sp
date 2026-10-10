#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * Usercmd consistency: diagnostics only. Nothing is punished.
 * Everything goes to logs/smac_usercmd_diag.log so thresholds can be chosen from real players.
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
 */

public Plugin:myinfo =
{
	name = "SMAC: Usercmd diagnostics",
	author = SMAC_AUTHOR,
	description = "Logs off-grid movement (FixMove / autostrafe) and one-cmd view snaps (silent aim) without punishing",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define RATIO_TOLERANCE		0.003	/* relative */
#define MAX_RATIOS			128
#define SNAP_MIN			2.0
#define SNAP_RETURN			0.1
#define SUMMARY_PERIOD		300.0

new Handle:g_hCvarEnable = INVALID_HANDLE;
new Handle:g_hCvarSamples = INVALID_HANDLE;
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
new g_iSamples[MAXPLAYERS+1];

public OnPluginStart()
{
	g_hCvarEnable = CreateConVar("smac_usercmd_diag", "1", "Usercmd diagnostics (MoveGrid, SnapBack): 0 = off, 1 = log to logs/smac_usercmd_diag.log", _, true, 0.0, true, 1.0);
	g_hCvarSamples = CreateConVar("smac_usercmd_diag_samples", "20", "Raw samples logged per player and map.", _, true, 0.0, true, 1000.0);

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
	ResetStats(client);
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
}

public Query_Speed(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[], any:data)
{
	if (GetClientOfUserId(data >> 2) != client || result != ConVarQuery_Okay)
		return;

	new idx = data & 3;
	if (idx == 3)
		g_bJoystick[client] = (StringToInt(cvarValue) != 0);
	else
		g_fSpeed[client][idx] = StringToFloat(cvarValue);

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

	CheckMoveGrid(client, vel, angles, cmdnum);
	CheckSnapBack(client, buttons, angles, cmdnum);

	return Plugin_Continue;
}

CheckMoveGrid(client, const Float:vel[3], const Float:angles[3], cmdnum)
{
	if (g_bJoystick[client] || g_iRatios[client] == 0 || vel[0] == 0.0 || vel[1] == 0.0)
		return;

	g_iMove2[client]++;

	new Float:fRatio = FloatAbs(vel[1] / vel[0]);
	if (IsOnGrid(client, fRatio))
		return;

	g_iOffGrid[client]++;

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
				g_iSilent[client]++;
			else
				g_iJitter[client]++;

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
	LogToFileEx(g_sLog, "%L summary (%s): cmds %d | MoveGrid off-grid %d of %d (%.1f%%)%s | SnapBack silent shots %d, jitter %d",
		client, reason, g_iCmds[client],
		g_iOffGrid[client], g_iMove2[client], Percent(g_iOffGrid[client], g_iMove2[client]),
		g_bJoystick[client] ? " [joystick, skipped]" : (g_iRatios[client] == 0 ? " [speeds unknown]" : ""),
		g_iSilent[client], g_iJitter[client]);
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

		ReplyToCommand(client, "%N: cmds %d | off-grid %d/%d (%.1f%%) | silent %d, jitter %d",
			i, g_iCmds[i], g_iOffGrid[i], g_iMove2[i], Percent(g_iOffGrid[i], g_iMove2[i]),
			g_iSilent[i], g_iJitter[i]);
	}
	return Plugin_Handled;
}
