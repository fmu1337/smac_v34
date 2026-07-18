#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <smac>

/*
 * SMAC: Anti-Smoke
 *
 * Immersion hide (original) plus optional eye↔eye LOS occlusion through
 * smoke spheres — idea rewritten from HOTGUARD fixsmoke / Valve-style
 * IsLineBlockedBySmoke (no SauRay extension required).
 */

public Plugin:myinfo =
{
	name = "SMAC: Anti-Smoke",
	author = SMAC_AUTHOR,
	description = "Prevents anti-smoke cheats (immersion + LOS modes)",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define SMOKE_DELAYTIME		0.75
#define SMOKE_FADETIME		15.0
#define SMOKE_RADIUS_SQ		2025		/* 45^2 immersion */
#define SMOKE_LOS_RADIUS_SQ	12225.0		/* ~110.6u LOS cylinder */

/* 0 = immersion only, 1 = LOS only, 2 = both */
new Handle:g_hCvarMode = INVALID_HANDLE;
new g_iMode = 2;

new Handle:g_hSmokeLoop = INVALID_HANDLE;
new Handle:g_hSmokes = INVALID_HANDLE;
new bool:g_bIsInSmoke[MAXPLAYERS+1];
new g_iRoundCount;
new bool:g_bHooked[MAXPLAYERS+1];

public OnPluginStart()
{
	g_hSmokes = CreateArray(3);
	g_hCvarMode = SMAC_CreateConVar("smac_antismoke_mode", "2", "Anti-smoke mode: 0=immersion, 1=LOS eye-line, 2=both.", _, true, 0.0, true, 2.0);
	OnModeChanged(g_hCvarMode, "", "");
	HookConVarChange(g_hCvarMode, OnModeChanged);

	HookEvent("smokegrenade_detonate", Event_SmokeDetonate, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

public OnModeChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	g_iMode = GetConVarInt(convar);
}

public OnMapEnd()
{
	AntiSmoke_UnhookAll();
	g_iRoundCount = 0;
}

public OnClientPutInServer(client)
{
	if (g_hSmokeLoop != INVALID_HANDLE || (g_iMode >= 1 && GetArraySize(g_hSmokes) > 0))
		HookClient(client);
}

public OnClientDisconnect(client)
{
	g_bIsInSmoke[client] = false;
	g_bHooked[client] = false;
}

public Event_SmokeDetonate(Handle:event, const String:name[], bool:dontBroadcast)
{
	new Handle:hPack;
	CreateDataTimer(SMOKE_DELAYTIME, Timer_SmokeDeployed, hPack, TIMER_FLAG_NO_MAPCHANGE);
	WritePackCell(hPack, g_iRoundCount);
	WritePackFloat(hPack, GetEventFloat(event, "x"));
	WritePackFloat(hPack, GetEventFloat(event, "y"));
	WritePackFloat(hPack, GetEventFloat(event, "z"));

	CreateTimer(SMOKE_FADETIME, Timer_SmokeEnded, g_iRoundCount, TIMER_FLAG_NO_MAPCHANGE);
}

public Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	AntiSmoke_UnhookAll();
	g_iRoundCount++;
}

public Action:Timer_SmokeDeployed(Handle:timer, Handle:hPack)
{
	ResetPack(hPack);
	if (g_iRoundCount == ReadPackCell(hPack))
	{
		decl Float:vSmoke[3];
		vSmoke[0] = ReadPackFloat(hPack);
		vSmoke[1] = ReadPackFloat(hPack);
		vSmoke[2] = ReadPackFloat(hPack);
		PushArrayArray(g_hSmokes, vSmoke);
		AntiSmoke_HookAll();
	}
	return Plugin_Stop;
}

public Action:Timer_SmokeEnded(Handle:timer, any:iRoundCount)
{
	if (g_iRoundCount == iRoundCount)
	{
		if (GetArraySize(g_hSmokes))
			RemoveFromArray(g_hSmokes, 0);

		if (!GetArraySize(g_hSmokes))
			AntiSmoke_UnhookAll();
	}
	return Plugin_Stop;
}

public Action:Timer_SmokeCheck(Handle:timer)
{
	if (g_iMode == 1)
		return Plugin_Continue;

	decl Float:vClient[3], Float:vSmoke[3];
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			GetClientAbsOrigin(i, vClient);
			g_bIsInSmoke[i] = false;
			for (new idx = 0; idx < GetArraySize(g_hSmokes); idx++)
			{
				GetArrayArray(g_hSmokes, idx, vSmoke);
				if (GetVectorDistance(vClient, vSmoke, true) < SMOKE_RADIUS_SQ)
				{
					g_bIsInSmoke[i] = true;
					break;
				}
			}
		}
	}
	return Plugin_Continue;
}

