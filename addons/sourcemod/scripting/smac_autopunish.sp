#pragma semicolon 1
#include <sourcemod>
#include <smac>

/*
 * Autopunish when no admins are online.
 *
 * Listens to SMAC_OnCheatDetected. Per DetectionType action:
 *   0 = off (do nothing, detectors keep their own reaction)
 *   1 = kick when no admins online
 *   2 = ban when no admins online
 *
 * When at least one admin with smac_admin_notices / ADMFLAG_GENERIC is in-game,
 * this module only prints an admin notice and returns Plugin_Continue so detectors
 * keep their configured behaviour (usually notice-only for ultra modules).
 *
 * When no such admin is present and the type is set to kick/ban, this module
 * punishes and returns Plugin_Handled to avoid a double kick/ban from stock
 * modules that still auto-punish by default.
 *
 * All per-type defaults are 0 (off). Enable the types you want to auto-punish.
 */

public Plugin:myinfo =
{
	name = "SMAC: Autopunish",
	author = SMAC_AUTHOR,
	description = "Kick/ban cheaters when no admins are online; notify when admins are present",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define ACTION_OFF		0
#define ACTION_KICK		1
#define ACTION_BAN		2

new Handle:g_hCvarEnable = INVALID_HANDLE;
new Handle:g_hCvarImmune = INVALID_HANDLE;

new Handle:g_hCvarAimbot = INVALID_HANDLE;
new Handle:g_hCvarAutoTrigger = INVALID_HANDLE;
new Handle:g_hCvarNameSpam = INVALID_HANDLE;
new Handle:g_hCvarCmdSpam = INVALID_HANDLE;
new Handle:g_hCvarBannedCmd = INVALID_HANDLE;
new Handle:g_hCvarCvarViolation = INVALID_HANDLE;
new Handle:g_hCvarUserCmdReuse = INVALID_HANDLE;
new Handle:g_hCvarUserCmdTickcount = INVALID_HANDLE;
new Handle:g_hCvarUserCmdButtons = INVALID_HANDLE;
new Handle:g_hCvarEyeangles = INVALID_HANDLE;
new Handle:g_hCvarSeedSkip = INVALID_HANDLE;
new Handle:g_hCvarSpeedhack = INVALID_HANDLE;
new Handle:g_hCvarSpinhack = INVALID_HANDLE;
new Handle:g_hCvarAirStuck = INVALID_HANDLE;
new Handle:g_hCvarLagExploit = INVALID_HANDLE;
new Handle:g_hCvarBacktrack = INVALID_HANDLE;
new Handle:g_hCvarUltraPSilent = INVALID_HANDLE;
new Handle:g_hCvarUltraAim = INVALID_HANDLE;
new Handle:g_hCvarUltraMovement = INVALID_HANDLE;
new Handle:g_hCvarUltraInput = INVALID_HANDLE;
new Handle:g_hCvarUltraClient = INVALID_HANDLE;
new Handle:g_hCvarUltraServer = INVALID_HANDLE;
new Handle:g_hCvarUltraFakeStatus = INVALID_HANDLE;
new Handle:g_hCvarLerp = INVALID_HANDLE;
new Handle:g_hCvarStrafe = INVALID_HANDLE;
new Handle:g_hCvarCvarTrap = INVALID_HANDLE;
new Handle:g_hCvarUsercmd = INVALID_HANDLE;

public OnPluginStart()
{
	LoadTranslations("smac.phrases");

	g_hCvarEnable = SMAC_CreateConVar("smac_autopunish", "1", "Autopunish when no admins are online: 0=off, 1=on", _, true, 0.0, true, 1.0);
	g_hCvarImmune = SMAC_CreateConVar("smac_autopunish_immune", "1", "Never kick/ban suspects with ban/root flag (notices still fire when admins are online).", _, true, 0.0, true, 1.0);

	/* Per DetectionType: 0=off, 1=kick, 2=ban when no admins online. Defaults off. */
	g_hCvarAimbot = SMAC_CreateConVar("smac_autopunish_aimbot", "0", "Detection_Aimbot: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarAutoTrigger = SMAC_CreateConVar("smac_autopunish_autotrigger", "0", "Detection_AutoTrigger: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarNameSpam = SMAC_CreateConVar("smac_autopunish_name_spam", "0", "Detection_NameChangeSpam: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarCmdSpam = SMAC_CreateConVar("smac_autopunish_cmd_spam", "0", "Detection_CommandSpamming: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarBannedCmd = SMAC_CreateConVar("smac_autopunish_banned_cmd", "0", "Detection_BannedCommand: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarCvarViolation = SMAC_CreateConVar("smac_autopunish_cvar", "0", "Detection_CvarViolation: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarUserCmdReuse = SMAC_CreateConVar("smac_autopunish_usercmd_reuse", "0", "Detection_UserCmdReuse: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarUserCmdTickcount = SMAC_CreateConVar("smac_autopunish_usercmd_tickcount", "0", "Detection_UserCmdTamperingTickcount: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarUserCmdButtons = SMAC_CreateConVar("smac_autopunish_usercmd_buttons", "0", "Detection_UserCmdTamperingButtons: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarEyeangles = SMAC_CreateConVar("smac_autopunish_eyeangles", "0", "Detection_Eyeangles: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarSeedSkip = SMAC_CreateConVar("smac_autopunish_seedskip", "0", "Detection_SeedSkip: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarSpeedhack = SMAC_CreateConVar("smac_autopunish_speedhack", "0", "Detection_Speedhack: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarSpinhack = SMAC_CreateConVar("smac_autopunish_spinhack", "0", "Detection_Spinhack: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarAirStuck = SMAC_CreateConVar("smac_autopunish_airstuck", "0", "Detection_AirStuck: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarLagExploit = SMAC_CreateConVar("smac_autopunish_lag_exploit", "0", "Detection_LagExploit: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarBacktrack = SMAC_CreateConVar("smac_autopunish_backtrack", "0", "Detection_Backtrack: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarUltraPSilent = SMAC_CreateConVar("smac_autopunish_psilent", "0", "Detection_UltraPSilent: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarUltraAim = SMAC_CreateConVar("smac_autopunish_ultra_aim", "0", "Detection_UltraAim: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarUltraMovement = SMAC_CreateConVar("smac_autopunish_ultra_movement", "0", "Detection_UltraMovement: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarUltraInput = SMAC_CreateConVar("smac_autopunish_ultra_input", "0", "Detection_UltraInput: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarUltraClient = SMAC_CreateConVar("smac_autopunish_ultra_client", "0", "Detection_UltraClient: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarUltraServer = SMAC_CreateConVar("smac_autopunish_ultra_server", "0", "Detection_UltraServer: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarUltraFakeStatus = SMAC_CreateConVar("smac_autopunish_fake_status", "0", "Detection_UltraFakeStatus: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarLerp = SMAC_CreateConVar("smac_autopunish_lerp", "0", "Detection_Lerp: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarStrafe = SMAC_CreateConVar("smac_autopunish_strafe", "0", "Detection_Strafe: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarCvarTrap = SMAC_CreateConVar("smac_autopunish_cvar_trap", "0", "Detection_CvarTrap: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
	g_hCvarUsercmd = SMAC_CreateConVar("smac_autopunish_usercmd", "0", "Detection_Usercmd: 0=off, 1=kick, 2=ban (no admins)", _, true, 0.0, true, 2.0);
}

public Action:SMAC_OnCheatDetected(client, const String:module[], DetectionType:type, Handle:info)
{
	if (!GetConVarBool(g_hCvarEnable))
		return Plugin_Continue;

	if (!IS_CLIENT(client) || !IsClientConnected(client) || IsClientInKickQueue(client))
		return Plugin_Continue;

	new action = GetTypeAction(type);
	if (action == ACTION_OFF)
		return Plugin_Continue;

	decl String:sLabel[64], String:sCheck[64], String:sDetail[64];
	GetTypeLabel(type, sLabel, sizeof(sLabel));
	sCheck[0] = '\0';
	sDetail[0] = '\0';

	if (info != INVALID_HANDLE)
	{
		KvGetString(info, "check", sCheck, sizeof(sCheck), "");
		if (sCheck[0] == '\0')
			KvGetString(info, "method", sCheck, sizeof(sCheck), "");
		KvGetString(info, "detail", sDetail, sizeof(sDetail), "");
	}

	if (HasAdminOnline())
	{
		if (sCheck[0] != '\0' && sDetail[0] != '\0')
			SMAC_PrintAdminNotice("%t", "SMAC_AutopunishNoticeDetail", client, sLabel, sCheck, sDetail, module);
		else if (sCheck[0] != '\0')
			SMAC_PrintAdminNotice("%t", "SMAC_AutopunishNoticeCheck", client, sLabel, sCheck, module);
		else
			SMAC_PrintAdminNotice("%t", "SMAC_AutopunishNotice", client, sLabel, module);
		return Plugin_Continue;
	}

	if (IsSuspectImmune(client))
	{
		SMAC_LogAction(client, "was detected by %s [%s] but is admin-immune (autopunish skipped).", module, sLabel);
		return Plugin_Continue;
	}

	if (sCheck[0] != '\0')
		SMAC_LogAction(client, "was autopunished for %s (%s) from %s (no admins online).", sLabel, sCheck, module);
	else
		SMAC_LogAction(client, "was autopunished for %s from %s (no admins online).", sLabel, module);

	if (action == ACTION_BAN)
	{
		if (sCheck[0] != '\0')
			SMAC_Ban(client, "Autopunish (%s: %s)", sLabel, sCheck);
		else
			SMAC_Ban(client, "Autopunish (%s)", sLabel);
	}
	else
	{
		KickClient(client, "%t", "SMAC_AutopunishKick");
	}

	return Plugin_Handled;
}

bool:HasAdminOnline()
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i)
			&& CheckCommandAccess(i, "smac_admin_notices", ADMFLAG_GENERIC, true))
		{
			return true;
		}
	}
	return false;
}

bool:IsSuspectImmune(client)
{
	return GetConVarBool(g_hCvarImmune)
		&& (GetUserFlagBits(client) & (ADMFLAG_BAN | ADMFLAG_ROOT)) != 0;
}

GetTypeAction(DetectionType:type)
{
	new Handle:hCvar = INVALID_HANDLE;

	switch (type)
	{
		case Detection_Aimbot:						hCvar = g_hCvarAimbot;
		case Detection_AutoTrigger:					hCvar = g_hCvarAutoTrigger;
		case Detection_NameChangeSpam:				hCvar = g_hCvarNameSpam;
		case Detection_CommandSpamming:				hCvar = g_hCvarCmdSpam;
		case Detection_BannedCommand:				hCvar = g_hCvarBannedCmd;
		case Detection_CvarViolation:				hCvar = g_hCvarCvarViolation;
		case Detection_UserCmdReuse:				hCvar = g_hCvarUserCmdReuse;
		case Detection_UserCmdTamperingTickcount:	hCvar = g_hCvarUserCmdTickcount;
		case Detection_UserCmdTamperingButtons:		hCvar = g_hCvarUserCmdButtons;
		case Detection_Eyeangles:					hCvar = g_hCvarEyeangles;
		case Detection_SeedSkip:					hCvar = g_hCvarSeedSkip;
		case Detection_Speedhack:					hCvar = g_hCvarSpeedhack;
		case Detection_Spinhack:					hCvar = g_hCvarSpinhack;
		case Detection_AirStuck:					hCvar = g_hCvarAirStuck;
		case Detection_LagExploit:					hCvar = g_hCvarLagExploit;
		case Detection_Backtrack:					hCvar = g_hCvarBacktrack;
		case Detection_UltraPSilent:				hCvar = g_hCvarUltraPSilent;
		case Detection_UltraAim:					hCvar = g_hCvarUltraAim;
		case Detection_UltraMovement:				hCvar = g_hCvarUltraMovement;
		case Detection_UltraInput:					hCvar = g_hCvarUltraInput;
		case Detection_UltraClient:					hCvar = g_hCvarUltraClient;
		case Detection_UltraServer:					hCvar = g_hCvarUltraServer;
		case Detection_UltraFakeStatus:				hCvar = g_hCvarUltraFakeStatus;
		case Detection_Lerp:						hCvar = g_hCvarLerp;
		case Detection_Strafe:						hCvar = g_hCvarStrafe;
		case Detection_CvarTrap:					hCvar = g_hCvarCvarTrap;
		case Detection_Usercmd:						hCvar = g_hCvarUsercmd;
		default:									return ACTION_OFF;
	}

	if (hCvar == INVALID_HANDLE)
		return ACTION_OFF;

	return GetConVarInt(hCvar);
}

GetTypeLabel(DetectionType:type, String:buffer[], maxlength)
{
	switch (type)
	{
		case Detection_Aimbot:						strcopy(buffer, maxlength, "Aimbot");
		case Detection_AutoTrigger:					strcopy(buffer, maxlength, "AutoTrigger");
		case Detection_NameChangeSpam:				strcopy(buffer, maxlength, "NameChangeSpam");
		case Detection_CommandSpamming:				strcopy(buffer, maxlength, "CommandSpamming");
		case Detection_BannedCommand:				strcopy(buffer, maxlength, "BannedCommand");
		case Detection_CvarViolation:				strcopy(buffer, maxlength, "CvarViolation");
		case Detection_UserCmdReuse:				strcopy(buffer, maxlength, "UserCmdReuse");
		case Detection_UserCmdTamperingTickcount:	strcopy(buffer, maxlength, "UserCmdTickcount");
		case Detection_UserCmdTamperingButtons:		strcopy(buffer, maxlength, "UserCmdButtons");
		case Detection_Eyeangles:					strcopy(buffer, maxlength, "Eyeangles");
		case Detection_SeedSkip:					strcopy(buffer, maxlength, "SeedSkip");
		case Detection_Speedhack:					strcopy(buffer, maxlength, "Speedhack");
		case Detection_Spinhack:					strcopy(buffer, maxlength, "Spinhack");
		case Detection_AirStuck:					strcopy(buffer, maxlength, "AirStuck");
		case Detection_LagExploit:					strcopy(buffer, maxlength, "LagExploit");
		case Detection_Backtrack:					strcopy(buffer, maxlength, "Backtrack");
		case Detection_UltraPSilent:				strcopy(buffer, maxlength, "PSilent");
		case Detection_UltraAim:					strcopy(buffer, maxlength, "UltraAim");
		case Detection_UltraMovement:				strcopy(buffer, maxlength, "UltraMovement");
		case Detection_UltraInput:					strcopy(buffer, maxlength, "UltraInput");
		case Detection_UltraClient:					strcopy(buffer, maxlength, "UltraClient");
		case Detection_UltraServer:					strcopy(buffer, maxlength, "UltraServer");
		case Detection_UltraFakeStatus:				strcopy(buffer, maxlength, "FakeStatus");
		case Detection_Lerp:						strcopy(buffer, maxlength, "Lerp");
		case Detection_Strafe:						strcopy(buffer, maxlength, "Strafe");
		case Detection_CvarTrap:					strcopy(buffer, maxlength, "CvarTrap");
		case Detection_Usercmd:						strcopy(buffer, maxlength, "Usercmd");
		default:									strcopy(buffer, maxlength, "Unknown");
	}
}
