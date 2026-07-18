#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Fake Lag Detector
 *
 * Original module by Danyas for SMAC v34.
 * Inspired by SMAC Ultra smac_FL_Ctrl / smac_DDoS_Ctrl — sustained packet
 * loss/choke above a threshold (fake lag scripts / cmd flooding).
 */

public Plugin:myinfo =
{
	name = "SMAC: Fake Lag Detector",
	author = SMAC_AUTHOR,
	description = "Detects sustained fake lag via loss/choke",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define STREAK_NEED		5

new Handle:g_hCvarLoss = INVALID_HANDLE;
new Handle:g_hCvarChoke = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;

new g_iLossStreak[MAXPLAYERS+1];
new g_iChokeStreak[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	/* 0 = off. Ultra used ~0.75 (75%) style thresholds via smac_FL_Ctrl. */
	g_hCvarLoss = SMAC_CreateConVar("smac_fakelag_loss", "0.0", "Avg loss (0-1) before streak. 0=off. Try 0.70-0.85.", _, true, 0.0, true, 1.0);
	g_hCvarChoke = SMAC_CreateConVar("smac_fakelag_choke", "0.0", "Avg choke (0-1) before streak. 0=off. Try 0.70-0.90.", _, true, 0.0, true, 1.0);
	g_hCvarBan = SMAC_CreateConVar("smac_fakelag_ban", "0", "Detections before ban. (0 = Never — kick only)", _, true, 0.0);

	CreateTimer(1.0, Timer_CheckLag, _, TIMER_REPEAT);
}

public OnClientPutInServer(client)
{
	g_iLossStreak[client] = 0;
	g_iChokeStreak[client] = 0;
	g_iDetects[client] = 0;
}

public Action:Timer_CheckLag(Handle:timer)
{
	new Float:lossLimit = GetConVarFloat(g_hCvarLoss);
	new Float:chokeLimit = GetConVarFloat(g_hCvarChoke);
	if (lossLimit <= 0.0 && chokeLimit <= 0.0)
		return Plugin_Continue;

	for (new client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || IsClientInKickQueue(client))
			continue;

		new bool:hit = false;
		new Float:loss = GetClientAvgLoss(client, NetFlow_Outgoing);
		new Float:choke = GetClientAvgChoke(client, NetFlow_Outgoing);

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
				FireLag(client, "loss", loss);
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
				FireLag(client, "choke", choke);
			}
		}
	}

	return Plugin_Continue;
}

FireLag(client, const String:kind[], Float:value)
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
		{
			SMAC_LogAction(client, "was banned for fake lag.");
			SMAC_Ban(client, "Fake Lag Detection");
		}
		else
		{
			KickClient(client, "%t", "SMAC_FakeLagKick");
		}
	}
	CloseHandle(info);
}
