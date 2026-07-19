#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Speed Limit / SpeedUp (packet-rate anomaly)
 *
 * Original module by Danyas for SMAC v34.
 * Ultr@ smac_SpeedLimitDetect + smac_SpeedUp: count usercmd floods vs
 * tickrate * multiplier (SpeedHack / packet DDoS). Soft defaults.
 */

public Plugin:myinfo =
{
	name = "SMAC: Speed Limit Detect",
	author = SMAC_AUTHOR,
	description = "Ultr@ SpeedLimitDetect / SpeedUp packet-rate checks",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarLimit = INVALID_HANDLE;
new Handle:g_hCvarSpeedUp = INVALID_HANDLE;

new g_iCmdBucket[MAXPLAYERS+1];
new g_iAnomalies[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];
new Float:g_fWindowStart[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	/* Signed Ultr@ style on limit; 0 disables both (per Ultr@ pairing note). */
	g_hCvarLimit = SMAC_CreateConVar("smac_SpeedLimitDetect", "0", "Anomaly count reaction. 0=off, -N=kick, +N=ban", _, true, -100.0, true, 100.0);
	g_hCvarSpeedUp = SMAC_CreateConVar("smac_SpeedUp", "1.2", "Allowed cmd rate vs tickrate (1.0=normal). 0=off", _, true, 0.0, true, 3.0);

	CreateTimer(1.0, Timer_FlushWindows, _, TIMER_REPEAT);
}

public OnClientPutInServer(client)
{
	g_iCmdBucket[client] = 0;
	g_iAnomalies[client] = 0;
	g_iDetects[client] = 0;
	g_fWindowStart[client] = 0.0;
}

public OnClientDisconnect(client)
{
	g_iCmdBucket[client] = 0;
	g_iAnomalies[client] = 0;
}

public Action:Timer_FlushWindows(Handle:timer)
{
	new Float:speedUp = GetConVarFloat(g_hCvarSpeedUp);
	new reaction = GetConVarInt(g_hCvarLimit);
	if (speedUp <= 0.0 || reaction == 0)
		return Plugin_Continue;

	new Float:tick = GetTickInterval();
	new expected = RoundToCeil((1.0 / tick) * speedUp);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		new got = g_iCmdBucket[i];
		g_iCmdBucket[i] = 0;

		if (got > expected)
		{
			g_iAnomalies[i]++;
			new need = reaction;
			if (need < 0)
				need = -need;

			if (g_iAnomalies[i] >= need)
			{
				g_iAnomalies[i] = 0;
				g_iDetects[i]++;
				new Handle:info = CreateKeyValues("");
				KvSetNum(info, "detection", g_iDetects[i]);
				KvSetNum(info, "cmds", got);
				KvSetNum(info, "expected", expected);
				if (SMAC_CheatDetected(i, Detection_SpeedLimit, info) == Plugin_Continue)
				{
					SMAC_PrintAdminNotice("%t", "SMAC_SpeedLimitDetected", i, g_iDetects[i]);
					SMAC_LogAction(i, "speed-limit anomaly (Detection #%i | cmds=%i expected=%i)", g_iDetects[i], got, expected);
					SMAC_UltraReact(i, g_iDetects[i], reaction, "Speed Limit Detection", "SMAC_SpeedLimitKick");
				}
				CloseHandle(info);
			}
		}
		else if (g_iAnomalies[i] > 0)
		{
			g_iAnomalies[i]--;
		}
	}
	return Plugin_Continue;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (GetConVarFloat(g_hCvarSpeedUp) <= 0.0 || GetConVarInt(g_hCvarLimit) == 0)
		return Plugin_Continue;
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	g_iCmdBucket[client]++;
	return Plugin_Continue;
}
