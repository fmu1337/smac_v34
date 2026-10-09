#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC Ultr@ R52 No Recoil A/B: diagnostics only. Nothing is punished.
 *
 * R52 compares the angles of the usercmd with m_angEyeAngles read in the OnPlayerRunCmd pre-hook.
 * If m_angEyeAngles there always equals the previous cmd's angles, R52's No Recoil A would fire on
 * every spray with mouse movement. This plugin measures that on a live server and replays the R52
 * logic exactly, writing what R52 would have done to logs/smac_norecoil_diag.log.
 *
 * R52 (docs/R52_SPEC.md §6a, decode branch):
 *   on a shot (FireBullets TE): A keeps the cmd angles; B is armed (state 1, max 0).
 *   +attack held:
 *     A: cmd angles != eye angles and the kept angles == eye angles on an axis -> counter + 1,
 *        kept := cmd angles; cmd angles == eye angles -> counter 0. A counter of 1..50 becomes a
 *        deadline tickcount + 7 that drops by 1 per cmd; tickcount reaching it -> 1101.
 *     B: pitch changed and cmd pitch != eye pitch -> state + 1 and the max |dPitch| is tracked;
 *        otherwise (pitch unchanged, or equal to eye pitch) -> state 0.
 *   +attack released: A counter > 0 -> 1101. B state > 0, pitch changed, != eye pitch, state + 1 > 1
 *     and |dPitch| >= 1.1 and > 1.5 * max -> 1102. B state 0.
 *   1101 / 1102 -> 1..3 s later counter42 + 1; more than |smac_NoR_Ban| (5) -> punish, else it
 *   decays in 300 s.
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: No Recoil diagnostics",
	author = SMAC_AUTHOR,
	description = "Measures m_angEyeAngles vs usercmd angles and replays R52 No Recoil A/B without punishing",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define A_LIMIT			50
#define A_DEADLINE		7
#define B_MIN_STEP		1.1
#define B_FACTOR		1.5
#define FINAL_DECAY		300.0
#define SUMMARY_PERIOD	300.0

new Handle:g_hCvarEnable = INVALID_HANDLE;
new Handle:g_hCvarSamples = INVALID_HANDLE;
new Handle:g_hCvarNoRBan = INVALID_HANDLE;
new String:g_sLog[PLATFORM_MAX_PATH];

new bool:g_bHasPrev[MAXPLAYERS+1];
new Float:g_fAng[MAXPLAYERS+1][2][2];		/* [0] = previous cmd, [1] = this cmd */
new g_iPrevButtons[MAXPLAYERS+1];

/* R52 state: g590bc[6..8], g59b0c[3], g59b0c[4], cnt[42]. */
new Float:g_fKept[MAXPLAYERS+1][2];
new g_iA[MAXPLAYERS+1];
new g_iB[MAXPLAYERS+1];
new Float:g_fBMax[MAXPLAYERS+1];
new g_iFinal[MAXPLAYERS+1];

/* Statistics. */
new g_iCmds[MAXPLAYERS+1];
new g_iEyeNotPrev[MAXPLAYERS+1];		/* eye angles != previous cmd angles */
new g_iEyeIsCur[MAXPLAYERS+1];			/* eye angles == this cmd angles while the aim moved */
new g_iHeldMoving[MAXPLAYERS+1];		/* cmds with +attack held and the aim moving */
new g_iShots[MAXPLAYERS+1];
new g_i1101[MAXPLAYERS+1];
new g_i1102[MAXPLAYERS+1];
new g_iPunish[MAXPLAYERS+1];
new g_iSamples[MAXPLAYERS+1];

public OnPluginStart()
{
	g_hCvarEnable = CreateConVar("smac_norecoil_diag", "1", "R52 No Recoil diagnostics: 0 = off, 1 = log to logs/smac_norecoil_diag.log", _, true, 0.0, true, 1.0);
	g_hCvarSamples = CreateConVar("smac_norecoil_diag_samples", "20", "Raw angle samples logged per player and map when eye angles differ from the previous cmd.", _, true, 0.0, true, 1000.0);
	g_hCvarNoRBan = CreateConVar("smac_norecoil_diag_ban", "5", "|smac_NoR_Ban| used for the replay (R52 default 5).", _, true, 1.0, true, 100.0);

	BuildPath(Path_SM, g_sLog, sizeof(g_sLog), "logs/smac_norecoil_diag.log");

	AddTempEntHook("Shotgun Shot", TE_FireBullets);
	RegAdminCmd("sm_norecoil_diag", Command_Diag, ADMFLAG_GENERIC, "Print the No Recoil diagnostics of every player.");
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
	g_bHasPrev[client] = false;
	g_iPrevButtons[client] = 0;
	g_fKept[client][0] = g_fKept[client][1] = 0.0;
	g_iA[client] = 0;
	g_iB[client] = 0;
	g_fBMax[client] = 0.0;
	g_iFinal[client] = -1;

	g_iCmds[client] = 0;
	g_iEyeNotPrev[client] = 0;
	g_iEyeIsCur[client] = 0;
	g_iHeldMoving[client] = 0;
	g_iShots[client] = 0;
	g_i1101[client] = 0;
	g_i1102[client] = 0;
	g_iPunish[client] = 0;
	g_iSamples[client] = 0;
}

