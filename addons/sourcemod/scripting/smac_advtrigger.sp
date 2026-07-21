#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Advanced Trigger / Advanced Auto-Fire
 *
 * Original module by Danyas for SMAC v34.
 * Rewritten from SMAC Ultr@ R52 Global behaviour (smac_AdvancedTrigger_*,
 * smac_AdvancedAutoFire_*): weapon-tagged trigger aim vs pre-fire lock
 * while ray-locked on an enemy. Not a 1:1 dump.
 */

public Plugin:myinfo =
{
	name = "SMAC: Advanced Trigger / AutoFire",
	author = SMAC_AUTHOR,
	description = "Ultr@ Advanced Trigger and Advanced Auto-Fire detectors",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarTrigWarn = INVALID_HANDLE;
new Handle:g_hCvarTrigBan = INVALID_HANDLE;
new Handle:g_hCvarFireWarn = INVALID_HANDLE;
new Handle:g_hCvarFireBan = INVALID_HANDLE;

/* Auto-Fire lock quality gates: the target must actually traverse the view
   (angular path) while the crosshair tracks it with low average error.
   Spraying into the back of a target running straight away produces a near
   zero path and must never count — that is normal chase spray. */
#define LOCK_MIN_PATH	12.0
#define LOCK_MAX_AVGERR	2.0

new g_iTicksOnTarget[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];
new bool:g_bWasOnEnemy[MAXPLAYERS+1];
new g_iTrigShots[MAXPLAYERS+1];
new g_iTrigDet[MAXPLAYERS+1];
new g_iPrefireHold[MAXPLAYERS+1];
new g_iFireHits[MAXPLAYERS+1];
new g_iFireDet[MAXPLAYERS+1];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];

new g_iLockTarget[MAXPLAYERS+1];
new Float:g_fLockPath[MAXPLAYERS+1];
new Float:g_fLockErrSum[MAXPLAYERS+1];
new Float:g_fLockPrevDir[MAXPLAYERS+1][2];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	/* Soft defaults — Ultr@ pub often uses high warn/ban; we stay notice-first. */
	g_hCvarTrigWarn = SMAC_CreateConVar("smac_AdvancedTrigger_Warning", "8", "Advanced Trigger detections before admin notice. (0 = Never)", _, true, 0.0);
	g_hCvarTrigBan = SMAC_CreateConVar("smac_AdvancedTrigger_Ban", "0", "Advanced Trigger reaction. 0=off kick/ban, -N=kick, +N=ban", _, true, -100.0, true, 100.0);
	g_hCvarFireWarn = SMAC_CreateConVar("smac_AdvancedAutoFire_Warning", "6", "Advanced AutoFire detections before admin notice. (0 = Never)", _, true, 0.0);
	g_hCvarFireBan = SMAC_CreateConVar("smac_AdvancedAutoFire_Ban", "0", "Advanced AutoFire reaction. 0=off, -N=kick, +N=ban", _, true, -100.0, true, 100.0);

	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);
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
	g_iTicksOnTarget[client] = 0;
	g_iPrevButtons[client] = 0;
	g_bWasOnEnemy[client] = false;
	g_iTrigShots[client] = 0;
	g_iTrigDet[client] = 0;
	g_iPrefireHold[client] = 0;
	g_iFireHits[client] = 0;
	g_iFireDet[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
	g_iLockTarget[client] = 0;
	g_fLockPath[client] = 0.0;
	g_fLockErrSum[client] = 0.0;
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_iTicksOnTarget[client] = 0;
		g_iPrefireHold[client] = 0;
		g_bWasOnEnemy[client] = false;
		g_fIgnoreUntil[client] = GetGameTime() + 1.5;
	}
}

public Teleport_OnEndTouch(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator) && IsClientConnected(activator))
	{
		g_iTicksOnTarget[activator] = 0;
		g_iPrefireHold[activator] = 0;
		g_bWasOnEnemy[activator] = false;
		g_fIgnoreUntil[activator] = GetGameTime() + 0.5 + delay;
	}
}

