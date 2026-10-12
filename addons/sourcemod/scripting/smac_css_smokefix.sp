#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <smac>

/* Plugin Info */
public Plugin:myinfo =
{
	name = "SMAC: Smoke Fix",
	author = SMAC_AUTHOR,
	description = "Denser smoke and an invisible line-of-sight blocker for smac_wallhack (CSS v34)",
	version = SMAC_VERSION,
	url = SMAC_URL
};

/*
 * Smoke on CSS v34 is thin and does not hide players from smac_wallhack. Based on
 * "SMAC v34 Advanced Smoke Fix & Anti-Wallhack" by DjAudition (forum.clientmod.ru, thread 1118),
 * but without its copy of smac_wallhack: on every smoke this module
 *   - spawns extra env_particlesmokegrenade emitters at full stage, so the cloud is denser;
 *   - after smac_smokefix_delay seconds places an invisible solid sphere (rxg/smokevol, r ~150)
 *     over the cloud. It is never sent to clients and collides with nothing, but it is solid for
 *     server traces, so smac_wallhack (MASK_VISIBLE, players skipped) treats players inside or
 *     behind the smoke as hidden and stops transmitting them;
 *   - optionally removes map fog, func_smokevolume and func_dustmotes on round start.
 * smac_wallhack must be loaded and enabled. The model was resized by the author to match the v34
 * cloud; don't replace it with rxg/smokevol from other sources.
 */

#define SMOKE_MODEL			"models/rxg/smokevol.mdl"
#define SMOKE_MODEL_ZOFS	65.5	// Sphere centre above the detonation point
#define SMOKE_BLOCK_END		18.0	// Seconds after detonation: blocker removed (cloud fades from ~17 s)
#define SMOKE_FADE_START	17.0
#define SMOKE_FADE_END		22.0
#define SMOKE_MAX_DENSITY	4

new const String:g_sDownloads[][] =
{
	"materials/rxg/smokevol.vmt",
	"materials/rxg/smokevol.vtf",
	"models/rxg/smokevol.dx80.vtx",
	"models/rxg/smokevol.dx90.vtx",
	"models/rxg/smokevol.mdl",
	"models/rxg/smokevol.phy",
	"models/rxg/smokevol.sw.vtx",
	"models/rxg/smokevol.vvd"
};

new Handle:g_hCvarEnable = INVALID_HANDLE;
new Handle:g_hCvarDelay = INVALID_HANDLE;
new Handle:g_hCvarDensity = INVALID_HANDLE;
new Handle:g_hCvarMapFog = INVALID_HANDLE;

