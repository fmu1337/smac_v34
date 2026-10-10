Порт SMAC от версии 0.8.6.0 для CSS v34.
Изначально задумывалось как простой перевод того что есть на 34-ку, но в дальнейшем пришлось всякий шлак добавлять.
Тем не менее, если что-то не нравиться, или работает не так - ставьте КАС и не нойте на форуме или в вк, что "АНО НИ БАНИТ ЗА ОИМ", или из серии "БАНИТ ДАЖЕ КОГДА ТЫ НЕ В ИГРЕ", а просто сразу выходите в окно.

[![Build](https://github.com/fmu1337/smac_v34/actions/workflows/build.yml/badge.svg)](https://github.com/fmu1337/smac_v34/actions/workflows/build.yml)

![picture alt](https://raw.githubusercontent.com/fmu1337/smac_v34/master/logo.jpg "SMAC v34 Logo")

Поддержка осуществляеться на форуме hlmod.ru, в обсуждениях по ссылке: https://hlmod.ru/threads/smac-v34.28266/

## Сборка

CI собирает плагины под SourceMod **1.6–1.13**. Обязательные: **1.6** (CSS v34) и **1.11 / 1.12 / 1.13**. Релизы публикуются автоматически при пуше тега (`v*` / `v34*`).

Локально (Linux, пример для SM 1.12):

```bash
curl -fsSL "https://www.sourcemod.net/latest.php?version=1.12&os=linux" -o sourcemod.tar.gz
mkdir -p "$HOME/sourcemod" && tar -xzf sourcemod.tar.gz -C "$HOME/sourcemod"
export SPCOMP="$HOME/sourcemod/addons/sourcemod/scripting/spcomp"
export SM_INCLUDE="$HOME/sourcemod/addons/sourcemod/scripting/include"
chmod +x "$SPCOMP" scripts/compile-all.sh
./scripts/compile-all.sh
```

Для CSS v34 возьмите SM 1.6 с [css34 drop](https://bitbucket.org/_4/smdrop-1.6/downloads/sourcemod-1.6.4-stable-git4626-css34-linux.tar.gz).

## Требования к SourceMod

Типичная цель — **SourceMod 1.6** (CSS v34).

`smac_wallhack` и `smac_eyetest` вызывают `RequireFeature(..., FEATURECAP_PLAYERRUNCMD_11PARAMS)`. Этот capability появился в **SourceMod 1.5.0** ([API Changes](https://wiki.alliedmods.net/Sourcemod_1.5.0_API_Changes)), не в 1.7. На нормальном SM ≥ 1.5 (включая css34 SM 1.6.4) модули должны загружаться.

Если wallhack не грузится с сообщением про «newer version of SourceMod» — проверьте, что у вас действительно SM ≥ 1.5 с рабочим SDKTools, а не урезанный/битый билд.

## Порты SMAC Ultr@ R52

Полная карта: что из R52 куда перенесено и что нет — [docs/ULTRA_COVERAGE.md](docs/ULTRA_COVERAGE.md).

* `smac_ultra_netcode` — Airstuck, Lag Exploit, Backtrack A/B, PSilent [Active Mode] и Changer Player Status по декоду SMAC Ultr@ R52.
  По умолчанию только уведомления админам. Подробности — в [docs/ULTRA_NETCODE.md](docs/ULTRA_NETCODE.md).
* `smac_ultra_aimbot` — AimBot PRG 301–304, AGTNL 200/201, AGTWS 100, AMSAF 101, UsingWH 103 и Accurate Analysis (AGT, Trigger, AGTAF) по декоду R52.
  Пороги считаются от `sensitivity` клиента. По умолчанию только уведомления. Подробности — в [docs/ULTRA_AIMBOT.md](docs/ULTRA_AIMBOT.md).
* `smac_ultra_movement` — Fast Run, Advanced BunnyHop, HaX2, AutoHotKeys Auto-Jump, Teleport Hack,
  Airstuck/BunnyHop Fast Detect и Spinhack по декоду R52. По умолчанию только уведомления.
  Подробности — в [docs/ULTRA_MOVEMENT.md](docs/ULTRA_MOVEMENT.md).
* `smac_ultra_input` — AutoTrigger (Auto-Fire, Auto-Strafe, Auto-Duck, Auto-Scroll, AutoHotKeys), 2X, KnifeBot, Advanced Trigger,
  Advanced AutoFire, Fast AIM Detect, Recoil Control System -F/-H и CheatCFG (Stop Movement, Fast Switch, Fast Reload)
  по декоду R52. По умолчанию только уведомления. Подробности — в [docs/ULTRA_INPUT.md](docs/ULTRA_INPUT.md).
* `smac_ultra_client` — спам impulse, проверки `sensitivity` и FakeSendPacket (частота usercmd) по декоду R52.
  По умолчанию только уведомления. Подробности — в [docs/ULTRA_CLIENT.md](docs/ULTRA_CLIENT.md).
* `smac_cvars` + таблица кваров R52 (`include/smac_cvars_ultra.inc`, 257 новых кваров): `smac_cvars_ultra` 0 выкл,
  1 только уведомления (по умолчанию), 2 кик/бан как в R52. Подробности — в [docs/ULTRA_CVARS.md](docs/ULTRA_CVARS.md).
* `smac_ultra_server` — команды от «полуподключённого» клиента, `rcon` из клиентской команды, переполнение числовых
  аргументов, SIC Iniuria и проверка авторизации из плагинов Rcon/Cvars/Client R52. По умолчанию блок и уведомления.
  Подробности — в [docs/ULTRA_SERVER.md](docs/ULTRA_SERVER.md).
* `smac_ultra_aimkill` — AIM_Kill из R52: невидимые несталкивающиеся приманки (ящик у лица игрока), в которые упираются
  трассы аимбота. Защита, а не детект. Подробности — в [docs/ULTRA_AIMKILL.md](docs/ULTRA_AIMKILL.md).
* `smac_ultra_protect` — No_Team_Flash (флешки не слепят своих) и Control_Entity (перезагрузка карты у лимита энтити)
  из R52. Подробности — в [docs/ULTRA_PROTECT.md](docs/ULTRA_PROTECT.md).
* `smac_ultra_diag_norecoil` — **диагностика, без наказаний**: меряет `m_angEyeAngles` против углов usercmd и прогоняет
  No Recoil A/B из R52, чтобы понять, ловил бы он обычных игроков. Как читать — в
  [docs/ULTRA_DIAG_NORECOIL.md](docs/ULTRA_DIAG_NORECOIL.md).
* `smac_wallhack`, `smac_css_antismoke`, `smac_css_antiflash` — доработки anti-WH из R52: `smac_wallhack` 0/1/2 (FFA),
  `smac_wallhack_Level`, `smac_wallhack_Time` 0.2 с, хитбокс уже, трасса в голову; дым и флешка с режимом 2.
  Подробности — в [docs/ULTRA_WALLHACK.md](docs/ULTRA_WALLHACK.md).
* `smac_css_smokefix` — Advanced Smoke Fix (DjAudition, forum.clientmod.ru, тема 1118) без своей копии wallhack:
  дым плотнее (`smac_smokefix_density` доп. эмиттеров), а через `smac_smokefix_delay` с (5 с) в облако ставится
  невидимая сфера `models/rxg/smokevol.mdl`. Клиентам она не отправляется и ни с чем не сталкивается, но перекрывает трассы
  `smac_wallhack`, так что игроков в дыму и за ним не видно. Нужен включённый `smac_wallhack`. `smac_smokefix_mapfog 1`
  убирает туман карты, `func_smokevolume` и `func_dustmotes`. `materials/rxg` и `models/rxg` выложить на FastDL.
* `smac_canary` — ловушка против «антибана» Insomnia: через команду закрытия MOTD (`VGUIMenu "info"`, ключ `cmd`)
  игроку пишется случайный `xbox_throttlebias`, через 2 с он читается обратно. Insomnia каждый кадр возвращает `xbox_*` к
  значениям по умолчанию, чтобы стереть метки NoSteamBans/SteamID Protect, — 100 вместо нашего значения и есть детект.
  Только CSS v34, по умолчанию уведомления (`smac_canary_action`). Подробности — в [docs/CANARY.md](docs/CANARY.md).
* `smac_aimbot`, `smac_eyetest`, `smac_client`, `smac_commands`, `smac_rcon` — доработки стоковых модулей из R52:
  снап 35° и на попаданиях, Eyetest 01–04 со вторым нарушением, `smac_NoS_NoR`, `smac_Lock_Adm`, спам ником и командами,
  блок-лист `cfg/sourcemod/smac_cmd_block.cfg`. Подробности — в [docs/ULTRA_STOCK.md](docs/ULTRA_STOCK.md).
