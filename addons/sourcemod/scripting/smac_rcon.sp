#include <smac>
public Plugin:myinfo =
{
	name = "SMAC: Rcon Locker",
	author = "KorDen",
	description = "Protects against rcon crashes and exploits",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarRconPass = INVALID_HANDLE,
	bool:g_bRconLocked = false,
	String:g_sRconRealPass[128];

public OnPluginStart()
{
	g_hCvarRconPass = FindConVar("rcon_password");
	HookConVarChange(g_hCvarRconPass, OnRconPassChanged);
	
	LoadBlockedCommands();
}

/**
 * SMAC Ultr@ R52: every command listed in cfg/sourcemod/smac_cmd_block.cfg (one per line,
 * "//" starts a comment) is blocked for players. R52 blocked them for the server console too;
 * here the console and rcon can still use them.
 */
LoadBlockedCommands()
{
	new Handle:hFile = OpenFile("cfg/sourcemod/smac_cmd_block.cfg", "r");
	
	if (hFile == INVALID_HANDLE)
		return;
	
	decl String:sLine[128];
	new count;
	
	while (!IsEndOfFile(hFile) && ReadFileLine(hFile, sLine, sizeof(sLine)))
	{
		new comment = StrContains(sLine, "//");
		
		if (comment != -1)
		{
			sLine[comment] = '\0';
		}
		
		TrimString(sLine);
		
		if (sLine[0] == '\0' || FindCharInString(sLine, ' ') != -1)
			continue;
		
		RegConsoleCmd(sLine, Command_Blocked);
		count++;
	}
	
	CloseHandle(hFile);
	LogMessage("[SMAC] %d commands blocked from smac_cmd_block.cfg", count);
}

public Action:Command_Blocked(client, args)
{
	return (client > 0) ? Plugin_Handled : Plugin_Continue;
}

public OnConfigsExecuted()
{
	if (!g_bRconLocked)
	{
		GetConVarString(g_hCvarRconPass, g_sRconRealPass, sizeof(g_sRconRealPass));
		g_bRconLocked = true;
	}
}

public OnRconPassChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (g_bRconLocked && !StrEqual(newValue, g_sRconRealPass))
	{
		SMAC_Log("Rcon password changed to \"%s\". Reverting back to original config value.", newValue);
		SetConVarString(g_hCvarRconPass, g_sRconRealPass);
	}
}