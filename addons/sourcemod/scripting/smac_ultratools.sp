#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Ultr@Tools SP shim
 *
 * Original module by Danyas for SMAC v34.
 * Reimplements Ultr@Tools.ext.so (1.0.1) natives/forwards in pure SourcePawn
 * when the closed extension is absent (it crashes on SM 1.9+/1.10+).
 *
 * Natives (same names as binary): GF, TimerUp, TimerDown, GetCmdStr, SetBan, ClearBanList
 * Forwards: OnBanReleased, OnTimerUp, OnTimerDown
 *
 * See docs/ULTRATOOLS_API.md
 */

public Plugin:myinfo =
{
	name = "SMAC: Ultr@Tools Shim",
	author = SMAC_AUTHOR,
	description = "Pure-SP Ultr@Tools API (SetBan/ClearBanList/GetCmdStr/…)",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hBanTrie = INVALID_HANDLE;
new bool:g_bTimerOn[MAXPLAYERS+1];
new g_iBanLevel[MAXPLAYERS+1];
new Float:g_fBanExpire[MAXPLAYERS+1];
new String:g_sLastCmd[MAXPLAYERS+1][256];
new String:g_sLastCmdGlobal[256];
new bool:g_bProvideNatives = false;

new Handle:g_hFwdBanReleased = INVALID_HANDLE;
new Handle:g_hFwdTimerUp = INVALID_HANDLE;
new Handle:g_hFwdTimerDown = INVALID_HANDLE;
new Handle:g_hCvarEnabled = INVALID_HANDLE;

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	/* Only provide natives if closed Ultr@Tools.ext is not already loaded. */
	if (GetFeatureStatus(FeatureType_Native, "SetBan") != FeatureStatus_Available)
	{
		CreateNative("GF", Native_GF);
		CreateNative("TimerUp", Native_TimerUp);
		CreateNative("TimerDown", Native_TimerDown);
		CreateNative("GetCmdStr", Native_GetCmdStr);
		CreateNative("SetBan", Native_SetBan);
		CreateNative("ClearBanList", Native_ClearBanList);
		g_bProvideNatives = true;
	}

	RegPluginLibrary("ultratools_shim");
	return APLRes_Success;
}

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarEnabled = SMAC_CreateConVar("smac_ultratools_shim", "1", "Enable Ultr@Tools SP shim ban list / timers / cmd capture.", _, true, 0.0, true, 1.0);

	g_hBanTrie = CreateTrie();
	g_hFwdBanReleased = CreateGlobalForward("OnBanReleased", ET_Ignore, Param_Cell);
	g_hFwdTimerUp = CreateGlobalForward("OnTimerUp", ET_Ignore, Param_Cell);
	g_hFwdTimerDown = CreateGlobalForward("OnTimerDown", ET_Ignore, Param_Cell);

	AddCommandListener(CmdListener_Any);
	RegAdminCmd("sm_ultra_banlist", Command_DumpBanList, ADMFLAG_BAN, "Dump Ultr@Tools shim ban list");
	RegAdminCmd("sm_ultra_clearbans", Command_ClearBans, ADMFLAG_BAN, "Clear Ultr@Tools shim ban list");

	CreateTimer(1.0, Timer_TickBans, _, TIMER_REPEAT);

	if (g_bProvideNatives)
		LogMessage("[SMAC] Ultr@Tools SP shim providing natives (closed .ext not loaded).");
	else
		LogMessage("[SMAC] Ultr@Tools SP shim idle — real Ultr@Tools natives already present.");
}

public OnPluginEnd()
{
	if (g_hBanTrie != INVALID_HANDLE)
	{
		CloseHandle(g_hBanTrie);
		g_hBanTrie = INVALID_HANDLE;
	}
}

public OnClientPutInServer(client)
{
	g_iBanLevel[client] = 0;
	g_fBanExpire[client] = 0.0;
	g_sLastCmd[client][0] = '\0';
	g_bTimerOn[client] = false;
}

public OnClientDisconnect(client)
{
	if (g_bTimerOn[client])
	{
		g_bTimerOn[client] = false;
		FireTimerDown(client);
	}
}

public Action:CmdListener_Any(client, const String:command[], argc)
{
	if (g_hCvarEnabled != INVALID_HANDLE && !GetConVarBool(g_hCvarEnabled))
		return Plugin_Continue;

	decl String:args[200];
	args[0] = '\0';
	GetCmdArgString(args, sizeof(args));

	if (client > 0 && IS_CLIENT(client))
		Format(g_sLastCmd[client], sizeof(g_sLastCmd[]), "%s %s", command, args);
	Format(g_sLastCmdGlobal, sizeof(g_sLastCmdGlobal), "%s %s", command, args);
	return Plugin_Continue;
}

