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
 * Sources used to restore Ultr@ aim detectors:
 *  1) R52 smac.cfg comments (mode → detector mapping)
 *  2) Author listing (Terminator-ws) on counter-strike.cn.ua / sourceplay.ru:
 *       "цифровая кодировка (представляют собой градусы)"
 *       Automatic Guidance to the Target     → 288, 299
 *       Passive Route Guidance                 → 301, 302, 303, 304
 *       Automatic Route - Null Level          → 200
 *       AimBot Trigger                        → 188, 199
 *       Automatic Route Guidance When a Shot  → 100   (AGTWS)
 *       Automatic Route Guidance After Firing → 88, 99
 *       Analysis Module Shooting using WH     → 102, 103  (see smac_strikeback)
 *       Analysis Module Shooting After Firing → 101   (AMSAF)
 *  3) Decompressed Global.smx .data labels + Accurate_Analysis_Module
 *     float bands 0.4° / 0.6° / 2.0° and mode floats 188.88 / 288.88 / …
 *  4) RCS -F/-H = smac_Advanced_Eye_Angle_Test_Fire / _Hurt
 *     (eye↔bullet / eye↔hurt desync)
 *
 * Soft ban defaults (0). Ultr@ used signed kick/ban style; we keep SMAC_Ban only.
 */

public Plugin:myinfo =
{
	name = "SMAC: Ultra Aim (Restored)",
	author = SMAC_AUTHOR,
	description = "Restored Ultr@ aim modes from cfg + author docs + smx dump",
	version = SMAC_VERSION,
	url = SMAC_URL
};

/* Ultr@ mode codes (degrees encoding per author). */
#define MODE_AGTAF_LO		88.0
#define MODE_AGTAF_HI		109.0
#define MODE_AGTWS			100.0
#define MODE_AMSAF			101.0
#define MODE_TRIGGER_LO		188.0
#define MODE_TRIGGER_HI		199.0
#define MODE_NULL_LO		200.0
#define MODE_NULL_HI		201.0
#define MODE_AGT_LO			288.0
#define MODE_AGT_HI			299.0
#define MODE_PRG_LO			300.0
#define MODE_PRG_HI			305.0

/* Accurate_Analysis_Module micro-bands */
#define BAND_LO				0.4
#define BAND_MID			0.6
#define BAND_HI				2.0

#define SNAP_TICKS			5
#define PRG_STREAK			48
#define AGT_STREAK			36
#define AGTWS_STREAK		20
#define AGTAF_WINDOW		0.35
#define TRIGGER_FOV			3.0
#define NULL_MOUSE			2

new Handle:g_hCvarEnabled = INVALID_HANDLE;
new Handle:g_hCvarPrgBan = INVALID_HANDLE;
new Handle:g_hCvarAgtBan = INVALID_HANDLE;
new Handle:g_hCvarAgtwsBan = INVALID_HANDLE;
new Handle:g_hCvarAgtafBan = INVALID_HANDLE;
new Handle:g_hCvarTrigBan = INVALID_HANDLE;
new Handle:g_hCvarNullBan = INVALID_HANDLE;
new Handle:g_hCvarAmsafBan = INVALID_HANDLE;
new Handle:g_hCvarRcsFire = INVALID_HANDLE;
new Handle:g_hCvarRcsHurt = INVALID_HANDLE;

new bool:g_bWhNative = false;

new Float:g_fPrevAng[MAXPLAYERS+1][3];
new bool:g_bHaveAng[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];

new g_iPrgStreak[MAXPLAYERS+1];
new g_iAgtStreak[MAXPLAYERS+1];
new g_iAgtwsStreak[MAXPLAYERS+1];

new Float:g_fLastFire[MAXPLAYERS+1];
new Float:g_fFireAng[MAXPLAYERS+1][3];
new Float:g_fFireEye[MAXPLAYERS+1][3];
new g_iSnapLeft[MAXPLAYERS+1];
new Float:g_fAmsafAccum[MAXPLAYERS+1];

