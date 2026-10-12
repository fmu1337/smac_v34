#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <smac>

#undef REQUIRE_PLUGIN
#include <adminmenu>
#define REQUIRE_PLUGIN

public Plugin:myinfo =
{
	name = "SMAC: No-Steam Bans",
	author = SMAC_AUTHOR,
	description = "Bans that follow a client-side marker when the SteamID changes",
	version = SMAC_VERSION,
	url = SMAC_URL
};

#define NSB_MARKER_MIN		1000000
#define NSB_MARKER_MAX		9999999

new const g_iBanMinutes[] = {0, 10, 30, 60, 240, 1440, 10080};
new const String:g_sBanTimePhrase[][] =
{
	"SMAC_NsbPermanent",
	"SMAC_Nsb10m",
	"SMAC_Nsb30m",
	"SMAC_Nsb1h",
	"SMAC_Nsb4h",
	"SMAC_Nsb1d",
	"SMAC_Nsb1w"
};
new const String:g_sBanReason[][] =
{
	"Abusive",
	"Racism",
	"General cheating/exploits",
	"WallHack",
	"AimBot",
	"Speedhacking",
	"Mic spamming",
	"Admin disrespect",
	"Camping",
	"Team killing",
	"Unacceptable Spray",
	"Breaking Server Rules",
	"Other"
};
new const String:g_sBanReasonPhrase[][] =
{
	"SMAC_NsbReason1",
	"SMAC_NsbReason2",
	"SMAC_NsbReason3",
	"SMAC_NsbReason4",
	"SMAC_NsbReason5",
	"SMAC_NsbReason6",
	"SMAC_NsbReason7",
	"SMAC_NsbReason8",
	"SMAC_NsbReason9",
	"SMAC_NsbReason10",
	"SMAC_NsbReason11",
	"SMAC_NsbReason12",
	"SMAC_NsbReason13"
};

new Handle:g_hEnable = INVALID_HANDLE;
new Handle:g_hBanIp = INVALID_HANDLE;
new Handle:g_hBanIpTime = INVALID_HANDLE;
new Handle:g_hBanSteam = INVALID_HANDLE;
new Handle:g_hFail = INVALID_HANDLE;
new Handle:g_hRestore = INVALID_HANDLE;
new Handle:g_hWarnEvery = INVALID_HANDLE;
new Handle:g_hHost = INVALID_HANDLE;

new Handle:g_hList = INVALID_HANDLE;
new Handle:g_hTopMenu = INVALID_HANDLE;
new Handle:g_hWarnTimer = INVALID_HANDLE;
new Handle:g_hRestoreTimer = INVALID_HANDLE;

new bool:g_bEngine;
new String:g_sListPath[PLATFORM_MAX_PATH];
new String:g_sCvar[16];
new String:g_sTail[24];
new String:g_sPanel[8];
new String:g_sKeyTitle[8];
new String:g_sKeyType[8];
new String:g_sKeyCmd[8];
new String:g_sTypeVal[4];
new g_iBanTarget[MAXPLAYERS + 1];
new g_iBanMinutesPick[MAXPLAYERS + 1];

public OnPluginStart()
{
	LoadTranslations("smac.phrases");
	InitSecrets();

	g_hEnable = SMAC_CreateConVar("smac_nsb", "1", "No-steam ban list: 0=off, 1=on", _, true, 0.0, true, 1.0);
	g_hBanIp = SMAC_CreateConVar("smac_nsb_banip", "1", "Also addip on enforce: 0=off, 1=exact IP, 2=/24, 3=/16", _, true, 0.0, true, 3.0);
	g_hBanIpTime = SMAC_CreateConVar("smac_nsb_banip_time", "45", "addip duration in minutes", _, true, 1.0);
	g_hBanSteam = SMAC_CreateConVar("smac_nsb_steamid", "1", "Also sm_ban the SteamID: 0=kick only, 1=ban", _, true, 0.0, true, 1.0);
	g_hFail = SMAC_CreateConVar("smac_nsb_fail", "1", "Client did not answer the marker query: 0=log, 1=kick", _, true, 0.0, true, 1.0);
	g_hRestore = SMAC_CreateConVar("smac_nsb_restore", "200", "Seconds until a menu toggle-off turns the check back on. 0 keeps it off", _, true, 0.0);
	g_hWarnEvery = SMAC_CreateConVar("smac_nsb_warn", "25", "Seconds between admin warnings while the check is toggled off. 0=silent", _, true, 0.0);

	HookConVarChange(g_hEnable, OnEnableChanged);

	RegAdminCmd("sm_nsb", Command_Menu, ADMFLAG_BAN, "Open the no-steam ban menu");
	RegAdminCmd("sm_nsb_enable", Command_Enable, ADMFLAG_ROOT, "Toggle the no-steam ban check");

	new EngineVersion:engine = GetEngineVersion();
	g_bEngine = (engine == Engine_SourceSDK2006 || engine == Engine_Original);
	if (!g_bEngine)
		SMAC_Log("smac_nsb: engine %d is not CSS v34, the client marker is disabled. SteamID hits still apply.", engine);

	g_hHost = FindConVar("hostname");
	LoadList();

	new Handle:topmenu;
	if (LibraryExists("adminmenu") && (topmenu = GetAdminTopMenu()) != INVALID_HANDLE)
		OnAdminMenuReady(topmenu);

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	}
}

