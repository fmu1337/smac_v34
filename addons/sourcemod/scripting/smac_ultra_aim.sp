#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

#undef REQUIRE_PLUGIN
#include <smac_wallhack>
#define REQUIRE_PLUGIN

/*
 * SMAC: Ultra Aim (restored)
 *
 * Original module by Danyas for SMAC v34.
 *
 * Restored from SMAC Ultra (Ultr@) R52 Global.smx after decompressing the
 * FFPS image and recovering plaintext detection labels + dbg symbols +
 * Accurate_Analysis_Module float thresholds from Lysis dumps:
 *
 *   Pass.Mode:301-304          → Passive Route Guidance (PRG)
 *   Mode 288/299               → Automatic Guidance (AGT) while firing
 *   Mode 88/99/108/109         → Automatic Guidance After Firing (AGTAF)
 *   Mode 188/199               → Trigger aim
 *   Mode 200/201               → Null-Level guidance (AGTNL)
 *   Mode 100                   → Guidance while spraying (AGTWS)
 *   Mode 101                   → Analysis Module After Firing (AMSAF)
 *   Recoil Control System -H/F → perfect RCS compensation
 *
 * Not a bytecode 1:1 port (control-flow remains obfuscated); algorithms are
 * reconstructed from recovered strings, symbols (g_fAngleDiff, FireAng,
 * iTarget, AIM_Sens, g_bIsVisible) and threshold constants (0.4 / 0.6 / 2.0°
 * bands, mode-id floats 188.88 / 200 / 288.88 / 299.99 / 301.99).
 */

public Plugin:myinfo =
{
	name = "SMAC: Ultra Aim (Restored)",
	author = SMAC_AUTHOR,
	description = "Restored Ultr@ advanced aim modes (PRG/AGT/AGTAF/Tr/RCS)",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define HISTORY			32
#define SNAP_TICKS		5
#define PRG_STREAK		48
#define AGT_STREAK		36
#define AGTAF_WINDOW	0.35
#define TRIGGER_FOV		3.0
#define NULL_MOUSE		2
#define RCS_STREAK		12

new Handle:g_hCvarPrgBan = INVALID_HANDLE;
new Handle:g_hCvarAgtBan = INVALID_HANDLE;
new Handle:g_hCvarAgtafBan = INVALID_HANDLE;
new Handle:g_hCvarTrigBan = INVALID_HANDLE;
new Handle:g_hCvarNullBan = INVALID_HANDLE;
new Handle:g_hCvarRcsBan = INVALID_HANDLE;
new Handle:g_hCvarEnabled = INVALID_HANDLE;

new bool:g_bWhNative = false;

new Float:g_fPrevAng[MAXPLAYERS+1][3];
new bool:g_bHaveAng[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];
new g_iPrevMouse[MAXPLAYERS+1][2];

new g_iPrgStreak[MAXPLAYERS+1];
new g_iAgtStreak[MAXPLAYERS+1];
new g_iRcsStreak[MAXPLAYERS+1];
new Float:g_fLastPunch[MAXPLAYERS+1][3];
new bool:g_bHavePunch[MAXPLAYERS+1];

new Float:g_fLastFire[MAXPLAYERS+1];
new Float:g_fFireAng[MAXPLAYERS+1][3];
new g_iSnapLeft[MAXPLAYERS+1];

new g_iPrgDet[MAXPLAYERS+1];
new g_iAgtDet[MAXPLAYERS+1];
new g_iAgtafDet[MAXPLAYERS+1];
new g_iTrigDet[MAXPLAYERS+1];
new g_iNullDet[MAXPLAYERS+1];
new g_iRcsDet[MAXPLAYERS+1];

new Float:g_fIgnoreUntil[MAXPLAYERS+1];

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	MarkNativeAsOptional("SMAC_IsClientVisible");
	return APLRes_Success;
}

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarEnabled = SMAC_CreateConVar("smac_ultra_aim", "1", "Enable restored Ultr@ advanced aim detectors.", _, true, 0.0, true, 1.0);
	/* Soft defaults — Ultra shipped aggressive bans; we log first. */
	g_hCvarPrgBan = SMAC_CreateConVar("smac_ultra_prg_ban", "0", "PRG (Pass.Mode 30x) detections before ban. (0=Never)", _, true, 0.0);
	g_hCvarAgtBan = SMAC_CreateConVar("smac_ultra_agt_ban", "0", "AGT (Mode 288/299) detections before ban. (0=Never)", _, true, 0.0);
	g_hCvarAgtafBan = SMAC_CreateConVar("smac_ultra_agtaf_ban", "0", "AGTAF (Mode 88/99) detections before ban. (0=Never)", _, true, 0.0);
	g_hCvarTrigBan = SMAC_CreateConVar("smac_ultra_trigger_ban", "0", "Trigger-aim (Mode 188/199) detections before ban. (0=Never)", _, true, 0.0);
	g_hCvarNullBan = SMAC_CreateConVar("smac_ultra_null_ban", "0", "Null-level aim (Mode 200) detections before ban. (0=Never)", _, true, 0.0);
	g_hCvarRcsBan = SMAC_CreateConVar("smac_ultra_rcs_ban", "0", "Perfect RCS detections before ban. (0=Never)", _, true, 0.0);

	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
	HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);

	g_bWhNative = (GetFeatureStatus(FeatureType_Native, "SMAC_IsClientVisible") == FeatureStatus_Available);
}