bool:IsEnemyUnderCrosshair(client, const Float:angles[3], String:weapon[], maxlen, &enemy)
{
	weapon[0] = '\0';
	enemy = 0;
	decl Float:eyePos[3];
	GetClientEyePosition(client, eyePos);

	new Handle:trace = TR_TraceRayFilterEx(eyePos, angles, MASK_SHOT, RayType_Infinite, TraceFilter_Adv, client);
	new bool:hit = false;
	if (TR_DidHit(trace))
	{
		new target = TR_GetEntityIndex(trace);
		if (IS_CLIENT(target) && IsClientInGame(target) && IsPlayerAlive(target)
			&& GetClientTeam(target) != GetClientTeam(client) && GetClientTeam(client) > 1)
		{
			hit = true;
			enemy = target;
		}
	}
	CloseHandle(trace);

	new wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (wep > MaxClients && IsValidEntity(wep))
		GetEntityClassname(wep, weapon, maxlen);

	return hit;
}

public bool:TraceFilter_Adv(entity, contentsMask, any:client)
{
	return entity != client;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	if (GetGameTime() < g_fIgnoreUntil[client])
	{
		g_iPrevButtons[client] = buttons;
		g_iTicksOnTarget[client] = 0;
		g_iPrefireHold[client] = 0;
		g_bWasOnEnemy[client] = false;
		return Plugin_Continue;
	}

	decl String:wpn[64];
	new enemy;
	new bool:onEnemy = IsEnemyUnderCrosshair(client, angles, wpn, sizeof(wpn), enemy);

	/* Skip knives / nades — Ultr@ tags weapon on gun triggers. */
	if (wpn[0] && (StrContains(wpn, "knife") != -1 || StrContains(wpn, "grenade") != -1
		|| StrContains(wpn, "flashbang") != -1 || StrContains(wpn, "smoke") != -1 || StrContains(wpn, "c4") != -1))
	{
		g_iPrevButtons[client] = buttons;
		g_iTicksOnTarget[client] = 0;
		g_iPrefireHold[client] = 0;
		g_bWasOnEnemy[client] = false;
		return Plugin_Continue;
	}

	new bool:atk = (buttons & IN_ATTACK) != 0;
	new bool:wasAtk = (g_iPrevButtons[client] & IN_ATTACK) != 0;
	new bool:atkEdge = atk && !wasAtk;
	new bool:acquireEdge = onEnemy && !g_bWasOnEnemy[client];

	if (onEnemy)
		g_iTicksOnTarget[client]++;
	else
		g_iTicksOnTarget[client] = 0;

	/* Advanced Trigger: fire edge on first tick of acquire (tick-perfect). */
	if (atkEdge && onEnemy && g_iTicksOnTarget[client] <= 1)
	{
		g_iTrigShots[client]++;
		if (g_iTrigShots[client] >= 6)
		{
			g_iTrigShots[client] = 0;
			g_iTrigDet[client]++;
			MaybeReactTrigger(client, wpn);
		}
	}

	/*
	 * Advanced Auto-Fire: already holding fire when first acquiring an enemy,
	 * then stay locked ~0.25s. Legit spray aims first then holds — not this.
	 */
	new holdNeed = RoundToNearest(0.25 / GetTickInterval());
	if (holdNeed < 8)
		holdNeed = 8;

	if (acquireEdge && atk && wasAtk)
	{
		/* Prefire into acquire — start candidate window. */
		g_iPrefireHold[client] = 1;
		BeginLockTrack(client, enemy, angles);
	}
	else if (g_iPrefireHold[client] > 0 && atk && onEnemy && enemy == g_iLockTarget[client])
	{
		g_iPrefireHold[client]++;
		TrackLock(client, enemy, angles);

		if (g_iPrefireHold[client] >= holdNeed)
		{
			/* Only an aimbot LOCK counts: the target visibly traversed the
			   view (angular path) while the crosshair tracked it with tiny
			   average error. Chase-spraying a straight-running back gives a
			   near-zero path and legit tracking gives a bigger error. */
			new Float:avgErr = g_fLockErrSum[client] / float(g_iPrefireHold[client]);
			g_iPrefireHold[client] = 0;

			if (g_fLockPath[client] >= LOCK_MIN_PATH && avgErr <= LOCK_MAX_AVGERR)
			{
				g_iFireHits[client]++;
				if (g_iFireHits[client] >= 3)
				{
					g_iFireHits[client] = 0;
					g_iFireDet[client]++;
					MaybeReactFire(client, wpn);
				}
			}
		}
	}
	else
	{
		g_iPrefireHold[client] = 0;
		g_iLockTarget[client] = 0;
	}

	g_bWasOnEnemy[client] = onEnemy;
	g_iPrevButtons[client] = buttons;
	return Plugin_Continue;
}