public OnPluginEnd()
{
	if (g_hList != INVALID_HANDLE)
	{
		CloseHandle(g_hList);
		g_hList = INVALID_HANDLE;
	}
}

public OnLibraryRemoved(const String:name[])
{
	if (StrEqual(name, "adminmenu"))
		g_hTopMenu = INVALID_HANDLE;
}

public OnAdminMenuReady(Handle:topmenu)
{
	if (topmenu == g_hTopMenu)
		return;

	g_hTopMenu = topmenu;
	new TopMenuObject:category = FindTopMenuCategory(topmenu, "PlayerCommands");
	if (category == INVALID_TOPMENUOBJECT)
		return;

	AddToTopMenu(topmenu, "sm_nsb", TopMenuObject_Item, AdminMenu_Nsb, category, "sm_nsb", ADMFLAG_BAN);
}

public AdminMenu_Nsb(Handle:topmenu, TopMenuAction:action, TopMenuObject:object_id, param, String:buffer[], maxlength)
{
	if (action == TopMenuAction_DisplayOption)
		Format(buffer, maxlength, "%T", "SMAC_NsbMenu", param);
	else if (action == TopMenuAction_SelectOption)
		DisplayMainMenu(param);
}

public OnEnableChanged(Handle:convar, const String:oldValue[], const String:newValue[])
{
	if (GetConVarBool(g_hEnable))
		StopOffTimers();
}

public OnClientPutInServer(client)
{
	if (!GetConVarBool(g_hEnable) || g_hList == INVALID_HANDLE)
		return;
	if (!IsClientInGame(client) || IsFakeClient(client))
		return;

	decl String:auth[MAX_AUTHID_LENGTH];
	if (GetAuth(client, auth, sizeof(auth)) && FindSteam(auth))
	{
		Enforce(client);
		return;
	}

	if (g_bEngine)
		QueryClientConVar(client, g_sCvar, Query_Connect, GetClientUserId(client));
}

public OnClientDisconnect(client)
{
	g_iBanTarget[client] = 0;
	g_iBanMinutesPick[client] = 0;
}

public Action:Command_Menu(client, args)
{
	if (!client)
	{
		PrintToServer("sm_nsb is an in-game menu.");
		return Plugin_Handled;
	}
	DisplayMainMenu(client);
	return Plugin_Handled;
}

public Action:Command_Enable(client, args)
{
	new bool:on = !GetConVarBool(g_hEnable);
	SetCheckEnabled(on, true);
	ReplyToCommand(client, "no-Steam Bans : %s", on ? "ON" : "OFF");
	return Plugin_Handled;
}

public Query_Connect(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[], any:userid)
{
	if (GetClientOfUserId(userid) != client || !IsClientInGame(client))
		return;
	if (!GetConVarBool(g_hEnable) || g_hList == INVALID_HANDLE)
		return;

	if (result != ConVarQuery_Okay)
	{
		if (GetConVarBool(g_hFail))
			KickClient(client, "%t", "SMAC_FailedToReply");
		else
			SMAC_LogAction(client, "no-steam ban: marker query failed (%d)", result);
		return;
	}

	decl String:auth[MAX_AUTHID_LENGTH];
	if (GetAuth(client, auth, sizeof(auth)) && FindSteam(auth))
	{
		Enforce(client);
		return;
	}

	decl String:marker[16];
	if (!IsMarkerValue(cvarValue, marker, sizeof(marker)))
	{
		if (GenerateMarker(marker, sizeof(marker)))
			ShowMarkerPanel(client, marker);
		return;
	}

	if (FindMarker(marker) && RecordActive())
		Enforce(client);
}

