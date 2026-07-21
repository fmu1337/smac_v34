#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <smac>

/*
 * SMAC: Anti-Flash
 *
 * Base immersion hide while fully blind, plus optional angle-scaled
 * "totally blind" window rewritten from SauRay's PlayerFlashBanged
 * (https://github.com/toomuchvoltage/SauRay) — uses flashbang_detonate
 * origin on CSS instead of CSGO event entityid.
 */

public Plugin:myinfo =
{
	name = "SMAC: Anti-Flash",
	author = SMAC_AUTHOR,
	description = "Prevents anti-flashbang cheats from working",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define M_PI	3.1415926535

new Handle:g_hCvarAngleScale = INVALID_HANDLE;
new Handle:g_hCvarNoTeamFlash = INVALID_HANDLE;
new bool:g_bAngleScale = true;
new g_iNoTeamFlash = 0;

new Float:g_fFlashedUntil[MAXPLAYERS+1];
new bool:g_bFlashHooked = false;
new Float:g_vLastFlash[3];
new bool:g_bHaveFlashOrigin = false;
new Float:g_fFlashOriginTime = 0.0;
new g_iFlashOwner = -1;

public OnPluginStart()
{
	g_hCvarAngleScale = SMAC_CreateConVar("smac_antiflash_anglescale", "1", "Scale totally-blind hide window by flashbang angle (SauRay idea).", _, true, 0.0, true, 1.0);
	/* SMAC Ultra smac_No_Team_Flash idea. */
	g_hCvarNoTeamFlash = SMAC_CreateConVar("smac_no_team_flash", "0", "0=off, 1=both teams, 2=T only, 3=CT only — skip team-flash blindness.", _, true, 0.0, true, 3.0);
	OnAngleScaleChanged(g_hCvarAngleScale, "", "");
	OnNoTeamFlashChanged(g_hCvarNoTeamFlash, "", "");
	HookConVarChange(g_hCvarAngleScale, OnAngleScaleChanged);
	HookConVarChange(g_hCvarNoTeamFlash, OnNoTeamFlashChanged);

	HookEvent("player_blind", Event_PlayerBlind, EventHookMode_Post);
	HookEvent("flashbang_detonate", Event_FlashDetonate, EventHookMode_Post);
}

public OnAngleScaleChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_bAngleScale = GetConVarBool(convar);
}

public OnNoTeamFlashChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_iNoTeamFlash = GetConVarInt(convar);
}

public OnClientPutInServer(client)
{
	if (g_bFlashHooked)
		SDKHook(client, SDKHook_SetTransmit, Hook_SetTransmit);
}

public OnClientDisconnect(client)
{
	g_fFlashedUntil[client] = 0.0;
}

public Event_FlashDetonate(Handle:event, const String:name[], bool:dontBroadcast)
{
	g_vLastFlash[0] = GetEventFloat(event, "x");
	g_vLastFlash[1] = GetEventFloat(event, "y");
	g_vLastFlash[2] = GetEventFloat(event, "z");
	g_bHaveFlashOrigin = true;
	g_fFlashOriginTime = GetGameTime();
	g_iFlashOwner = GetClientOfUserId(GetEventInt(event, "userid"));
}

