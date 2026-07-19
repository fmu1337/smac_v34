# Ultr@ P0 mining → v34 port notes

Sources: live `001_SMAC_Global.smx` (FFPS+zlib unpack), `smac.cfg` comments, `.data` labels (`BunnyHop: Fast Detect`, `No Recoil: Active Mode`, `g_hCvarSpeedLimitDetect`…). SmartPawn CF — no clean Lysis. Rewrites only.

### smac_AdvancedTrigger_* / Advanced AutoFire
- **Файлы:** Ultr@ Global; v34 `smac_advtrigger.sp`
- **Триггер:** `OnPlayerRunCmd` + eye trace
- **Условие:** AdvTrigger = `IN_ATTACK` edge on first tick of enemy acquire (×6); AdvAutoFire ≈ 1s hold-fire while lock ≈ hold window
- **Игноры:** spawn/teleport grace, knife/nades
- **Наказание:** Ultr@ signed `Warning`/`Ban` (−N kick / +N ban); soft ban default `0`
- **Порт:** new module; cvars keep Ultr@ names
- **FP:** good players flick-shot; keep ban=0 on pub

### BunnyHop: Fast Detect / smac_FD_BHOP
- **Файлы:** Global string `BunnyHop: Fast Detect` + Fast Run; v34 `smac_fdbhop.sp`
- **Триггер:** ground land edges + XY speed
- **Условие:** land→land ≤0.12s at ≥250 u/s ×12; Fast Run ≥320 u/s ×40 ticks
- **Игноры:** noclip/ladder; default mode `0` (surf)
- **Наказание:** `0/1/2/3` = off/notice/kick/ban (Ultr@)
- **Отличие от ssac timed-bhop:** no jump-button required; separate Fast Run
- **FP:** surf/bhop maps — leave `smac_FD_BHOP 0`

### Teleport / SpeedTeleport / SpeedLimit / SpeedUp
- **Teleport:** `smac_teleport.sp` — signed `smac_SpeedTeleport` + Fast Detect mid-jumps 400–999u ×3
- **SpeedLimit:** `smac_speedlimit.sp` — cmds/sec vs `tickrate * smac_SpeedUp`; paired with `smac_SpeedLimitDetect` signed count
- **FP:** lag spikes → soft defaults `0`

### No Recoil Mode A vs B
- **Файлы:** `smac_norecoil.sp`; cvars `smac_NoS_NoR`, `smac_NoR_Ban`
- **Mode A:** punch magnitude &lt; 0.08 ×10 shots
- **Mode B:** punch pitch &lt; −0.5 but eye pitch never absorbs (×12)
- **FP:** Mode B on high ping — ban soft `0`

### PSilent Active Mode
- **Файлы:** `smac_psilent.sp` + `smac_psilent_ultra 1`
- **Условие:** StAC A-B-A **and** `IN_ATTACK` on silent B frame
- **FP:** lower than raw ABA

### smac_AIM_Kill
- **Файлы:** `smac_aimkill.sp`
- **Условие:** kill within 150ms of aim-snap fire and first-see &lt; 80ms
- **Наказание:** soft `smac_AIM_Kill 0`

### smac_SoundESP
- **Файлы:** `smac_soundesp.sp`
- **Blocker:** `AddNormalSoundHook` drops enemy footsteps/weapons without LOS
- **Detect (soft):** hard turn toward invisible shooter &lt;120ms after fire
- **Без Ultr@Tools natives**

### Fast Reload / Shooting
- Already in `smac_fastreload.sp` (stock reload table ×0.55 + early `m_flNextPrimaryAttack`)
- Maps Ultr@ `Fast Recharge or Shooting of Weapon` / CheatCFG family

---

## Diff: Ultr@ умеет / v34 ещё нет

| Ultr@ | v34 now |
|-------|---------|
| Advanced Trigger / AutoFire | **added** `smac_advtrigger` |
| FD_BHOP + Fast Run | **added** `smac_fdbhop` |
| SpeedTeleport signed + Fast Detect | **enhanced** `smac_teleport` |
| SpeedLimitDetect + SpeedUp | **added** `smac_speedlimit` |
| NoRecoil A/B | **enhanced** `smac_norecoil` |
| PSilent Active | **enhanced** `smac_psilent_ultra` |
| AIM_Kill | **added** soft `smac_aimkill` |
| SoundESP | **added** blocker+soft react |
| Fast Reload | already present |
| WH Ignore / UCP / SoftDetector DLL | **still not** (by design) |
| Ultr@Tools natives full list | **documented + SP shim** `smac_ultratools` / `ULTRATOOLS_API.md` |

## Live CSS test plan
1. Compile `scripts/compile-all.sh`, load new smx on CSS34 test.
2. AdvTrigger/AutoFire: bot + trigger script vs legit AWP flick.
3. FD_BHOP: only on pub/DM — confirm surf stays `0`.
4. SpeedTeleport: set `-1500`, rocket-jump / nade boost false positives.
5. SpeedUp: fake packet flood vs 100+ ping.
6. NoRecoil A/B: null-recoil cfg vs spray transfer.
7. SoundESP blocker: hear test through wall with/without module.
