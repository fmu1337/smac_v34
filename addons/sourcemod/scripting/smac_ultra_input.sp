#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC Ultr@ R52 port: weapon / input detectors.
 *
 * Rewritten from 001_SMAC_Global.smx of SMAC Ultr@ R52 as decompiled with
 * tools/r52re/decomp.py (docs/R52_SPEC.md §3, §5, §6, §6b; docs/ULTRA_INPUT.md).
 * No Ultr@ code and no Ultr@Tools extension is used.
 *
 * AutoTrigger (R52 fn_37a058, smac_autotrigger_ban):
 *   A button state that flips on every cmd (one steady cmd in between is tolerated) is a
 *   burst: +attack 5 flips (Auto-Fire), +moveleft / +moveright 5 (Auto-Strafe), +duck 5
 *   (Auto-Duck), +jump 25 (Auto-Scroll). Holding +left and +right more than 6 cmds each
 *   within one second is an AutoHotKeys burst. 7 bursts of one type = detection; every
 *   type loses one burst every 4 s.
 * Advanced Trigger (code 305): +attack pressed again after a press that lasted exactly 1 cmd.
 * Advanced AutoFire (code 306): checked every second - the last +attack press lasted
 *   exactly 1 cmd and the button is released now.
 * Fast AIM Detect (code 408): +attack pressed on a cmd where pitch and yaw both changed
 *   opens a 6-tick window; damage inside it extends the window by 6 ticks. Releasing the
 *   button inside the window with the angles exactly equal to the previous cmd's.
 * Recoil Control System -F / -H: inside that window |dPitch| + |dYaw| of every cmd is
 *   summed per second; the cmd that landed a hit goes to the -H sum instead. -F: sum > 40
 *   in 10 seconds; -H: sum > 4 in 4 seconds (each such second decays in 420 s).
 * CheatCFG (smac_css_CheatCFG):
 *   Stop Movement  - +attack alone right after a cmd with exactly one movement key
 *                    (or forward/back + one side key), more than 7 times;
 *   Fast Switch    - the weapon is switched at most 2 ticks after +attack while it is held,
 *                    more than 7 times;
 *   Fast Reload    - the weapon's attack timers change while the same weapon is held, no
 *                    new shot was fired and the clip at the last shot was not empty; 3 times.
 *
 * Knife, grenades and world damage are skipped (R52 trie 4103/4104).
 * Cvars keep the Ultr@ names. Defaults are admin-notice only.
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: Input",
	author = SMAC_AUTHOR,
	description = "AutoTrigger, Advanced Trigger/AutoFire, Fast AIM, RCS and CheatCFG from SMAC Ultr@ R52",
	version = SMAC_VERSION,
	url = SMAC_URL
};

/* AutoTrigger types (R52 fn_37a058 argument). */
#define AT_FIRE				1
#define AT_STRAFE_LEFT		2
#define AT_STRAFE_RIGHT		3
#define AT_DUCK				4
#define AT_SCROLL			5
#define AT_HOTKEYS			6
#define AT_COUNT			7

new String:g_sAutoTrigger[AT_COUNT][] =
{
	"BunnyHop",
	"Auto-Fire",
	"Auto-Strafe [Left]",
	"Auto-Strafe [Right]",
	"Auto-Duck",
	"Auto-Scroll",
	"Auto-Strafe"
};

/* Button slots for the flip counters. */
#define B_ATTACK			0
#define B_JUMP				1
#define B_LEFT				2
#define B_RIGHT				3
#define B_DUCK				4
#define B_COUNT				5

#define AT_FLIPS			5
#define AT_FLIPS_SCROLL		25
#define AT_BURSTS			7
#define AT_DECAY_PERIOD		4
#define HOTKEY_CMDS			6

/* Warning/Ban counters. */
#define C_ADVTRIGGER		0
#define C_AUTOFIRE			1
#define C_FASTAIM			2
#define C_RCS_H				3
#define C_RCS_F				4
#define C_STOPMOVE			5
#define C_FASTSWITCH		6
#define C_FASTRELOAD		7
#define C_COUNT				8