new g_iPrgDet[MAXPLAYERS+1];
new g_iAgtDet[MAXPLAYERS+1];
new g_iAgtwsDet[MAXPLAYERS+1];
new g_iAgtafDet[MAXPLAYERS+1];
new g_iTrigDet[MAXPLAYERS+1];
new g_iNullDet[MAXPLAYERS+1];
new g_iAmsafDet[MAXPLAYERS+1];
new g_iRcsFireDet[MAXPLAYERS+1];
new g_iRcsHurtDet[MAXPLAYERS+1];

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

	/* Mirror Ultr@ smac_aimbot_Advanced_* names; default 0 = never ban (safer than Ultra). */
	g_hCvarPrgBan = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_PRG", "0", "PRG Mode:300-305 bans after N detects. (0=Never)", _, true, 0.0);
	g_hCvarAgtBan = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_AGT", "0", "AGT Mode:288/299 bans after N detects. (0=Never)", _, true, 0.0);
	g_hCvarAgtwsBan = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_AGTWS", "0", "AGTWS Mode:100 bans after N detects. (0=Never)", _, true, 0.0);
	g_hCvarAgtafBan = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_AGTAF", "0", "AGTAF Mode:88/99 bans after N detects. (0=Never)", _, true, 0.0);
	g_hCvarTrigBan = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_Tr", "0", "Trigger Mode:188/199 bans after N detects. (0=Never)", _, true, 0.0);
	g_hCvarNullBan = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_AGTNL", "0", "Null Mode:200/201 bans after N detects. (0=Never)", _, true, 0.0);
	g_hCvarAmsafBan = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_AMSAF", "0", "AMSAF Mode:101 bans after N detects. (0=Never)", _, true, 0.0);

	/* Ultr@ Eye Angle Test — signed: 0=off, we treat abs as threshold, ban off by default. */
	g_hCvarRcsFire = SMAC_CreateConVar("smac_Advanced_Eye_Angle_Test_Fire", "0.0", "RCS-F: eye↔shot desync units before detect. 0=off. Ultra default was -40.", _, true, 0.0);
	g_hCvarRcsHurt = SMAC_CreateConVar("smac_Advanced_Eye_Angle_Test_Hurt", "0.0", "RCS-H: eye↔hurt desync degrees before detect. 0=off. Ultra default was 4.", _, true, 0.0);

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
	g_iPrevButtons[client] = 0;
	g_iPrgStreak[client] = 0;
	g_iAgtStreak[client] = 0;
	g_iAgtwsStreak[client] = 0;
	g_iSnapLeft[client] = 0;
	g_fLastFire[client] = 0.0;
	g_fAmsafAccum[client] = 0.0;
	g_iPrgDet[client] = 0;
	g_iAgtDet[client] = 0;
	g_iAgtwsDet[client] = 0;
	g_iAgtafDet[client] = 0;
	g_iTrigDet[client] = 0;
	g_iNullDet[client] = 0;
	g_iAmsafDet[client] = 0;
	g_iRcsFireDet[client] = 0;
	g_iRcsHurtDet[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_bHaveAng[client] = false;
		g_fIgnoreUntil[client] = GetGameTime() + 1.5;
		g_fAmsafAccum[client] = 0.0;
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
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client))
		return;

	g_fLastFire[client] = GetGameTime();
	GetClientEyeAngles(client, g_fFireAng[client]);
	GetClientEyePosition(client, g_fFireEye[client]);
	g_iSnapLeft[client] = SNAP_TICKS;
	g_fAmsafAccum[client] = 0.0;
}

