# SMAC Plus — карта покрытия

Что покрыто модулями SMAC Plus в этом репозитории.

Обозначения: **да** — перенесено по коду; **уведомл.** — перенесено, по умолчанию только уведомления; **нет** — не
перенесено (причина в последней колонке); **master** — уже есть в стоковых плагинах SMAC этого репозитория.

## Детекты

| R52 | Модуль | Статус | Примечание |
|---|---|---|---|
| Airstuck (tickcount) | `smac_plus_netcode` | уведомл. | |
| Lag Exploit | `smac_plus_netcode` | уведомл. | строже R52: потеря пакетов не банит |
| Backtrack Exploit-Mode:A / B | `smac_plus_netcode` | уведомл. | |
| PSilent [Active Mode] | `smac_plus_netcode` | уведомл. | |
| Changer Player Status | `smac_plus_netcode` | уведомл. | |
| AimBot PRG 301–304 | `smac_plus_aimbot` | уведомл. | |
| AGTNL 200 / 201 | `smac_plus_aimbot` | уведомл. | |
| AGTWS 100, AMSAF 101 | `smac_plus_aimbot` | уведомл. | |
| Accurate Analysis (AGT 288/299, Trigger 188/199, AGTAF 88/99, 108/109) | `smac_plus_aimbot` | уведомл. | |
| UsingWH 103 | `smac_plus_aimbot` | уведомл. | |
| UsingWH 102 | — | нет | мёртвый код в самом R52 |
| Act.Mode 300 (зонд по `m_angEyeAngles`) | — | нет | не разобран до конца |
| Fast Run, BunnyHop / Airstuck / Teleport Fast Detect, Teleport Hack | `smac_plus_movement` | уведомл. | |
| Advanced BunnyHop, HaX2, AutoHotKeys Auto-Jump | `smac_plus_movement` | уведомл. | |
| Eye Angles 04 | `smac_eyetest` | да | перенесён из `smac_plus_movement` |
| Spinhack (R52) | `smac_plus_movement` | уведомл. | в master есть свой `smac_spinhack` |
| Eyetest 01–03, `smac_NoS_NoR` | `smac_eyetest` | да | второе нарушение, пауза 5 с — `docs/PLUS_STOCK.md` |
| AutoTrigger (Auto-Fire, Strafe, Duck, Scroll, AutoHotKeys) | `smac_plus_input` | уведомл. | |
| AutoTrigger тип 0 (BunnyHop-таймер) | — | нет | смысл таймера не разобран |
| Advanced Trigger, Advanced AutoFire | `smac_plus_input` | уведомл. | |
| Fast AIM Detect, RCS -F / -H | `smac_plus_input` | уведомл. | |
| 2X | `smac_plus_input` | уведомл. | |
| KnifeBot | `smac_plus_input` | выкл. | условие выполняется у людей |
| CheatCFG: Stop movement, Fast Switch, Fast Reload | `smac_plus_input` | уведомл. | счётчики затухают (в R52 нет) |
| CheatCFG: Jumpthrow (лига) | — | нет | только «лиговый» режим |
| No Recoil A / B | `smac_plus_diag_norecoil` | диагностика | ждёт логов с сервера |
| Impulse spam, Sensitivity (границы и смены), FakeSendPacket Max/Min | `smac_plus_client` | уведомл. | |
| Fake Lag (`smac_FL_Ctrl`), DDoS, Voice_Ctrl | — | нет | эвристики на средних потоках, шумные |
| Таблица кваров (325) | `smac_cvars` + `smac_cvars_plus.inc` | уведомл. | 257 новых, 68 уже были |
| Half-connected command, `rcon` от клиента, переполнение аргументов, Iniuria, Validate Auth | `smac_plus_server` | блок + уведомл. | |
| Стандартный AimBot (`smac_aimbot_ban`) | `smac_aimbot` | да | 35°, 45 cmd, и на попаданиях |
| Ник, анти-реконнект, `autobuy`, `smac_Lock_Adm` | `smac_client` | да | спам ником 2 за 15 с; Lock_Adm по умолчанию 4 |
| Спам команд, `say`, `ucp_*` | `smac_commands` | да | −25 в секунду, кик |
| `smac_cmd_block.cfg`, `rcon_password` | `smac_rcon` | да | блок только для игроков |
| Флуд `status` / `ping` | master | master | лимит = `smac_antispam_cmds`; подмена вывода `status` не перенесена |

## Защиты

| R52 | Модуль | Статус | Примечание |
|---|---|---|---|
| AIM_Kill (приманки) | `smac_plus_aimkill` | вкл. | не проверено в игре |
| No_Team_Flash | `smac_plus_protect` | выкл. (как в R52) | |
| Control_Entity 1 (перезагрузка у лимита) | `smac_plus_protect` | вкл. (как в R52) | |
| Control_Entity 2 (удаление спама) | — | нет | не перенесено |
| defusefix, respawnfix | `smac_css_fixes` | master | совпадают с R52; исправлена проверка SteamID на SM ≥ 1.7 |
| Anti-Wallhack (`_Level`, `_Time`, FFA) | `smac_wallhack` | да | ядро R52 = стоковый SMAC; перенесены геометрия, время, FFA — `docs/PLUS_WALLHACK.md` |
| AntiFlash 1/2 | `smac_css_antiflash` | да | режим 2 (оверлей) не проверен в игре |
| AntiSmoke 1/2 | `smac_css_antismoke` | да | константы R52; режим 2 не зависит от anti-WH |
| SoundESP 0–4 | `smac_wallhack` | да | по умолчанию 0, как в R52; каждый звук сразу, без лимита R52 «один звук за тик» |
| NoSpamWeapon | — | нет | код с кваром не найден |
| Лицензионная обвязка / внешние таймеры бана | — | не нужно | заменено таймерами SourceMod |

## Цепочка PR

| PR | Что |
|---|---|
| #10 | `smac_plus_netcode` |
| #11 | `smac_plus_aimbot` |
| #12 | `smac_plus_movement` |
| #13 | `smac_plus_input` |
| #14 | `smac_plus_client` |
| #15 | UsingWH 103 в `smac_plus_aimbot` |
| #16 | таблица кваров R52 в `smac_cvars` |
| #17 | `smac_plus_server` |
| #18 | `smac_plus_aimkill` |
| #19 | 2X, KnifeBot, `smac_plus_protect` |
| #20 | `smac_plus_diag_norecoil` |
| #21 | Backtrack A, Changer Player Status, эта карта |
| #22 | anti-WH, AntiFlash, AntiSmoke по R52 |
| #23 | стоковые aimbot, eyetest, client, commands, rcon по R52 |
| #24 | Anti-SoundESP |

Каждый PR стоит на предыдущем; #10 — на master. Сливать по порядку.
