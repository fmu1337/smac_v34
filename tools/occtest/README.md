# Проверка окклюдеров `smac_wallhack`

Загрузчик окклюдеров (`addons/sourcemod/scripting/include/smac_wallhack_occ.inc`) читает `.bsp` прямо на сервере.
Ошибка в разборе может прятать видимых игроков, поэтому код на SourcePawn сверяется с эталоном на Python (`occ.py`):

* `gen_harness.py` пишет `data.inc`: файл карты словами int32, случайные точки и отрезки около брашей и ответы эталона;
* `test.sp` подменяет файловые нативы SourceMod чтением из этого массива, грузит карту кодом плагина и сравнивает
  набор брашей, поиск листа, пересечение отрезка с брашем и браши-кандидаты вдоль луча;
* `to_v19.py` переписывает лепестки v20-карты в формат v19 (56 байт, ламп версии 0), чтобы проверить и эту ветку.

Запуск под `spshell` из [SourcePawn](https://github.com/alliedmodders/sourcepawn) (сборка: `configure.py`, `ambuild`):

```bash
SPCOMP=<obj>/oldspcomp/linux-x86_64/oldspcomp SPSHELL=<obj>/spshell/linux-x86_64/spshell SP_ROOT=<sourcepawn> \
  ./run.sh map1.bsp map2.bsp
```

Ожидается `python brushes missing in SP: 0` и 0 во всех `mismatches`. Проверено на de_dust2, de_inferno, de_piranesi,
2000 (CS:S, v19 и v20), тестовых картах из [bsp_tool](https://github.com/snake-biscuits/bsp_tool) и
[ValveBSP](https://github.com/pySourceSDK/ValveBSP) (TF2, v20) и на v20-карте, переписанной в v19.

`sim.py` (нужен numpy) оценивает пользу на реальной карте: случайные пары игроков в точках из `.nav` (`nav.py` читает
CS:S `.nav` версий 5–9). Для полностью скрытых пар печатает, какая доля доказывается одним брашем так, как его ищет
плагин, и потолок для любого одного браша:

```bash
python3 sim.py de_dust2.bsp de_dust2.nav 11 1000
# hidden pairs 867; proven by one brush: 89% (any single brush: 93%), brush proofs per hidden pair 2.9
```
