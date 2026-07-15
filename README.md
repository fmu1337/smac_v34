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