public Event_PlayerHurt(Handle:event, const String:name[], bool:dontBroadcast)
{
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
	GetClientAbsOrigin(victim, tgt);
	tgt[2] += 40.0; /* approx chest */
	GetClientEyeAngles(attacker, ang);
	MakeVectorFromPoints(eye, tgt, toTarget);
	GetVectorAngles(toTarget, toTarget);

	new Float:dyaw = FloatAbs(AngleDiff(ang[1], toTarget[1]));
	new Float:dpitch = FloatAbs(AngleDiff(ang[0], toTarget[0]));
	new Float:fov = dyaw + dpitch;

	/* RCS-H: Eye Angle Test Hurt — desync look vs hit point (Ultra cfg). */
	new Float:hurtLimit = GetConVarFloat(g_hCvarRcsHurt);
	if (hurtLimit > 0.0 && fov >= hurtLimit)
	{
		g_iRcsHurtDet[attacker]++;
		FireDetect(attacker, Detection_UltraRCS, g_iRcsHurtDet[attacker], INVALID_HANDLE,
			"SMAC_UltraRCSDetected", "RCS-H EyeAngleTest_Hurt", fov, MODE_AMSAF);
	}

	/* AGTAF Mode:88/99 — snap onto victim after fire. */
	if (GetGameTime() - g_fLastFire[attacker] <= AGTAF_WINDOW && fov <= TRIGGER_FOV)
	{
		new Float:snap = FloatAbs(AngleDiff(ang[1], g_fFireAng[attacker][1]))
			+ FloatAbs(AngleDiff(ang[0], g_fFireAng[attacker][0]));
		if (snap >= BAND_HI && snap <= MODE_AGTAF_HI)
		{
			g_iAgtafDet[attacker]++;
			FireDetect(attacker, Detection_UltraAGTAF, g_iAgtafDet[attacker], g_hCvarAgtafBan,
				"SMAC_UltraAGTAFDetected", "AGTAF Mode:88/99", snap, ClassifyAgtaf(snap));
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
	new score = ScoreBand(delta);

	/* PRG Pass.Mode:301-304 — passive guidance */
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
					"SMAC_UltraPRGDetected", "PRG Pass.Mode:301-304", delta, MODE_PRG_LO + float(score));
			}
		}
		else g_iPrgStreak[client] = 0;
	}
	else if (!mouseStill)
		g_iPrgStreak[client] = 0;

	/* AGT Mode:288/299 — guidance while holding attack */
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
					"SMAC_UltraAGTDetected", "AGT Mode:288/299", delta, MODE_AGT_LO);
			}
		}
		else g_iAgtStreak[client] = 0;
	}
	else if (!attacking)
		g_iAgtStreak[client] = 0;

	/* AGTWS Mode:100 — Automatic Route Guidance When a Shot (attack edge) */
	if (attackEdge && mouseStill && score >= 1 && bestTarget > 0 && bestFov < 18.0)
	{
		if (IsAimToward(client, angles, g_fPrevAng[client], bestTarget))
		{
			g_iAgtwsStreak[client] += score;
			if (g_iAgtwsStreak[client] >= AGTWS_STREAK)
			{
				g_iAgtwsStreak[client] = 0;
				g_iAgtwsDet[client]++;
				FireDetect(client, Detection_UltraAGTWS, g_iAgtwsDet[client], g_hCvarAgtwsBan,
					"SMAC_UltraAGTWSDetected", "AGTWS Mode:100", delta, MODE_AGTWS);
			}
		}
	}
	else if (!attacking)
		g_iAgtwsStreak[client] = 0;

	/* AGTAF Mode:88/99 — post-fire snap (RunCmd) */
	if (g_iSnapLeft[client] > 0)
	{
		g_iSnapLeft[client]--;
		g_fAmsafAccum[client] += delta;

		if (mouseStill && delta >= BAND_HI && delta <= MODE_AGTAF_HI && bestTarget > 0 && bestFov < 15.0)
		{
			if (IsAimToward(client, angles, g_fFireAng[client], bestTarget))
			{
				g_iAgtafDet[client]++;
				g_iSnapLeft[client] = 0;
				FireDetect(client, Detection_UltraAGTAF, g_iAgtafDet[client], g_hCvarAgtafBan,
					"SMAC_UltraAGTAFDetected", "AGTAF Mode:88/99", delta, ClassifyAgtaf(delta));
			}
		}

		/* AMSAF Mode:101 — Analysis Module Shooting After Firing */
		if (g_iSnapLeft[client] == 0 && g_fAmsafAccum[client] >= MODE_AGTWS)
		{
			g_iAmsafDet[client]++;
			FireDetect(client, Detection_UltraAMSAF, g_iAmsafDet[client], g_hCvarAmsafBan,
				"SMAC_UltraAMSAFDetected", "AMSAF Mode:101", g_fAmsafAccum[client], MODE_AMSAF);
			g_fAmsafAccum[client] = 0.0;
		}
	}

	/* Trigger Mode:188/199 */
	if (attackEdge && bestTarget > 0 && bestFov <= TRIGGER_FOV && delta >= BAND_HI && mouseStill)
	{
		g_iTrigDet[client]++;
		FireDetect(client, Detection_UltraTriggerAim, g_iTrigDet[client], g_hCvarTrigBan,
			"SMAC_UltraTriggerAimDetected", "Trigger Mode:188/199", bestFov, MODE_TRIGGER_LO);
	}

	/* AGTNL Mode:200/201 — null mouse */
	if (mouseZero && delta >= BAND_MID && delta <= 40.0 && bestTarget > 0 && bestFov < 18.0)
	{
		if (IsAimToward(client, angles, g_fPrevAng[client], bestTarget))
		{
			g_iNullDet[client]++;
			if ((g_iNullDet[client] % 3) == 0)
			{
				FireDetect(client, Detection_UltraNullAim, g_iNullDet[client] / 3, g_hCvarNullBan,
					"SMAC_UltraNullAimDetected", "AGTNL Mode:200/201", delta, MODE_NULL_LO);
			}
		}
	}

	/* RCS-F: Eye Angle Test Fire — cmd angles vs eye angles at recent fire */
	new Float:fireLimit = GetConVarFloat(g_hCvarRcsFire);
	if (fireLimit > 0.0 && attacking && g_fLastFire[client] > 0.0
		&& (GetGameTime() - g_fLastFire[client]) < 0.25)
	{
		new Float:desync = FloatAbs(AngleDiff(angles[0], g_fFireAng[client][0]))
			+ FloatAbs(AngleDiff(angles[1], g_fFireAng[client][1]));
		if (desync >= fireLimit)
		{
			g_iRcsFireDet[client]++;
			FireDetect(client, Detection_UltraRCS, g_iRcsFireDet[client], INVALID_HANDLE,
				"SMAC_UltraRCSDetected", "RCS-F EyeAngleTest_Fire", desync, MODE_AMSAF);
		}
	}

	g_fPrevAng[client][0] = angles[0];
	g_fPrevAng[client][1] = angles[1];
	g_iPrevButtons[client] = buttons;
	return Plugin_Continue;
}

