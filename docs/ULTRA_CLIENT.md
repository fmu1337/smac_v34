# smac_ultra_client — частота usercmd и настройки клиента из SMAC Ultr@ R52

Логика переписана по декомпиляции `001_SMAC_Global.smx` SMAC Ultr@ R52 (декомпилятор `tools/r52re/decomp.py`,
спецификация `docs/R52_SPEC.md` §0.1, §5; оба лежат в ветке с декодом). Кода Ultr@ здесь нет, расширение
`Ultr@Tools` не нужно. Собирается SourceMod 1.6 (CS:S v34) и новее.

## Детекты

| Детект | Условие | Квар |
|---|---|---|
| **Impulse Spam** | больше `smac_css_Impulse` (12) cmd с impulse (фонарик, спрей, …) за одну секунду. В R52 — всегда кик | `smac_css_Impulse` |
| **Sensitivity** | `sensitivity` вне [1; 20]. В R52 — кик (`SMAC_Sensitivity_L` / `_H`); здесь сообщается один раз за заход | `smac_ultra_sensitivity_limits` |
| **Sensitivity Change Spam** | значение `sensitivity` (запрос раз в минуту) менялось больше `|N|` раз за карту | `smac_antispam_Mouse_Sensitivity` |
| **FakeSendPacket[Max]** | usercmd в секунду больше `ceil(тикрейт · SpeedUp)` (80 на 66 тиках; при ≥ 2× тикрейта секунда считается за 4) больше `|SpeedLimitDetect|` секунд подряд | `smac_SpeedUp`, `smac_SpeedLimitDetect` |
| **FakeSendPacket[Min]** | usercmd в секунду меньше `round(тикрейт · 0.2)` (13) больше `2·|SpeedLimitDetect|` секунд подряд | `smac_SpeedLimitDetect` |

FakeSendPacket не выносится, если клиент шлёт или получает ≤ 25 пакетов/с (это обычный лаг или низкий FPS) или если
исходящие данные и пакеты сервера к клиенту оба больше чем в 2.9 раза превышают входящие (условия R52). Клиенты
в таймауте не проверяются.

## Квары

| Квар | По умолчанию | В R52 | Значения |
|---|---|---|---|
| `smac_css_Impulse` | 12 | 12 | лимит в секунду, 0 выкл; превышение — кик |
| `smac_ultra_sensitivity_limits` | 1 | кик | 0 выкл, 1 уведомление, 2 кик |
| `smac_antispam_Mouse_Sensitivity` | −5 | −5 | `+N` бан, `−N` кик, 0 выкл |
| `smac_SpeedUp` | 1.2 | 1.2 | множитель тикрейта, 0 выкл |
| `smac_SpeedLimitDetect` | −7 | −7 | `+N` бан, `−N` кик, 0 выкл |
| `smac_ultra_client_notice_only` | 1 | — | 1 — все кики и баны модуля заменяются уведомлением |
| `smac_ultra_admin_immune` | 1 | — | админы с флагом ban или root не наказываются |

**По умолчанию только уведомления** (`smac_ultra_client_notice_only 1`). Кик и бан, как в R52, понижаются на ступень
при среднем пинге ≥ 150 мс и ещё на ступень при avg packets ≤ 70% тикрейта.

## Отличия от R52

* Первое значение `sensitivity` не считается сменой (в R52 считается, поэтому там фактически на одну смену меньше).
* Тикрейт берётся с сервера; в R52 — константа 66.
* Не перенесены:
  * **DDoS** и ветка `smac_FL_Ctrl` — эвристики на отношениях средних потоков данных, плохо проверяемы без сервера;
  * **Eyetest 01–03** — в master это уже делает `smac_eyetest` (повтор cmdnum, подмена tickcount и кнопок);
  * **Backtrack Mode:A** — относится к `smac_ultra_netcode`.

## Риски ложных срабатываний

* **Sensitivity** ниже 1 у части игроков нормальна (0.8 и т.п.), поэтому по умолчанию только уведомление.
* **FakeSendPacket[Max]** после долгого фриза клиента: пачка накопленных cmd. Нужно больше 7 секунд подряд.
* **FakeSendPacket[Min]** при очень низком FPS: гейт по пакетам должен это отсекать, но на живом сервере не проверялось.
* **Impulse Spam**: фонарик на колесе мыши даёт 15–20 impulse в секунду.

## Как проверять

1. Положить `smac_ultra_client.smx` в `plugins/`, оставить значения по умолчанию (только уведомления).
2. Поиграть с разной `sensitivity`, с низким FPS и с потерями пакетов (`net_fakeloss` на тестовом сервере).
3. Смотреть `logs/SMAC.log` по `smac_ultra_client`, потом снимать `smac_ultra_client_notice_only`.
