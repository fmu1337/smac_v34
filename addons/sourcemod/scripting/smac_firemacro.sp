#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Fire Macro / Fast AIM
 *
 * Original module by Danyas for SMAC v34.
 * Inspired by SMAC Ultra smac_method_2X_* and smac_Fast_AIM_Detect_* —
 * ATTACK2 spam on weapons that should not fire with +attack2, and
 * blink-aim snaps immediately followed by a shot.
 */

public Plugin:myinfo =
{
	name = "SMAC: Fire Macro / Fast AIM",
	author = SMAC_AUTHOR,
	description = "Detects +attack2 fire macros and snap-to-fire aim",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define ATK2_NEED		24
/* Fast-AIM = aimbot snap-to-fire. Distinguished from a human flick by:
   1) the turn is a single-tick teleport (>= SNAP_DEG in ONE usercmd),
   2) the tick before it was calm (< SNAP_CALM) — no human ramp-up,
   3) the view lands on an enemy and fires within SNAP_TICKS,
   4) it settles instantly (next tick < SNAP_CALM) — no human overshoot. */
#define SNAP_DEG		55.0
#define SNAP_CALM		8.0
#define SNAP_TICKS		2

new Handle:g_hCvarAtk2Ban = INVALID_HANDLE;
new Handle:g_hCvarFastBan = INVALID_HANDLE;
new Handle:g_hCvarAtk2 = INVALID_HANDLE;
new Handle:g_hCvarFast = INVALID_HANDLE;

new g_iAtk2Edges[MAXPLAYERS+1];
new Float:g_fAtk2Window[MAXPLAYERS+1];
new g_iAtk2Det[MAXPLAYERS+1];

new Float:g_fPrevAng[MAXPLAYERS+1][3];
new bool:g_bHaveAng[MAXPLAYERS+1];
new Float:g_fPrevDelta[MAXPLAYERS+1];
new g_iSnapLeft[MAXPLAYERS+1];
new bool:g_bSnapPending[MAXPLAYERS+1];
new g_iFastDet[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];

new Handle:g_hZoomWeapons = INVALID_HANDLE;

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarAtk2 = SMAC_CreateConVar("smac_fire_attack2", "1", "Detect +attack2 spam on non-zoom weapons (Ultra 2X).", _, true, 0.0, true, 1.0);
	g_hCvarAtk2Ban = SMAC_CreateConVar("smac_fire_attack2_ban", "0", "2X detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarFast = SMAC_CreateConVar("smac_fast_aim", "1", "Detect large aim snaps followed by fire.", _, true, 0.0, true, 1.0);
	g_hCvarFastBan = SMAC_CreateConVar("smac_fast_aim_ban", "0", "Fast-AIM detections before ban. (0 = Never)", _, true, 0.0);

	g_hZoomWeapons = CreateTrie();
	SetTrieValue(g_hZoomWeapons, "weapon_awp", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_scout", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_sg550", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_g3sg1", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_knife", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_usp", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_m4a1", 1); /* silencer */
	SetTrieValue(g_hZoomWeapons, "weapon_hegrenade", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_flashbang", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_smokegrenade", 1);
	SetTrieValue(g_hZoomWeapons, "weapon_c4", 1);
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
	g_iAtk2Edges[client] = 0;
	g_fAtk2Window[client] = 0.0;
	g_iAtk2Det[client] = 0;
	g_bHaveAng[client] = false;
	g_fPrevDelta[client] = 0.0;
	g_iSnapLeft[client] = 0;
	g_bSnapPending[client] = false;
	g_iFastDet[client] = 0;
	g_iPrevButtons[client] = 0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	if (GetConVarBool(g_hCvarAtk2))
		CheckAttack2Macro(client, buttons);

	if (GetConVarBool(g_hCvarFast))
		CheckFastAim(client, buttons, angles);

	g_iPrevButtons[client] = buttons;
	return Plugin_Continue;
}

CheckAttack2Macro(client, buttons)
{
	if (!((buttons & IN_ATTACK2) && !(g_iPrevButtons[client] & IN_ATTACK2)))
		return;

	new ent = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (ent <= MaxClients || !IsValidEdict(ent))
		return;

	decl String:cls[64], dummy;
	GetEdictClassname(ent, cls, sizeof(cls));
	if (GetTrieValue(g_hZoomWeapons, cls, dummy))
		return;

	new Float:now = GetGameTime();
	if (g_fAtk2Window[client] <= 0.0 || now - g_fAtk2Window[client] > 1.0)
	{
		g_fAtk2Window[client] = now;
		g_iAtk2Edges[client] = 0;
	}

	g_iAtk2Edges[client]++;
	if (g_iAtk2Edges[client] < ATK2_NEED)
		return;

	g_iAtk2Edges[client] = 0;
	g_iAtk2Det[client]++;
	FireDetect(client, Detection_Attack2Macro, g_iAtk2Det[client], g_hCvarAtk2Ban,
		"SMAC_Attack2MacroDetected", "attack2 fire macro (2X)");
}

CheckFastAim(client, buttons, const Float:angles[3])
{
	if (!g_bHaveAng[client])
	{
		g_fPrevAng[client][0] = angles[0];
		g_fPrevAng[client][1] = angles[1];
		g_bHaveAng[client] = true;
		return;
	}

	/* Dropped usercmds concatenate view movement into one big delta —
	   legit flick during a rate dip reads as a snap. Skip while lagging. */
	if (SMAC_IsClientLagging(client))
	{
		g_fPrevAng[client][0] = angles[0];
		g_fPrevAng[client][1] = angles[1];
		g_iSnapLeft[client] = 0;
		return;
	}

	new Float:dpitch = FloatAbs(angles[0] - g_fPrevAng[client][0]);
	new Float:dyaw = FloatAbs(angles[1] - g_fPrevAng[client][1]);
	if (dyaw > 180.0)
		dyaw = 360.0 - dyaw;
	new Float:delta = (dyaw > dpitch) ? dyaw : dpitch;

	new Float:prevDelta = g_fPrevDelta[client];
	g_fPrevDelta[client] = delta;
	g_fPrevAng[client][0] = angles[0];
	g_fPrevAng[client][1] = angles[1];

	/* An aimbot snap is one isolated tick: huge jump preceded by a calm
	   tick (no human ramp-up). A human flick ramps across several ticks,
	   so the tick before its peak is NOT calm. */
	new bool:isolatedSnap = (delta >= SNAP_DEG && prevDelta < SNAP_CALM);

	if (isolatedSnap)
	{
		g_iSnapLeft[client] = SNAP_TICKS;
		g_bSnapPending[client] = true;
	}
	else if (g_iSnapLeft[client] > 0)
	{
		g_iSnapLeft[client]--;

		/* Human overshoot: the ticks after a flick keep moving/correcting.
		   A cheat lands dead-on and stops — require the settle to be calm. */
		if (delta >= SNAP_CALM)
		{
			g_iSnapLeft[client] = 0;
			g_bSnapPending[client] = false;
		}
	}

	if (g_iSnapLeft[client] <= 0 || !g_bSnapPending[client])
		return;
	if (!((buttons & IN_ATTACK) && !(g_iPrevButtons[client] & IN_ATTACK)))
		return;

	/* The snap must land on an enemy — a flick into empty space then a shot
	   is just spray, not an aimbot lock. */
	if (!IsAimOnEnemy(client, angles))
		return;

	g_iSnapLeft[client] = 0;
	g_bSnapPending[client] = false;
	g_iFastDet[client]++;
	FireDetect(client, Detection_FastAim, g_iFastDet[client], g_hCvarFastBan,
		"SMAC_FastAimDetected", "fast aim snap-to-fire");
}

bool:IsAimOnEnemy(client, const Float:angles[3])
{
	decl Float:eyePos[3];
	GetClientEyePosition(client, eyePos);
	new Handle:trace = TR_TraceRayFilterEx(eyePos, angles, MASK_SHOT, RayType_Infinite, TraceFilter_NotSelf, client);
	new bool:onEnemy = false;
	if (TR_DidHit(trace))
	{
		new target = TR_GetEntityIndex(trace);
		if (IS_CLIENT(target) && IsClientInGame(target) && IsPlayerAlive(target)
			&& GetClientTeam(client) > 1 && GetClientTeam(target) != GetClientTeam(client))
		{
			onEnemy = true;
		}
	}
	CloseHandle(trace);
	return onEnemy;
}

public bool:TraceFilter_NotSelf(entity, contentsMask, any:client)
{
	return entity != client;
}

FireDetect(client, DetectionType:type, detects, Handle:hBanCvar, const String:phrase[], const String:logTag[])
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", detects);
	if (SMAC_CheatDetected(client, type, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", phrase, client, detects);
		SMAC_LogAction(client, "%s (Detection #%i)", logTag, detects);
		new banAt = GetConVarInt(hBanCvar);
		if (banAt && detects >= banAt)
		{
			SMAC_LogAction(client, "was banned for %s.", logTag);
			SMAC_Ban(client, "Fire Macro / Fast AIM Detection");
		}
	}
	CloseHandle(info);
}
