/**
 * Dev plugin: records the engine's own visibility traces next to the smac_wallhack occluder decision, for offline
 * checks (tools/occtest/check_dataset.py). Not part of SMAC; don't run it on a live server.
 *
 * Every smac_occ_dataset_interval seconds it picks smac_occ_dataset_pairs random (viewer, target) pairs of alive
 * players, bots included, and for each pair writes one CSV line to addons/sourcemod/data/occ_dataset_<map>.csv:
 * the eye, both peek eyes, the 10 target points smac_wallhack traces to, which of those traces the engine lets
 * through, and which brush (if any) the occluder code would use to call the target hidden.
 *
 * The occluder is evaluated independently of the engine result, so the file shows both kinds of disagreement:
 * "proven hidden but the engine sees" (must never happen) and "the engine says hidden but no brush proves it" (the
 * traces handle those; this is the share the occluders don't save).
 */

#include <sourcemod>
#include <sdktools>
#include <smac_wallhack_occ>

#define DS_SAMPLES		10
#define DS_EYES			3
#define DS_CANDIDATES	8

public Plugin:myinfo =
{
	name = "SMAC occluder dataset",
	author = "SMAC",
	description = "Engine traces vs BSP occluders, for offline checks",
	version = "1.0",
	url = "https://github.com/fmu1337/smac_v34"
};

new Handle:g_hCvarInterval = INVALID_HANDLE;
new Handle:g_hCvarPairs = INVALID_HANDLE;
new Handle:g_hCvarPeek = INVALID_HANDLE;
new Handle:g_hCvarSameTeam = INVALID_HANDLE;

new Handle:g_hFile = INVALID_HANDLE;
new Handle:g_hTimer = INVALID_HANDLE;
new String:g_sMap[PLATFORM_MAX_PATH];
new String:g_sLoadError[128];

new g_iRecords, g_iHidden, g_iProven, g_iDisagree;
new Float:g_fTraceTime, Float:g_fOccTime;

public OnPluginStart()
{
	g_hCvarInterval = CreateConVar("smac_occ_dataset_interval", "0.25", "Seconds between samples.", _, true, 0.05);
	g_hCvarPairs = CreateConVar("smac_occ_dataset_pairs", "16", "Random viewer/target pairs per sample.", _, true, 1.0, true, 256.0);
	g_hCvarPeek = CreateConVar("smac_occ_dataset_peek", "11.0", "Peek side-step in units (smac_wallhack: ~11 at 0.1 s with default CS:S cvars). 0 = real eye only.", _, true, 0.0, true, 64.0);
	g_hCvarSameTeam = CreateConVar("smac_occ_dataset_sameteam", "1", "Also sample pairs from the same team (more pairs; visibility doesn't care about teams).", _, true, 0.0, true, 1.0);
	
	RegAdminCmd("smac_occ_dataset_start", Command_Start, ADMFLAG_ROOT, "Start writing the dataset for this map.");
	RegAdminCmd("smac_occ_dataset_stop", Command_Stop, ADMFLAG_ROOT, "Stop and close the file.");
	RegAdminCmd("smac_occ_dataset_status", Command_Status, ADMFLAG_ROOT, "Records so far and live counters.");
}

public OnMapStart()
{
	GetCurrentMap(g_sMap, sizeof(g_sMap));
	g_iRecords = g_iHidden = g_iProven = g_iDisagree = 0;
	g_fTraceTime = g_fOccTime = 0.0;
	
	if (Occ_Load(g_sMap, g_sLoadError, sizeof(g_sLoadError)))
	{
		LogMessage("Occluders for %s: %d of %d brushes (%d without a full box, %d wedges).", g_sMap, g_iOccKept, g_iOccNumBrushes, g_iOccRejected, g_iOccOdd);
		g_sLoadError[0] = '\0';
	}
	else
	{
		LogMessage("No occluders for %s: %s", g_sMap, g_sLoadError);
	}
}

public OnMapEnd()
{
	Dataset_Stop();
}