public Query_Ban(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[], any:pack)
{
	new Handle:kv = Handle:pack;
	new admin = GetClientOfUserId(KvGetNum(kv, "AdminUserID", 0));
	new target = GetClientOfUserId(KvGetNum(kv, "BanTargetUserID", 0));
	new minutes = KvGetNum(kv, "BanTargetTime", 0);
	decl String:reason[64];
	KvGetString(kv, "BanTargetReason", reason, sizeof(reason), "Other");
	CloseHandle(kv);

	if (!target || !IsClientInGame(target) || target != client)
	{
		if (admin)
			PrintToChat(admin, "[SMAC] %t", "SMAC_NsbMissing");
		return;
	}
	if (admin && !CanUserTarget(admin, target))
	{
		PrintToChat(admin, "[SMAC] %t", "SMAC_NsbNoTarget");
		return;
	}

	decl String:marker[16];
	marker[0] = 0;
	if (result != ConVarQuery_Okay || !IsMarkerValue(cvarValue, marker, sizeof(marker)))
	{
		if (!GenerateMarker(marker, sizeof(marker)))
		{
			if (admin)
				PrintToChat(admin, "[SMAC] %t", "SMAC_NsbMissing");
			return;
		}
		ShowMarkerPanel(target, marker);
	}

	if (!marker[0])
	{
		if (admin)
			PrintToChat(admin, "[SMAC] %t", "SMAC_NsbMissing");
		return;
	}

	WriteBan(target, admin, marker, reason, minutes);
	Punish(target, reason, minutes);
	if (admin)
	{
		decl String:name[32];
		GetClientName(target, name, sizeof(name));
		PrintToChat(admin, "[SMAC] %t", "SMAC_NsbPlayerBanned", name);
	}
}

DisplayMainMenu(client)
{
	new Handle:menu = CreateMenu(Menu_Main);
	decl String:title[128];
	Format(title, sizeof(title), "%T", "SMAC_NsbMenu", client);
	SetMenuTitle(menu, title);

	decl String:item[128];
	if (CheckCommandAccess(client, "sm_nsb_ban", ADMFLAG_BAN, false))
	{
		Format(item, sizeof(item), "%T", "SMAC_NsbBan", client);
		AddMenuItem(menu, "ban", item);
	}
	if (CheckCommandAccess(client, "sm_nsb_unban", ADMFLAG_UNBAN, false))
	{
		Format(item, sizeof(item), "%T", "SMAC_NsbUnban", client);
		AddMenuItem(menu, "unban", item);
	}
	if (CheckCommandAccess(client, "sm_nsb_onoff", ADMFLAG_BAN | ADMFLAG_UNBAN, false))
	{
		if (GetConVarBool(g_hEnable))
		{
			Format(item, sizeof(item), "%T", "SMAC_NsbCheckOff", client);
			AddMenuItem(menu, "off", item);
		}
		else
		{
			Format(item, sizeof(item), "%T", "SMAC_NsbCheckOn", client);
			AddMenuItem(menu, "on", item);
		}
	}

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public Menu_Main(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack && g_hTopMenu != INVALID_HANDLE)
			DisplayTopMenu(g_hTopMenu, param1, TopMenuPosition_LastCategory);
	}
	else if (action == MenuAction_Select)
	{
		decl String:info[16];
		GetMenuItem(menu, param2, info, sizeof(info));
		if (StrEqual(info, "ban"))
		{
			if (!GetConVarBool(g_hEnable))
			{
				PrintToChat(param1, "[SMAC] %t", "SMAC_NsbNeedOn");
				DisplayMainMenu(param1);
			}
			else
			{
				DisplayPlayerMenu(param1);
			}
		}
		else if (StrEqual(info, "unban"))
		{
			DisplayUnbanMenu(param1);
		}
		else if (StrEqual(info, "on"))
		{
			SetCheckEnabled(true, true);
			PrintToChat(param1, "[SMAC] %t", "SMAC_NsbNowOn");
			DisplayMainMenu(param1);
		}
		else if (StrEqual(info, "off"))
		{
			SetCheckEnabled(false, true);
			PrintToChat(param1, "[SMAC] %t", "SMAC_NsbNowOff");
			DisplayMainMenu(param1);
		}
	}
}

