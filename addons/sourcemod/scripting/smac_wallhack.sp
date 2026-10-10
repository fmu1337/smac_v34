#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smac>
#include <smac_wallhack_occ>


/**
 * CS:S FarESP Blocking
 */
#define CS_TEAM_NONE		0	/**< No team yet. */
#define CS_TEAM_SPECTATOR	1	/**< Spectators. */
#define CS_TEAM_T			2	/**< Terrorists. */
#define CS_TEAM_CT			3	/**< Counter-Terrorists. */

#define MAX_RADAR_CLIENTS	36	// Max amount of client data we can include in one message.

public Plugin:myinfo =
{
	name = "SMAC: Anti-Wallhack",
	author = SMAC_AUTHOR,
	description = "Prevents wallhack cheats from working",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new bool:g_bFarEspEnabled;
new g_iMaxTraces; //ty for crashfix to alex smirnov (aka Ultr@)

// SMAC Ultr@ R52: 0 = off, 1 = enemies only (radar on), 2 = FFA (everyone, radar off).
new g_iMode = 1;
// SMAC Ultr@ R52: rectangle width divisor = 7.0 + smac_wallhack_Level (master SMAC used 4.0).
new Float:g_fWideDivisor = 7.0;
new Handle:g_hCvarTime = INVALID_HANDLE;
// SMAC Ultr@ R52 Anti-SoundESP: -1 = no sound handling, 0 = real sounds, 1-4 = faked for listeners who can't see the source.
new g_iSoundESP = 0;
new Handle:g_hCvarTickTime = INVALID_HANDLE;
// Peek lookahead (CornerCulling, github.com/87andrewh/CornerCulling): max seconds of viewer movement to account for.
new Float:g_fPeekTime = 0.1;
new Handle:g_hCvarAccelerate = INVALID_HANDLE;
new Handle:g_hCvarFriction = INVALID_HANDLE;
new Handle:g_hCvarMaxSpeed = INVALID_HANDLE;

new g_iDownloadTable = INVALID_STRING_TABLE;
new Handle:g_hIgnoreSounds = INVALID_HANDLE;

new g_iPVSCache[MAXPLAYERS][MAXPLAYERS];
new g_iPVSSoundCache[MAXPLAYERS][MAXPLAYERS];
new bool:g_bIsVisible[MAXPLAYERS][MAXPLAYERS];
new bool:g_bIsObserver[MAXPLAYERS];
new bool:g_bIsFake[MAXPLAYERS];
new bool:g_bProcess[MAXPLAYERS];
new bool:g_bIgnore[MAXPLAYERS];

new g_iWeaponOwner[2048];
new g_iTeam[MAXPLAYERS];
new Float:g_vMins[MAXPLAYERS][3];
new Float:g_vMaxs[MAXPLAYERS][3];
new Float:g_vAbsCentre[MAXPLAYERS][3];
new Float:g_vEyePos[MAXPLAYERS][3];
new Float:g_vEyeAngles[MAXPLAYERS][3];
new Float:g_fPeekDist[MAXPLAYERS];

// Trace targets on a player: centre, outer rectangle, head, inner rectangle (in that order).
#define SAMPLE_COUNT		10
// Peek eyes only trace the centre, the outer rectangle and the head.
#define SAMPLE_PEEK_COUNT	6
// Real eye + two side-stepped peek eyes.
#define EYE_COUNT			3

// Last eye/sample pair that saw the entity (eye * SAMPLE_COUNT + sample + 1), 0 = none. Tried first next time.
new g_iLastSample[MAXPLAYERS][MAXPLAYERS];

// Map brush that proved the entity hidden last time (brush + 1), 0 = none. See smac_wallhack_occ.inc.
new g_iOccCache[MAXPLAYERS][MAXPLAYERS];
new bool:g_bOccEnabled = true;
new g_iBeamSprite = -1;

// smac_wallhack_occ statistics, reset by the command.
// A brush proof counts as one trace towards smac_wallhack_maxtraces; the stats keep them apart.
new g_iStatChecks, g_iStatTraces, g_iStatProofs, g_iStatOccCached, g_iStatOccFound;
new Float:g_fStatTime;

new g_iTotalThreads = 1, g_iCurrentThread = 1, g_iThread[MAXPLAYERS] = { 1, ... };
new g_iCacheTicks, g_iTraceCount;
new g_iTickCount, g_iCmdTickCount[MAXPLAYERS], g_iTickRate;

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	RegPluginLibrary("smac_wallhack");
	return APLRes_Success;
}

