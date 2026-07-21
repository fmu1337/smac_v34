#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Fake Lag / DDoS / Voice (Ultr@ FL_Ctrl family)
 *
 * Original module by Danyas for SMAC v34.
 * Ultr@ smac_FL_Ctrl (signed %% loss), smac_DDoS_Ctrl (RunCmd flood while
 * FL active), smac_Voice_Ctrl (mute voice_inputfromfile / loopback abuse).
 * Legacy smac_fakelag_* cvars kept as aliases.
 */

public Plugin:myinfo =
{
	name = "SMAC: Fake Lag / DDoS / Voice",
	author = SMAC_AUTHOR,
	description = "Ultr@ Fake Lag, DDoS packet flood, Voice abuse",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define STREAK_NEED		5

new Handle:g_hCvarFL = INVALID_HANDLE;
new Handle:g_hCvarDDoS = INVALID_HANDLE;
new Handle:g_hCvarVoice = INVALID_HANDLE;
new Handle:g_hCvarLoss = INVALID_HANDLE;
new Handle:g_hCvarChoke = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;

new g_iLossStreak[MAXPLAYERS+1];
new g_iChokeStreak[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];
new g_iDDoSDetects[MAXPLAYERS+1];
new g_iCmdBucket[MAXPLAYERS+1];
new g_iVoiceDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	/* Ultr@ signed %% : abs=threshold percent; sign selects kick/ban. 0=off. Soft default 0. */
	g_hCvarFL = SMAC_CreateConVar("smac_FL_Ctrl", "0.0", "Fake Lag %% loss. 0=off, -75=kick@75%%, +75=ban@75%%", _, true, -90.0, true, 90.0);
	g_hCvarDDoS = SMAC_CreateConVar("smac_DDoS_Ctrl", "0.0", "DDoS RunCmd flood (needs FL on). 0=off, -1=kick, +1=ban", _, true, -1.0, true, 1.0);
	g_hCvarVoice = SMAC_CreateConVar("smac_Voice_Ctrl", "1", "Mute voice_inputfromfile / loopback abuse. 0=off 1=on", _, true, 0.0, true, 1.0);

	/* Legacy aliases (0-1 fraction). Prefer FL_Ctrl when non-zero. */
	g_hCvarLoss = SMAC_CreateConVar("smac_fakelag_loss", "0.0", "Legacy avg loss 0-1. Used if FL_Ctrl=0.", _, true, 0.0, true, 1.0);
	g_hCvarChoke = SMAC_CreateConVar("smac_fakelag_choke", "0.0", "Legacy avg choke 0-1. Used if FL_Ctrl=0.", _, true, 0.0, true, 1.0);
	g_hCvarBan = SMAC_CreateConVar("smac_fakelag_ban", "0", "Legacy detections before ban when using fakelag_* only.", _, true, 0.0);

	CreateTimer(1.0, Timer_CheckLag, _, TIMER_REPEAT);
}

