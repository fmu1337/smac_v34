#if defined _smac_included
  #endinput
#endif
#define _smac_included

#include <smac_stocks>

/* Globals */
#define SMAC_VERSION	"v34.R2"
#define SMAC_URL		"https://vk.com/by_danyas"
#define SMAC_AUTHOR		"Danyas"


enum DetectionType {
	Detection_Unknown = 0,
	Detection_Aimbot = 100,
	Detection_AutoTrigger = 200,
	Detection_NameChangeSpam = 300,
	Detection_CommandSpamming = 400,
	Detection_BannedCommand,
	Detection_CvarViolation = 500,
	Detection_UserCmdReuse = 600,
	Detection_UserCmdTamperingTickcount,
	Detection_UserCmdTamperingButtons,
	Detection_Eyeangles,
	Detection_Speedhack = 700,
	Detection_Spinhack = 800,

	/* Ported detectors from Cheat-Acid GRAB (LilAC / StAC / 2xAA / FFC). */
	Detection_Aimlock = 900,
	Detection_pSilent = 1000,
	Detection_AimOriginConsistency = 1100,
	Detection_ChatClear = 1200,
	Detection_HardFlood = 1300,

	/* Rewritten detectors (inspired by CowAC / Bash / CA-ServerProtect ideas). */
	Detection_SilentStrafe = 1400,
	Detection_PerfectStrafe = 1500,
	Detection_IllegalSidemove = 1600,
	Detection_TriggerBot = 1700,

	/* HOTGUARD / Ash / Bash / Oryx / Cow Private (rewritten, Danyas). */
	Detection_MouseAim = 1800,
	Detection_AngleDesync = 1900,
	Detection_WiggleHack = 2000,
	Detection_AntiAimAngles = 2100,
	Detection_AngleDelay = 2200,
	Detection_WishVelocity = 2300,
	Detection_PerfectBhop = 2400,
	Detection_AutoShoot = 2500,
	Detection_KeySwitchHack = 2600,
	Detection_StrafeSync = 2700,

	/* SMAC Ultra (Ultr@) ideas — rewritten, Danyas. */
	Detection_KnifeBotWH = 2800,
	Detection_AimThroughWH = 2900,
	Detection_TeleportHack = 3000,
	Detection_EntitySpam = 3100,
	Detection_SensitivitySpam = 3200,
	Detection_ImpulseSpam = 3300,

	/* SSAC v2 ideas — rewritten, Danyas. */
	Detection_TimedBhop = 3400,
	Detection_AirStuck = 3500,
	Detection_FastLadder = 3600,
	Detection_FastRun = 3700,
	Detection_LagExploit = 3800,
	Detection_MouselessAim = 3900,

	/* SMAC Ultra deep-mine — rewritten, Danyas. */
	Detection_NoRecoil = 4000,
	Detection_FakeLag = 4100,
	Detection_Attack2Macro = 4200,
	Detection_FastAim = 4300,

	/* SMAC Ultra aim modes restored from R52 Global.smx .data / dbg symbols. */
	Detection_UltraPRG = 4400,		/* Pass.Mode:301-304 */
	Detection_UltraAGT = 4500,		/* Mode:288/299 */
	Detection_UltraAGTAF = 4600,	/* Mode:88/99/108/109 */
	Detection_UltraTriggerAim = 4700,	/* Mode:188/199 */
	Detection_UltraNullAim = 4800,	/* Mode:200/201 AGTNL */
	Detection_UltraRCS = 4900,		/* Recoil Control System -H/-F */
	Detection_UltraAGTWS = 5000,	/* Mode:100 When a Shot */
	Detection_UltraAMSAF = 5100,	/* Mode:101 Analysis After Firing */
};

#if SOURCEMOD_V_MAJOR >= 1 && SOURCEMOD_V_MINOR >= 11
// Newer compilers require an explicit type; older ones create the GameType tag implicitly.
enum GameType {
	Game_Unknown = 0,
	Game_CSS,
	Game_TF2,
	Game_DODS,
	Game_INS,
	Game_L4D,
	Game_L4D2,
	Game_HL2DM,
	Game_CSGO,
	Game_GMODOS,
	Game_ND,
	Game_CSGOZombie
};
#endif

/* Natives */
native GameType:SMAC_GetGameType();
native SMAC_Log(const String:format[], any:...);
native SMAC_LogAction(client, const String:format[], any:...);
native SMAC_Ban(client, const String:reason[], any:...);
native SMAC_PrintAdminNotice(const String:format[], any:...);
native Handle:SMAC_CreateConVar(const String:name[], const String:defaultValue[], const String:description[]="", flags=0, bool:hasMin=false, Float:min=0.0, bool:hasMax=false, Float:max=0.0);
native Action:SMAC_CheatDetected(client, DetectionType:type = Detection_Unknown, Handle:info = INVALID_HANDLE);

/* Forwards */
forward Action:SMAC_OnCheatDetected(client, const String:module[], DetectionType:type, Handle:info);


public SharedPlugin:__pl_smac = 
{
	name = "smac",
	file = "smac.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public __pl_smac_SetNTVOptional()
{
	MarkNativeAsOptional("SMAC_GetGameType");
	MarkNativeAsOptional("SMAC_Log");
	MarkNativeAsOptional("SMAC_LogAction");
	MarkNativeAsOptional("SMAC_Ban");
	MarkNativeAsOptional("SMAC_PrintAdminNotice");
	MarkNativeAsOptional("SMAC_CreateConVar");
	MarkNativeAsOptional("SMAC_CheatDetected");
}
#endif
