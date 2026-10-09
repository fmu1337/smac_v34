#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC Ultr@ R52 port: aimbot detectors.
 *
 * Rewritten from 001_SMAC_Global.smx of SMAC Ultr@ R52 as decompiled with
 * tools/r52re/decomp.py (docs/R52_SPEC.md §0, §1, §2; docs/ULTRA_AIMBOT.md).
 * No Ultr@ code and no Ultr@Tools extension is used.
 *
 * Thresholds come from the client's sensitivity (queried like R52):
 *   thr2 = sens * 0.033, thr3 = min(thr2 * 2.6, 0.7), s = round(sens).
 * dYaw = |yaw(cmd) - yaw(prev cmd)| without 360 wrapping (as R52).
 *
 * Target trace (R52 fn_35cd2c): ray from the eyes along the cmd angles; counts only an
 * enemy player at >= 200 units. Modes 1/2 add a small probe to the yaw and lower the
 * eyes by probe*180 while nothing was hit, and track hitgroup stability: the first two
 * distinct hitgroups are remembered, hits in them count up, a third one breaks the run.
 *
 * On ground, no mouse input (mouse[0] == mouse[1] == 0):
 *   PRG Pass.Mode:301  dYaw > thr2 several cmds while the trace keeps the same hitgroups (>= 4)
 *   PRG Pass.Mode:302  same streak > 5 cmds, hitgroups >= 2, after a 301 was seen
 *   AGTNL Mode:200     0.005 < dYaw < 0.007 on an enemy, not zoomed, once per 22 cmds
 * Mouse moving:
 *   AGTNL Mode:201     mouse moves but pitch and yaw change < 0.005; 6 such cmds (>= 22 apart,
 *                      one decays every 5 s)
 *   PRG Pass.Mode:303  on ground, steady mouse (|dmouse| <= s on an axis), trace mode 2 hitgroups >= 10
 *   PRG Pass.Mode:304  same streak > 11, hitgroups >= 8, after a 303 was seen
 * While firing:
 *   AGTWS Mode:100     +attack pressed with a snap (dYaw >= thr3); within 7 cmds yaw freezes exactly
 *                      (dYaw == 0) while pitch still changes, on an enemy
 *   AMSAF Mode:101     shot right after the view moved without mouse input, with a mouse flick of
 *                      quantized size (multiples of s); two more held cmds are scored by the same
 *                      quantization plus the target trace; score > 1 at release adds to the counter
 * Accurate Analysis Module (player_hurt with dmg >= 10 / player_death, distance >= 200):
 *   AGT Mode:299/288   weighted hit counter while the aim was still turning without mouse
 *   Trigger 199/188    same, only for hits within 2 cmds after the +attack press
 *   AGTAF 99/88, 109/108  hits during the PRG 303 steady-mouse streak with stable hitgroups
 * UsingWH Mode:103   6-tick window from the first shot after +attack: aim change above thr2
 *                    per axis on ground without mouse input sums to >= thr5 = max(sens / 8.5, 0.2)
 *                    and the shot did damage (R52 102 is dead code there and not ported)
 *   (first number = kill, second = hurt)
 *
 * Counters start at -1 like R52: a detector reports when its counter reaches
 * "Warning" and punishes when it exceeds |Ban|. Every detection schedules a decrement
 * (420 s, 303/304 and AGTNL 300 s), postponed while the player is a spectator.
 * Defaults are admin-notice only (all Ban cvars 0).
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: Aimbot",
	author = SMAC_AUTHOR,
	description = "AimBot PRG 301-304, AGTNL 200/201, AGTWS 100, AMSAF 101, UsingWH 103 and Accurate Analysis (AGT, Trigger, AGTAF) from SMAC Ultr@ R52",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define UNKNOWN_THR			100.0
#define QUERY_INTERVAL		60.0

#define MIN_TARGET_DIST_SQ	40000.0		/* 200 units */
#define DIST_NEAR_SQ		302500.0	/* 550 units */
#define DIST_FAR_SQ			1690000.0	/* 1300 units */

#define NL_MIN_STEP			0.005
#define NL_MAX_STEP			0.007
#define NL_COOLDOWN			22
#define NL201_NEED			4
#define NL201_DECAY			5.0
#define NL_MIN_FOV			50

#define DECAY_LONG			420.0
#define DECAY_SHORT			300.0

#define AMS_WINDOW			6
#define AGTWS_WINDOW		7
#define WH_WINDOW			6

/* Counters (R52 cnt[] slots). */
#define C_TRIGGER	0	/* cnt[1]  Trigger 188/199 */
#define C_STREAK	1	/* cnt[2]  PRG 301/302 streak */
#define C_AGT		2	/* cnt[3]  AGT 288/299 */
#define C_PRG301	3	/* cnt[4] */
#define C_PRG302	4	/* cnt[5] */
#define C_STEADY	5	/* cnt[6]  PRG 303/304 streak */
#define C_PRG303	6	/* cnt[7] */
#define C_PRG304	7	/* cnt[8] */
#define C_AGTAF1	8	/* cnt[9]  AGTAF 88/99 */
#define C_AGTNL		9	/* cnt[17] */
#define C_AGTAF2	10	/* cnt[38] AGTAF 108/109 */
#define C_NL201		11	/* cnt[45] */
#define C_AMSAF		12	/* cnt[12] AMSAF 101 */
#define C_AGTWS		13	/* cnt[16] AGTWS 100 */
#define C_USINGWH	14	/* cnt[18] UsingWH 103 */
#define C_COUNT		15

/* Detector groups (cvar pairs). */
#define G_PRG		0
#define G_AGT		1
#define G_TR		2
#define G_AGTAF		3
#define G_AGTNL		4
#define G_AMSAF		5
#define G_AGTWS		6
#define G_USINGWH	7
#define G_COUNT		8

new Handle:g_hCvarWarn[G_COUNT];
new Handle:g_hCvarBan[G_COUNT];
new Handle:g_hCvarAdminImmune = INVALID_HANDLE;

new Handle:g_hTrieExclude = INVALID_HANDLE;		/* R52 trie 4104: knife, grenades, world */
new Handle:g_hTriePistol = INVALID_HANDLE;		/* R52 trie 4105 */
new Handle:g_hTrieSniper = INVALID_HANDLE;		/* R52 trie 4106 */
new Handle:g_hTrieGrenade = INVALID_HANDLE;		/* R52 trie 4103: aim checks skipped */

new g_iCnt[MAXPLAYERS+1][C_COUNT];
new Float:g_fNl201Time[MAXPLAYERS+1];