public OnPluginStart()
{
	new Handle: hCvar = CreateConVar("smac_wallhack", "1", "Anti-Wallhack mode. (0:Disable, 1:Normal Mode, 2:FFA Mode, Radar OFF)", _, true, 0.0, true, 2.0);
	g_iMode = GetConVarInt(hCvar);
	HookConVarChange(hCvar, OnModeChanged);
	
	hCvar = CreateConVar("smac_wallhack_Level", "0.0", "Degree of rigidity of the Anti-Wallhack. (Easy < 0.0 > Hard; -3.0 = stock SMAC width)", _, true, -3.0, true, 3.0);
	OnLevelChanged(hCvar, "", "");
	HookConVarChange(hCvar, OnLevelChanged);
	
	hCvar = CreateConVar("smac_SoundESP", "0", "Anti-SoundESP for listeners who can't see the source. (-1:Disable sound handling, 0:Real sounds, 1:Fake position, 2:Fake position + level/pitch, 3:Volume by distance + level/pitch, 4:All)", _, true, -1.0, true, 4.0);
	g_iSoundESP = GetConVarInt(hCvar);
	HookConVarChange(hCvar, OnSoundESPChanged);
	
	hCvar = CreateConVar("smac_wallhack_maxtraces", "1280", "Max amount of traces that can be executed in one tick.", _, true, 1.0);
	OnMaxTracesChanged(hCvar, "", "");
	HookConVarChange(hCvar, OnMaxTracesChanged);
	
	g_hCvarTime = CreateConVar("smac_wallhack_Time", "0.2", "How long a player stays visible after he was last seen, in seconds.", _, true, 0.1, true, 0.4);
	HookConVarChange(g_hCvarTime, WallHack_TickOnSettingsChanged);
	
	g_hCvarTickTime = CreateConVar("smac_wallhack_ticktime", "0", "Legacy (stock SMAC, was 0.75): when above 0, used instead of smac_wallhack_Time.", _, true, 0.0, true, 2.0);
	HookConVarChange(g_hCvarTickTime, WallHack_TickOnSettingsChanged);
	WallHack_TickOnSettingsChanged(INVALID_HANDLE, "", "");
	
	hCvar = CreateConVar("smac_wallhack_peek", "0.1", "Peek lookahead: also check from where a client could have side-stepped within its ping, up to this many seconds. Prevents enemies popping in late on peeks. (0:Disable)", _, true, 0.0, true, 0.3);
	g_fPeekTime = GetConVarFloat(hCvar);
	HookConVarChange(hCvar, OnPeekChanged);
	
	hCvar = CreateConVar("smac_wallhack_occluders", "1", "Use the map's own brushes (read from the .bsp) to prove players hidden without engine traces. Same result, fewer traces. (0:Disable)", _, true, 0.0, true, 1.0);
	g_bOccEnabled = GetConVarBool(hCvar);
	HookConVarChange(hCvar, OnOccChanged);
	
	RegAdminCmd("smac_wallhack_occ", Command_Occ, ADMFLAG_GENERIC, "Anti-Wallhack occluder status and stats. \"reset\" clears the stats, \"show\" draws the brushes hiding enemies from you.");
	
	g_hCvarAccelerate = FindConVar("sv_accelerate");
	g_hCvarFriction = FindConVar("sv_friction");
	g_hCvarMaxSpeed = FindConVar("sv_maxspeed");
	
	g_iTickRate = RoundToFloor(1.0 / GetTickInterval());
	
	if ((hCvar = FindConVar("sv_minupdaterate")) != INVALID_HANDLE && IsConVarDefault(hCvar))
		SetConVarInt(hCvar, g_iTickRate);
	if ((hCvar = FindConVar("sv_maxupdaterate")) != INVALID_HANDLE && IsConVarDefault(hCvar))
		SetConVarInt(hCvar, g_iTickRate);
	if ((hCvar = FindConVar("sv_client_min_interp_ratio")) != INVALID_HANDLE && IsConVarDefault(hCvar))
		SetConVarInt(hCvar, 0);
	if ((hCvar = FindConVar("sv_client_max_interp_ratio")) != INVALID_HANDLE && IsConVarDefault(hCvar))
		SetConVarInt(hCvar, 1);
	
	// Initialize.
	g_iDownloadTable = FindStringTable("downloadables");
	
	// FEATURECAP_PLAYERRUNCMD_11PARAMS shipped in SourceMod 1.5.0 (not 1.7).
	RequireFeature(FeatureType_Capability, FEATURECAP_PLAYERRUNCMD_11PARAMS, "This module requires SourceMod 1.5.0 or newer (FEATURECAP_PLAYERRUNCMD_11PARAMS).");
	
	for (new i = 0; i < sizeof(g_bIsVisible); i++)
	{
		for (new j = 0; j < sizeof(g_bIsVisible[]); j++)
		{
			g_bIsVisible[i][j] = true;
		}
	}
	
	AddNormalSoundHook(Hook_NormalSound);
	
	HookEvent("player_spawn", Event_PlayerStateChanged, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerStateChanged, EventHookMode_Post);
	HookEvent("player_team", Event_PlayerStateChanged, EventHookMode_Post);
	
	if (g_iMode)
	{
		FarESP_Enable();
	}
	
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			Wallhack_Hook(i);
			Wallhack_UpdateClientCache(i);
		}
	}
	
	for (new i = MaxClients + 1; i < 2048; i++)
	{
		if (IsValidEdict(i))
		{
			new owner = GetEntPropEnt(i, Prop_Data, "m_hOwnerEntity");
			
			if (IS_CLIENT(owner))
			{
				g_iWeaponOwner[i] = owner;
				SDKHook(i, SDKHook_SetTransmit, Hook_SetTransmitWeapon);
			}
		}
	}
	
	// Default sounds to ignore in sound hook.
	g_hIgnoreSounds = CreateTrie();
	SetTrieValue(g_hIgnoreSounds, "buttons/button14.wav", 1);
	SetTrieValue(g_hIgnoreSounds, "buttons/combine_button7.wav", 1);
	SetTrieValue(g_hIgnoreSounds, "radio/terwin.wav", 1);
	SetTrieValue(g_hIgnoreSounds, "radio/ctwin.wav", 1);
}

public WallHack_TickOnSettingsChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	new Float:fTime = GetConVarFloat(g_hCvarTickTime);
	
	if (fTime <= 0.0)
	{
		fTime = GetConVarFloat(g_hCvarTime);
	}
	
	g_iCacheTicks = TIME_TO_TICK(fTime);
}

public OnSoundESPChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_iSoundESP = GetConVarInt(convar);
}

public OnOccChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_bOccEnabled = GetConVarBool(convar);
}

public OnPeekChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_fPeekTime = GetConVarFloat(convar);
}

public OnLevelChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_fWideDivisor = 7.0 + GetConVarFloat(convar);
}

public OnModeChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_iMode = GetConVarInt(convar);
	
	if (g_iMode)
	{
		if (!g_bFarEspEnabled)
		{
			FarESP_Enable();
		}
	}
	else
	{
		if (g_bFarEspEnabled)
		{
			FarESP_Disable();
		}
		
		// Everyone is transmitted again.
		for (new i = 0; i < sizeof(g_bIsVisible); i++)
		{
			for (new j = 0; j < sizeof(g_bIsVisible[]); j++)
			{
				g_bIsVisible[i][j] = true;
			}
		}
	}
}

public OnConfigsExecuted()
{
	// Ignore all sounds in the download table.
	if (g_iDownloadTable == INVALID_STRING_TABLE)
		return;
	
	decl String:sBuffer[PLATFORM_MAX_PATH];
	new iMaxStrings = GetStringTableNumStrings(g_iDownloadTable);
	
	for (new i = 0; i < iMaxStrings; i++)
	{
		ReadStringTable(g_iDownloadTable, i, sBuffer, sizeof(sBuffer));
		
		if (strncmp(sBuffer, "sound", 5) == 0)
		{
			SetTrieValue(g_hIgnoreSounds, sBuffer[6], 1);
		}
	}
}

public OnClientPutInServer(client)
{
	Wallhack_Hook(client);
	Wallhack_UpdateClientCache(client);
}

public OnClientDisconnect(client)
{
	// Stop checking clients right before they disconnect.
	g_bIsObserver[client] = false;
	g_bProcess[client] = false;
	g_bIgnore[client] = false;
}

public OnClientDisconnect_Post(client)
{
	// Clear cache on post to ensure it's not updated again.
	for (new i = 0; i < sizeof(g_iPVSCache); i++)
	{
		g_iPVSCache[i][client] = 0;
		g_iPVSSoundCache[i][client] = 0;
		g_bIsVisible[i][client] = true;
		g_iLastSample[i][client] = 0;
		g_iOccCache[i][client] = 0;
	}
}

