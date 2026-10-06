# PR #7: откуда что взято, состояние, план возврата

Документ-закладка по PR [fmu1337/smac_v34#7](https://github.com/fmu1337/smac_v34/pull/7)
(ветка `cursor/port-xmazax-smac-4b55`, draft, 32 коммита, ~10k строк, 96 файлов).
Ревью сделано 2026-10-05 на голове `9e00332`. PR не смержен; этот файл живёт в master-линии
отдельно, чтобы к работе можно было вернуться без PR.

Как поднять ветку локально:

```sh
git fetch origin cursor/port-xmazax-smac-4b55
git worktree add ../smac_pr7 origin/cursor/port-xmazax-smac-4b55
```

Документы, которые лежат внутри самого PR (читать оттуда):
`docs/ULTRA_HANDOFF.md`, `docs/ULTRA_P0_MINING.md`, `docs/ULTRA_P1_MINING.md`,
`docs/ULTRATOOLS_API.md`, `docs/CSS34_RUNTIME_ISSUES.md`, `docs/TESTBENCH.md`,
`addons/sourcemod/configs/smac_observe.cfg`.

---

## 1. Источники

Лицензии ниже: «✔» — GPLv3 заявлена явно; «GPL (SM)» — явной лицензии нет или автор её не публиковал, но это плагин/расширение SourceMod, а значит GPLv3 по условиям SourceMod (см. раздел 1.1).

| # | Источник | Где | Лицензия | Что взято |
|---|----------|-----|----------|-----------|
| S1 | **xMaZax/SMAC 0.8.7.3** (форк SMAC, Silenci0) | https://github.com/xMaZax/SMAC | GPLv3 ✔ (как SMAC) | SourceBans/SB++ в `SMAC_Ban`, `MAXPLAYERS+1`, `smac_validate_auth`, achievement spam, `give` block, `smac_anticmdspam_kick`, eyetest compat + ослабленная проверка tickcount, ladder-skip в autotrigger, `IsClientInGame` в speedhack |
| S2 | **Cheat-Acid GRAB** (сборник чужих AC) | https://github.com/DJPlaya/Cheat-Acid | у каждой папки своя; всё — плагины SM → GPL (SM) | транзитный источник для S3–S8 |
| S3 | **Little Anti-Cheat** (J_Tanzanite) | через S2, upstream `lilac_aimlock.sp`, `lilac_stock.sp` | GPLv3 ✔ | `smac_aimlock` (алгоритм почти 1:1), идея chat-clear, backtrack patch |
| S4 | **StAC** (sapphonie / stephanie) | через S2 `GRAB/StAC/scripting/stac.sp` | GPLv3 ✔ | `smac_psilent` (A-B-A), `smac_aimsnap`, cmdnum spike в `smac_backtrack`, `cl_interpolate` в cvars |
| S5 | **2x Anti-Aimbot Source** (simoneaolson) | через S2 `GRAB/2x Anti-Aimbot Source/sm_2x-AntiAimbot.sp` | GPL (SM) | `smac_aimorigin` |
| S6 | **SMAC official `_unsupported/smac_immunity.sp`** (GoD-Tony) | через S2 | GPLv3 ✔ | `smac_immunity` |
| S7 | **Forlix FloodCheck** (`ff_hardflood`, `ff_voiceloopback`) | через S2 / FFC | GPL (SM) | hardflood и voice_loopback в `smac_client` |
| S8 | **CowAC** / **Bash** / **Oryx** / **Ash** | через S2 | GPL (SM) | идеи для `smac_strafe`, `smac_triggerbot`, `smac_turncheck`, `smac_strafesync`, `smac_movesanity` |
| S9 | **HOTGUARD**, **Cow Private** | приватные/слитые сборки | GPL (SM); распространялось без исходников — нарушение со стороны авторов | `smac_movesanity`, `smac_turncheck`, LOS в `smac_css_antismoke`, cvar-проверки `cl_pitch*`, `net_fake*` |
| S10 | **CA-ServerProtect / CA-ClientProtect** (Cheat-Acid) | через S2 | GPL (SM) | `smac_serverlock` |
| S11 | **SSAC v2** (null138, hlmod) | hlmod.ru | GPL (SM) | `smac_ssac` |
| S12 | **ProtectCMDS** (WeSTManCoder) | ? | GPL (SM) | список блокируемых команд (`q_sndrcn`, `npc_*`, …) в `smac_commands` |
| S13 | **SauRay** (toomuchvoltage) | https://github.com/toomuchvoltage/SauRay | SP-часть — GPL (SM); ядро (GPU/HighOmega) — лицензия репозитория, мы его не брали | sound jitter и TE jitter в `smac_wallhack`, angle-scaled flash в `smac_css_antiflash` |
| S14 | **SMAC Ultr@** R51/R52 (The Terminator, club-ultra.info) | закрытый, обфусцирован SmartPawn; распакованный `001_SMAC_Global.smx` (FFPS+zlib), `.data`-строки, `smac.cfg`, `smacr52fix.txt`, описание автора на counter-strike.cn.ua / sourceplay.ru | GPL (SM); распространялось без исходников (SmartPawn-обфускация) — нарушение со стороны авторов | идеи и имена cvar всех `Ultr@`-модулей (см. таблицу 2); `smac_cmd_block.cfg` в `smac_commands` |
| S15 | **Ultr@Tools.ext.so 1.0.1** | закрытое расширение, разобрано по бинарю | GPL (SM) — расширение линкуется с SourceMod; бинарь без исходников | `include/ultratools.inc`, `smac_ultratools.sp` |
| S16 | **FrozDark custom_weapons** | локальный файл автора PR | GPL (SM) | имя TE `"Shotgun Shot"` для CS:S |

### 1.1 Лицензии: как это устроено

- **SourceMod — GPLv3** с исключением AlliedModders: разрешено линковать с Source Engine, SourcePawn JIT
  и модами Valve. Официальная позиция AlliedModders (`LICENSE.txt` в SourceMod, sourcemod.net/license.php):
  плагины и расширения, собранные с include-файлами/API SourceMod, — производные работы и обязаны быть
  GPL-совместимыми. Это и есть основание «всё, что под SM, — GPL».
- Следовательно, Ultr@ (S14), Ultr@Tools.ext (S15), HOTGUARD и Cow Private (S9), раздаваемые только
  бинарями (да ещё обфусцированными), **сами нарушают** условия SourceMod. Претензий у них к нам по сути нет.
- Оговорка для честности: нарушение GPL автором не делает его код public domain и не выдаёт лицензию
  автоматически каждому — права всё равно у автора, требовать соблюдения GPL может правообладатель
  SourceMod. Но это теоретический риск: подавать в суд за переписанный код, защищая заведомо
  нарушающий продукт, для таких авторов бессмысленно.
- Важнее: **алгоритмы и идеи авторским правом не охраняются вообще**, охраняется конкретный текст кода.
  Модули PR — переписанные реализации; имена cvar, коды режимов и пороги — функциональные параметры.
  Так что по S9/S14/S15 вопрос закрыт.

**Что реально надо сделать по лицензиям — это про наш репозиторий:**

1. В репозитории **нет файла `LICENSE`**, а шапки GPL от оригинального SMAC (GoD-Tony, GPLv3) из
   исходников вырезаны. SMAC v34 — производная SMAC, значит сам обязан быть GPLv3: положить
   `LICENSE` (GPLv3) и вернуть copyright-уведомления (GoD-Tony / SMAC team, дальше Danyas).
2. Где код перенесён близко к тексту (`smac_aimlock` из LilAC, `smac_psilent`/`smac_aimsnap` из StAC,
   `smac_immunity` из SMAC), сохранить copyright авторов и пометку GPLv3 в шапке — сейчас стоит только
   «ported from», без лицензионного уведомления.
3. Раздавать `.smx` только вместе с исходниками (у нас и так открытый репозиторий — ок).

Отдельно: `ULTRA_AGENT_PROMPT.txt` и `.gitignore` с `_ultra_mine/` — рабочий мусор агента, не продукт.

---

## 2. Карта модулей

Колонки: **Источник** — из таблицы 1; **Коммит** — где появился; **Дефолт** — что включено из коробки;
**Вердикт**: ✅ оставить, 🔧 чинить, ❌ выкинуть/переделать.

### 2.1 Новые модули

| Модуль | Источник | Коммит | Дефолт | Вердикт | Главное из ревью |
|--------|----------|--------|--------|---------|------------------|
| `smac_aimlock` | S3 | 530a375 | on, ban 0 | 🔧 | таймер с `NO_MAPCHANGE` умирает после смены карты; `processed >= 5` — игроки с индексом 6+ не проверяются никогда |
| `smac_aimorigin` | S5 | 530a375 | **on**, ban 0 | ❌/🔧 | дробь (каждая дробина — `player_hurt`) и стрельба по стоящему без движения мыши → детект |
| `smac_psilent` | S4 | 530a375 | on, ban 0 | ✅ | один из самых чистых; декремент по таймеру 1200 с теряется на смене карты |
| `smac_immunity` | S6 | 530a375 | в сборке → `disabled/`, но в `plugins/` лежит старый `.smx` | 🔧 | убрать противоречие |
| `smac_strafe` | S8 | 46f944b | on, ban 0 | 🔧 | reason 6: ходьба с Shift (sidemove 208) = «illegal sidemove» |
| `smac_triggerbot` | S8 | 46f944b | on, ban 0 | 🔧 | счётчик не сбрасывается за сессию; дубль `smac_advtrigger` |
| `smac_serverlock` | S10 | 46f944b | **on** | 🔧 | молча включает `sv_cheats 0` и `sv_allowupload 0` (спреи) — сделать opt-in |
| `smac_movesanity` | S8, S9 | d4d5ef6 | on, ban 0 | 🔧 | Shift по диагонали → wishspeed; scroll-bhop → perfect bhop; быстрые клики пистолетом → autoshoot; лог `IN_BULLRUSH` каждый тик |
| `smac_strafesync` | S8 | d4d5ef6 | on, ban 0 | ✅? | глубоко не смотрел |
| `smac_turncheck` | S8, S9 | d4d5ef6 | on, ban 0 | 🔧 | mouse-aim зависит от `mouse[]` (см. вопрос Q1); angle-delay ловит A/D в прыжке без мыши |
| `smac_strikeback` | S14 | 702b236 | on, warn 1/5, ban 0 | 🔧 | прострелы стен = «aim through WH»; видимость серверная, попадание лагокомпенсировано; нет затухания |
| `smac_entityspam` | S14 | 702b236 | on (`mode 1`) | ❌ | в `OnEntityCreated` `m_hOwnerEntity` ещё пуст — скорее всего мёртвый; алиас `smac_Control_Entity` не читается |
| `smac_teleport` | S14 | 702b236 / 15343f1 | off | ✅ | FP от телепортов других плагинов (`TeleportEntity`), но выключен |
| `smac_ssac` | S11 | 0c8a2be | частично on | 🔧 | FastRun шлёт notice каждый тик; LagExploit без проверки лага; `smac_ssac_airstuck_ban` мёртвый; mouseless aim — Q1 |
| `smac_norecoil` | S14 | 4cd0d41 | on, ban 0 | 🔧 | `HasEntProp` ломает сборку SM 1.6 (`smac_norecoil.sp:255`) |
| `smac_fakelag` | S14 | 4cd0d41 / 8813c63 | FL/DDoS off, **Voice on** | 🔧 | меряет `NetFlow_Outgoing` (сервер→клиент) — не то направление; Voice мутит за легальный `voice_loopback`, дубль `smac_client`, мут не снимается |
| `smac_firemacro` | S14 | 4cd0d41 | on, ban 0 | 🔧 | нет AUG/SG552 в списке зум-оружия; Fast-AIM ложно срабатывает при fps < tickrate |
| `smac_ultra_aim` | S14 | 1cd4f66, 52aa6a6 | **on**, ban 0 | ❌/🔧 | реконструкция по рекламе автора и меткам `.data`, то есть догадки; почти всё зависит от `mouse[]` (Q1); O(N²) на каждый тик |
| `smac_backtrack` | S3, S4, S14 | 343e3cb | **mode 3** (patch on) | 🔧 | Mode B переписывает `tickcount` всем после любой аномалии; cmdspike 32 без проверки лага; алиас `smac_eyetest_reaction_Advanced` мёртвый |
| `smac_fastreload` | S14 | 343e3cb | on, ban 0 | 🔧 | R + переключение на пистолет = «fast reload»; `fastshoot` мёртвый (серия не может дойти до 4) |
| `smac_aimsnap` | S4 | 343e3cb | on, ban 0 | ✅ | добавить проверку лага, как в StAC |
| `smac_advtrigger` | S14 | 15343f1 / 756a67d | warn on, ban 0 | 🔧 | Trigger — дубль `smac_triggerbot`, без сброса; AutoFire после 756a67d нормальный |
| `smac_aimkill` | S14 | 15343f1 | ban 0 | ✅? | не копал |
| `smac_fdbhop` | S14 | 15343f1 | off (observe cfg ставит 1) | ✅? | на surf/bhop-картах держать 0 |
| `smac_speedlimit` | S14 | 15343f1 | off | ✅ | дубль speedhack/DDoS |
| `smac_soundesp` | S14 | 15343f1 | **block on** | ❌ | вырезает шаги и выстрелы врагов без прямой видимости — ломает базовую механику CS |
| `smac_ultratools` | S15 | 9fc9c4c | on | ❌ | никто в репо не использует; имена нативов `GF`, `SetBan` могут конфликтовать |
| `0_smac_testbench` | своё | 48e2643 / 9da5a1d | `disabled/` | 🔧 | меняет `bot_quota`, `mp_limitteams`, `mp_autoteambalance`, `smac_*` без восстановления; инъекция на сервере (тест не доказывает работу на клиенте); может забанить админа через legacy `smac_aimbot` |
| `smac_nospamweapon` | S14 | 8813c63 | off | 🔧 | нет затухания + порог применяется дважды (кик после N×N дропов) |
| `smac_cheatcfg` | S14 | 8813c63 | off | ✅ | смена оружия колесом мыши даст FP, если включить |

### 2.2 Изменения в существующих (legacy) модулях

Legacy-модули **банят даже в observe-режиме**, поэтому тут ошибки дороже всего.

| Модуль | Источник | Коммит | Что поменяли | Вердикт |
|--------|----------|--------|--------------|---------|
| `smac.sp` | S1 + своё | 41079ca, 55630b9 | SB/SB++, kick после бана, observe-гейт по `g_LastDetection`, `smac_log_verbose` → 1 | 🔧 `KickClient` сразу после `sm_ban` (порядок не гарантирован); `KickClient(client, sReason)` — причина как формат-строка; `g_LastDetection` протекает между модулями |
| `include/smac_stocks.inc` | своё | 15343f1, 55630b9, 2c466f4, 9e00332 | `SMAC_UltraReact`, `SMAC_MayEnforce`, lag-guard | 🔧 `SMAC_IsClientLagging` (choke > 30% / loss > 5%) выключает legacy aimbot → обход через низкий `rate`; ChatClear/HardFlood записаны в legacy |
| `smac_aimbot` | S1 + своё | 41079ca, 2c466f4 | `MAXPLAYERS+1`, сброс истории при лаге | 🔧 см. обход выше |
| `smac_autotrigger` | S1 | 41079ca | ladder skip, `MAXPLAYERS+1` | ✅ |
| `smac_eyetest` | S1 | 41079ca | compat=1 выключает проверку кнопок; tickcount ослаблен | 🔧 решить осознанно |
| `smac_speedhack` | S1 | 41079ca | пропуск не-ingame | ✅ |
| `smac_commands` | S1, S12, S14 | 41079ca, 0c8a2be, 4cd0d41 | ProtectCMDS + Ultra-блоки, `!IsClientInGame → Plugin_Stop` | ❌ блок `kill`; **`shutdown → Action_Ban`**; `Plugin_Stop` для подключающихся (у Danyas было закомментировано) |
| `smac_cvars` | S4, S9 | 530a375, d4d5ef6, eb2d779 | `cl_interpolate`, `cl_pitch*`, `net_fake*`, (`cl_bobcycle` удалён) | 🔧 `cl_interpolate → Ban` под вопросом (Q3); **закоммиченный `.smx` всё ещё банит за `cl_bobcycle`** |
| `smac_client` | S1, S3, S7, S14 | 41079ca, 530a375, 702b236, 4cd0d41 | auth, chat-clear, hardflood → **бан**, voice_loopback мут, sens/impulse | 🔧 таймеры умирают на смене карты (строки 70–72); мут за легальный `voice_loopback` |
| `smac_spinhack` | S14 | 8813c63 | cvar порогов, счётчик | ✅ |
| `smac_css_antiflash` | S13, S14 | 2ffe391, 702b236 | угловое окно, no-team-flash | 🔧 `g_iFlashOwner` без проверки времени; порядок событий (Q2) |
| `smac_css_antismoke` | S9 | d4d5ef6 | LOS-режим (по умолчанию 2) | 🔧 скрывает при любом касании сферы — нужен порог, как у Valve |
| `smac_wallhack` | S13 | 2ffe391, 55630b9 | sound jitter, TE jitter, натив `SMAC_IsClientVisible` | ❌ TE jitter ±100 всем на каждом выстреле (трассеры и звук выстрела кривые); sound jitter убивает ориентацию по звуку; оба включены |

---

## 3. Блокеры (до любого мержа)

1. **CI SM 1.6 красный**: `HasEntProp` в `smac_norecoil.sp:255` (введён в a5da0fe). Заменить на
   `FindSendPropOffs("CBaseCombatWeapon", "m_iClip1")` или аналог.
2. **`.smx` в git устаревшие**: последняя пересборка в e4e4700. `smac_cvars.smx` проверен распаковкой —
   в нём есть `cl_bobcycle`. Для 8 новых модулей `.smx` нет. Решение: не хранить `.smx` в git,
   собирать в CI (артефакт или релиз).
3. **Активные изменения геймплея включены по умолчанию** (observe их не трогает):
   `smac_SoundESP_block`, `smac_wallhack_sound_jitter`, `smac_wallhack_te_jitter`,
   `smac_antismoke_mode 2`, `smac_Voice_Ctrl`, `smac_mute_voice_loopback`, `smac_backtrack_mode 3`,
   блок `kill`, `smac_serverlock`.
4. **Новые баны в legacy-пути**: `shutdown → Action_Ban`, `cl_interpolate → Action_Ban`, HardFlood → `SMAC_Ban`.
5. **Observe-гейт**: `g_LastDetection[client]` общий для всех модулей, не сбрасывается после бана
   и пишется даже при заблокированной форвардом детекции. Нужно передавать тип детекции в `SMAC_Ban` явно.
6. **Обход legacy aimbot** через искусственный choke (2c466f4).

---

## 4. Сквозные проблемы

- Около 25 плагинов хукают `OnPlayerRunCmd`, многие делают трассировку или перебор всех игроков на каждый тик → CPU на v34.
- Около 8 aim-детекторов пересекаются (aimbot, aimsnap, firemacro fast-aim, ultra_aim, aimlock, aimkill, advtrigger, triggerbot) → один флик даёт 3–4 уведомления.
- Счётчики детектов без затухания по времени у многих модулей → на долгой сессии FP неизбежны.
- Паттерн `CreateTimer(..., TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE)` в `OnPluginStart` — таймер живёт одну карту
  (`smac_aimlock`, `smac_client`).
- Мёртвые алиасы cvar: `smac_Control_Entity`, `smac_eyetest_reaction_Advanced`, `smac_ssac_airstuck_ban`.

---

## 5. Открытые вопросы (проверить на живом v34)

- **Q1.** Передаёт ли клиент CS:S v34 `mousedx/mousedy` в usercmd (SM `mouse[2]`)? Если всегда 0 —
  выключить `turncheck` mouse-aim, `ssac` mouseless aim и почти весь `ultra_aim`. Косвенный признак:
  троттлинг спама в fdfb0d0. Ещё учесть `m_filter 1`, при котором вид двигается на тиках с нулевым mouse.
- **Q2.** Порядок `player_blind` и `flashbang_detonate` в CS:S. Если detonate идёт после blind,
  угловое окно и no-team-flash в antiflash работают по предыдущей флешке.
- **Q3.** Есть ли у `cl_interpolate` в v34 флаг `FCVAR_CHEAT`. Если нет — это бан за твик конфига.
- **Q4.** Порядок исполнения `ServerCommand("sm_ban …")` и `KickClient` в `Native_Ban`:
  не превращается ли бан в простой кик.
- **Q5.** Ловит ли `smac_entityspam` хоть что-то (owner в `OnEntityCreated`).

---

## 6. План, когда вернёмся

1. **Разбить PR.** Отдельно: (a) фиксы legacy из S1 без спорных частей; (b) observe-режим с правильным
   гейтом; (c) каждый новый детектор отдельным PR, с `ban 0` и выключенными активными мерами.
2. Починить блокеры из раздела 3 в порядке номеров.
3. Убрать `.smx` из git, собирать в CI для 1.6 / 1.11 / 1.12 / 1.13.
4. Закрыть Q1–Q5 на тестовом сервере v34 с живым клиентом (не только `0_smac_testbench`).
5. Собрать логи observe-режима минимум неделю, по каждому модулю посчитать срабатывания на
   заведомо честных игроках, и только потом поднимать `*_ban`.
6. Кандидаты на выброс: `smac_soundesp` (blocker), TE и sound jitter в wallhack, `smac_ultratools`,
   `smac_entityspam`, `smac_aimorigin`, режимы `ultra_aim` без подтверждённого `mouse[]`.
7. Добавить `LICENSE` (GPLv3) и вернуть copyright-уведомления в шапки (раздел 1.1).

---

## 7. Коммиты PR по порядку

| # | Коммит | Что | Ключевое |
|---|--------|-----|----------|
| 1 | 41079ca | порт фиксов xMaZax (S1) | kick после `sm_ban`; `Plugin_Stop` в commands; eyetest ослаблен |
| 2 | 530a375 | Cheat-Acid: aimlock, aimorigin, psilent, immunity, chat-clear, hardflood | таймеры; aimorigin FP; HardFlood банит в observe; `cl_interpolate` |
| 3 | 46f944b | strafe, triggerbot, serverlock | Shift-ходьба; счётчик без сброса; serverlock по умолчанию |
| 4 | d4d5ef6 | HOTGUARD/Ash/Bash/Oryx/Cow: movesanity, strafesync, turncheck, antismoke LOS, cvars | `cl_bobcycle` (в `.smx` до сих пор); LOS без порога |
| 5 | 2ffe391 | SauRay в wallhack/antiflash | TE `"FireBullets"` ронял загрузку до 55630b9; jitter ломает игру |
| 6 | 702b236 | Strike Back, entityspam, teleport, sens/impulse | strikeback ловит прострелы; entityspam мёртвый |
| 7 | 0c8a2be | ssac, ProtectCMDS | notice каждый тик; lag exploit без проверки лага |
| 8 | 4cd0d41 | norecoil, fakelag, firemacro, Ultra cmd blocks | блок `kill`, `shutdown → Ban`; fakelag не то направление |
| 9 | 1cd4f66 | ultra_aim из R52 | реконструкция-догадка |
| 10 | 52aa6a6 | ultra_aim уточнение | зависимость от `mouse[]` |
| 11 | 343e3cb | backtrack, fastreload, aimsnap | Mode B по умолчанию; fastshoot мёртвый |
| 12 | 13b97ad | handoff-доки для агента | мусор агента в репо |
| 13 | 15343f1 | P0: advtrigger, aimkill, fdbhop, soundesp, speedlimit, lag stocks | SoundESP blocker включён |
| 14 | 9fc9c4c | Ultr@Tools шим | не используется |
| 15 | 126d37d | фиксы P0 | ок |
| 16 | 48e2643 | testbench | меняет серверные cvar без восстановления |
| 17 | e4e4700 | порядок include для SM 1.6 | последняя пересборка `.smx` |
| 18 | 8813c63 | P1: nospamweapon, cheatcfg, FL/DDoS/Voice, airstuck FD, spinhack | Voice мут по умолчанию; N×N |
| 19 | 55630b9 | observe-режим, фиксы wallhack/fastreload | утечка `g_LastDetection`; активные меры не гейтятся |
| 20 | f8d314e | airstuck kick за observe | ок |
| 21 | eb2d779 | убрать `cl_bobcycle` | только в исходнике |
| 22 | f494bc9 | immunity в `disabled/` | `.smx` в `plugins/` остался |
| 23 | 246d0d6 | пропуск сэмплов при лаге | основа будущего обхода |
| 24 | bf1616b | norecoil Mode B переписан | ок по идее |
| 25 | a5da0fe | norecoil clip-gate | `HasEntProp` → SM 1.6 сломан |
| 26 | 08a04a1 | aimkill/firemacro FP | ок |
| 27 | cf3459f | AMSAF с учётом мыши | зависит от Q1 |
| 28 | 756a67d | AutoFire требует lock | ок |
| 29 | 9da5a1d | testbench: сценарии на голову | см. риск бана админа |
| 30 | 2c466f4 | server-lag guard | **обход legacy aimbot через choke** |
| 31 | fdfb0d0 | троттлинг mouseless aim | лечит симптом Q1 |
| 32 | 9e00332 | lag guard только на всплески | ок |