new bool:g_bSensKnown[MAXPLAYERS+1];
new Float:g_fThr2[MAXPLAYERS+1];
new Float:g_fThr3[MAXPLAYERS+1];
new Float:g_fThr5[MAXPLAYERS+1];
new g_iSensRound[MAXPLAYERS+1];

new bool:g_bHasPrev[MAXPLAYERS+1];
new Float:g_fPrevAng[MAXPLAYERS+1][2];
new Float:g_fDYaw[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];
new g_iCmd[MAXPLAYERS+1];
new g_iTriggerUntil[MAXPLAYERS+1];
new g_iNlCooldown[MAXPLAYERS+1];
new bool:g_bGrenade[MAXPLAYERS+1];

/* Trace state (R52 g1ece0 probe, g1ebd8 last hit, g1d848 / g1de78 / g1e3a0). */
/* Last cmd with mouse input (R52 mouseSt[0..1], angles g57b0c[2..3]). */
new g_iLastMouse[MAXPLAYERS+1][2];
new Float:g_fLastMouseAng[MAXPLAYERS+1][2];

/* AMSAF state (R52 cnt[10], cnt[11], g58874, g576ec, mouseSt[5..6], g57b0c[0..1]). */
new g_iAmsStage[MAXPLAYERS+1];
new g_iAmsStep[MAXPLAYERS+1];
new g_iAmsScore[MAXPLAYERS+1];
new g_iAmsAccum[MAXPLAYERS+1][2];
new bool:g_bAmsFlat[MAXPLAYERS+1];
new g_iAmsWindowEnd[MAXPLAYERS+1];
new g_iAmsStillCmd[MAXPLAYERS+1];
new Float:g_fAmsEye[MAXPLAYERS+1][2];

/* AGTWS: cmd of the +attack press that snapped (R52 g4d81c[2]). */
new g_iSnapCmd[MAXPLAYERS+1];

new Float:g_fProbe[MAXPLAYERS+1];
new g_iLastHit[MAXPLAYERS+1];
new g_iHit1[MAXPLAYERS+1][4];	/* count, hits, hitgroup A, hitgroup B */
new g_iHit2[MAXPLAYERS+1][4];
new g_iHit2b[MAXPLAYERS+1];

/* UsingWH 103 (R52 whState[0], [1], [6], [9], [10], g53fc4): window after the first shot. */
new g_iWhEnd[MAXPLAYERS+1];
new g_iWhShotTick[MAXPLAYERS+1];
new g_iWhDmg[MAXPLAYERS+1];
new g_iWhLastTick[MAXPLAYERS+1];
new g_iWhShots[MAXPLAYERS+1];
new Float:g_fWhSum[MAXPLAYERS+1];
new bool:g_bWhGround[MAXPLAYERS+1];
new bool:g_bWhNoMouse[MAXPLAYERS+1];
new g_iWhPrevMouse[MAXPLAYERS+1];
new Float:g_fWhAng[MAXPLAYERS+1][2][2];	/* [0] = this cmd, [1] = previous cmd */

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarWarn[G_PRG] = SMAC_CreateConVar("smac_aimbot_Advanced_Warning_PRG", "3", "AimBot PRG Pass.Mode:301-304: notify admins from this counter value. (0 = never)", _, true, 0.0);
	g_hCvarBan[G_PRG] = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_PRG", "0", "AimBot PRG Pass.Mode:301-304: punish when the counter exceeds |N|: -N kick, +N ban, 0 = never (R52: 5)", _, true, -100.0, true, 100.0);
	g_hCvarWarn[G_AGT] = SMAC_CreateConVar("smac_aimbot_Advanced_Warning_AGT", "7", "AimBot AGT Mode:288/299: notify admins from this counter value. (0 = never)", _, true, 0.0);
	g_hCvarBan[G_AGT] = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_AGT", "0", "AimBot AGT Mode:288/299: punish when the counter exceeds |N|: -N kick, +N ban, 0 = never (R52: 9)", _, true, -100.0, true, 100.0);
	g_hCvarWarn[G_TR] = SMAC_CreateConVar("smac_aimbot_Advanced_Warning_Tr", "7", "AimBot Trigger Mode:188/199: notify admins from this counter value. (0 = never)", _, true, 0.0);
	g_hCvarBan[G_TR] = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_Tr", "0", "AimBot Trigger Mode:188/199: punish when the counter exceeds |N|: -N kick, +N ban, 0 = never (R52: 9)", _, true, -100.0, true, 100.0);
	g_hCvarWarn[G_AGTAF] = SMAC_CreateConVar("smac_aimbot_Advanced_Warning_AGTAF", "3", "AimBot AGTAF Mode:88/99/108/109: notify admins from this counter value. (0 = never)", _, true, 0.0);
	g_hCvarBan[G_AGTAF] = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_AGTAF", "0", "AimBot AGTAF Mode:88/99/108/109: punish when the counter exceeds |N|: -N kick, +N ban, 0 = never (R52: 5)", _, true, -100.0, true, 100.0);
	g_hCvarWarn[G_AGTNL] = SMAC_CreateConVar("smac_aimbot_Advanced_Warning_AGTNL", "1", "AimBot AGTNL Mode:200/201: notify admins from this counter value. (0 = never)", _, true, 0.0);
	g_hCvarBan[G_AGTNL] = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_AGTNL", "0", "AimBot AGTNL Mode:200/201: punish when the counter exceeds |N|: -N kick, +N ban, 0 = never (R52: 1)", _, true, -100.0, true, 100.0);
	g_hCvarWarn[G_AMSAF] = SMAC_CreateConVar("smac_aimbot_Advanced_Warning_AMSAF", "5", "AimBot AMSAF Mode:101: notify admins from this counter value. (0 = never)", _, true, 0.0);
	g_hCvarBan[G_AMSAF] = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_AMSAF", "0", "AimBot AMSAF Mode:101: punish when the counter exceeds |N|: -N kick, +N ban, 0 = never (R52: 7)", _, true, -100.0, true, 100.0);
	g_hCvarWarn[G_AGTWS] = SMAC_CreateConVar("smac_aimbot_Advanced_Warning_AGTWS", "4", "AimBot AGTWS Mode:100: notify admins from this counter value. (0 = never)", _, true, 0.0);
	g_hCvarBan[G_AGTWS] = SMAC_CreateConVar("smac_aimbot_Advanced_Ban_AGTWS", "0", "AimBot AGTWS Mode:100: punish when the counter exceeds |N|: -N kick, +N ban, 0 = never (R52: 6)", _, true, -100.0, true, 100.0);
	g_hCvarWarn[G_USINGWH] = SMAC_CreateConVar("smac_aimbot_UsingWH_Warning_AMS", "3", "AimBot UsingWH Mode:103: notify admins from this counter value. (0 = never)", _, true, 0.0);
	g_hCvarBan[G_USINGWH] = SMAC_CreateConVar("smac_aimbot_UsingWH_Ban_AMS", "0", "AimBot UsingWH Mode:103: punish when the counter exceeds |N|: -N kick, +N ban, 0 = never (R52: 6)", _, true, -100.0, true, 100.0);
	g_hCvarAdminImmune = SMAC_CreateConVar("smac_ultra_admin_immune", "1", "Never kick/ban admins with ban/root flag (detections are still logged).", _, true, 0.0, true, 1.0);

	g_hTrieExclude = CreateTrie();
	g_hTriePistol = CreateTrie();
	g_hTrieSniper = CreateTrie();
	g_hTrieGrenade = CreateTrie();
	FillTrie(g_hTrieExclude, "knife tknifehs tknife env_explosion hegrenade flashbang smokegrenade hegrenade_projectile flashbang_projectile smokegrenade_projectile entityflame worldspawn world watermelon watermelon_projectile");
	FillTrie(g_hTriePistol, "deagle elite glock fiveseven p228 usp");
	FillTrie(g_hTrieSniper, "awp g3sg1 scout sg550");
	FillTrie(g_hTrieGrenade, "weapon_hegrenade weapon_flashbang weapon_smokegrenade");

	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	AddTempEntHook("Shotgun Shot", TE_FireBullets);

	CreateTimer(QUERY_INTERVAL, Timer_QueryAll, _, TIMER_REPEAT);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
}

