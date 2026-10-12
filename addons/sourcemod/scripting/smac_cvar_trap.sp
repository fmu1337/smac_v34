#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

public Plugin:myinfo =
{
	name = "SMAC: Cvar Trap",
	author = SMAC_AUTHOR,
	description = "Detects cheats that reset the xbox_* marker cvars (Insomnia antiban) through the MOTD exit command",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define TRAP_CVAR			"xbox_throttlebias"
#define TRAP_DEFAULT		100.0
#define TRAP_ACK			"smac_cvar_trap_ack"
#define TRAP_HOLD			5.0
#define TRAP_MAX_CMD		128

enum TrapState {
	State_None = 0,
	State_Query,
	State_Armed,
	State_Sent,
	State_Check,
	State_Done
};

new Handle:g_hCvarEnable = INVALID_HANDLE;
new Handle:g_hCvarAction = INVALID_HANDLE;
new Handle:g_hCvarDelay = INVALID_HANDLE;

new bool:g_bSupported;
new bool:g_bResending;

new TrapState:g_iState[MAXPLAYERS+1];
new Handle:g_hMotd[MAXPLAYERS+1] = {INVALID_HANDLE, ...};
new g_iTrap[MAXPLAYERS+1];
new g_iToken[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarEnable = SMAC_CreateConVar("smac_cvar_trap", "1", "xbox_throttlebias MOTD trap (CSS v34): 0=off, 1=on", _, true, 0.0, true, 1.0);
	g_hCvarAction = SMAC_CreateConVar("smac_cvar_trap_action", "0", "If the trap was reset: 0=notice, 1=kick, 2=ban", _, true, 0.0, true, 2.0);
	g_hCvarDelay = SMAC_CreateConVar("smac_cvar_trap_delay", "2.0", "Seconds between MOTD ack and the check query", _, true, 0.5, true, 30.0);

	new EngineVersion:engine = GetEngineVersion();
	g_bSupported = (engine == Engine_SourceSDK2006 || engine == Engine_Original);
	if (!g_bSupported)
	{
		SMAC_Log("smac_cvar_trap: engine %d is not CSS v34 (2006), the trap is disabled.", engine);
		return;
	}

	HookUserMessage(GetUserMessageId("VGUIMenu"), Hook_VGUIMenu, true);
	RegConsoleCmd(TRAP_ACK, Command_Ack);
}

public OnClientConnected(client)
{
	ResetClient(client);

	if (g_bSupported && GetConVarBool(g_hCvarEnable) && !IsFakeClient(client))
		g_iState[client] = State_Query;
}

public OnClientPutInServer(client)
{
	if (g_iState[client] != State_Query)
		return;

	QueryClientConVar(client, TRAP_CVAR, Query_First, GetClientUserId(client));
	CreateTimer(TRAP_HOLD, Timer_Hold, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public OnClientDisconnect(client)
{
	ResetClient(client);
}

ResetClient(client)
{
	g_iState[client] = State_None;
	if (g_hMotd[client] != INVALID_HANDLE)
	{
		CloseHandle(g_hMotd[client]);
		g_hMotd[client] = INVALID_HANDLE;
	}
}

public Query_First(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[], any:userid)
{
	if (GetClientOfUserId(userid) != client || g_iState[client] != State_Query)
		return;

	if (result != ConVarQuery_Okay || StringToFloat(cvarValue) != TRAP_DEFAULT)
	{

		g_iState[client] = State_Done;
		SendHeldMotd(client, false);
		return;
	}

	g_iState[client] = State_Armed;
	SendHeldMotd(client, true);
}

public Action:Timer_Hold(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (client && g_iState[client] == State_Query)
	{
		g_iState[client] = State_Done;
		SendHeldMotd(client, false);
	}
	return Plugin_Stop;
}

public Action:Hook_VGUIMenu(UserMsg:msg_id, Handle:bf, const players[], playersNum, bool:reliable, bool:init)
{
	if (g_bResending || playersNum != 1)
		return Plugin_Continue;

	new client = players[0];
	if (!IS_CLIENT(client) || (g_iState[client] != State_Query && g_iState[client] != State_Armed))
		return Plugin_Continue;

	decl String:sName[32];
	BfReadString(bf, sName, sizeof(sName));
	if (!StrEqual(sName, "info") || !BfReadByte(bf))
		return Plugin_Continue;

	new Handle:kv = CreateKeyValues("data");
	decl String:sKey[64], String:sValue[1024];
	for (new i = BfReadByte(bf); i > 0; i--)
	{
		BfReadString(bf, sKey, sizeof(sKey));
		BfReadString(bf, sValue, sizeof(sValue));
		KvSetString(kv, sKey, sValue);
	}

	if (g_hMotd[client] != INVALID_HANDLE)
		CloseHandle(g_hMotd[client]);
	g_hMotd[client] = kv;

	if (g_iState[client] == State_Armed)
		CreateTimer(0.1, Timer_SendArmed, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

	return Plugin_Handled;
}

public Action:Timer_SendArmed(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (client && g_iState[client] == State_Armed)
		SendHeldMotd(client, true);
	return Plugin_Stop;
}

SendHeldMotd(client, bool:bTrap)
{
	new Handle:kv = g_hMotd[client];
	if (kv == INVALID_HANDLE || !IsClientInGame(client))
		return;
	g_hMotd[client] = INVALID_HANDLE;

	if (bTrap)
	{
		decl String:sCmd[TRAP_MAX_CMD], String:sNew[256];
		KvGetString(kv, "cmd", sCmd, sizeof(sCmd));

		if (strlen(sCmd) >= TRAP_MAX_CMD - 1 || (sCmd[0] && IsNumeric(sCmd)))
		{
			g_iState[client] = State_Done;
		}
		else
		{
			g_iTrap[client] = GetRandomInt(101, 9999);
			g_iToken[client] = GetRandomInt(100000, 999999999);

			FormatEx(sNew, sizeof(sNew), "%s %d;%s %d", TRAP_CVAR, g_iTrap[client], TRAP_ACK, g_iToken[client]);
			if (sCmd[0])
				Format(sNew, sizeof(sNew), "%s;%s", sNew, sCmd);

			KvSetString(kv, "cmd", sNew);
			g_iState[client] = State_Sent;
		}
	}

	g_bResending = true;
	ShowVGUIPanel(client, "info", kv, true);
	g_bResending = false;

	CloseHandle(kv);
}

bool:IsNumeric(const String:str[])
{
	for (new i = 0; str[i]; i++)
	{
		if (!IsCharNumeric(str[i]))
			return false;
	}
	return true;
}

public Action:Command_Ack(client, args)
{
	if (!IS_CLIENT(client) || g_iState[client] != State_Sent || args < 1)
		return Plugin_Handled;

	decl String:sArg[16];
	GetCmdArg(1, sArg, sizeof(sArg));
	if (StringToInt(sArg) != g_iToken[client])
		return Plugin_Handled;

	g_iState[client] = State_Check;
	CreateTimer(GetConVarFloat(g_hCvarDelay), Timer_Check, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Handled;
}

public Action:Timer_Check(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (client && g_iState[client] == State_Check)
		QueryClientConVar(client, TRAP_CVAR, Query_Check, userid);
	return Plugin_Stop;
}

public Query_Check(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[], any:userid)
{
	if (GetClientOfUserId(userid) != client || g_iState[client] != State_Check)
		return;

	g_iState[client] = State_Done;
	if (result != ConVarQuery_Okay)
		return;

	new Float:fValue = StringToFloat(cvarValue);
	if (fValue == float(g_iTrap[client]))
		return;

	decl String:sDetail[128];
	FormatEx(sDetail, sizeof(sDetail), "%s set to %d, read back \"%s\"", TRAP_CVAR, g_iTrap[client], cvarValue);

	if (fValue != TRAP_DEFAULT)
	{
		SMAC_LogAction(client, "Cvar Trap: changed by something else | %s", sDetail);
		return;
	}

	React(client, sDetail);
}

React(client, const String:detail[])
{
	new String:sName[] = "Cvar Trap (xbox_* reset)";

	new Handle:info = CreateKeyValues("");
	KvSetString(info, "check", sName);
	KvSetString(info, "detail", detail);
	new Action:result = SMAC_CheatDetected(client, Detection_CvarTrap, info);
	CloseHandle(info);

	if (result != Plugin_Continue)
		return;

	SMAC_LogAction(client, "%s | %s", sName, detail);
	SMAC_PrintAdminNotice("%t", "SMAC_PlusNotice", client, sName, 1);

	switch (GetConVarInt(g_hCvarAction))
	{
		case 1:
		{
			SMAC_LogAction(client, "was kicked for %s.", sName);
			KickClient(client, "%t", "SMAC_PlusKick");
		}
		case 2:
		{
			SMAC_LogAction(client, "was banned for %s.", sName);
			SMAC_Ban(client, "%s Detection", sName);
		}
	}
}
