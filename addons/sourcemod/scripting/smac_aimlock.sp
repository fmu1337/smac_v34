#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Aimlock Detector
 *
 * Core algorithm ported from Little Anti-Cheat (J_Tanzanite), GPL-3.0,
 * via Cheat-Acid GRAB: https://github.com/DJPlaya/Cheat-Acid
 *   → GRAB/Little Anti-Cheat + upstream lilac_aimlock.sp / lilac_stock.sp
 * Rewritten for SMAC v34 (old SourcePawn syntax, CSS v34).
 */

public Plugin:myinfo =
{
	name = "SMAC: Aimlock Detector",
	author = "J_Tanzanite, Danyas",
	description = "Detects aimlock (from LilAC via Cheat-Acid)",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define CMD_LENGTH		330
#define AIMLOCK_BAN_MIN	2

new Handle:g_hCvarBan = INVALID_HANDLE;
new g_iBanAt = 0;

new Float:g_fAngles[MAXPLAYERS+1][CMD_LENGTH][3];
new Float:g_fCmdTime[MAXPLAYERS+1][CMD_LENGTH];
new g_iIndex[MAXPLAYERS+1];
new Float:g_fTeleportIgnore[MAXPLAYERS+1];
new Float:g_fAimlockTime[MAXPLAYERS+1];
new g_iAimlockSus[MAXPLAYERS+1];
new g_iAimlockDet[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");
	g_hCvarBan = SMAC_CreateConVar("smac_aimlock_ban", "3", "Aimlock detections before ban. Minimum 2. (0 = Never ban)", _, true, 0.0);
	OnBanChanged(g_hCvarBan, "", "");
	HookConVarChange(g_hCvarBan, OnBanChanged);

	CreateTimer(0.5, Timer_CheckAimlock, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);
}

public OnBanChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	new v = GetConVarInt(convar);
	if (v > 0 && v < AIMLOCK_BAN_MIN)
	{
		SetConVarInt(convar, AIMLOCK_BAN_MIN);
		return;
	}
	g_iBanAt = v;
}

public OnClientPutInServer(client)
{
	g_iIndex[client] = 0;
	g_fTeleportIgnore[client] = 0.0;
	g_fAimlockTime[client] = 0.0;
	g_iAimlockSus[client] = 0;
	g_iAimlockDet[client] = 0;
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
		g_fTeleportIgnore[client] = GetGameTime() + 2.0;
}

public Teleport_OnEndTouch(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator) && IsClientConnected(activator))
		g_fTeleportIgnore[activator] = GetGameTime() + 2.0 + delay;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	new idx = g_iIndex[client];
	g_fAngles[client][idx][0] = angles[0];
	g_fAngles[client][idx][1] = angles[1];
	g_fAngles[client][idx][2] = angles[2];
	g_fCmdTime[client][idx] = GetGameTime();

	if (++g_iIndex[client] >= CMD_LENGTH)
		g_iIndex[client] = 0;

	return Plugin_Continue;
}

public Action:Timer_CheckAimlock(Handle:timer)
{
	new Float:pos[3], Float:pos2[3];
	new bool:detected[MAXPLAYERS+1];
	new processed = 0;

	for (new client = 1; client <= MaxClients; client++)
	{
		detected[client] = false;

		if (processed >= 5)
			continue;

		if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
			continue;
		if (GetClientTeam(client) < 2)
			continue;
		if (GetGameTime() - g_fTeleportIgnore[client] < 2.0)
			continue;
		if (GetClientAvgLoss(client, NetFlow_Both) > 0.5)
			continue;

		GetClientEyePosition(client, pos);
		processed++;

		new bool:process = true;
		for (new target = 1; process && target <= MaxClients; target++)
		{
			if (client == target || !IsClientInGame(target) || !IsPlayerAlive(target))
				continue;
			if (GetClientTeam(client) == GetClientTeam(target) || GetClientTeam(target) < 2)
				continue;
			if (GetGameTime() - g_fTeleportIgnore[target] < 2.0)
				continue;

			GetClientEyePosition(target, pos2);

			if (GetVectorDistance(pos, pos2) < 300.0)
			{
				detected[client] = false;
				process = false;
				continue;
			}

			if (detected[client])
				continue;

			if (IsAimlocking(client, pos, pos2))
				detected[client] = true;
		}
	}

	for (new i = 1; i <= MaxClients; i++)
	{
		if (detected[i])
			AimlockDetected(i);
	}

	return Plugin_Continue;
}