public OnPluginStart()
{
	g_hCvarEnable = SMAC_CreateConVar("smac_smokefix", "1", "Smoke fix: denser smoke and an invisible blocker that hides players in smoke from smac_wallhack. (0:Disabled, 1:Enabled)", _, true, 0.0, true, 1.0);
	g_hCvarDelay = SMAC_CreateConVar("smac_smokefix_delay", "5.0", "Seconds after detonation until the blocker is placed. Too low and players vanish before the cloud has grown.", _, true, 0.0, true, 15.0);
	g_hCvarDensity = SMAC_CreateConVar("smac_smokefix_density", "2", "Extra smoke emitters per grenade.", _, true, 0.0, true, float(SMOKE_MAX_DENSITY));
	g_hCvarMapFog = SMAC_CreateConVar("smac_smokefix_mapfog", "1", "Remove env_fog_controller, func_smokevolume and func_dustmotes on round start.", _, true, 0.0, true, 1.0);

	HookEvent("smokegrenade_detonate", Event_SmokeDetonate, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

public OnMapStart()
{
	PrecacheModel(SMOKE_MODEL, true);

	for (new i = 0; i < sizeof(g_sDownloads); i++)
	{
		AddFileToDownloadsTable(g_sDownloads[i]);
	}
}

public Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (!GetConVarBool(g_hCvarEnable) || !GetConVarBool(g_hCvarMapFog))
		return;

	SmokeFix_KillAll("env_fog_controller");
	SmokeFix_KillAll("func_smokevolume");
	SmokeFix_KillAll("func_dustmotes");
}

public Event_SmokeDetonate(Handle:event, const String:name[], bool:dontBroadcast)
{
	if (!GetConVarBool(g_hCvarEnable))
		return;

	decl Float:vPos[3];
	vPos[0] = GetEventFloat(event, "x");
	vPos[1] = GetEventFloat(event, "y");
	vPos[2] = GetEventFloat(event, "z");

	new iDensity = GetConVarInt(g_hCvarDensity);

	for (new i = 0; i < iDensity; i++)
	{
		SmokeFix_SpawnEmitter(vPos);
	}

	new iEntity = CreateEntityByName("prop_physics_multiplayer");

	if (iEntity != -1)
	{
		vPos[2] += SMOKE_MODEL_ZOFS;
		SetEntityModel(iEntity, SMOKE_MODEL);
		TeleportEntity(iEntity, vPos, NULL_VECTOR, NULL_VECTOR);

		new ref = EntIndexToEntRef(iEntity);
		new Float:fDelay = GetConVarFloat(g_hCvarDelay);

		// Blocker removal is scheduled from detonation, so a delay past it never places one.
		if (fDelay < SMOKE_BLOCK_END)
			CreateTimer(fDelay, Timer_StartBlocker, ref, TIMER_FLAG_NO_MAPCHANGE);

		CreateTimer(SMOKE_BLOCK_END, Timer_Kill, ref, TIMER_FLAG_NO_MAPCHANGE);
	}
}

SmokeFix_SpawnEmitter(const Float:vPos[3])
{
	new iEntity = CreateEntityByName("env_particlesmokegrenade");

	if (iEntity == -1)
		return;

	SetEntProp(iEntity, Prop_Data, "m_CurrentStage", 1);
	SetEntPropFloat(iEntity, Prop_Data, "m_FadeStartTime", SMOKE_FADE_START);
	SetEntPropFloat(iEntity, Prop_Data, "m_FadeEndTime", SMOKE_FADE_END);
	DispatchSpawn(iEntity);
	ActivateEntity(iEntity);
	TeleportEntity(iEntity, vPos, NULL_VECTOR, NULL_VECTOR);

	CreateTimer(SMOKE_FADE_END, Timer_Kill, EntIndexToEntRef(iEntity), TIMER_FLAG_NO_MAPCHANGE);
}

public Action:Timer_StartBlocker(Handle:timer, any:ref)
{
	new iEntity = EntRefToEntIndex(ref);

	if (iEntity == INVALID_ENT_REFERENCE)
		return Plugin_Stop;

	DispatchSpawn(iEntity);
	SetEntityMoveType(iEntity, MOVETYPE_NONE);
	AcceptEntityInput(iEntity, "DisableMotion");
	AcceptEntityInput(iEntity, "DisableShadow");
	SDKHook(iEntity, SDKHook_ShouldCollide, Hook_ShouldCollide);

	// Never sent to clients: they don't predict against it and can't find it.
	SetEdictFlags(iEntity, (GetEdictFlags(iEntity) & ~FL_EDICT_ALWAYS) | FL_EDICT_DONTSEND);

	return Plugin_Stop;
}

public bool:Hook_ShouldCollide(entity, collisiongroup, contentsmask, bool:originalResult)
{
	// Players, bullets, grenades and dropped weapons pass through. Plugin traces with their own
	// filter (smac_wallhack) don't ask this hook, so the sphere still blocks them.
	return false;
}

public Action:Timer_Kill(Handle:timer, any:ref)
{
	new iEntity = EntRefToEntIndex(ref);

	if (iEntity != INVALID_ENT_REFERENCE)
	{
		AcceptEntityInput(iEntity, "Kill");
	}

	return Plugin_Stop;
}

SmokeFix_KillAll(const String:classname[])
{
	new iEntity = -1;

	while ((iEntity = FindEntityByClassname(iEntity, classname)) != -1)
	{
		AcceptEntityInput(iEntity, "Kill");
	}
}
