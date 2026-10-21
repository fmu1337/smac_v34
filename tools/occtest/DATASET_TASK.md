# Задача: собрать датасет для окклюдеров `smac_wallhack` на сервере CS:S v34

## Зачем

`smac_wallhack` (ветка `claude/clever-shannon-jgos9l` репозитория `fmu1337/smac_v34`) читает браши карты из `.bsp`
и по ним заранее доказывает, что противник скрыт, чтобы не делать трассы движка. Код загрузчика проверен оффлайн против
эталона на Python, но не против самого движка v34. Нужен датасет: на реальном сервере для тысяч пар игроков записать,
что говорят трассы движка и что сказал бы окклюдер, и прогнать проверку.

Писать код не нужно: всё готово. Нужно собрать, поставить, запустить на картах, проверить и прислать результаты.
Код плагинов не менять. Если что-то не работает — остановиться и прислать точную ошибку.

## Что есть в репозитории

* `addons/sourcemod/scripting/smac_wallhack.sp` — сам anti-WH (для датасета не обязателен, но пусть стоит как в бою).
* `tools/occtest/occ_dataset.sp` — dev-плагин сбора. Раз в 0.25 с берёт 16 случайных пар живых игроков (боты тоже),
  делает те же трассы, что `smac_wallhack` (глаза и две точки упреждения пика → 10 точек на цели), спрашивает
  окклюдер и пишет строку в `addons/sourcemod/data/occ_dataset_<карта>.csv`.
* `tools/occtest/check_dataset.py` — проверка CSV против `.bsp` (Python 3, без зависимостей).

## 1. Сборка

Нужен компилятор SourceMod 1.6 для CS:S v34
(`https://bitbucket.org/_4/smdrop-1.6/downloads/sourcemod-1.6.4-stable-git4626-css34-linux.tar.gz`, на Linux x64
нужны 32-битные библиотеки: `libc6:i386 lib32stdc++6`). Из корня репозитория:

```bash
git checkout claude/clever-shannon-jgos9l
SP=<sourcemod>/addons/sourcemod/scripting
$SP/spcomp -iaddons/sourcemod/scripting/include -i$SP/include addons/sourcemod/scripting/smac_wallhack.sp -osmac_wallhack.smx
$SP/spcomp -iaddons/sourcemod/scripting/include -i$SP/include tools/occtest/occ_dataset.sp -oocc_dataset.smx
```

Должно собраться без ошибок и предупреждений. Если на сервере уже стоит SourceMod другой версии — собирать его spcomp.

## 2. Сервер

* srcds CS:S v34, SourceMod (у нас 1.6.4 css34) с SDKTools. Записать вывод `version`, `sm version`, `meta list`.
* Положить `smac.smx` (из обычной сборки SMAC, если стоит), `smac_wallhack.smx` и `occ_dataset.smx` в
  `addons/sourcemod/plugins/`. Сервер закрытый (пароль), не боевой: dev-плагин делает лишние трассы.
* Боты: для каждой карты нужен `.nav` рядом с `.bsp`. Если его нет — `sv_cheats 1`, `nav_generate` на этой карте
  (может занять несколько минут), потом перезапуск карты.
* Настройки, чтобы боты бегали по всей карте и раунды не кончались слишком быстро:

```
sv_cheats 1
bot_quota 20
bot_quota_mode normal
bot_join_after_player 0
mp_autoteambalance 0
mp_limitteams 0
mp_timelimit 0
mp_maxrounds 0
mp_roundtime 9
mp_freezetime 0
bot_dont_shoot 1     // если такого квара нет — пропустить
```

## 3. Прогон на каждой карте

Карты: `de_dust2`, `de_dust`, `de_inferno`, `de_nuke`, `de_train`, `de_aztec`, `de_cbble`, `de_piranesi`,
`de_prodigy`, `de_chateau`, `de_port`, `de_tides`, `cs_office`, `cs_italy`, `cs_assault`, `cs_compound`,
`cs_havana` и 3–5 кастомных карт, которые реально крутятся на наших серверах.

Для каждой карты:

1. `changelevel <карта>`, подождать 30 с, пока зайдут боты.
2. В логе SourceMod (`addons/sourcemod/logs/L*.log`) найти строку от `occ_dataset` / `smac_wallhack`:
   `Occluders for <карта>: N of M brushes ...` или `No occluders for <карта>: <причина>`. Записать её.
   Если «No occluders» — карту всё равно прогнать (датасет покажет, что плагин работает без окклюдеров), причину прислать.