public Action:Command_Start(client, args)
{
	if (g_hTimer != INVALID_HANDLE)
	{
		ReplyToCommand(client, "[occ] Already running.");
		return Plugin_Handled;
	}
	
	decl String:sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "data/occ_dataset_%s.csv", g_sMap);
	
	new bool:bNew = !FileExists(sPath);
	g_hFile = OpenFile(sPath, "a");
	
	if (g_hFile == INVALID_HANDLE)
	{
		ReplyToCommand(client, "[occ] Can't open %s.", sPath);
		return Plugin_Handled;
	}
	
	if (bNew)
	{
		WriteFileLine(g_hFile, "map,tick,viewer_bot,target_bot,eye,peek_dist,peek_a,peek_a_ok,peek_b,peek_b_ok,samples,vis_eye,vis_peek_a,vis_peek_b,centre_frac,centre_ent,candidates,proof_brush,occ_loaded,trace_us,occ_us");
	}
	
	g_hTimer = CreateTimer(GetConVarFloat(g_hCvarInterval), Timer_Sample, _, TIMER_REPEAT);
	ReplyToCommand(client, "[occ] Writing %s (occluders: %s).", sPath, g_sLoadError[0] ? g_sLoadError : "loaded");
	return Plugin_Handled;
}

public Action:Command_Stop(client, args)
{
	Dataset_Stop();
	ReplyToCommand(client, "[occ] Stopped, %d records on %s.", g_iRecords, g_sMap);
	return Plugin_Handled;
}

public Action:Command_Status(client, args)
{
	ReplyToCommand(client, "[occ] %s: %s, %d records; engine-hidden %d, proven by a brush %d, PROVEN BUT ENGINE SEES %d.", g_sMap, g_hTimer != INVALID_HANDLE ? "running" : "stopped", g_iRecords, g_iHidden, g_iProven, g_iDisagree);
	
	if (g_iRecords)
	{
		ReplyToCommand(client, "[occ] Per record: %.1f us of engine traces (all %d segments), %.1f us of occluder search + proofs.", g_fTraceTime * 1000000.0 / float(g_iRecords), DS_EYES * DS_SAMPLES, g_fOccTime * 1000000.0 / float(g_iRecords));
	}
	
	return Plugin_Handled;
}

Dataset_Stop()
{
	if (g_hTimer != INVALID_HANDLE)
	{
		KillTimer(g_hTimer);
		g_hTimer = INVALID_HANDLE;
	}
	
	if (g_hFile != INVALID_HANDLE)
	{
		CloseHandle(g_hFile);
		g_hFile = INVALID_HANDLE;
	}
}

public Action:Timer_Sample(Handle:timer)
{
	decl iAlive[MAXPLAYERS + 1];
	new iCount;
	
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsPlayerAlive(i))
		{
			iAlive[iCount++] = i;
		}
	}
	
	if (iCount < 2)
		return Plugin_Continue;
	
	new bool:bSameTeam = GetConVarBool(g_hCvarSameTeam);
	new iPairs = GetConVarInt(g_hCvarPairs);
	
	for (new i = 0, iTries = 0; i < iPairs && iTries < iPairs * 4; iTries++)
	{
		new iViewer = iAlive[GetRandomInt(0, iCount - 1)];
		new iTarget = iAlive[GetRandomInt(0, iCount - 1)];
		
		if (iViewer == iTarget || (!bSameTeam && GetClientTeam(iViewer) == GetClientTeam(iTarget)))
			continue;
		
		Dataset_Record(iViewer, iTarget);
		i++;
	}
	
	if (g_hFile != INVALID_HANDLE)
	{
		FlushFile(g_hFile);
	}
	
	return Plugin_Continue;
}

// Same filter as smac_wallhack: players and what they hold don't block.
public bool:Filter_NoPlayers(entity, mask)
{
	if (entity <= MaxClients)
		return false;
	
	new iOwner = GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity");
	return !(iOwner >= 1 && iOwner <= MaxClients);
}

