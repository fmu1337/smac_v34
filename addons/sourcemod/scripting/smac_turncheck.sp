#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

/*
 * SMAC: Turn Check
 *
 * Original module by Danyas for SMAC v34.
 * Ideas rewritten from HOTGUARD (mouse↔angle desync, identical yaw steps),
 * Bash/Oryx (IN_LEFT+IN_RIGHT wiggle, angle-delay after key press), and
 * Cow Private (pitch/yaw anti-aim snaps). Not a 1:1 port of private dumps.
 */

public Plugin:myinfo =
{
	name = "SMAC: Turn Check",
	author = SMAC_AUTHOR,
	description = "Detects mouse/angle desync, wiggle, anti-aim snaps, angle delay",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define MOUSE_AIM_STREAK		64
#define ANGLE_DESYNC_STREAK		48
#define WIGGLE_STREAK			8
#define AA_SNAP_STREAK			12
#define ANGLE_DELAY_TICKS		3
#define ANGLE_DELAY_STREAK		10

new Handle:g_hCvarMouseBan = INVALID_HANDLE;
new Handle:g_hCvarDesyncBan = INVALID_HANDLE;
new Handle:g_hCvarWiggleBan = INVALID_HANDLE;
new Handle:g_hCvarAntiAimBan = INVALID_HANDLE;
new Handle:g_hCvarDelayBan = INVALID_HANDLE;
new Handle:g_hCvarBlockWiggle = INVALID_HANDLE;

new Float:g_fPrevAng[MAXPLAYERS+1][3];
new bool:g_bHaveAng[MAXPLAYERS+1];
new g_iMouseAim[MAXPLAYERS+1];
new g_iMouseDetects[MAXPLAYERS+1];

new Float:g_fPrevYawDelta[MAXPLAYERS+1];
new g_iDesyncStreak[MAXPLAYERS+1];
new g_iDesyncDetects[MAXPLAYERS+1];

new g_iWiggleStreak[MAXPLAYERS+1];
new g_iWiggleDetects[MAXPLAYERS+1];

new g_iAASnap[MAXPLAYERS+1];
new g_iAADetects[MAXPLAYERS+1];
new Float:g_fPrevPitch[MAXPLAYERS+1];

new g_iPrevButtons[MAXPLAYERS+1];
new g_iDelayFreeze[MAXPLAYERS+1];
new g_iDelayStreak[MAXPLAYERS+1];
new g_iDelayDetects[MAXPLAYERS+1];
new Float:g_fIgnoreUntil[MAXPLAYERS+1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarMouseBan = SMAC_CreateConVar("smac_turn_mouse_ban", "0", "Mouse-aim detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarDesyncBan = SMAC_CreateConVar("smac_turn_desync_ban", "0", "Identical yaw-delta detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarWiggleBan = SMAC_CreateConVar("smac_turn_wiggle_ban", "0", "Wiggle (+left+right) detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarAntiAimBan = SMAC_CreateConVar("smac_turn_antiaim_ban", "0", "Anti-aim snap detections before ban. (0 = Never)", _, true, 0.0);
	g_hCvarDelayBan = SMAC_CreateConVar("smac_turn_delay_ban", "0", "Angle-delay detections before ban. (0 = Never; default off — lag FP)", _, true, 0.0);
	g_hCvarBlockWiggle = SMAC_CreateConVar("smac_turn_block_wiggle", "1", "Strip IN_LEFT|IN_RIGHT when both pressed in air.", _, true, 0.0, true, 1.0);

	HookEvent("player_spawn", Event_Spawn, EventHookMode_Post);
	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);
}

public OnClientPutInServer(client)
{
	ResetClient(client);
}

public OnClientDisconnect(client)
{
	ResetClient(client);
}

public Event_Spawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (IS_CLIENT(client))
	{
		g_bHaveAng[client] = false;
		g_fIgnoreUntil[client] = GetGameTime() + 1.5;
	}
}

public Teleport_OnEndTouch(const String:output[], caller, activator, Float:delay)
{
	if (IS_CLIENT(activator) && IsClientConnected(activator))
	{
		g_bHaveAng[activator] = false;
		g_fIgnoreUntil[activator] = GetGameTime() + 0.5 + delay;
	}
}

ResetClient(client)
{
	g_bHaveAng[client] = false;
	g_iMouseAim[client] = 0;
	g_iMouseDetects[client] = 0;
	g_fPrevYawDelta[client] = 0.0;
	g_iDesyncStreak[client] = 0;
	g_iDesyncDetects[client] = 0;
	g_iWiggleStreak[client] = 0;
	g_iWiggleDetects[client] = 0;
	g_iAASnap[client] = 0;
	g_iAADetects[client] = 0;
	g_fPrevPitch[client] = 0.0;
	g_iPrevButtons[client] = 0;
	g_iDelayFreeze[client] = 0;
	g_iDelayStreak[client] = 0;
	g_iDelayDetects[client] = 0;
	g_fIgnoreUntil[client] = 0.0;
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	if (!IS_CLIENT(client) || !IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		return Plugin_Continue;

	new bool:changed = false;
	new MoveType:mt = GetEntityMoveType(client);
	if (mt != MOVETYPE_WALK && mt != MOVETYPE_ISOMETRIC && mt != MOVETYPE_LADDER)
	{
		g_iPrevButtons[client] = buttons;
		StoreAngles(client, angles);
		return Plugin_Continue;
	}

	if (GetGameTime() < g_fIgnoreUntil[client])
	{
		g_iPrevButtons[client] = buttons;
		StoreAngles(client, angles);
		return Plugin_Continue;
	}

	new bool:usingArrowTurn = ((buttons & IN_LEFT) || (buttons & IN_RIGHT));

	/* HOTGUARD: angles move while mouse deltas are zero. */
	if (g_bHaveAng[client] && !usingArrowTurn)
	{
		new Float:delta = AngleDelta2D(angles, g_fPrevAng[client]);
		if (mouse[0] == 0 && mouse[1] == 0 && delta > 0.05)
		{
			g_iMouseAim[client]++;
			if (g_iMouseAim[client] >= MOUSE_AIM_STREAK)
			{
				g_iMouseAim[client] = 0;
				FireDetect(client, Detection_MouseAim, g_iMouseDetects[client], g_hCvarMouseBan, "SMAC_MouseAimDetected", "mouse-aim desync");
				g_iMouseDetects[client]++;
			}
		}
		else
		{
			g_iMouseAim[client] = 0;
		}
	}

	/* HOTGUARD: repeated identical yaw steps (desync / silent aim family). */
	if (g_bHaveAng[client] && !usingArrowTurn)
	{
		new Float:yawDelta = NormalizeYaw(angles[1] - g_fPrevAng[client][1]);
		if (yawDelta != 0.0 && yawDelta == g_fPrevYawDelta[client] && FloatAbs(yawDelta) >= 0.01)
		{
			g_iDesyncStreak[client]++;
			if (g_iDesyncStreak[client] >= ANGLE_DESYNC_STREAK)
			{
				g_iDesyncStreak[client] = 0;
				FireDetect(client, Detection_AngleDesync, g_iDesyncDetects[client], g_hCvarDesyncBan, "SMAC_AngleDesyncDetected", "identical yaw-delta desync");
				g_iDesyncDetects[client]++;
			}
		}
		else
		{
			g_iDesyncStreak[client] = 0;
		}
		g_fPrevYawDelta[client] = yawDelta;
	}

	/* Bash/Oryx: both +left and +right while airborne. */
	new bool:inAir = !(GetEntityFlags(client) & FL_ONGROUND);
	if (inAir && (buttons & IN_LEFT) && (buttons & IN_RIGHT))
	{
		g_iWiggleStreak[client]++;
		if (GetConVarBool(g_hCvarBlockWiggle))
		{
			buttons &= ~(IN_LEFT | IN_RIGHT);
			changed = true;
		}
		if (g_iWiggleStreak[client] >= WIGGLE_STREAK)
		{
			g_iWiggleStreak[client] = 0;
			FireDetect(client, Detection_WiggleHack, g_iWiggleDetects[client], g_hCvarWiggleBan, "SMAC_WiggleDetected", "wiggle +left+right");
			g_iWiggleDetects[client]++;
		}
	}
	else
	{
		g_iWiggleStreak[client] = 0;
	}

	/* Cow Private: pitch snap off ±89 / exact 90°|180° yaw snaps while attacking. */
	if (g_bHaveAng[client] && (buttons & IN_ATTACK))
	{
		new Float:pitch = angles[0];
		new Float:pitchDelta = FloatAbs(pitch - g_fPrevPitch[client]);
		new Float:yawSnap = FloatAbs(NormalizeYaw(angles[1] - g_fPrevAng[client][1]));
		new bool:snap = false;

		if ((FloatAbs(g_fPrevPitch[client]) >= 88.5) && pitchDelta >= 20.0)
			snap = true;
		if (FloatAbs(yawSnap - 90.0) < 0.05 || FloatAbs(yawSnap - 180.0) < 0.05)
			snap = true;

		if (snap)
		{
			g_iAASnap[client]++;
			if (g_iAASnap[client] >= AA_SNAP_STREAK)
			{
				g_iAASnap[client] = 0;
				FireDetect(client, Detection_AntiAimAngles, g_iAADetects[client], g_hCvarAntiAimBan, "SMAC_AntiAimAnglesDetected", "anti-aim angle snaps");
				g_iAADetects[client]++;
			}
		}
	}
	else if (!(buttons & IN_ATTACK))
	{
		/* decay slowly while not attacking */
		if (g_iAASnap[client] > 0)
			g_iAASnap[client]--;
	}

	/* Bash: after A/D press, yaw frozen for several air ticks. */
	if (inAir)
	{
		new bool:pressedStrafe =
			((buttons & IN_MOVELEFT) && !(g_iPrevButtons[client] & IN_MOVELEFT))
			|| ((buttons & IN_MOVERIGHT) && !(g_iPrevButtons[client] & IN_MOVERIGHT));

		if (pressedStrafe)
			g_iDelayFreeze[client] = ANGLE_DELAY_TICKS;

		if (g_iDelayFreeze[client] > 0 && g_bHaveAng[client])
		{
			new Float:yd = FloatAbs(NormalizeYaw(angles[1] - g_fPrevAng[client][1]));
			if (yd < 0.01)
			{
				g_iDelayStreak[client]++;
				if (g_iDelayStreak[client] >= ANGLE_DELAY_STREAK)
				{
					g_iDelayStreak[client] = 0;
					FireDetect(client, Detection_AngleDelay, g_iDelayDetects[client], g_hCvarDelayBan, "SMAC_AngleDelayDetected", "angle delay after strafe key");
					g_iDelayDetects[client]++;
				}
			}
			else
			{
				g_iDelayStreak[client] = 0;
			}
			g_iDelayFreeze[client]--;
		}
	}
	else
	{
		g_iDelayFreeze[client] = 0;
		g_iDelayStreak[client] = 0;
	}

	g_iPrevButtons[client] = buttons;
	g_fPrevPitch[client] = angles[0];
	StoreAngles(client, angles);
	return changed ? Plugin_Changed : Plugin_Continue;
}

StoreAngles(client, const Float:angles[3])
{
	g_fPrevAng[client][0] = angles[0];
	g_fPrevAng[client][1] = angles[1];
	g_fPrevAng[client][2] = angles[2];
	g_bHaveAng[client] = true;
}

Float:AngleDelta2D(const Float:a[3], const Float:b[3])
{
	decl Float:p1[3], Float:p2[3];
	p1[0] = a[0]; p1[1] = a[1]; p1[2] = 0.0;
	p2[0] = b[0]; p2[1] = b[1]; p2[2] = 0.0;
	new Float:delta = GetVectorDistance(p1, p2);
	while (delta > 180.0)
		delta = FloatAbs(delta - 360.0);
	return delta;
}

Float:NormalizeYaw(Float:yaw)
{
	while (yaw > 180.0) yaw -= 360.0;
	while (yaw < -180.0) yaw += 360.0;
	return yaw;
}

FireDetect(client, DetectionType:type, detectsSoFar, Handle:hBanCvar, const String:phrase[], const String:logName[])
{
	new detection = detectsSoFar + 1;
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
