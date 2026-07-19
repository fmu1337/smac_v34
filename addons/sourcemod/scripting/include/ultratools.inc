#if defined _ultratools_included
  #endinput
#endif
#define _ultratools_included

/**
 * Ultr@Tools API (reversed from Ultr@Tools.ext.so 1.0.1, Jan 30 2016)
 * Author tag in binary: "The Terminator" / club-ultra.info
 *
 * Official closed extension is unsafe on SM 1.9+/1.10+ (IBinTools / load crashes).
 * Prefer smac_ultratools.sp stocks when the real .ext is absent.
 *
 * Natives registered (order in .so):
 *   GF, TimerUp, TimerDown, GetCmdStr, SetBan, ClearBanList
 *
 * Forwards seen in binary / SMAC Ultr@ plugins:
 *   OnBanReleased, OnTimerDown, OnTimerUp
 */

#if defined REQUIRE_EXTENSIONS
	#define ULTRATOOLS_REQUIRE
#endif

/**
 * Unknown short native (registered as "GF"). Ultr@ Global references it sparsely.
 * Shim returns 1 when the SP reimplementation is ready.
 */
native GF();

/**
 * Start / bump the per-client ban-release ticker (threaded in real Ultr@Tools).
 */
native TimerUp(client);

/**
 * Cancel the per-client ban-release ticker.
 */
native TimerDown(client);

/**
 * Copy the last captured command / say string (used in Ultra detection logs).
 * @return  true on success
 */
native bool:GetCmdStr(String:buffer[], maxlength);

/**
 * Record an Ultra internal ban entry (separate from SourceMod BanClient).
 * C++ symbol: SetBan(unsigned, int, unsigned)  (_Z6SetBanjij)
 *
 * Observed Ultr@ usage pattern (best effort):
 *   SetBan(client, durationMinutes, banLevel);
 * banLevel aligns with smac_Ban_Level / Advanced ban tiers.
 */
native SetBan(client, duration, banLevel);

/**
 * Wipe the Ultr@Tools internal ban list.
 */
native ClearBanList();

/**
 * Fired when a SetBan timer completes / ban slot released (extension thread).
 */
forward OnBanReleased(client);

/**
 * Fired from Ultr@Tools ticker (binary string OnTimerDown).
 */
forward OnTimerDown(client);

/**
 * Used by SMAC Ultr@ plugins (Global/Core) — may be fired by TimerUp path.
 */
forward OnTimerUp(client);

public Extension:__ext_ultratools =
{
	name = "Ultr@Tools",
	file = "Ultr@Tools.ext",
#if defined ULTRATOOLS_REQUIRE
	required = 1,
#else
	required = 0,
#endif
};

#if !defined ULTRATOOLS_REQUIRE
public __ext_ultratools_SetNTVOptional()
{
	MarkNativeAsOptional("GF");
	MarkNativeAsOptional("TimerUp");
	MarkNativeAsOptional("TimerDown");
	MarkNativeAsOptional("GetCmdStr");
	MarkNativeAsOptional("SetBan");
	MarkNativeAsOptional("ClearBanList");
}
#endif
