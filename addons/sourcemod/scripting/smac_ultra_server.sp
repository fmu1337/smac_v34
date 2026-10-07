#pragma semicolon 1
#include <sourcemod>
#include <smac>

/*
 * SMAC Ultr@ R52 port: server protections from 001_SMAC_Rcon, 001_SMAC_Cvars and 001_SMAC_Client
 * that stock SMAC (smac_client, smac_commands, smac_rcon) does not have.
 *
 * Rewritten from the R52 decompile (tools/r52re/decomp.py, docs/R52_SPEC.md §8;
 * docs/ULTRA_SERVER.md). No Ultr@ code and no Ultr@Tools extension is used.
 *
 *   Half-connected command  a client command from a client that is connected but not in game
 *                           (R52 Rcon: SMAC_Hack + addip; "menuclosed" is only dropped).
 *   Rcon command            a client command named rcon* from a non-admin (R52 Cvars: ban).
 *   Argument overflow       the absolute values of the numeric arguments add up to more than
 *                           3e9 (R52 Cvars: kick; ucp_* and say are skipped).
 *   Iniuria (SIC)           voice_loopback / voice_inputfromfile sent as a command after more than
 *                           20 commands in the same second (R52 "cheat class Iniuria CS:S").
 *   Validate auth           the client is in game but still not authorized 10 s after joining
 *                           (R52 Client: kick SMAC_FailedAuth).
 *
 * Defaults block the command and notify admins; the R52 kick/ban is level 2 (3 for Iniuria).
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: Server",
	author = SMAC_AUTHOR,
	description = "Half-connected commands, rcon commands, argument overflow, Iniuria and auth checks from SMAC Ultr@ R52",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define OVERFLOW_LIMIT		3000000000.0
#define INIURIA_CMDS		20
#define AUTH_DELAY			10.0
#define LOG_COOLDOWN		5.0

#define MAX_PING			0.15
#define MIN_PACKET_FRAC		0.7

new Handle:g_hCvarHalfConnected = INVALID_HANDLE;
new Handle:g_hCvarRcon = INVALID_HANDLE;
new Handle:g_hCvarOverflow = INVALID_HANDLE;
new Handle:g_hCvarIniuria = INVALID_HANDLE;
new Handle:g_hCvarAuth = INVALID_HANDLE;
new Handle:g_hCvarAdminImmune = INVALID_HANDLE;

new g_iCmds[MAXPLAYERS+1];
new Float:g_fNextLog[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarHalfConnected = SMAC_CreateConVar("smac_ultra_halfconnected", "1", "Commands from clients that are connected but not in game: 0=allow, 1=block and log, 2=block and ban (R52)", _, true, 0.0, true, 2.0);
	g_hCvarRcon = SMAC_CreateConVar("smac_ultra_rcon_command", "1", "rcon* client commands from non-admins: 0=allow, 1=block and notify, 2=block and ban (R52)", _, true, 0.0, true, 2.0);
	g_hCvarOverflow = SMAC_CreateConVar("smac_ultra_arg_overflow", "1", "Commands whose numeric arguments add up to more than 3e9: 0=allow, 1=block and notify, 2=block and kick (R52)", _, true, 0.0, true, 2.0);
	g_hCvarIniuria = SMAC_CreateConVar("smac_indirect_cheat", "1", "Iniuria cheat (voice_loopback/voice_inputfromfile command flood): 0=off, 1=admin notice, 2=kick, 3=ban (R52: 3)", _, true, 0.0, true, 3.0);
	g_hCvarAuth = SMAC_CreateConVar("smac_validate_auth", "1", "Client not authorized 10 s after joining: 0=off, 1=admin notice, 2=kick (R52)", _, true, 0.0, true, 2.0);
	g_hCvarAdminImmune = SMAC_CreateConVar("smac_ultra_admin_immune", "1", "Never kick/ban admins with ban/root flag (detections are still logged).", _, true, 0.0, true, 1.0);

	AddCommandListener(Command_Listener);
	CreateTimer(1.0, Timer_ResetCmds, _, TIMER_REPEAT);
}

public OnClientConnected(client)
{
	g_iCmds[client] = 0;
	g_fNextLog[client] = 0.0;
}

public OnClientPutInServer(client)
{
	if (!IsFakeClient(client) && GetConVarInt(g_hCvarAuth) > 0)
		CreateTimer(AUTH_DELAY, Timer_CheckAuth, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_ResetCmds(Handle:timer)
{
	for (new i = 1; i <= MaxClients; i++)
		g_iCmds[i] = 0;
	return Plugin_Continue;
}

public Action:Timer_CheckAuth(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsClientAuthorized(client))
		return Plugin_Stop;

	new level = GetConVarInt(g_hCvarAuth);
	if (level <= 0)
		return Plugin_Stop;

	if (Detected(client, "Validate Auth", "not authorized 10 s after joining"))
	{
		if (level >= 2 && !IsImmune(client))
		{
			SMAC_LogAction(client, "was kicked for failing authorization.");
			KickClient(client, "%t", "SMAC_FailedAuth");
		}
	}
	return Plugin_Stop;
}

public Action:Command_Listener(client, const String:command[], argc)
{
	if (!IS_CLIENT(client) || !IsClientConnected(client) || IsFakeClient(client))
		return Plugin_Continue;

	decl String:sArgs[192];

	/* R52 Rcon: commands before the client is in game. */
	if (!IsClientInGame(client))
	{
		new level = GetConVarInt(g_hCvarHalfConnected);
		if (level <= 0)
			return Plugin_Continue;

		if (StrEqual(command, "menuclosed", false))
			return Plugin_Stop;

		GetCmdArgString(sArgs, sizeof(sArgs));
		decl String:sDetail[256];
		FormatEx(sDetail, sizeof(sDetail), "%s %s", command, sArgs);

		if (Detected(client, "Half-connected Command", sDetail) && level >= 2 && !IsImmune(client))
		{
			SMAC_LogAction(client, "was banned for a half-connected command.");
			SMAC_Ban(client, "Half-connected command %s", command);
		}
		return Plugin_Stop;
	}

	g_iCmds[client]++;

	if (StrEqual(command, "say", false) || StrEqual(command, "say_team", false))
		return Plugin_Continue;

	/* R52 Cvars: rcon from a client that is not an admin. */
	if (StrContains(command, "rcon", false) == 0 && !CheckCommandAccess(client, "smac_ultra_rcon", ADMFLAG_RCON, true))
	{
		new level = GetConVarInt(g_hCvarRcon);
		if (level > 0)
		{
			GetCmdArgString(sArgs, sizeof(sArgs));
			decl String:sDetail[256];
			FormatEx(sDetail, sizeof(sDetail), "%s %s", command, sArgs);
			if (Detected(client, "Rcon Command", sDetail) && level >= 2 && !IsImmune(client))
			{
				SMAC_LogAction(client, "was banned for an rcon command.");
				SMAC_Ban(client, "Exploit Violation (%s)", command);
			}
			return Plugin_Stop;
		}
	}

	/* R52 Cvars: numeric arguments that overflow. */
	if (argc > 1 && StrContains(command, "ucp_", false) != 0)
	{
		new level = GetConVarInt(g_hCvarOverflow);
		if (level > 0 && ArgsOverflow(argc))
		{
			GetCmdArgString(sArgs, sizeof(sArgs));
			decl String:sDetail[256];
			FormatEx(sDetail, sizeof(sDetail), "%s %s", command, sArgs);
			if (Detected(client, "Argument Overflow", sDetail) && level >= 2 && !IsImmune(client))
			{
				SMAC_LogAction(client, "was kicked for an exploit command.");
				KickClient(client, "%t", "SMAC_UltraKick");
			}
			return Plugin_Stop;
		}
	}

	/* R52 Cvars: Iniuria floods voice_loopback / voice_inputfromfile as commands. */
	if (g_iCmds[client] > INIURIA_CMDS
		&& (StrEqual(command, "voice_loopback", false) || StrEqual(command, "voice_inputfromfile", false)))
	{
		new level = GetConVarInt(g_hCvarIniuria);
		if (level > 0)
		{
			g_iCmds[client] = -100;

			decl String:sDetail[96];
			FormatEx(sDetail, sizeof(sDetail), "%s after more than %i commands in 1 s", command, INIURIA_CMDS);
			if (Detected(client, "Cheat class Iniuria CS:S", sDetail))
				Punish(client, level, "Cheat class Iniuria CS:S");
			return Plugin_Stop;
		}
	}

	return Plugin_Continue;
}