public Event_PlayerStateChanged(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Not all data has been updated at this time. Wait until the next tick to update cache.
	CreateTimer(0.001, Timer_PlayerStateChanged, GetEventInt(event, "userid"), TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_PlayerStateChanged(Handle:timer, any:userid)
{
	new client = GetClientOfUserId(userid);
	
	if (IS_CLIENT(client) && IsClientInGame(client))
	{
		Wallhack_UpdateClientCache(client);
	}

	return Plugin_Stop;
}

Wallhack_UpdateClientCache(client)
{
	g_iTeam[client] = GetClientTeam(client);
	g_bIsObserver[client] = IsClientObserver(client);
	g_bIsFake[client] = IsFakeClient(client);
	g_bProcess[client] = IsPlayerAlive(client);
	
	g_bIgnore[client] = g_bIsFake[client];
}

public OnMaxTracesChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_iMaxTraces = GetConVarInt(convar);
}

Wallhack_Hook(client)
{
	SDKHook(client, SDKHook_SetTransmit, Hook_SetTransmit);
	SDKHook(client, SDKHook_WeaponEquipPost, Hook_WeaponEquipPost);
	SDKHook(client, SDKHook_WeaponDropPost, Hook_WeaponDropPost);
}

public OnEntityCreated(entity, const String:classname[])
{
	if (entity > MaxClients && entity < 2048)
	{
		g_iWeaponOwner[entity] = 0;
	}
}

public OnEntityDestroyed(entity)
{
	if (entity > MaxClients && entity < 2048)
	{
		g_iWeaponOwner[entity] = 0;
	}
}

public Hook_WeaponEquipPost(client, weapon)
{
	if (weapon > MaxClients && weapon < 2048)
	{
		g_iWeaponOwner[weapon] = client;
		SDKHook(weapon, SDKHook_SetTransmit, Hook_SetTransmitWeapon);
	}
}

public Hook_WeaponDropPost(client, weapon)
{
	if (weapon > MaxClients && weapon < 2048)
	{
		g_iWeaponOwner[weapon] = 0;
		SDKUnhook(weapon, SDKHook_SetTransmit, Hook_SetTransmitWeapon);
	}
}

public Action:Hook_NormalSound(clients[64], &numClients, String:sample[PLATFORM_MAX_PATH], &entity, &channel, &Float:volume, &level, &pitch, &flags)
{
	/* Emit sounds to clients who aren't being transmitted the entity. */
	decl dummy;
	
	if (!g_iMode || g_iSoundESP < 0)
		return Plugin_Continue;
	
	if (!entity || !IsValidEdict(entity) || GetTrieValue(g_hIgnoreSounds, sample, dummy))
		return Plugin_Continue;

	new iOwner = (entity > MaxClients) ? g_iWeaponOwner[entity] : entity;
		
	if (!IS_CLIENT(iOwner))
		return Plugin_Continue;
	
	decl newClients[MaxClients];
	new bool:bAddClient[MaxClients+1], newTotal;
	
	// Check clients that get the sound by default.
	for (new i = 0; i < numClients; i++)
	{
		new client = clients[i];
		
		// SourceMod and game engine don't always agree.
		if (!IsClientInGame(client))
			continue;
		
		// These clients need the entity information for prediction.
		if (g_bIsFake[client] || client == iOwner)
		{
			newClients[newTotal++] = client;
			continue;
		}
		
		// Body sounds (footsteps, jumping, etc) will be kept strict to the PVS because they're quiet anyway.
		// Weapons can be heard from larger distances.
		if (channel == SNDCHAN_BODY)
			bAddClient[client] = g_bIsVisible[iOwner][client];
		else
			bAddClient[client] = true;
	}
	
	// Emit with entity information.
	if (newTotal)
	{
		EmitSound(newClients, newTotal, sample, entity, channel, level, flags, volume, pitch);
		newTotal = 0;
	}
	
	// R52 fakes weapon, item and body sounds only.
	new bool:bFake = (g_iSoundESP > 0 && (channel == SNDCHAN_WEAPON || channel == SNDCHAN_ITEM || channel == SNDCHAN_BODY));
	decl hiddenClients[MaxClients];
	new hiddenTotal;
	
	// Determine which clients still need this sound.
	for (new i = 1; i <= MaxClients; i++)
	{
		// A client in the PVS will be expected to predict the sound even if we're blocking transmit.
		if (bAddClient[i] || ((g_bProcess[i] || g_bIsObserver[i]) && !g_bIsVisible[iOwner][i] && g_iPVSSoundCache[iOwner][i] > g_iTickCount))
		{
			if (bFake && !g_bIsVisible[iOwner][i])
			{
				hiddenClients[hiddenTotal++] = i;
			}
			else
			{
				newClients[newTotal++] = i;
			}
		}
	}
	
	decl Float:vOrigin[3];
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", vOrigin);
	
	// Emit without entity information.
	if (newTotal)
	{
		EmitSound(newClients, newTotal, sample, SOUND_FROM_WORLD, channel, level, flags, volume, pitch, _, vOrigin);
	}
	
	if (hiddenTotal)
	{
		SoundESP_Emit(hiddenClients, hiddenTotal, sample, channel, level, flags, volume, pitch, vOrigin);
	}
	
	return Plugin_Stop;
}

/**
 * Anti-SoundESP (SMAC Ultr@ R52, smac_SoundESP). For each listener who can't see the source:
 *   1, 2, 4  the sound comes from a random point near the source (x/y -269.7..289, z -180..289);
 *   2+       level 75 and pitch 100, so the weapon can't be told from them;
 *   3, 4     volume 100000 / dist^2 limited to 0.7, nothing below 0.1 (about 1000 units).
 * R52 replayed one sound per server tick from OnPlayerRunCmd and dropped the rest; here every sound
 * is sent right away.
 */
SoundESP_Emit(const clients[], numClients, const String:sample[], channel, level, flags, Float:volume, pitch, const Float:vSource[3])
{
	decl Float:vPos[3], Float:vListener[3], players[1];
	
	for (new n = 0; n < numClients; n++)
	{
		new client = clients[n];
		new iLevel = level, iPitch = pitch;
		new Float:fVolume = volume;
		
		vPos[0] = vSource[0];
		vPos[1] = vSource[1];
		vPos[2] = vSource[2];
		
		if (g_iSoundESP != 3)
		{
			vPos[0] += GetRandomFloat(-269.7, 289.0);
			vPos[1] += GetRandomFloat(-269.7, 289.0);
			vPos[2] += GetRandomFloat(-180.0, 289.0);
		}
		
		if (g_iSoundESP >= 2)
		{
			iLevel = SNDLEVEL_NORMAL;
			iPitch = SNDPITCH_NORMAL;
		}
		
		if (g_iSoundESP >= 3)
		{
			GetClientAbsOrigin(client, vListener);
			new Float:fDist = GetVectorDistance(vListener, vSource, true);
			
			fVolume = (fDist > 0.0) ? 100000.0 / fDist : 0.7;
			
			if (fVolume < 0.1)
				continue;
			
			if (fVolume > 0.7)
				fVolume = 0.7;
		}
		
		players[0] = client;
		EmitSound(players, 1, sample, SOUND_FROM_WORLD, channel, iLevel, flags, fVolume, iPitch, _, vPos);
	}
}

/**
 * OnGameFrame
 */
public OnGameFrame()
{
	g_iTickCount = GetGameTickCount();
	
	// Increment to next thread.
	if (++g_iCurrentThread > g_iTotalThreads)
	{
		g_iCurrentThread = 1;
		
		// Reassign threads
		if (g_iTraceCount)
		{
			// Calculate total needed threads for the next pass.
			g_iTotalThreads = g_iTraceCount / g_iMaxTraces + 1;
			
			// Assign each client to a thread.
			new iThreadAssign = 1;
			
			for (new i = 1; i <= MaxClients; i++)
			{
				if (g_bProcess[i])
				{
					g_iThread[i] = iThreadAssign;
					
					if (++iThreadAssign > g_iTotalThreads)
					{
						iThreadAssign = 1;
					}
				}
			}
			
			g_iTraceCount = 0;
		}
	}
	
	// FFA mode keeps the radar off: engine messages stay blocked and nothing is sent instead.
	if (g_bFarEspEnabled && g_iMode == 1)
	{
		switch (g_iTickCount % g_iTickRate)
		{
			case 0:
			{
				SendRadarSpotted();
			}
			case 1:
			{
				SendRadarTeam(CS_TEAM_T);
			}
			case 2:
			{
				SendRadarTeam(CS_TEAM_CT);
			}
			case 3:
			{
				SendRadarObservers();
			}
			case 4:
			{
				SendRadarFakeTeam(CS_TEAM_T);
			}
			case 5:
			{
				SendRadarFakeTeam(CS_TEAM_CT);
			}
		}
	}
}

public Action:Hook_SetTransmit(entity, client)
{
	static iLastChecked[MAXPLAYERS][MAXPLAYERS];
	
	if (!g_iMode)
		return Plugin_Continue;
	
	// Cache PVS for sound hook.
	g_iPVSSoundCache[entity][client] = g_iTickCount + g_iCacheTicks;
	
	// Data is transmitted multiple times per tick. Only run calculations once.
	if (iLastChecked[entity][client] == g_iTickCount)
	{
		return g_bIsVisible[entity][client] ? Plugin_Continue : Plugin_Handled;
	}

	iLastChecked[entity][client] = g_iTickCount;
	
	if (g_bProcess[client])
	{
		if (g_bProcess[entity] && (g_iMode == 2 || g_iTeam[client] != g_iTeam[entity]) && !g_bIgnore[client])
		{
			if (g_iThread[client] == g_iCurrentThread)
			{
				// Grab client data before running traces.
				UpdateClientData(client);
				UpdateClientData(entity);
				
				new Float:fStart = GetEngineTime();
				new iTraces = g_iTraceCount;
				new bool:bVisible = IsAbleToSee(entity, client);
				
				g_fStatTime += GetEngineTime() - fStart;
				g_iStatTraces += g_iTraceCount - iTraces;
				g_iStatChecks++;
				
				if (bVisible)
				{
					g_bIsVisible[entity][client] = true;
					g_iPVSCache[entity][client] = g_iTickCount + g_iCacheTicks;
				}
				else if (g_iTickCount > g_iPVSCache[entity][client])
				{
					g_bIsVisible[entity][client] = false;
				}
			}
		}
		else
		{
			g_bIsVisible[entity][client] = true;
		}
	}
	else if (!g_bIsFake[client] && g_bProcess[entity] && GetClientObserverMode(client) == OBS_MODE_IN_EYE)
	{
		// Observers in first-person will clone the visiblity of their target.
		new iTarget = GetClientObserverTarget(client);
		
		if (IS_CLIENT(iTarget))
		{
			g_bIsVisible[entity][client] = g_bIsVisible[entity][iTarget];
		}
		else
		{
			g_bIsVisible[entity][client] = true;
		}
	}
	else
	{
		g_bIsVisible[entity][client] = true;
	}
	
	return g_bIsVisible[entity][client] ? Plugin_Continue : Plugin_Handled;
}

public Action:Hook_SetTransmitWeapon(entity, client)
{
	return g_bIsVisible[g_iWeaponOwner[entity]][client] ? Plugin_Continue : Plugin_Handled;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!g_bProcess[client])
		return Plugin_Continue;
	
	g_vEyeAngles[client] = angles;
	g_iCmdTickCount[client] = tickcount;
	
	return Plugin_Continue;
}