public Action:Timer_TickBans(Handle:timer)
{
	if (g_hCvarEnabled != INVALID_HANDLE && !GetConVarBool(g_hCvarEnabled))
		return Plugin_Continue;

	new Float:now = GetGameTime();
	new i;
	for (i = 1; i <= MaxClients; i++)
	{
		if (g_fBanExpire[i] > 0.0 && now >= g_fBanExpire[i])
		{
			g_fBanExpire[i] = 0.0;
			g_iBanLevel[i] = 0;
			if (g_bTimerOn[i])
			{
				g_bTimerOn[i] = false;
				FireTimerDown(i);
			}
			FireBanReleased(i);
		}
		else if (g_bTimerOn[i])
		{
			FireTimerUp(i);
		}
	}
	return Plugin_Continue;
}

FireBanReleased(client)
{
	Call_StartForward(g_hFwdBanReleased);
	Call_PushCell(client);
	Call_Finish();
}

FireTimerUp(client)
{
	Call_StartForward(g_hFwdTimerUp);
	Call_PushCell(client);
	Call_Finish();
}

FireTimerDown(client)
{
	Call_StartForward(g_hFwdTimerDown);
	Call_PushCell(client);
	Call_Finish();
}

/* -------- natives (Ultr@Tools ABI) -------- */

public Native_GF(Handle:plugin, numParams)
{
	/* Unknown semantics in binary; expose shim-ready flag. */
	return (g_hCvarEnabled != INVALID_HANDLE && GetConVarBool(g_hCvarEnabled)) ? 1 : 0;
}

public Native_TimerUp(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if (!IS_CLIENT(client))
		return;
	if (!g_bTimerOn[client])
	{
		g_bTimerOn[client] = true;
		FireTimerUp(client);
	}
}

public Native_TimerDown(Handle:plugin, numParams)
{
	new client = GetNativeCell(1);
	if (!IS_CLIENT(client))
		return;
	if (g_bTimerOn[client])
	{
		g_bTimerOn[client] = false;
		FireTimerDown(client);
	}
}

public Native_GetCmdStr(Handle:plugin, numParams)
{
	new maxlength = GetNativeCell(2);
	decl String:buffer[256];
	buffer[0] = '\0';

	/* Real Ultr@ GetCmdStr often takes only buffer — support buffer[, client]. */
	if (numParams >= 3)
	{
		new client = GetNativeCell(3);
		if (IS_CLIENT(client) && g_sLastCmd[client][0])
			strcopy(buffer, sizeof(buffer), g_sLastCmd[client]);
		else
			strcopy(buffer, sizeof(buffer), g_sLastCmdGlobal);
	}
	else
	{
		strcopy(buffer, sizeof(buffer), g_sLastCmdGlobal);
	}

	SetNativeString(1, buffer, maxlength);
	return (buffer[0] != '\0');
}

public Native_SetBan(Handle:plugin, numParams)
{
	/* SetBan(unsigned client-or-userid, int duration, unsigned banLevel) */
	new client = GetNativeCell(1);
	new duration = GetNativeCell(2);
	new banLevel = GetNativeCell(3);

	if (client > MaxClients)
	{
		/* Might be userid */
		new idx = GetClientOfUserId(client);
		if (idx > 0)
			client = idx;
	}

	if (!IS_CLIENT(client) || !IsClientConnected(client))
		return;

	decl String:auth[64];
	auth[0] = '\0';
	GetClientAuthString(client, auth, sizeof(auth));
	if (!auth[0])
		Format(auth, sizeof(auth), "slot:%d", client);

	new Float:expire;
	if (duration > 0)
		expire = GetGameTime() + float(duration) * 60.0;
	else if (duration == 0)
		expire = GetGameTime() + 30.0;
	else
		expire = GetGameTime() + 365.0 * 24.0 * 3600.0;

	g_iBanLevel[client] = banLevel;
	g_fBanExpire[client] = expire;
	SetTrieValue(g_hBanTrie, auth, expire);

	if (!g_bTimerOn[client])
	{
		g_bTimerOn[client] = true;
		FireTimerUp(client);
	}

	SMAC_LogAction(client, "Ultr@Tools shim SetBan (duration=%i level=%i)", duration, banLevel);
}

public Native_ClearBanList(Handle:plugin, numParams)
{
	ClearTrie(g_hBanTrie);
	new i;
	for (i = 1; i <= MaxClients; i++)
	{
		g_fBanExpire[i] = 0.0;
		g_iBanLevel[i] = 0;
		if (g_bTimerOn[i])
		{
			g_bTimerOn[i] = false;
			FireTimerDown(i);
		}
	}
	LogMessage("[SMAC] Ultr@Tools shim ClearBanList()");
}

public Action:Command_DumpBanList(client, args)
{
	ReplyToCommand(client, "[SMAC] Ultr@Tools shim active natives=%d", g_bProvideNatives);
	new i;
	for (i = 1; i <= MaxClients; i++)
	{
		if (g_fBanExpire[i] > GetGameTime() && IsClientConnected(i))
			ReplyToCommand(client, "  %N level=%i expire_in=%.0fs timer=%d", i, g_iBanLevel[i], g_fBanExpire[i] - GetGameTime(), g_bTimerOn[i]);
	}
	return Plugin_Handled;
}

public Action:Command_ClearBans(client, args)
{
	Native_ClearBanList(INVALID_HANDLE, 0);
	ReplyToCommand(client, "[SMAC] Ultr@Tools shim ban list cleared.");
	return Plugin_Handled;
}