public OnClientPutInServer(client)
{
	g_iLossStreak[client] = 0;
	g_iChokeStreak[client] = 0;
	g_iDetects[client] = 0;
	g_iDDoSDetects[client] = 0;
	g_iCmdBucket[client] = 0;
	g_iVoiceDetects[client] = 0;

	if (GetConVarBool(g_hCvarVoice) && !IsFakeClient(client))
	{
		CreateTimer(3.0, Timer_VoiceQuery, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		CreateTimer(30.0, Timer_VoiceQuery, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action:Timer_VoiceQuery(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Stop;
	if (!GetConVarBool(g_hCvarVoice))
		return Plugin_Stop;

	QueryClientConVar(client, "voice_loopback", Query_VoiceAbuse);
	QueryClientConVar(client, "voice_inputfromfile", Query_VoiceAbuse);
	return Plugin_Continue;
}

public Query_VoiceAbuse(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[])
{
	if (result != ConVarQuery_Okay || !IS_CLIENT(client) || !IsClientInGame(client))
		return;
	if (!GetConVarBool(g_hCvarVoice))
		return;

	new Float:v = StringToFloat(cvarValue);
	if (v < 0.5 && !StrEqual(cvarValue, "1"))
		return;

	g_iVoiceDetects[client]++;
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iVoiceDetects[client]);
	KvSetString(info, "cvar", cvarName);
	if (SMAC_CheatDetected(client, Detection_VoiceAbuse, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_VoiceAbuseDetected", client, cvarName);
		SMAC_LogAction(client, "voice abuse (%s=%s) — muting", cvarName, cvarValue);
		SetClientListeningFlags(client, VOICE_MUTED);
		PrintToChat(client, "[SMAC] Voice abuse blocked (%s).", cvarName);
	}
	CloseHandle(info);
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (GetConVarFloat(g_hCvarFL) == 0.0 || GetConVarFloat(g_hCvarDDoS) == 0.0)
		return Plugin_Continue;
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	g_iCmdBucket[client]++;
	return Plugin_Continue;
}

public Action:Timer_CheckLag(Handle:timer)
{
	new Float:fl = GetConVarFloat(g_hCvarFL);
	new Float:ddos = GetConVarFloat(g_hCvarDDoS);
	new Float:lossLimit = GetConVarFloat(g_hCvarLoss);
	new Float:chokeLimit = GetConVarFloat(g_hCvarChoke);

	new Float:flFrac = 0.0;
	if (fl != 0.0)
		flFrac = FloatAbs(fl) / 100.0;

	new tick = RoundToCeil(1.0 / GetTickInterval());

	for (new client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || IsClientInKickQueue(client))
		{
			g_iCmdBucket[client] = 0;
			continue;
		}

		new cmds = g_iCmdBucket[client];
		g_iCmdBucket[client] = 0;

		new Float:loss = GetClientAvgLoss(client, NetFlow_Outgoing);
		new Float:choke = GetClientAvgChoke(client, NetFlow_Outgoing);

		/* Fake Lag — Ultr@ FL_Ctrl or legacy fraction cvars. */
		if (flFrac > 0.0)
		{
			if (loss >= flFrac || choke >= flFrac)
			{
				g_iLossStreak[client]++;
				if (g_iLossStreak[client] >= STREAK_NEED)
				{
					g_iLossStreak[client] = 0;
					FireFL(client, fl, (loss >= flFrac) ? loss : choke);
				}
			}
			else
			{
				g_iLossStreak[client] = 0;
			}
		}
		else if (lossLimit > 0.0 || chokeLimit > 0.0)
		{
			CheckLegacy(client, loss, choke, lossLimit, chokeLimit);
		}

		/* DDoS — RunCmd flood while FL module is enabled. */
		if (fl != 0.0 && ddos != 0.0 && cmds > tick + 8)
		{
			g_iDDoSDetects[client]++;
			new react = (ddos > 0.0) ? 1 : -1;
			new Handle:info = CreateKeyValues("");
			KvSetNum(info, "detection", g_iDDoSDetects[client]);
			KvSetNum(info, "cmds", cmds);
			KvSetNum(info, "tick", tick);
			if (SMAC_CheatDetected(client, Detection_DDoS, info) == Plugin_Continue)
			{
				SMAC_PrintAdminNotice("%t", "SMAC_DDoSDetected", client, g_iDDoSDetects[client]);
				SMAC_LogAction(client, "ddos-cmd flood (Detection #%i | cmds=%i tick=%i)", g_iDDoSDetects[client], cmds, tick);
				SMAC_UltraReact(client, g_iDDoSDetects[client], react, "DDoS Cheat Exploit", "SMAC_DDoSKick");
			}
			CloseHandle(info);
		}
	}

	return Plugin_Continue;
}

CheckLegacy(client, Float:loss, Float:choke, Float:lossLimit, Float:chokeLimit)
{
	new bool:hit = false;
	if (lossLimit > 0.0)
	{
		if (loss >= lossLimit)
			g_iLossStreak[client]++;
		else
			g_iLossStreak[client] = 0;
		if (g_iLossStreak[client] >= STREAK_NEED)
		{
			g_iLossStreak[client] = 0;
			hit = true;
			FireLegacy(client, "loss", loss);
		}
	}
	if (!hit && chokeLimit > 0.0)
	{
		if (choke >= chokeLimit)
			g_iChokeStreak[client]++;
		else
			g_iChokeStreak[client] = 0;
		if (g_iChokeStreak[client] >= STREAK_NEED)
		{
			g_iChokeStreak[client] = 0;
			FireLegacy(client, "choke", choke);
		}
	}
}

FireFL(client, Float:signedFL, Float:value)
{
	g_iDetects[client]++;
	new react = (signedFL > 0.0) ? 1 : -1;
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iDetects[client]);
	KvSetFloat(info, "value", value);
	if (SMAC_CheatDetected(client, Detection_FakeLag, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_FakeLagDetected", client, g_iDetects[client]);
		SMAC_LogAction(client, "fake lag FL_Ctrl (Detection #%i | val=%.2f)", g_iDetects[client], value);
		SMAC_UltraReact(client, g_iDetects[client], react, "Fake Lag Detection", "SMAC_FakeLagKick");
	}
	CloseHandle(info);
}

FireLegacy(client, const String:kind[], Float:value)
{
	g_iDetects[client]++;
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iDetects[client]);
	KvSetString(info, "kind", kind);
	KvSetFloat(info, "value", value);
	if (SMAC_CheatDetected(client, Detection_FakeLag, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_FakeLagDetected", client, g_iDetects[client]);
		SMAC_LogAction(client, "fake lag (Detection #%i | %s=%.2f)", g_iDetects[client], kind, value);
		new banAt = GetConVarInt(g_hCvarBan);
		if (banAt && g_iDetects[client] >= banAt)
			SMAC_Ban(client, "Fake Lag Detection");
		else if (SMAC_MayEnforce(Detection_FakeLag))
			KickClient(client, "%t", "SMAC_FakeLagKick");
	}
	CloseHandle(info);
}