#define DECAY				420.0
#define FASTAIM_WINDOW		6
#define RCS_H_SECONDS		2
#define RCS_F_SECONDS		8
#define CFG_STOPMOVE		7
#define CFG_FASTSWITCH		7
#define CFG_FASTSWITCH_TICKS	2
#define CFG_FASTRELOAD		1

#define MIN_HIT_DIST_SQ		40000.0
#define MIN_HIT_DMG			10

#define MAX_PING			0.15
#define MIN_PACKET_FRAC		0.7

new Handle:g_hCvarAutoTrigger = INVALID_HANDLE;
new Handle:g_hCvarTriggerWarn = INVALID_HANDLE;
new Handle:g_hCvarTriggerBan = INVALID_HANDLE;
new Handle:g_hCvarAutoFireWarn = INVALID_HANDLE;
new Handle:g_hCvarAutoFireBan = INVALID_HANDLE;
new Handle:g_hCvarFastAimWarn = INVALID_HANDLE;
new Handle:g_hCvarFastAimBan = INVALID_HANDLE;
new Handle:g_hCvarRcsHurt = INVALID_HANDLE;
new Handle:g_hCvarRcsFire = INVALID_HANDLE;
new Handle:g_hCvarRcsNotice = INVALID_HANDLE;
new Handle:g_hCvarCheatCfg = INVALID_HANDLE;
new Handle:g_hCvarAdminImmune = INVALID_HANDLE;

new Handle:g_hTrieExclude = INVALID_HANDLE;

new g_iCnt[MAXPLAYERS+1][C_COUNT];
new g_iPrevButtons[MAXPLAYERS+1];
new Float:g_fPrevAng[MAXPLAYERS+1][2];
new bool:g_bHasPrev[MAXPLAYERS+1];

/* AutoTrigger */
new g_iFlips[MAXPLAYERS+1][B_COUNT];
new bool:g_bSteady[MAXPLAYERS+1][B_COUNT];
new g_iBursts[MAXPLAYERS+1][AT_COUNT];
new g_iHotkeyLeft[MAXPLAYERS+1];
new g_iHotkeyRight[MAXPLAYERS+1];
new g_iSecond;

/* Advanced Trigger / AutoFire (R52 g4d81c[0], g4d81c[1]) */
new g_iClickButtons[MAXPLAYERS+1];
new bool:g_bReleased[MAXPLAYERS+1];

/* Fast AIM window and RCS sums (R52 g54ca8[7], g54ca8[8], rcs[0..2]) */
new g_iWindowEnd[MAXPLAYERS+1];
new g_iWindowDmg[MAXPLAYERS+1];
new Float:g_fRcsLast[MAXPLAYERS+1];
new Float:g_fRcsFire[MAXPLAYERS+1];
new Float:g_fRcsHurt[MAXPLAYERS+1];

