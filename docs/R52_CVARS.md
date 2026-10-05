# SMAC Ultr@ R52 — таблица проверки кваров (`001_SMAC_Cvars.smx`)

Восстановлено эмуляцией `OnPluginStart` (по одному trie на квар: имя, тип сравнения, действие, значения, группа).
Действия: `kick` / `ban` (кодировка 2/3 — по совпадению с текстом cvar-описаний; высокая уверенность).

Важно для `smac_cvars` в #7: `cl_interpolate` в этой таблице **нет**; `net_fakelag/net_fakeloss/voice_*/cl_predict/cl_lagcompensation` — **kick**, не ban;
`cl_bobcycle` ожидается **0.8**; `fps_max` — between 30..1000; `cl_interp_ratio`/`cl_pred_optimize` — between 1..2; `mat_dxlevel` ≥ 80 (kick).

| Группа | Квар | Сравнение | Значение | Действие |
|---|---|---|---|---|
| Check_Hack | `0penscript` | nonexist |  | ban |
| Check_Hack | `aim_bot` | nonexist |  | ban |
| Check_Hack | `aim_fov` | nonexist |  | ban |
| Check_Hack | `fm_attackmode` | nonexist |  | ban |
| Check_Hack | `lua-engine` | nonexist |  | ban |
| Check_Hack | `lua_open` | nonexist |  | ban |
| Check_Hack | `maniadminhacker` | nonexist |  | ban |
| Check_Hack | `maniadmintakeover` | nonexist |  | ban |
| Check_Hack | `openscript` | nonexist |  | ban |
| Check_Hack | `openscript_version` | nonexist |  | ban |
| Check_Hack | `runnscript` | nonexist |  | ban |
| Check_Hack | `smadmintakeover` | nonexist |  | ban |
| Check_Hack | `tb_enabled` | nonexist |  | ban |
| Check_Hack | `run` | nonexist |  | ban |
| Check_Hack | `deathcorecssv86` | nonexist |  | ban |
| Check_Hack | `deathcorecssv34` | nonexist |  | ban |
| Check_Hack | `by_` | nonexist |  | ban |
| Check_Hack | `hacked` | nonexist |  | ban |
| Check_Hack | `prepareuranus` | nonexist |  | ban |
| Check_Hack | `zapuskscript` | nonexist |  | ban |
| Check_Hack | `openvirus` | nonexist |  | ban |
| Check_Hack | `open` | nonexist |  | ban |
| Check_Hack | `ExLua` | nonexist |  | ban |
| Check_Hack | `ZhykLua` | nonexist |  | ban |
| Check_Hack | `skillok` | nonexist |  | ban |
| Check_Hack | `hvb` | nonexist |  | ban |
| Check_Hack | `load_list` | nonexist |  | ban |
| Check_Hack | `game_list` | nonexist |  | ban |
| Check_Hack | `Madzal_LagServer` | nonexist |  | ban |
| Check_Hack | `openmadzal` | nonexist |  | ban |
| Check_Hack | `dc2013` | nonexist |  | ban |
| Check_Hack | `fuck_KAC` | nonexist |  | ban |
| Check_Hack | `fuck_SMAC` | nonexist |  | ban |
| Check_Hack | `Spammer` | nonexist |  | ban |
| Check_Hack | `openlua` | nonexist |  | ban |
| Check_Hack | `openslua` | nonexist |  | ban |
| Check_Hack | `openhack` | nonexist |  | ban |
| Check_Hack | `antiban` | nonexist |  | ban |
| Check_Hack | `openxcl` | nonexist |  | ban |
| Check_Hack | `Runlua` | nonexist |  | ban |
| Check_Hack | `dk` | nonexist |  | ban |
| Check_Hack | `file` | nonexist |  | ban |
| Check_Hack | `lua` | nonexist |  | ban |
| Check_Hack | `go` | nonexist |  | ban |
| Check_Hack | `sm_plugin` | nonexist |  | ban |
| Check_Hack | `Kentavr1kTakeOver` | nonexist |  | ban |
| Check_Hack | `Kentavr1kTakeOver_Information` | nonexist |  | ban |
| Check_Hack | `TakeOver_Password` | nonexist |  | ban |
| Check_Hack | `runscript` | nonexist |  | ban |
| Check_Hack | `NosorogManiTakeOver` | nonexist |  | ban |
| Check_Hack | `NosorogSmTakeOver` | nonexist |  | ban |
| Check_Hack | `NosorogServercfgDownload` | nonexist |  | ban |
| Check_Hack | `NosorogDownloadFile` | nonexist |  | ban |
| Check_Hack | `NosorogUploadFile` | nonexist |  | ban |
| Check_Changer | `cs_show_team` | nonexist |  | ban |
| Check_Changer | `starts` | nonexist |  | ban |
| Check_Hack | `NosorogSmallCheatMenu` | nonexist |  | ban |
| Check_Hack | `FunnyExploitByNosorog` | nonexist |  | ban |
| Check_Hack | `MNosorogcrashOver` | nonexist |  | ban |
| Check_Hack | `DownloadServerCfg` | nonexist |  | ban |
| Check_Hack | `AdminAddedByMrWhite` | nonexist |  | ban |
| Check_Hack | `TakeOverByMrWhite` | nonexist |  | ban |
| Check_Hack | `TakeOverByMrWhite_Information` | nonexist |  | ban |
| Check_Hack | `ManiNogganoooHack` | nonexist |  | ban |
| Check_Hack | `SmNogganoooHack` | nonexist |  | ban |
| Check_Hack | `bat_version` | nonexist |  | kick |
| Check_Hack | `beetlesmod_version` | nonexist |  | kick |
| Check_Hack | `est_version` | nonexist |  | kick |
| Check_Hack | `eventscripts_ver` | nonexist |  | kick |
| Check_Hack | `mani_admin_plugin_version` | nonexist |  | kick |
| Check_Hack | `metamod_version` | nonexist |  | kick |
| Check_Hack | `sourcemod_version` | nonexist |  | kick |
| Check_Hack | `zb_version` | nonexist |  | kick |
| Check_Hack | `voicerecord` | nonexist |  | kick |
| Check_Changer | `rragg_err_id` | nonexist |  | ban |
| Check_Changer | `ukrainaaa_id` | nonexist |  | ban |
| Check_Changer | `ghwazxnat_id` | nonexist |  | ban |
| Check_Changer | `ZhykLua_show_steam` | nonexist |  | ban |
| Check_Changer | `ZhykLua_steam_set_id` | nonexist |  | ban |
| Check_Changer | `ZhykLua_steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `PhaNToM_show_id` | nonexist |  | ban |
| Check_Changer | `PhaNToM_steam_set_id` | nonexist |  | ban |
| Check_Changer | `PhaNToM_steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `hooligan_show_id` | nonexist |  | ban |
| Check_Changer | `hooligan_steam_set_id` | nonexist |  | ban |
| Check_Changer | `hooligan_steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `hack` | nonexist |  | ban |
| Check_Changer | `hack-1` | nonexist |  | ban |
| Check_Changer | `hack-2` | nonexist |  | ban |
| Check_Changer | `hack-3` | nonexist |  | ban |
| Check_Changer | `cs_show_steam` | nonexist |  | ban |
| Check_Changer | `cs_steam_set_id` | nonexist |  | ban |
| Check_Changer | `cs_steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `aaa123_show_steam` | nonexist |  | ban |
| Check_Changer | `aaa123_steam_set_id` | nonexist |  | ban |
| Check_Changer | `aaa123_steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `no_KAC_show_steam` | nonexist |  | ban |
| Check_Changer | `no_KAC_steam_set_id` | nonexist |  | ban |
| Check_Changer | `no_KAC_steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `ru_show_steam` | nonexist |  | ban |
| Check_Changer | `ru_steam_set_id` | nonexist |  | ban |
| Check_Changer | `ru_steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `ru_set_id` | nonexist |  | ban |
| Check_Changer | `ru_set_random_id` | nonexist |  | ban |
| Check_Changer | `asd_show_steam` | nonexist |  | ban |
| Check_Changer | `asd_steam_set_id` | nonexist |  | ban |
| Check_Changer | `asd_steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `ServisHack_show_steam` | nonexist |  | ban |
| Check_Changer | `ServisHack_steam_set_id` | nonexist |  | ban |
| Check_Changer | `ServisHack_steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `tigr_show_steam` | nonexist |  | ban |
| Check_Changer | `tigr_steam_set_id` | nonexist |  | ban |
| Check_Changer | `tigr_steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `deathcore2013show_steam` | nonexist |  | ban |
| Check_Changer | `deathcore2013steam_set_id` | nonexist |  | ban |
| Check_CheatsC | `snd_show` | equal | 0.0 | ban |
| Check_Changer | `dcshow_steam` | nonexist |  | ban |
| Check_Changer | `dcsteam_set_id` | nonexist |  | ban |
| Check_Changer | `dcsteam_set_random_id` | nonexist |  | ban |
| Check_Changer | `show_steam` | nonexist |  | ban |
| Check_Changer | `steam_set` | nonexist |  | ban |
| Check_Changer | `steam_set_id` | nonexist |  | ban |
| Check_Changer | `steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `set_id` | nonexist |  | ban |
| Check_Changer | `set_random_id` | nonexist |  | ban |
| Check_Changer | `steam` | nonexist |  | ban |
| Check_Changer | `id` | nonexist |  | ban |
| Check_Changer | `random_id` | nonexist |  | ban |
| Check_Changer | `steam_random_id` | nonexist |  | ban |
| Check_Changer | `csx_show_steam` | nonexist |  | ban |
| Check_Changer | `csx_steamid` | nonexist |  | ban |
| Check_Changer | `csx_steamid_random` | nonexist |  | ban |
| Check_Changer | `steam_set_random_value` | nonexist |  | ban |
| Check_Changer | `connect_nick` | nonexist |  | ban |
| Check_Changer | `connect_set_nick` | nonexist |  | ban |
| Check_Changer | `ct_show_steam` | nonexist |  | ban |
| Check_Changer | `ct_steam_set_value` | nonexist |  | ban |
| Check_Changer | `ct_steam_set_random_value` | nonexist |  | ban |
| Check_Changer | `ct_emu_ran` | nonexist |  | ban |
| Check_Changer | `ct_emu_set` | nonexist |  | ban |
| Check_Changer | `cc_esp` | nonexist |  | ban |
| Check_Changer | `cc_steamid_random` | nonexist |  | ban |
| Check_Changer | `dc2013show_steam` | nonexist |  | ban |
| Check_Changer | `dc2013steam_set_id` | nonexist |  | ban |
| Check_Changer | `dc2013steam_set_random_id` | nonexist |  | ban |
| Check_Changer | `ms_chat` | nonexist |  | ban |
| Check_Changer | `ms_aimbot` | nonexist |  | ban |
| Check_Changer | `wallhack` | nonexist |  | ban |
| Check_Changer | `cheat_chat` | nonexist |  | ban |
| Check_Changer | `cheat_chams` | nonexist |  | ban |
| Check_Changer | `cheat_dlight` | nonexist |  | ban |
| Check_Changer | `byp_svc` | nonexist |  | ban |
| Check_Changer | `k0ntr011_aim` | nonexist |  | ban |
| Check_Changer | `esp` | nonexist |  | ban |
| Check_Changer | `aimbot` | nonexist |  | ban |
| Check_Changer | `ru_show_team` | nonexist |  | ban |
| Check_Changer | `show_team` | nonexist |  | ban |
| Check_CheatsC | `r_flashlightfov` | equal | 45.0 | kick |
| Check_CheatsC | `cl_wpn_sway_scale` | equal | 1.0 | kick |
| Check_CheatsC | `viewmodel_fov` | equal | 54.0 | kick |
| Check_CheatsC | `cl_bobcycle` | equal | 0.8 | kick |
| Check_CheatsC | `r_newflashlight` | equal | 1.0 | kick |
| Check_CheatsC | `r_flashlightoffsetx` | equal | 10.0 | kick |
| Check_CheatsC | `r_flashlightoffsety` | equal | -20.0 | kick |
| Check_CheatsC | `r_flashlightoffsetz` | equal | 24.0 | kick |
| Check_CheatsC | `cl_particleeffect_aabb_buffer` | equal | 2.0 | kick |
| Check_CheatsC | `r_propsmaxdist` | equal | 1200.0 | kick |
| Check_CheatsC | `mat_debug_process_halfscreen` | equal | 0.0 | kick |
| Check_CheatsC | `mat_debug_autoexposure` | equal | 0.0 | kick |
| Check_CheatsC | `mat_debugdepth` | equal | 0.0 | kick |
| Check_CheatsC | `mat_showlightmappage` | equal | -1.0 | kick |
| Check_CheatsC | `net_showevents` | equal | 0.0 | kick |
| Check_CheatsC | `cl_bob` | equal | 0.002 | kick |
| Check_CheatsC | `sv_pushaway_player_force` | equal | 200000.0 | kick |
| Check_CheatsC | `sv_pushaway_max_player_force` | equal | 10000.0 | kick |
| Check_CheatsC | `sv_showplayerhitboxes` | equal | 0.0 | kick |
| Check_CheatsC | `mat_diffuse` | equal | 1.0 | kick |
| Check_CheatsC | `cl_anglespeedkey` | equal | 0.67 | kick |
| Check_CheatsC | `cl_yawspeed` | equal | 210 | kick |
| Check_CheatsC | `mat_dxlevel` | greater | 80.0 | kick |
| Check_CheatsC | `mem_force_flush` | equal | 0.0 | ban |
| Check_CheatsC | `r_aspectratio` | equal | 0.0 | ban |
| Check_CheatsC | `cam_command` | equal | 0.0 | kick |
| Check_CheatsC | `cl_pred_optimize` | between | 1.0..2.0 | kick |
| Check_CheatsC | `net_chokeloop` | equal | 0.0 | kick |
| Check_CheatsC | `fps_max` | between | 30.0..1000.0 | kick |
| Check_CheatsC | `cl_interp_ratio` | between | 1.0..2.0 | kick |
| Check_CheatsC | `soundscape_fadetime` | equal | 3.0 | kick |
| Check_CheatsC | `r_JeepViewBlendToScale` | equal | 0.03 | kick |
| Check_CheatsC | `r_JeepViewBlendToTime` | equal | 1.5 | kick |
| Check_CheatsC | `r_JeepFOV` | equal | 90.0 | kick |
| Check_CheatsC | `r_flashlightfar` | equal | 750.0 | kick |
| Check_CheatsC | `r_flashlightlinear` | equal | 100.0 | kick |
| Check_CheatsC | `cl_sun_decay_rate` | equal | 0.05 | kick |
| Check_CheatsC | `cl_extrapolate_amount` | equal | 0.25 | kick |
| Check_CheatsC | `r_mapextents` | equal | 16384.0 | kick |
| Check_CheatsC | `cl_maxrenderable_dist` | equal | 3000.0 | kick |
| Check_CheatsC | `r_RainSplashPercentage` | equal | 20.0 | kick |
| Check_CheatsC | `r_RainRadius` | equal | 1500.0 | kick |
| Check_CheatsC | `r_RainSideVel` | equal | 130.0 | kick |
| Check_CheatsC | `r_SnowParticles` | equal | 500.0 | kick |
| Check_CheatsC | `r_SnowInsideRadius` | equal | 256.0 | kick |
| Check_CheatsC | `r_SnowOutsideRadius` | equal | 1024.0 | kick |
| Check_CheatsC | `cl_sporeclipdistance` | equal | 512.0 | kick |
| Check_CheatsC | `default_fov` | equal | 90.0 | kick |
| Check_CheatsC | `cl_bobup` | equal | 0.5 | kick |
| Check_CheatsC | `cl_pitchdown` | equal | 89.0 | ban |
| Check_CheatsC | `cl_pitchup` | equal | 89.0 | ban |
| Check_CheatsC | `cl_clock_correction_force_server_tick` | equal | 999.0 | ban |
| Check_CheatsC | `r_avglight` | equal | 1.0 | kick |
| Check_CheatsC | `mat_loadtextures` | equal | 1.0 | kick |
| Check_CheatsC | `cl_extrapolate` | equal | 1.0 | kick |
| Check_CheatsC | `r_drawropes` | equal | 1.0 | kick |
| Check_CheatsC | `r_drawsprites` | equal | 1.0 | kick |
| Check_CheatsC | `r_JeepViewBlendTo` | equal | 1.0 | kick |
| Check_CheatsC | `cl_drawhud` | equal | 1.0 | kick |
| Check_CheatsC | `mat_viewportscale` | equal | 1.0 | kick |
| Check_CheatsC | `r_drawviewmodel` | equal | 1.0 | kick |
| Check_CheatsC | `r_drawtranslucentrenderables` | equal | 1.0 | kick |
| Check_CheatsC | `r_drawopaquerenderables` | equal | 1.0 | kick |
| Check_CheatsC | `fog_enableskybox` | equal | 1.0 | kick |
| Check_CheatsC | `mat_drawwater` | equal | 1.0 | kick |
| Check_CheatsC | `r_RainSimulate` | equal | 1.0 | kick |
| Check_CheatsC | `r_DrawRain` | equal | 1.0 | kick |
| Check_CheatsC | `r_SnowEnable` | equal | 1.0 | kick |
| Check_CheatsC | `r_SnowSpeedScale` | equal | 1.0 | kick |
| Check_CheatsC | `r_VehicleViewClamp` | equal | 1.0 | kick |
| Check_CheatsC | `cl_predictweapons` | equal | 1.0 | kick |
| Check_CheatsC | `cl_predict` | equal | 1.0 | kick |
| Check_CheatsC | `cl_lagcompensation` | equal | 1.0 | kick |
| Check_CheatsC | `net_droppackets` | equal | 0.0 | kick |
| Check_CheatsC | `developer` | equal | 0.0 | kick |
| Check_CheatsC | `r_novis` | equal | 0.0 | kick |
| Check_CheatsC | `showtriggers` | equal | 0.0 | kick |
| Check_CheatsC | `g_debug_ragdoll_visualize` | equal | 0.0 | kick |
| Check_CheatsC | `fish_debug` | equal | 0.0 | kick |
| Check_CheatsC | `mat_stub` | equal | 0.0 | kick |
| Check_CheatsC | `r_flashlightlockposition` | equal | 0.0 | kick |
| Check_CheatsC | `r_flashlightconstant` | equal | 0.0 | kick |
| Check_CheatsC | `r_flashlightquadratic` | equal | 0.0 | kick |
| Check_CheatsC | `r_flashlightvisualizetrace` | equal | 0.0 | kick |
| Check_CheatsC | `hidehud` | equal | 0.0 | kick |
| Check_CheatsC | `particle_simulateoverflow` | equal | 0.0 | kick |
| Check_CheatsC | `cl_showerror` | equal | 0.0 | kick |
| Check_CheatsC | `cl_predictionlist` | equal | 0.0 | kick |
| Check_CheatsC | `fog_override` | equal | 0.0 | kick |
| Check_CheatsC | `r_debugcheapwater` | equal | 0.0 | kick |
| Check_CheatsC | `cl_drawshadowtexture` | equal | 0.0 | kick |
| Check_CheatsC | `mat_showwatertextures` | equal | 0.0 | kick |
| Check_CheatsC | `mat_showframebuffertexture` | equal | 0.0 | kick |
| Check_CheatsC | `mat_showcamerarendertarget` | equal | 0.0 | kick |
| Check_CheatsC | `mat_hsv` | equal | 0.0 | kick |
| Check_CheatsC | `mat_yuv` | equal | 0.0 | kick |
| Check_CheatsC | `mat_force_bloom` | equal | 0.0 | kick |
| Check_CheatsC | `mat_debug_bloom` | equal | 0.0 | kick |
| Check_CheatsC | `mat_leafvis` | equal | 0.0 | kick |
| Check_CheatsC | `mat_surfacemat` | equal | 0.0 | kick |
| Check_CheatsC | `mat_surfaceid` | equal | 0.0 | kick |
| Check_CheatsC | `mat_bumpbasis` | equal | 0.0 | kick |
| Check_CheatsC | `mat_debugalttab` | equal | 0.0 | kick |
| Check_CheatsC | `cl_winddir` | equal | 0.0 | kick |
| Check_CheatsC | `cl_windspeed` | equal | 0.0 | kick |
| Check_CheatsC | `r_RainHack` | equal | 0.0 | kick |
| Check_CheatsC | `r_RainProfile` | equal | 0.0 | kick |
| Check_CheatsC | `cl_leveloverviewmarker` | equal | 0.0 | kick |
| Check_CheatsC | `ent_messages_draw` | equal | 0.0 | kick |
| Check_CheatsC | `sv_noclipduringpause` | equal | 0.0 | kick |
| Check_CheatsC | `sv_showlagcompensation` | equal | 0.0 | kick |
| Check_CheatsC | `host_framerate` | equal | 0.0 | kick |
| Check_CheatsC | `r_showenvcubemap` | equal | 0.0 | kick |
| Check_CheatsC | `mat_normalmaps` | equal | 0.0 | kick |
| Check_CheatsC | `r_visualizetraces` | equal | 0.0 | kick |
| Check_CheatsC | `r_visualizelighttraces` | equal | 0.0 | kick |
| Check_CheatsC | `r_modelwireframedecal` | equal | 0.0 | kick |
| Check_CheatsC | `sv_showimpacts` | equal | 0.0 | kick |
| Check_CheatsC | `r_drawlights` | equal | 0.0 | kick |
| Check_CheatsC | `mat_luxels` | equal | 0.0 | kick |
| Check_CheatsC | `vgui_drawtree` | equal | 0.0 | kick |
| Check_CheatsC | `cl_entityreport` | equal | 0.0 | kick |
| Check_CheatsC | `cl_flushentitypacket` | equal | 0.0 | kick |
| Check_CheatsC | `cl_ignorepackets` | equal | 0.0 | kick |
| Check_CheatsC | `net_fakeloss` | equal | 0.0 | kick |
| Check_CheatsC | `net_fakelag` | equal | 0.0 | kick |
| Check_CheatsC | `voice_inputfromfile` | equal | 0.0 | kick |
| Check_CheatsC | `voice_loopback` | equal | 0.0 | kick |
| Check_CheatsC | `cl_drawleaf` | equal | -1.0 | kick |
| Check_CheatsC | `cl_pdump` | equal | -1.0 | kick |
| Check_CheatsC | `pwatchent` | equal | -1.0 | kick |
| Check_CheatsC | `r_farz` | equal | -1.0 | kick |
| Check_CheatsC | `fog_start` | equal | -1.0 | kick |
| Check_CheatsC | `fog_end` | equal | -1.0 | kick |
| Check_CheatsC | `fog_startskybox` | equal | -1.0 | kick |
| Check_CheatsC | `fog_endskybox` | equal | -1.0 | kick |
| Check_CheatsC | `r_partition_level` | equal | -1.0 | kick |
| Check_CheatsC | `cl_clock_correction` | equal | 1.0 | ban |
| Check_CheatsC | `cl_phys_timescale` | equal | 1.0 | ban |
| Check_CheatsC | `fog_enable` | equal | 1.0 | ban |
| Check_CheatsC | `r_drawbeams` | equal | 1.0 | ban |
| Check_CheatsC | `r_drawbrushmodels` | equal | 1.0 | ban |
| Check_CheatsC | `r_drawdecals` | equal | 1.0 | ban |
| Check_CheatsC | `r_drawentities` | equal | 1.0 | ban |
| Check_CheatsC | `r_drawopaqueworld` | equal | 1.0 | ban |
| Check_CheatsC | `r_drawothermodels` | equal | 1.0 | ban |
| Check_CheatsC | `r_drawparticles` | equal | 1.0 | ban |
| Check_CheatsC | `r_drawskybox` | equal | 1.0 | ban |
| Check_CheatsC | `r_drawtranslucentworld` | equal | 1.0 | ban |
| Check_CheatsC | `r_skybox` | equal | 1.0 | ban |
| Check_CheatsC | `cl_leveloverview` | equal | 0.0 | ban |
| Check_CheatsC | `cl_overdraw_test` | equal | 0.0 | ban |
| Check_CheatsC | `cl_showevents` | equal | 0.0 | ban |
| Check_CheatsC | `mat_fillrate` | equal | 0.0 | ban |
| Check_CheatsC | `mat_measurefillrate` | equal | 0.0 | ban |
| Check_CheatsC | `mat_proxy` | equal | 0.0 | ban |
| Check_CheatsC | `mat_showlowresimage` | equal | 0.0 | ban |
| Check_CheatsC | `mat_wireframe` | equal | 0.0 | ban |
| Check_CheatsC | `r_colorstaticprops` | equal | 0.0 | ban |
| Check_CheatsC | `r_dispwalkable` | equal | 0.0 | ban |
| Check_CheatsC | `r_drawclipbrushes` | equal | 0.0 | ban |
| Check_CheatsC | `r_drawmodelstatsoverlay` | equal | 0.0 | ban |
| Check_CheatsC | `r_drawrenderboxes` | equal | 0.0 | ban |
| Check_CheatsC | `r_shadowwireframe` | equal | 0.0 | ban |
| Check_CheatsC | `r_visocclusion` | equal | 0.0 | ban |
| Check_CheatsC | `snd_visualize` | equal | 0.0 | ban |
| Check_CheatsC | `vcollide_wireframe` | equal | 0.0 | ban |
| Check_CheatsC | `mat_texture_list` | equal | 0.0 | ban |