FillTrie(Handle:trie, const String:list[])
{
	decl String:parts[24][32];
	new n = ExplodeString(list, " ", parts, sizeof(parts), sizeof(parts[]));
	for (new i = 0; i < n; i++)
		SetTrieValue(trie, parts[i], 1);
}

public OnClientPutInServer(client)
{
	for (new i = 0; i < C_COUNT; i++)
		g_iCnt[client][i] = -1;
	g_fNl201Time[client] = 0.0;

	g_bSensKnown[client] = false;
	g_fThr2[client] = UNKNOWN_THR;
	g_fThr3[client] = UNKNOWN_THR;
	g_fThr5[client] = UNKNOWN_THR;
	g_iSensRound[client] = 0;

	ResetMotion(client);
	g_iTriggerUntil[client] = -1;
	g_iNlCooldown[client] = 0;
	g_iLastMouse[client][0] = g_iLastMouse[client][1] = 0;
	g_fLastMouseAng[client][0] = g_fLastMouseAng[client][1] = 0.0;
	ResetAmsaf(client);
	g_iAmsStillCmd[client] = 0;
	g_iSnapCmd[client] = 0;
	ResetWh(client);
	g_iWhShots[client] = 0;
	g_iWhPrevMouse[client] = 0;

	g_fProbe[client] = 0.0;
	g_iLastHit[client] = 0;
	ResetHit1(client);
	ResetHit2(client);

	if (!IsFakeClient(client))
		QueryClientConVar(client, "sensitivity", Query_Sensitivity);
}

ResetMotion(client)
{
	g_bHasPrev[client] = false;
	g_fDYaw[client] = 0.0;
	g_iPrevButtons[client] = 0;
}

ResetHit1(client)
{
	g_iHit1[client][0] = g_iHit1[client][1] = g_iHit1[client][2] = g_iHit1[client][3] = 0;
}

ResetHit2(client)
{
	g_iHit2[client][0] = g_iHit2[client][1] = g_iHit2[client][2] = g_iHit2[client][3] = 0;
	g_iHit2b[client] = 0;
}

public Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
		ResetMotion(client);
}

public Action:Timer_QueryAll(Handle:timer)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			QueryClientConVar(i, "sensitivity", Query_Sensitivity);
	}
	return Plugin_Continue;
}

public Query_Sensitivity(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[])
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || result != ConVarQuery_Okay)
		return;

	/* R52 kicks for sensitivity outside [1; 20]; here it is clamped instead. */
	new Float:sens = StringToFloat(cvarValue);
	if (sens < 1.0)
		sens = 1.0;
	else if (sens > 20.0)
		sens = 20.0;

	g_fThr2[client] = sens * 0.033;
	g_fThr3[client] = g_fThr2[client] * 2.6;
	if (g_fThr3[client] > 0.7)
		g_fThr3[client] = 0.7;
	g_fThr5[client] = sens / 8.5;
	if (g_fThr5[client] < 0.2)
		g_fThr5[client] = 0.2;
	g_iSensRound[client] = RoundToNearest(sens);
	g_bSensKnown[client] = true;
}

/**
 * Usercmd analysis
 */
public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!IsPlaying(client))
	{
		ResetMotion(client);
		return Plugin_Continue;
	}

	g_iCmd[client] = cmdnum;

	if (g_bHasPrev[client])
	{
		new bool:bMouse = (mouse[0] != 0 || mouse[1] != 0);
		new prevMouse0 = g_iLastMouse[client][0];
		new prevMouse1 = g_iLastMouse[client][1];
		new Float:dPitch = FloatAbs(g_fPrevAng[client][0] - angles[0]);

		g_fDYaw[client] = FloatAbs(g_fPrevAng[client][1] - angles[1]);
		g_bGrenade[client] = IsHoldingGrenade(client);

		/* R52 keeps the last non-zero mouse input. */
		if (bMouse)
		{
			g_iLastMouse[client][0] = AbsValue(mouse[0]);
			g_iLastMouse[client][1] = AbsValue(mouse[1]);
		}

		/* Trigger window: the +attack press and the next cmd. */
		if (g_iTriggerUntil[client] != -1 && cmdnum > g_iTriggerUntil[client])
			g_iTriggerUntil[client] = -1;

		if (g_bSensKnown[client])
		{
			if (bMouse)
				CheckMouse(client, buttons, angles, cmdnum, prevMouse0, prevMouse1, dPitch);
			else
				CheckNoMouse(client, angles, cmdnum);

			CheckAttack(client, buttons, vel, angles, cmdnum);
		}

		if ((buttons & IN_ATTACK) && !(g_iPrevButtons[client] & IN_ATTACK))
			g_iTriggerUntil[client] = cmdnum + 1;

		if (GroupEnabled(G_USINGWH))
			UsingWhCmd(client, buttons, angles, mouse);
	}

	g_fPrevAng[client][0] = angles[0];
	g_fPrevAng[client][1] = angles[1];
	g_iPrevButtons[client] = buttons;
	g_bHasPrev[client] = true;
	return Plugin_Continue;
}