/* CheatCFG: weapon and clip at the last shot, attack timers of the previous cmd. */
new g_iShotWeapon[MAXPLAYERS+1];
new g_iShotClip[MAXPLAYERS+1];
new g_iSeenClip[MAXPLAYERS+1];
new Float:g_fTimers[MAXPLAYERS+1][3];
new g_iPressTick[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarAutoTrigger = SMAC_CreateConVar("smac_autotrigger_ban", "0", "AutoTrigger (Auto-Fire/Strafe/Duck/Scroll), Advanced BunnyHop, HaX2, Auto-Jump: -1=off, 0=admin notice, 1=kick, 2=ban, 3/4=kick/ban for Auto-Fire only (R52: 2)", _, true, -1.0, true, 4.0);
	g_hCvarTriggerWarn = SMAC_CreateConVar("smac_AdvancedTrigger_Warning", "3", "Advanced Trigger detections before admins are notified. (0 = never)", _, true, 0.0);
	g_hCvarTriggerBan = SMAC_CreateConVar("smac_AdvancedTrigger_Ban", "0", "Advanced Trigger: +N ban / -N kick after more than N detections, 0 = never (R52: 5)", _, true, -100.0, true, 100.0);
	g_hCvarAutoFireWarn = SMAC_CreateConVar("smac_AdvancedAutoFire_Warning", "3", "Advanced AutoFire detections before admins are notified. (0 = never)", _, true, 0.0);
	g_hCvarAutoFireBan = SMAC_CreateConVar("smac_AdvancedAutoFire_Ban", "0", "Advanced AutoFire: +N ban / -N kick after more than N detections, 0 = never (R52: 5)", _, true, -100.0, true, 100.0);
	g_hCvarFastAimWarn = SMAC_CreateConVar("smac_Fast_AIM_Detect_Warning", "3", "Fast AIM Detect detections before admins are notified. (0 = never)", _, true, 0.0);
	g_hCvarFastAimBan = SMAC_CreateConVar("smac_Fast_AIM_Detect_Ban", "0", "Fast AIM Detect: +N ban / -N kick after more than N detections, 0 = never (R52: 5)", _, true, -100.0, true, 100.0);
	g_hCvarRcsHurt = SMAC_CreateConVar("smac_Advanced_Eye_Angle_Test_Hurt", "4", "Recoil Control System -H: max aim change per second on hits, +N = ban, -N = kick, 0 = off", _, true, -1000.0, true, 1000.0);
	g_hCvarRcsFire = SMAC_CreateConVar("smac_Advanced_Eye_Angle_Test_Fire", "-40", "Recoil Control System -F: max aim change per second while firing, +N = ban, -N = kick, 0 = off", _, true, -1000.0, true, 1000.0);
	g_hCvarRcsNotice = SMAC_CreateConVar("smac_Advanced_Eye_Angle_Test_notice_only", "1", "Recoil Control System: only notify admins instead of the kick/ban set by the sign.", _, true, 0.0, true, 1.0);
	g_hCvarCheatCfg = SMAC_CreateConVar("smac_css_CheatCFG", "1", "CheatCFG (Stop Movement, Fast Switch, Fast Reload): 0=off, 1=admin notice, 2=kick, 3=ban (4-6 = same, R52 league mode) (R52: 3)", _, true, 0.0, true, 6.0);
	g_hCvarAdminImmune = SMAC_CreateConVar("smac_ultra_admin_immune", "1", "Never kick/ban admins with ban/root flag (detections are still logged).", _, true, 0.0, true, 1.0);

	g_hTrieExclude = CreateTrie();
	FillTrie(g_hTrieExclude, "knife tknifehs tknife env_explosion hegrenade flashbang smokegrenade hegrenade_projectile flashbang_projectile smokegrenade_projectile entityflame worldspawn world watermelon watermelon_projectile");

	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
	AddTempEntHook("Shotgun Shot", TE_FireBullets);

	CreateTimer(1.0, Timer_Second, _, TIMER_REPEAT);

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
	g_iCnt[client][C_STOPMOVE] = 0;

	for (new i = 0; i < B_COUNT; i++)
	{
		g_iFlips[client][i] = 0;
		g_bSteady[client][i] = false;
	}
	for (new i = 0; i < AT_COUNT; i++)
		g_iBursts[client][i] = 0;

	g_iPrevButtons[client] = 0;
	g_bHasPrev[client] = false;
	g_iHotkeyLeft[client] = 0;
	g_iHotkeyRight[client] = 0;
	g_iClickButtons[client] = 0;
	g_bReleased[client] = false;
	g_iWindowEnd[client] = -1;
	g_iWindowDmg[client] = -1;
	g_fRcsLast[client] = 0.0;
	g_fRcsFire[client] = 0.0;
	g_fRcsHurt[client] = 0.0;
	g_iShotWeapon[client] = INVALID_ENT_REFERENCE;
	g_iShotClip[client] = 0;
	g_iSeenClip[client] = 0;
	g_fTimers[client][0] = g_fTimers[client][1] = g_fTimers[client][2] = 0.0;
	g_iPressTick[client] = 0;
}

/* R52 hooks the FireBullets temp entity ("Shotgun Shot" in CS:S); the clip is already
   decremented when it is sent. */
