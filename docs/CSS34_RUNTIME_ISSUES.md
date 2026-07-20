# SMAC v34 — CSS34 runtime issues (2026-07-20)

Observed on prod `144.24.170.98` / SM `1.11.0.6572` / CS:S v34.

## 1. `smac_wallhack` — failed to load

```
Exception: Invalid TempEntity name: "FireBullets"
  AddTempEntHook → OnPluginStart line ~132
```

**Cause:** wrong TE **string name**, not a broken callback.

| Tried | Result |
|-------|--------|
| `"FireBullets"` | Invalid on CS:S (DoD-style name) |
| `"ShotgunShot"` | Invalid (no space) |
| `"Shotgun Shot"` | Correct for CS:S / CSS34 |

Reference: FrozDark `custom_weapons` (`c:\!gd\Do_062017\custom_weapons (2).sp`):

```sp
AddTempEntHook("Shotgun Shot", Hook_ShotgunShot);
```

Callback `TE_OnFireBullets` itself is fine: reads/writes `m_vecOrigin` (same TE fields as CW: `m_vecOrigin`, `m_vecAngles[0/1]`, `m_iPlayer`).

**Fix:** hook `"Shotgun Shot"` when `gamefolder == cstrike`.

## 2. `smac_fastreload` — error spam

```
Exception: Property "m_bInReload" not found (entity N/weapon_*)
  CheckReload → OnPlayerRunCmd  (every tick with a weapon)
```

**Cause:** CS:S v34 weapons do **not** net `m_bInReload` (CS:GO-era prop). `GetEntProp` throws; floods `errors_*.log`.

**custom_weapons reload approach:** viewmodel **sequence + cycle** timers for anim/sound sync — not a netprop reload flag. Not a drop-in for AC timing, but confirms CSS34 has no reliable `m_bInReload`.

**Fix:** on `cstrike`, detect reload via `IN_RELOAD` edge + `m_iClip1` refill elapsed vs stock min × 0.55. Keep `m_bInReload` path for other games. Fast-shoot still uses `m_flNextPrimaryAttack` (present on CSS).

## 3. Observe mode (local, unpushed)

`smac_observe_new 1`: new detectors log+notify only; legacy (aimbot/eyetest/autotrigger/commands/cvars/client/status) still ban/kick.

## Related remote commits (already on origin)

- `e4e4700` — Fix SM 1.6: natives before `SMAC_UltraReact` stock
- `8813c63` — Ultr@ P1: nospamweapon, cheatcfg, fakelag FL/DDoS/Voice, airstuck FD
