#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>
#include <smac_ultra>

/*
 * SMAC Ultr@ R52 port: CheatCFG (shooting binds/scripts).
 *
 * Logic recovered from 001_SMAC_Global.smx R52 (docs/R52_DECODED.md §5):
 *   Stop movement, AIM CFG/Script - the previous cmd held only movement keys
 *       (one of FORWARD/BACK/MOVELEFT/MOVERIGHT or a forward/back + side pair),
 *       the current cmd holds exactly +attack: all movement released and fire
 *       pressed in the same tick. More than 7 attack presses in a row.
 *   Fast Weapon Switch CFG/Script - weapon switch requested within 2 cmds after
 *       the attack press ("+attack; lastinv" style binds). More than 7 in a row.
 *
 * smac_css_CheatCFG keeps the Ultr@ encoding: 0 = off, 1/4 = admin notice,
 * 2/5 = kick, 3/6 = ban (values above 3 were the "league rules" mode in R52 and
 * are treated like 1..3 here).
 */

public Plugin:myinfo =
{
	name = "SMAC Ultr@: CheatCFG",
	author = SMAC_AUTHOR,
	description = "Stop-shoot and fast weapon switch binds from SMAC Ultr@ R52",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define STOPSHOOT_STREAK	7
#define SWITCH_WINDOW		2
#define SWITCH_STREAK		7

new Handle:g_hCvarCfg = INVALID_HANDLE;

new g_iStopStreak[MAXPLAYERS+1];
new g_iStopDetects[MAXPLAYERS+1];

new g_iAttackCmd[MAXPLAYERS+1];
new bool:g_bSwitchPending[MAXPLAYERS+1];
new g_iSwitchStreak[MAXPLAYERS+1];
new g_iSwitchDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	Ultra_OnPluginStart();

	g_hCvarCfg = SMAC_CreateConVar("smac_css_CheatCFG", "1", "CheatCFG (stop-shoot / fast switch binds): 0=off, 1/4=admin notice, 2/5=kick, 3/6=ban", _, true, 0.0, true, 6.0);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
}

public OnGameFrame()
{
	SMAC_ServerLagSample();
}

public OnClientPutInServer(client)
{
	Ultra_ResetClient(client);

	g_iStopStreak[client] = 0;
	g_iStopDetects[client] = 0;
	g_iAttackCmd[client] = 0;
	g_bSwitchPending[client] = false;
	g_iSwitchStreak[client] = 0;
	g_iSwitchDetects[client] = 0;
}

GetLevel()
{
	new v = GetConVarInt(g_hCvarCfg);
	return (v > 3) ? v - 3 : v;
}

/* Exactly one movement key, or forward/back combined with one side key. */
bool:IsPureMoveCombo(buttons)
{
	switch (buttons)
	{
		case IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT,
			(IN_FORWARD | IN_MOVELEFT), (IN_FORWARD | IN_MOVERIGHT),
			(IN_BACK | IN_MOVELEFT), (IN_BACK | IN_MOVERIGHT):
		{
			return true;
		}
	}
	return false;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!Ultra_IsPlaying(client))
	{
		g_bUHasPrev[client] = false;
		g_bSwitchPending[client] = false;
		return Plugin_Continue;
	}

	new level = GetLevel();
	if (level > 0 && Ultra_IsSequential(client, cmdnum, tickcount) && !Ultra_IsIgnored(client) && !Ultra_IsLagging(client))
	{
		CheckFastSwitch(client, buttons, weapon, cmdnum, level);
		CheckStopShoot(client, buttons, level);
	}
	else
	{
		g_bSwitchPending[client] = false;
	}

	Ultra_StoreCmd(client, buttons, angles, cmdnum, tickcount);
	return Plugin_Continue;
}

CheckStopShoot(client, buttons, level)
{
	/* Only judge attack presses. */
	if (!(buttons & IN_ATTACK) || (g_iUPrevButtons[client] & IN_ATTACK))
		return;

	if (buttons != IN_ATTACK || !IsPureMoveCombo(g_iUPrevButtons[client]))
	{
		g_iStopStreak[client] = 0;
		return;
	}

	if (++g_iStopStreak[client] <= STOPSHOOT_STREAK)
		return;

	g_iStopStreak[client] = 0;

	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "prev_buttons", g_iUPrevButtons[client]);

	decl String:sDetail[96];
	FormatEx(sDetail, sizeof(sDetail), "%i attacks in a row fired on the tick movement was released", STOPSHOOT_STREAK + 1);
	Ultra_ReportLevel(client, Detection_UltraStopShoot, info, g_iStopDetects[client], level, "CheatCFG: Stop movement, AIM CFG/Script", sDetail);
	CloseHandle(info);
}

CheckFastSwitch(client, buttons, weaponselect, cmdnum, level)
{
	if (g_bSwitchPending[client])
	{
		if (weaponselect != 0)
		{
			g_bSwitchPending[client] = false;

			if (++g_iSwitchStreak[client] > SWITCH_STREAK)
			{
				g_iSwitchStreak[client] = 0;

				new Handle:info = CreateKeyValues("");
				KvSetNum(info, "cmds_after_attack", cmdnum - g_iAttackCmd[client]);

				decl String:sDetail[96];
				FormatEx(sDetail, sizeof(sDetail), "%i weapon switches within %i cmds of the shot", SWITCH_STREAK + 1, SWITCH_WINDOW);
				Ultra_ReportLevel(client, Detection_UltraFastSwitch, info, g_iSwitchDetects[client], level, "CheatCFG: Fast Weapon Switch CFG/Script", sDetail);
				CloseHandle(info);
			}
		}
		else if (cmdnum - g_iAttackCmd[client] > SWITCH_WINDOW)
		{
			g_bSwitchPending[client] = false;
			g_iSwitchStreak[client] = 0;
		}
	}

	/* New attack press opens the window. */
	if ((buttons & IN_ATTACK) && !(g_iUPrevButtons[client] & IN_ATTACK))
	{
		if (g_bSwitchPending[client])
			g_iSwitchStreak[client] = 0;

		g_bSwitchPending[client] = true;
		g_iAttackCmd[client] = cmdnum;
	}
}