public OnAllPluginsLoaded()
{
	g_bWhNative = (GetFeatureStatus(FeatureType_Native, "SMAC_IsClientVisible") == FeatureStatus_Available);
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
	g_bHaveAng[client] = false;
	g_bHavePunch[client] = false;
	g_iPrevButtons[client] = 0;
	g_iPrevMouse[client][0] = 0;
	g_iPrevMouse[client][1] = 0;
	g_iPrgStreak[client] = 0;
	g_iAgtStreak[client] = 0;
	g_iRcsStreak[client] = 0;
	g_iSnapLeft[client] = 0;
	g_fLastFire[client] = 0.0;
	g_iPrgDet[client] = 0;
	g_iAgtDet[client] = 0;
	g_iAgtafDet[client] = 0;
	g_iTrigDet[client] = 0;
	g_iNullDet[client] = 0;
	g_iRcsDet[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_bHaveAng[client] = false;
		g_bHavePunch[client] = false;
		g_fIgnoreUntil[client] = GetGameTime() + 1.5;
	}
}

public Teleport_OnEndTouch(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator) && IsClientConnected(activator))
	{
		g_bHaveAng[activator] = false;
		g_fIgnoreUntil[activator] = GetGameTime() + 0.5 + delay;
	}
}

public Event_WeaponFire(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (!IS_CLIENT(client) || !IsClientInGame(client))
		return;

	g_fLastFire[client] = GetGameTime();
	GetClientEyeAngles(client, g_fFireAng[client]);
	g_iSnapLeft[client] = SNAP_TICKS;
}