/* mouse[0] == mouse[1] == 0 */
CheckNoMouse(client, const Float:angles[3], cmdnum)
{
	CheckNoMouseAim(client, angles, cmdnum);

	/* R52: any cmd without mouse input ends the AMSAF shot and the steady-mouse streak. */
	if (g_iAmsStage[client] > 1)
		AmsafEvaluate(client);
	g_iCnt[client][C_STEADY] = -1;
	ResetHit2(client);
}

CheckNoMouseAim(client, const Float:angles[3], cmdnum)
{
	if (!(GetEntityFlags(client) & FL_ONGROUND))
		return;

	if (g_fDYaw[client] > g_fThr2[client])
	{
		g_iCnt[client][C_STREAK]++;
		if (g_iCnt[client][C_STREAK] <= 0 || !GroupEnabled(G_PRG))
			return;

		if (g_bGrenade[client])
		{
			ResetPrg(client);
			return;
		}

		new target = TraceTarget(client, angles, 1);
		if (target > 0 && g_iHit1[client][1] >= 4)
		{
			g_iCnt[client][C_STREAK] = -1;
			ResetHit1(client);
			Detect(client, G_PRG, C_PRG301, DECAY_LONG, "AimBot (Passive Route Guidance)", "Pass.Mode:301");
			return;
		}

		if (g_iCnt[client][C_STREAK] > 5)
		{
			if (g_iCnt[client][C_PRG301] >= 0 && g_iHit1[client][1] >= 2)
			{
				g_iCnt[client][C_STREAK] = -1;
				ResetHit1(client);
				Detect(client, G_PRG, C_PRG302, DECAY_LONG, "AimBot (Passive Route Guidance)", "Pass.Mode:302");
			}
		}
		else if (g_iCnt[client][C_STREAK] > 10)
		{
			g_iCnt[client][C_STREAK] = -1;
			ResetHit1(client);
		}
		return;
	}

	/* Null Level 200: micro step without mouse input. */
	if (g_fDYaw[client] > NL_MIN_STEP && g_fDYaw[client] < NL_MAX_STEP)
	{
		if (GetFov(client) <= NL_MIN_FOV || cmdnum <= g_iNlCooldown[client] || !GroupEnabled(G_AGTNL))
			return;

		if (g_bGrenade[client])
		{
			ResetPrg(client);
			return;
		}

		if (TraceTarget(client, angles, 0) > 0)
		{
			g_iNlCooldown[client] = cmdnum + NL_COOLDOWN;
			Detect(client, G_AGTNL, C_AGTNL, DECAY_SHORT, "AimBot (Automatic Route - Null Level)", "Mode:200");
		}
		return;
	}

	g_iCnt[client][C_STREAK] = -1;
	ResetHit1(client);
}

/* Mouse is moving. */
CheckMouse(client, buttons, const Float:angles[3], cmdnum, prevMouse0, prevMouse1, Float:dPitch)
{
	/* Null Level 201: the mouse moves, the view does not. */
	if (cmdnum > g_iNlCooldown[client] && GroupEnabled(G_AGTNL)
		&& dPitch < NL_MIN_STEP && g_fDYaw[client] < NL_MIN_STEP)
	{
		g_iNlCooldown[client] = cmdnum + NL_COOLDOWN;

		/* R52 decays this counter by one every 5 s. */
		if (g_iCnt[client][C_NL201] > -1 && g_fNl201Time[client] > 0.0)
		{
			new steps = RoundToFloor((GetGameTime() - g_fNl201Time[client]) / NL201_DECAY);
			g_iCnt[client][C_NL201] -= steps;
			if (g_iCnt[client][C_NL201] < -1)
				g_iCnt[client][C_NL201] = -1;
		}
		g_fNl201Time[client] = GetGameTime();

		if (++g_iCnt[client][C_NL201] > NL201_NEED)
		{
			g_iCnt[client][C_NL201] = -1;
			if (HasWeapon(client))
				Detect(client, G_AGTNL, C_AGTNL, DECAY_SHORT, "AimBot (Automatic Route - Null Level)", "Mode:201");
		}
	}

	if (GetEntityFlags(client) & FL_ONGROUND)
	{
		if (GroupEnabled(G_PRG) || GroupEnabled(G_AGTAF))
			CheckSteadyMouse(client, angles, prevMouse0, prevMouse1);

		if (GroupEnabled(G_AMSAF))
			CheckAmsafHeld(client, buttons, angles, cmdnum);
	}

	/* Any mouse input ends the no-mouse streak. */
	g_iCnt[client][C_STREAK] = -1;
	ResetHit1(client);

	g_fLastMouseAng[client][0] = angles[0];
	g_fLastMouseAng[client][1] = angles[1];
}

/* PRG 303/304: steady mouse movement while the trace stays on the same hitgroups. */
CheckSteadyMouse(client, const Float:angles[3], prevMouse0, prevMouse1)
{
	new s = g_iSensRound[client];
	new d0 = AbsValue(g_iLastMouse[client][0] - prevMouse0);
	new d1 = AbsValue(g_iLastMouse[client][1] - prevMouse1);

	if (d0 > s && d1 > s)
	{
		g_iCnt[client][C_STEADY] = -1;
		ResetHit2(client);
		return;
	}

	g_iCnt[client][C_STEADY]++;
	if (g_iCnt[client][C_STEADY] <= 0)
		return;

	if (g_bGrenade[client])
	{
		ResetPrg(client);
		return;
	}

	new target = TraceTarget(client, angles, 2);
	if (target > 0 && g_iHit2[client][1] >= 10 && GroupEnabled(G_PRG))
	{
		g_iCnt[client][C_STEADY] = -1;
		ResetHit2(client);
		Detect(client, G_PRG, C_PRG303, DECAY_SHORT, "AimBot (Passive Route Guidance)", "Pass.Mode:303");
	}

	if (g_iCnt[client][C_STEADY] > 11)
	{
		if (g_iCnt[client][C_PRG303] >= 0 && g_iHit2[client][1] >= 8)
		{
			g_iCnt[client][C_STEADY] = -1;
			ResetHit2(client);
			Detect(client, G_PRG, C_PRG304, DECAY_SHORT, "AimBot (Passive Route Guidance)", "Pass.Mode:304");
		}
	}
	else if (g_iCnt[client][C_STEADY] > 22)
	{
		g_iCnt[client][C_STEADY] = -1;
		ResetHit2(client);
	}
}

/**
 * AGTWS Mode:100 and AMSAF Mode:101 (R52 attack section of OnPlayerRunCmd)
 */
