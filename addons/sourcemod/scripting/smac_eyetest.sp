#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smac>

/* Plugin Info */
public Plugin:myinfo =
{
	name = "SMAC: Eye Angle Test",
	author = SMAC_AUTHOR,
	description = "Detects eye angle violations used in cheats",
	version = SMAC_VERSION,
	url = SMAC_URL
};

/*
 * Eyetest 01-04 as in SMAC Ultr@ R52 (001_SMAC_Global.smx, OnPlayerRunCmd):
 *   01  cmdnum went back                                  (Detection_UserCmdReuse)
 *   02  cmdnum repeated, tickcount is not prev or prev+1  (Detection_UserCmdTamperingTickcount)
 *   03  cmdnum repeated, movement/score buttons changed   (Detection_UserCmdTamperingButtons)
 *   04  pitch outside +-89.9 or roll outside +-30         (Detection_Eyeangles)
 * Differences from stock SMAC: a violation is reported only when a second one of the same kind
 * comes within EYE_DECAY seconds, checks pause for 5 s (not 30 s) after a violation, the roll
 * limit is 30 (was 90) and the reaction is set by smac_eyetest_reaction.
 * smac_NoS_NoR (R52) gives every +attack usercmd a new random seed.
 */

#define EYE_MAX_PITCH	89.9
#define EYE_MAX_ROLL	30.0
#define EYE_DECAY		528.0	// R52: SetBan(..., 528) releases one violation
#define EYE_PAUSE		5.0		// R52: checks pause for 5 s worth of cmds after a violation

#define ET_CMDNUM		0
#define ET_TICKCOUNT	1
#define ET_BUTTONS		2
#define ET_ANGLES		3
#define ET_COUNT		4

new const String:g_sCheck[ET_COUNT][] =
{
	"Eye Test Violation => UserCmdReuse",
	"Eye Test Violation => UserCmdTamperingTickcount",
	"Eye Test Violation => UserCmdTamperingButtons",
	"Eye Test Violation => Eye Angle"
};

new const DetectionType:g_iDetection[ET_COUNT] =
{
	Detection_UserCmdReuse,
	Detection_UserCmdTamperingTickcount,
	Detection_UserCmdTamperingButtons,
	Detection_Eyeangles
};

enum ResetStatus {
	State_Okay = 0,
	State_Resetting,
	State_Reset
};

new Handle:g_hCvarBan = INVALID_HANDLE;
new Handle:g_hCvarReaction = INVALID_HANDLE;
new Handle:g_hCvarNoSpread = INVALID_HANDLE;
new g_iPauseCmds;

new g_iPauseUntilCmd[MAXPLAYERS+1];
new g_iViolations[MAXPLAYERS+1][ET_COUNT];
new bool:g_bPrevAlive[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1] = {-1, ...};
new g_iPrevCmdNum[MAXPLAYERS+1] = {-1, ...};
new g_iPrevTickCount[MAXPLAYERS+1] = {-1, ...};
new g_iCmdNumOffset[MAXPLAYERS+1] = {1, ...};
new ResetStatus:g_TickStatus[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	// Convars.
	g_hCvarReaction = SMAC_CreateConVar("smac_eyetest_reaction", "3", "Eye test 01-04 reaction: 0=off, 1=admin notice, 2=kick, 3=ban (SMAC Ultr@ R52: 3)", _, true, 0.0, true, 3.0);
	g_hCvarNoSpread = SMAC_CreateConVar("smac_NoS_NoR", "1", "No Spread / No Recoil block (SMAC Ultr@ R52): a new random seed on every +attack usercmd. 0 = only when cmdnums are skipped (stock SMAC).", _, true, 0.0, true, 1.0);
	g_hCvarBan = SMAC_CreateConVar("smac_eyetest_ban", "1", "Legacy: 0 limits smac_eyetest_reaction to admin notices.", _, true, 0.0, true, 1.0);

	g_iPauseCmds = TIME_TO_TICK(EYE_PAUSE);
	
	for (new i = 1; i <= MaxClients; i++)
	{
		OnClientDisconnect_Post(i);
	}

	// FEATURECAP_PLAYERRUNCMD_11PARAMS shipped in SourceMod 1.5.0 (not 1.7).
	RequireFeature(FeatureType_Capability, FEATURECAP_PLAYERRUNCMD_11PARAMS, "This module requires SourceMod 1.5.0 or newer (FEATURECAP_PLAYERRUNCMD_11PARAMS).");
}