3. `smac_occ_dataset_start` (в консоли сервера или rcon).
4. Подождать 15 минут. Каждые 5 минут — `smac_occ_dataset_status`, вывод сохранить.
5. `smac_occ_dataset_stop`.
6. Проверка (на сервере или где есть Python 3 и `.bsp` карты):

```bash
python3 tools/occtest/check_dataset.py <cstrike>/maps/<карта>.bsp <cstrike>/addons/sourcemod/data/occ_dataset_<карта>.csv
```

Ожидается последняя строка `RESULT: OK`. Скрипт выходит с кодом 1, если есть проблемы — тогда карту не перезапускать,
сохранить всё как есть.

Если в логе или в `status` появляется `PROVEN BUT ENGINE SEES` — это главное, что мы ищем: окклюдер считает
игрока скрытым, а движок его видит. Такие строки лога прислать обязательно.

## 4. Что прислать

Архивом, по папке на карту:

* `occ_dataset_<карта>.csv.gz` (около 50–100 МБ до сжатия на 15 минут);
* вывод `check_dataset.py` и все выводы `smac_occ_dataset_status`;
* строки лога с `Occluders for`, `No occluders`, `PROVEN BUT ENGINE SEES`, плюс `errors_*.log` за время прогона;
* для кастомных карт — их `.bsp` и `.nav`.

И одним файлом: версии сервера/SourceMod/Metamod, список карт с итогом (`RESULT`, число записей, доля
`engine-hidden pairs proven by one brush`, время `engine traces` и `occluder` на запись), всё, что падало или вело
себя странно.

## Критерии готовности

* По каждой карте не меньше 10 000 записей.
* `RESULT: OK` на всех картах, либо для каждой карты с `PROBLEMS` — полный вывод скрипта, CSV и строки лога.

## GitHub Action

Тот же прогон запускается вручную: Actions → **Occluder dataset** → Run workflow
(`.github/workflows/occ-dataset.yml`). Код плагинов не меняется: `spcomp` 1.6.4 должен
собрать `smac.sp`, `smac_wallhack.sp` и `occ_dataset.sp` без ошибок и предупреждений.

Сервер берётся так же, как smoke test в [`fmu1337/sourcemod-css34`](https://github.com/fmu1337/sourcemod-css34):
`testing/scripts/fetch-server.sh`, затем `apply-valve-rc-fix.sh` и `apply-srcds-patch.sh`
(BufferFix, в том workflow он включён по умолчанию). Metamod ставит `install-addons.sh`
этого репозитория (пакет по умолчанию, mmsource 1.10.6 css34). SourceMod — 1.6.4 css34
с bitbucket `_4/smdrop-1.6`: в этом архиве нет бинарей Metamod, а датасет собирается именно этим `spcomp`.

Каждая карта — отдельная job. Артефакт `occ-dataset-<карта>` содержит csv.gz, вывод
`check_dataset.py`, статусы, `version` / `sm version` / `meta list` и строки лога.
`occ-dataset-summary` — сводная таблица. Кастомных карт в архиве сервера нет: имя добавляется
в `maps`, а файлы — в `extra_map_urls` как `имя=https://...bsp|https://...nav`.
Если `.nav` нет, job делает `nav_generate` и перезапускает карту.

## Синтетический режим (`mode: synth`)

Боты ходят только по `.nav`, поэтому верх ящиков, карнизы, крыши и места с прыжка в живой прогон почти не попадают.
`smac_occ_dataset_start synth` обходится без ботов: плагин набирает пул из 4000 точек, где можно стоять. Половина —
случайные точки зон `.nav`, половина — хулл игрока, сброшенный из случайной точки карты на любую пологую поверхность.
Пары точек (половина ближе 1024 юнитов), у каждой случайная поза: стоя, присев, в прыжке (+40). Запись та же, что у
живых игроков, файл — `occ_synth_<карта>.csv`, в колонках `viewer_bot`/`target_bot` стоит −1. 64 пары каждые 0.25 с:
за 3 минуты около 44 тысяч пар. В Actions — вход `mode` = `synth`, `bot_quota` не нужен.