public Action:Hook_SetTransmit(entity, client)
{
	if (entity == client || !IS_CLIENT(entity) || !IS_CLIENT(client))
		return Plugin_Continue;
	if (!IsClientInGame(entity) || !IsClientInGame(client))
		return Plugin_Continue;
	if (GetClientTeam(entity) == GetClientTeam(client))
		return Plugin_Continue;

	/* Immersion: hide everyone from a viewer standing in smoke. */
	if (g_iMode != 1 && g_bIsInSmoke[client])
		return Plugin_Handled;

	/* LOS: hide entity if eye-line crosses a smoke sphere (HOTGUARD idea). */
	if (g_iMode >= 1 && GetArraySize(g_hSmokes) > 0)
	{
		decl Float:eyeClient[3], Float:eyeEntity[3], Float:smoke[3];
		GetClientEyePosition(client, eyeClient);
		GetClientEyePosition(entity, eyeEntity);
		for (new idx = 0; idx < GetArraySize(g_hSmokes); idx++)
		{
			GetArrayArray(g_hSmokes, idx, smoke);
			if (IsLineBlockedBySmoke(smoke, eyeClient, eyeEntity))
				return Plugin_Handled;
		}
	}

	return Plugin_Continue;
}

bool:IsLineBlockedBySmoke(const Float:smokeOrigin[3], const Float:from[3], const Float:to[3])
{
	decl Float:sightDir[3], Float:toGrenade[3], Float:close[3], Float:toClose[3], Float:trash[3];
	new Float:totalSmokedLength = 0.0;

	SubtractVectors(to, from, sightDir);
	new Float:sightLength = NormalizeVector(sightDir, sightDir);
	SubtractVectors(smokeOrigin, from, toGrenade);

	new Float:alongDist = GetVectorDotProduct(toGrenade, sightDir);
	if (alongDist < 0.0)
	{
		close[0] = from[0]; close[1] = from[1]; close[2] = from[2];
	}
	else if (alongDist >= sightLength)
	{
		close[0] = to[0]; close[1] = to[1]; close[2] = to[2];
	}
	else
	{
		close[0] = sightDir[0]; close[1] = sightDir[1]; close[2] = sightDir[2];
		ScaleVector(close, alongDist);
		AddVectors(from, close, close);
	}

	SubtractVectors(close, smokeOrigin, toClose);
	new Float:lengthSq = GetVectorLength(toClose, true);
	if (lengthSq >= SMOKE_LOS_RADIUS_SQ)
		return false;

	new Float:fromSq = GetVectorLength(toGrenade, true);
	SubtractVectors(smokeOrigin, to, trash);
	new Float:toSq = GetVectorLength(trash, true);

	if (fromSq < SMOKE_LOS_RADIUS_SQ)
	{
		if (toSq < SMOKE_LOS_RADIUS_SQ)
		{
			SubtractVectors(to, from, trash);
			totalSmokedLength += GetVectorLength(trash);
		}
		else
		{
			new Float:halfSmokedLength = SquareRoot(SMOKE_LOS_RADIUS_SQ - lengthSq);
			SubtractVectors(close, from, trash);
			if (alongDist > 0.0)
				totalSmokedLength += halfSmokedLength + GetVectorLength(trash);
			else
				totalSmokedLength += halfSmokedLength - GetVectorLength(trash);
		}
	}
	else if (toSq < SMOKE_LOS_RADIUS_SQ)
	{
		new Float:halfSmokedLength = SquareRoot(SMOKE_LOS_RADIUS_SQ - lengthSq);
		decl Float:v[3];
		SubtractVectors(to, smokeOrigin, v);
		SubtractVectors(close, to, trash);
		if (GetVectorDotProduct(v, sightDir) > 0.0)
			totalSmokedLength += halfSmokedLength + GetVectorLength(trash);
		else
			totalSmokedLength += halfSmokedLength - GetVectorLength(trash);
	}
	else
	{
		totalSmokedLength += 2.0 * SquareRoot(SMOKE_LOS_RADIUS_SQ - lengthSq);
	}

	return (totalSmokedLength > 0.0);
}

HookClient(client)
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || g_bHooked[client])
		return;
	SDKHook(client, SDKHook_SetTransmit, Hook_SetTransmit);
	g_bHooked[client] = true;
}

AntiSmoke_HookAll()
{
	if (g_iMode != 1 && g_hSmokeLoop == INVALID_HANDLE)
		g_hSmokeLoop = CreateTimer(0.1, Timer_SmokeCheck, _, TIMER_REPEAT);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			HookClient(i);
	}
}

AntiSmoke_UnhookAll()
{
	if (g_hSmokeLoop != INVALID_HANDLE)
	{
		KillTimer(g_hSmokeLoop);
		g_hSmokeLoop = INVALID_HANDLE;
	}

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && g_bHooked[i])
		{
			SDKUnhook(i, SDKHook_SetTransmit, Hook_SetTransmit);
			g_bHooked[i] = false;
		}
		g_bIsInSmoke[i] = false;
	}

	ClearArray(g_hSmokes);
}
