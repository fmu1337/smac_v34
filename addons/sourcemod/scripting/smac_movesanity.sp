#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Move Sanity
 *
 * Original module by Danyas for SMAC v34.
 * Ideas rewritten from HOTGUARD (wishspeed quantization, max-move without
 * matching key, FastDuck/IN_BULLRUSH, perfect ground bhop), Cow Private
 * (autoshoot cmd-gap spam), and Ash (zero-holdtime A/D|W/S switches).
 */

public Plugin:myinfo =
{
	name = "SMAC: Move Sanity",
	author = SMAC_AUTHOR,
	description = "Wishspeed, perfect bhop, autoshoot, key-switch sanity checks",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#if !defined IN_BULLRUSH
#define IN_BULLRUSH		(1 << 22)
#endif

#define CSS_MAX_MOVE		400.0
#define WISH_STREAK			48
#define BHOP_STREAK			10
#define AUTOSHOOT_GAP		10
#define AUTOSHOOT_NEED		20
#define KEYSWITCH_NEED		200

new Handle:g_hCvarWishBan = INVALID_HANDLE;
new Handle:g_hCvarBhopBan = INVALID_HANDLE;
new Handle:g_hCvarAutoBan = INVALID_HANDLE;
new Handle:g_hCvarKeyBan = INVALID_HANDLE;
new Handle:g_hCvarBlockBullrush = INVALID_HANDLE;
new Handle:g_hCvarBhopEnabled = INVALID_HANDLE;

new g_iWishStreak[MAXPLAYERS+1];
new g_iWishDetects[MAXPLAYERS+1];

new g_iGroundTicks[MAXPLAYERS+1];
new g_iBhopStreak[MAXPLAYERS+1];
new g_iBhopDetects[MAXPLAYERS+1];
new g_iPrevButtons[MAXPLAYERS+1];

new g_iLastAttackCmd[MAXPLAYERS+1];
new g_iAutoShoot[MAXPLAYERS+1];
new g_iAutoDetects[MAXPLAYERS+1];
new g_iCmdNum[MAXPLAYERS+1];
new bool:g_bFirstShot[MAXPLAYERS+1];

new g_iHoldAD[MAXPLAYERS+1];
new g_iHoldWS[MAXPLAYERS+1];
new g_iPerfectAD[MAXPLAYERS+1];
new g_iPerfectWS[MAXPLAYERS+1];
new g_iKeyDetects[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarWishBan = SMAC_CreateConVar("smac_move_wish_ban", "3", "Illegal wishspeed detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarBhopBan = SMAC_CreateConVar("smac_move_bhop_ban", "0", "Perfect-bhop detections before ban. (0 = Never; off by default for surf)", _, true, 0.0);
	g_hCvarBhopEnabled = SMAC_CreateConVar("smac_move_bhop", "1", "Enable perfect ground-tick bhop detection.", _, true, 0.0, true, 1.0);
	g_hCvarAutoBan = SMAC_CreateConVar("smac_move_autoshoot_ban", "2", "Autoshoot detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarKeyBan = SMAC_CreateConVar("smac_move_keyswitch_ban", "0", "Zero-hold keyswitch detections before ban. (0 = Never; keyboard FP)", _, true, 0.0);
	g_hCvarBlockBullrush = SMAC_CreateConVar("smac_move_block_bullrush", "1", "Strip IN_BULLRUSH (FastDuck) and log.", _, true, 0.0, true, 1.0);
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
	g_iWishStreak[client] = 0;
	g_iWishDetects[client] = 0;
	g_iGroundTicks[client] = 0;
	g_iBhopStreak[client] = 0;
	g_iBhopDetects[client] = 0;
	g_iPrevButtons[client] = 0;
	g_iLastAttackCmd[client] = 0;
	g_iAutoShoot[client] = 0;
	g_iAutoDetects[client] = 0;
	g_iCmdNum[client] = 0;
	g_bFirstShot[client] = true;
	g_iHoldAD[client] = 0;
	g_iHoldWS[client] = 0;
	g_iPerfectAD[client] = 0;
	g_iPerfectWS[client] = 0;
	g_iKeyDetects[client] = 0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	g_iCmdNum[client]++;
	new bool:changed = false;

	/* HOTGUARD FastDuck */
	if ((buttons & IN_BULLRUSH) && GetConVarBool(g_hCvarBlockBullrush))
	{
		buttons &= ~IN_BULLRUSH;
		changed = true;
		SMAC_LogAction(client, "IN_BULLRUSH (FastDuck) stripped");
	}

	CheckWishVelocity(client, vel, buttons);
	if (GetConVarBool(g_hCvarBhopEnabled))
		CheckPerfectBhop(client, buttons);
	CheckAutoShoot(client, buttons);
	CheckKeySwitch(client, buttons);

	g_iPrevButtons[client] = buttons;
	return changed ? Plugin_Changed : Plugin_Continue;
}

bool:IsLegalWish(Float:num)
{
	num = FloatAbs(num);
	if (num == 0.0 || num == CSS_MAX_MOVE)
		return true;
	if (num == CSS_MAX_MOVE * 0.75 || num == CSS_MAX_MOVE * 0.50 || num == CSS_MAX_MOVE * 0.25)
		return true;
	/* common CSS partial: 112.5 */
	if (FloatAbs(num - 112.5) < 0.1)
		return true;
	return false;
}

CheckWishVelocity(client, const Float:vel[3], buttons)
{
	/* Max wish without matching key — definitive. */
	if ((vel[0] == CSS_MAX_MOVE && !(buttons & IN_FORWARD))
		|| (vel[0] == -CSS_MAX_MOVE && !(buttons & IN_BACK))
		|| (vel[1] == CSS_MAX_MOVE && !(buttons & IN_MOVERIGHT))
		|| (vel[1] == -CSS_MAX_MOVE && !(buttons & IN_MOVELEFT)))
	{
		g_iWishStreak[client] += 4;
	}
	else if (!IsLegalWish(vel[0]) && !IsLegalWish(vel[1]))
	{
		g_iWishStreak[client]++;
	}
	else
	{
		g_iWishStreak[client] = 0;
	}

	if (g_iWishStreak[client] >= WISH_STREAK)
	{
		g_iWishStreak[client] = 0;
		g_iWishDetects[client]++;
		FireDetect(client, Detection_WishVelocity, g_iWishDetects[client], g_hCvarWishBan,
			"SMAC_WishVelocityDetected", "illegal wish velocity");
	}
}

CheckPerfectBhop(client, buttons)
{
	if (GetEntityMoveType(client) == MOVETYPE_LADDER)
	{
		g_iGroundTicks[client] = 0;
		g_iBhopStreak[client] = 0;
		return;
	}

	if (GetEntityFlags(client) & FL_ONGROUND)
		g_iGroundTicks[client]++;
	else
		g_iGroundTicks[client] = 0;

	if ((buttons & IN_JUMP) && !(g_iPrevButtons[client] & IN_JUMP)
		&& (GetEntityFlags(client) & FL_ONGROUND)
		&& g_iGroundTicks[client] == 1)
	{
		g_iBhopStreak[client]++;
		if (g_iBhopStreak[client] >= BHOP_STREAK)
		{
			new streak = g_iBhopStreak[client];
			g_iBhopStreak[client] = 0;
			g_iBhopDetects[client]++;

			new Handle:info = CreateKeyValues("");
			KvSetNum(info, "detection", g_iBhopDetects[client]);
			KvSetNum(info, "streak", streak);
			if (SMAC_CheatDetected(client, Detection_PerfectBhop, info) == Plugin_Continue)
			{
				SMAC_PrintAdminNotice("%t", "SMAC_PerfectBhopDetected", client, g_iBhopDetects[client]);
				SMAC_LogAction(client, "perfect bhop (Detection #%i | streak=%i)", g_iBhopDetects[client], streak);
				new banAt = GetConVarInt(g_hCvarBhopBan);
				if (banAt && g_iBhopDetects[client] >= banAt)
				{
					SMAC_LogAction(client, "was banned for perfect bhop.");
					SMAC_Ban(client, "Perfect Bhop Detection");
				}
			}
			CloseHandle(info);
		}
	}
	else if ((GetEntityFlags(client) & FL_ONGROUND) && g_iGroundTicks[client] > 2)
	{
		g_iBhopStreak[client] = 0;
	}
}

CheckAutoShoot(client, buttons)
{
	if ((buttons & IN_ATTACK) && !(g_iPrevButtons[client] & IN_ATTACK))
	{
		if (g_bFirstShot[client])
		{
			g_bFirstShot[client] = false;
			g_iLastAttackCmd[client] = g_iCmdNum[client];
		}
		else if ((g_iCmdNum[client] - g_iLastAttackCmd[client]) <= AUTOSHOOT_GAP)
		{
			g_iAutoShoot[client]++;
			g_iLastAttackCmd[client] = g_iCmdNum[client];
			if (g_iAutoShoot[client] >= AUTOSHOOT_NEED)
			{
				new shots = g_iAutoShoot[client];
				g_iAutoShoot[client] = 0;
				g_iAutoDetects[client]++;

				new Handle:info = CreateKeyValues("");
				KvSetNum(info, "detection", g_iAutoDetects[client]);
				KvSetNum(info, "shots", shots);
				if (SMAC_CheatDetected(client, Detection_AutoShoot, info) == Plugin_Continue)
				{
					SMAC_PrintAdminNotice("%t", "SMAC_AutoShootDetected", client, g_iAutoDetects[client]);
					SMAC_LogAction(client, "autoshoot (Detection #%i | burst=%i)", g_iAutoDetects[client], shots);
					new banAt = GetConVarInt(g_hCvarAutoBan);
					if (banAt && g_iAutoDetects[client] >= banAt)
					{
						SMAC_LogAction(client, "was banned for autoshoot.");
						SMAC_Ban(client, "Autoshoot Detection");
					}
				}
				CloseHandle(info);
			}
		}
		else
		{
			g_iAutoShoot[client] = 0;
			g_iLastAttackCmd[client] = g_iCmdNum[client];
		}
	}
}

CheckKeySwitch(client, buttons)
{
	new bool:left = ((buttons & IN_MOVELEFT) != 0);
	new bool:right = ((buttons & IN_MOVERIGHT) != 0);
	new bool:fwd = ((buttons & IN_FORWARD) != 0);
	new bool:back = ((buttons & IN_BACK) != 0);

	new bool:prevL = ((g_iPrevButtons[client] & IN_MOVELEFT) != 0);
	new bool:prevR = ((g_iPrevButtons[client] & IN_MOVERIGHT) != 0);
	new bool:prevF = ((g_iPrevButtons[client] & IN_FORWARD) != 0);
	new bool:prevB = ((g_iPrevButtons[client] & IN_BACK) != 0);

	if (left && right)
		g_iHoldAD[client]++;
	else if (left != right)
	{
		/* exclusive A or D */
		if ((left && prevR && !prevL) || (right && prevL && !prevR))
		{
			if (g_iHoldAD[client] == 0)
				g_iPerfectAD[client]++;
			else
				g_iPerfectAD[client] = 0;
		}
		g_iHoldAD[client] = 0;
	}
	else
	{
		g_iHoldAD[client] = 0;
	}

	if (fwd && back)
		g_iHoldWS[client]++;
	else if (fwd != back)
	{
		if ((fwd && prevB && !prevF) || (back && prevF && !prevB))
		{
			if (g_iHoldWS[client] == 0)
				g_iPerfectWS[client]++;
			else
				g_iPerfectWS[client] = 0;
		}
		g_iHoldWS[client] = 0;
	}
	else
	{
		g_iHoldWS[client] = 0;
	}

	new best = g_iPerfectAD[client];
	if (g_iPerfectWS[client] > best)
		best = g_iPerfectWS[client];

	if (best >= KEYSWITCH_NEED)
	{
		g_iPerfectAD[client] = 0;
		g_iPerfectWS[client] = 0;
		g_iKeyDetects[client]++;
		FireDetect(client, Detection_KeySwitchHack, g_iKeyDetects[client], g_hCvarKeyBan,
			"SMAC_KeySwitchDetected", "zero-hold key switch streak");
	}
}

FireDetect(client, DetectionType:type, detection, Handle:hBanCvar, const String:phrase[], const String:logName[])
{
	new Handle:info = CreateKeyValues("");
	KvSetNum(info, "detection", detection);
	if (SMAC_CheatDetected(client, type, info) == Plugin_Continue)
	{
		SMAC_PrintAdminNotice("%t", phrase, client, detection);
		SMAC_LogAction(client, "%s (Detection #%i)", logName, detection);
		new banAt = GetConVarInt(hBanCvar);
		if (banAt && detection >= banAt)
		{
			SMAC_LogAction(client, "was banned for %s.", logName);
			SMAC_Ban(client, "%s Detection", logName);
		}
	}
	CloseHandle(info);
}