DisplayPlayerMenu(client)
{
	new Handle:menu = CreateMenu(Menu_Player);
	decl String:title[128];
	Format(title, sizeof(title), "%T", "SMAC_NsbBan", client);
	SetMenuTitle(menu, title);

	if (!AddTargets(client, menu))
	{
		CloseHandle(menu);
		PrintToChat(client, "[SMAC] %t", "SMAC_NsbNoPlayers");
		DisplayMainMenu(client);
		return;
	}

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public Menu_Player(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
			DisplayMainMenu(param1);
	}
	else if (action == MenuAction_Select)
	{
		decl String:info[16];
		GetMenuItem(menu, param2, info, sizeof(info));
		new target = GetClientOfUserId(StringToInt(info));
		if (!target)
		{
			PrintToChat(param1, "[SMAC] %t", "SMAC_NsbMissing");
			DisplayPlayerMenu(param1);
			return;
		}
		if (!CanUserTarget(param1, target))
		{
			PrintToChat(param1, "[SMAC] %t", "SMAC_NsbNoTarget");
			DisplayPlayerMenu(param1);
			return;
		}
		g_iBanTarget[param1] = GetClientUserId(target);
		DisplayTimeMenu(param1);
	}
}

DisplayTimeMenu(client)
{
	new target = GetClientOfUserId(g_iBanTarget[client]);
	if (!target || !CanUserTarget(client, target))
	{
		PrintToChat(client, "[SMAC] %t", "SMAC_NsbMissing");
		DisplayPlayerMenu(client);
		return;
	}

	new Handle:menu = CreateMenu(Menu_Time);
	decl String:title[128];
	Format(title, sizeof(title), "%T: %N", "SMAC_NsbBan", client, target);
	SetMenuTitle(menu, title);

	decl String:info[16], String:item[128];
	for (new i = 0; i < sizeof(g_iBanMinutes); i++)
	{
		IntToString(g_iBanMinutes[i], info, sizeof(info));
		Format(item, sizeof(item), "%T", g_sBanTimePhrase[i], client);
		AddMenuItem(menu, info, item);
	}

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public Menu_Time(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
			DisplayPlayerMenu(param1);
	}
	else if (action == MenuAction_Select)
	{
		new target = GetClientOfUserId(g_iBanTarget[param1]);
		if (!target || !CanUserTarget(param1, target))
		{
			PrintToChat(param1, "[SMAC] %t", "SMAC_NsbMissing");
			DisplayPlayerMenu(param1);
			return;
		}
		decl String:info[16];
		GetMenuItem(menu, param2, info, sizeof(info));
		g_iBanMinutesPick[param1] = StringToInt(info);
		DisplayReasonMenu(param1);
	}
}

DisplayReasonMenu(client)
{
	new target = GetClientOfUserId(g_iBanTarget[client]);
	if (!target || !CanUserTarget(client, target))
	{
		PrintToChat(client, "[SMAC] %t", "SMAC_NsbMissing");
		DisplayPlayerMenu(client);
		return;
	}

	new Handle:menu = CreateMenu(Menu_Reason);
	decl String:title[128];
	Format(title, sizeof(title), "%T: %N", "SMAC_NsbReason", client, target);
	SetMenuTitle(menu, title);

	decl String:item[128];
	for (new i = 0; i < sizeof(g_sBanReason); i++)
	{
		Format(item, sizeof(item), "%T", g_sBanReasonPhrase[i], client);
		AddMenuItem(menu, g_sBanReason[i], item);
	}

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public Menu_Reason(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
			DisplayTimeMenu(param1);
	}
	else if (action == MenuAction_Select)
	{
		new target = GetClientOfUserId(g_iBanTarget[param1]);
		if (!target || !CanUserTarget(param1, target))
		{
			PrintToChat(param1, "[SMAC] %t", "SMAC_NsbMissing");
			DisplayPlayerMenu(param1);
			return;
		}

		decl String:reason[64];
		GetMenuItem(menu, param2, reason, sizeof(reason));

		new Handle:kv = CreateKeyValues("UserInfoList");
		KvSetNum(kv, "AdminUserID", GetClientUserId(param1));
		KvSetNum(kv, "BanTargetUserID", g_iBanTarget[param1]);
		KvSetNum(kv, "BanTargetTime", g_iBanMinutesPick[param1]);
		KvSetString(kv, "BanTargetReason", reason);

		if (g_bEngine)
			QueryClientConVar(target, g_sCvar, Query_Ban, kv);
		else
			Query_Ban(QueryCookie:0, target, ConVarQuery_NotFound, g_sCvar, "", kv);
	}
}

