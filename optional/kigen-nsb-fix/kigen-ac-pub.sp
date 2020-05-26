#include <sourcemod>
#pragma semicolon 1

public Plugin:myinfo =
{
	name = "Kigen's Anti-Cheat",
	description = "\"CS:S v.34\" The greatest thing since sliced pie.",
	author = "Kigen, GoD-Tony, psychonic and GoDtm666.",
	version = "1.2.2.9.9.3",
	url = "http://kigenac.sourcetm.com/"
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	CreateConVar("kac_version", "1.2.2.9.9.3", "Kigen's Anti-Cheat Version");
	CreateNative("KAC_PrintAdminNotice", Native_PrintAdminNotice);
	RegPluginLibrary("Kigen's Anti-Cheat");

	return APLRes_Success;
}


public OnPluginStart()
{
	// KEK???
}

public Native_PrintAdminNotice(Handle:plugin, numParams)
{

}