

#if defined _colors_included
 #endinput
#endif
#define _colors_included

#define MAX_MESSAGE_LENGTH 250
#define MAX_COLORS 6

#define SERVER_INDEX 0
#define NO_INDEX -1
#define NO_PLAYER -2

enum Colors
{
 	Color_Default = 0,
	Color_Green,
	Color_Lightgreen,
	Color_Red,
	Color_Blue,
	Color_Olive
}

new String:CTag[][] = {"{default}", "{green}", "{lightgreen}", "{red}", "{blue}", "{olive}"};
new String:CTagCode[][] = {"\x01", "\x04", "\x03", "\x03", "\x03", "\x05"};
new bool:CTagReqSayText2[] = {false, false, true, true, true, false};
new bool:CEventIsHooked = false;
new bool:CSkipList[MAXPLAYERS+1] = {false,...};

new bool:CProfile_Colors[] = {true, true, false, false, false, false};
new CProfile_TeamIndex[] = {NO_INDEX, NO_INDEX, NO_INDEX, NO_INDEX, NO_INDEX, NO_INDEX};
new bool:CProfile_SayText2 = false;

stock CPrintToChat(client, const String:szMessage[], any:...)
{
	if (client <= 0 || client > MaxClients)
		ThrowError("Invalid client index %d", client);

	if (!IsClientInGame(client))
		ThrowError("Client %d is not in game", client);

	decl String:szBuffer[MAX_MESSAGE_LENGTH];
	decl String:szCMessage[MAX_MESSAGE_LENGTH];
	SetGlobalTransTarget(client);
	Format(szBuffer, sizeof(szBuffer), "\x01%s", szMessage);
	VFormat(szCMessage, sizeof(szCMessage), szBuffer, 3);

	new index = CFormat(szCMessage, sizeof(szCMessage));
	if (index == NO_INDEX)
	{
		PrintToChat(client, szCMessage);
	}
	else
	{
		CSayText2(client, index, szCMessage);
	}
}

stock CPrintToChatAll(const String:szMessage[], any:...)
{
	decl String:szBuffer[MAX_MESSAGE_LENGTH];

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && !CSkipList[i])
		{
			SetGlobalTransTarget(i);
			VFormat(szBuffer, sizeof(szBuffer), szMessage, 2);
			CPrintToChat(i, szBuffer);
		}

		CSkipList[i] = false;
	}
}

stock CPrintToChatEx(client, author, const String:szMessage[], any:...)
{
	if (client <= 0 || client > MaxClients)
		ThrowError("Invalid client index %d", client);

	if (!IsClientInGame(client))
		ThrowError("Client %d is not in game", client);

	if (author < 0 || author > MaxClients)
		ThrowError("Invalid client index %d", author);

	decl String:szBuffer[MAX_MESSAGE_LENGTH];
	decl String:szCMessage[MAX_MESSAGE_LENGTH];
	SetGlobalTransTarget(client);
	Format(szBuffer, sizeof(szBuffer), "\x01%s", szMessage);
	VFormat(szCMessage, sizeof(szCMessage), szBuffer, 4);

	new index = CFormat(szCMessage, sizeof(szCMessage), author);
	if (index == NO_INDEX)
	{
		PrintToChat(client, szCMessage);
	}
	else
	{
		CSayText2(client, author, szCMessage);
	}
}

stock CPrintToChatAllEx(author, const String:szMessage[], any:...)
{
	if (author < 0 || author > MaxClients)
		ThrowError("Invalid client index %d", author);

	if (!IsClientInGame(author))
		ThrowError("Client %d is not in game", author);

	decl String:szBuffer[MAX_MESSAGE_LENGTH];

	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && !CSkipList[i])
		{
			SetGlobalTransTarget(i);
			VFormat(szBuffer, sizeof(szBuffer), szMessage, 3);
			CPrintToChatEx(i, author, szBuffer);
		}

		CSkipList[i] = false;
	}
}

stock CRemoveTags(String:szMessage[], maxlength)
{
	for (new i = 0; i < MAX_COLORS; i++)
	{
		ReplaceString(szMessage, maxlength, CTag[i], "");
	}

	ReplaceString(szMessage, maxlength, "{teamcolor}", "");
}

stock CSkipNextClient(client)
{
	if (client <= 0 || client > MaxClients)
		ThrowError("Invalid client index %d", client);

	CSkipList[client] = true;
}

