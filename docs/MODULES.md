# Новые модули SMAC v34

Почти везде по умолчанию **только уведомление админам** (0/1/2/3 = выкл / notice / кик / бан).  
Админы с ban/root не наказываются (`smac_plus_admin_immune`).

## SMAC Plus

| Модуль | Что делает |
|---|---|
| `smac_plus_netcode` | Airstuck, Lag Exploit, Backtrack A/B, PSilent, фейк-бот с мышью. CmdNum Jump / Tick Ahead (420hook). Опционально Backtrack Patch (`smac_backtrack_patch`). |
| `smac_plus_aimbot` | Снапы и silent-aim: PRG, AGTNL, AGTWS, AMSAF, UsingWH, Accurate Analysis. Пороги от `sensitivity`. |
| `smac_plus_movement` | Fast Run, bhop/HaX2/Auto-Jump, телепорт, spinhack. FastWalk / AutoStrafe / CircleStrafe (420hook). |
| `smac_plus_input` | Макросы: AutoTrigger, 2X, KnifeBot (выкл), Trigger/AutoFire, Fast AIM, RCS, CheatCFG. |
| `smac_plus_client` | Спам impulse, `sensitivity` вне нормы / спам сменой, слишком много/мало usercmd в секунду. |
| `smac_plus_server` | Команды до входа в игру, клиентский `rcon*`, переполнение аргументов, Iniuria, неавторизованный клиент. |
| `smac_plus_aimkill` | Защита: невидимые приманки у лица против трасс аимбота (`smac_AIM_Kill`). |
| `smac_plus_protect` | Флешки не слепят своих (`smac_No_Team_Flash`); рестарт карты у лимита энтити (`smac_Control_Entity`). |
| `smac_plus_diag_norecoil` | Только лог: прогон No Recoil A/B без наказаний. |
| `smac_cvars` + `smac_cvars_plus` | +257 клиентских кваров/команд читов. `0` выкл, `1` notice, `2` кик/бан. |

### Доработки стока (в обычных плагинах)

| Что | Куда |
|---|---|
| Снап 35°, проверка на попаданиях | `smac_aimbot` |
| Eyetest 01–04 (2-е нарушение), lisp-yaw, нулевые углы, `smac_NoS_NoR` | `smac_eyetest` |
| Спам ником, `smac_Lock_Adm`, name stealer, реклама читов в чате | `smac_client` |
| Антиспам команд (−25/с) | `smac_cmdspam` |
| Блок-лист `cfg/sourcemod/smac_cmd_block.cfg` | `smac_rcon` |
| Anti-WH Level/Time/FFA, трасса в голову, Anti-SoundESP | `smac_wallhack` |
| Дым/флешка режим 2 | `smac_css_antismoke` / `smac_css_antiflash` |
| `cl_interpolate` только 0 или 1, `mat_fullbright` | `smac_cvars` |

## Прочее

| Модуль | Что делает |
|---|---|
| `smac_css_smokefix` | Плотнее дым + невидимая сфера, чтобы `smac_wallhack` не видел сквозь дым. Нужны `materials/rxg`, `models/rxg` на FastDL. |
| `smac_cvar_trap` | Ловушка Insomnia: пишет `xbox_throttlebias` через MOTD, читает обратно. CSS v34. |
| `smac_usercmd` | Только лог/notice: MoveGrid, SnapBack, FakeLag, Roll. `logs/smac_usercmd_diag.log`. |
| `smac_lerp` | NoLerp / слишком большой lerp; опционально зажимает lerp перед лагкомпенсацией. |
| `smac_strafe` | Опционально (`plugins/disabled`): sync / perfect turn / silent strafe / AHK mouse. |
| `smac_nsb` | No-steam баны по метке в клиенте + `data/smac_nsblist.txt`. Меню `sm_nsb`. |
