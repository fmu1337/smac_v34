#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smac>

public Plugin:myinfo =
{
	name = "SMAC: Eye Angle Test",
	author = SMAC_AUTHOR,
	description = "Detects eye angle violations used in cheats",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define EYE_MAX_PITCH	89.9
#define EYE_MAX_ROLL	30.0
#define EYE_MAX_YAW		100000.0
#define EYE_ZERO_STREAK	16
#define EYE_DECAY		528.0
#define EYE_PAUSE		5.0

#define SEED_SKIP_MIN_DELTA		16
#define SEED_SKIP_DETECT_BAN	3

#define ET_CMDNUM		0
#define ET_TICKCOUNT	1
#define ET_BUTTONS		2
#define ET_ANGLES		3
#define ET_ZERO			4
#define ET_LISP			5
#define ET_COUNT		6

new const String:g_sCheck[ET_COUNT][] =
{
	"Eye Test Violation => UserCmdReuse",
	"Eye Test Violation => UserCmdTamperingTickcount",
	"Eye Test Violation => UserCmdTamperingButtons",
	"Eye Test Violation => Eye Angle",
	"Eye Test Violation => Zero Angles",
	"Eye Test Violation => Lisp Yaw"
};

new const DetectionType:g_iDetection[ET_COUNT] =
{
	Detection_UserCmdReuse,
	Detection_UserCmdTamperingTickcount,
	Detection_UserCmdTamperingButtons,
	Detection_Eyeangles,
	Detection_Eyeangles,
	Detection_Eyeangles
};

enum ResetStatus {
	State_Okay = 0,
	State_Resetting,
	State_Reset
};

new Handle:g_hCvarBan = INVALID_HANDLE;
new Handle:g_hCvarReaction = INVALID_HANDLE;
new Handle:g_hCvarNewReaction = INVALID_HANDLE;
new Handle:g_hCvarNoSpread = INVALID_HANDLE;
new Handle:g_hCvarSeedBan = INVALID_HANDLE;
new g_iPauseCmds;

new g_iPauseUntilCmd[MAXPLAYERS+1];
new g_iViolations[MAXPLAYERS+1][ET_COUNT];
new bool:g_bPrevAlive[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1] = {-1, ...};
new g_iPrevCmdNum[MAXPLAYERS+1] = {-1, ...};
new g_iPrevTickCount[MAXPLAYERS+1] = {-1, ...};
new g_iCmdNumOffset[MAXPLAYERS+1] = {1, ...};
new ResetStatus:g_TickStatus[MAXPLAYERS+1];
new g_iSeedSkipDetections[MAXPLAYERS+1];
new g_iZeroStreak[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarReaction = SMAC_CreateConVar("smac_eyetest_reaction", "3", "Eyetest 01-04: 0=off, 1=notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarNewReaction = SMAC_CreateConVar("smac_eyetest_new_reaction", "1", "Lisp yaw (04L) and zero angles (05): 0=off, 1=notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarNoSpread = SMAC_CreateConVar("smac_NoS_NoR", "1", "New random seed on every +attack (0 = only when cmdnum skips)", _, true, 0.0, true, 1.0);
	g_hCvarBan = SMAC_CreateConVar("smac_eyetest_ban", "1", "Legacy: 0 forces smac_eyetest_reaction to notice only", _, true, 0.0, true, 1.0);
	g_hCvarSeedBan = SMAC_CreateConVar("smac_eyetest_seed_ban", "1", "Ban for nospread seed hunting (cmdnum skips on attack): 0=off, 1=on", _, true, 0.0, true, 1.0);

	g_iPauseCmds = TIME_TO_TICK(EYE_PAUSE);

	for (new i = 1; i <= MaxClients; i++)
	{
		OnClientDisconnect_Post(i);
	}

	RequireFeature(FeatureType_Capability, FEATURECAP_PLAYERRUNCMD_11PARAMS, "This module requires SourceMod 1.5.0 or newer (FEATURECAP_PLAYERRUNCMD_11PARAMS).");
}

public OnClientDisconnect(client)
{

	g_bPrevAlive[client] = false;
	g_iPrevButtons[client] = -1;
	g_iPrevCmdNum[client] = -1;
	g_iPrevTickCount[client] = -1;
	g_iCmdNumOffset[client] = 1;
	g_TickStatus[client] = State_Okay;
	g_iSeedSkipDetections[client] = 0;
	g_iZeroStreak[client] = 0;
}

public OnClientDisconnect_Post(client)
{
	g_iPauseUntilCmd[client] = 0;

	for (new i = 0; i < ET_COUNT; i++)
	{
		g_iViolations[client][i] = -1;
	}
}

public OnClientPutInServer(client)
{
	if (IsClientNew(client))
	{
		OnClientDisconnect_Post(client);
	}
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{

	if (IsFakeClient(client))
		return Plugin_Continue;

	if (cmdnum <= 0)
		return Plugin_Handled;

	if ((buttons & IN_ATTACK) && GetConVarBool(g_hCvarNoSpread))
		seed = GetURandomInt();

	if (tickcount <= 0)
		g_TickStatus[client] = State_Resetting;

	new bool:bAlive = IsPlayerAlive(client);

	if (!bAlive || !g_bPrevAlive[client] || cmdnum <= g_iPauseUntilCmd[client])
	{
		g_bPrevAlive[client] = bAlive;
		g_iPrevButtons[client] = buttons;

		if (g_iPrevCmdNum[client] >= cmdnum)
		{
			if (g_TickStatus[client] == State_Resetting)
				g_TickStatus[client] = State_Reset;

			g_iCmdNumOffset[client]++;
		}
		else
		{
			if (g_TickStatus[client] == State_Reset)
				g_TickStatus[client] = State_Okay;

			g_iPrevCmdNum[client] = cmdnum;
			g_iCmdNumOffset[client] = 1;
		}

		g_iPrevTickCount[client] = tickcount;

		return Plugin_Continue;
	}

	if (g_iPrevCmdNum[client] > cmdnum)
	{
		if (g_TickStatus[client] != State_Okay)
		{
			g_TickStatus[client] = State_Reset;
			return Plugin_Handled;
		}

		g_iPauseUntilCmd[client] = cmdnum + g_iPauseCmds;

		new Handle:info = CreateKeyValues("");
		KvSetNum(info, "cmdnum", cmdnum);
		KvSetNum(info, "prevcmdnum", g_iPrevCmdNum[client]);
		KvSetNum(info, "tickcount", tickcount);
		KvSetNum(info, "prevtickcount", g_iPrevTickCount[client]);
		KvSetNum(info, "gametickcount", GetGameTickCount());

		decl String:sDetail[128];
		FormatEx(sDetail, sizeof(sDetail), "CmdNum: %d PrevCmdNum: %d | [%d:%d:%d]", cmdnum, g_iPrevCmdNum[client], g_iPrevTickCount[client], tickcount, GetGameTickCount());
		Eyetest_Violation(client, ET_CMDNUM, info, sDetail);

		CloseHandle(info);
		return Plugin_Handled;
	}

	if (g_iPrevCmdNum[client] == cmdnum)
	{
		if (g_TickStatus[client] != State_Okay)
		{
			g_TickStatus[client] = State_Reset;
			return Plugin_Handled;
		}

		if (tickcount != g_iPrevTickCount[client] && tickcount != g_iPrevTickCount[client] + 1)
		{
			g_iPauseUntilCmd[client] = cmdnum + g_iPauseCmds;

			new Handle:info = CreateKeyValues("");
			KvSetNum(info, "cmdnum", cmdnum);
			KvSetNum(info, "tickcount", tickcount);
			KvSetNum(info, "prevtickcount", g_iPrevTickCount[client]);
			KvSetNum(info, "gametickcount", GetGameTickCount());

			decl String:sDetail[128];
			FormatEx(sDetail, sizeof(sDetail), "CmdNum: %d | [%d:%d:%d]", cmdnum, g_iPrevTickCount[client], tickcount, GetGameTickCount());
			Eyetest_Violation(client, ET_TICKCOUNT, info, sDetail);

			CloseHandle(info);
			return Plugin_Handled;
		}

		if (((g_iPrevButtons[client] ^ buttons) & (IN_FORWARD|IN_BACK|IN_MOVELEFT|IN_MOVERIGHT|IN_SCORE)))
		{
			g_iPauseUntilCmd[client] = cmdnum + g_iPauseCmds;

			new Handle:info = CreateKeyValues("");
			KvSetNum(info, "cmdnum", cmdnum);
			KvSetNum(info, "prevbuttons", g_iPrevButtons[client]);
			KvSetNum(info, "buttons", buttons);

			decl String:sDetail[128];
			FormatEx(sDetail, sizeof(sDetail), "CmdNum: %d | Buttons: %d -> %d", cmdnum, g_iPrevButtons[client], buttons);
			Eyetest_Violation(client, ET_BUTTONS, info, sDetail);

			CloseHandle(info);
			return Plugin_Handled;
		}

		g_iCmdNumOffset[client]++;
	}
	else
	{
		new iExpected = g_iPrevCmdNum[client] + g_iCmdNumOffset[client];
		new iSkipDelta = cmdnum - iExpected;

		if ((buttons & IN_ATTACK) && iSkipDelta != 0 && g_iPrevCmdNum[client] > 0)
		{
			seed = GetURandomInt();

			if (iSkipDelta >= SEED_SKIP_MIN_DELTA)
			{
				EyeTest_SeedSkipDetected(client, cmdnum, iExpected, iSkipDelta, seed);
			}
		}

		g_iCmdNumOffset[client] = 1;
	}

	g_iPrevButtons[client] = buttons;
	g_iPrevCmdNum[client] = cmdnum;
	g_iPrevTickCount[client] = tickcount;

	if (g_TickStatus[client] == State_Reset)
	{
		g_TickStatus[client] = State_Okay;
	}

	new flags = GetEntityFlags(client);

	if (flags & (FL_FROZEN|FL_ATCONTROLS))
		return Plugin_Continue;

	if (angles[0] == 0.0 && angles[1] == 0.0 && angles[2] == 0.0 && (mouse[0] != 0 || mouse[1] != 0))
	{
		if (++g_iZeroStreak[client] >= EYE_ZERO_STREAK && !IsBotAuth(client))
		{
			g_iZeroStreak[client] = 0;
			g_iPauseUntilCmd[client] = cmdnum + g_iPauseCmds;

			new Handle:zinfo = CreateKeyValues("");
			KvSetNum(zinfo, "streak", EYE_ZERO_STREAK);

			decl String:sZero[128];
			FormatEx(sZero, sizeof(sZero), "Zero Angles: %d cmds, mouse %d %d", EYE_ZERO_STREAK, mouse[0], mouse[1]);
			Eyetest_Violation(client, ET_ZERO, zinfo, sZero);

			CloseHandle(zinfo);
		}
	}
	else
	{
		g_iZeroStreak[client] = 0;
	}

	new Float:fPitch = angles[0], Float:fRoll = angles[2];
	new bool:bLisp = (angles[1] > EYE_MAX_YAW || angles[1] < -EYE_MAX_YAW);

	if (fPitch > 180.0)	fPitch -= 360.0;
	if (fRoll > 180.0)	fRoll -= 360.0;

	if (!bLisp && fPitch >= -EYE_MAX_PITCH && fPitch <= EYE_MAX_PITCH && fRoll >= -EYE_MAX_ROLL && fRoll <= EYE_MAX_ROLL)
		return Plugin_Continue;

	if (IsBotAuth(client))
		return Plugin_Continue;

	g_iPauseUntilCmd[client] = cmdnum + g_iPauseCmds;

	new Handle:info = CreateKeyValues("");
	KvSetVector(info, "angles", angles);

	decl String:sDetail[128];
	FormatEx(sDetail, sizeof(sDetail), "Eye Angles: %.0f %.0f %.0f", angles[0], angles[1], angles[2]);

	new bool:bOnlyLisp = (fPitch >= -EYE_MAX_PITCH && fPitch <= EYE_MAX_PITCH && fRoll >= -EYE_MAX_ROLL && fRoll <= EYE_MAX_ROLL);
	Eyetest_Violation(client, bOnlyLisp ? ET_LISP : ET_ANGLES, info, sDetail);

	CloseHandle(info);

	if (fPitch > EYE_MAX_PITCH)
		angles[0] = EYE_MAX_PITCH;
	else if (fPitch < -EYE_MAX_PITCH)
		angles[0] = -EYE_MAX_PITCH;
	else
		angles[0] = fPitch;
	angles[2] = 0.0;

	if (bLisp)
	{
		angles[1] -= 360.0 * float(RoundToFloor(angles[1] / 360.0));
		if (angles[1] > 180.0)
			angles[1] -= 360.0;
	}

	return Plugin_Changed;
}

bool:IsBotAuth(client)
{
	decl String:sAuthID[MAX_AUTHID_LENGTH];

	#if SOURCEMOD_V_MAJOR >= 1 && SOURCEMOD_V_MINOR >= 7
	if (!GetClientAuthId(client, AuthId_Steam2, sAuthID, sizeof(sAuthID), false) || StrEqual(sAuthID, "BOT"))
	#else
	if (!GetClientAuthString(client, sAuthID, sizeof(sAuthID), false) || StrEqual(sAuthID, "BOT"))
	#endif
		return true;

	return false;
}

EyeTest_SeedSkipDetected(client, cmdnum, expected, skipDelta, seed)
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "cmdnum", cmdnum);
	KvSetNum(info, "expected", expected);
	KvSetNum(info, "skip", skipDelta);
	KvSetNum(info, "seed", seed);
	KvSetNum(info, "detection", g_iSeedSkipDetections[client] + 1);

	if (SMAC_CheatDetected(client, Detection_SeedSkip, info) != Plugin_Continue)
	{
		CloseHandle(info);
		return;
	}

	CloseHandle(info);

	g_iSeedSkipDetections[client]++;
	CreateTimer(600.0, Timer_DecreaseSeedSkip, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

	SMAC_PrintAdminNotice("%t", "SMAC_SeedSkipDetected", client, g_iSeedSkipDetections[client], skipDelta);
	SMAC_LogAction(client, "is suspected of nospread seed hunting. (Detection #%i | CmdNum skip: %d | expected %d got %d)", g_iSeedSkipDetections[client], skipDelta, expected, cmdnum);

	if (GetConVarBool(g_hCvarSeedBan) && g_iSeedSkipDetections[client] >= SEED_SKIP_DETECT_BAN)
	{
		SMAC_LogAction(client, "was banned for nospread seed hunting.");
		SMAC_Ban(client, "Eye Test Violation => SeedSkip");
	}
}

public Action:Timer_DecreaseSeedSkip(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (IS_CLIENT(client) && g_iSeedSkipDetections[client] > 0)
	{
		g_iSeedSkipDetections[client]--;
	}
	return Plugin_Stop;
}

Eyetest_Violation(client, check, Handle:info, const String:detail[])
{
	new level = GetConVarInt((check == ET_ZERO || check == ET_LISP) ? g_hCvarNewReaction : g_hCvarReaction);

	if (level <= 0)
		return;

	if (++g_iViolations[client][check] <= 0)
	{
		CreateTimer(EYE_DECAY, Timer_Decay, (GetClientUserId(client) << 3) | check, TIMER_FLAG_NO_MAPCHANGE);
		return;
	}

	if (level > 1 && !GetConVarBool(g_hCvarBan))
	{
		level = 1;
	}

	if (SMAC_CheatDetected(client, g_iDetection[check], info) != Plugin_Continue)
	{
		g_iViolations[client][check] = -1;
		return;
	}

	SMAC_PrintAdminNotice("%t", "SMAC_EyetestDetected", client);

	switch (level)
	{
		case 3:
		{
			SMAC_LogAction(client, "was banned for %s. %s", g_sCheck[check], detail);
			SMAC_Ban(client, "%s", g_sCheck[check]);
		}
		case 2:
		{
			SMAC_LogAction(client, "was kicked for %s. %s", g_sCheck[check], detail);
			KickClient(client, "%t", "SMAC_PlusKick");
		}
		default:
		{
			SMAC_LogAction(client, "is suspected of %s. %s", g_sCheck[check], detail);
		}
	}

	g_iViolations[client][check] = (level > 1) ? -30 : -2;
}

public Action:Timer_Decay(Handle:timer, any:data)
{
	new client = GetClientOfUserId(data >> 3);
	new check = data & 7;

	if (IS_CLIENT(client) && g_iViolations[client][check] > -1)
	{
		g_iViolations[client][check]--;
	}

	return Plugin_Stop;
}
