#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Backtrack / Cmdnum Abuse
 *
 * Original module by Danyas for SMAC v34.
 * Inspired by:
 *   - SMAC Ultra Backtrack Exploit-Mode:A (detect) / Mode:B (mitigate)
 *   - Lilac / Jay's Backtrack Patch (tickcount lock while in timeout)
 *   - StAC cmdnum-spike check (nospread cmdnum skip)
 * Soft defaults — Mode A ban off; Mode B patch on with tolerance 1.
 */

public Plugin:myinfo =
{
	name = "SMAC: Backtrack / Cmdnum Abuse",
	author = SMAC_AUTHOR,
	description = "Detects/patches tickcount backtrack and cmdnum spikes",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define TIMEOUT_SEC		1.1
#define TELEPORT_GRACE	2.0
#define UNLAG_WINDOW	0.2

new Handle:g_hCvarMode = INVALID_HANDLE;
new Handle:g_hCvarTol = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;
new Handle:g_hCvarSpike = INVALID_HANDLE;
new Handle:g_hCvarSpikeBan = INVALID_HANDLE;

new g_iPrevTick[MAXPLAYERS+1];
new g_iBufTick[MAXPLAYERS+1];
new g_iDiffTick[MAXPLAYERS+1];
new Float:g_fTimeoutUntil[MAXPLAYERS+1];
new Float:g_fTeleportUntil[MAXPLAYERS+1];
new g_iBackDet[MAXPLAYERS+1];

new g_iLastCmd[MAXPLAYERS+1];
new g_iSpikeDet[MAXPLAYERS+1];

new g_iBacktrackTicks;

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	/* 0=off 1=Mode A detect 2=Mode B patch 3=both (Ultra A+B). */
	g_hCvarMode = SMAC_CreateConVar("smac_backtrack_mode", "3", "0=off 1=detect(A) 2=patch(B) 3=both", _, true, 0.0, true, 3.0);
	g_hCvarTol = SMAC_CreateConVar("smac_backtrack_tolerance", "1", "Allowed tickcount drift (0=strict, max 3).", _, true, 0.0, true, 3.0);
	g_hCvarBan = SMAC_CreateConVar("smac_backtrack_ban", "0", "Mode-A detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarSpike = SMAC_CreateConVar("smac_cmdspike_delta", "32", "Abs cmdnum jump to flag (StAC-style). 0=off.", _, true, 0.0);
	g_hCvarSpikeBan = SMAC_CreateConVar("smac_cmdspike_ban", "0", "Cmdnum-spike detections before ban. (0 = Never)", _, true, 0.0);
	/* Ultr@ alias: Advanced eyetest reaction maps to Mode-A ban threshold soft gate. */
	SMAC_CreateConVar("smac_eyetest_reaction_Advanced", "0", "Ultr@ alias (Backtrack A/B). 0=off soft, 1=notice-oriented, 2=kick-ish, 3=use ban cvar", _, true, 0.0, true, 3.0);

	g_iBacktrackTicks = RoundToNearest(UNLAG_WINDOW / GetTickInterval());
	if (g_iBacktrackTicks < 1)
		g_iBacktrackTicks = 1;

	HookEvent("player_spawn", Event_SpawnGrace, EventHookMode_Post);
	HookEvent("player_death", Event_SpawnGrace, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);
}

public OnMapStart()
{
	g_iBacktrackTicks = RoundToNearest(UNLAG_WINDOW / GetTickInterval());
	if (g_iBacktrackTicks < 1)
		g_iBacktrackTicks = 1;
}

public OnClientPutInServer(client)
{
	ResetClient(client);
}

public OnClientDisconnect(client)
{
	ResetClient(client);
}

ResetClient(client)
{
	g_iPrevTick[client] = 0;
	g_iBufTick[client] = 0;
	g_iDiffTick[client] = 0;
	g_fTimeoutUntil[client] = 0.0;
	g_fTeleportUntil[client] = 0.0;
	g_iBackDet[client] = 0;
	g_iLastCmd[client] = 0;
	g_iSpikeDet[client] = 0;
}

public Event_SpawnGrace(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
		g_fTeleportUntil[client] = GetGameTime() + TELEPORT_GRACE;
}

public Teleport_OnEndTouch(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator) && IsClientConnected(activator) && !IsFakeClient(activator))
		g_fTeleportUntil[activator] = GetGameTime() + TELEPORT_GRACE + delay;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	CheckCmdSpike(client, cmdnum);

	new mode = GetConVarInt(g_hCvarMode);
	if (mode <= 0)
	{
		StoreTick(client, tickcount);
		return Plugin_Continue;
	}

	StoreTick(client, tickcount);

	if (GetGameTime() < g_fTeleportUntil[client])
		return Plugin_Continue;

	if (!ValidTick(client, tickcount) && GetGameTime() >= g_fTimeoutUntil[client])
	{
		EnterTimeout(client);

		/* Tick rollback is normal during loss/choke — keep the Mode-B patch
		   active but don't count it as a Mode-A detection. */
		if ((mode == 1 || mode == 3) && !SMAC_IsClientLagging(client))
			FireBacktrack(client, tickcount);
	}

	if ((mode == 2 || mode == 3) && GetGameTime() < g_fTimeoutUntil[client])
	{
		tickcount = SimulateTick(client);
		return Plugin_Changed;
	}

	return Plugin_Continue;
}

