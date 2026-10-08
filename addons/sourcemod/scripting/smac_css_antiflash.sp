
#include <sourcemod>
#include <sdkhooks>
#include <smac>
/* Plugin Info */
public Plugin:myinfo =
{
	name = "SMAC: Anti-Flash",
	author = SMAC_AUTHOR,
	description = "Prevents anti-flashbang cheats from working",
	version = SMAC_VERSION,
	url = SMAC_URL
};


new Float:g_fFlashedUntil[MAXPLAYERS+1];
new Float:g_fOverlayUntil[MAXPLAYERS+1];
new bool:g_bFlashHooked = false;

// 0 = off, 1 = white fade and no players while fully blind, 2 = also a random screen overlay (SMAC Ultr@ R52).
new g_iMode = 1;

// Overlays SMAC Ultr@ R52 uses on CS:S.
new const String:g_sOverlays[][] =
{
	"effects/security_noise2.vmt",
	"effects/filmscan256.vmt"
};

public OnPluginStart()
{
	new Handle:hCvar = CreateConVar("smac_AntiFlash", "1", "Prevents anti-flashbang cheats from working. (0:Disabled, 1:Standard Protection, 2:Advanced Protection)", _, true, 0.0, true, 2.0);
	g_iMode = GetConVarInt(hCvar);
	HookConVarChange(hCvar, OnModeChanged);
	
	// Hooks.
	HookEvent("player_blind", Event_PlayerBlind, EventHookMode_Post);
}


public OnClientPutInServer(client)
{
	if (g_bFlashHooked)
	{
		SDKHook(client, SDKHook_SetTransmit, Hook_SetTransmit);
	}
}

public OnModeChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_iMode = GetConVarInt(convar);
}

public OnClientDisconnect(client)
{
	g_fFlashedUntil[client] = 0.0;
	g_fOverlayUntil[client] = 0.0;
}

public Event_PlayerBlind(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if (g_iMode && IS_CLIENT(client) && !IsFakeClient(client))
	{
		new Float:alpha = GetEntPropFloat(client, Prop_Send, "m_flFlashMaxAlpha");
		
		if (alpha < 255.0)
		{
			// New flashes override previous ones.
			g_fFlashedUntil[client] = 0.0;
			return;
		}
		
		new Float:duration = GetEntPropFloat(client, Prop_Send, "m_flFlashDuration");
		
		if (duration > 2.9)
		{
			g_fFlashedUntil[client] = GetGameTime() + duration - 2.9;
		}
		else
		{
			g_fFlashedUntil[client] = GetGameTime() + duration * 0.1;
		}
		
		// Fade in the flash.
		SendMsgFadeUser(client, RoundToNearest(duration * 1000.0));
		
		if (g_iMode == 2)
		{
			// SMAC Ultr@ R52: a second flash that cheats removing the white fade don't touch.
			// It is cleared after 0.72 of the flash duration (R52: duration * 900 / 1250).
			new Float:fOverlay = duration * 0.72;
			
			ClientCommand(client, "r_screenoverlay \"%s\"", g_sOverlays[GetRandomInt(0, sizeof(g_sOverlays) - 1)]);
			g_fOverlayUntil[client] = GetGameTime() + fOverlay;
			CreateTimer(fOverlay, Timer_OverlayEnded, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		}
		
		if (!g_bFlashHooked)
		{
			AntiFlash_HookAll();
		}
			
		CreateTimer(duration, Timer_FlashEnded);
	}
}

public Action:Timer_OverlayEnded(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	
	// A newer flash keeps its own overlay.
	if (client && g_fOverlayUntil[client] && GetGameTime() >= g_fOverlayUntil[client] - 0.05)
	{
		g_fOverlayUntil[client] = 0.0;
		ClientCommand(client, "r_screenoverlay 0");
	}
	
	return Plugin_Stop;
}

public Action:Timer_FlashEnded(Handle:timer)
{
	/* Check if there are any other flashes being processed. Otherwise, we can unhook. */
	for (new i = 1; i <= MaxClients; i++)
	{
		if (g_fFlashedUntil[i])
		{
			return Plugin_Stop;
		}
	}
	
	if (g_bFlashHooked)
	{
		AntiFlash_UnhookAll();
	}
	
	return Plugin_Stop;
}

public Action:Hook_SetTransmit(entity, client)
{
	/* Don't send client data to players that are fully blind. */
	if (g_fFlashedUntil[client])
	{
		if (g_fFlashedUntil[client] > GetGameTime())
			return (entity == client) ? Plugin_Continue : Plugin_Handled;
		
		// Fade out the flash.
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
		{
			SDKHook(i, SDKHook_SetTransmit, Hook_SetTransmit);
		}
	}
}

AntiFlash_UnhookAll()
{
	g_bFlashHooked = false;

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			SDKUnhook(i, SDKHook_SetTransmit, Hook_SetTransmit);
		}
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
	BfWriteShort(bf, (duration > 0) ? duration : 50); // duration
	BfWriteShort(bf, (duration > 0) ? 1000 : 0); // hold time
	BfWriteShort(bf, FFADE_IN|FFADE_PURGE);
	BfWriteByte(bf, 255); // r
	BfWriteByte(bf, 255); // g
	BfWriteByte(bf, 255); // b
	BfWriteByte(bf, 255); // a
	
	EndMessage();
}