BeginLockTrack(client, enemy, const Float:angles[3])
{
	g_iLockTarget[client] = enemy;
	g_fLockPath[client] = 0.0;
	g_fLockErrSum[client] = 0.0;
	if (IS_CLIENT(enemy))
	{
		decl Float:dir[2];
		DirToTarget(client, enemy, dir);
		g_fLockPrevDir[client][0] = dir[0];
		g_fLockPrevDir[client][1] = dir[1];
		g_fLockErrSum[client] = AimError(angles, dir);
	}
}

TrackLock(client, enemy, const Float:angles[3])
{
	if (!IS_CLIENT(enemy) || !IsClientInGame(enemy))
		return;

	decl Float:dir[2];
	DirToTarget(client, enemy, dir);

	/* Angular path of the target across the shooter's view. */
	g_fLockPath[client] += FloatAbs(AngleDiff(dir[0], g_fLockPrevDir[client][0]))
		+ FloatAbs(AngleDiff(dir[1], g_fLockPrevDir[client][1]));
	g_fLockPrevDir[client][0] = dir[0];
	g_fLockPrevDir[client][1] = dir[1];

	g_fLockErrSum[client] += AimError(angles, dir);
}

DirToTarget(client, target, Float:dir[2])
{
	decl Float:eye[3], Float:tgt[3], Float:v[3];
	GetClientEyePosition(client, eye);
	GetClientEyePosition(target, tgt);
	MakeVectorFromPoints(eye, tgt, v);
	GetVectorAngles(v, v);
	dir[0] = v[0];
	dir[1] = v[1];
}

Float:AimError(const Float:angles[3], const Float:dir[2])
{
	return FloatAbs(AngleDiff(angles[0], dir[0])) + FloatAbs(AngleDiff(angles[1], dir[1]));
}

Float:AngleDiff(Float:a, Float:b)
{
	new Float:d = a - b;
	while (d > 180.0) d -= 360.0;
	while (d < -180.0) d += 360.0;
	return d;
}

MaybeReactTrigger(client, const String:wpn[])
{
	new warnAt = GetConVarInt(g_hCvarTrigWarn);
	new reaction = GetConVarInt(g_hCvarTrigBan);
	if (reaction == 0 && warnAt == 0)
		return;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iTrigDet[client]);
	KvSetString(info, "weapon", wpn);
	if (SMAC_CheatDetected(client, Detection_AdvancedTrigger, info) == Plugin_Continue)
	{
		if (warnAt && g_iTrigDet[client] >= warnAt)
			SMAC_PrintAdminNotice("%t", "SMAC_AdvancedTriggerDetected", client, g_iTrigDet[client], wpn);
		SMAC_LogAction(client, "advanced trigger (Detection #%i | Weapon: %s)", g_iTrigDet[client], wpn);
		if (SMAC_UltraReact(client, g_iTrigDet[client], reaction, "Advanced Trigger Detection", "SMAC_AdvancedTriggerKick"))
			SMAC_LogAction(client, "was punished for advanced trigger.");
	}
	CloseHandle(info);
}

MaybeReactFire(client, const String:wpn[])
{
	new warnAt = GetConVarInt(g_hCvarFireWarn);
	new reaction = GetConVarInt(g_hCvarFireBan);
	if (reaction == 0 && warnAt == 0)
		return;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iFireDet[client]);
	KvSetString(info, "weapon", wpn);
	if (SMAC_CheatDetected(client, Detection_AdvancedAutoFire, info) == Plugin_Continue)
	{
		if (warnAt && g_iFireDet[client] >= warnAt)
			SMAC_PrintAdminNotice("%t", "SMAC_AdvancedAutoFireDetected", client, g_iFireDet[client], wpn);
		SMAC_LogAction(client, "advanced autofire (Detection #%i | Weapon: %s)", g_iFireDet[client], wpn);
		if (SMAC_UltraReact(client, g_iFireDet[client], reaction, "Advanced AutoFire Detection", "SMAC_AdvancedAutoFireKick"))
			SMAC_LogAction(client, "was punished for advanced autofire.");
	}
	CloseHandle(info);
}