ScoreBand(Float:delta)
{
	if (delta >= BAND_HI) return 3;
	if (delta >= BAND_MID) return 2;
	if (delta >= BAND_LO) return 1;
	return 0;
}

Float:ClassifyAgtaf(Float:snap)
{
	if (snap >= 108.0) return 109.0;
	if (snap >= 99.0) return 108.0;
	if (snap >= 88.0) return 99.0;
	return MODE_AGTAF_LO;
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

FireDetect(client, DetectionType:type, detects, Handle:hBan, const String:phrase[], const String:logTag[], Float:metric, Float:modeDeg)
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", detects);
	KvSetFloat(info, "metric", metric);
	KvSetFloat(info, "mode", modeDeg);
	KvSetString(info, "ultra_tag", logTag);

	if (SMAC_CheatDetected(client, type, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", phrase, client, detects);
		SMAC_LogAction(client, "%s (Detection #%i | Mode:%.1f | metric=%.2f)", logTag, detects, modeDeg, metric);
		if (hBan != INVALID_HANDLE)
		{
			new banAt = GetConVarInt(hBan);
			if (banAt && detects >= banAt)
			{
				SMAC_LogAction(client, "was banned for %s.", logTag);
				SMAC_Ban(client, "Ultra Aim Detection");
			}
		}
	}
	CloseHandle(info);
}
