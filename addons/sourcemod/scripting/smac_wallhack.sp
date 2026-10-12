#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smac>

#define CS_TEAM_NONE		0
#define CS_TEAM_SPECTATOR	1
#define CS_TEAM_T			2
#define CS_TEAM_CT			3

#define MAX_RADAR_CLIENTS	36

public Plugin:myinfo =
{
	name = "SMAC: Anti-Wallhack",
	author = SMAC_AUTHOR,
	description = "Prevents wallhack cheats from working",
	version = SMAC_VERSION,
	url = SMAC_URL
};

new bool:g_bFarEspEnabled;
new g_iMaxTraces;

new g_iMode = 1;

new Float:g_fWideDivisor = 7.0;
new Handle:g_hCvarTime = INVALID_HANDLE;

new g_iSoundESP = 0;
new Handle:g_hCvarTickTime = INVALID_HANDLE;

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
	new Handle: hCvar = CreateConVar("smac_wallhack", "1", "Anti-wallhack: 0=off, 1=normal, 2=FFA (radar off)", _, true, 0.0, true, 2.0);
	g_iMode = GetConVarInt(hCvar);
	HookConVarChange(hCvar, OnModeChanged);

	hCvar = CreateConVar("smac_wallhack_Level", "0.0", "Anti-WH tightness (easy < 0 < hard; -3.0 = stock width)", _, true, -3.0, true, 3.0);
	OnLevelChanged(hCvar, "", "");
	HookConVarChange(hCvar, OnLevelChanged);

	hCvar = CreateConVar("smac_SoundESP", "0", "Anti-SoundESP for hidden sources: -1=off sounds, 0=real, 1=fake pos, 2=fake+level/pitch, 3=vol by dist, 4=all", _, true, -1.0, true, 4.0);
	g_iSoundESP = GetConVarInt(hCvar);
	HookConVarChange(hCvar, OnSoundESPChanged);

	hCvar = CreateConVar("smac_wallhack_maxtraces", "1280", "Max traces per tick", _, true, 1.0);
	OnMaxTracesChanged(hCvar, "", "");
	HookConVarChange(hCvar, OnMaxTracesChanged);

	g_hCvarTime = CreateConVar("smac_wallhack_Time", "0.2", "Seconds a player stays visible after last seen", _, true, 0.1, true, 0.4);
	HookConVarChange(g_hCvarTime, WallHack_TickOnSettingsChanged);

	g_hCvarTickTime = CreateConVar("smac_wallhack_ticktime", "0", "Legacy: if > 0, used instead of smac_wallhack_Time", _, true, 0.0, true, 2.0);
	HookConVarChange(g_hCvarTickTime, WallHack_TickOnSettingsChanged);
	WallHack_TickOnSettingsChanged(INVALID_HANDLE, "", "");

	g_iTickRate = RoundToFloor(1.0 / GetTickInterval());

	if ((hCvar = FindConVar("sv_minupdaterate")) != INVALID_HANDLE && IsConVarDefault(hCvar))
		SetConVarInt(hCvar, g_iTickRate);
	if ((hCvar = FindConVar("sv_maxupdaterate")) != INVALID_HANDLE && IsConVarDefault(hCvar))
		SetConVarInt(hCvar, g_iTickRate);
	if ((hCvar = FindConVar("sv_client_min_interp_ratio")) != INVALID_HANDLE && IsConVarDefault(hCvar))
		SetConVarInt(hCvar, 0);
	if ((hCvar = FindConVar("sv_client_max_interp_ratio")) != INVALID_HANDLE && IsConVarDefault(hCvar))
		SetConVarInt(hCvar, 1);

	g_iDownloadTable = FindStringTable("downloadables");

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

	g_bIsObserver[client] = false;
	g_bProcess[client] = false;
	g_bIgnore[client] = false;
}

public OnClientDisconnect_Post(client)
{

	for (new i = 0; i < sizeof(g_iPVSCache); i++)
	{
		g_iPVSCache[i][client] = 0;
		g_iPVSSoundCache[i][client] = 0;
		g_bIsVisible[i][client] = true;
	}
}