StoreTick(client, tickcount)
{
	g_iPrevTick[client] = g_iBufTick[client];
	g_iBufTick[client] = tickcount;
}

bool:ValidTick(client, tickcount)
{
	new expected = g_iPrevTick[client] + 1;
	new delta = expected - tickcount;
	if (delta < 0)
		delta = -delta;
	return (delta <= GetConVarInt(g_hCvarTol));
}

EnterTimeout(client)
{
	g_fTimeoutUntil[client] = GetGameTime() + TIMEOUT_SEC;

	new ping = RoundToNearest(GetClientAvgLatency(client, NetFlow_Outgoing) / GetTickInterval());
	new tick = GetGameTickCount() - ping;
	g_iDiffTick[client] = (g_iPrevTick[client] - tick) + 1;

	new hi = g_iBacktrackTicks - 3;
	new lo = -(g_iBacktrackTicks) + 3;
	if (hi < 1) hi = 1;
	if (g_iDiffTick[client] > hi)
		g_iDiffTick[client] = hi;
	else if (g_iDiffTick[client] < lo)
		g_iDiffTick[client] = lo;
}

SimulateTick(client)
{
	new ping = RoundToNearest(GetClientAvgLatency(client, NetFlow_Outgoing) / GetTickInterval());
	new tick = g_iDiffTick[client] + (GetGameTickCount() - ping);
	new server = GetGameTickCount();
	if (tick > server)
		tick = server;
	return tick;
}

FireBacktrack(client, tickcount)
{
	g_iBackDet[client]++;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iBackDet[client]);
	KvSetNum(info, "tickcount", tickcount);
	KvSetNum(info, "prevtickcount", g_iPrevTick[client]);
	KvSetNum(info, "gametickcount", GetGameTickCount());

	if (SMAC_CheatDetected(client, Detection_Backtrack, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_BacktrackDetected", client, g_iBackDet[client]);
		SMAC_LogAction(client, "backtrack Mode:A (Detection #%i | tick %d→%d server=%d)",
			g_iBackDet[client], g_iPrevTick[client], tickcount, GetGameTickCount());

		new banAt = GetConVarInt(g_hCvarBan);
		if (banAt && g_iBackDet[client] >= banAt)
		{
			SMAC_LogAction(client, "was banned for backtrack exploit.");
			SMAC_Ban(client, "Backtrack Exploit Detection");
		}
	}
	CloseHandle(info);
}

CheckCmdSpike(client, cmdnum)
{
	new thresh = GetConVarInt(g_hCvarSpike);
	if (thresh <= 0)
	{
		g_iLastCmd[client] = cmdnum;
		return;
	}

	/* Nullcmd / reset — ignore like StAC. */
	if (cmdnum == 0 && g_iLastCmd[client] == 0)
		return;

	if (g_iLastCmd[client] > 0 && cmdnum > 0)
	{
		new spike = cmdnum - g_iLastCmd[client];
		if (spike >= thresh || spike <= -thresh)
		{
			g_iSpikeDet[client]++;

			new Handle:info = CreateKeyValues("");
			KvSetNum(info, "detection", g_iSpikeDet[client]);
			KvSetNum(info, "spike", spike);
			KvSetNum(info, "cmdnum", cmdnum);
			KvSetNum(info, "prevcmdnum", g_iLastCmd[client]);

			if (SMAC_CheatDetected(client, Detection_CmdnumSpike, info) == Plugin_Continue)
			{
				SMAC_PrintAdminNotice("%t", "SMAC_CmdnumSpikeDetected", client, g_iSpikeDet[client]);
				SMAC_LogAction(client, "cmdnum spike (Detection #%i | delta=%d)", g_iSpikeDet[client], spike);

				new banAt = GetConVarInt(g_hCvarSpikeBan);
				if (banAt && g_iSpikeDet[client] >= banAt)
				{
					SMAC_LogAction(client, "was banned for cmdnum spike.");
					SMAC_Ban(client, "Cmdnum Spike Detection");
				}
			}
			CloseHandle(info);
		}
	}

	g_iLastCmd[client] = cmdnum;
}