CheckAttack(client, buttons, const Float:vel[3], const Float:angles[3], cmdnum)
{
	if (!(buttons & IN_ATTACK))
	{
		g_iSnapCmd[client] = 0;
		return;
	}

	if (!(g_iPrevButtons[client] & IN_ATTACK))
	{
		/* +attack press: remember a snap for AGTWS, arm AMSAF. */
		if (g_fDYaw[client] >= g_fThr3[client])
			g_iSnapCmd[client] = cmdnum;

		if (g_iTriggerUntil[client] == -1)
		{
			ResetAmsaf(client);
			if (GroupEnabled(G_AMSAF))
				ArmAmsaf(client, vel, cmdnum);
		}
	}

	CheckAgtws(client, angles, cmdnum);
}

CheckAgtws(client, const Float:angles[3], cmdnum)
{
	if (g_iSnapCmd[client] <= 0 || !GroupEnabled(G_AGTWS) || g_fDYaw[client] != 0.0)
		return;

	/* Yaw froze exactly after the snap, while pitch was still corrected. */
	if (cmdnum - g_iSnapCmd[client] <= AGTWS_WINDOW
		&& (g_fPrevAng[client][0] != angles[0] || g_fPrevAng[client][1] != angles[1]))
	{
		if (g_bGrenade[client])
			ResetPrg(client);
		else if (TraceTarget(client, angles, 0) > 0)
			Detect(client, G_AGTWS, C_AGTWS, DECAY_LONG, "AimBot (Automatic Route Guidance When a Shot)", "Mode:100");
	}

	g_iSnapCmd[client] = 0;
}

ResetAmsaf(client)
{
	g_iAmsStage[client] = 0;
	g_iAmsStep[client] = 0;
	g_iAmsScore[client] = 0;
	g_bAmsFlat[client] = false;
}

/* Bucket of a mouse delta in units of s: 0 (none), 1..cap (m <= k*s), cap+1 above. */
Bucket(m, s, cap)
{
	if (m <= 0)
		return 0;
	for (new k = 1; k <= cap; k++)
	{
		if (m <= k * s)
			return k;
	}
	return cap + 1;
}

ArmAmsaf(client, const Float:vel[3], cmdnum)
{
	/* Standing still (no wishmove) at the press, or the mouse was moving while attacking. */
	if (vel[0] == 0.0 && vel[1] == 0.0)
		g_iAmsStillCmd[client] = cmdnum;
	if (cmdnum - g_iAmsStillCmd[client] > 1)
		return;

	g_iAmsWindowEnd[client] = cmdnum + AMS_WINDOW;

	/* The view must have moved since the last cmd with mouse input. */
	decl Float:vEye[3];
	GetClientEyeAngles(client, vEye);
	if (vEye[0] == g_fLastMouseAng[client][0] && vEye[1] == g_fLastMouseAng[client][1])
		return;

	g_fAmsEye[client][0] = vEye[0];
	g_fAmsEye[client][1] = vEye[1];
	g_iAmsScore[client] = 0;

	new s = g_iSensRound[client];
	new m0 = g_iLastMouse[client][0];
	new m1 = g_iLastMouse[client][1];
	g_iAmsAccum[client][0] = m0;
	g_iAmsAccum[client][1] = m1;

	new b0 = Bucket(m0, s, 7);
	new b1 = Bucket(m1, s, 7);

	new bool:bArm = false;
	if (b0 == 8 || b1 == 8)
		bArm = true;
	else if (b0 >= 3 || b1 >= 3)
		bArm = (m0 >= s && m1 >= s && !(m0 < 2 * s && m1 < 2 * s));
	else if (b0 == 2 || b1 == 2)
		bArm = (m0 >= 2 * s && m1 >= 2 * s && !(m0 < 3 * s && m1 < 3 * s));

	if (bArm)
	{
		g_iAmsStage[client] = 1;
		g_iAmsStep[client] = 1;
	}
}

/* Mouse moving on the ground (R52 runs this inside the mouse branch). */
CheckAmsafHeld(client, buttons, const Float:angles[3], cmdnum)
{
	if (!(buttons & IN_ATTACK))
	{
		if (g_iAmsStage[client] > 1)
			AmsafEvaluate(client);
		return;
	}

	if (cmdnum > g_iAmsWindowEnd[client])
	{
		ResetAmsaf(client);
	}
	else if (g_iAmsStage[client] > 0)
	{
		g_iAmsStage[client]++;

		new s = g_iSensRound[client];
		new m0 = g_iLastMouse[client][0];
		new m1 = g_iLastMouse[client][1];

		if (g_iAmsStage[client] == 2 && g_iAmsStep[client] == 1)
		{
			decl Float:vEye[3];
			GetClientEyeAngles(client, vEye);
			if (g_fAmsEye[client][0] == vEye[0] || g_fAmsEye[client][1] == vEye[1])
			{
				ResetAmsaf(client);
			}
			else
			{
				g_iAmsAccum[client][0] += m0;
				g_iAmsAccum[client][1] += m1;
				new sum = g_iAmsAccum[client][0] + g_iAmsAccum[client][1];

				new b0 = Bucket(m0, s, 7);
				new b1 = Bucket(m1, s, 7);
				new bool:bHit = false;
				if (b0 == 8 || b1 == 8)
					bHit = (9 * s <= sum);
				else if (b0 >= 3 || b1 >= 3)
					bHit = (m0 >= s && m1 >= s && 9 * s <= sum);
				else if (b0 == 2 || b1 == 2)
					bHit = (m0 >= 2 * s && m1 >= 2 * s && 9 * s <= sum);

				if (bHit)
				{
					g_iAmsScore[client]++;
					g_iAmsStep[client] = 2;
				}
				if (g_iAmsStep[client] == 2 && TraceTarget(client, angles, 0) > 0)
					g_iAmsScore[client]++;
			}
		}
		else if (g_iAmsStage[client] == 3 && g_iAmsStep[client] == 2)
		{
			new b0 = Bucket(m0, s, 2);
			new b1 = Bucket(m1, s, 2);
			new bool:bHit = false;
			if (b0 == 3 || b1 == 3)
				bHit = !(m0 < 2 * s || m1 < 2 * s || m0 > 5 * s || m1 > 5 * s);
			else if (b0 == 2 || b1 == 2)
				bHit = !(m0 < s || m1 < s || m0 > 3 * s || m1 > 3 * s);
			else if (b0 == 1 || b1 == 1)
				bHit = !((m0 <= 0 && m1 <= 0) || m0 > 2 * s || m1 > 2 * s);

			if (bHit)
			{
				g_iAmsScore[client]++;
				g_iAmsStep[client] = 3;
			}
			if (g_iAmsStep[client] == 3 && TraceTarget(client, angles, 0) > 0)
				g_iAmsScore[client]++;
		}

		if (angles[0] == g_fLastMouseAng[client][0] || angles[1] == g_fLastMouseAng[client][1])
			g_bAmsFlat[client] = true;
	}

	g_iAmsStillCmd[client] = cmdnum;
}