stock CFormat(String:szMessage[], maxlength, author=NO_INDEX)
{

	if (!CEventIsHooked)
	{
		CSetupProfile();
		HookEvent("server_spawn", CEvent_MapStart, EventHookMode_PostNoCopy);
		CEventIsHooked = true;
	}

	new iRandomPlayer = NO_INDEX;

	if (author != NO_INDEX)
	{
		if (CProfile_SayText2)
		{
			ReplaceString(szMessage, maxlength, "{teamcolor}", "\x03");
			iRandomPlayer = author;
		}

		else
		{
			ReplaceString(szMessage, maxlength, "{teamcolor}", CTagCode[Color_Green]);
		}
	}
	else
	{
		ReplaceString(szMessage, maxlength, "{teamcolor}", "");
	}

	for (new i = 0; i < MAX_COLORS; i++)
	{

		if (StrContains(szMessage, CTag[i]) == -1)
		{
			continue;
		}

		else if (!CProfile_Colors[i])
		{
			ReplaceString(szMessage, maxlength, CTag[i], CTagCode[Color_Green]);
		}

		else if (!CTagReqSayText2[i])
		{
			ReplaceString(szMessage, maxlength, CTag[i], CTagCode[i]);
		}

		else
		{

			if (!CProfile_SayText2)
			{
				ReplaceString(szMessage, maxlength, CTag[i], CTagCode[Color_Green]);
			}

			else
			{

				if (iRandomPlayer == NO_INDEX)
				{

					iRandomPlayer = CFindRandomPlayerByTeam(CProfile_TeamIndex[i]);

					if (iRandomPlayer == NO_PLAYER)
					{
						ReplaceString(szMessage, maxlength, CTag[i], CTagCode[Color_Green]);
					}

					else
					{
						ReplaceString(szMessage, maxlength, CTag[i], CTagCode[i]);
					}

				}

				else
				{

					ThrowError("Using two team colors in one message is not allowed");
				}
			}

		}
	}

	return iRandomPlayer;
}

stock CFindRandomPlayerByTeam(color_team)
{
	if (color_team == SERVER_INDEX)
	{
		return 0;
	}
	else
	{
		for (new i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && GetClientTeam(i) == color_team)
			{
				return i;
			}
		}
	}

	return NO_PLAYER;
}

stock CSayText2(client, author, const String:szMessage[])
{
	new Handle:hBuffer = StartMessageOne("SayText2", client);
	BfWriteByte(hBuffer, author);
	BfWriteByte(hBuffer, true);
	BfWriteString(hBuffer, szMessage);
	EndMessage();
}

stock CSetupProfile()
{
	decl String:szGameName[30];
	GetGameFolderName(szGameName, sizeof(szGameName));

	if (StrEqual(szGameName, "cstrike", false))
	{
		CProfile_Colors[Color_Lightgreen] = true;
		CProfile_Colors[Color_Red] = true;
		CProfile_Colors[Color_Blue] = true;
		CProfile_Colors[Color_Olive] = true;
		CProfile_TeamIndex[Color_Lightgreen] = SERVER_INDEX;
		CProfile_TeamIndex[Color_Red] = 2;
		CProfile_TeamIndex[Color_Blue] = 3;
		CProfile_SayText2 = true;
	}
	else if (StrEqual(szGameName, "tf", false))
	{
		CProfile_Colors[Color_Lightgreen] = true;
		CProfile_Colors[Color_Red] = true;
		CProfile_Colors[Color_Blue] = true;
		CProfile_Colors[Color_Olive] = true;
		CProfile_TeamIndex[Color_Lightgreen] = SERVER_INDEX;
		CProfile_TeamIndex[Color_Red] = 2;
		CProfile_TeamIndex[Color_Blue] = 3;
		CProfile_SayText2 = true;
	}
	else if (StrEqual(szGameName, "left4dead", false) || StrEqual(szGameName, "left4dead2", false))
	{
		CProfile_Colors[Color_Lightgreen] = true;
		CProfile_Colors[Color_Red] = true;
		CProfile_Colors[Color_Blue] = true;
		CProfile_Colors[Color_Olive] = true;
		CProfile_TeamIndex[Color_Lightgreen] = SERVER_INDEX;
		CProfile_TeamIndex[Color_Red] = 3;
		CProfile_TeamIndex[Color_Blue] = 2;
		CProfile_SayText2 = true;
	}
	else if (StrEqual(szGameName, "hl2mp", false))
	{

		if (GetConVarBool(FindConVar("mp_teamplay")))
		{
			CProfile_Colors[Color_Red] = true;
			CProfile_Colors[Color_Blue] = true;
			CProfile_TeamIndex[Color_Red] = 3;
			CProfile_TeamIndex[Color_Blue] = 2;
			CProfile_SayText2 = true;
		}
		else
		{
			CProfile_SayText2 = false;
		}
	}
	else if (StrEqual(szGameName, "dod", false))
	{
		CProfile_Colors[Color_Olive] = true;
		CProfile_SayText2 = false;
	}

	else
	{
		if (GetUserMessageId("SayText2") == INVALID_MESSAGE_ID)
		{
			CProfile_SayText2 = false;
		}
		else
		{
			CProfile_Colors[Color_Red] = true;
			CProfile_Colors[Color_Blue] = true;
			CProfile_TeamIndex[Color_Red] = 2;
			CProfile_TeamIndex[Color_Blue] = 3;
			CProfile_SayText2 = true;
		}
	}
}

public Action:CEvent_MapStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	CSetupProfile();

	for (new i = 1; i <= MaxClients; i++)
	{
		CSkipList[i] = false;
	}
}