public OnClientDisconnect(client)
{
	// Clients don't actually disconnect on map change. They start sending the new cmdnums before _Post fires.
	g_bPrevAlive[client] = false;
	g_iPrevButtons[client] = -1;
	g_iPrevCmdNum[client] = -1;
	g_iPrevTickCount[client] = -1;
	g_iCmdNumOffset[client] = 1;
	g_TickStatus[client] = State_Okay;
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
	// Ignore bots
	if (IsFakeClient(client))
		return Plugin_Continue;

	// NULL commands
	if (cmdnum <= 0)
		return Plugin_Handled;

	// R52 No Spread / No Recoil block: the cheat can't predict the spread of a shot it doesn't know the seed of.
	if ((buttons & IN_ATTACK) && GetConVarBool(g_hCvarNoSpread))
		seed = GetURandomInt();

	// Block old cmds after a client resets their tickcount.
	if (tickcount <= 0)
		g_TickStatus[client] = State_Resetting;

	// Fixes issues caused by client timeouts.
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

	// Check for valid cmd values being sent. The command number cannot decrement.
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

	// Other than the incremented tickcount, nothing should have changed.
	if (g_iPrevCmdNum[client] == cmdnum)
	{
		if (g_TickStatus[client] != State_Okay)
		{
			g_TickStatus[client] = State_Reset;
			return Plugin_Handled;
		}

		// The tickcount should be incremented. R52 also lets the same tickcount through.
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

		// Check for specific buttons in order to avoid compatibility issues with server-side plugins.
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

		// Track so we can predict the next cmdnum.
		g_iCmdNumOffset[client]++;
	}
	else
	{
		// Passively block cheats from skipping to desired seeds.
		if ((buttons & IN_ATTACK) && g_iPrevCmdNum[client] + g_iCmdNumOffset[client] != cmdnum && g_iPrevCmdNum[client] > 0)
		{
			seed = GetURandomInt();
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

	// Eye Angles 04 (R52): pitch +-89.9, roll +-30.
	new flags = GetEntityFlags(client);

	if (flags & (FL_FROZEN|FL_ATCONTROLS))
		return Plugin_Continue;

	new Float:fPitch = angles[0], Float:fRoll = angles[2];

	if (fPitch > 180.0)	fPitch -= 360.0;
	if (fRoll > 180.0)	fRoll -= 360.0;

	if (fPitch >= -EYE_MAX_PITCH && fPitch <= EYE_MAX_PITCH && fRoll >= -EYE_MAX_ROLL && fRoll <= EYE_MAX_ROLL)
		return Plugin_Continue;

	// Strict bot checking - https://bugs.alliedmods.net/show_bug.cgi?id=5294
	decl String:sAuthID[MAX_AUTHID_LENGTH];

	#if SOURCEMOD_V_MAJOR >= 1 && SOURCEMOD_V_MINOR >= 7
	if (!GetClientAuthId(client, AuthId_Steam2, sAuthID, sizeof(sAuthID), false) || StrEqual(sAuthID, "BOT"))
	#else
	if (!GetClientAuthString(client, sAuthID, sizeof(sAuthID), false) || StrEqual(sAuthID, "BOT"))
	#endif
		return Plugin_Continue;

	g_iPauseUntilCmd[client] = cmdnum + g_iPauseCmds;

	new Handle:info = CreateKeyValues("");
	KvSetVector(info, "angles", angles);

	decl String:sDetail[128];
	FormatEx(sDetail, sizeof(sDetail), "Eye Angles: %.0f %.0f %.0f", angles[0], angles[1], angles[2]);
	Eyetest_Violation(client, ET_ANGLES, info, sDetail);

	CloseHandle(info);
	return Plugin_Continue;
}

Eyetest_Violation(client, check, Handle:info, const String:detail[])
{
	new level = GetConVarInt(g_hCvarReaction);

	if (level <= 0)
		return;

	// R52: the first violation only arms a decay, the next one of the same kind is reported.
	if (++g_iViolations[client][check] <= 0)
	{
		CreateTimer(EYE_DECAY, Timer_Decay, (GetClientUserId(client) << 2) | check, TIMER_FLAG_NO_MAPCHANGE);
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
			KickClient(client, "%t", "SMAC_UltraKick");
		}
		default:
		{
			SMAC_LogAction(client, "is suspected of %s. %s", g_sCheck[check], detail);
		}
	}

	// As in R52: after a notice the next violation is reported again, after a kick/ban it takes 30 more.
	g_iViolations[client][check] = (level > 1) ? -30 : -2;
}

public Action:Timer_Decay(Handle:timer, any:data)
{
	new client = GetClientOfUserId(data >> 2);
	new check = data & 3;

	if (IS_CLIENT(client) && g_iViolations[client][check] > -1)
	{
		g_iViolations[client][check]--;
	}

	return Plugin_Stop;
}