public Action:TE_FireBullets(const String:te_name[], const clients[], numClients, Float:delay)
{
	new client = TE_ReadNum("m_iPlayer") + 1;
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Continue;

	new weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon > MaxClients && IsValidEntity(weapon))
	{
		g_iShotWeapon[client] = EntIndexToEntRef(weapon);
		g_iShotClip[client] = GetEntProp(weapon, Prop_Send, "m_iClip1");
	}
	else
	{
		g_iShotWeapon[client] = INVALID_ENT_REFERENCE;
		g_iShotClip[client] = 0;
	}
	return Plugin_Continue;
}

/**
 * Usercmd analysis
 */
public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!IsPlaying(client))
	{
		g_bHasPrev[client] = false;
		return Plugin_Continue;
	}

	if (!g_bHasPrev[client])
	{
		g_bHasPrev[client] = true;
		Store(client, buttons, angles);
		return Plugin_Continue;
	}

	new prev = g_iPrevButtons[client];

	CheckAutoTrigger(client, buttons, prev);

	if (buttons & IN_ATTACK)
	{
		CheckCheatCfg(client, buttons, prev, tickcount);
		CheckWindow(client, prev, angles, tickcount);

		if (!(prev & IN_ATTACK))
			OnAttackPress(client, buttons, tickcount);
		else
			OnAttackHold(client);
	}
	else
	{
		OnAttackUp(client, prev, angles, tickcount);
	}

	Store(client, buttons, angles);
	return Plugin_Continue;
}

Store(client, buttons, const Float:angles[3])
{
	g_iPrevButtons[client] = buttons;
	g_fPrevAng[client][0] = angles[0];
	g_fPrevAng[client][1] = angles[1];
}

/* R52: a flipped button ends the chain for this cmd (only the first one in this order counts). */
CheckAutoTrigger(client, buttons, prev)
{
	new value = GetConVarInt(g_hCvarAutoTrigger);
	if (value <= -1)
		return;

	/* AutoHotKeys: cmds with +left / +right, judged every second. */
	if (value < 3)
	{
		if (buttons & IN_LEFT)
			g_iHotkeyLeft[client]++;
		else if (buttons & IN_RIGHT)
			g_iHotkeyRight[client]++;
	}

	if (Flip(client, B_ATTACK, IN_ATTACK, AT_FLIPS, AT_FIRE, buttons, prev) || value >= 3)
		return;
	if (Flip(client, B_JUMP, IN_JUMP, AT_FLIPS_SCROLL, AT_SCROLL, buttons, prev))
		return;
	if (Flip(client, B_LEFT, IN_MOVELEFT, AT_FLIPS, AT_STRAFE_LEFT, buttons, prev))
		return;
	if (Flip(client, B_RIGHT, IN_MOVERIGHT, AT_FLIPS, AT_STRAFE_RIGHT, buttons, prev))
		return;
	Flip(client, B_DUCK, IN_DUCK, AT_FLIPS, AT_DUCK, buttons, prev);
}

bool:Flip(client, slot, bit, flips, type, buttons, prev)
{
	if ((buttons & bit) != (prev & bit))
	{
		if (++g_iFlips[client][slot] >= flips)
		{
			g_iFlips[client][slot] = 0;
			AddBurst(client, type);
		}
		g_bSteady[client][slot] = false;
		return true;
	}

	/* One steady cmd between flips is tolerated, two end the chain. */
	if (g_bSteady[client][slot])
	{
		g_iFlips[client][slot] = 0;
		g_bSteady[client][slot] = false;
	}
	else
	{
		g_bSteady[client][slot] = true;
	}
	return false;
}

AddBurst(client, type)
{
	if (++g_iBursts[client][type] < AT_BURSTS)
		return;

	g_iBursts[client][type] = 0;

	/* R52: -1 off, 0 notice, 1/3 kick, 2/4 ban; 3 and 4 only judge Auto-Fire. */
	new value = GetConVarInt(g_hCvarAutoTrigger);
	if (value <= -1 || (value >= 3 && type != AT_FIRE))
		return;

	new action = 1;
	if (value == 1 || value == 3)
		action = 2;
	else if (value == 2 || value == 4)
		action = 3;

	decl String:sDetail[64];
	FormatEx(sDetail, sizeof(sDetail), "%i bursts of button flips", AT_BURSTS);
	React(client, "AutoTrigger", g_sAutoTrigger[type], action, -1, sDetail);
}

