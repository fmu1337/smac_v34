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
 *   Mode B — punch present but eye pitch never absorbs recoil (no RCS)
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
#define STREAK_NEED_B	12

new Handle:g_hCvarEnabled = INVALID_HANDLE;
new Handle:g_hCvarBan = INVALID_HANDLE;

new bool:g_bPending[MAXPLAYERS+1];
new g_iZeroPunch[MAXPLAYERS+1];
new g_iNoAbsorb[MAXPLAYERS+1];
new g_iDetectsA[MAXPLAYERS+1];
new g_iDetectsB[MAXPLAYERS+1];
new Float:g_fPrevPitch[MAXPLAYERS+1];
new bool:g_bHavePitch[MAXPLAYERS+1];
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

public OnClientPutInServer(client)
{
	g_bPending[client] = false;
	g_iZeroPunch[client] = 0;
	g_iNoAbsorb[client] = 0;
	g_iDetectsA[client] = 0;
	g_iDetectsB[client] = 0;
	g_bHavePitch[client] = false;
}

public OnClientDisconnect(client)
{
	g_bPending[client] = false;
	g_bHavePitch[client] = false;
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

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!g_bPending[client])
	{
		g_fPrevPitch[client] = angles[0];
		g_bHavePitch[client] = true;
		return Plugin_Continue;
	}
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
	{
		g_bPending[client] = false;
		return Plugin_Continue;
	}

	g_bPending[client] = false;

	/* Choked/replayed usercmds carry frozen angles — a legit player looks
	   like he never absorbs recoil. Skip the sample and drop streaks. */
	if (SMAC_IsClientLagging(client))
	{
		g_iZeroPunch[client] = 0;
		g_iNoAbsorb[client] = 0;
		g_fPrevPitch[client] = angles[0];
		return Plugin_Continue;
	}

	new reaction = GetConVarInt(g_hCvarBan);

	decl Float:punch[3];
	GetEntPropVector(client, Prop_Send, "m_vecPunchAngle", punch);
	new Float:mag = SquareRoot((punch[0] * punch[0]) + (punch[1] * punch[1]) + (punch[2] * punch[2]));

	/* Mode A: missing punch entirely. */
	if (mag < PUNCH_EPS)
	{
		g_iZeroPunch[client]++;
		g_iNoAbsorb[client] = 0;
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

		/* Mode B: punch exists but pitch never moves into recoil (no absorb). */
		if (g_bHavePitch[client] && punch[0] < -0.5)
		{
			new Float:pitchDelta = angles[0] - g_fPrevPitch[client];
			/* Expected: eye pitch increases (look down) or stays when compensating.
			   Flag when pitch moves opposite to punch for sustained shots. */
			if (pitchDelta > -0.05)
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
						SMAC_LogAction(client, "norecoil Mode:B (Detection #%i | punch=%.3f)", g_iDetectsB[client], mag);
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

	g_fPrevPitch[client] = angles[0];
	g_bHavePitch[client] = true;
	return Plugin_Continue;
}
