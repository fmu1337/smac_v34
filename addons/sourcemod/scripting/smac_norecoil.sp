#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: No-Recoil Detector (Mode A / Mode B)
 *
 * Original module by Danyas for SMAC v34.
 * Ultr@ smac_NoS_NoR / smac_NoR_Ban:
 *   Mode A — sustained near-zero view punch while firing
 *   Mode B — eye pitch counter-tracks punch decay tick-perfect (RCS bot).
 *
 * Mode B rewritten 2026-07-21: the old check flagged players who did NOT
 * pull down while spraying — that is normal human play, it false-positived
 * on the server owner within minutes. A real norecoil/RCS cheat writes
 * viewangles that cancel m_vecPunchAngle every tick (typically angle -=
 * punch*2 in CS:S), so the usercmd pitch delta exactly mirrors the punch
 * delta for the whole kick+decay curve. Humans cannot track that curve.
 */

public Plugin:myinfo =
{
	name = "SMAC: No-Recoil Detector",
	author = SMAC_AUTHOR,
	description = "NoRecoil Mode A/B via punch and eye absorb",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define PUNCH_EPS		0.08
#define STREAK_NEED_A	10
/* Consecutive ticks of exact punch-mirroring before a Mode B detection.
   Punch decay in CS:S lasts ~0.3-0.5s => 16 ticks @66tick is ~0.24s. */
#define STREAK_NEED_B	16
#define COMP_EPS		0.05
#define PUNCH_ACTIVE	0.5
/* Mode B requires the view to actually MOVE against the punch this tick;
   a player holding still (pitchDelta ~ 0) is not compensating anything. */
#define MIN_PITCH_MOVE	0.15

new Handle:g_hCvarEnabled = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;

new bool:g_bPending[MAXPLAYERS+1];
new g_iZeroPunch[MAXPLAYERS+1];
new g_iNoAbsorb[MAXPLAYERS+1];
new g_iDetectsA[MAXPLAYERS+1];
new g_iDetectsB[MAXPLAYERS+1];
new Float:g_fPrevPitch[MAXPLAYERS+1];
new Float:g_fPrevPunchPitch[MAXPLAYERS+1];
new bool:g_bHavePrev[MAXPLAYERS+1];
new g_iLastClip[MAXPLAYERS+1];
new Handle:g_hIgnoreWeapons = INVALID_HANDLE;

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarEnabled = SMAC_CreateConVar("smac_NoS_NoR", "1", "Enable NoSpread/NoRecoil Mode A/B checks.", _, true, 0.0, true, 1.0);
	g_hCvarBan = SMAC_CreateConVar("smac_NoR_Ban", "0", "NoRecoil reaction. 0=notice, -N=kick, +N=ban", _, true, -100.0, true, 100.0);

	g_hIgnoreWeapons = CreateTrie();
	SetTrieValue(g_hIgnoreWeapons, "weapon_knife", 1);
	SetTrieValue(g_hIgnoreWeapons, "weapon_hegrenade", 1);
	SetTrieValue(g_hIgnoreWeapons, "weapon_flashbang", 1);
	SetTrieValue(g_hIgnoreWeapons, "weapon_smokegrenade", 1);
	SetTrieValue(g_hIgnoreWeapons, "weapon_c4", 1);

	HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
}

public OnGameFrame()
{
	SMAC_ServerLagSample();
}

public OnClientPutInServer(client)
{
	g_bPending[client] = false;
	g_iZeroPunch[client] = 0;
	g_iNoAbsorb[client] = 0;
	g_iDetectsA[client] = 0;
	g_iDetectsB[client] = 0;
	g_bHavePrev[client] = false;
	g_iLastClip[client] = -1;
}

public OnClientDisconnect(client)
{
	g_bPending[client] = false;
	g_bHavePrev[client] = false;
}

public Event_WeaponFire(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (!GetConVarBool(g_hCvarEnabled))
		return;

	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return;

	decl String:weapon[64], dummy;
	GetEventString(event, "weapon", weapon, sizeof(weapon));
	if (StrContains(weapon, "weapon_") != 0)
		Format(weapon, sizeof(weapon), "weapon_%s", weapon);

	if (GetTrieValue(g_hIgnoreWeapons, weapon, dummy))
		return;

	g_bPending[client] = true;
}

