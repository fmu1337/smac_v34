#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Aimsnap Detector
 *
 * Original module by Danyas for SMAC v34.
 * Algorithm rewritten from StAC aimsnapCheck (stephanie / sapphonie):
 * a large angular snap surrounded by near-zero "noise" deltas while
 * attacking. Soft ban default — high sensitivity FP risk.
 */

public Plugin:myinfo =
{
	name = "SMAC: Aimsnap Detector",
	author = SMAC_AUTHOR,
	description = "Detects aim snaps with quiet neighbor deltas (StAC-style)",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define HIST			5
#define SNAP_SIZE		10.0
#define NOISE_SIZE		0.5
#define NONZERO			0.001

new Handle:g_hCvarEnable = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;
new Handle:g_hCvarSnap = INVALID_HANDLE;

new Float:g_fAng[MAXPLAYERS+1][HIST][2];
new g_iButtons[MAXPLAYERS+1][3];
new g_iFilled[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarEnable = SMAC_CreateConVar("smac_aimsnap", "1", "Enable StAC-style aimsnap detector.", _, true, 0.0, true, 1.0);
	g_hCvarBan = SMAC_CreateConVar("smac_aimsnap_ban", "0", "Aimsnap detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarSnap = SMAC_CreateConVar("smac_aimsnap_deg", "10.0", "Minimum snap size in degrees.", _, true, 5.0, true, 90.0);

	HookEvent("player_spawn", Event_SpawnClear, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);
}

public OnClientPutInServer(client)
{
	ClearHist(client);
	g_iDetects[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
}

public OnClientDisconnect(client)
{
	ClearHist(client);
	g_iDetects[client] = 0;
}

public Event_SpawnClear(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		ClearHist(client);
		g_fIgnoreUntil[client] = GetGameTime() + 1.0;
	}
}

public Teleport_OnEndTouch(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator) && IsClientConnected(activator))
	{
		ClearHist(activator);
		g_fIgnoreUntil[activator] = GetGameTime() + 0.5 + delay;
	}
}

ClearHist(client)
{
	g_iFilled[client] = 0;
	for (new i = 0; i < HIST; i++)
	{
		g_fAng[client][i][0] = 0.0;
		g_fAng[client][i][1] = 0.0;
	}
	g_iButtons[client][0] = 0;
	g_iButtons[client][1] = 0;
	g_iButtons[client][2] = 0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!GetConVarBool(g_hCvarEnable))
		return Plugin_Continue;
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;
	if (GetGameTime() < g_fIgnoreUntil[client])
	{
		ClearHist(client);
		return Plugin_Continue;
	}

	/* Shift history: [0]=newest */
	for (new i = HIST - 1; i > 0; i--)
	{
		g_fAng[client][i][0] = g_fAng[client][i - 1][0];
		g_fAng[client][i][1] = g_fAng[client][i - 1][1];
	}
	g_fAng[client][0][0] = angles[0];
	g_fAng[client][0][1] = angles[1];

	g_iButtons[client][2] = g_iButtons[client][1];
	g_iButtons[client][1] = g_iButtons[client][0];
	g_iButtons[client][0] = buttons;

	if (g_iFilled[client] < HIST)
	{
		g_iFilled[client]++;
		return Plugin_Continue;
	}

	if (!(g_iButtons[client][0] & IN_ATTACK)
		&& !(g_iButtons[client][1] & IN_ATTACK)
		&& !(g_iButtons[client][2] & IN_ATTACK))
		return Plugin_Continue;

	new Float:aDiff[4];
	aDiff[0] = AngDelta(g_fAng[client][0], g_fAng[client][1]);
	aDiff[1] = AngDelta(g_fAng[client][1], g_fAng[client][2]);
	aDiff[2] = AngDelta(g_fAng[client][2], g_fAng[client][3]);
	aDiff[3] = AngDelta(g_fAng[client][3], g_fAng[client][4]);

	new Float:snapsize = GetConVarFloat(g_hCvarSnap);
	new useIdx = -1;

	/* Quiet-noisy-quiet-quiet around the snap (StAC patterns 1 and 2). */
	if (IsNoise(aDiff[0]) && aDiff[1] > snapsize && IsNoise(aDiff[2]) && IsNoise(aDiff[3]))
		useIdx = 1;
	else if (IsNoise(aDiff[0]) && IsNoise(aDiff[1]) && aDiff[2] > snapsize && IsNoise(aDiff[3]))
		useIdx = 2;

	if (useIdx < 0)
		return Plugin_Continue;

	g_iDetects[client]++;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iDetects[client]);
	KvSetFloat(info, "snap", aDiff[useIdx]);
	KvSetFloat(info, "d0", aDiff[0]);
	KvSetFloat(info, "d1", aDiff[1]);
	KvSetFloat(info, "d2", aDiff[2]);
	KvSetFloat(info, "d3", aDiff[3]);

	if (SMAC_CheatDetected(client, Detection_Aimsnap, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_AimsnapDetected", client, g_iDetects[client]);
		SMAC_LogAction(client, "aimsnap (Detection #%i | %.2f° idx=%d)",
			g_iDetects[client], aDiff[useIdx], useIdx);

		new banAt = GetConVarInt(g_hCvarBan);
		if (banAt && g_iDetects[client] >= banAt)
		{
			SMAC_LogAction(client, "was banned for aimsnap.");
			SMAC_Ban(client, "Aimsnap Detection");
		}
	}
	CloseHandle(info);
	return Plugin_Continue;
}

bool:IsNoise(Float:d)
{
	return (d < NOISE_SIZE && d > NONZERO);
}

Float:AngDelta(const Float:a[2], const Float:b[2])
{
	decl Float:va[3], Float:vb[3], Float:fa[3], Float:fb[3];
	fa[0] = a[0]; fa[1] = a[1]; fa[2] = 0.0;
	fb[0] = b[0]; fb[1] = b[1]; fb[2] = 0.0;
	GetAngleVectors(fa, va, NULL_VECTOR, NULL_VECTOR);
	GetAngleVectors(fb, vb, NULL_VECTOR, NULL_VECTOR);
	new Float:dot = (va[0] * vb[0]) + (va[1] * vb[1]) + (va[2] * vb[2]);
	if (dot > 1.0) dot = 1.0;
	if (dot < -1.0) dot = -1.0;
	return RadToDeg(ArcCosine(dot));
}
