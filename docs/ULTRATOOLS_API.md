# Ultr@Tools API (reversed)

Binary: `Ultr@Tools.ext.so` / `.dll` — **"Ultr@" Tools** 1.0.1 (Jan 30 2016)  
Author string: `The Terminator` · URL: `http://club-ultra.info`  
Log tag: `Ultr@Tools`

Used by SMAC Ultr@ `001_SMAC_Core/Client/Global.smx` (`SetBan`, `ClearBanList`, `GetCmdStr`, `TimerUp`, …).

> Closed extension is a known crash/load hazard on **SM 1.9+ / 1.10+** (IBinTools).  
> v34 ships `smac_ultratools.sp` — pure-SP shim that registers the **same native names** when the real `.ext` is not loaded.

---

## Natives (registration order in `.so`)

| Native | C++ / notes | Shim behaviour |
|--------|-------------|----------------|
| `GF()` | Unknown short native (`sm_GF`) | Returns `1` if shim enabled |
| `TimerUp(client)` | Starts ban-release ticker (extension uses `IThreader`) | Marks client timer; fires `OnTimerUp` |
| `TimerDown(client)` | Cancels ticker | Clears mark; fires `OnTimerDown` |
| `GetCmdStr(String:buf[], maxlen)` | Last command string for Ultra logs | Last `AddCommandListener` capture |
| `SetBan(client, duration, banLevel)` | `_Z6SetBanjij` = `(uint, int, uint)`; internal `ban_list` | Trie by SteamID + expire; starts timer |
| `ClearBanList()` | `ClearBanListv` / `dump_ban_list` helpers | Wipe trie + client slots |

### SetBan semantics (best effort)

- `client` — client index (or userid if `> MaxClients`, shim resolves via `GetClientOfUserId`)
- `duration` — minutes (`>0` timed, `0` short hold ~30s, `<0` long/permanent marker)
- `banLevel` — Ultra ban tier (`smac_Ban_Level` / Advanced duration family)

Internal symbols: `check_ban_list`, `delete_from_ban_list`, `dump_ban_list`, `ban_item`, `FireTicker`.

---

## Forwards

| Forward | Source |
|---------|--------|
| `OnBanReleased(client)` | Binary + SMAC Core/Client |
| `OnTimerDown(client)` | Binary string table |
| `OnTimerUp(client)` | SMAC Global/Core references |

---

## Include / plugin

- `addons/sourcemod/scripting/include/ultratools.inc` — optional native decls  
- `addons/sourcemod/scripting/smac_ultratools.sp` — shim (`smac_ultratools_shim` cvar, `sm_ultra_banlist`, `sm_ultra_clearbans`)

```sourcepawn
#include <ultratools>
// MarkNativeAsOptional via __ext when REQUIRE_EXTENSIONS unset

public OnBanReleased(client)
{
	// Ultra timed ban slot freed
}
```

---

## Diff vs closed `.ext`

| | Closed Ultr@Tools.ext | v34 shim |
|--|----------------------|----------|
| Natives | yes | yes (if `.ext` absent) |
| Threaded ban release | `IThreader` | 1s game timer |
| Crash on SM 1.10+ | often | no |
| SoftDetector / AntiDLL | no (not in this ext) | no |
| WH Ignore | no | no |

---

## Live test

1. Load `smac_ultratools.smx` **without** `Ultr@Tools.ext.so`.  
2. `sm plugins list` → shim log “providing natives”.  
3. From another test plugin: `SetBan(client, 1, 1)`, wait, expect `OnBanReleased`.  
4. `sm_ultra_banlist` / `sm_ultra_clearbans`.  
5. Do **not** load closed `.ext` on SM 6572 crash repro hosts.
