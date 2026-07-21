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

enum ResetStatus {
	State_Okay = 0,
	State_Resetting,
	State_Reset
};

// ForceSeed / SeedHelp (insomnia, informant, 420hook): skip command_number until
// (MD5_PseudoRandom(cmdnum) & 255) matches a desired seed. Average skip ~128.
// Small gaps can be choke/lag; large gaps on IN_ATTACK are nospread seed hunting.
#define SEED_SKIP_MIN_DELTA		16
#define SEED_SKIP_DETECT_BAN	3

new Handle:g_hCvarBan = INVALID_HANDLE;
new Handle:g_hCvarSeedBan = INVALID_HANDLE;
new Float:g_fDetectedTime[MAXPLAYERS+1];

new bool:g_bPrevAlive[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1] = {-1, ...};
new g_iPrevCmdNum[MAXPLAYERS+1] = {-1, ...};
new g_iPrevTickCount[MAXPLAYERS+1] = {-1, ...};
new g_iCmdNumOffset[MAXPLAYERS+1] = {1, ...};
new g_iSeedSkipDetections[MAXPLAYERS+1];

new ResetStatus:g_TickStatus[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");
	
	// Convars.
	g_hCvarBan = SMAC_CreateConVar("smac_eyetest_ban", "1", "Automatically ban players on eye test detections.", _, true, 0.0, true, 1.0);
	g_hCvarSeedBan = SMAC_CreateConVar("smac_eyetest_seed_ban", "1", "Automatically ban players for nospread seed hunting (command_number skips on attack).", _, true, 0.0, true, 1.0);
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
	g_iSeedSkipDetections[client] = 0;
}