public OnClientDisconnect(client)
{
	if (IsClientInGame(client) && !IsFakeClient(client) && g_iCmds[client] > 0)
		WriteSummary(client, "disconnect");
}

public Action:TE_FireBullets(const String:te_name[], const clients[], numClients, Float:delay)
{
	new client = TE_ReadNum("m_iPlayer") + 1;
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !g_bHasPrev[client])
		return Plugin_Continue;

	g_iShots[client]++;

	/* A keeps the angles of the shot cmd; B is armed. */
	g_fKept[client][0] = g_fAng[client][1][0];
	g_fKept[client][1] = g_fAng[client][1][1];
	g_iB[client] = 1;
	g_fBMax[client] = 0.0;
	return Plugin_Continue;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!GetConVarBool(g_hCvarEnable) || IsFakeClient(client) || !IsPlayerAlive(client))
	{
		g_bHasPrev[client] = false;
		return Plugin_Continue;
	}

	g_fAng[client][0][0] = g_fAng[client][1][0];
	g_fAng[client][0][1] = g_fAng[client][1][1];
	g_fAng[client][1][0] = angles[0];
	g_fAng[client][1][1] = angles[1];

	if (!g_bHasPrev[client])
	{
		g_bHasPrev[client] = true;
		g_iPrevButtons[client] = buttons;
		return Plugin_Continue;
	}

	new Float:eye0 = GetEntPropFloat(client, Prop_Send, "m_angEyeAngles[0]");
	new Float:eye1 = GetEntPropFloat(client, Prop_Send, "m_angEyeAngles[1]");
	new bool:bMoved = (angles[0] != g_fAng[client][0][0] || angles[1] != g_fAng[client][0][1]);

	/* The question: does the pre-hook see the previous cmd's angles in m_angEyeAngles? */
	g_iCmds[client]++;
	if (eye0 != g_fAng[client][0][0] || eye1 != g_fAng[client][0][1])
	{
		g_iEyeNotPrev[client]++;
		if (g_iSamples[client] < GetConVarInt(g_hCvarSamples))
		{
			g_iSamples[client]++;
			LogToFileEx(g_sLog, "%L sample: cmd %d tick %d | prev cmd %.4f %.4f | this cmd %.4f %.4f | eye %.4f %.4f | buttons %d",
				client, cmdnum, tickcount, g_fAng[client][0][0], g_fAng[client][0][1], angles[0], angles[1], eye0, eye1, buttons);
		}
	}
	if (bMoved && eye0 == angles[0] && eye1 == angles[1])
		g_iEyeIsCur[client]++;

	new prev = g_iPrevButtons[client];
	if ((buttons & IN_ATTACK) && (prev & IN_ATTACK))
	{
		if (bMoved)
			g_iHeldMoving[client]++;
		HoldA(client, angles, eye0, eye1, tickcount);
		HoldB(client, angles, eye0);
	}
	else if (!(buttons & IN_ATTACK))
	{
		if (g_iA[client] > 0)
		{
			g_iA[client] = 0;
			Fire(client, 1101, "release with A counter > 0");
		}
		ReleaseB(client, angles, eye0);
	}

	g_iPrevButtons[client] = buttons;
	return Plugin_Continue;
}

HoldA(client, const Float:angles[3], Float:eye0, Float:eye1, tickcount)
{
	if (g_fKept[client][0] != 0.0 && g_fKept[client][1] != 0.0)
	{
		if (angles[0] != eye0 || angles[1] != eye1)
		{
			if (g_fKept[client][0] == eye0 || g_fKept[client][1] == eye1)
				g_iA[client]++;
			else
				g_iA[client] = 0;

			g_fKept[client][0] = angles[0];
			g_fKept[client][1] = angles[1];
		}
		else
		{
			g_iA[client] = 0;
			g_fKept[client][0] = g_fKept[client][1] = 0.0;
		}
	}

	if (g_iA[client] <= 0)
		return;

	if (tickcount >= g_iA[client] && g_iA[client] > A_LIMIT)
	{
		g_iA[client] = 0;
		Fire(client, 1101, "aim moved on every held cmd until the deadline");
	}
	else if (g_iA[client] <= A_LIMIT)
	{
		g_iA[client] = tickcount + A_DEADLINE;
	}
	else
	{
		g_iA[client]--;
	}
}