DisplayUnbanMenu(client)
{
	if (g_hList == INVALID_HANDLE)
	{
		PrintToChat(client, "[SMAC] %t", "SMAC_NsbListClear");
		DisplayMainMenu(client);
		return;
	}

	new Handle:menu = CreateMenu(Menu_Unban);
	decl String:title[128];
	Format(title, sizeof(title), "%T", "SMAC_NsbSelect", client);
	SetMenuTitle(menu, title);

	KvRewind(g_hList);
	if (KvGotoFirstSubKey(g_hList, false))
	{
		decl String:marker[16], String:name[32];
		do
		{
			KvGetSectionName(g_hList, marker, sizeof(marker));
			KvGetString(g_hList, "Player", name, sizeof(name), marker);
			if (marker[0])
				AddMenuItem(menu, marker, name);
		}
		while (KvGotoNextKey(g_hList, false));
	}

	if (!GetMenuItemCount(menu))
	{
		CloseHandle(menu);
		PrintToChat(client, "[SMAC] %t", "SMAC_NsbListClear");
		DisplayMainMenu(client);
		return;
	}

	SetMenuExitBackButton(menu, true);
	DisplayMenu(menu, client, MENU_TIME_FOREVER);
}

public Menu_Unban(Handle:menu, MenuAction:action, param1, param2)
{
	if (action == MenuAction_End)
	{
		CloseHandle(menu);
	}
	else if (action == MenuAction_Cancel)
	{
		if (param2 == MenuCancel_ExitBack)
			DisplayMainMenu(param1);
	}
	else if (action == MenuAction_Select)
	{
		decl String:marker[16];
		GetMenuItem(menu, param2, marker, sizeof(marker));
		UnbanMarker(param1, marker);
		DisplayMainMenu(param1);
	}
}

bool:AddTargets(client, Handle:menu)
{
	new Handle:list = CreateArray();
	for (new i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || IsFakeClient(i))
			continue;
		if (!CanUserTarget(client, i) || IsClientInKickQueue(i))
			continue;
		new userid = GetClientUserId(i);
		if (userid)
			PushArrayCell(list, userid);
	}

	SortADTArray(list, Sort_Descending, Sort_Integer);

	new count = GetArraySize(list);
	decl String:info[16], String:name[48], String:item[80], String:tag[8];
	for (new n = 0; n < count; n++)
	{
		new userid = GetArrayCell(list, n);
		new target = GetClientOfUserId(userid);
		if (!target)
			continue;

		IntToString(userid, info, sizeof(info));
		if (!GetClientName(target, name, sizeof(name)))
			strcopy(name, sizeof(name), "unknown");

		new team = GetClientTeam(target);
		if (team <= 1)
			strcopy(tag, sizeof(tag), "SPEC");
		else if (team == 2)
			strcopy(tag, sizeof(tag), "T");
		else
			strcopy(tag, sizeof(tag), "CT");

		Format(item, sizeof(item), "[%s] %s #%d", tag, name, userid);
		AddMenuItem(menu, info, item);
	}

	CloseHandle(list);
	return GetMenuItemCount(menu) > 0;
}

LoadList()
{
	BuildPath(Path_SM, g_sListPath, sizeof(g_sListPath), "data/smac_nsblist.txt");
	g_hList = CreateKeyValues("SMAC NSB");

	if (FileExists(g_sListPath) && !FileToKeyValues(g_hList, g_sListPath))
		SMAC_Log("smac_nsb: failed to read %s", g_sListPath);

	ImportKacBans();
}

ImportKacBans()
{
	if (g_hList == INVALID_HANDLE)
		return;

	decl String:oldpath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, oldpath, sizeof(oldpath), "data/kac_nsblist.txt");
	if (!FileExists(oldpath))
		return;

	new Handle:old = CreateKeyValues("import");
	if (!FileToKeyValues(old, oldpath))
	{
		CloseHandle(old);
		SMAC_Log("smac_nsb: failed to read %s", oldpath);
		return;
	}

	if (!KvGotoFirstSubKey(old))
	{
		CloseHandle(old);
		return;
	}

	new imported = 0;
	decl String:marker[16];
	do
	{
		KvGetSectionName(old, marker, sizeof(marker));
		if (!marker[0] || FindMarker(marker))
			continue;
		KvRewind(g_hList);
		if (!KvJumpToKey(g_hList, marker, true))
			continue;
		KvCopySubkeys(old, g_hList);
		imported++;
	}
	while (KvGotoNextKey(old));

	CloseHandle(old);
	if (imported < 1)
		return;

	if (SaveList())
		SMAC_Log("smac_nsb: imported %d ban(s) from %s", imported, oldpath);
}