Dataset_Record(viewer, target)
{
	decl Float:vEyes[DS_EYES][3], bool:bEyes[DS_EYES], Float:vSamples[DS_SAMPLES][3];
	decl Float:vOrigin[3], Float:vTargetEye[3], Float:vMins[3], Float:vMaxs[3], Float:vCentre[3];
	
	GetClientEyePosition(viewer, vEyes[0]);
	bEyes[0] = true;
	
	GetClientAbsOrigin(target, vOrigin);
	GetClientEyePosition(target, vTargetEye);
	GetClientMins(target, vMins);
	GetClientMaxs(target, vMaxs);
	
	// Target points as smac_wallhack builds them for a target at about the same level: centre at half the view
	// offset / 2.2 above the feet, outer and inner rectangles (x1.30 / x0.65) facing the viewer, and the head.
	new Float:fHalf = (vTargetEye[2] - vOrigin[2]) / 2.2;
	new Float:fWide = ((vMaxs[0] - vMins[0]) + (vMaxs[1] - vMins[1])) / 7.0;
	
	vCentre = vOrigin;
	vCentre[2] += fHalf;
	
	decl Float:vRight[3];
	vRight[0] = vEyes[0][1] - vCentre[1];
	vRight[1] = vCentre[0] - vEyes[0][0];
	vRight[2] = 0.0;
	
	if (NormalizeVector(vRight, vRight) == 0.0)
	{
		vRight[0] = 1.0;
		vRight[1] = 0.0;
	}
	
	vSamples[0] = vCentre;
	vSamples[5] = vTargetEye;
	Dataset_Rect(vCentre, vRight, fWide * 1.30, fHalf * 1.30, vSamples, 1);
	Dataset_Rect(vCentre, vRight, fWide * 0.65, fHalf * 0.65, vSamples, 6);
	
	// Peek eyes: side-stepped along vRight, stopped by walls like in smac_wallhack.
	new Float:fPeek = GetConVarFloat(g_hCvarPeek);
	bEyes[1] = false;
	bEyes[2] = false;
	
	if (fPeek >= 1.0 && !(TR_GetPointContents(vEyes[0]) & MASK_PLAYERSOLID))
	{
		for (new e = 1; e <= 2; e++)
		{
			decl Float:vEnd[3];
			
			for (new k = 0; k < 3; k++)
			{
				vEnd[k] = vEyes[0][k] + vRight[k] * fPeek * ((e == 1) ? 1.0 : -1.0);
			}
			
			TR_TraceHullFilter(vEyes[0], vEnd, Float:{-4.0, -4.0, -4.0}, Float:{4.0, 4.0, 4.0}, MASK_PLAYERSOLID, Filter_NoPlayers);
			TR_GetEndPosition(vEyes[e]);
			bEyes[e] = GetVectorDistance(vEyes[0], vEyes[e], true) >= 1.0;
		}
	}
	
	// Engine: every eye to every sample, exactly the trace smac_wallhack uses.
	new iVisible[DS_EYES];
	new Float:fStart = GetEngineTime();
	
	for (new e = 0; e < DS_EYES; e++)
	{
		if (!bEyes[e])
			continue;
		
		for (new i = 0; i < DS_SAMPLES; i++)
		{
			TR_TraceRayFilter(vEyes[e], vSamples[i], MASK_VISIBLE, RayType_EndPoint, Filter_NoPlayers);
			
			if (TR_GetFraction() == 1.0)
			{
				iVisible[e] |= (1 << i);
			}
		}
	}
	
	TR_TraceRayFilter(vEyes[0], vSamples[0], MASK_VISIBLE, RayType_EndPoint, Filter_NoPlayers);
	new Float:fCentreFrac = TR_GetFraction();
	new iCentreEnt = (fCentreFrac < 1.0) ? TR_GetEntityIndex() : -1;
	
	new Float:fTraceTime = GetEngineTime() - fStart;
	g_fTraceTime += fTraceTime;
	
	// Occluder, the plugin's way: brushes along the centre line, first one that blocks everything.
	decl iCandidates[DS_CANDIDATES];
	new iCandidateCount, iProof = -1;
	fStart = GetEngineTime();
	
	if (g_bOccLoaded)
	{
		iCandidateCount = Occ_RayCandidates(vEyes[0], vSamples[0], iCandidates, sizeof(iCandidates));
		
		for (new i = 0; i < iCandidateCount; i++)
		{
			if (Occ_Proves(iCandidates[i], vEyes, bEyes, vSamples, DS_SAMPLES))
			{
				iProof = iCandidates[i];
				break;
			}
		}
	}
	
	new Float:fOccTime = GetEngineTime() - fStart;
	g_fOccTime += fOccTime;
	
	new bool:bHidden = !iVisible[0] && !iVisible[1] && !iVisible[2];
	g_iRecords++;
	
	if (bHidden)
	{
		g_iHidden++;
	}
	
	if (iProof >= 0)
	{
		g_iProven++;
		
		if (!bHidden)
		{
			g_iDisagree++;
			
			if (g_iDisagree <= 20)
			{
				LogMessage("PROVEN BUT ENGINE SEES on %s: brush #%d, %N eye %.1f %.1f %.1f, %N centre %.1f %.1f %.1f, visible masks %d/%d/%d.", g_sMap, iProof, viewer, vEyes[0][0], vEyes[0][1], vEyes[0][2], target, vCentre[0], vCentre[1], vCentre[2], iVisible[0], iVisible[1], iVisible[2]);
			}
		}
	}
	
	if (g_hFile == INVALID_HANDLE)
		return;
	
	// One CSV line; vectors as "x y z", lists separated by ';'.
	decl String:sLine[4096], String:sPart[256];
	
	Format(sLine, sizeof(sLine), "%s,%d,%d,%d,", g_sMap, GetGameTickCount(), IsFakeClient(viewer), IsFakeClient(target));
	Dataset_AppendVec(sLine, sizeof(sLine), vEyes[0], ",");
	Format(sPart, sizeof(sPart), "%.2f,", fPeek);
	StrCat(sLine, sizeof(sLine), sPart);
	
	for (new e = 1; e <= 2; e++)
	{
		Dataset_AppendVec(sLine, sizeof(sLine), vEyes[e], ",");
		StrCat(sLine, sizeof(sLine), bEyes[e] ? "1," : "0,");
	}
	
	for (new i = 0; i < DS_SAMPLES; i++)
	{
		Dataset_AppendVec(sLine, sizeof(sLine), vSamples[i], (i < DS_SAMPLES - 1) ? ";" : ",");
	}
	
	Format(sPart, sizeof(sPart), "%d,%d,%d,%.5f,%d,", iVisible[0], iVisible[1], iVisible[2], fCentreFrac, iCentreEnt);
	StrCat(sLine, sizeof(sLine), sPart);
	
	for (new i = 0; i < iCandidateCount; i++)
	{
		Format(sPart, sizeof(sPart), (i < iCandidateCount - 1) ? "%d;" : "%d", iCandidates[i]);
		StrCat(sLine, sizeof(sLine), sPart);
	}
	
	Format(sPart, sizeof(sPart), ",%d,%d,%.1f,%.1f", iProof, g_bOccLoaded, fTraceTime * 1000000.0, fOccTime * 1000000.0);
	StrCat(sLine, sizeof(sLine), sPart);
	
	WriteFileLine(g_hFile, "%s", sLine);
}

Dataset_Rect(const Float:vCentre[3], const Float:vRight[3], Float:fWide, Float:fHalf, Float:vSamples[][3], first)
{
	for (new j = 0; j < 4; j++)
	{
		new Float:fSide = (j & 1) ? -fWide : fWide;
		new Float:fUp = (j & 2) ? -fHalf : fHalf;
		
		vSamples[first + j][0] = vCentre[0] + vRight[0] * fSide;
		vSamples[first + j][1] = vCentre[1] + vRight[1] * fSide;
		vSamples[first + j][2] = vCentre[2] + fUp;
	}
}

Dataset_AppendVec(String:sLine[], maxlen, const Float:v[3], const String:sep[])
{
	decl String:sPart[64];
	Format(sPart, sizeof(sPart), "%.4f %.4f %.4f%s", v[0], v[1], v[2], sep);
	StrCat(sLine, maxlen, sPart);
}