HoldB(client, const Float:angles[3], Float:eye0)
{
	if (g_iB[client] <= 0)
		return;

	/* R52: an unchanged pitch while held disarms B as well. */
	if (angles[0] != g_fAng[client][0][0] && angles[0] != eye0)
	{
		g_iB[client]++;
		new Float:dp = PitchStep(client);
		if (dp > g_fBMax[client])
			g_fBMax[client] = dp;
	}
	else
	{
		g_iB[client] = 0;
	}
}

ReleaseB(client, const Float:angles[3], Float:eye0)
{
	if (g_iB[client] <= 0)
		return;

	if (angles[0] != g_fAng[client][0][0] && angles[0] != eye0 && ++g_iB[client] > 1)
	{
		new Float:dp = PitchStep(client);
		if (dp >= B_MIN_STEP && dp > B_FACTOR * g_fBMax[client])
		{
			decl String:sDetail[96];
			FormatEx(sDetail, sizeof(sDetail), "pitch step %.3f on release, max while held %.3f", dp, g_fBMax[client]);
			Fire(client, 1102, sDetail);
		}
	}
	g_iB[client] = 0;
}

Float:PitchStep(client)
{
	return FloatAbs(NormalizeAngle(g_fAng[client][0][0]) - NormalizeAngle(g_fAng[client][1][0]));
}

/* R52 SetBan(1101/1102, 1..3 s) -> OnBanReleased: counter42 + 1. */
Fire(client, code, const String:detail[])
{
	if (code == 1101)
		g_i1101[client]++;
	else
		g_i1102[client]++;

	decl String:sWeapon[32];
	GetClientWeapon(client, sWeapon, sizeof(sWeapon));
	LogToFileEx(g_sLog, "%L R52 would arm %d (%s) | weapon %s", client, code, detail, sWeapon);

	new Handle:pack;
	CreateDataTimer(float(GetRandomInt(1, 3)), Timer_Final, pack, TIMER_FLAG_NO_MAPCHANGE);
	WritePackCell(pack, GetClientUserId(client));
	WritePackCell(pack, code);
}

public Action:Timer_Final(Handle:timer, Handle:pack)
{
	ResetPack(pack);
	new client = GetClientOfUserId(ReadPackCell(pack));
	new code = ReadPackCell(pack);
	if (!IS_CLIENT(client) || !IsClientInGame(client))
		return Plugin_Stop;

	new limit = GetConVarInt(g_hCvarNoRBan);
	if (++g_iFinal[client] > limit)
	{
		g_iFinal[client] = -1;
		g_iPunish[client]++;
		LogToFileEx(g_sLog, "%L R52 WOULD PUNISH for No Recoil (last %d, counter over %d)", client, code, limit);
		return Plugin_Stop;
	}

	CreateTimer(FINAL_DECAY, Timer_FinalDecay, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

public Action:Timer_FinalDecay(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (IS_CLIENT(client) && IsClientInGame(client) && g_iFinal[client] > -1)
		g_iFinal[client]--;
	return Plugin_Stop;
}

public Action:Timer_Summary(Handle:timer)
{
	if (!GetConVarBool(g_hCvarEnable))
		return Plugin_Continue;

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && g_iCmds[i] > 0)
			WriteSummary(i, "periodic");
	}
	return Plugin_Continue;
}

public Action:Command_Diag(client, args)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i) || g_iCmds[i] == 0)
			continue;

		ReplyToCommand(client, "%N: cmds %d, eye!=prev %d (%.2f%%), eye==this %d, held+moving %d, shots %d, 1101 %d, 1102 %d, punish %d",
			i, g_iCmds[i], g_iEyeNotPrev[i], 100.0 * float(g_iEyeNotPrev[i]) / float(g_iCmds[i]),
			g_iEyeIsCur[i], g_iHeldMoving[i], g_iShots[i], g_i1101[i], g_i1102[i], g_iPunish[i]);
	}
	return Plugin_Handled;
}

WriteSummary(client, const String:reason[])
{
	LogToFileEx(g_sLog, "%L summary (%s): cmds %d, eye!=prev %d (%.2f%%), eye==this %d, held+moving %d, shots %d, would arm 1101 %d, 1102 %d, would punish %d",
		client, reason, g_iCmds[client], g_iEyeNotPrev[client], 100.0 * float(g_iEyeNotPrev[client]) / float(g_iCmds[client]),
		g_iEyeIsCur[client], g_iHeldMoving[client], g_iShots[client], g_i1101[client], g_i1102[client], g_iPunish[client]);
}

Float:NormalizeAngle(Float:angle)
{
	if (angle > 180.0)
		angle -= 360.0;
	return angle;
}
