#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Spinhack Detector
 *
 * Stock SMAC spin + Ultr@-style optional thresholds (cfg docs referenced
 * ~900°/s sustained). Soft defaults keep stock behaviour.
 */

public Plugin:myinfo =
{
	name = "SMAC: Spinhack Detector",
	author = SMAC_AUTHOR,
	description = "Monitors players to detect the use of spinhacks",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define SPIN_SENSITIVITY	6

new Handle:g_hCvarAngle = INVALID_HANDLE;
new Handle:g_hCvarSeconds = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;

new Float:g_fPrevAngle[MAXPLAYERS+1];
new Float:g_fAngleDiff[MAXPLAYERS+1];
new Float:g_fAngleBuffer;
new Float:g_fSensitivity[MAXPLAYERS+1];

new g_iSpinCount[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	/* Stock SMAC: 1440° over 15s. Ultr@-leaning: try 900 / 5. */
	g_hCvarAngle = SMAC_CreateConVar("smac_spinhack_angle", "1440.0", "Yaw degrees summed per second before spin flag.", _, true, 360.0, true, 7200.0);
	g_hCvarSeconds = SMAC_CreateConVar("smac_spinhack_seconds", "15", "Consecutive spinning seconds before detect.", _, true, 3.0, true, 60.0);
	g_hCvarBan = SMAC_CreateConVar("smac_spinhack_ban", "0", "Detections before ban. (0 = Never — notice only)", _, true, 0.0);

	CreateTimer(1.0, Timer_CheckSpins, _, TIMER_REPEAT);
}

public OnClientDisconnect(client)
{
	g_iSpinCount[client] = 0;
	g_fSensitivity[client] = 0.0;
	g_iDetects[client] = 0;
}

public Action:Timer_CheckSpins(Handle:timer)
{
	new Float:needAngle = GetConVarFloat(g_hCvarAngle);
	new needSec = GetConVarInt(g_hCvarSeconds);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
			continue;

		if (g_fAngleDiff[i] > needAngle && IsPlayerAlive(i))
		{
			g_iSpinCount[i]++;

			if (g_iSpinCount[i] == 1)
				QueryClientConVar(i, "sensitivity", Query_MouseCheck, GetClientUserId(i));

			if (g_iSpinCount[i] >= needSec && g_fSensitivity[i] <= SPIN_SENSITIVITY)
			{
				g_iSpinCount[i] = 0;
				Spinhack_Detected(i);
			}
		}
		else
		{
			g_iSpinCount[i] = 0;
		}

		g_fAngleDiff[i] = 0.0;
	}

	return Plugin_Continue;
}

public Query_MouseCheck(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[], any:userid)
{
	if (result == ConVarQuery_Okay && GetClientOfUserId(userid) == client)
		g_fSensitivity[client] = StringToFloat(cvarValue);
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!(buttons & IN_LEFT || buttons & IN_RIGHT))
	{
		g_fAngleBuffer = FloatAbs(angles[1] - g_fPrevAngle[client]);
		g_fAngleDiff[client] += (g_fAngleBuffer > 180.0) ? (g_fAngleBuffer - 360.0) * -1.0 : g_fAngleBuffer;
		g_fPrevAngle[client] = angles[1];
	}

	return Plugin_Continue;
}

Spinhack_Detected(client)
{
	g_iDetects[client]++;
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iDetects[client]);
	if (SMAC_CheatDetected(client, Detection_Spinhack, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_SpinhackDetected", client);
		SMAC_LogAction(client, "is suspected of using a spinhack (Detection #%i).", g_iDetects[client]);
		new banAt = GetConVarInt(g_hCvarBan);
		if (banAt && g_iDetects[client] >= banAt)
			SMAC_Ban(client, "Spinhack Detection");
	}
	CloseHandle(info);
}
