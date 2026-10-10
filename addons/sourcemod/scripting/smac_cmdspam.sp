#include <sourcemod>
#include <smac>

/* Plugin Info */
public Plugin:myinfo =
{
	name = "SMAC: Command Spam",
	author = SMAC_AUTHOR,
	description = "Kicks players who flood the server with commands",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hIgnoredCmds = INVALID_HANDLE;
new Handle:g_hCvarCmdSpam = INVALID_HANDLE;
new Handle:g_hCvarCmdSpamKick = INVALID_HANDLE;
new g_iCmdSpamLimit = 25;
new g_iCmdCount[MAXPLAYERS+1] = {0, ...};

/* Plugin Functions */
public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarCmdSpam = SMAC_CreateConVar("smac_antispam_cmds", "-25", "Amount of commands allowed per second, kick above it. (0 = Disabled; SMAC Ultr@ R52: -25, stock SMAC: 35; the sign is accepted for R52 configs)");
	OnSettingsChanged(g_hCvarCmdSpam, "", "");
	HookConVarChange(g_hCvarCmdSpam, OnSettingsChanged);

	g_hCvarCmdSpamKick = SMAC_CreateConVar("smac_antispam_cmds_kick", "1", "Kick (1) or only notify admins and log (0) on command spam.", _, true, 0.0, true, 1.0);

	// Commands that never count towards the limit.
	g_hIgnoredCmds = CreateTrie();
//	SetTrieValue(g_hIgnoredCmds, "buy", true); // AntiBuy DDOS
//	SetTrieValue(g_hIgnoredCmds, "buyammo1", true);
//	SetTrieValue(g_hIgnoredCmds, "buyammo2", true);
	SetTrieValue(g_hIgnoredCmds, "setpause", true);
//	SetTrieValue(g_hIgnoredCmds, "spec_mode", true);
//	SetTrieValue(g_hIgnoredCmds, "spec_next", true);
//	SetTrieValue(g_hIgnoredCmds, "spec_prev", true);
	SetTrieValue(g_hIgnoredCmds, "unpause", true);
	SetTrieValue(g_hIgnoredCmds, "use", true);
	SetTrieValue(g_hIgnoredCmds, "vban", true);
	SetTrieValue(g_hIgnoredCmds, "vmodenable", true);

	CreateTimer(1.0, Timer_ResetCmdCount, _, TIMER_REPEAT);

	AddCommandListener(Command_CommandListener);

	RegAdminCmd("smac_addignorecmd", Command_AddIgnoreCmd, ADMFLAG_ROOT, "Ignore a command.");
	RegAdminCmd("smac_removeignorecmd", Command_RemoveIgnoreCmd, ADMFLAG_ROOT, "Unignore a command.");
}

public OnClientDisconnect_Post(client)
{
	g_iCmdCount[client] = 0;
}

public Action:Command_AddIgnoreCmd(client, args)
{
	if (args == 1)
	{
		decl String:sCommand[PLATFORM_MAX_PATH];

		GetCmdArg(1, sCommand, sizeof(sCommand));
		StringToLower(sCommand);

		SetTrieValue(g_hIgnoredCmds, sCommand, true);
		ReplyToCommand(client, "%s has been added.", sCommand);

		return Plugin_Handled;
	}

	ReplyToCommand(client, "Usage: smac_addignorecmd <cmd>");
	return Plugin_Handled;
}

public Action:Command_RemoveIgnoreCmd(client, args)
{
	if (args == 1)
	{
		decl String:sCommand[PLATFORM_MAX_PATH];

		GetCmdArg(1, sCommand, sizeof(sCommand));
		StringToLower(sCommand);

		if (RemoveFromTrie(g_hIgnoredCmds, sCommand))
		{
			ReplyToCommand(client, "%s has been removed.", sCommand);
		}
		else
		{
			ReplyToCommand(client, "%s was not found.", sCommand);
		}

		return Plugin_Handled;
	}

	ReplyToCommand(client, "Usage: smac_removeignorecmd <cmd>");
	return Plugin_Handled;
}

public Action:Command_CommandListener(client, const String:command[], argc)
{
	if (!IS_CLIENT(client))
		return Plugin_Continue;

	// NOTE: InternalDispatch automatically lower cases "command".
	// R52 also never counts ucp_* (UCP anti-cheat client) commands.
	new bool:bIgnored;
	if (!g_iCmdSpamLimit || GetTrieValue(g_hIgnoredCmds, command, bIgnored) || strncmp(command, "ucp_", 4) == 0)
		return Plugin_Continue;

	if (++g_iCmdCount[client] <= g_iCmdSpamLimit)
		return Plugin_Continue;

	// Report once per burst; the rest of the burst is just dropped.
	if (g_iCmdCount[client] == g_iCmdSpamLimit + 1)
	{
		decl String:sArgString[192];
		GetCmdArgString(sArgString, sizeof(sArgString));

		new Handle:info = CreateKeyValues("");
		KvSetString(info, "command", command);
		KvSetString(info, "argstring", sArgString);

		if (SMAC_CheatDetected(client, Detection_CommandSpamming, info) == Plugin_Continue)
		{
			if (GetConVarBool(g_hCvarCmdSpamKick))
			{
				SMAC_PrintAdminNotice("%N was kicked for spamming: %s %s", client, command, sArgString);
				SMAC_LogAction(client, "was kicked for spamming: %s %s", command, sArgString);
				KickClient(client, "%t", "SMAC_CommandSpamKick");
			}
			else
			{
				SMAC_PrintAdminNotice("%N looks to be spamming commands: %s %s", client, command, sArgString);
				SMAC_LogAction(client, "looks to be spamming commands: %s %s", command, sArgString);
			}
		}

		CloseHandle(info);
	}

	return Plugin_Stop;
}

public Action:Timer_ResetCmdCount(Handle:timer)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		g_iCmdCount[i] = 0;
	}

	return Plugin_Continue;
}

public OnSettingsChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_iCmdSpamLimit = GetConVarInt(convar);

	if (g_iCmdSpamLimit < 0)
	{
		g_iCmdSpamLimit = -g_iCmdSpamLimit;
	}
}