UpdateClientData(client)
{
	/* Only update client data once per tick. */
	static iLastCached[MAXPLAYERS];
	
	if (iLastCached[client] == g_iTickCount)
		return;
	
	iLastCached[client] = g_iTickCount;
	
	GetClientMins(client, g_vMins[client]);
	GetClientMaxs(client, g_vMaxs[client]);
	GetClientAbsOrigin(client, g_vAbsCentre[client]);
	GetClientEyePosition(client, g_vEyePos[client]);
	
	// Adjust vectors relative to the model's absolute centre.
	// SMAC Ultr@ R52: half height = view offset / 2.2 (follows crouching, a bit lower than the hull).
	new Float:fHalfHeight = (g_vEyePos[client][2] - g_vAbsCentre[client][2]) / 2.2;
	
	if (fHalfHeight > 0.0)
	{
		g_vMaxs[client][2] = fHalfHeight;
	}
	else
	{
		g_vMaxs[client][2] /= 2.0;
	}
	
	g_vMins[client][2] -= g_vMaxs[client][2];
	g_vAbsCentre[client][2] += g_vMaxs[client][2];

	// Adjust vectors based on the clients velocity.
	decl Float:vVelocity[3];
	GetClientAbsVelocity(client, vVelocity);
	
	if (!IsVectorZero(vVelocity))
	{
		// Lag compensation.
		decl iTargetTick;
		
		if (g_bIsFake[client])
		{
			iTargetTick = g_iTickCount - 1;
		}
		else
		{
			// Based on CLagCompensationManager::StartLagCompensation.
			new Float:fCorrect = GetClientLatency(client, NetFlow_Outgoing);
			new iLerpTicks = TIME_TO_TICK(GetEntPropFloat(client, Prop_Data, "m_fLerpTime"));
			
			// Assume sv_maxunlag == 1.0f seconds.
			fCorrect += TICK_TO_TIME(iLerpTicks);
			fCorrect = ClampValue(fCorrect, 0.0, 1.0);
			
			iTargetTick = g_iCmdTickCount[client] - iLerpTicks;
			
			if (FloatAbs(fCorrect - TICK_TO_TIME(g_iTickCount - iTargetTick)) > 0.2)
			{
				// Difference between cmd time and latency is too big > 200ms.
				// Use time correction based on latency.
				iTargetTick = g_iTickCount - TIME_TO_TICK(fCorrect);
			}
		}
		
		// Use velocity before it's modified.
		decl Float:vTemp[3];
		vTemp[0] = FloatAbs(vVelocity[0]) * 0.01;
		vTemp[1] = FloatAbs(vVelocity[1]) * 0.01;
		vTemp[2] = FloatAbs(vVelocity[2]) * 0.01;
		
		// Calculate predicted positions for the next frame.
		decl Float:vPredicted[3];
		ScaleVector(vVelocity, TICK_TO_TIME((g_iTickCount - iTargetTick) * g_iTotalThreads));
		AddVectors(g_vAbsCentre[client], vVelocity, vPredicted);
		
		// Make sure the predicted position is still inside the world.
		TR_TraceHullFilter(vPredicted, vPredicted, Float:{-5.0, -5.0, -5.0}, Float:{5.0, 5.0, 5.0}, MASK_PLAYERSOLID_BRUSHONLY, Filter_WorldOnly);
		g_iTraceCount++;
		
		if (!TR_DidHit())
		{
			g_vAbsCentre[client] = vPredicted;
			AddVectors(g_vEyePos[client], vVelocity, g_vEyePos[client]);
		}
		
		// Expand the mins/maxs to help smooth during fast movement.
		if (vTemp[0] > 1.0)
		{
			g_vMins[client][0] *= vTemp[0];
			g_vMaxs[client][0] *= vTemp[0];
		}
		if (vTemp[1] > 1.0)
		{
			g_vMins[client][1] *= vTemp[1];
			g_vMaxs[client][1] *= vTemp[1];
		}
		if (vTemp[2] > 1.0)
		{
			g_vMins[client][2] *= vTemp[2];
			g_vMaxs[client][2] *= vTemp[2];
		}
	}
	
	// The client renders its own movement ahead of the server by about its ping, plus the ticks until its next check.
	// In that time it can side-step at most 0.5*a*t^2 off the predicted path (from a standstill, or by reversing).
	g_fPeekDist[client] = 0.0;
	
	if (g_fPeekTime > 0.0 && !g_bIsFake[client] && g_hCvarAccelerate != INVALID_HANDLE && g_hCvarFriction != INVALID_HANDLE && g_hCvarMaxSpeed != INVALID_HANDLE)
	{
		new Float:fMaxSpeed = GetConVarFloat(g_hCvarMaxSpeed);
		new Float:fAccel = (GetConVarFloat(g_hCvarAccelerate) + GetConVarFloat(g_hCvarFriction)) * fMaxSpeed;
		new Float:fTime = GetClientLatency(client, NetFlow_Both) + TICK_TO_TIME(g_iTotalThreads);
		
		if (fTime > g_fPeekTime)
		{
			fTime = g_fPeekTime;
		}
		
		g_fPeekDist[client] = 0.5 * fAccel * fTime * fTime;
		
		if (g_fPeekDist[client] > fMaxSpeed * fTime)
		{
			g_fPeekDist[client] = fMaxSpeed * fTime;
		}
	}
}

/**
 * Calculations
 */
