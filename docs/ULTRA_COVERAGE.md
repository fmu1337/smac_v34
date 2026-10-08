# SMAC Ultr@ R52 — карта покрытия

Что есть в R52 (`001_SMAC_Global/Client/Cvars/Rcon/Core.smx` и расширение `Ultr@Tools`) и где это в этом репозитории.
Разбор — `docs/R52_SPEC.md` и `docs/R52_CVARS.md` в ветке декода (fmu1337/smac_v34#9). R52_3 из архивов совпадает с R52
байт в байт, кроме `001_SMAC_Cvars.smx` (9 байт).

Обозначения: **да** — перенесено по коду; **уведомл.** — перенесено, по умолчанию только уведомления; **нет** — не
перенесено (причина в последней колонке); **master** — уже есть в стоковых плагинах SMAC этого репозитория.

## Детекты

| R52 | Модуль | Статус | Примечание |
|---|---|---|---|
| Airstuck (tickcount) | `smac_ultra_netcode` | уведомл. | |
| Lag Exploit | `smac_ultra_netcode` | уведомл. | строже R52: потеря пакетов не банит |
| Backtrack Exploit-Mode:A / B | `smac_ultra_netcode` | уведомл. | |
| PSilent [Active Mode] | `smac_ultra_netcode` | уведомл. | |
| Changer Player Status | `smac_ultra_netcode` | уведомл. | |
| AimBot PRG 301–304 | `smac_ultra_aimbot` | уведомл. | |
| AGTNL 200 / 201 | `smac_ultra_aimbot` | уведомл. | |
| AGTWS 100, AMSAF 101 | `smac_ultra_aimbot` | уведомл. | |
| Accurate Analysis (AGT 288/299, Trigger 188/199, AGTAF 88/99, 108/109) | `smac_ultra_aimbot` | уведомл. | |
| UsingWH 103 | `smac_ultra_aimbot` | уведомл. | |
| UsingWH 102 | — | нет | мёртвый код в самом R52 |
| Act.Mode 300 (зонд по `m_angEyeAngles`) | — | нет | не разобран до конца |
| Fast Run, BunnyHop / Airstuck / Teleport Fast Detect, Teleport Hack | `smac_ultra_movement` | уведомл. | |
| Advanced BunnyHop, HaX2, AutoHotKeys Auto-Jump | `smac_ultra_movement` | уведомл. | |
| Eye Angles 04 | `smac_ultra_movement` | уведомл. | |
| Spinhack (R52) | `smac_ultra_movement` | уведомл. | в master есть свой `smac_spinhack` |
| Eyetest 01–03 | master | master | `smac_eyetest` |
| AutoTrigger (Auto-Fire, Strafe, Duck, Scroll, AutoHotKeys) | `smac_ultra_input` | уведомл. | |
| AutoTrigger тип 0 (BunnyHop-таймер) | — | нет | смысл таймера не разобран |
| Advanced Trigger, Advanced AutoFire | `smac_ultra_input` | уведомл. | |
| Fast AIM Detect, RCS -F / -H | `smac_ultra_input` | уведомл. | |
| 2X | `smac_ultra_input` | уведомл. | |
| KnifeBot | `smac_ultra_input` | выкл. | условие выполняется у людей |
| CheatCFG: Stop movement, Fast Switch, Fast Reload | `smac_ultra_input` | уведомл. | счётчики затухают (в R52 нет) |
| CheatCFG: Jumpthrow (лига) | — | нет | только «лиговый» режим |
| No Recoil A / B | `smac_ultra_diag_norecoil` | диагностика | ждёт логов с сервера |
| Impulse spam, Sensitivity (границы и смены), FakeSendPacket Max/Min | `smac_ultra_client` | уведомл. | |
| Fake Lag (`smac_FL_Ctrl`), DDoS, Voice_Ctrl | — | нет | эвристики на средних потоках, шумные |
| Таблица кваров (325) | `smac_cvars` + `smac_cvars_ultra.inc` | уведомл. | 257 новых, 68 уже были |
| Half-connected command, `rcon` от клиента, переполнение аргументов, Iniuria, Validate Auth | `smac_ultra_server` | блок + уведомл. | |
| Ник, анти-реконнект, блок-лист и спам команд, `say`, `ent_*`, `rcon_password` | master | master | `smac_client`, `smac_commands`, `smac_rcon` |
| Флуд `status` / `ping` | master | master | лимит = `smac_antispam_cmds`; подмена вывода `status` не перенесена |

## Защиты

| R52 | Модуль | Статус | Примечание |
|---|---|---|---|
| AIM_Kill (приманки) | `smac_ultra_aimkill` | вкл. | не проверено в игре |
| No_Team_Flash | `smac_ultra_protect` | выкл. (как в R52) | |
| Control_Entity 1 (перезагрузка у лимита) | `smac_ultra_protect` | вкл. (как в R52) | |
| Control_Entity 2 (удаление спама) | — | нет | условие искажено в декомпиляции |
| defusefix, respawnfix | master | master | `smac_css_fixes` |
| Anti-Wallhack, AntiFlash, AntiSmoke | master / #5, #7 | — | свои реализации в других PR |
| SoundESP | — | нет | работает от матрицы видимости anti-WH R52 |
| NoSpamWeapon | — | нет | код с кваром не найден |
| Лицензионная обвязка, Ultr@Tools (таймеры, `SetBan`/`OnBanReleased`) | — | не нужно | заменено таймерами SourceMod |

## Цепочка PR

| PR | Что |
|---|---|
| #10 | `smac_ultra_netcode` |
| #11 | `smac_ultra_aimbot` |
| #12 | `smac_ultra_movement` |
| #13 | `smac_ultra_input` |
| #14 | `smac_ultra_client` |
| #15 | UsingWH 103 в `smac_ultra_aimbot` |
| #16 | таблица кваров R52 в `smac_cvars` |
| #17 | `smac_ultra_server` |
| #18 | `smac_ultra_aimkill` |
| #19 | 2X, KnifeBot, `smac_ultra_protect` |
| #20 | `smac_ultra_diag_norecoil` |
| #21 | Backtrack A, Changer Player Status, эта карта |

Каждый PR стоит на предыдущем; #10 — на master. Сливать по порядку.