bool:SaveList()
{
	if (g_hList == INVALID_HANDLE)
		return false;
	KvRewind(g_hList);
	if (!KeyValuesToFile(g_hList, g_sListPath))
	{
		SMAC_Log("smac_nsb: failed to write %s", g_sListPath);
		return false;
	}
	return true;
}

bool:FindSteam(const String:auth[])
{
	if (!auth[0] || g_hList == INVALID_HANDLE)
		return false;
	if (StrEqual(auth, "BOT") || StrEqual(auth, "STEAM_ID_PENDING") || StrEqual(auth, "STEAM_ID_LAN"))
		return false;

	KvRewind(g_hList);
	if (!KvGotoFirstSubKey(g_hList, false))
		return false;

	decl String:id[MAX_AUTHID_LENGTH];
	do
	{
		KvGetString(g_hList, "SteamID", id, sizeof(id), "");
		if (id[0] && StrEqual(id, auth))
			return true;
	}
	while (KvGotoNextKey(g_hList, false));
	return false;
}

bool:FindMarker(const String:marker[])
{
	if (!marker[0] || g_hList == INVALID_HANDLE)
		return false;
	KvRewind(g_hList);
	return KvJumpToKey(g_hList, marker, false);
}

bool:RecordActive()
{
	decl String:status[16];
	KvGetString(g_hList, "Status", status, sizeof(status), "");
	if (status[0] && !StrEqual(status, "Banned"))
		return false;

	decl String:expires[16];
	KvGetString(g_hList, "Expires", expires, sizeof(expires), "");
	if (expires[0])
	{
		new when = StringToInt(expires);
		if (when <= 0)
			return true;
		return GetTime() < when;
	}

	decl String:elapse[32];
	KvGetString(g_hList, "Elapse", elapse, sizeof(elapse), "");
	if (!elapse[0] || StrEqual(elapse, "Permanent") || StrEqual(elapse, "0"))
		return true;
	return LegacyElapseActive(elapse);
}

bool:LegacyElapseActive(const String:elapse[])
{
	decl String:flat[32], String:now[32];
	strcopy(flat, sizeof(flat), elapse);
	ReplaceString(flat, sizeof(flat), ".", "");
	ReplaceString(flat, sizeof(flat), " ", "");
	new end = StringToInt(flat);
	if (end <= 0)
		return true;

	FormatTime(now, sizeof(now), "%d.%m%H.%M", GetTime());
	ReplaceString(now, sizeof(now), ".", "");
	return StringToInt(now) < end;
}

WriteBan(target, admin, const String:marker[], const String:reason[], minutes)
{
	if (g_hList == INVALID_HANDLE)
		return;
	if (!FindMarker(marker) && !KvJumpToKey(g_hList, marker, true))
		return;

	decl String:name[32], String:auth[MAX_AUTHID_LENGTH], String:adminName[32];
	if (!GetClientName(target, name, sizeof(name)))
		strcopy(name, sizeof(name), "Unknown");
	if (!GetAuth(target, auth, sizeof(auth)))
		strcopy(auth, sizeof(auth), "Unknown");
	if (!admin || !GetClientName(admin, adminName, sizeof(adminName)))
		strcopy(adminName, sizeof(adminName), "Console");

	KvSetString(g_hList, "Player", name);
	KvSetString(g_hList, "SteamID", auth);
	KvSetString(g_hList, "Status", "Banned");
	KvSetString(g_hList, "Banned By Admin", adminName);
	KvSetString(g_hList, "Ban Reason", reason);

	decl String:elapse[32], String:expires[16];
	if (minutes <= 0)
	{
		strcopy(elapse, sizeof(elapse), "Permanent");
		strcopy(expires, sizeof(expires), "0");
	}
	else
	{
		new when = GetTime() + minutes * 60;
		FormatTime(elapse, sizeof(elapse), "%d.%m %H.%M", when);
		FormatEx(expires, sizeof(expires), "%d", when);
	}
	KvSetString(g_hList, "Elapse", elapse);
	KvSetString(g_hList, "Expires", expires);
	SaveList();

	decl String:adminAuth[MAX_AUTHID_LENGTH], String:adminIp[32];
	if (admin)
	{
		if (!GetAuth(admin, adminAuth, sizeof(adminAuth)))
			strcopy(adminAuth, sizeof(adminAuth), "Unknown");
		if (!GetClientIP(admin, adminIp, sizeof(adminIp)))
			strcopy(adminIp, sizeof(adminIp), "Unknown");
	}
	else
	{
		strcopy(adminAuth, sizeof(adminAuth), "Console");
		strcopy(adminIp, sizeof(adminIp), "-");
	}

	SMAC_LogAction(target, "no-steam banned by %s (%s | %s), marker %s, reason '%s', until %s", adminName, adminAuth, adminIp, marker, reason, elapse);
}

