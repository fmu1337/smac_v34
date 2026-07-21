#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: SoundESP blocker / soft detect
 *
 * Original module by Danyas for SMAC v34.
 * Ultr@ smac_SoundESP idea without Ultr@Tools: strip enemy footstep /
 * weapon sounds for listeners who have no LOS (anti-SoundESP). Soft
 * "react" detect if a player turns toward an invisible firing enemy
 * within a tiny window (high FP → ban default 0).
 */

public Plugin:myinfo =
{
	name = "SMAC: SoundESP",
	author = SMAC_AUTHOR,
	description = "Block through-wall enemy sounds; soft SoundESP react",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarBlock = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;

new Float:g_fEnemyShotAt[MAXPLAYERS+1][MAXPLAYERS+1];
new Float:g_fLastYaw[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");
	g_hCvarBlock = SMAC_CreateConVar("smac_SoundESP_block", "1", "Strip enemy sounds with no LOS (SoundESP blocker).", _, true, 0.0, true, 1.0);
	g_hCvarBan = SMAC_CreateConVar("smac_SoundESP", "0", "Soft react detect. 0=off punish, -N=kick, +N=ban", _, true, -100.0, true, 100.0);

	AddNormalSoundHook(NormalSoundHook);
	HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
}

public OnClientPutInServer(client)
{
	g_iDetects[client] = 0;
	g_fLastYaw[client] = 0.0;
	new i;
	for (i = 0; i <= MaxClients; i++)
		g_fEnemyShotAt[client][i] = 0.0;
}

public Event_WeaponFire(Handle:event, const String:name[], bool:dontBroadcast)
{
	new shooter = GetClientOfUserId(GetEventInt(event, "userid"));
	if (!IS_CLIENT(shooter) || !IsClientInGame(shooter))
		return;

	new Float:now = GetGameTime();
	new i;
	for (i = 1; i <= MaxClients; i++)
	{
		if (i == shooter || !IsClientInGame(i) || IsFakeClient(i))
			continue;
		if (GetClientTeam(i) == GetClientTeam(shooter))
			continue;
		g_fEnemyShotAt[i][shooter] = now;
	}
}

public Action:NormalSoundHook(clients[64], &numClients, String:sample[PLATFORM_MAX_PATH], &entity, &channel, &Float:volume, &level, &pitch, &flags)
{
	if (!GetConVarBool(g_hCvarBlock))
		return Plugin_Continue;
	if (!IS_CLIENT(entity) || !IsClientInGame(entity))
		return Plugin_Continue;

	/* Footsteps / weapon fire only — avoid stripping all player VO. */
	if (StrContains(sample, "footsteps", false) == -1
		&& StrContains(sample, "weapons", false) == -1)
	{
		return Plugin_Continue;
	}

	new Float:origin[3];
	GetClientAbsOrigin(entity, origin);

	new write = 0;
	new i;
	for (i = 0; i < numClients; i++)
	{
		new listener = clients[i];
		if (!IS_CLIENT(listener) || !IsClientInGame(listener) || listener == entity)
		{
			clients[write++] = listener;
			continue;
		}
		if (GetClientTeam(listener) == GetClientTeam(entity))
		{
			clients[write++] = listener;
			continue;
		}
		if (HasLOS(listener, entity))
			clients[write++] = listener;
		/* else drop — no LOS enemy sound */
	}
	numClients = write;
	return (numClients > 0) ? Plugin_Changed : Plugin_Stop;
}

bool:HasLOS(listener, target)
{
	decl Float:a[3], Float:b[3];
	GetClientEyePosition(listener, a);
	GetClientEyePosition(target, b);
	new Handle:tr = TR_TraceRayFilterEx(a, b, MASK_VISIBLE, RayType_EndPoint, TraceFilter_Sound, listener);
	new bool:clear = !TR_DidHit(tr) || TR_GetEntityIndex(tr) == target;
	CloseHandle(tr);
	return clear;
}

public bool:TraceFilter_Sound(entity, contentsMask, any:listener)
{
	if (entity == listener)
		return false;
	if (IS_CLIENT(entity))
		return false;
	return true;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	new reaction = GetConVarInt(g_hCvarBan);
	if (reaction == 0)
	{
		g_fLastYaw[client] = angles[1];
		return Plugin_Continue;
	}
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	new Float:yawDelta = FloatAbs(angles[1] - g_fLastYaw[client]);
	if (yawDelta > 180.0)
		yawDelta = 360.0 - yawDelta;
	g_fLastYaw[client] = angles[1];

	if (yawDelta < 25.0)
		return Plugin_Continue;

	new Float:now = GetGameTime();
	new s;
	for (s = 1; s <= MaxClients; s++)
	{
		if (s == client || g_fEnemyShotAt[client][s] <= 0.0)
			continue;
		if ((now - g_fEnemyShotAt[client][s]) > 0.12)
			continue;
		if (!IsClientInGame(s) || !IsPlayerAlive(s))
			continue;
		if (HasLOS(client, s))
			continue;

		/* Turned hard toward recent invisible shooter. */
		decl Float:eye[3], Float:tgt[3], Float:fwd[3], Float:dir[3];
		GetClientEyePosition(client, eye);
		GetClientAbsOrigin(s, tgt);
		MakeVectorFromPoints(eye, tgt, dir);
		NormalizeVector(dir, dir);
		GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
		if (GetVectorDotProduct(fwd, dir) < 0.92)
			continue;

		g_iDetects[client]++;
		g_fEnemyShotAt[client][s] = 0.0;
		new Handle:info = CreateKeyValues("");
		KvSetNum(info, "detection", g_iDetects[client]);
		if (SMAC_CheatDetected(client, Detection_SoundESP, info) == Plugin_Continue)
		{
			SMAC_PrintAdminNotice("%t", "SMAC_SoundESPDetected", client, g_iDetects[client]);
			SMAC_LogAction(client, "soundesp-react (Detection #%i)", g_iDetects[client]);
			SMAC_UltraReact(client, g_iDetects[client], reaction, "SoundESP Detection", "SMAC_SoundESPKick");
		}
		CloseHandle(info);
		break;
	}
	return Plugin_Continue;
}