bool:IsAimlocking(client, const Float:pos[3], const Float:pos2[3])
{
	new Float:ideal[3], Float:lang[3], Float:ang[3];
	new Float:laimdist, Float:aimdist;
	new lock = 0;
	new ind = g_iIndex[client] - 1;
	new ticks = TimeToTicks(0.6);

	AimAtPoint(pos, pos2, ideal);

	for (new i = 0; i < ticks; i++)
	{
		if (ind < 0)
			ind += CMD_LENGTH;

		if (GetGameTime() - g_fCmdTime[client][ind] < 0.6)
		{
			ang[0] = g_fAngles[client][ind][0];
			ang[1] = g_fAngles[client][ind][1];
			ang[2] = 0.0;
			laimdist = AngleDelta(ang, ideal);

			if (i)
			{
				if (aimdist < 5.0)
					lock++;
				else
					lock = 0;

				if (aimdist < laimdist * 0.1
					&& AngleDelta(ang, lang) > 20.0
					&& lock > TimeToTicks(0.1))
					return true;
			}

			lang[0] = ang[0];
			lang[1] = ang[1];
			lang[2] = 0.0;
			aimdist = laimdist;
		}
		ind--;
	}
	return false;
}

AimlockDetected(client)
{
	if (GetGameTime() - g_fAimlockTime[client] < 180.0)
		g_iAimlockSus[client]++;
	else
		g_iAimlockSus[client] = 1;

	g_fAimlockTime[client] = GetGameTime();

	if (g_iAimlockSus[client] < 2)
		return;

	g_iAimlockSus[client] = 0;
	CreateTimer(600.0, Timer_DecrAimlock, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

	if (++g_iAimlockDet[client] < 2)
		return;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iAimlockDet[client]);

	if (SMAC_CheatDetected(client, Detection_Aimlock, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_AimlockDetected", client, g_iAimlockDet[client]);
		SMAC_LogAction(client, "is suspected of using an aimlock (Detection #%i).", g_iAimlockDet[client]);

		if (g_iBanAt && g_iAimlockDet[client] >= g_iBanAt)
		{
			SMAC_LogAction(client, "was banned for Aimlock.");
			SMAC_Ban(client, "Aimlock Detection");
		}
	}
	CloseHandle(info);
}

public Action:Timer_DecrAimlock(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	if (IS_CLIENT(client) && g_iAimlockDet[client] > 0)
		g_iAimlockDet[client]--;
	return Plugin_Stop;
}

/* --- LilAC stocks (J_Tanzanite) --- */

AimAtPoint(const Float:p1[3], const Float:p2[3], Float:writeto[3])
{
	SubtractVectors(p2, p1, writeto);
	GetVectorAngles(writeto, writeto);

	while (writeto[0] > 90.0) writeto[0] -= 360.0;
	while (writeto[0] < -90.0) writeto[0] += 360.0;
	while (writeto[1] > 180.0) writeto[1] -= 360.0;
	while (writeto[1] < -180.0) writeto[1] += 360.0;
	writeto[2] = 0.0;
}

Float:AngleDelta(const Float:a1[3], const Float:a2[3])
{
	new normal = 5;
	new Float:p1[3], Float:p2[3], Float:delta;

	p1[0] = a1[0];
	p1[1] = a1[1];
	p1[2] = 0.0;
	p2[0] = a2[0];
	p2[1] = a2[1];
	p2[2] = 0.0;

	delta = GetVectorDistance(p1, p2);
	while (delta > 180.0 && normal > 0)
	{
		normal--;
		delta = FloatAbs(delta - 360.0);
	}
	return delta;
}

TimeToTicks(Float:time)
{
	if (time > 0.0)
		return RoundToNearest(time / GetTickInterval());
	return 0;
}