bool:IsAbleToSee(entity, client)
{
	// Skip all traces if the player isn't within the field of view.
	if (!IsInFieldOfView(g_vEyePos[client], g_vEyeAngles[client], g_vAbsCentre[entity]))
		return false;
	
	decl Float:vSamples[SAMPLE_COUNT][3], Float:vOuter[4][3], Float:vInner[4][3];
	
	GetRectangleCorners(g_vEyePos[client], g_vAbsCentre[entity], g_vMins[entity], g_vMaxs[entity], 1.30, vOuter);
	GetRectangleCorners(g_vEyePos[client], g_vAbsCentre[entity], g_vMins[entity], g_vMaxs[entity], 0.65, vInner);
	
	for (new i = 0; i < 3; i++)
	{
		vSamples[0][i] = g_vAbsCentre[entity][i];
		// Head (SMAC Ultr@ R52; stock SMAC traced to a point 50 units in front of the eyes).
		vSamples[5][i] = g_vEyePos[entity][i];
		
		for (new j = 0; j < 4; j++)
		{
			vSamples[1 + j][i] = vOuter[j][i];
			vSamples[6 + j][i] = vInner[j][i];
		}
	}
	
	decl Float:vEyes[EYE_COUNT][3], bool:bEyes[EYE_COUNT];
	new bool:bPeekReady;
	
	vEyes[0] = g_vEyePos[client];
	bEyes[0] = true;
	
	new bool:bOcc = g_bOccEnabled && g_bOccLoaded;
	
	// Visible pairs usually stay visible along the same line: try it first.
	new iCached = g_iLastSample[entity][client] - 1;
	
	if (iCached >= 0)
	{
		new iEye = iCached / SAMPLE_COUNT;
		
		if (iEye > 0)
		{
			GetPeekEyes(entity, client, vEyes, bEyes);
			bPeekReady = true;
		}
		
		if (bEyes[iEye] && IsPointVisible(vEyes[iEye], vSamples[iCached % SAMPLE_COUNT]))
			return true;
		
		if (iCached == 0 && bOcc && Occ_FindFromTrace(entity, client, vEyes, bEyes, vSamples, bPeekReady))
		{
			g_iLastSample[entity][client] = 0;
			return false;
		}
	}
	
	// A wall that hid this pair last time usually still does.
	if (bOcc && g_iOccCache[entity][client])
	{
		if (!bPeekReady)
		{
			GetPeekEyes(entity, client, vEyes, bEyes);
			bPeekReady = true;
		}
		
		g_iTraceCount++;
		g_iStatProofs++;
		
		if (Occ_Proves(g_iOccCache[entity][client] - 1, vEyes, bEyes, vSamples))
		{
			g_iStatOccCached++;
			g_iLastSample[entity][client] = 0;
			return false;
		}
		
		g_iOccCache[entity][client] = 0;
	}
	
	for (new iEye = 0; iEye < EYE_COUNT; iEye++)
	{
		if (iEye == 1 && !bPeekReady)
		{
			GetPeekEyes(entity, client, vEyes, bEyes);
			bPeekReady = true;
		}
		
		if (!bEyes[iEye])
			continue;
		
		new iCount = (iEye == 0) ? SAMPLE_COUNT : SAMPLE_PEEK_COUNT;
		
		for (new i = 0; i < iCount; i++)
		{
			new iIndex = iEye * SAMPLE_COUNT + i;
			
			if (iIndex == iCached)
				continue;
			
			if (IsPointVisible(vEyes[iEye], vSamples[i]))
			{
				g_iLastSample[entity][client] = iIndex + 1;
				return true;
			}
			
			// The first blocked trace to the centre tells which wall is in the way: if it hides everything, stop here.
			if (iIndex == 0 && bOcc && Occ_FindFromTrace(entity, client, vEyes, bEyes, vSamples, bPeekReady))
			{
				g_iLastSample[entity][client] = 0;
				return false;
			}
		}
	}
	
	g_iLastSample[entity][client] = 0;
	return false;
}

/**
 * Right after a blocked trace from the real eye to the centre: look up the world brushes at the hit point and keep
 * the first one that hides the entity from every eye. The trace result must still be the current one.
 */
bool:Occ_FindFromTrace(entity, client, Float:vEyes[][3], bool:bEyes[], Float:vSamples[][3], &bool:bPeekReady)
{
	if (TR_GetEntityIndex() != 0)
		return false;
	
	decl Float:vHit[3], Float:vDir[3];
	TR_GetEndPosition(vHit);
	
	SubtractVectors(vSamples[0], vEyes[0], vDir);
	NormalizeVector(vDir, vDir);
	
	// Step a little into the wall so the point lands in the solid leaf behind the surface.
	ScaleVector(vDir, 2.0);
	AddVectors(vHit, vDir, vHit);
	
	new iLeaf = Occ_PointLeaf(vHit);
	
	if (iLeaf < 0)
		return false;
	
	new iFirst = g_iOccLeaf[iLeaf * 2];
	new iCount = g_iOccLeaf[iLeaf * 2 + 1];
	
	if (iCount > 16)
	{
		iCount = 16;
	}
	
	for (new i = iFirst; i < iFirst + iCount; i++)
	{
		new iBrush = g_iOccLeafBrush[i];
		
		if (!g_iOccBrushCount[iBrush])
			continue;
		
		if (!bPeekReady)
		{
			GetPeekEyes(entity, client, vEyes, bEyes);
			bPeekReady = true;
		}
		
		g_iTraceCount++;
		g_iStatProofs++;
		
		if (Occ_Proves(iBrush, vEyes, bEyes, vSamples))
		{
			g_iOccCache[entity][client] = iBrush + 1;
			g_iStatOccFound++;
			return true;
		}
	}
	
	return false;
}

/**
 * Does the brush block every segment the visibility traces would test? The real eye and the peek eyes lie on one
 * line, and the points from which a segment to a fixed sample hits a convex brush form a convex set, so checking
 * from the two outermost eyes covers every eye between them. All 10 samples are checked from both.
 */
bool:Occ_Proves(brush, Float:vEyes[][3], bool:bEyes[], Float:vSamples[][3])
{
	new iEyeA = bEyes[1] ? 1 : 0;
	new iEyeB = bEyes[2] ? 2 : 0;
	
	for (new i = 0; i < SAMPLE_COUNT; i++)
	{
		if (!Occ_SegmentBlocked(brush, vEyes[iEyeA], vSamples[i]))
			return false;
		
		if (iEyeB != iEyeA && !Occ_SegmentBlocked(brush, vEyes[iEyeB], vSamples[i]))
			return false;
	}
	
	return true;
}

Occ_MapStart()
{
	for (new i = 0; i < MAXPLAYERS; i++)
	{
		for (new j = 0; j < MAXPLAYERS; j++)
		{
			g_iOccCache[i][j] = 0;
		}
	}
	
	g_iBeamSprite = PrecacheModel("materials/sprites/laserbeam.vmt");
	
	decl String:sMap[PLATFORM_MAX_PATH], String:sError[128];
	GetCurrentMap(sMap, sizeof(sMap));
	
	if (Occ_Load(sMap, sError, sizeof(sError)))
	{
		LogMessage("Occluders for %s: %d of %d brushes.", sMap, g_iOccKept, g_iOccNumBrushes);
	}
	else
	{
		LogMessage("No occluders for %s (%s), traces only.", sMap, sError);
	}
}

