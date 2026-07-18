#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: No-Recoil Detector
 *
 * Original module by Danyas for SMAC v34.
 * Inspired by SMAC Ultra smac_NoS_NoR / smac_NoR_Ban — flags sustained
 * firing with near-zero view punch (classic NoRecoil scripts).
 */

public Plugin:myinfo =
{
	name = "SMAC: No-Recoil Detector",
	author = SMAC_AUTHOR,
	description = "Detects NoRecoil via missing view punch while firing",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define PUNCH_EPS		0.08
#define STREAK_NEED		10

new Handle:g_hCvarBan = INVALID_HANDLE;
new Handle:g_hCvarEnabled = INVALID_HANDLE;

new bool:g_bPending[MAXPLAYERS+1];
new g_iZeroPunch[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];
new Handle:g_hIgnoreWeapons = INVALID_HANDLE;

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarEnabled = SMAC_CreateConVar("smac_norecoil", "1", "Enable NoRecoil punch checks.", _, true, 0.0, true, 1.0);
	g_hCvarBan = SMAC_CreateConVar("smac_norecoil_ban", "0", "Detections before ban. (0 = Never; notice/log only by default)", _, true, 0.0);

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
	g_iDetects[client] = 0;
}

public OnClientDisconnect(client)
{
	g_bPending[client] = false;
	g_iZeroPunch[client] = 0;
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
		return Plugin_Continue;
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
	{
		g_bPending[client] = false;
		return Plugin_Continue;
	}

	g_bPending[client] = false;

	decl Float:punch[3];
	GetEntPropVector(client, Prop_Send, "m_vecPunchAngle", punch);
	new Float:mag = SquareRoot((punch[0] * punch[0]) + (punch[1] * punch[1]) + (punch[2] * punch[2]));

	if (mag < PUNCH_EPS)
	{
		g_iZeroPunch[client]++;
		if (g_iZeroPunch[client] >= STREAK_NEED)
		{
			g_iZeroPunch[client] = 0;
			g_iDetects[client]++;

			new Handle:info = CreateKeyValues("");
			KvSetNum(info, "detection", g_iDetects[client]);
			KvSetFloat(info, "punch", mag);
			if (SMAC_CheatDetected(client, Detection_NoRecoil, info) == Plugin_Continue)
			{
				SMAC_PrintAdminNotice("%t", "SMAC_NoRecoilDetected", client, g_iDetects[client]);
				SMAC_LogAction(client, "norecoil (Detection #%i | punch=%.3f)", g_iDetects[client], mag);
				new banAt = GetConVarInt(g_hCvarBan);
				if (banAt && g_iDetects[client] >= banAt)
				{
					SMAC_LogAction(client, "was banned for norecoil.");
					SMAC_Ban(client, "NoRecoil Detection");
				}
			}
			CloseHandle(info);
		}
	}
	else
	{
		g_iZeroPunch[client] = 0;
	}

	return Plugin_Continue;
}