/**
 * Advanced Trigger: R52 keeps the buttons of the last +attack press until it is held a
 * second cmd; a new press while they are kept means the previous click lasted 1 cmd.
 */
OnAttackPress(client, buttons, tickcount)
{
	g_iPressTick[client] = tickcount;
	g_bReleased[client] = false;

	new warn = GetConVarInt(g_hCvarTriggerWarn);
	new ban = GetConVarInt(g_hCvarTriggerBan);
	if (!(g_iClickButtons[client] & IN_ATTACK) || (warn <= 0 && ban == 0))
	{
		g_iClickButtons[client] = buttons;
		return;
	}

	g_iClickButtons[client] = 0;
	if (IsExcludedWeapon(client))
		return;

	g_iCnt[client][C_ADVTRIGGER]++;
	Evaluate(client, C_ADVTRIGGER, warn, ban, "Advanced Trigger", "two clicks, the first one 1 cmd long");
}

OnAttackHold(client)
{
	g_iClickButtons[client] = 0;
	g_bReleased[client] = false;
}

OnAttackUp(client, prev, const Float:angles[3], tickcount)
{
	g_bReleased[client] = true;
	g_iPressTick[client] = 0;

	/* Fast AIM Detect: released inside the window after damage, aim frozen on release. */
	if (!(prev & IN_ATTACK) || g_iWindowEnd[client] < tickcount)
	{
		g_iWindowEnd[client] = -1;
		g_iWindowDmg[client] = -1;
		return;
	}

	g_iWindowEnd[client] = -1;
	if (g_iWindowDmg[client] <= 0 || angles[0] != g_fPrevAng[client][0] || angles[1] != g_fPrevAng[client][1])
		return;

	g_iWindowDmg[client] = -1;

	new warn = GetConVarInt(g_hCvarFastAimWarn);
	new ban = GetConVarInt(g_hCvarFastAimBan);
	if (warn <= 0 && ban == 0)
		return;

	g_iCnt[client][C_FASTAIM]++;
	Evaluate(client, C_FASTAIM, warn, ban, "AimBot: Fast AIM Detect", "aim turned on the shot, damage, aim frozen on release");
}

/* R52 opens the window on a press where pitch and yaw both changed and sums the aim
   change of the cmds inside it (Recoil Control System). */
CheckWindow(client, prev, const Float:angles[3], tickcount)
{
	if (GetConVarInt(g_hCvarFastAimWarn) <= 0 && GetConVarInt(g_hCvarFastAimBan) == 0
		&& GetConVarInt(g_hCvarRcsHurt) == 0 && GetConVarInt(g_hCvarRcsFire) == 0)
		return;

	if (angles[0] == g_fPrevAng[client][0] || angles[1] == g_fPrevAng[client][1])
	{
		g_iWindowEnd[client]--;
		return;
	}

	if (!(prev & IN_ATTACK))
	{
		g_iWindowEnd[client] = tickcount + FASTAIM_WINDOW;
		g_iWindowDmg[client] = 0;
	}
	else if (g_iWindowEnd[client] < tickcount)
	{
		g_iWindowEnd[client] = -1;
		g_iWindowDmg[client] = -1;
		return;
	}
	else if (g_iWindowEnd[client] <= 0)
	{
		return;
	}

	g_fRcsLast[client] = FloatAbs(NormalizeAngle(angles[0]) - NormalizeAngle(g_fPrevAng[client][0]))
		+ FloatAbs(NormalizeAngle(angles[1]) - NormalizeAngle(g_fPrevAng[client][1]));
	g_fRcsFire[client] += g_fRcsLast[client];
}

