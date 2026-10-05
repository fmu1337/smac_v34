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
| `dbgsym.py` | имена и адреса глобалов из `.dbg.symbols` (в R51 часть имён не обфусцирована) |

Пример:

```bash
python3 xref.py r52/addons/sourcemod/plugins/001_SMAC_Global.smx 'PSilent'   # base_*.bin + где используется строка
python3 run_chain.py r52/addons/sourcemod/plugins/001_SMAC_Global.smx OnPlayerRunCmd out.pkl '15e0d0:PSilent [Active Mode]'
python3 crep.py r52/addons/sourcemod/plugins/001_SMAC_Global.smx out.pkl OnPlayerRunCmd
```

Обозначения в отчётах: `gXXXX` — глобал по адресу (`{=N}` — значение после инициализации),
`ang0/1/2`, `btn`, `mouse0/1`, `cmdnum`, `tick`, `vel0..2` — аргументы `OnPlayerRunCmd`;
`*` — ветка, необходимая для достижения детекта (по CFG). Код написан «на коленке», пути к файлам относительные.