static Float:NormalizeAngleDelta(Float:delta)
{
	while (delta > 180.0)
		delta -= 360.0;
	while (delta < -180.0)
		delta += 360.0;
	return delta;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client)
		|| !GetConVarBool(g_hCvarEnabled))
	{
		g_bPending[client] = false;
		g_bHavePrev[client] = false;
		return Plugin_Continue;
	}

	decl Float:punch[3];
	GetEntPropVector(client, Prop_Send, "m_vecPunchAngle", punch);
	new Float:mag = SquareRoot((punch[0] * punch[0]) + (punch[1] * punch[1]) + (punch[2] * punch[2]));

	/* Choked/replayed usercmds carry frozen or concatenated angles — skip
	   sampling and drop streaks while the connection is degraded. */
	if (SMAC_IsClientLagging(client))
	{
		g_bPending[client] = false;
		g_iZeroPunch[client] = 0;
		g_iNoAbsorb[client] = 0;
		StorePrev(client, angles[0], punch[0]);
		return Plugin_Continue;
	}

	new reaction = GetConVarInt(g_hCvarBan);

	/* Confirm a real shot by ammo consumption. CS:S spams weapon_fire while
	   the button is held even when the semi-auto weapon does not actually
	   fire (deagle) — those phantom events carry no punch and previously
	   triggered Mode A. Only a clip decrease counts as a genuine shot. */
	new clip = GetActiveClip(client);
	new bool:realShot = (g_bPending[client] && clip >= 0 && g_iLastClip[client] >= 0 && clip < g_iLastClip[client]);
	g_iLastClip[client] = clip;

	/* Mode A: real shot fired but no punch at all (server-side punch removal). */
	if (g_bPending[client])
	{
		g_bPending[client] = false;

		if (!realShot)
		{
			/* Phantom weapon_fire or weapon switch — ignore, keep streak. */
		}
		else if (mag < PUNCH_EPS)
		{
			g_iZeroPunch[client]++;
			if (g_iZeroPunch[client] >= STREAK_NEED_A)
			{
				g_iZeroPunch[client] = 0;
				g_iDetectsA[client]++;
				new Handle:info = CreateKeyValues("");
				KvSetNum(info, "detection", g_iDetectsA[client]);
				KvSetFloat(info, "punch", mag);
				KvSetString(info, "mode", "A");
				if (SMAC_CheatDetected(client, Detection_NoRecoil, info) == Plugin_Continue)
				{
					SMAC_PrintAdminNotice("%t", "SMAC_NoRecoilDetected", client, g_iDetectsA[client]);
					SMAC_LogAction(client, "norecoil Mode:A (Detection #%i | punch=%.3f)", g_iDetectsA[client], mag);
					SMAC_UltraReact(client, g_iDetectsA[client], reaction, "NoRecoil Mode A", "SMAC_NoRecoilKick");
				}
				CloseHandle(info);
			}
		}
		else
		{
			g_iZeroPunch[client] = 0;
		}
	}

	/* Mode B: usercmd pitch mirrors punch pitch change tick-perfect while
	   the punch curve is active — the signature of angle-writing RCS bots
	   (viewangles -= punch or punch*2). Humans cannot track the decay. */
	if (g_bHavePrev[client] && mag > PUNCH_ACTIVE)
	{
		new Float:punchDelta = punch[0] - g_fPrevPunchPitch[client];
		new Float:pitchDelta = NormalizeAngleDelta(angles[0] - g_fPrevPitch[client]);

		/* Require a real recoil kick this tick AND a real counter-move by the
		   view. Holding the mouse still (pitchDelta ~ 0) is NOT compensation
		   and must never match — that was the AK-hold false positive. */
		if (FloatAbs(punchDelta) > MIN_PITCH_MOVE && FloatAbs(pitchDelta) > MIN_PITCH_MOVE)
		{
			if (FloatAbs(pitchDelta + punchDelta) < COMP_EPS
				|| FloatAbs(pitchDelta + (punchDelta * 2.0)) < COMP_EPS)
			{
				g_iNoAbsorb[client]++;
				if (g_iNoAbsorb[client] >= STREAK_NEED_B)
				{
					g_iNoAbsorb[client] = 0;
					g_iDetectsB[client]++;
					new Handle:info = CreateKeyValues("");
					KvSetNum(info, "detection", g_iDetectsB[client]);
					KvSetFloat(info, "punch", mag);
					KvSetString(info, "mode", "B");
					if (SMAC_CheatDetected(client, Detection_NoRecoilB, info) == Plugin_Continue)
					{
						SMAC_PrintAdminNotice("%t", "SMAC_NoRecoilBDetected", client, g_iDetectsB[client]);
						SMAC_LogAction(client, "norecoil Mode:B perfect-RCS (Detection #%i | punch=%.3f)", g_iDetectsB[client], mag);
						SMAC_UltraReact(client, g_iDetectsB[client], reaction, "NoRecoil Mode B", "SMAC_NoRecoilKick");
					}
					CloseHandle(info);
				}
			}
			else
			{
				g_iNoAbsorb[client] = 0;
			}
		}
	}
	else
	{
		g_iNoAbsorb[client] = 0;
	}

	StorePrev(client, angles[0], punch[0]);
	return Plugin_Continue;
}

StorePrev(client, Float:pitch, Float:punchPitch)
{
	g_fPrevPitch[client] = pitch;
	g_fPrevPunchPitch[client] = punchPitch;
	g_bHavePrev[client] = true;
}

GetActiveClip(client)
{
	new wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (wep <= MaxClients || !IsValidEdict(wep))
		return -1;
	if (!HasEntProp(wep, Prop_Send, "m_iClip1"))
		return -1;
	return GetEntProp(wep, Prop_Send, "m_iClip1");
}
