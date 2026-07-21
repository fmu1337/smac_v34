#if defined _smac_wallhack_included
  #endinput
#endif
#define _smac_wallhack_included

/**
 * Returns whether subject is currently considered visible to viewer
 * by smac_wallhack (PVS/trace cache). Used by Strike Back detectors.
 *
 * @param viewer	Client index receiving transmit decisions.
 * @param subject	Client index being transmitted.
 * @return			True if visible / unknown / wallhack off.
 */
native bool:SMAC_IsClientVisible(viewer, subject);

public SharedPlugin:__pl_smac_wallhack =
{
	name = "smac_wallhack",
	file = "smac_wallhack.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public __pl_smac_wallhack_SetNTVOptional()
{
	MarkNativeAsOptional("SMAC_IsClientVisible");
}
#endif