public Event_PlayerHurt(Handle:event, const String:name[], bool:dontBroadcast)
{
	/* Advanced_Eye_Angle_Test_Hurt idea — snap onto victim on hurt tick. */
	if (!GetConVarBool(g_hCvarEnabled))
		return;

	new victim = GetClientOfUserId(GetEventInt(event, "userid"));
	new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	if (!IS_CLIENT(attacker) || !IS_CLIENT(victim) || attacker == victim)
		return;
	if (!IsClientInGame(attacker) || !IsPlayerAlive(attacker) || IsFakeClient(attacker))
		return;
	if (GetGameTime() < g_fIgnoreUntil[attacker])
		return;

	decl Float:eye[3], Float:tgt[3], Float:ang[3], Float:toTarget[3];
	GetClientEyePosition(attacker, eye);
	GetClientEyePosition(victim, tgt);
	GetClientEyeAngles(attacker, ang);
	MakeVectorFromPoints(eye, tgt, toTarget);
	GetVectorAngles(toTarget, toTarget);

	new Float:dyaw = FloatAbs(AngleDiff(ang[1], toTarget[1]));
	new Float:dpitch = FloatAbs(AngleDiff(ang[0], toTarget[0]));
	if (dyaw > TRIGGER_FOV || dpitch > TRIGGER_FOV)
		return;

	/* Hurt with FOV lock + recent fire snap → AGTAF-style. */
	if (GetGameTime() - g_fLastFire[attacker] <= AGTAF_WINDOW)
	{
		new Float:snap = FloatAbs(AngleDiff(ang[1], g_fFireAng[attacker][1]));
		if (snap >= 2.0 && snap <= 60.0)
		{
			g_iAgtafDet[attacker]++;
			FireDetect(attacker, Detection_UltraAGTAF, g_iAgtafDet[attacker], g_hCvarAgtafBan,
				"SMAC_UltraAGTAFDetected", "AGTAF Mode:88/99 (guidance after firing)", snap);
		}
	}
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!GetConVarBool(g_hCvarEnabled))
		return Plugin_Continue;
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;
	if (GetGameTime() < g_fIgnoreUntil[client])
	{
		g_bHaveAng[client] = false;
		g_iPrevButtons[client] = buttons;
		return Plugin_Continue;
	}
	if ((buttons & IN_LEFT) || (buttons & IN_RIGHT))
	{
		g_iPrgStreak[client] = 0;
		g_iAgtStreak[client] = 0;
		g_bHaveAng[client] = false;
		g_iPrevButtons[client] = buttons;
		return Plugin_Continue;
	}

	if (!g_bHaveAng[client])
	{
		g_fPrevAng[client][0] = angles[0];
		g_fPrevAng[client][1] = angles[1];
		g_bHaveAng[client] = true;
		g_iPrevButtons[client] = buttons;
		g_iPrevMouse[client][0] = mouse[0];
		g_iPrevMouse[client][1] = mouse[1];
		return Plugin_Continue;
	}

	new Float:dpitch = FloatAbs(AngleDiff(angles[0], g_fPrevAng[client][0]));
	new Float:dyaw = FloatAbs(AngleDiff(angles[1], g_fPrevAng[client][1]));
	new Float:delta = dpitch + dyaw;
	new bool:mouseStill = (AbsInt(mouse[0]) <= NULL_MOUSE && AbsInt(mouse[1]) <= NULL_MOUSE);
	new bool:mouseZero = (mouse[0] == 0 && mouse[1] == 0);
	new bool:attacking = ((buttons & IN_ATTACK) != 0);
	new bool:attackEdge = (attacking && !(g_iPrevButtons[client] & IN_ATTACK));

	new Float:bestFov = 999.0;
	new bestTarget = FindBestTarget(client, angles, bestFov);

	/* Ultra Accurate_Analysis_Module bands: 0.4 / 0.6 / 2.0° */
	new score = 0;
	if (delta >= 2.0)
		score = 3;
	else if (delta >= 0.6)
		score = 2;
	else if (delta >= 0.4)
		score = 1;

	/* --- PRG Pass.Mode:301-304 — passive guidance, mouse still --- */
	if (!attacking && mouseStill && score >= 1 && bestTarget > 0 && bestFov < 25.0)
	{
		if (IsAimToward(client, angles, g_fPrevAng[client], bestTarget))
		{
			g_iPrgStreak[client] += score;
			if (g_iPrgStreak[client] >= PRG_STREAK)
			{
				g_iPrgStreak[client] = 0;
				g_iPrgDet[client]++;
				FireDetect(client, Detection_UltraPRG, g_iPrgDet[client], g_hCvarPrgBan,
					"SMAC_UltraPRGDetected", "PRG Pass.Mode:301-304", delta);
			}
		}
		else
			g_iPrgStreak[client] = 0;
	}
	else if (!mouseStill)
		g_iPrgStreak[client] = 0;

	/* --- AGT Mode:288/299 — guidance while firing --- */
	if (attacking && mouseStill && score >= 1 && bestTarget > 0 && bestFov < 20.0)
	{
		if (IsAimToward(client, angles, g_fPrevAng[client], bestTarget))
		{
			g_iAgtStreak[client] += score;
			if (g_iAgtStreak[client] >= AGT_STREAK)
			{
				g_iAgtStreak[client] = 0;
				g_iAgtDet[client]++;
				FireDetect(client, Detection_UltraAGT, g_iAgtDet[client], g_hCvarAgtBan,
					"SMAC_UltraAGTDetected", "AGT Mode:288/299", delta);
			}
		}
		else
			g_iAgtStreak[client] = 0;
	}
	else if (!attacking)
		g_iAgtStreak[client] = 0;

	/* --- AGTAF Mode:88/99 — snap after fire (RunCmd path) --- */
	if (g_iSnapLeft[client] > 0)
	{
		g_iSnapLeft[client]--;
		if (mouseStill && delta >= 2.0 && delta <= 60.0 && bestTarget > 0 && bestFov < 15.0)
		{
			if (IsAimToward(client, angles, g_fFireAng[client], bestTarget))
			{
				g_iAgtafDet[client]++;
				g_iSnapLeft[client] = 0;
				FireDetect(client, Detection_UltraAGTAF, g_iAgtafDet[client], g_hCvarAgtafBan,
					"SMAC_UltraAGTAFDetected", "AGTAF Mode:88/99", delta);
			}
		}
	}

	/* --- Trigger Mode:188/199 — attack edge as FOV collapses --- */
	if (attackEdge && bestTarget > 0 && bestFov <= TRIGGER_FOV && delta >= 1.0 && mouseStill)
	{
		g_iTrigDet[client]++;
		FireDetect(client, Detection_UltraTriggerAim, g_iTrigDet[client], g_hCvarTrigBan,
			"SMAC_UltraTriggerAimDetected", "Trigger Mode:188/199", bestFov);
	}

	/* --- AGTNL Mode:200/201 — null mouse + aim move toward target --- */
	if (mouseZero && delta >= 0.6 && delta <= 40.0 && bestTarget > 0 && bestFov < 18.0)
	{
		if (IsAimToward(client, angles, g_fPrevAng[client], bestTarget))
		{
			g_iNullDet[client]++;
			if (g_iNullDet[client] % 3 == 0) /* need repeated ticks */
			{
				FireDetect(client, Detection_UltraNullAim, g_iNullDet[client] / 3, g_hCvarNullBan,
					"SMAC_UltraNullAimDetected", "AGTNL Mode:200/201", delta);
			}
		}
	}

	/* --- RCS Recoil Control System -H/-F — perfect punch cancel --- */
	CheckRCS(client, angles);

	g_fPrevAng[client][0] = angles[0];
	g_fPrevAng[client][1] = angles[1];
	g_iPrevButtons[client] = buttons;
	g_iPrevMouse[client][0] = mouse[0];
	g_iPrevMouse[client][1] = mouse[1];
	return Plugin_Continue;
}

