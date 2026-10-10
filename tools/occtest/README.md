# Проверка окклюдеров `smac_wallhack`

Загрузчик окклюдеров (`addons/sourcemod/scripting/include/smac_wallhack_occ.inc`) читает `.bsp` прямо на сервере.
Ошибка в разборе может прятать видимых игроков, поэтому код на SourcePawn сверяется с эталоном на Python (`occ.py`):

* `gen_harness.py` пишет `data.inc`: файл карты словами int32, случайные точки и отрезки около брашей и ответы эталона;
* `test.sp` подменяет файловые нативы SourceMod чтением из этого массива, грузит карту кодом плагина и сравнивает
  набор брашей, поиск листа и пересечение отрезка с брашем;
* `to_v19.py` переписывает лепестки v20-карты в формат v19 (56 байт, ламп версии 0), чтобы проверить и эту ветку.

Запуск под `spshell` из [SourcePawn](https://github.com/alliedmodders/sourcepawn) (сборка: `configure.py`, `ambuild`):

```bash
SPCOMP=<obj>/oldspcomp/linux-x86_64/oldspcomp SPSHELL=<obj>/spshell/linux-x86_64/spshell SP_ROOT=<sourcepawn> \
  ./run.sh map1.bsp map2.bsp
```

Ожидается `python brushes missing in SP: 0`, `leaf mismatches: 0`, `segment mismatches: 0`.
Проверено на тестовых картах из [bsp_tool](https://github.com/snake-biscuits/bsp_tool) и
[ValveBSP](https://github.com/pySourceSDK/ValveBSP) (VBSP v20, TF2) и на их копии, переписанной в v19.