public Event_PlayerHurt(Handle:event, const String:name[], bool:dontBroadcast)
{
	new dmg = GetEventInt(event, "dmg_health");
	if (GetEventInt(event, "health") > 0 && dmg < MIN_HIT_DMG)
		return;

	new victim = GetClientOfUserId(GetEventInt(event, "userid"));
	new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
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
	if (GetVectorDistance(vA, vV, true) < MIN_HIT_DIST_SQ || g_iWindowEnd[attacker] <= 0)
		return;

	/* R52 Accurate Analysis: damage extends the window once; the aim change of the hit cmd
	   moves from the -F sum to the -H sum. */
	if (g_iWindowDmg[attacker] == 0)
		g_iWindowEnd[attacker] += FASTAIM_WINDOW;
	g_iWindowDmg[attacker] += dmg;

	g_fRcsFire[attacker] -= g_fRcsLast[attacker];
	g_fRcsHurt[attacker] += g_fRcsLast[attacker];
	g_fRcsLast[attacker] = 0.0;
}

/**
 * CheatCFG (R52, smac_css_CheatCFG).
 */
CheckCheatCfg(client, buttons, prev, tickcount)
{
	new level = CheatCfgLevel();
	if (level <= 0)
		return;

	/* Stop Movement: +attack alone right after exactly one movement key. */
	if (buttons == IN_ATTACK && IsStopKeys(prev))
	{
		if (++g_iCnt[client][C_STOPMOVE] > CFG_STOPMOVE)
		{
			g_iCnt[client][C_STOPMOVE] = -2;
			React(client, "CheatCFG", "Stop Movement", level, -1, "+attack right after releasing the movement key");
		}
		else
		{
			ScheduleDecay(client, C_STOPMOVE);
		}
	}

	/* The reference turns invalid when the weapon entity is removed. */
	new shotWeapon = EntRefToEntIndex(g_iShotWeapon[client]);
	if (shotWeapon <= MaxClients || g_iShotClip[client] <= 0 || IsExcludedWeapon(client))
		return;

	decl Float:timers[3];
	timers[0] = GetEntPropFloat(shotWeapon, Prop_Send, "m_flNextPrimaryAttack");
	timers[1] = GetEntPropFloat(client, Prop_Send, "m_flNextAttack");
	timers[2] = GetEntPropFloat(shotWeapon, Prop_Send, "m_flNextSecondaryAttack");

	/* A new shot since the previous cmd: only resync. */
	if (g_iSeenClip[client] == g_iShotClip[client]
		&& (timers[0] != g_fTimers[client][0] || timers[1] != g_fTimers[client][1] || timers[2] != g_fTimers[client][2]))
	{
		if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == shotWeapon)
		{
			/* Fast Reload: attack timers reset without a shot on the same weapon. */
			if (++g_iCnt[client][C_FASTRELOAD] > CFG_FASTRELOAD)
			{
				g_iCnt[client][C_FASTRELOAD] = -2;
				React(client, "CheatCFG", "Fast Reload or Shooting of Weapon", level, -1, "attack timers changed without a shot");
				return;
			}
			ScheduleDecay(client, C_FASTRELOAD);
		}
		else
		{
			/* Fast Switch: weapon switched at most 2 ticks after +attack, still held. */
			new dt = tickcount - g_iPressTick[client];
			if (g_iPressTick[client] > 0 && dt >= 0 && dt <= CFG_FASTSWITCH_TICKS)
			{
				g_iPressTick[client] = 0;
				if (++g_iCnt[client][C_FASTSWITCH] > CFG_FASTSWITCH)
				{
					g_iCnt[client][C_FASTSWITCH] = -1;
					React(client, "CheatCFG", "Fast Switch", level, -1, "weapon switched right after +attack");
				}
				else
				{
					ScheduleDecay(client, C_FASTSWITCH);
				}
			}
		}
	}

	g_iSeenClip[client] = g_iShotClip[client];
	g_fTimers[client][0] = timers[0];
	g_fTimers[client][1] = timers[1];
	g_fTimers[client][2] = timers[2];
}

bool:IsStopKeys(prev)
{
	switch (prev)
	{
		case IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT,
			IN_FORWARD | IN_MOVELEFT, IN_FORWARD | IN_MOVERIGHT,
			IN_BACK | IN_MOVELEFT, IN_BACK | IN_MOVERIGHT:
			return true;
	}
	return false;
}

/* R52: 1 notice, 2 kick, 3 ban; 4-6 are the same plus league-only checks. */
CheatCfgLevel()
{
	new value = GetConVarInt(g_hCvarCheatCfg);
	if (value > 3)
		value -= 3;
	return value;
}