UnbanMarker(admin, const String:marker[])
{
	if (!FindMarker(marker))
	{
		PrintToChat(admin, "[SMAC] %t", "SMAC_NsbListClear");
		return;
	}

	decl String:name[32], String:auth[MAX_AUTHID_LENGTH];
	KvGetString(g_hList, "Player", name, sizeof(name), marker);
	KvGetString(g_hList, "SteamID", auth, sizeof(auth), "");
	KvDeleteThis(g_hList);
	SaveList();

	if (auth[0] && !StrEqual(auth, "Unknown"))
	{
		decl String:cmd[96];
		FormatEx(cmd, sizeof(cmd), "sm_unban \"%s\"", auth);
		ServerCommand(cmd);
	}

	decl String:adminName[32];
	if (!GetClientName(admin, adminName, sizeof(adminName)))
		strcopy(adminName, sizeof(adminName), "Console");
	SMAC_Log("smac_nsb: %s removed ban '%s' (%s), marker %s", adminName, name, auth, marker);
	PrintToChat(admin, "[SMAC] %t", "SMAC_NsbPlayerUnbanned", name);
}

Enforce(client)
{
	decl String:reason[64];
	KvGetString(g_hList, "Ban Reason", reason, sizeof(reason), "no-steam ban");

	new Handle:info = CreateKeyValues("");
	KvSetString(info, "check", "no-steam ban");
	KvSetString(info, "reason", reason);
	new Action:result = SMAC_CheatDetected(client, Detection_Nsb, info);
	CloseHandle(info);
	if (result != Plugin_Continue)
		return;

	SMAC_PrintAdminNotice("%t", "SMAC_NsbHit", client, reason);
	SMAC_LogAction(client, "no-steam ban list (%s)", reason);
	Punish(client, reason, 5);
}

Punish(client, const String:reason[], minutes)
{
	BanIp(client);

	if (GetConVarBool(g_hBanSteam))
	{
		decl String:safe[64], String:cmd[160];
		strcopy(safe, sizeof(safe), reason);
		ReplaceString(safe, sizeof(safe), "\"", "'");
		FormatEx(cmd, sizeof(cmd), "sm_ban #%d %d \"%s\"", GetClientUserId(client), minutes, safe);
		ServerCommand(cmd);
	}
	else
	{
		KickClient(client, "%t", "SMAC_NsbBanned");
	}
}

BanIp(client)
{
	new mode = GetConVarInt(g_hBanIp);
	if (mode < 1)
		return;

	decl String:ip[32];
	if (!GetClientIP(client, ip, sizeof(ip)))
		return;

	new minutes = GetConVarInt(g_hBanIpTime);
	if (minutes < 1)
		minutes = 1;

	decl String:cmd[96];
	if (mode <= 1)
	{
		FormatEx(cmd, sizeof(cmd), "addip \"%d\" \"%s\"", minutes, ip);
	}
	else
	{
		decl String:parts[4][8];
		new n = ExplodeString(ip, ".", parts, 4, 8);
		if (n < 2)
			return;
		if (mode == 2 && n >= 3)
			FormatEx(cmd, sizeof(cmd), "addip \"%d\" \"%s.%s.%s.0/255.255.255.0\"", minutes, parts[0], parts[1], parts[2]);
		else
			FormatEx(cmd, sizeof(cmd), "addip \"%d\" \"%s.%s.0.0/255.255.0.0\"", minutes, parts[0], parts[1]);
	}
	InsertServerCommand(cmd);
}

bool:GenerateMarker(String:marker[], maxlen)
{
	for (new i = 0; i < 8; i++)
	{
		FormatEx(marker, maxlen, "%d", GetRandomInt(NSB_MARKER_MIN, NSB_MARKER_MAX));
		if (!FindMarker(marker))
			return true;
	}
	marker[0] = 0;
	return false;
}

ShowMarkerPanel(client, const String:marker[])
{
	if (!g_bEngine || !IsClientInGame(client) || !marker[0])
		return;

	decl String:host[64], String:cmd[64];
	host[0] = 0;
	if (g_hHost != INVALID_HANDLE)
		GetConVarString(g_hHost, host, sizeof(host));
	if (!host[0])
		strcopy(host, sizeof(host), "Server");
	FormatEx(cmd, sizeof(cmd), "%s %s%s", g_sCvar, marker, g_sTail);

	new Handle:kv = CreateKeyValues("data");
	KvSetString(kv, g_sKeyTitle, host);
	KvSetString(kv, g_sKeyType, g_sTypeVal);
	KvSetString(kv, g_sKeyCmd, cmd);
	ShowVGUIPanel(client, g_sPanel, kv, true);
	CloseHandle(kv);
}

