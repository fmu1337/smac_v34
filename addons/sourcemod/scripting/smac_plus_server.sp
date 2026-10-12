#pragma semicolon 1
#include <sourcemod>
#include <smac>

public Plugin:myinfo =
{
	name = "SMAC Plus: Server",
	author = SMAC_AUTHOR,
	description = "Half-connected commands, rcon commands, argument overflow, Iniuria and auth checks from SMAC Plus",
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

	g_hCvarHalfConnected = SMAC_CreateConVar("smac_plus_halfconnected", "1", "Commands before in-game: 0=allow, 1=block+log, 2=block+ban", _, true, 0.0, true, 2.0);
	g_hCvarRcon = SMAC_CreateConVar("smac_plus_rcon_command", "1", "Client rcon* from non-admins: 0=allow, 1=block+notice, 2=block+ban", _, true, 0.0, true, 2.0);
	g_hCvarOverflow = SMAC_CreateConVar("smac_plus_arg_overflow", "1", "Numeric args sum > 3e9: 0=allow, 1=block+notice, 2=block+kick", _, true, 0.0, true, 2.0);
	g_hCvarIniuria = SMAC_CreateConVar("smac_indirect_cheat", "1", "Iniuria voice cmd flood: 0=off, 1=notice, 2=kick, 3=ban", _, true, 0.0, true, 3.0);
	g_hCvarAuth = SMAC_CreateConVar("smac_validate_auth", "1", "Not authorized 10 s after join: 0=off, 1=notice, 2=kick", _, true, 0.0, true, 2.0);
	g_hCvarAdminImmune = SMAC_CreateConVar("smac_plus_admin_immune", "1", "Never kick/ban admins with ban/root (still logged): 0=off, 1=on", _, true, 0.0, true, 1.0);

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

	if (StrContains(command, "rcon", false) == 0 && !CheckCommandAccess(client, "smac_plus_rcon", ADMFLAG_RCON, true))
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
				KickClient(client, "%t", "SMAC_PlusKick");
			}
			return Plugin_Stop;
		}
	}

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

bool:Detected(client, const String:name[], const String:detail[])
{
	new Handle:info = CreateKeyValues("");
	KvSetString(info, "check", name);
	KvSetString(info, "detail", detail);
	new Action:result = SMAC_CheatDetected(client, Detection_PlusServer, info);
	CloseHandle(info);

	if (result != Plugin_Continue)
		return false;

	if (CanLog(client))
	{
		SMAC_LogAction(client, "%s | %s", name, detail);
		SMAC_PrintAdminNotice("%t", "SMAC_PlusNotice", client, name, 1);
	}
	return true;
}

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
		KickClient(client, "%t", "SMAC_PlusKick");
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

LowerAction(client, action)
{
	if (action > 1 && GetClientAvgLatency(client, NetFlow_Outgoing) >= MAX_PING)
		action--;

	if (action > 1 && GetClientAvgPackets(client, NetFlow_Incoming) <= MIN_PACKET_FRAC / GetTickInterval())
		action--;

	return action;
}