/**
 * Second ticker (R52 OnTimerUp)
 */
public Action:Timer_Second(Handle:timer)
{
	new bool:bDecayBursts = false;
	if (GetConVarInt(g_hCvarAutoTrigger) > -1 && ++g_iSecond > AT_DECAY_PERIOD - 1)
	{
		g_iSecond = 0;
		bDecayBursts = true;
	}

	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IS_CLIENT(i) || !IsClientInGame(i) || IsFakeClient(i))
			continue;

		if (bDecayBursts)
		{
			for (new t = 0; t < AT_COUNT; t++)
			{
				if (g_iBursts[i][t] > 0)
					g_iBursts[i][t]--;
			}
		}

		if (IsPlaying(i))
		{
			CheckAutoFire(i);
			CheckRcs(i);

			if (g_iHotkeyLeft[i] > HOTKEY_CMDS && g_iHotkeyRight[i] > HOTKEY_CMDS)
				AddBurst(i, AT_HOTKEYS);
		}

		g_iHotkeyLeft[i] = 0;
		g_iHotkeyRight[i] = 0;
		g_fRcsLast[i] = 0.0;
		g_fRcsFire[i] = 0.0;
		g_fRcsHurt[i] = 0.0;
	}
	return Plugin_Continue;
}

/* Advanced AutoFire: the last +attack press lasted 1 cmd and the button is up now. */
CheckAutoFire(client)
{
	if (!g_bReleased[client])
		return;

	g_bReleased[client] = false;
	if (g_iClickButtons[client] == 0)
		return;

	g_iClickButtons[client] = 0;

	new warn = GetConVarInt(g_hCvarAutoFireWarn);
	new ban = GetConVarInt(g_hCvarAutoFireBan);
	if (warn <= 0 && ban == 0)
		return;

	g_iCnt[client][C_AUTOFIRE]++;
	Evaluate(client, C_AUTOFIRE, warn, ban, "Advanced AutoFire", "1 cmd long +attack clicks");
}

CheckRcs(client)
{
	new hurt = GetConVarInt(g_hCvarRcsHurt);
	if (hurt != 0 && g_fRcsHurt[client] > float(AbsValue(hurt)))
		RcsSecond(client, C_RCS_H, RCS_H_SECONDS, hurt, "Recoil Control System -H", g_fRcsHurt[client]);

	new fire = GetConVarInt(g_hCvarRcsFire);
	if (fire != 0 && g_fRcsFire[client] > float(AbsValue(fire)))
		RcsSecond(client, C_RCS_F, RCS_F_SECONDS, fire, "Recoil Control System -F", g_fRcsFire[client]);
}

RcsSecond(client, counter, seconds, value, const String:name[], Float:sum)
{
	if (++g_iCnt[client][counter] <= seconds)
	{
		ScheduleDecay(client, counter);
		return;
	}

	g_iCnt[client][counter] = 0;

	new action = (value > 0) ? 3 : 2;
	if (GetConVarBool(g_hCvarRcsNotice))
		action = 1;

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "aim change %.1f deg/s (limit %i) in %i seconds", sum, AbsValue(value), seconds + 2);
	React(client, "Recoil Control System", name, action, -1, sDetail);
}

/**
 * Warning/Ban counters (R52): the counter starts at -1; admins are notified from Warning on,
 * more than |Ban| punishes (+ ban, - kick) and resets it to -1. Each step decays in 420 s.
 */
Evaluate(client, counter, warn, ban, const String:name[], const String:detail[])
{
	new value = g_iCnt[client][counter];

	if (ban != 0 && value > AbsValue(ban) && !IsImmune(client))
	{
		g_iCnt[client][counter] = -1;
		React(client, name, name, (ban > 0) ? 3 : 2, value, detail);
		return;
	}

	if (value <= -1)
		return;

	ScheduleDecay(client, counter);

	if (warn > 0 && value >= warn)
		React(client, name, name, 1, value, detail);
}

