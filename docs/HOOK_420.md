# Детекты по исходникам 420hook

Детекты написаны по исходникам 420hook для CS:S v34 (база Ikaros, плюс backtrack, `deathcore2013/420hook-css-v34-src`)
и чита под клиент ClientMod (`deathcore2013/clientmod`). В R52 их нет. Каждый закрывает функцию чита, которую текущие
модули пропускали или ловили только частично.

Надёжные детекты сразу наказывают. Спорные по умолчанию только пишут в лог и уведомляют админов: включать наказание
стоит после того, как логи с сервера покажут, что честных игроков они не задевают.

## smac_ultra_netcode

| Детект | Что ловит в 420hook | Условие | Квар (по умолчанию) |
|---|---|---|---|
| **CmdNum Jump** | Lag Exploit: `command_number += 450` на каждой команде (`Client.cpp:868`) | cmdnum вырос больше чем на 90 (`MULTIPLAYER_BACKUP`); 3 таких скачка за 10 с. Настоящий обрыв связи даёт один скачок | `smac_CmdNumJump_reaction` (2, кик) |
| **Tick Ahead** | Airstuck: `tick_count = INT_MAX` (`Client.cpp:1114`), FakeWalk: `tick_count += 10` | client tickcount больше чем на 1 с впереди серверного тика на 3 cmd подряд. Часы клиента всегда отстают от сервера | `smac_TickAhead_reaction` (2, кик) |
| **Fake Lag** | fake lag: держит до 14 команд и шлёт их одним пакетом (`Client.cpp:1191`) | в среднем ≥ 7 команд на пакет 5 секунд подряд, больше чем вдвое против `cl_cmdrate` клиента (из userinfo, с учётом `sv_maxcmdrate`), без потерь. После детекта 25 с тишины | `smac_FakeLag_reaction` (1, лог) |

CmdNum Jump и Tick Ahead работают **до** проверки на потери пакетов, и действие у них не понижается за плохую сеть.
Lag Exploit сдвигает номер исходящего пакета, поэтому сервер видит у клиента почти 100 % потерь, а остальные детекты
модуля при потерях молчат. Остальные исключения (спавн, `trigger_teleport`, хитч сервера, таймаут клиента) действуют.

Старый Lag Exploit из R52 ловит скачки **tickcount**. Скачки **cmdnum** R52 считал потерей пакетов и не наказывал,
а `smac_eyetest` проверяет их только на +attack (перебор сида).

## smac_ultra_movement

Только для `MOVETYPE_WALK`, без `FL_FROZEN`/`FL_ATCONTROLS`, после спавна и телепорта — пауза. Все четыре — уведомления.

| Детект | Что ловит | Условие | Квар (по умолчанию) |
|---|---|---|---|
| **FastWalk** | FastWalk: ±0.5065·400 к forward/side, знак меняется каждую команду (`Client.cpp:877`) | на земле без +jump изменение forwardmove или sidemove меняет знак на каждом cmd при одинаковой величине (≥ 100), 20 cmd подряд. Клавиатура так не может. Сюда же попадёт anti-aim с дёрганьем yaw каждую команду (movement fix крутит вектор туда-сюда) | `smac_FastWalk_reaction` (1) |
| **AutoStrafe** | `sidemove = ±400` без клавиш стрейфа (`cBhop.cpp:41`) | в воздухе \|sidemove\| = `cl_sidespeed` клиента, нет +moveleft/+moveright, знак против поворота yaw; 60 таких cmd за жизнь. Fast Run из R52 ловит это только на скорости > 289 | `smac_AutoStrafe_reaction` (1) |
| **CircleStrafe** | forward/side = cos/sin × 450 (`Client.cpp:925`) | forwardmove или sidemove больше `cl_forwardspeed` / `cl_backspeed` / `cl_sidespeed` клиента (+1); 10 таких cmd за жизнь. Пока квары клиента не известны, проверка молчит | `smac_CircleStrafe_reaction` (1) |
| **Move Fix** | movement fix silent aim / anti-aim (`CL_FixMove`) | на земле зажата одна клавиша хода, по второй оси значение не ноль, а длина вектора равна скорости клавиши (или ×0.52 для +speed) с точностью 1 %. Так выглядит вектор, повёрнутый под другие углы. Отпущенная в кадре клавиша даёт другую длину и не считается. 30 таких cmd за 60 с | `smac_MoveFix_reaction` (1, лог) |

Квары `cl_forwardspeed`, `cl_backspeed`, `cl_sidespeed` запрашиваются при заходе и раз в минуту, вместе с `sensitivity`.

## smac_client

| Детект | Что ловит | Условие | Квар (по умолчанию) |
|---|---|---|---|
| **Name stealer** | `setinfo name "<чужой ник> "` (`esp.cpp:447`) | новый ник после обрезки пробелов и префикса `(N)` совпадает с ником другого игрока. Наказывается только точная форма 420hook (ник с пробелами по краям); остальные копии ника (`(1)ник`, ручное копирование) — уведомление. Ники `unnamed` и `Player` пропускаются | `smac_namesteal_action` (2, кик) |
| **Текст отключения** | подмена причины дисконнекта (`Client.cpp:340`) | причина в `player_disconnect` ровно «420hook», «VAC BAN!!!» или «Gay Shit». Обычный клиент шлёт «Disconnect by user.». Бан по SteamID через `BanIdentity` уже после выхода, на `smac_ban_duration` минут. Заглушки `STEAM_ID_LAN`/`STEAM_ID_PENDING` и не-Steam ID не банятся, только лог | `smac_disconnect_signature_action` (3, бан) |
| **Реклама в чате** | kill say: `say 420hook`, `999hook`, `game bandit 1.1`, `bennyhook.pw`, `polenware.pw` (`CGameEventManager2.cpp:32`) | `say`/`say_team` содержит одну из строк (без учёта регистра). Сообщение не блокируется. Уведомление не чаще раза в 30 с | `smac_chat_signature_action` (1) |

Кик за эти детекты показывает фразу `SMAC_SignatureKick`.

## smac_cvars

`mat_fullbright` должен быть 0 (Fullbright в 420hook, `Client.cpp:172`), иначе бан, как у остальных визуальных кваров.
В v34 это cheat-квар: без `sv_cheats` честный клиент другое значение не выставит.

## Что уже ловилось раньше

Перебор сида (`smac_eyetest`), Backtrack A, PSilent, speedhack, bhop, autopistol, anti-aim с pitch 180, аим через
`SetViewAngles` (поворот без мыши), `cl_pred_optimize 0`, `r_skybox`, `sv_cheats`, `net_fakelag`. Визуалка
(ESP, chams, NoFlash, NoSmoke) серверу не видна; от неё защищают `smac_wallhack`, `smac_css_antismoke`,
`smac_css_antiflash`.

Чит под ClientMod в текущем виде — только ESP: вызов аимбота закомментирован, хук перебора сида не подключён.
Если их включат, аимбот поймают детекты снапов и поворота без мыши, а перебор сида на каждой команде — CmdNum Jump.

## ClientMod

Все детекты поворота без мыши (PRG, AGT, AGTNL, UsingWH 103, AMSAF) считают, что `mousedx/mousedy` в usercmd не нули,
когда игрок двигает мышью. Перед включением наказаний стоит проверить по логам, что честный клиент ClientMod (с raw input)
их заполняет.