public Action:Command_Occ(client, args)
{
	decl String:sArg[16];
	GetCmdArg(1, sArg, sizeof(sArg));
	
	if (StrEqual(sArg, "reset"))
	{
		g_iStatChecks = g_iStatTraces = g_iStatProofs = g_iStatOccCached = g_iStatOccFound = 0;
		g_fStatTime = 0.0;
		ReplyToCommand(client, "[SMAC] Anti-Wallhack stats reset.");
		return Plugin_Handled;
	}
	
	if (StrEqual(sArg, "show"))
	{
		Occ_Show(client);
		return Plugin_Handled;
	}
	
	if (g_bOccLoaded)
	{
		ReplyToCommand(client, "[SMAC] Occluders: %s, %d of %d brushes (%d failed the plane check), %d nodes, %d leafs.", g_bOccEnabled ? "on" : "off (smac_wallhack_occluders 0)", g_iOccKept, g_iOccNumBrushes, g_iOccRejected, g_iOccNumNodes, g_iOccNumLeafs);
	}
	else
	{
		ReplyToCommand(client, "[SMAC] Occluders: not loaded for this map (see the log), traces only.");
	}
	
	if (g_iStatChecks)
	{
		ReplyToCommand(client, "[SMAC] Checks: %d, per check: %.2f engine traces, %.2f brush proofs, %.2f us.", g_iStatChecks, float(g_iStatTraces - g_iStatProofs) / float(g_iStatChecks), float(g_iStatProofs) / float(g_iStatChecks), g_fStatTime * 1000000.0 / float(g_iStatChecks));
		ReplyToCommand(client, "[SMAC] Hidden by occluder: %d from cache, %d newly found (%.1f%% of checks).", g_iStatOccCached, g_iStatOccFound, float(g_iStatOccCached + g_iStatOccFound) * 100.0 / float(g_iStatChecks));
	}
	
	return Plugin_Handled;
}

/**
 * Draws the bounding box of each brush that currently hides an enemy from the client, for 5 seconds.
 */
Occ_Show(client)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client))
	{
		ReplyToCommand(client, "[SMAC] In game only.");
		return;
	}
	
	new iShown;
	
	for (new i = 1; i <= MaxClients; i++)
	{
		new iBrush = g_iOccCache[i][client] - 1;
		
		if (iBrush < 0 || !IsClientInGame(i))
			continue;
		
		decl Float:vMins[3], Float:vMaxs[3];
		
		for (new k = 0; k < 3; k++)
		{
			vMins[k] = g_fOccBrushMins[iBrush * 3 + k];
			vMaxs[k] = g_fOccBrushMaxs[iBrush * 3 + k];
		}
		
		if (vMins[0] > vMaxs[0] || vMins[1] > vMaxs[1] || vMins[2] > vMaxs[2])
			continue;
		
		Occ_DrawBox(client, vMins, vMaxs);
		ReplyToCommand(client, "[SMAC] %N is behind brush #%d.", i, iBrush);
		iShown++;
	}
	
	if (!iShown)
	{
		ReplyToCommand(client, "[SMAC] Nobody is hidden from you by an occluder right now.");
	}
}

Occ_DrawBox(client, const Float:vMins[3], const Float:vMaxs[3])
{
	decl Float:vCorner[8][3];
	
	for (new i = 0; i < 8; i++)
	{
		vCorner[i][0] = (i & 1) ? vMaxs[0] : vMins[0];
		vCorner[i][1] = (i & 2) ? vMaxs[1] : vMins[1];
		vCorner[i][2] = (i & 4) ? vMaxs[2] : vMins[2];
	}
	
	new iColor[4] = { 255, 64, 0, 255 };
	
	// The 12 edges: corners that differ in exactly one bit.
	for (new i = 0; i < 8; i++)
	{
		for (new iBit = 1; iBit < 8; iBit <<= 1)
		{
			if (i & iBit)
				continue;
			
			TE_SetupBeamPoints(vCorner[i], vCorner[i | iBit], g_iBeamSprite, 0, 0, 0, 5.0, 1.0, 1.0, 0, 0.0, iColor, 0);
			TE_SendToClient(client);
		}
	}
}

/**
 * Peek lookahead, after CornerCulling (github.com/87andrewh/CornerCulling): the client may already be up to
 * g_fPeekDist units to either side of where the server thinks its eyes are, so also look from those two points.
 * The side is perpendicular to the line towards the entity, where a side-step changes the most.
 */
GetPeekEyes(entity, client, Float:vEyes[][3], bool:bEyes[])
{
	bEyes[1] = false;
	bEyes[2] = false;
	
	if (g_fPeekDist[client] < 1.0)
		return;
	
	decl Float:vSide[3];
	vSide[0] = g_vEyePos[client][1] - g_vAbsCentre[entity][1];
	vSide[1] = g_vAbsCentre[entity][0] - g_vEyePos[client][0];
	vSide[2] = 0.0;
	
	if (NormalizeVector(vSide, vSide) == 0.0)
		return;
	
	// A trace starting inside a wall could come out on its other side (TR_StartSolid isn't in SM 1.6).
	if (TR_GetPointContents(g_vEyePos[client]) & MASK_PLAYERSOLID)
		return;
	
	ScaleVector(vSide, g_fPeekDist[client]);
	
	decl Float:vEnd[3];
	
	for (new i = 1; i < EYE_COUNT; i++)
	{
		if (i == 1)
		{
			AddVectors(g_vEyePos[client], vSide, vEnd);
		}
		else
		{
			SubtractVectors(g_vEyePos[client], vSide, vEnd);
		}
		
		// Never step through a wall: stop where the client itself would be stopped.
		TR_TraceHullFilter(g_vEyePos[client], vEnd, Float:{-4.0, -4.0, -4.0}, Float:{4.0, 4.0, 4.0}, MASK_PLAYERSOLID, Filter_NoPlayers);
		g_iTraceCount++;
		
		TR_GetEndPosition(vEyes[i]);
		
		// Barely moved (against a wall): same view as the real eye, don't waste traces on it.
		bEyes[i] = GetVectorDistance(g_vEyePos[client], vEyes[i], true) >= 1.0;
	}
}

bool:IsInFieldOfView(const Float:start[3], const Float:angles[3], const Float:end[3])
{
	decl Float:normal[3], Float:plane[3];
	
	GetAngleVectors(angles, normal, NULL_VECTOR, NULL_VECTOR);
	SubtractVectors(end, start, plane);
	NormalizeVector(plane, plane);
	
	return GetVectorDotProduct(plane, normal) > 0.0; // Cosine(Deg2Rad(179.9 / 2.0))
}

public bool:Filter_WorldOnly(entity, mask)
{
	return false;
}