/* End of the shot (R52 fn_185afc). */
AmsafEvaluate(client)
{
	new score = g_iAmsScore[client];
	new stage = g_iAmsStage[client];
	new bool:bFlat = g_bAmsFlat[client];
	ResetAmsaf(client);

	if (score <= 1 || (!bFlat && stage > 3))
		return;

	if (g_bGrenade[client])
	{
		ResetPrg(client);
		return;
	}

	g_iCnt[client][C_AMSAF] += score;

	decl String:sWeapon[32], String:sMode[32];
	GetClientWeapon(client, sWeapon, sizeof(sWeapon));
	FormatEx(sMode, sizeof(sMode), "Mode:101 | score %i", score);
	if (Evaluate(client, G_AMSAF, C_AMSAF, 480.0, "AimBot (Analysis Module Shooting After Firing)", sMode, sWeapon))
		return;

	/* R52 schedules one decay per score point (480 / 540 / 600 s). */
	if (g_iCnt[client][C_AMSAF] > -1)
	{
		ScheduleDecay(client, C_AMSAF, 540.0);
		if (score > 2)
			ScheduleDecay(client, C_AMSAF, 600.0);
	}
}

ResetPrg(client)
{
	/* R52 fn_34af34(14): grenades in hand reset the aim streaks. */
	g_iCnt[client][C_STREAK] = -1;
	g_iCnt[client][C_STEADY] = -1;
	ResetHit1(client);
	ResetHit2(client);
}

/**
 * Target trace (R52 fn_35cd2c). Returns the enemy client or -1.
 */
TraceTarget(client, const Float:angles[3], mode)
{
	decl Float:vEye[3], Float:vAng[3], Float:vEnd[3];
	GetClientEyePosition(client, vEye);
	vAng[0] = angles[0];
	vAng[1] = angles[1];
	vAng[2] = angles[2];

	if (mode == 1 || mode == 2)
	{
		if (g_iLastHit[client] < 1)
		{
			if (g_fProbe[client] > 0.1)
				g_fProbe[client] = 0.005;
			else
				g_fProbe[client] += 0.01;
		}
		vAng[1] += g_fProbe[client];
		if (vAng[1] >= 360.0)
			vAng[1] -= 360.0;
		vEye[2] -= g_fProbe[client] * 180.0;
	}

	new Handle:tr = TR_TraceRayFilterEx(vEye, vAng, MASK_SHOT, RayType_Infinite, TraceFilter_NotSelf, client);
	if (!TR_DidHit(tr))
	{
		CloseHandle(tr);
		g_iHit2b[client] = 0;
		g_iLastHit[client] = 0;
		return -1;
	}

	new ent = TR_GetEntityIndex(tr);
	g_iLastHit[client] = ent;

	if (!IS_CLIENT(ent) || !IsClientInGame(ent) || GetClientTeam(ent) == GetClientTeam(client))
	{
		CloseHandle(tr);
		g_iHit2b[client] = 0;
		return -1;
	}

	TR_GetEndPosition(vEnd, tr);
	if (GetVectorDistance(vEye, vEnd, true) < MIN_TARGET_DIST_SQ)
	{
		CloseHandle(tr);
		g_iHit2b[client] = 0;
		return -1;
	}

	new hg = TR_GetHitGroup(tr);
	CloseHandle(tr);

	if (mode == 1)
	{
		if (++g_iHit1[client][0] > 5)
		{
			ResetHit1(client);
		}
		else
		{
			if (!g_iHit1[client][2])
			{
				g_iHit1[client][2] = hg;
			}
			else if (!g_iHit1[client][3] && g_iHit1[client][2] != hg)
			{
				g_iHit1[client][3] = hg;
				g_iHit1[client][1]--;
			}
			else if (g_iHit1[client][2] != hg && g_iHit1[client][3] != hg)
			{
				g_iHit1[client][1] = -1;
			}

			if (hg == g_iHit1[client][2] || hg == g_iHit1[client][3])
				g_iHit1[client][1]++;
		}
	}
	else if (mode == 2)
	{
		if (++g_iHit2[client][0] > 11)
		{
			ResetHit2(client);
		}
		else
		{
			if (!g_iHit2[client][2])
			{
				g_iHit2[client][2] = hg;
			}
			else if (!g_iHit2[client][3] && g_iHit2[client][2] != hg)
			{
				g_iHit2[client][3] = hg;
				g_iHit2[client][1] -= 2;
				g_iHit2b[client]--;
			}
			else if (g_iHit2[client][2] != hg && g_iHit2[client][3] != hg)
			{
				g_iHit2[client][1] = -1;
				g_iHit2b[client] = -1;
			}

			if (hg == g_iHit2[client][2] || hg == g_iHit2[client][3])
			{
				g_iHit2[client][1]++;
				g_iHit2b[client]++;
			}
		}
	}

	return ent;
}

public bool:TraceFilter_NotSelf(entity, contentsMask, any:client)
{
	return entity != client;
}

/**
 * UsingWH Mode:103 (R52 fn_37ba38 / fn_138a8). Despite the name it does not use the
 * anti-wallhack: the first shot after +attack (and every third one after it) opens a
 * 6-tick window; on ground and without mouse input the per-axis aim change above thr2
 * is summed. If the shot did damage and the sum reached thr5 = max(sens / 8.5, 0.2),
 * the counter grows. R52 Mode:102 is not ported: its state never leaves -1 in R52.
 */
UsingWhCmd(client, buttons, const Float:angles[3], const mouse[2])
{
	g_fWhAng[client][1][0] = g_fPrevAng[client][0];
	g_fWhAng[client][1][1] = g_fPrevAng[client][1];
	g_fWhAng[client][0][0] = angles[0];
	g_fWhAng[client][0][1] = angles[1];
	g_bWhNoMouse[client] = (g_iWhPrevMouse[client] == 0 && mouse[0] == 0 && mouse[1] == 0);
	g_iWhPrevMouse[client] = mouse[0];
	g_bWhGround[client] = (GetEntityFlags(client) & FL_ONGROUND) != 0;

	if (buttons & IN_ATTACK)
	{
		WhProcess(client);

		if (!(g_iPrevButtons[client] & IN_ATTACK))
		{
			g_fWhSum[client] = 0.0;
			g_iWhShots[client] = 0;
			g_iWhDmg[client] = 0;
		}
	}
	else
	{
		if (g_iWhDmg[client] > 0)
			WhEvaluate(client);
		g_iWhDmg[client] = 0;
	}
}