CheckRCS(client, const Float:angles[3])
{
	decl Float:punch[3];
	GetEntPropVector(client, Prop_Send, "m_vecPunchAngle", punch);

	if (!g_bHavePunch[client])
	{
		g_fLastPunch[client][0] = punch[0];
		g_fLastPunch[client][1] = punch[1];
		g_fLastPunch[client][2] = punch[2];
		g_bHavePunch[client] = true;
		return;
	}

	new Float:dpunchPitch = punch[0] - g_fLastPunch[client][0];
	new Float:dangPitch = angles[0] - g_fPrevAng[client][0];
	g_fLastPunch[client][0] = punch[0];
	g_fLastPunch[client][1] = punch[1];
	g_fLastPunch[client][2] = punch[2];

	/* Punch grew (recoil up) and eye pitch compensated almost exactly opposite. */
	if (dpunchPitch > 0.15 && dangPitch < -0.10)
	{
		new Float:ratio = FloatAbs(dangPitch / dpunchPitch);
		if (ratio > 0.85 && ratio < 1.25)
		{
			g_iRcsStreak[client]++;
			if (g_iRcsStreak[client] >= RCS_STREAK)
			{
				g_iRcsStreak[client] = 0;
				g_iRcsDet[client]++;
				FireDetect(client, Detection_UltraRCS, g_iRcsDet[client], g_hCvarRcsBan,
					"SMAC_UltraRCSDetected", "Recoil Control System", ratio);
			}
			return;
		}
	}
	g_iRcsStreak[client] = 0;
}

FindBestTarget(client, const Float:angles[3], &Float:bestFov)
{
	decl Float:eye[3];
	GetClientEyePosition(client, eye);
	new team = GetClientTeam(client);
	new best = 0;
	bestFov = 999.0;

	for (new i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || !IsPlayerAlive(i))
			continue;
		if (team > 1 && GetClientTeam(i) == team)
			continue;
		if (g_bWhNative)
		{
			if (!SMAC_IsClientVisible(client, i))
				continue;
		}

		decl Float:tgt[3], Float:dir[3];
		GetClientEyePosition(i, tgt);
		MakeVectorFromPoints(eye, tgt, dir);
		GetVectorAngles(dir, dir);

		new Float:fov = FloatAbs(AngleDiff(angles[1], dir[1])) + FloatAbs(AngleDiff(angles[0], dir[0]));
		if (fov < bestFov)
		{
			bestFov = fov;
			best = i;
		}
	}
	return best;
}

bool:IsAimToward(client, const Float:cur[3], const Float:prev[3], target)
{
	decl Float:eye[3], Float:tgt[3], Float:dir[3];
	GetClientEyePosition(client, eye);
	GetClientEyePosition(target, tgt);
	MakeVectorFromPoints(eye, tgt, dir);
	GetVectorAngles(dir, dir);

	new Float:prevErr = FloatAbs(AngleDiff(prev[1], dir[1])) + FloatAbs(AngleDiff(prev[0], dir[0]));
	new Float:curErr = FloatAbs(AngleDiff(cur[1], dir[1])) + FloatAbs(AngleDiff(cur[0], dir[0]));
	return (curErr + 0.05 < prevErr);
}

Float:AngleDiff(Float:a, Float:b)
{
	new Float:d = a - b;
	while (d > 180.0) d -= 360.0;
	while (d < -180.0) d += 360.0;
	return d;
}

AbsInt(v)
{
	return (v < 0) ? -v : v;
}

FireDetect(client, DetectionType:type, detects, Handle:hBan, const String:phrase[], const String:logTag[], Float:metric)
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", detects);
	KvSetFloat(info, "metric", metric);
	KvSetString(info, "ultra_tag", logTag);

	if (SMAC_CheatDetected(client, type, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", phrase, client, detects);
		SMAC_LogAction(client, "%s (Detection #%i | metric=%.2f)", logTag, detects, metric);
		new banAt = GetConVarInt(hBan);
		if (banAt && detects >= banAt)
		{
			SMAC_LogAction(client, "was banned for %s.", logTag);
			SMAC_Ban(client, "Ultra Aim Detection");
		}
	}
	CloseHandle(info);
}