public bool:Filter_NoPlayers(entity, mask)
{
	return entity > MaxClients && !IS_CLIENT(GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity"));
}

bool:IsPointVisible(const Float:start[3], const Float:end[3])
{
	TR_TraceRayFilter(start, end, MASK_VISIBLE, RayType_EndPoint, Filter_NoPlayers);
	g_iTraceCount++;
	return TR_GetFraction() == 1.0;
}

GetRectangleCorners(const Float:start[3], const Float:end[3], const Float:mins[3], const Float:maxs[3], Float:scale, Float:vRectangle[4][3])
{
	new Float:ZpozOffset = maxs[2];
	new Float:ZnegOffset = mins[2];
	new Float:WideOffset = ((maxs[0] - mins[0]) + (maxs[1] - mins[1])) / g_fWideDivisor;

	// This rectangle is just a point!
	if (ZpozOffset == 0.0 && ZnegOffset == 0.0 && WideOffset == 0.0)
	{
		for (new i = 0; i < 4; i++)
		{
			vRectangle[i] = end;
		}
		
		return;
	}

	// Adjust to scale.
	ZpozOffset *= scale;
	ZnegOffset *= scale;
	WideOffset *= scale;
	
	// Prepare rotation matrix.
	decl Float:angles[3], Float:fwd[3], Float:right[3];

	SubtractVectors(start, end, fwd);
	NormalizeVector(fwd, fwd);

	GetVectorAngles(fwd, angles);
	GetAngleVectors(angles, fwd, right, NULL_VECTOR);

	decl Float:vTemp[3];

	// If the player is on the same level as us, we can optimize by only rotating on the z-axis.
	if (FloatAbs(fwd[2]) <= 0.7071)
	{
		ScaleVector(right, WideOffset);
		
		// Corner 1, 2
		vTemp = end;
		vTemp[2] += ZpozOffset;
		AddVectors(vTemp, right, vRectangle[0]);
		SubtractVectors(vTemp, right, vRectangle[1]);
		
		// Corner 3, 4
		vTemp = end;
		vTemp[2] += ZnegOffset;
		AddVectors(vTemp, right, vRectangle[2]);
		SubtractVectors(vTemp, right, vRectangle[3]);
		
	}
	else if (fwd[2] > 0.0) // Player is below us.
	{
		fwd[2] = 0.0;
		NormalizeVector(fwd, fwd);
		
		ScaleVector(fwd, scale);
		ScaleVector(fwd, WideOffset);
		ScaleVector(right, WideOffset);
		
		// Corner 1
		vTemp = end;
		vTemp[2] += ZpozOffset;
		AddVectors(vTemp, right, vTemp);
		SubtractVectors(vTemp, fwd, vRectangle[0]);
		
		// Corner 2
		vTemp = end;
		vTemp[2] += ZpozOffset;
		SubtractVectors(vTemp, right, vTemp);
		SubtractVectors(vTemp, fwd, vRectangle[1]);
		
		// Corner 3
		vTemp = end;
		vTemp[2] += ZnegOffset;
		AddVectors(vTemp, right, vTemp);
		AddVectors(vTemp, fwd, vRectangle[2]);
		
		// Corner 4
		vTemp = end;
		vTemp[2] += ZnegOffset;
		SubtractVectors(vTemp, right, vTemp);
		AddVectors(vTemp, fwd, vRectangle[3]);
	}
	else // Player is above us.
	{
		fwd[2] = 0.0;
		NormalizeVector(fwd, fwd);
		
		ScaleVector(fwd, scale);
		ScaleVector(fwd, WideOffset);
		ScaleVector(right, WideOffset);

		// Corner 1
		vTemp = end;
		vTemp[2] += ZpozOffset;
		AddVectors(vTemp, right, vTemp);
		AddVectors(vTemp, fwd, vRectangle[0]);
		
		// Corner 2
		vTemp = end;
		vTemp[2] += ZpozOffset;
		SubtractVectors(vTemp, right, vTemp);
		AddVectors(vTemp, fwd, vRectangle[1]);
		
		// Corner 3
		vTemp = end;
		vTemp[2] += ZnegOffset;
		AddVectors(vTemp, right, vTemp);
		SubtractVectors(vTemp, fwd, vRectangle[2]);
		
		// Corner 4
		vTemp = end;
		vTemp[2] += ZnegOffset;
		SubtractVectors(vTemp, right, vTemp);
		SubtractVectors(vTemp, fwd, vRectangle[3]);
	}
}

new UserMsg:g_msgUpdateRadar = INVALID_MESSAGE_ID;
new bool:g_bPlayerSpotted[MAXPLAYERS];

new g_iSpottedCache[MAXPLAYERS];
new g_iUpdateFrequency;

new g_iPlayerManager = -1;
new g_iPlayerSpotted = -1;

new Handle:g_hCvarForceCamera = INVALID_HANDLE;
new bool:g_bForceCamera;

FarESP_Enable()
{
	if ((g_iPlayerManager = GetPlayerResourceEntity()) == -1)
		return;
		
	#if SOURCEMOD_V_MAJOR >= 1 && SOURCEMOD_V_MINOR >= 7
	g_iPlayerSpotted = FindSendPropInfo("CCSPlayerResource", "m_bPlayerSpotted");
	#else
	g_iPlayerSpotted = FindSendPropOffs("CCSPlayerResource", "m_bPlayerSpotted");
	#endif		

	SDKHook(g_iPlayerManager, SDKHook_ThinkPost, PlayerManager_ThinkPost);
	
	g_msgUpdateRadar = GetUserMessageId("UpdateRadar");
	HookUserMessage(g_msgUpdateRadar, Hook_UpdateRadar, true);
	
	HookEvent("player_death", FarESP_PlayerDeath, EventHookMode_Pre);
	
	g_hCvarForceCamera = FindConVar("mp_forcecamera");
	OnForceCameraChanged(g_hCvarForceCamera, "", "");
	HookConVarChange(g_hCvarForceCamera, OnForceCameraChanged);
	
	g_iUpdateFrequency = TIME_TO_TICK(2.0);
	
	g_bFarEspEnabled = true;
}

FarESP_Disable()
{
	SDKUnhook(g_iPlayerManager, SDKHook_ThinkPost, PlayerManager_ThinkPost);
	
	for (new i = 0; i < sizeof(g_bPlayerSpotted); i++)
	{
		g_bPlayerSpotted[i] = false;
	}
	
	UnhookUserMessage(g_msgUpdateRadar, Hook_UpdateRadar, true);
	
	UnhookEvent("player_death", FarESP_PlayerDeath, EventHookMode_Pre);
	
	UnhookConVarChange(g_hCvarForceCamera, OnForceCameraChanged);
	
	g_bFarEspEnabled = false;
}

public Action:FarESP_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if (IS_CLIENT(client) && IsClientInGame(client))
	{
		SendRadarClient(client, USERMSG_RELIABLE|USERMSG_BLOCKHOOKS);
	}
	
	return Plugin_Continue;
}

public OnForceCameraChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_bForceCamera = (GetConVarInt(convar) == 1);
}

public OnMapStart()
{
	Occ_MapStart();
	
	if (g_iMode && !g_bFarEspEnabled)
	{
		FarESP_Enable();
	}
}

public OnMapEnd()
{
	if (g_bFarEspEnabled)
	{
		FarESP_Disable();
	}
}

public Action:Hook_UpdateRadar(UserMsg:msg_id, Handle:bf, const players[], playersNum, bool:reliable, bool:init)
{
	// We will send custom messages only.
	return Plugin_Handled;
}

public PlayerManager_ThinkPost(entity)
{
	if (!g_bFarEspEnabled)
		return;
	
	// Keep track of which players have been spotted.
	for (new i = 1; i <= MaxClients; i++)
	{
		if (g_bProcess[i] && GetEntData(entity, g_iPlayerSpotted + i, 1))
		{
			// Immediately update this client's data.
			if (!g_bPlayerSpotted[i])
			{
				g_bPlayerSpotted[i] = true;
				SendRadarClient(i, USERMSG_BLOCKHOOKS);
			}
			
			g_iSpottedCache[i] = g_iTickCount + g_iUpdateFrequency;
		}
		else
		{
			g_bPlayerSpotted[i] = false;
		}
	}
}