/* R52 hooks the FireBullets temp entity ("Shotgun Shot" in CS:S). */
public Action:TE_FireBullets(const String:te_name[], const clients[], numClients, Float:delay)
{
	new client = TE_ReadNum("m_iPlayer") + 1;
	if (!IsPlaying(client) || !GroupEnabled(G_USINGWH))
		return Plugin_Continue;

	new tick = GetGameTickCount();
	if (g_iWhShotTick[client] == tick)
		return Plugin_Continue;

	if (++g_iWhShots[client] == 1)
	{
		if (g_iWhDmg[client] > 0)
			WhEvaluate(client);
		if (g_iWhEnd[client] != 0)
			ResetWh(client);

		g_iWhEnd[client] = tick + WH_WINDOW;
		g_iWhShotTick[client] = tick;
		WhProcess(client);
	}
	else if (g_iWhShots[client] > 2)
	{
		g_iWhShots[client] = 0;
	}
	return Plugin_Continue;
}

WhProcess(client)
{
	new tick = GetGameTickCount();
	if (g_iWhEnd[client] < tick)
	{
		if (g_iWhEnd[client] != 0)
		{
			if (g_iWhDmg[client] > 0)
				WhEvaluate(client);
			ResetWh(client);
		}
		return;
	}

	if (g_iWhLastTick[client] == tick)
		return;
	g_iWhLastTick[client] = tick;

	if (!g_bWhGround[client] || !g_bWhNoMouse[client])
	{
		g_fWhSum[client] = 0.0;
		return;
	}

	for (new axis = 0; axis < 2; axis++)
	{
		new Float:d = FloatAbs(FloatAbs(NormalizeAngle(g_fWhAng[client][0][axis])) - FloatAbs(NormalizeAngle(g_fWhAng[client][1][axis])));
		if (d > g_fThr2[client])
			g_fWhSum[client] += d;
	}
}

WhEvaluate(client)
{
	if (g_bSensKnown[client] && g_fWhSum[client] >= g_fThr5[client])
	{
		ResetWh(client);
		Detect(client, G_USINGWH, C_USINGWH, DECAY_LONG, "AimBot (Using WH)", "Mode:103");
		return;
	}
	g_fWhSum[client] = 0.0;
}

ResetWh(client)
{
	g_iWhEnd[client] = 0;
	g_iWhShotTick[client] = 0;
	g_iWhDmg[client] = 0;
	g_iWhLastTick[client] = 0;
	g_fWhSum[client] = 0.0;
}

Float:NormalizeAngle(Float:angle)
{
	if (angle > 180.0)
		angle -= 360.0;
	return angle;
}

/**
 * Accurate Analysis Module (player_hurt / player_death)
 */
public Event_PlayerHurt(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (GetEventInt(event, "health") <= 0 || GetEventInt(event, "dmg_health") < 10)
		return;

	new victim = GetClientOfUserId(GetEventInt(event, "userid"));
	new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	AnalyzeHit(event, attacker, victim, false, false, GetEventInt(event, "dmg_health"));
}

public Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new victim = GetClientOfUserId(GetEventInt(event, "userid"));
	new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));

	/* R52: the victim's aim counters relax on death. */
	if (IS_CLIENT(victim) && IsClientInGame(victim))
	{
		RelaxOnDeath(victim, C_TRIGGER, DECAY_LONG);
		RelaxOnDeath(victim, C_AGT, DECAY_LONG);
		RelaxOnDeath(victim, C_AGTAF1, DECAY_LONG);
	}

	AnalyzeHit(event, attacker, victim, GetEventBool(event, "headshot"), true, 100);
}

RelaxOnDeath(client, counter, Float:delay)
{
	if (g_iCnt[client][counter] > 1)
		ScheduleDecay(client, counter, delay);
	else if (g_iCnt[client][counter] > -1)
		g_iCnt[client][counter]--;
}

AnalyzeHit(Handle:event, attacker, victim, bool:headshot, bool:kill, dmg)
{
	if (!IS_CLIENT(attacker) || !IS_CLIENT(victim) || attacker == victim)
		return;
	if (!IsClientInGame(attacker) || !IsClientInGame(victim) || IsFakeClient(attacker) || !IsPlayerAlive(attacker))
		return;

	decl String:sWeapon[32];
	GetEventString(event, "weapon", sWeapon, sizeof(sWeapon));
	new dummy;
	if (GetTrieValue(g_hTrieExclude, sWeapon, dummy))
		return;

	decl Float:vA[3], Float:vV[3];
	GetClientAbsOrigin(attacker, vA);
	GetClientAbsOrigin(victim, vV);
	new Float:dist = GetVectorDistance(vA, vV, true);
	if (dist < MIN_TARGET_DIST_SQ)
		return;

	/* R52 Accurate Analysis adds the damage to the UsingWH window (whState[6]). */
	g_iWhDmg[attacker] += dmg;

	new bool:bPistol = GetTrieValue(g_hTriePistol, sWeapon, dummy);
	new bool:bSniper = GetTrieValue(g_hTrieSniper, sWeapon, dummy);

	/* AGT / Trigger: the aim was still turning without mouse input at the hit. */
	new Float:dYaw = g_fDYaw[attacker];
	new streak = g_iCnt[attacker][C_STREAK];
	if ((dYaw >= g_fThr3[attacker] && streak > -1) || (dYaw > g_fThr2[attacker] && streak > 0))
	{
		new w = 0;
		if (kill)
		{
			if (dYaw > 2.0)
				w = (streak > 1) ? 3 : 2;
			else if (dYaw > 0.6)
				w = (streak > 1) ? 2 : 1;
			else if (dYaw > 0.4)
				w = 1;
		}

		new add = w + HitBonus(dist, headshot, bPistol, bSniper);

		if (GroupEnabled(G_AGT))
		{
			g_iCnt[attacker][C_AGT] += add;
			if (Evaluate(attacker, G_AGT, C_AGT, DECAY_LONG, "AimBot (Automatic Route Guidance)", kill ? "Mode:299" : "Mode:288", sWeapon))
				return;
		}

		if (GroupEnabled(G_TR) && g_iTriggerUntil[attacker] != -1 && g_iCmd[attacker] <= g_iTriggerUntil[attacker])
		{
			g_iCnt[attacker][C_TRIGGER] += add;
			if (Evaluate(attacker, G_TR, C_TRIGGER, DECAY_LONG, "AimBot (Trigger)", kill ? "Mode:199" : "Mode:188", sWeapon))
				return;
		}
	}

	/* AGTAF: hits during the PRG 303 steady-mouse streak with stable hitgroups. */
	if (!GroupEnabled(G_AGTAF))
		return;

	new steady = g_iCnt[attacker][C_STEADY];
	new hits = g_iHit2[attacker][1];
	new hitsB = g_iHit2b[attacker];

	if (steady > 2 && steady < 5)
	{
		if (hitsB > 2 && hits == hitsB)
		{
			g_iCnt[attacker][C_STEADY] = -1;
			g_iCnt[attacker][C_AGTAF1] += headshot ? 2 : 1;
			Evaluate(attacker, G_AGTAF, C_AGTAF1, DECAY_LONG, "AimBot (Automatic Route Guidance After Firing)", kill ? "Mode:99" : "Mode:88", sWeapon);
		}
	}
	else if (steady >= 5)
	{
		if ((hitsB > 2 && hits >= 5) || (hitsB >= 4 && hits >= 4))
		{
			g_iCnt[attacker][C_STEADY] = -1;
			g_iCnt[attacker][C_AGTAF2] += headshot ? 2 : 1;
			Evaluate(attacker, G_AGTAF, C_AGTAF2, DECAY_LONG, "AimBot (Automatic Route Guidance After Firing)", kill ? "Mode:109" : "Mode:108", sWeapon);
		}
	}
}