/* R52 SetBan -> OnBanReleased, postponed while the player is not on a team. */
ScheduleDecay(client, counter)
{
	new Handle:pack;
	CreateDataTimer(DECAY, Timer_Decay, pack, TIMER_FLAG_NO_MAPCHANGE);
	WritePackCell(pack, GetClientUserId(client));
	WritePackCell(pack, counter);
}

public Action:Timer_Decay(Handle:timer, Handle:pack)
{
	ResetPack(pack);
	new client = GetClientOfUserId(ReadPackCell(pack));
	new counter = ReadPackCell(pack);

	if (!IS_CLIENT(client) || !IsClientInGame(client) || g_iCnt[client][counter] <= -1)
		return Plugin_Stop;

	if (GetClientTeam(client) > 1)
		g_iCnt[client][counter]--;
	else
		ScheduleDecay(client, counter);

	return Plugin_Stop;
}

/**
 * Reaction: 1 = admin notice, 2 = kick, 3 = ban.
 */
React(client, const String:group[], const String:name[], action, count, const String:detail[])
{
	if (action > 1 && IsImmune(client))
		action = 1;

	new lowered = LowerAction(client, action);
	if (lowered != action)
	{
		SMAC_LogAction(client, "%s: action lowered %i -> %i (avg ping %.0f ms, %.1f pkt/s).",
			name, action, lowered,
			GetClientAvgLatency(client, NetFlow_Outgoing) * 1000.0,
			GetClientAvgPackets(client, NetFlow_Incoming));
		action = lowered;
	}

	new Handle:info = CreateKeyValues("");
	KvSetString(info, "group", group);
	KvSetString(info, "check", name);
	KvSetString(info, "detail", detail);
	KvSetNum(info, "counter", count);
	new Action:result = SMAC_CheatDetected(client, Detection_UltraInput, info);
	CloseHandle(info);

	if (result != Plugin_Continue)
		return;

	decl String:sWeapon[32];
	GetClientWeapon(client, sWeapon, sizeof(sWeapon));

	if (count >= 0)
		SMAC_LogAction(client, "%s: %s (counter %i) | Weapon:%s %s", group, name, count, sWeapon, detail);
	else
		SMAC_LogAction(client, "%s: %s | Weapon:%s %s", group, name, sWeapon, detail);
	SMAC_PrintAdminNotice("%t", "SMAC_UltraNotice", client, name, (count >= 0) ? count : 1);

	if (action == 3)
	{
		SMAC_LogAction(client, "was banned for %s.", name);
		SMAC_Ban(client, "%s Detection", name);
	}
	else if (action == 2)
	{
		SMAC_LogAction(client, "was kicked for %s.", name);
		KickClient(client, "%t", "SMAC_UltraKick");
	}
}

/**
 * Helpers
 */
bool:IsPlaying(client)
{
	return IS_CLIENT(client) && IsClientInGame(client) && !IsFakeClient(client)
		&& IsPlayerAlive(client) && !IsClientObserver(client);
}

bool:IsExcludedWeapon(client)
{
	decl String:sWeapon[32];
	GetClientWeapon(client, sWeapon, sizeof(sWeapon));

	new dummy;
	if (strncmp(sWeapon, "weapon_", 7) == 0)
		return GetTrieValue(g_hTrieExclude, sWeapon[7], dummy);
	return sWeapon[0] == '\0' || GetTrieValue(g_hTrieExclude, sWeapon, dummy);
}

Float:NormalizeAngle(Float:angle)
{
	if (angle > 180.0)
		angle -= 360.0;
	return angle;
}

bool:IsImmune(client)
{
	return GetConVarBool(g_hCvarAdminImmune) && (GetUserFlagBits(client) & (ADMFLAG_BAN | ADMFLAG_ROOT)) != 0;
}

/* R52 network gate: lower ban -> kick -> notice once for bad ping and once for few packets. */
LowerAction(client, action)
{
	if (action > 1 && GetClientAvgLatency(client, NetFlow_Outgoing) >= MAX_PING)
		action--;

	if (action > 1 && GetClientAvgPackets(client, NetFlow_Incoming) <= MIN_PACKET_FRAC / GetTickInterval())
		action--;

	return action;
}
