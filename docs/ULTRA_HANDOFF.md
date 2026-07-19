# Ultr@ → SMAC v34 handoff

Документ для агента, у которого есть **доступ к SMAC Ultr@** (исходники / незапакованные `.sp` / рабочий сервер с Ultr@).  
Целевой репозиторий: `fmu1337/smac_v34`, ветка PR: `cursor/port-xmazax-smac-4b55` (PR #7).  
Стек: **CSS v34**, SourceMod ~1.6, **старый** SourcePawn (`new`/`:`), автор модулей `SMAC_AUTHOR` = `Danyas`.

---

## Контекст (что уже сделано у нас)

Мы **не** имеем чистого исходника Ultr@. Плагины обфусцированы **SmartPawn** (Timocop): renaming, CF obfuscation, function proxies, invalid debug. Lysis даёт ~98k строк каши; `PoweredBySmartPawn` в publics подтверждён.

Уже портировано (rewrites, soft `*_ban` часто `0`):

| Модуль v34 | Ultr@ идея |
|------------|------------|
| `smac_ultra_aim` | PRG 301–304, AGT 288/299, AGTAF 88/99, Tr 188/199, Null 200/201, AGTWS 100, AMSAF 101, RCS-F/H cvars |
| `smac_norecoil` | No Recoil Mode A/B (punch + absorb) |
| `smac_fakelag` | `smac_FL_Ctrl` / DDoS-style loss-choke (**выкл** loss/choke=0) |
| `smac_firemacro` | `smac_method_2X_*`, Fast AIM detect |
| `smac_backtrack` | Mode A detect + Mode B patch; + StAC cmdnum spike |
| `smac_fastreload` | «Fast Reload or Shooting of Weapon» |
| `smac_strikeback` | KnifeBot/Aim UsingWH (102/103) |
| `smac_teleport` | SpeedTeleport signed + Fast Detect |
| `smac_advtrigger` | Advanced Trigger / Advanced AutoFire |
| `smac_fdbhop` | `smac_FD_BHOP` Fast Detect + Fast Run |
| `smac_speedlimit` | `smac_SpeedLimitDetect` + `smac_SpeedUp` |
| `smac_aimkill` | AIM_Kill soft escalate |
| `smac_soundesp` | SoundESP LOS sound strip + soft react |
| `smac_ultratools` | Ultr@Tools natives shim (`SetBan`/`ClearBanList`/…) |
| `smac_entityspam` | Control_Entity / weapon spam |
| `smac_client` | sens spam/min/max, impulse extras |
| antiflash/antismoke/wallhack | частично усилены |

См. также `docs/ULTRA_P0_MINING.md` (алгоритмы P0).

**Не тащить:** WH Ignore API, UCP, SoftDetector/AntiDLL без ext, 1:1 dump Ultr@.

---

## Приоритет: что нужно добыть из Ultr@

Агенту с Ultr@: для каждого пункта — **алгоритм** (псевдокод / условия / пороги / события), не обязательно копипаст. Потом мы перепишем под v34.

### P0 — высокий приоритет (ещё нет или слабо)

1. **`smac_AdvancedTrigger_*` / `smac_AdvancedAutoFire_*`**  
   Чем отличаются от обычного autotrigger/triggerbot? Какие окна тиков, кнопки, оружие, FP-фильтры?

2. **`BunnyHop: Fast Detect` / `smac_FD_BHOP`**  
   Логика «Fast Detect» vs обычный BunnyHop/Auto-Jump. Отличие от нашего `smac_ssac` timed-bhop / `smac_movesanity`.

3. **`Teleport Hack: Fast Detect` + `smac_SpeedTeleport` / `smac_SpeedLimitDetect` / `smac_SpeedUp`**  
   Точные формулы (units/tick? abs velocity? teleport vs speedhack). У нас teleport только грубый dist-cvar.

4. **`No Recoil [Active Mode:A]` vs `[Mode:B]`**  
   Чем A отличается от B (punch / eye / seed / только при hurt)? Наш `smac_norecoil` упрощён.

5. **`PSilent [Active Mode]` Ultr@** vs наш StAC `smac_psilent`  
   Совпадает ли A-B-A или Ultr@ смотрит другое (seed, cmdnum, tick)?

6. **`smac_AIM_Kill`**  
   Что именно: килл после aim-детекта? автобан на kill event? пороги?

7. **`smac_SoundESP`**  
   Как блокирует/детектит SoundESP на CSS (usermsg? emit sound filter?). Нужен ли только blocker или detection.

8. **`Fast Reload or Shooting`** — точная логика  
   Reload table? `m_flNextPrimaryAttack` streak? Наш `smac_fastreload` — эвристика 55% stock reload.

### P1 — средний

9. **`smac_NoSpamWeapon_MaxW`** — окно, счётчик, kick/ban семантика `-N` vs `+N` (Ultr@ kick/ban encoding).  
10. **`smac_NoS_NoR` / `smac_NoR_Ban`** — связь с NoRecoil / NoSpread.  
11. **`Airstuck: Fast Detect`** vs обычный airstuck (`smac_Airstuck_reaction`) — отличие от нашего SSAC airstuck.  
12. **`smac_Voice_Ctrl` / `smac_DDoS_Ctrl` / `smac_FL_Ctrl`** — точные пороги loss/choke/voice.  
13. **`smac_eyetest_reaction_Advanced`** — что ещё кроме Backtrack A/B входит в «Advanced» eyetest.  
14. **Spinhack Ultr@** — если отличается от stock SMAC (у Ultr@ в доках встречалось 900°/s × 5s).  
15. **`smac_css_CheatCFG`** — список признаков / cvar checks.

### P2 — низкий / опционально

16. `smac_Check_Hack` / `smac_Check_Changer` / `smac_Check_CheatsC` / `smac_indirect_cheat` — что реально проверяется на клиенте (без закрытых DLL).  
17. `smac_Lock_Adm`, `smac_ClanTag_Spam`, status/ping prot — если есть нетривиальная логика.  
18. **Ultr@Tools.ext** — **done:** see `docs/ULTRATOOLS_API.md`, `include/ultratools.inc`, shim `smac_ultratools.sp` (natives when closed `.ext` absent).

---

## Формат ответа агента (обязательно)

Для **каждого** добытого детектора:

```markdown
### <Имя Ultr@ / cvar>
- **Файлы:** (Global.sp / Client.sp / … + функции)
- **Триггер:** событие / OnPlayerRunCmd / timer
- **Условие детекта:** (формула, пороги, streak)
- **Игноры / FP-фильтры:** лаг, teleport, spawn, weapon…
- **Наказание:** warning / kick / ban mapping (−N / +N Ultr@)
- **Псевдокод:** 15–40 строк
- **Порт в v34:** новый `smac_*.sp` или правка существующего; soft ban default
- **Риски FP:** …
```

В конце: краткий **diff «Ultr@ умеет / v34 ещё нет»**.

---

## Ограничения порта в v34

- Только CSS v34 + old SP; без transitional syntax.
- `SMAC_CheatDetected` + enums в `include/smac.inc`; phrases EN+RU.
- High-FP → `*_ban` default `0` (лог/kick).
- Не коммитить чужой Ultr@ source 1:1; rewrite + attribution in header comment.
- Не трогать WH Ignore / UCP.
- Компилить через `scripts/compile-all.sh` (или project `spcomp` + includes).
- После правок: commit + push на `cursor/port-xmazax-smac-4b55`, обновить PR #7.

---

## Как копать Ultr@ (если есть только .smx)

1. FFPS+zlib: снять compression → секции `.code/.data/.names/.publics`.  
2. В `.data` plaintext labels и все `smac_*` cvar names уже лежат.  
3. SmartPawn: CF ломает Lysis; ищи по string xref / runtime dump после `OnPluginStart`.  
4. Лучший путь при наличии **исходников или незапакованного `.sp`**: читать функции вокруг cvar hooks и detection strings выше.  
5. При наличии **живого сервера с Ultr@**: логировать admin notices + demo на известных читах, сопоставить с cvar’ами.

---

## Готовый промпт (скопировать агенту)

См. `docs/ULTRA_AGENT_PROMPT.txt`.
