# SMAC Testbench

Admin-only cheat-pattern injector for live CSS34 QA. Source: `addons/sourcemod/scripting/0_smac_testbench.sp`.

**Do not leave enabled on production.** Prefer `plugins/disabled/0_smac_testbench.smx`.
`smac_immunity.smx` is also optional and must stay in `plugins/disabled/`
unless an operator explicitly wants flag-`o` admins excluded from detections.

## Why `0_` prefix?

SourceMod loads plugins alphabetically. The testbench must run `OnPlayerRunCmd` **before** `smac_*` detectors so injected angles/buttons/tickcount are visible to them.

## Setup

1. Compile (`scripts/compile-all.sh`) and move `0_smac_testbench.smx` into `plugins/` (or `sm plugins load`).
2. You need `ADMFLAG_ROOT` (`sm_smactest`).
3. Bots are **targets only** — detectors skip `IsFakeClient`.

```
sm_smactest soft
sm_smactest bots
# join opposite team, stay alive, look roughly at bots
sm_smactest psilent
```

Watch admin chat notices and `addons/sourcemod/logs/SMAC.log`.

## Commands

| Command | Effect |
|---------|--------|
| `sm_smactest soft` | Notice-only detector cvars (no kick/ban) |
| `sm_smactest bots` | `bot_quota 4`, `bot_stop 1`, … |
| `sm_smactest <scenario>` | Inject pattern on **you** |
| `sm_smactest cycle` | Short sequence of several sims |
| `sm_smactest fire <name>` | Call `SMAC_CheatDetected` only (pipeline/immunity) |
| `sm_smactest stop` | Stop |
| `sm_smactest status` | Active mode |

## Scenarios

| Name | Hits |
|------|------|
| `trigger` | Advanced Trigger |
| `autofire` | Advanced AutoFire |
| `psilent` | pSilent A-B-A + attack |
| `aimsnap` | StAC-style quiet/snap/quiet |
| `bhop` | FD_BHOP land→leave (flag spoof; may be flaky) |
| `fastrun` | FD Fast Run overspeed |
| `teleport` / `tpfast` | SpeedTeleport / Fast Detect |
| `norecoila` / `norecoilb` | NoRecoil Mode A/B |
| `wish` | Magic wishspeed (movesanity/SSAC) |
| `backtrack` / `cmdspike` | tickcount / cmdnum abuse |
| `fastshoot` | Early `m_flNextPrimaryAttack` edges |

Not auto-simulated: **SpeedLimit** (needs real cmd flood), **SoundESP react**, **AimKill** (use `fire aimkill` for pipeline).

## Cvars

- `smac_testbench` `1` — allow commands
- `smac_testbench_maxtime` `25` — auto-stop seconds
