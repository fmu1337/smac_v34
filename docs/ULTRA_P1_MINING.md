# Ultr@ P1 mining → v34 port notes

Sources: R52 `smac.cfg` EN/RU comments, `smacr52fix.txt`, `R52_data.bin` module labels. Soft defaults for pub.

### smac_NoSpamWeapon_MaxW
- **Файлы:** v34 `smac_nospamweapon.sp`
- **Условие:** count `drop` commands; signed `0` off / `-N` kick / `+N` ban
- **Default:** `0` (Ultr@ often `-25`)

### Airstuck / Airstuck: Fast Detect
- **Файлы:** `smac_ssac.sp` + `smac_Airstuck_reaction` `0..3`
- **FD:** tickcount reuse streak == 2; normal > 4
- **Default reaction:** `1` (admin notice)

### smac_FL_Ctrl / DDoS_Ctrl / Voice_Ctrl
- **Файлы:** `smac_fakelag.sp`
- **FL:** signed %% loss/choke (abs/100), soft `0`
- **DDoS:** RunCmd/sec > tick+8 while FL enabled
- **Voice:** mute `voice_loopback` / `voice_inputfromfile` when `smac_Voice_Ctrl 1`

### smac_eyetest_reaction_Advanced
- **Cfg modules:** Backtrack A/B only
- **Порт:** cvar alias on `smac_backtrack` (logic already in Mode A/B)

### Spinhack Ultr@
- **Файлы:** `smac_spinhack.sp` — cvars `smac_spinhack_angle` (default 1440) / `seconds` (15)
- Ultr@-leaning tune: `900` / `5` (not confirmed in binary; optional)

### smac_css_CheatCFG
- **Файлы:** `smac_cheatcfg.sp`
- **Условие:** jumpthrow (nade fire ≤0.10s after jump) ×3; fast weapon switch ×8 / 0.5s
- **Encoding:** `0` off; `1/4` notice; `2/5` kick; `3/6` ban; `>3` league (stricter)
- **Default:** `0`

### NoS_NoR / NoR_Ban
- Already in `smac_norecoil` (P0)

### Control_Entity
- Alias cvar on `smac_entityspam`