public Event_PlayerStateChanged(Handle:event, const String:name[], bool:dontBroadcast)
{

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

	for (new i = 0; i < numClients; i++)
	{
		new client = clients[i];

		if (!IsClientInGame(client))
			continue;

		if (g_bIsFake[client] || client == iOwner)
		{
			newClients[newTotal++] = client;
			continue;
		}

		if (channel == SNDCHAN_BODY)
			bAddClient[client] = g_bIsVisible[iOwner][client];
		else
			bAddClient[client] = true;
	}

	if (newTotal)
	{
		EmitSound(newClients, newTotal, sample, entity, channel, level, flags, volume, pitch);
		newTotal = 0;
	}

	new bool:bFake = (g_iSoundESP > 0 && (channel == SNDCHAN_WEAPON || channel == SNDCHAN_ITEM || channel == SNDCHAN_BODY));
	decl hiddenClients[MaxClients];
	new hiddenTotal;

	for (new i = 1; i <= MaxClients; i++)
	{

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

public OnGameFrame()
{
	g_iTickCount = GetGameTickCount();

	if (++g_iCurrentThread > g_iTotalThreads)
	{
		g_iCurrentThread = 1;

		if (g_iTraceCount)
		{

			g_iTotalThreads = g_iTraceCount / g_iMaxTraces + 1;

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

	g_iPVSSoundCache[entity][client] = g_iTickCount + g_iCacheTicks;

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

				UpdateClientData(client);
				UpdateClientData(entity);

				if (IsAbleToSee(entity, client))
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

	static iLastCached[MAXPLAYERS];

	if (iLastCached[client] == g_iTickCount)
		return;

	iLastCached[client] = g_iTickCount;

	GetClientMins(client, g_vMins[client]);
	GetClientMaxs(client, g_vMaxs[client]);
	GetClientAbsOrigin(client, g_vAbsCentre[client]);
	GetClientEyePosition(client, g_vEyePos[client]);

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

	decl Float:vVelocity[3];
	GetClientAbsVelocity(client, vVelocity);

	if (!IsVectorZero(vVelocity))
	{

		decl iTargetTick;

		if (g_bIsFake[client])
		{
			iTargetTick = g_iTickCount - 1;
		}
		else
		{

			new Float:fCorrect = GetClientLatency(client, NetFlow_Outgoing);
			new iLerpTicks = TIME_TO_TICK(GetEntPropFloat(client, Prop_Data, "m_fLerpTime"));

			fCorrect += TICK_TO_TIME(iLerpTicks);
			fCorrect = ClampValue(fCorrect, 0.0, 1.0);

			iTargetTick = g_iCmdTickCount[client] - iLerpTicks;

			if (FloatAbs(fCorrect - TICK_TO_TIME(g_iTickCount - iTargetTick)) > 0.2)
			{

				iTargetTick = g_iTickCount - TIME_TO_TICK(fCorrect);
			}
		}

		decl Float:vTemp[3];
		vTemp[0] = FloatAbs(vVelocity[0]) * 0.01;
		vTemp[1] = FloatAbs(vVelocity[1]) * 0.01;
		vTemp[2] = FloatAbs(vVelocity[2]) * 0.01;

		decl Float:vPredicted[3];
		ScaleVector(vVelocity, TICK_TO_TIME((g_iTickCount - iTargetTick) * g_iTotalThreads));
		AddVectors(g_vAbsCentre[client], vVelocity, vPredicted);

		TR_TraceHullFilter(vPredicted, vPredicted, Float:{-5.0, -5.0, -5.0}, Float:{5.0, 5.0, 5.0}, MASK_PLAYERSOLID_BRUSHONLY, Filter_WorldOnly);
		g_iTraceCount++;

		if (!TR_DidHit())
		{
			g_vAbsCentre[client] = vPredicted;
			AddVectors(g_vEyePos[client], vVelocity, g_vEyePos[client]);
		}

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
}

bool:IsAbleToSee(entity, client)
{

	if (IsInFieldOfView(g_vEyePos[client], g_vEyeAngles[client], g_vAbsCentre[entity]))
	{

		if (IsPointVisible(g_vEyePos[client], g_vAbsCentre[entity]))
			return true;

		if (IsRectangleVisible(g_vEyePos[client], g_vAbsCentre[entity], g_vMins[entity], g_vMaxs[entity], 1.30))
			return true;

		if (IsPointVisible(g_vEyePos[client], g_vEyePos[entity]))
			return true;

		if (IsRectangleVisible(g_vEyePos[client], g_vAbsCentre[entity], g_vMins[entity], g_vMaxs[entity], 0.65))
			return true;
	}

	return false;
}

bool:IsInFieldOfView(const Float:start[3], const Float:angles[3], const Float:end[3])
{
	decl Float:normal[3], Float:plane[3];

	GetAngleVectors(angles, normal, NULL_VECTOR, NULL_VECTOR);
	SubtractVectors(end, start, plane);
	NormalizeVector(plane, plane);

	return GetVectorDotProduct(plane, normal) > 0.0;
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

bool:IsRectangleVisible(const Float:start[3], const Float:end[3], const Float:mins[3], const Float:maxs[3], Float:scale=1.0)
{
	new Float:ZpozOffset = maxs[2];
	new Float:ZnegOffset = mins[2];
	new Float:WideOffset = ((maxs[0] - mins[0]) + (maxs[1] - mins[1])) / g_fWideDivisor;

	if (ZpozOffset == 0.0 && ZnegOffset == 0.0 && WideOffset == 0.0)
	{
		return IsPointVisible(start, end);
	}

	ZpozOffset *= scale;
	ZnegOffset *= scale;
	WideOffset *= scale;

	decl Float:angles[3], Float:fwd[3], Float:right[3];

	SubtractVectors(start, end, fwd);
	NormalizeVector(fwd, fwd);

	GetVectorAngles(fwd, angles);
	GetAngleVectors(angles, fwd, right, NULL_VECTOR);

	decl Float:vRectangle[4][3], Float:vTemp[3];

	if (FloatAbs(fwd[2]) <= 0.7071)
	{
		ScaleVector(right, WideOffset);

		vTemp = end;
		vTemp[2] += ZpozOffset;
		AddVectors(vTemp, right, vRectangle[0]);
		SubtractVectors(vTemp, right, vRectangle[1]);

		vTemp = end;
		vTemp[2] += ZnegOffset;
		AddVectors(vTemp, right, vRectangle[2]);
		SubtractVectors(vTemp, right, vRectangle[3]);

	}
	else if (fwd[2] > 0.0)
	{
		fwd[2] = 0.0;
		NormalizeVector(fwd, fwd);

		ScaleVector(fwd, scale);
		ScaleVector(fwd, WideOffset);
		ScaleVector(right, WideOffset);

		vTemp = end;
		vTemp[2] += ZpozOffset;
		AddVectors(vTemp, right, vTemp);
		SubtractVectors(vTemp, fwd, vRectangle[0]);

		vTemp = end;
		vTemp[2] += ZpozOffset;
		SubtractVectors(vTemp, right, vTemp);
		SubtractVectors(vTemp, fwd, vRectangle[1]);

		vTemp = end;
		vTemp[2] += ZnegOffset;
		AddVectors(vTemp, right, vTemp);
		AddVectors(vTemp, fwd, vRectangle[2]);

		vTemp = end;
		vTemp[2] += ZnegOffset;
		SubtractVectors(vTemp, right, vTemp);
		AddVectors(vTemp, fwd, vRectangle[3]);
	}
	else
	{
		fwd[2] = 0.0;
		NormalizeVector(fwd, fwd);

		ScaleVector(fwd, scale);
		ScaleVector(fwd, WideOffset);
		ScaleVector(right, WideOffset);

		vTemp = end;
		vTemp[2] += ZpozOffset;
		AddVectors(vTemp, right, vTemp);
		AddVectors(vTemp, fwd, vRectangle[0]);

		vTemp = end;
		vTemp[2] += ZpozOffset;
		SubtractVectors(vTemp, right, vTemp);
		AddVectors(vTemp, fwd, vRectangle[1]);

		vTemp = end;
		vTemp[2] += ZnegOffset;
		AddVectors(vTemp, right, vTemp);
		SubtractVectors(vTemp, fwd, vRectangle[2]);

		vTemp = end;
		vTemp[2] += ZnegOffset;
		SubtractVectors(vTemp, right, vTemp);
		SubtractVectors(vTemp, fwd, vRectangle[3]);
	}

	for (new i = 0; i < 4; i++)
	{
		if (IsPointVisible(start, vRectangle[i]))
		{
			return true;
		}
	}

	return false;
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

	return Plugin_Handled;
}

public PlayerManager_ThinkPost(entity)
{
	if (!g_bFarEspEnabled)
		return;

	for (new i = 1; i <= MaxClients; i++)
	{
		if (g_bProcess[i] && GetEntData(entity, g_iPlayerSpotted + i, 1))
		{

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

	decl iClients[MaxClients];
	new numClients;

	for (new i = 1; i <= MaxClients; i++)
	{

		if ((g_bProcess[i] || (g_bForceCamera && g_bIsObserver[i])) && g_iTeam[i] == team)
		{
			iClients[numClients++] = i;
		}
	}

	if (!numClients)
		return;

	decl Float:vOrigin[3], Float:vAngles[3], client;
	new Handle:bf = StartMessageEx(g_msgUpdateRadar, iClients, numClients, USERMSG_BLOCKHOOKS);

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

	SortIntegers(iReceivers, numReceivers, Sort_Random);

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

	if (g_iMode != 1)
		return;

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

	decl iClients[MaxClients];
	new numClients, count;

	for (new i = 1; i <= MaxClients; i++)
	{

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
