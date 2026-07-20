#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: CheatCFG (jumpthrow / fast weapon switch)
 *
 * Original module by Danyas for SMAC v34.
 * Ultr@ smac_css_CheatCFG: action encoding 0=off, 1/4=notice, 2/5=kick,
 * 3/6=ban; values >3 = stricter "league" thresholds. Rewrites for CSS v34
 * covering jumpthrow scripts and inhuman weapon-switch spam. Soft default 0.
 */

public Plugin:myinfo =
{
	name = "SMAC: CheatCFG",
	author = SMAC_AUTHOR,
	description = "Ultr@ CheatCFG jumpthrow / fast-switch detectors",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new Handle:g_hCvarCfg = INVALID_HANDLE;

new g_iPrevButtons[MAXPLAYERS+1];
new Float:g_fLastJump[MAXPLAYERS+1];
new g_iJumpThrowHits[MAXPLAYERS+1];
new g_iSwitchCount[MAXPLAYERS+1];
new Float:g_fSwitchWindow[MAXPLAYERS+1];
new g_iLastWeapon[MAXPLAYERS+1];
new g_iDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarCfg = SMAC_CreateConVar("smac_css_CheatCFG", "0", "CheatCFG. 0=off; 1/4=notice; 2/5=kick; 3/6=ban; >3=league strict", _, true, 0.0, true, 6.0);

	HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
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
	g_iPrevButtons[client] = 0;
	g_fLastJump[client] = 0.0;
	g_iJumpThrowHits[client] = 0;
	g_iSwitchCount[client] = 0;
	g_fSwitchWindow[client] = 0.0;
	g_iLastWeapon[client] = -1;
	g_iDetects[client] = 0;
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_iJumpThrowHits[client] = 0;
		g_iSwitchCount[client] = 0;
		g_fLastJump[client] = 0.0;
	}
}

bool:IsLeagueMode()
{
	return GetConVarInt(g_hCvarCfg) > 3;
}

ActionMode()
{
	new v = GetConVarInt(g_hCvarCfg);
	if (v == 1 || v == 4)
		return 0; /* notice only */
	if (v == 2 || v == 5)
		return -2; /* kick after 2 detections */
	if (v == 3 || v == 6)
		return 2; /* ban after 2 detections */
	return 0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (GetConVarInt(g_hCvarCfg) <= 0)
		return Plugin_Continue;
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	if ((buttons & IN_JUMP) && !(g_iPrevButtons[client] & IN_JUMP))
		g_fLastJump[client] = GetGameTime();

	/* Fast weapon switch: many active-weapon changes in a short window. */
	new wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (wep > MaxClients && wep != g_iLastWeapon[client] && g_iLastWeapon[client] > 0)
	{
		new Float:now = GetGameTime();
		new Float:win = IsLeagueMode() ? 0.35 : 0.50;
		new need = IsLeagueMode() ? 6 : 8;
		if (g_fSwitchWindow[client] <= 0.0 || (now - g_fSwitchWindow[client]) > win)
		{
			g_fSwitchWindow[client] = now;
			g_iSwitchCount[client] = 0;
		}
		g_iSwitchCount[client]++;
		if (g_iSwitchCount[client] >= need)
		{
			g_iSwitchCount[client] = 0;
			FireCfg(client, "fast-weapon-switch");
		}
	}
	if (wep > 0)
		g_iLastWeapon[client] = wep;

	g_iPrevButtons[client] = buttons;
	return Plugin_Continue;
}

public Event_WeaponFire(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (GetConVarInt(g_hCvarCfg) <= 0)
		return;

	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return;

	decl String:wpn[64];
	GetEventString(event, "weapon", wpn, sizeof(wpn));
	if (StrContains(wpn, "hegrenade", false) == -1
		&& StrContains(wpn, "flashbang", false) == -1
		&& StrContains(wpn, "smokegrenade", false) == -1)
		return;

	/* Jumpthrow script: nade fire within tiny window after jump edge. */
	new Float:dt = GetGameTime() - g_fLastJump[client];
	new Float:maxDt = IsLeagueMode() ? 0.06 : 0.10;
	if (g_fLastJump[client] <= 0.0 || dt < 0.0 || dt > maxDt)
		return;

	/* Prefer airborne / just left ground. */
	if ((GetEntityFlags(client) & FL_ONGROUND) && dt > 0.02)
		return;

	g_iJumpThrowHits[client]++;
	new need = IsLeagueMode() ? 2 : 3;
	if (g_iJumpThrowHits[client] >= need)
	{
		g_iJumpThrowHits[client] = 0;
		FireCfg(client, "jumpthrow");
	}
}

FireCfg(client, const String:kind[])
{
	g_iDetects[client]++;
	new mode = GetConVarInt(g_hCvarCfg);
	new reaction = ActionMode();

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", g_iDetects[client]);
	KvSetString(info, "kind", kind);
	KvSetNum(info, "cfg_mode", mode);
	if (SMAC_CheatDetected(client, Detection_CheatCFG, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", "SMAC_CheatCFGDetected", client, g_iDetects[client], kind);
		SMAC_LogAction(client, "cheatcfg (Detection #%i | %s | mode=%i)", g_iDetects[client], kind, mode);
		if (reaction != 0)
			SMAC_UltraReact(client, g_iDetects[client], reaction, "CheatCFG Detection", "SMAC_CheatCFGKick");
	}
	CloseHandle(info);
}
