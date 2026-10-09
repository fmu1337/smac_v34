# r52re — разбор SMAC Ultr@ R52 (SmartPawn)

Инструменты, которыми декодирована логика `001_SMAC_Global.smx` из R52 (см. `docs/R52_DECODED.md`).
Бинарники Ultr@ в репозиторий **не** кладём — положите распакованный архив в `./r52/` рядом со скриптами.

Требуется Python 3.10+, без внешних зависимостей.

| Файл | Что делает |
|------|------------|
| `smx.py`, `dis.py`, `ops.json` | парсер SMX (FFPS+zlib) и дизассемблер SourcePawn v1 |
| `emu2.py`, `sym.py` | concolic-эмулятор VM: символьные аргументы/глобалы, ветвление по символьным условиям |
| `run_apl.py` | прогон `AskPluginLoad2` → расшифровка всех строк SmartPawn (`Format("%s%c%c…")`) |
| `host.py`, `hybrid.py` | модель SM-хоста (квары из `smac.cfg`, `OnPluginStart/OnConfigsExecuted/OnMapStart/OnClientPutInServer`), классификация глобалов: пул констант / per-client состояние |
| `directed2.py`, `run_chain.py`, `run_chain_pub.py` | направленный поиск пути к блоку детекта (CFG-reachability + отсечение) |
| `crep.py`, `svar.py` | отчёты: условия на пути к детекту, кто пишет переменную состояния |
| `decomp.py` | **декомпилятор SP1 → псевдокод**: свёртка XOR-пар и opaque-предикатов по памяти после init, `&&`/`||` на стыках, удаление мёртвых веток, инлайн мелких функций; `--base hbase.bin --wr wr.pkl` |
| `wr.py` | межпроцедурный анализ записей в глобалы → какие базы константны после init (нужно `decomp.py`) |
| `dbgsym.py` | имена и адреса глобалов из `.dbg.symbols` (в R51 часть имён не обфусцирована) |

Пример (декомпиляция):

```bash
python3 wr.py r52/addons/sourcemod/plugins/001_SMAC_Global.smx wr_global.pkl
python3 decomp.py r52/addons/sourcemod/plugins/001_SMAC_Global.smx Accurate_Analysis_Module --base hbase_global.bin --wr wr_global.pkl
```

`hbase_global.bin` — память после прогона `AskPluginLoad2`/`OnPluginStart` (`run_apl.py` / `host.py`, pickle от `bytes`).

Пример (поиск путей, старый способ):

```bash
python3 xref.py r52/addons/sourcemod/plugins/001_SMAC_Global.smx 'PSilent'   # base_*.bin + где используется строка
python3 run_chain.py r52/addons/sourcemod/plugins/001_SMAC_Global.smx OnPlayerRunCmd out.pkl '15e0d0:PSilent [Active Mode]'
python3 crep.py r52/addons/sourcemod/plugins/001_SMAC_Global.smx out.pkl OnPlayerRunCmd
```

Обозначения в отчётах: `gXXXX` — глобал по адресу (`{=N}` — значение после инициализации),
`ang0/1/2`, `btn`, `mouse0/1`, `cmdnum`, `tick`, `vel0..2` — аргументы `OnPlayerRunCmd`;
`*` — ветка, необходимая для достижения детекта (по CFG). Код написан «на коленке», пути к файлам относительные.
