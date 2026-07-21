# SMAC Testbench

Admin-only cheat-pattern injector for live CSS34 QA. Source: `addons/sourcemod/scripting/0_smac_testbench.sp`.

**Do not leave enabled on production.** Prefer `plugins/disabled/0_smac_testbench.smx`.
`smac_immunity.smx` is also optional and must stay in `plugins/disabled/`
unless an operator explicitly wants flag-`o` admins excluded from detections.

## Why `0_` prefix?

SourceMod loads plugins alphabetically. The testbench must run `OnPlayerRunCmd` **before** `smac_*` detectors so injected angles/buttons/tickcount are visible to them.

## Setup

```
sm_smactest setup
# soft cvars + bots + plant you in front of a frozen enemy
sm_smactest flick
```

Or step by step: `soft` → `bots` → join opposite team → `setup` → scenario.

Aim scenarios **freeze your movement**, plant you ~200u in front of a bot, and aim at their **head**. You should see snaps onto the bot, not sideways walking into empty space.

## Commands

| Command | Effect |
|---------|--------|
| `sm_smactest setup` | soft + bots + plant on enemy |
| `sm_smactest soft` | Notice-only detector cvars |
| `sm_smactest bots` | Fill bots, stop them |
| `sm_smactest <scenario>` | Inject pattern on **you** |
| `sm_smactest cycle` | flick → lock → silent → trigger → aimsnap |
| `sm_smactest fire <name>` | Call `SMAC_CheatDetected` only |
| `sm_smactest stop` | Stop |

## Realistic aim scenarios (preferred)

| Name | What you see | Hits |
|------|----------------|------|
| `flick` | Look away → one-tick snap to head → fire → settle | Fast-AIM, aimsnap, aimkill, AGTAF |
| `lock` | Glue to head while bot is nudged sideways + spray | Aimlock, AutoFire, AGT |
| `silent` | Client view stays off-target; shots go into head (A-B-A) | pSilent, AMSAF |

## Other scenarios

| Name | Hits |
|------|------|
| `trigger` / `autofire` | Advanced Trigger / AutoFire (planted) |
| `psilent` / `aimsnap` | Same family as silent / flick |
| `bhop` / `fastrun` | FD bhop / overspeed |
| `teleport` / `tpfast` | SpeedTeleport |
| `norecoila` / `norecoilb` | Mode A (zero punch) / Mode B (perfect RCS mirror) |
| `wish` / `backtrack` / `cmdspike` / `fastshoot` | Movement / tick abuse |

## Cvars

- `smac_testbench` `1` — allow commands
- `smac_testbench_maxtime` `25` — auto-stop seconds