SendRadarSpotted()
{
	// Send scrambled spotted data to all clients.
	decl iClients[MaxClients];
	new numClients, count;
	
	for (new i = 1; i <= MaxClients; i++)
	{
		if (g_bProcess[i])
		{
			iClients[numClients++] = i;
		}
	}
	
	if (!numClients)
		return;
	
	decl Float:vOrigin[3], Float:vAngles[3];
	new Handle:bf = StartMessageEx(g_msgUpdateRadar, iClients, numClients, USERMSG_BLOCKHOOKS);
	
	for (new i = 1; i <= MaxClients && count < MAX_RADAR_CLIENTS; i++)
	{
		if (g_bPlayerSpotted[i] && g_bProcess[i])
		{
			GetClientAbsOrigin(i, vOrigin);
			GetClientAbsAngles(i, vAngles);
			
			BfWriteByte(bf, i);
			BfWriteSBitLong(bf, RoundToNearest(vOrigin[0] / 4.0), 13);
			BfWriteSBitLong(bf, RoundToNearest(vOrigin[1] / 4.0), 13);
			BfWriteSBitLong(bf, RoundToNearest((vOrigin[2] - MT_GetRandomFloat(500.0, 1000.0)) / 4.0), 13);
			BfWriteSBitLong(bf, RoundToNearest(vAngles[1]), 9);
			count++;
		}
	}
	
	BfWriteByte(bf, 0);
	EndMessage();
}

SendRadarTeam(team)
{
	// Send proper team data to all teammates.
	decl iClients[MaxClients];
	new numClients;
	
	for (new i = 1; i <= MaxClients; i++)
	{
		// Include dead players observering their teammates.
		if ((g_bProcess[i] || (g_bForceCamera && g_bIsObserver[i])) && g_iTeam[i] == team)
		{
			iClients[numClients++] = i;
		}
	}
	
	if (!numClients)
		return;
	
	decl Float:vOrigin[3], Float:vAngles[3], client;
	new Handle:bf = StartMessageEx(g_msgUpdateRadar, iClients, numClients, USERMSG_BLOCKHOOKS);
	
	// Limit payload early.
	if (numClients >= MAX_RADAR_CLIENTS)
		numClients = MAX_RADAR_CLIENTS - 1;
	
	for (new i = 0; i < numClients; i++)
	{
		client = iClients[i];
		
		GetClientAbsOrigin(client, vOrigin);
		GetClientAbsAngles(client, vAngles);
		
		BfWriteByte(bf, client);
		BfWriteSBitLong(bf, RoundToNearest(vOrigin[0] / 4.0), 13);
		BfWriteSBitLong(bf, RoundToNearest(vOrigin[1] / 4.0), 13);
		BfWriteSBitLong(bf, RoundToNearest(vOrigin[2] / 4.0), 13);
		BfWriteSBitLong(bf, RoundToNearest(vAngles[1]), 9);
	}
	
	BfWriteByte(bf, 0);
	EndMessage();
}

SendRadarFakeTeam(team)
{
	// Send fake data to team.
	decl iReceivers[MaxClients], iSenders[MaxClients];
	new numReceivers, numSenders, iReceiver;
	
	for (new i = 1; i <= MaxClients; i++)
	{
		if (g_bProcess[i])
		{
			if (g_iTeam[i] == team)
			{
				iReceivers[numReceivers++] = i;
			}
			else if (g_iSpottedCache[i] < g_iTickCount)
			{
				iSenders[numSenders++] = i;
			}
		}
	}
	
	if (!numReceivers || !numSenders)
		return;
	
	decl Float:vOrigin[3];
	new Handle:bf = StartMessageEx(g_msgUpdateRadar, iReceivers, numReceivers, USERMSG_BLOCKHOOKS);
	
	// Randomize so that every client is ensured fake data.
	SortIntegers(iReceivers, numReceivers, Sort_Random);
	
	// Randomize the payload before limiting.
	if (numSenders >= MAX_RADAR_CLIENTS)
	{
		SortIntegers(iSenders, numSenders, Sort_Random);
		numSenders = MAX_RADAR_CLIENTS - 1;
	}
	
	for (new i = 0; i < numSenders; i++)
	{
		GetClientAbsOrigin(iReceivers[iReceiver++], vOrigin);

		BfWriteByte(bf, iSenders[i]);
		BfWriteSBitLong(bf, RoundToNearest((vOrigin[0] + MT_GetRandomFloat(-1000.0, 1000.0)) / 4.0), 13);
		BfWriteSBitLong(bf, RoundToNearest((vOrigin[1] + MT_GetRandomFloat(-1000.0, 1000.0)) / 4.0), 13);
		BfWriteSBitLong(bf, RoundToNearest((vOrigin[2] + MT_GetRandomFloat(-1000.0, 1000.0)) / 4.0), 13);
		BfWriteSBitLong(bf, RoundToNearest(MT_GetRandomFloat(-180.0, 180.0)), 9);
		
		if (iReceiver >= numReceivers)
			iReceiver = 0;
 	}
 	
	BfWriteByte(bf, 0);
	EndMessage();
}

SendRadarClient(client, flags)
{
	// FFA mode: radar off.
	if (g_iMode != 1)
		return;

	// A player was spotted and needs to be sent out to all clients.
	decl iClients[MaxClients];
	new numClients, iTeam = g_iTeam[client];
	
	for (new i = 1; i <= MaxClients; i++)
	{
		if (g_bProcess[i] && g_iTeam[i] != iTeam)
		{
			iClients[numClients++] = i;
		}
	}
	
	if (!numClients)
		return;
	
	decl Float:vOrigin[3], Float:vAngles[3];
	new Handle:bf = StartMessageEx(g_msgUpdateRadar, iClients, numClients, flags);
	
	GetClientAbsOrigin(client, vOrigin);
	GetClientAbsAngles(client, vAngles);
	
	BfWriteByte(bf, client);
	BfWriteSBitLong(bf, RoundToNearest(vOrigin[0] / 4.0), 13);
	BfWriteSBitLong(bf, RoundToNearest(vOrigin[1] / 4.0), 13);
	BfWriteSBitLong(bf, RoundToNearest((vOrigin[2] - MT_GetRandomFloat(500.0, 1000.0)) / 4.0), 13);
	BfWriteSBitLong(bf, RoundToNearest(vAngles[1]), 9);

	BfWriteByte(bf, 0);
	EndMessage();
}

SendRadarObservers()
{
	// Send all player data to all observers.
	decl iClients[MaxClients];
	new numClients, count;
	
	for (new i = 1; i <= MaxClients; i++)
	{
		// Include teammate-observers if forcecamera is disabled.
		if (g_bIsObserver[i] && (!g_bForceCamera || g_iTeam[i] <= CS_TEAM_SPECTATOR))
		{
			iClients[numClients++] = i;
		}
	}
	
	if (!numClients)
		return;
	
	decl Float:vOrigin[3], Float:vAngles[3];
	new Handle:bf = StartMessageEx(g_msgUpdateRadar, iClients, numClients, USERMSG_BLOCKHOOKS);
	
	for (new i = 1; i <= MaxClients && count < MAX_RADAR_CLIENTS; i++)
	{
		if (g_bProcess[i])
		{
			GetClientAbsOrigin(i, vOrigin);
			GetClientAbsAngles(i, vAngles);
			
			BfWriteByte(bf, i);
			BfWriteSBitLong(bf, RoundToNearest(vOrigin[0] / 4.0), 13);
			BfWriteSBitLong(bf, RoundToNearest(vOrigin[1] / 4.0), 13);
			BfWriteSBitLong(bf, RoundToNearest(vOrigin[2] / 4.0), 13);
			BfWriteSBitLong(bf, RoundToNearest(vAngles[1]), 9);
			count++;
		}
	}
	
	BfWriteByte(bf, 0);
	EndMessage();
}