InitSecrets()
{
	new const t0[] = {6, 14, 36, 18, 238, 227, 226, 233, 229, 255};
	new const t1[] = {78, 14, 25, 31, 239, 164, 183, 170, 189, 171, 240, 254, 246, 243, 236, 199, 209, 205, 202, 195};
	new const t2[] = {28, 22, 29, 17};
	new const t3[] = {1, 17, 15, 18, 228};
	new const t4[] = {1, 1, 11, 27};
	new const t5[] = {22, 21, 31};
	new const t6[] = {71};
	Unpack(t0, sizeof(t0), g_sCvar, sizeof(g_sCvar));
	Unpack(t1, sizeof(t1), g_sTail, sizeof(g_sTail));
	Unpack(t2, sizeof(t2), g_sPanel, sizeof(g_sPanel));
	Unpack(t3, sizeof(t3), g_sKeyTitle, sizeof(g_sKeyTitle));
	Unpack(t4, sizeof(t4), g_sKeyType, sizeof(g_sKeyType));
	Unpack(t5, sizeof(t5), g_sKeyCmd, sizeof(g_sKeyCmd));
	Unpack(t6, sizeof(t6), g_sTypeVal, sizeof(g_sTypeVal));
}

Unpack(const blob[], n, String:dest[], maxlen)
{
	new a = 4;
	a += 7;
	a *= 3;
	a += 84;
	new i;
	for (i = 0; i < n && i < maxlen - 1; i++)
		dest[i] = blob[i] ^ (a + i * 3);
	dest[i] = 0;
}

SetCheckEnabled(bool:on, bool:fromMenu)
{
	SetConVarBool(g_hEnable, on);
	if (on || !fromMenu)
	{
		StopOffTimers();
		if (on)
		{
			for (new i = 1; i <= MaxClients; i++)
			{
				if (IsClientInGame(i))
					OnClientPutInServer(i);
			}
		}
		return;
	}

	StopOffTimers();
	new Float:restore = GetConVarFloat(g_hRestore);
	new Float:warn = GetConVarFloat(g_hWarnEvery);
	if (warn >= 1.0)
	{
		g_hWarnTimer = CreateTimer(warn, Timer_Warn, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		SMAC_PrintAdminNotice("%t", "SMAC_NsbWarnOff");
	}
	if (restore >= 1.0)
		g_hRestoreTimer = CreateTimer(restore, Timer_Restore, _, TIMER_FLAG_NO_MAPCHANGE);
}

StopOffTimers()
{
	if (g_hWarnTimer != INVALID_HANDLE)
	{
		KillTimer(g_hWarnTimer);
		g_hWarnTimer = INVALID_HANDLE;
	}
	if (g_hRestoreTimer != INVALID_HANDLE)
	{
		KillTimer(g_hRestoreTimer);
		g_hRestoreTimer = INVALID_HANDLE;
	}
}

public Action:Timer_Warn(Handle:timer)
{
	if (GetConVarBool(g_hEnable))
	{
		g_hWarnTimer = INVALID_HANDLE;
		return Plugin_Stop;
	}
	SMAC_PrintAdminNotice("%t", "SMAC_NsbWarnOff");
	return Plugin_Continue;
}

public Action:Timer_Restore(Handle:timer)
{
	g_hRestoreTimer = INVALID_HANDLE;
	SetCheckEnabled(true, false);
	return Plugin_Stop;
}

bool:GetAuth(client, String:auth[], maxlen)
{
#if SOURCEMOD_V_MAJOR >= 1 && SOURCEMOD_V_MINOR >= 7
	return GetClientAuthId(client, AuthId_Steam2, auth, maxlen, false);
#else
	return GetClientAuthString(client, auth, maxlen, false);
#endif
}

bool:IsMarkerValue(const String:value[], String:out[], maxlen)
{
	out[0] = 0;
	new n = strlen(value);
	if (n != 7)
		return false;

	for (new i = 0; i < n; i++)
	{
		if (!IsCharNumeric(value[i]))
			return false;
	}

	new v = StringToInt(value);
	if (v < NSB_MARKER_MIN || v > NSB_MARKER_MAX)
		return false;

	strcopy(out, maxlen, value);
	return true;
}