/* R52 AAM bonus by distance band, headshot and weapon group. */
HitBonus(Float:dist, bool:headshot, bool:bPistol, bool:bSniper)
{
	if (dist < DIST_NEAR_SQ)
	{
		if (headshot)
			return bPistol ? 1 : (bSniper ? 3 : 2);
		return bSniper ? 2 : 1;
	}

	if (dist <= DIST_FAR_SQ)
	{
		if (headshot)
			return bPistol ? 3 : 2;
		return bPistol ? 2 : 1;
	}

	if (headshot)
		return bSniper ? 2 : (bPistol ? 3 : 2);
	return bPistol ? 2 : 1;
}

/**
 * Reporting (R52 semantics)
 */
bool:GroupEnabled(group)
{
	return GetConVarInt(g_hCvarWarn[group]) > 0 || GetConVarInt(g_hCvarBan[group]) != 0;
}

/* Counter already incremented by the caller; returns true if the client was removed.
   Like R52, nothing is reported below the Warning value; each step schedules a decay. */
bool:Evaluate(client, group, counter, Float:delay, const String:name[], const String:mode[], const String:weapon[])
{
	new ban = GetConVarInt(g_hCvarBan[group]);
	new warn = GetConVarInt(g_hCvarWarn[group]);
	new value = g_iCnt[client][counter];

	new bool:bPunish = (ban != 0 && value > AbsValue(ban) && !IsImmune(client));
	new bool:bNotice = (warn > 0 && value >= warn);

	if (!bPunish)
		ScheduleDecay(client, counter, delay);

	if (!bPunish && !bNotice)
		return false;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "counter", value);
	KvSetString(info, "mode", mode);
	KvSetFloat(info, "dyaw", g_fDYaw[client]);
	new Action:result = SMAC_CheatDetected(client, Detection_UltraAim, info);
	CloseHandle(info);

	if (result != Plugin_Continue)
		return false;

	SMAC_LogAction(client, "%s %s | Weapon:%s (counter %i, dYaw %.3f, thr %.3f)", name, mode, weapon, value, g_fDYaw[client], g_fThr2[client]);
	SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, name, value);

	if (!bPunish)
		return false;

	g_iCnt[client][counter] = -2;

	new action = LowerAction(client, (ban > 0) ? 3 : 2);
	if (action == 3)
	{
		SMAC_LogAction(client, "was banned for %s %s.", name, mode);
		SMAC_Ban(client, "%s %s", name, mode);
		return true;
	}
	if (action == 2)
	{
		SMAC_LogAction(client, "was kicked for %s %s.", name, mode);
		KickClient(client, "%t", "SMAC_UltraKick");
		return true;
	}

	SMAC_LogAction(client, "%s: punishment lowered to a notice (connection).", name);
	return false;
}

/* For detectors whose counter is incremented here. */
Detect(client, group, counter, Float:delay, const String:name[], const String:mode[])
{
	g_iCnt[client][counter]++;

	decl String:sWeapon[32];
	GetClientWeapon(client, sWeapon, sizeof(sWeapon));
	Evaluate(client, group, counter, delay, name, mode, sWeapon);
}

/**
 * R52 SetBan(client, code, delay) -> OnBanReleased: decrement the counter after the delay,
 * postponed while the player is not on a team.
 */
ScheduleDecay(client, counter, Float:delay)
{
	new Handle:pack;
	CreateDataTimer(delay, Timer_Decay, pack, TIMER_FLAG_NO_MAPCHANGE);
	WritePackCell(pack, GetClientUserId(client));
	WritePackCell(pack, counter);
	WritePackFloat(pack, delay);
}

public Action:Timer_Decay(Handle:timer, Handle:pack)
{
	ResetPack(pack);
	new client = GetClientOfUserId(ReadPackCell(pack));
	new counter = ReadPackCell(pack);
	new Float:delay = ReadPackFloat(pack);

	if (!IS_CLIENT(client) || !IsClientInGame(client) || g_iCnt[client][counter] <= -1)
		return Plugin_Stop;

	if (GetClientTeam(client) > 1)
		g_iCnt[client][counter]--;
	else
		ScheduleDecay(client, counter, delay);

	return Plugin_Stop;
}

/**
 * Helpers
 */
bool:IsPlaying(client)
{
	return IS_CLIENT(client) && IsClientInGame(client) && !IsFakeClient(client)
		&& IsPlayerAlive(client) && !IsClientObserver(client);
}

bool:IsHoldingGrenade(client)
{
	decl String:sWeapon[32];
	GetClientWeapon(client, sWeapon, sizeof(sWeapon));
	new dummy;
	return GetTrieValue(g_hTrieGrenade, sWeapon, dummy);
}

bool:HasWeapon(client)
{
	decl String:sWeapon[32];
	GetClientWeapon(client, sWeapon, sizeof(sWeapon));
	return sWeapon[0] != '\0';
}

GetFov(client)
{
	new fov = GetEntProp(client, Prop_Send, "m_iFOV");
	return (fov <= 0) ? 90 : fov;
}

bool:IsImmune(client)
{
	return GetConVarBool(g_hCvarAdminImmune) && (GetUserFlagBits(client) & (ADMFLAG_BAN | ADMFLAG_ROOT)) != 0;
}

/* R52 network gate: lower ban -> kick -> notice once for bad ping and once for few packets. */
LowerAction(client, action)
{
	if (action > 1 && GetClientAvgLatency(client, NetFlow_Outgoing) >= 0.15)
		action--;

	if (action > 1 && GetClientAvgPackets(client, NetFlow_Incoming) <= 0.7 / GetTickInterval())
		action--;

	return action;
}
