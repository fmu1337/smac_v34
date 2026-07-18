#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Fast Reload / Fast Shoot
 *
 * Original module by Danyas for SMAC v34.
 * Inspired by SMAC Ultra "Fast Reload or Shooting of Weapon" —
 * reload completing far below stock CSS times, and attack edges while
 * m_flNextPrimaryAttack is still in the future.
 */

public Plugin:myinfo =
{
	name = "SMAC: Fast Reload / Shoot",
	author = SMAC_AUTHOR,
	description = "Detects truncated reloads and early fire rate",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define SHOOT_STREAK	4
#define RELOAD_RATIO	0.55

new Handle:g_hCvarReload = INVALID_HANDLE;
new Handle:g_hCvarShoot = INVALID_HANDLE;
new Handle:g_hCvarReloadBan = INVALID_HANDLE;
new Handle:g_hCvarShootBan = INVALID_HANDLE;
new Handle:g_hReloadMin = INVALID_HANDLE;

new bool:g_bInReload[MAXPLAYERS+1];
new Float:g_fReloadStart[MAXPLAYERS+1];
new g_iClipAtReload[MAXPLAYERS+1];
new g_iReloadDet[MAXPLAYERS+1];

new g_iPrevButtons[MAXPLAYERS+1];
new g_iEarlyShoot[MAXPLAYERS+1];
new g_iShootDet[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarReload = SMAC_CreateConVar("smac_fastreload", "1", "Detect truncated weapon reloads.", _, true, 0.0, true, 1.0);
	g_hCvarShoot = SMAC_CreateConVar("smac_fastshoot", "1", "Detect firing before NextPrimaryAttack.", _, true, 0.0, true, 1.0);
	g_hCvarReloadBan = SMAC_CreateConVar("smac_fastreload_ban", "0", "Fast-reload detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarShootBan = SMAC_CreateConVar("smac_fastshoot_ban", "0", "Fast-shoot detections before ban. (0 = Never)", _, true, 0.0);

	/* Minimum stock reload seconds (CSS). Lookup by classname. */
	g_hReloadMin = CreateTrie();
	SetTrieValue(g_hReloadMin, "weapon_glock", 2.2);
	SetTrieValue(g_hReloadMin, "weapon_usp", 2.2);
	SetTrieValue(g_hReloadMin, "weapon_p228", 2.7);
	SetTrieValue(g_hReloadMin, "weapon_deagle", 2.2);
	SetTrieValue(g_hReloadMin, "weapon_fiveseven", 2.2);
	SetTrieValue(g_hReloadMin, "weapon_elite", 3.7);
	SetTrieValue(g_hReloadMin, "weapon_galil", 2.45);
	SetTrieValue(g_hReloadMin, "weapon_famas", 3.3);
	SetTrieValue(g_hReloadMin, "weapon_ak47", 2.43);
	SetTrieValue(g_hReloadMin, "weapon_m4a1", 3.05);
	SetTrieValue(g_hReloadMin, "weapon_sg552", 2.8);
	SetTrieValue(g_hReloadMin, "weapon_aug", 3.3);
	SetTrieValue(g_hReloadMin, "weapon_scout", 2.0);
	SetTrieValue(g_hReloadMin, "weapon_sg550", 3.35);
	SetTrieValue(g_hReloadMin, "weapon_awp", 3.67);
	SetTrieValue(g_hReloadMin, "weapon_g3sg1", 4.6);
	SetTrieValue(g_hReloadMin, "weapon_mac10", 3.2);
	SetTrieValue(g_hReloadMin, "weapon_tmp", 2.1);
	SetTrieValue(g_hReloadMin, "weapon_mp5navy", 2.63);
	SetTrieValue(g_hReloadMin, "weapon_ump45", 3.5);
	SetTrieValue(g_hReloadMin, "weapon_p90", 3.4);
	SetTrieValue(g_hReloadMin, "weapon_m249", 5.7);
	/* Shotguns shell-by-shell — skipped (not in trie). */
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
	g_bInReload[client] = false;
	g_fReloadStart[client] = 0.0;
	g_iClipAtReload[client] = 0;
	g_iReloadDet[client] = 0;
	g_iPrevButtons[client] = 0;
	g_iEarlyShoot[client] = 0;
	g_iShootDet[client] = 0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
	{
		if (IS_CLIENT(client))
			g_iPrevButtons[client] = buttons;
		return Plugin_Continue;
	}

	new ent = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (ent > MaxClients && IsValidEdict(ent))
	{
		if (GetConVarBool(g_hCvarReload))
			CheckReload(client, ent);
		if (GetConVarBool(g_hCvarShoot))
			CheckEarlyShoot(client, ent, buttons);
	}

	g_iPrevButtons[client] = buttons;
	return Plugin_Continue;
}

CheckReload(client, weapon)
{
	new bool:reloading = bool:GetEntProp(weapon, Prop_Send, "m_bInReload");
	new clip = GetEntProp(weapon, Prop_Send, "m_iClip1");

	if (reloading && !g_bInReload[client])
	{
		g_bInReload[client] = true;
		g_fReloadStart[client] = GetGameTime();
		g_iClipAtReload[client] = clip;
		return;
	}

	if (!reloading && g_bInReload[client])
	{
		g_bInReload[client] = false;

		if (clip <= g_iClipAtReload[client] || g_fReloadStart[client] <= 0.0)
			return;

		decl String:cls[32];
		if (!GetEdictClassname(weapon, cls, sizeof(cls)))
			return;

		new Float:stockMin;
		if (!GetTrieValue(g_hReloadMin, cls, stockMin))
			return;

		new Float:elapsed = GetGameTime() - g_fReloadStart[client];
		new Float:limit = stockMin * RELOAD_RATIO;
		if (elapsed >= limit || elapsed <= 0.05)
			return;

		g_iReloadDet[client]++;
		FireDetect(client, Detection_FastReload, g_iReloadDet[client], g_hCvarReloadBan,
			"SMAC_FastReloadDetected", "fast reload", cls, elapsed, stockMin);
	}
}

CheckEarlyShoot(client, weapon, buttons)
{
	if (!((buttons & IN_ATTACK) && !(g_iPrevButtons[client] & IN_ATTACK)))
	{
		if (!(buttons & IN_ATTACK))
			g_iEarlyShoot[client] = 0;
		return;
	}

	new Float:nextAtk = GetEntPropFloat(weapon, Prop_Send, "m_flNextPrimaryAttack");
	new Float:now = GetGameTime();

	/* Still locked out by more than a tick — early fire. */
	if (nextAtk > now + GetTickInterval())
	{
		g_iEarlyShoot[client]++;
		if (g_iEarlyShoot[client] >= SHOOT_STREAK)
		{
			g_iEarlyShoot[client] = 0;
			g_iShootDet[client]++;

			decl String:cls[32];
			GetEdictClassname(weapon, cls, sizeof(cls));
			FireDetect(client, Detection_FastShoot, g_iShootDet[client], g_hCvarShootBan,
				"SMAC_FastShootDetected", "fast shoot (NextPrimaryAttack)", cls,
				nextAtk - now, 0.0);
		}
	}
	else
	{
		g_iEarlyShoot[client] = 0;
	}
}

FireDetect(client, DetectionType:type, detects, Handle:hBan, const String:phrase[], const String:logTag[],
	const String:weapon[], Float:value, Float:stockMin)
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", detects);
	KvSetString(info, "weapon", weapon);
	KvSetFloat(info, "value", value);
	if (stockMin > 0.0)
		KvSetFloat(info, "stock", stockMin);

	if (SMAC_CheatDetected(client, type, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", phrase, client, detects);
		if (stockMin > 0.0)
			SMAC_LogAction(client, "%s (Detection #%i | %s elapsed=%.2f stock=%.2f)",
				logTag, detects, weapon, value, stockMin);
		else
			SMAC_LogAction(client, "%s (Detection #%i | %s ahead=%.3f)",
				logTag, detects, weapon, value);

		new banAt = GetConVarInt(hBan);
		if (banAt && detects >= banAt)
		{
			SMAC_LogAction(client, "was banned for %s.", logTag);
			SMAC_Ban(client, "Fast Reload/Shoot Detection");
		}
	}
	CloseHandle(info);
}