bool:ArgsOverflow(argc)
{
	decl String:sArg[64];
	new Float:left = OVERFLOW_LIMIT;

	for (new i = 1; i <= argc; i++)
	{
		GetCmdArg(i, sArg, sizeof(sArg));
		left -= FloatAbs(StringToFloat(sArg));
		if (left < 0.0)
			return true;
	}
	return false;
}

/* Logs and notifies (rate-limited per client); returns false if another plugin handled it. */
bool:Detected(client, const String:name[], const String:detail[])
{
	new Handle:info = CreateKeyValues("");
	KvSetString(info, "check", name);
	KvSetString(info, "detail", detail);
	new Action:result = SMAC_CheatDetected(client, Detection_UltraServer, info);
	CloseHandle(info);

	if (result != Plugin_Continue)
		return false;

	if (CanLog(client))
	{
		SMAC_LogAction(client, "%s | %s", name, detail);
		SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, name, 1);
	}
	return true;
}

/* level: 1 notice (done), 2 kick, 3 ban, lowered by the R52 network gate. */
Punish(client, level, const String:name[])
{
	if (level < 2 || IsImmune(client))
		return;

	new action = LowerAction(client, level);
	if (action == 3)
	{
		SMAC_LogAction(client, "was banned for %s.", name);
		SMAC_Ban(client, "%s Detection", name);
	}
	else if (action == 2)
	{
		SMAC_LogAction(client, "was kicked for %s.", name);
		KickClient(client, "%t", "SMAC_UltraKick");
	}
}

bool:CanLog(client)
{
	new Float:now = GetEngineTime();
	if (now < g_fNextLog[client])
		return false;
	g_fNextLog[client] = now + LOG_COOLDOWN;
	return true;
}

bool:IsImmune(client)
{
	return GetConVarBool(g_hCvarAdminImmune) && (GetUserFlagBits(client) & (ADMFLAG_BAN | ADMFLAG_ROOT)) != 0;
}

/* R52 network gate: lower ban -> kick -> notice once for bad ping and once for few packets. */
LowerAction(client, action)
{
	if (action > 1 && GetClientAvgLatency(client, NetFlow_Outgoing) >= MAX_PING)
		action--;

	if (action > 1 && GetClientAvgPackets(client, NetFlow_Incoming) <= MIN_PACKET_FRAC / GetTickInterval())
		action--;

	return action;
}