public Event_PlayerBlind(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));

	if (IS_CLIENT(client) && !IsFakeClient(client))
	{
		/* Ultra No-Team-Flash: clear teammate flashes (except thrower). */
		if (g_iNoTeamFlash > 0 && IS_CLIENT(g_iFlashOwner) && IsClientInGame(g_iFlashOwner)
			&& client != g_iFlashOwner && GetClientTeam(client) == GetClientTeam(g_iFlashOwner))
		{
			new team = GetClientTeam(client);
			new bool:protect = (g_iNoTeamFlash == 1)
				|| (g_iNoTeamFlash == 2 && team == 2)
				|| (g_iNoTeamFlash == 3 && team == 3);
			if (protect)
			{
				SetEntPropFloat(client, Prop_Send, "m_flFlashMaxAlpha", 0.5);
				SetEntPropFloat(client, Prop_Send, "m_flFlashDuration", 0.0);
				g_fFlashedUntil[client] = 0.0;
				return;
			}
		}

		new Float:alpha = GetEntPropFloat(client, Prop_Send, "m_flFlashMaxAlpha");

		if (alpha < 255.0)
		{
			g_fFlashedUntil[client] = 0.0;
			return;
		}

		new Float:duration = GetEntPropFloat(client, Prop_Send, "m_flFlashDuration");
		new Float:blindUntil;

		if (g_bAngleScale && g_bHaveFlashOrigin
			&& (GetGameTime() - g_fFlashOriginTime) < 1.5
			&& IsClientInGame(client) && IsPlayerAlive(client))
		{
			blindUntil = GetGameTime() + CalcAngleBlindDuration(client, duration);
		}
		else if (duration > 2.9)
		{
			blindUntil = GetGameTime() + duration - 2.9;
		}
		else
		{
			blindUntil = GetGameTime() + duration * 0.1;
		}

		g_fFlashedUntil[client] = blindUntil;

		SendMsgFadeUser(client, RoundToNearest(duration * 1000.0));

		if (!g_bFlashHooked)
			AntiFlash_HookAll();

		CreateTimer(duration, Timer_FlashEnded);
	}
}

Float:CalcAngleBlindDuration(client, Float:blindDuration)
{
	/* SauRay flash-angle tiers (counterstrike.fandom.com Flashbang guide). */
	decl Float:curEye[3], Float:tmpAngles[3], Float:curLook[3], Float:flashDir[3];
	GetClientEyePosition(client, curEye);
	GetClientEyeAngles(client, tmpAngles);
	GetAngleVectors(tmpAngles, curLook, NULL_VECTOR, NULL_VECTOR);
	SubtractVectors(g_vLastFlash, curEye, flashDir);
	NormalizeVector(flashDir, flashDir);

	new Float:flashAngle = ArcCosine(GetVectorDotProduct(flashDir, curLook));
	new Float:totallyBlind;

	if (flashAngle < (53.0 / 180.0) * M_PI)
		totallyBlind = (1.88 / 4.87) * blindDuration;
	else if (flashAngle < (72.0 / 180.0) * M_PI)
		totallyBlind = (0.45 / 3.4) * blindDuration;
	else if (flashAngle < (101.0 / 180.0) * M_PI)
		totallyBlind = (0.08 / 1.95) * blindDuration;
	else
		totallyBlind = (0.08 / 0.95) * blindDuration;

	totallyBlind -= 0.3;
	if (totallyBlind < 0.05)
		totallyBlind = 0.05;
	return totallyBlind;
}

public Action:Timer_FlashEnded(Handle:timer)
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (g_fFlashedUntil[i])
			return Plugin_Stop;
	}

	if (g_bFlashHooked)
		AntiFlash_UnhookAll();

	return Plugin_Stop;
}

public Action:Hook_SetTransmit(entity, client)
{
	if (g_fFlashedUntil[client])
	{
		if (g_fFlashedUntil[client] > GetGameTime())
			return (entity == client) ? Plugin_Continue : Plugin_Handled;

		SendMsgFadeUser(client, 0);
		g_fFlashedUntil[client] = 0.0;
	}

	return Plugin_Continue;
}

AntiFlash_HookAll()
{
	g_bFlashHooked = true;

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			SDKHook(i, SDKHook_SetTransmit, Hook_SetTransmit);
	}
}

AntiFlash_UnhookAll()
{
	g_bFlashHooked = false;

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			SDKUnhook(i, SDKHook_SetTransmit, Hook_SetTransmit);
	}
}

SendMsgFadeUser(client, duration)
{
	static UserMsg:msgFadeUser = INVALID_MESSAGE_ID;

	if (msgFadeUser == INVALID_MESSAGE_ID)
		msgFadeUser = GetUserMessageId("Fade");

	decl players[1];
	players[0] = client;

	new Handle:bf = StartMessageEx(msgFadeUser, players, 1);
	BfWriteShort(bf, (duration > 0) ? duration : 50);
	BfWriteShort(bf, (duration > 0) ? 1000 : 0);
	BfWriteShort(bf, FFADE_IN|FFADE_PURGE);
	BfWriteByte(bf, 255);
	BfWriteByte(bf, 255);
	BfWriteByte(bf, 255);
	BfWriteByte(bf, 255);

	EndMessage();
}