public OnClientDisconnect_Post(client)
{
	g_fDetectedTime[client] = 0.0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	// Ignore bots
	if (IsFakeClient(client))
		return Plugin_Continue;
	
	// NULL commands
	if (cmdnum <= 0)
		return Plugin_Handled;
	
	// Block old cmds after a client resets their tickcount.
	if (tickcount <= 0)
		g_TickStatus[client] = State_Resetting;
	
	// Fixes issues caused by client timeouts.
	new bool:bAlive = IsPlayerAlive(client);
	if (!bAlive || !g_bPrevAlive[client] || GetGameTime() <= g_fDetectedTime[client])
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
	
		g_fDetectedTime[client] = GetGameTime() + 30.0;
		
		new Handle:info = CreateKeyValues("");
		KvSetNum(info, "cmdnum", cmdnum);
		KvSetNum(info, "prevcmdnum", g_iPrevCmdNum[client]);
		KvSetNum(info, "tickcount", tickcount);
		KvSetNum(info, "prevtickcount", g_iPrevTickCount[client]);
		KvSetNum(info, "gametickcount", GetGameTickCount());
		
		if (SMAC_CheatDetected(client, Detection_UserCmdReuse, info) == Plugin_Continue)
		{
			SMAC_PrintAdminNotice("%t", "SMAC_EyetestDetected", client);
			
			if (GetConVarBool(g_hCvarBan))
			{
				SMAC_LogAction(client, "was banned for reusing old movement commands. CmdNum: %d PrevCmdNum: %d | [%d:%d:%d]", cmdnum, g_iPrevCmdNum[client], g_iPrevTickCount[client], tickcount, GetGameTickCount());
				SMAC_Ban(client, "Eye Test Violation => UserCmdReuse");
			}
			else
			{
				SMAC_LogAction(client, "is suspected of reusing old movement commands. CmdNum: %d PrevCmdNum: %d | [%d:%d:%d]", cmdnum, g_iPrevCmdNum[client], g_iPrevTickCount[client], tickcount, GetGameTickCount());
			}
		}
		
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
	
		// The tickcount should be incremented.
		if (g_iPrevTickCount[client]+1 != tickcount)
		{
			g_fDetectedTime[client] = GetGameTime() + 30.0;
			new Handle:info = CreateKeyValues("");
			KvSetNum(info, "cmdnum", cmdnum);
			KvSetNum(info, "tickcount", tickcount);
			KvSetNum(info, "prevtickcount", g_iPrevTickCount[client]);
			KvSetNum(info, "gametickcount", GetGameTickCount());
			if (SMAC_CheatDetected(client, Detection_UserCmdTamperingTickcount, info) == Plugin_Continue)
			{
				SMAC_PrintAdminNotice("%t", "SMAC_EyetestDetected", client);
				if (GetConVarBool(g_hCvarBan))
				{
					SMAC_LogAction(client, "was banned for tampering with an old movement command (tickcount). CmdNum: %d | [%d:%d:%d]", cmdnum, g_iPrevTickCount[client], tickcount, GetGameTickCount());
					SMAC_Ban(client, "Eye Test Violation => UserCmdTamperingTickcount");
				}
				else
				{
					SMAC_LogAction(client, "is suspected of tampering with an old movement command (tickcount). CmdNum: %d | [%d:%d:%d]", cmdnum, g_iPrevTickCount[client], tickcount, GetGameTickCount());
				}
			}
			
			CloseHandle(info);
			return Plugin_Handled;
		}
		
		// Check for specific buttons in order to avoid compatibility issues with server-side plugins.
		if (((g_iPrevButtons[client] ^ buttons) & (IN_FORWARD|IN_BACK|IN_MOVELEFT|IN_MOVERIGHT|IN_SCORE))) 
		//if (!GetConVarBool(g_hCvarCompat) && (AbsValue(g_iPrevButtons[client] - buttons) & (IN_FORWARD|IN_BACK|IN_MOVELEFT|IN_MOVERIGHT|IN_SCORE))) - new shit [b3 method]
		{
			g_fDetectedTime[client] = GetGameTime() + 30.0;
			
			new Handle:info = CreateKeyValues("");
			KvSetNum(info, "cmdnum", cmdnum);
			KvSetNum(info, "prevbuttons", g_iPrevButtons[client]);
			KvSetNum(info, "buttons", buttons);

			if (SMAC_CheatDetected(client, Detection_UserCmdTamperingButtons, info) == Plugin_Continue)
			{
				SMAC_PrintAdminNotice("%t", "SMAC_EyetestDetected", client);				
			}
			CloseHandle(info);
			return Plugin_Handled;
		}
		// Track so we can predict the next cmdnum.
		g_iCmdNumOffset[client]++;
	}
	else
	{
		new iExpected = g_iPrevCmdNum[client] + g_iCmdNumOffset[client];
		new iSkipDelta = cmdnum - iExpected;
		
		// Passively block cheats from skipping to desired seeds (ForceSeed / SeedHelp).
		if ((buttons & IN_ATTACK) && iSkipDelta != 0 && g_iPrevCmdNum[client] > 0)
		{
			seed = GetURandomInt();
			
			// Large skips while firing = nospread seed search (avg ~128 for &255 match).
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
		
	// Normalize one turn, then reject residual out-of-range pitch/roll.
	// Lisp AA (insomnia ~697049 / ~696871) fails residual check; also clamp so AA gains nothing.
	decl Float:vTemp[3];
	vTemp = angles;
	if (vTemp[0] > 180.0)
		vTemp[0] -= 360.0;
	if (vTemp[2] > 180.0)
		vTemp[2] -= 360.0;
	if (vTemp[0] >= -90.0 && vTemp[0] <= 90.0 && vTemp[2] >= -90.0 && vTemp[2] <= 90.0)
		return Plugin_Continue;
	
	new flags = GetEntityFlags(client);
	if (flags & FL_FROZEN || flags & FL_ATCONTROLS)
		return Plugin_Continue;
	
	// The client failed all checks.
	g_fDetectedTime[client] = GetGameTime() + 30.0;
	
	// Strict bot checking - https://bugs.alliedmods.net/show_bug.cgi?id=5294
	decl String:sAuthID[MAX_AUTHID_LENGTH];
	
	new Handle:info = CreateKeyValues("");
	KvSetVector(info, "angles", angles);
	#if SOURCEMOD_V_MAJOR >= 1 && SOURCEMOD_V_MINOR >= 7
	if (GetClientAuthId(client, AuthId_Steam2, sAuthID, sizeof(sAuthID), false) && !StrEqual(sAuthID, "BOT") && SMAC_CheatDetected(client, Detection_Eyeangles, info) == Plugin_Continue)
	#else
	if (GetClientAuthString(client, sAuthID, sizeof(sAuthID), false) && !StrEqual(sAuthID, "BOT") && SMAC_CheatDetected(client, Detection_Eyeangles, info) == Plugin_Continue)
	#endif
	{
		SMAC_PrintAdminNotice("%t", "SMAC_EyetestDetected", client);
		
		if (GetConVarBool(g_hCvarBan))
		{
			SMAC_LogAction(client, "was banned for cheating with their eye angles. Eye Angles: %.0f %.0f %.0f", angles[0], angles[1], angles[2]);
			SMAC_Ban(client, "Eye Test Violation => Eye Angle");
		}
		else
		{
			SMAC_LogAction(client, "is suspected of cheating with their eye angles. Eye Angles: %.0f %.0f %.0f", angles[0], angles[1], angles[2]);
		}
	}
	
	CloseHandle(info);
	
	// Neutralize illegal AA / lisp even when ban is off or forward blocked the ban.
	if (angles[0] > 89.0)
		angles[0] = 89.0;
	else if (angles[0] < -89.0)
		angles[0] = -89.0;
	angles[2] = 0.0;
	
	return Plugin_Changed;
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
