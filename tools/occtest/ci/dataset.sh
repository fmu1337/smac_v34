#!/usr/bin/env bash
# Collect an smac_wallhack occluder dataset on a CS:S v34 server.
#
# The dedicated server is assembled the same way as the sourcemod-css34 smoke
# test: testing/scripts/fetch-server.sh, then apply-valve-rc-fix.sh and
# apply-srcds-patch.sh. Metamod is the package install-addons.sh downloads
# when MM_PACKAGE is unset (mmsource 1.10.6 css34). SourceMod is 1.6.4 css34,
# which is the compiler this dataset was written for; that tarball does not
# ship Metamod binaries.
#
#   dataset.sh prepare     # download and patch srcds into SERVER_DIR
#   dataset.sh install     # 32-bit deps, MM, SM 1.6.4, compile the three plugins
#   dataset.sh run MAP     # one map: bots, sample, check_dataset.py
#
# Plugin sources are compiled as they are. A warning or error from spcomp stops
# the run. Nothing in this script edits .sp files.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SMAC_DIR="$(cd "${SMAC_DIR:-${HERE}/../../..}" && pwd)"
CSS34_DIR="${CSS34_DIR:-}"
SERVER_DIR="${SERVER_DIR:-${SMAC_DIR}/.ci-server}"
CACHE_DIR="${CACHE_DIR:-${SMAC_DIR}/.ci-cache}"
SM_URL="${SM_URL:-https://bitbucket.org/_4/smdrop-1.6/downloads/sourcemod-1.6.4-stable-git4626-css34-linux.tar.gz}"
PORT="${PORT:-27015}"
MAXPLAYERS="${MAXPLAYERS:-32}"
BOT_QUOTA="${BOT_QUOTA:-20}"
MINUTES="${MINUTES:-15}"
MIN_RECORDS="${MIN_RECORDS:-10000}"
# live: pairs of bots walking the nav mesh. synth: pairs of standing spots anywhere on the map, no bots needed.
MODE="${MODE:-live}"
STATUS_EVERY="${STATUS_EVERY:-300}"
OUT_DIR="${OUT_DIR:-}"
EXTRA_MAP_URLS="${EXTRA_MAP_URLS:-}"
RCON_PASSWORD="${RCON_PASSWORD:-}"

usage() {
  echo "usage: dataset.sh prepare|install|run MAP" >&2
  exit 2
}

need_css34() {
  if [[ -z "${CSS34_DIR}" || ! -x "${CSS34_DIR}/testing/scripts/fetch-server.sh" ]]; then
    echo "CSS34_DIR must be a sourcemod-css34 checkout (testing/scripts/fetch-server.sh)" >&2
    exit 1
  fi
  chmod +x "${CSS34_DIR}/testing/scripts/"*.sh
}

prepare_server() {
  need_css34
  echo "Fetching CS:S v34 server the way sourcemod-css34 smoke test does"
  SERVER_DIR="${SERVER_DIR}" CACHE_DIR="${CACHE_DIR}" \
    "${CSS34_DIR}/testing/scripts/fetch-server.sh"
  # Same follow-up as .github/workflows/test-server.yml when apply_srcds_patch=1.
  SERVER_DIR="${SERVER_DIR}" "${CSS34_DIR}/testing/scripts/apply-valve-rc-fix.sh"
  SERVER_DIR="${SERVER_DIR}" "${CSS34_DIR}/testing/scripts/apply-srcds-patch.sh"
  echo "Server ready at ${SERVER_DIR}"
}

run_install_deps() {
  need_css34
  if [[ "${SKIP_DEPS:-0}" == "1" ]]; then
    echo "SKIP_DEPS=1"
    return 0
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    "${CSS34_DIR}/testing/scripts/install-deps.sh"
  else
    sudo -E bash "${CSS34_DIR}/testing/scripts/install-deps.sh"
  fi
}

compile_clean() {
  local src="$1" out="$2" log
  log="$(mktemp)"
  set +e
  "${SPCOMP}" \
    -i"${SMAC_DIR}/addons/sourcemod/scripting/include" \
    -i"${SM_INCLUDE}" \
    "${src}" -o"${out}" >"${log}" 2>&1
  local rc=$?
  set -e
  cat "${log}"
  if [[ "${rc}" -ne 0 ]] || grep -E -q ': (warning|error)|Fatal error' "${log}"; then
    echo "FAIL: $(basename "${src}") did not compile cleanly (spcomp exit ${rc})" >&2
    rm -f "${log}"
    exit 1
  fi
  rm -f "${log}"
  if [[ ! -s "${out}" ]]; then
    echo "FAIL: spcomp wrote no output for ${src}" >&2
    exit 1
  fi
}

install_addons() {
  need_css34
  run_install_deps
  echo "Installing Metamod via sourcemod-css34 install-addons.sh and SourceMod 1.6.4"
  # Leave MM_URL / MM_PACKAGE unset so install-addons.sh uses its own default.
  unset MM_PACKAGE MM_URL USE_BUILT_MM BUILT_MM_DIR BUILT_MM_PACKAGE || true
  SERVER_DIR="${SERVER_DIR}" CACHE_DIR="${CACHE_DIR}" SM_URL="${SM_URL}" \
    "${CSS34_DIR}/testing/scripts/install-addons.sh"

  local sm_root="${SERVER_DIR}/cstrike/addons/sourcemod"
  SPCOMP="${sm_root}/scripting/spcomp"
  SM_INCLUDE="${sm_root}/scripting/include"
  chmod +x "${SPCOMP}"
  local plugins="${sm_root}/plugins"
  mkdir -p "${plugins}"
  compile_clean "${SMAC_DIR}/addons/sourcemod/scripting/smac.sp" "${plugins}/smac.smx"
  compile_clean "${SMAC_DIR}/addons/sourcemod/scripting/smac_wallhack.sp" "${plugins}/smac_wallhack.smx"
  compile_clean "${SMAC_DIR}/tools/occtest/occ_dataset.sp" "${plugins}/occ_dataset.smx"
  mkdir -p "${sm_root}/translations/ru"
  cp -f "${SMAC_DIR}/addons/sourcemod/translations/smac.phrases.txt" "${sm_root}/translations/smac.phrases.txt"
  cp -f "${SMAC_DIR}/addons/sourcemod/translations/ru/smac.phrases.txt" "${sm_root}/translations/ru/smac.phrases.txt"
  echo "Plugins installed: smac.smx smac_wallhack.smx occ_dataset.smx"
}

valid_map() {
  [[ "$1" =~ ^[A-Za-z0-9_.\$\-]+$ ]]
}

download_extra_map() {
  local map="$1" spec name bsp nav
  [[ -n "${EXTRA_MAP_URLS}" ]] || return 1
  local IFS=','
  for spec in ${EXTRA_MAP_URLS}; do
    name="${spec%%=*}"
    [[ "${name}" == "${map}" ]] || continue
    spec="${spec#*=}"
    bsp="${spec%%|*}"
    nav=""
    if [[ "${spec}" == *"|"* ]]; then
      nav="${spec#*|}"
    fi
    echo "Downloading custom map ${map}"
    curl -fL --retry 5 --retry-delay 3 -o "${SERVER_DIR}/cstrike/maps/${map}.bsp.partial" "${bsp}"
    mv "${SERVER_DIR}/cstrike/maps/${map}.bsp.partial" "${SERVER_DIR}/cstrike/maps/${map}.bsp"
    if [[ -n "${nav}" ]]; then
      curl -fL --retry 5 --retry-delay 3 -o "${SERVER_DIR}/cstrike/maps/${map}.nav.partial" "${nav}"
      mv "${SERVER_DIR}/cstrike/maps/${map}.nav.partial" "${SERVER_DIR}/cstrike/maps/${map}.nav"
    fi
    CUSTOM_MAP=1
    return 0
  done
  return 1
}

write_server_cfg() {
  local cfg="${SERVER_DIR}/cstrike/cfg/server.cfg"
  mkdir -p "${SERVER_DIR}/cstrike/cfg"
  touch "${cfg}"
  if grep -q '^// occ-dataset-cvars$' "${cfg}"; then
    sed -i '/^\/\/ occ-dataset-cvars$/,/^\/\/ occ-dataset-cvars-end$/d' "${cfg}"
  fi
  cat >>"${cfg}" <<EOF
// occ-dataset-cvars
hostname "occ dataset test"
rcon_password "${RCON_PASSWORD}"
sv_password "${RCON_PASSWORD}"
sv_cheats 1
bot_quota ${BOT_QUOTA}
bot_quota_mode normal
bot_join_after_player 0
mp_autoteambalance 0
mp_limitteams 0
mp_timelimit 0
mp_maxrounds 0
mp_roundtime 9
mp_freezetime 0
sv_logfile 1
log on
// occ-dataset-cvars-end
EOF
}

rcon() {
  python3 "${HERE}/rcon.py" 127.0.0.1 "${PORT}" "${RCON_PASSWORD}" "$1" "${2:-20}"
}

rcon_try() {
  local out err rc
  out="$(mktemp)"
  err="$(mktemp)"
  set +e
  python3 "${HERE}/rcon.py" 127.0.0.1 "${PORT}" "${RCON_PASSWORD}" "$1" "${2:-20}" >"${out}" 2>"${err}"
  rc=$?
  set -e
  cat "${out}"
  if [[ "${rc}" -ne 0 ]]; then
    cat "${err}" >&2
  fi
  rm -f "${out}" "${err}"
  return "${rc}"
}

wait_rcon() {
  local i
  for i in $(seq 1 40); do
    if rcon_try "status" 5 >/dev/null; then
      return 0
    fi
    if ! kill -0 "${SRCDS_PID}" 2>/dev/null; then
      echo "srcds exited while waiting for rcon" >&2
      return 1
    fi
    sleep 2
  done
  echo "timeout waiting for rcon on 127.0.0.1:${PORT}" >&2
  return 1
}

snapshot_marks() {
  CONSOLE_MARK=0
  SRCDS_MARK=0
  [[ -f "${CONSOLE_LOG}" ]] && CONSOLE_MARK="$(wc -l <"${CONSOLE_LOG}" | tr -d ' ')"
  [[ -f "${SRCDS_OUT}" ]] && SRCDS_MARK="$(wc -l <"${SRCDS_OUT}" | tr -d ' ')"
}

map_is_up() {
  local spec file mark
  local -a specs=("${CONSOLE_LOG}:${CONSOLE_MARK:-0}" "${SRCDS_OUT}:${SRCDS_MARK:-0}")
  for spec in "${specs[@]}"; do
    mark="${spec##*:}"
    file="${spec%%:*}"
    [[ -f "${file}" ]] || continue
    # awk, not grep -q in a pipe: pipefail would turn SIGPIPE into a miss.
    if awk -v start="$((mark + 1))" -v map="${MAP}" '
      NR >= start && (index($0, "Started map \"" map "\"") || index($0, "Loading map \"" map "\"") || index($0, "Mapchange to " map)) {
        found = 1
        exit
      }
      END { exit !found }
    ' "${file}"; then
      return 0
    fi
  done
  return 1
}

wait_map() {
  local i
  for i in $(seq 1 90); do
    if map_is_up; then
      return 0
    fi
    if ! kill -0 "${SRCDS_PID}" 2>/dev/null; then
      echo "srcds exited before map ${MAP} loaded" >&2
      tail -n 80 "${SRCDS_OUT}" >&2 || true
      return 1
    fi
    sleep 1
  done
  echo "timeout waiting for map ${MAP}" >&2
  tail -n 80 "${SRCDS_OUT}" >&2 || true
  tail -n 40 "${CONSOLE_LOG}" >&2 || true
  return 1
}

apply_cvars() {
  local cmd reply
  for cmd in \
    "sv_cheats 1" \
    "bot_quota ${BOT_QUOTA}" \
    "bot_quota_mode normal" \
    "bot_join_after_player 0" \
    "mp_autoteambalance 0" \
    "mp_limitteams 0" \
    "mp_timelimit 0" \
    "mp_maxrounds 0" \
    "mp_roundtime 9" \
    "mp_freezetime 0"
  do
    reply="$(rcon_try "${cmd}" || true)"
    printf '>>> %s\n%s\n' "${cmd}" "${reply}" >>"${OUT_DIR}/cvars.txt"
    if grep -q 'Unknown command' <<<"${reply}"; then
      echo "cvar missing: ${cmd}" | tee -a "${OUT_DIR}/notes.txt" >&2
    fi
  done
  reply="$(rcon_try "bot_dont_shoot 1" || true)"
  printf '>>> bot_dont_shoot 1\n%s\n' "${reply}" >>"${OUT_DIR}/cvars.txt"
  if grep -q 'Unknown command' <<<"${reply}"; then
    echo "bot_dont_shoot is not a cvar on this server; skipped" | tee -a "${OUT_DIR}/notes.txt"
  fi
}

player_count() {
  local status="$1" n
  # "players : 20 (32 max)". A leading space is not printed before userid 10,
  # so counting "# 2" lines under-counts the table.
  n="$(sed -n 's/.*players[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"${status}" | head -n1)"
  if [[ -n "${n}" ]]; then
    echo "${n}"
    return 0
  fi
  grep -Ec '^#[[:space:]]*[0-9]+' <<<"${status}" || true
}

wait_bots() {
  local status count i
  echo "Waiting 30s for bots"
  sleep 30
  status="$(rcon_try "status" || true)"
  printf '%s\n' "${status}" >"${OUT_DIR}/status-bots.txt"
  count="$(player_count "${status}")"
  if [[ "${count}" -ge 2 ]]; then
    echo "Players in status: ${count}"
    return 0
  fi
  echo "Only ${count} players after 30s; waiting up to 90s more"
  for i in $(seq 1 18); do
    sleep 5
    status="$(rcon_try "status" || true)"
    printf '%s\n' "${status}" >"${OUT_DIR}/status-bots.txt"
    count="$(player_count "${status}")"
    if [[ "${count}" -ge 2 ]]; then
      echo "Players in status: ${count}"
      return 0
    fi
  done
  echo "FAIL: fewer than 2 players after waiting. status:" >&2
  printf '%s\n' "${status}" >&2
  return 1
}

ensure_nav() {
  local nav="${SERVER_DIR}/cstrike/maps/${MAP}.nav"
  if [[ -s "${nav}" ]]; then
    return 0
  fi
  echo "No nav mesh for ${MAP}; running nav_generate"
  rcon_try "sv_cheats 1" >/dev/null || true
  rcon_try "nav_generate" 10 || true
  local i size
  for i in $(seq 1 240); do
    if [[ -s "${nav}" ]]; then
      size="$(stat -c%s "${nav}")"
      sleep 3
      if [[ "$(stat -c%s "${nav}")" == "${size}" && "${size}" -gt 100 ]]; then
        echo "nav_generate wrote ${nav} (${size} bytes)"
        NAV_GENERATED=1
        echo "Restarting ${MAP} after nav_generate"
        snapshot_marks
        rcon_try "changelevel ${MAP}" 10 || true
        sleep 2
        wait_map
        return 0
      fi
    fi
    if ! kill -0 "${SRCDS_PID}" 2>/dev/null; then
      echo "srcds exited during nav_generate" >&2
      return 1
    fi
    sleep 5
  done
  echo "FAIL: nav_generate did not produce ${nav}" >&2
  tail -n 60 "${CONSOLE_LOG}" >&2 || true
  return 1
}

capture_versions() {
  {
    echo "===== version ====="
    rcon_try "version" || true
    echo "===== sm version ====="
    rcon_try "sm version" || true
    echo "===== meta list ====="
    rcon_try "meta list" || true
    echo "===== sm plugins list ====="
    rcon_try "sm plugins list" || true
    echo "===== sm exts list ====="
    rcon_try "sm exts list" || true
  } >"${OUT_DIR}/versions.txt"
  cat "${OUT_DIR}/versions.txt"
}

plugins_loaded() {
  local list="${OUT_DIR}/versions.txt"
  local missing=0
  local name
  for name in "SMAC: Core" "SMAC: Anti-Wallhack" "SMAC occluder dataset"; do
    if ! grep -F -q "${name}" "${list}"; then
      echo "FAIL: plugin not listed: ${name}" >&2
      missing=1
    fi
  done
  if grep -E -q '<FAILED>' "${list}"; then
    grep -E '<FAILED>' "${list}" | tee -a "${OUT_DIR}/notes.txt" >&2
  fi
  if ! grep -F -q "SDK Tools" "${list}"; then
    echo "FAIL: SDK Tools extension is not loaded" >&2
    missing=1
  fi
  return "${missing}"
}

save_logs() {
  mkdir -p "${OUT_DIR}/logs"
  [[ -f "${CONSOLE_LOG}" ]] && cp -f "${CONSOLE_LOG}" "${OUT_DIR}/logs/console.log" || true
  [[ -f "${SRCDS_OUT}" ]] && cp -f "${SRCDS_OUT}" "${OUT_DIR}/logs/srcds.out" || true
  local sm_logs="${SERVER_DIR}/cstrike/addons/sourcemod/logs"
  if compgen -G "${sm_logs}/L*.log" >/dev/null; then
    cp -f "${sm_logs}"/L*.log "${OUT_DIR}/logs/" || true
  fi
  if compgen -G "${sm_logs}/errors_"*.log >/dev/null; then
    cp -f "${sm_logs}"/errors_*.log "${OUT_DIR}/logs/" || true
  fi
  : >"${OUT_DIR}/occluders.txt"
  : >"${OUT_DIR}/proven.txt"
  : >"${OUT_DIR}/log-lines.txt"
  local files=()
  shopt -s nullglob
  files=("${OUT_DIR}/logs"/L*.log "${OUT_DIR}/logs"/errors_*.log)
  shopt -u nullglob
  if [[ "${#files[@]}" -eq 0 && -f "${OUT_DIR}/logs/console.log" ]]; then
    files=("${OUT_DIR}/logs/console.log")
  fi
  if [[ "${#files[@]}" -gt 0 ]]; then
    # Status text always contains "PROVEN BUT ENGINE SEES N". The log line that
    # means a real disagreement is "PROVEN BUT ENGINE SEES on <map>:".
    grep -h -E 'Occluders for |No occluders for |PROVEN BUT ENGINE SEES on ' "${files[@]}" \
      | awk '!seen[$0]++' >"${OUT_DIR}/log-lines.txt" || true
    grep -h -E 'Occluders for |No occluders for ' "${files[@]}" \
      | awk '!seen[$0]++' >"${OUT_DIR}/occluders.txt" || true
    grep -h -F 'PROVEN BUT ENGINE SEES on ' "${files[@]}" \
      | awk '!seen[$0]++' >"${OUT_DIR}/proven.txt" || true
  fi
}

kill_server() {
  if [[ -n "${SRCDS_PID:-}" ]] && kill -0 "${SRCDS_PID}" 2>/dev/null; then
    kill "${SRCDS_PID}" 2>/dev/null || true
    sleep 2
    kill -9 "${SRCDS_PID}" 2>/dev/null || true
    wait "${SRCDS_PID}" 2>/dev/null || true
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT
  save_logs || true
  kill_server || true
  exit "${rc}"
}

write_summary() {
  python3 - "${OUT_DIR}" "${MAP}" "${MIN_RECORDS}" <<'PY'
import os, re, sys
out, map_name, min_records = sys.argv[1], sys.argv[2], sys.argv[3]
check_path = os.path.join(out, "check.txt")
text = open(check_path, encoding="utf-8", errors="replace").read() if os.path.isfile(check_path) else ""
records = ""
m = re.search(r": (\d+) records", text)
if m:
    records = m.group(1)
proven = ""
m = re.search(r"engine-hidden pairs proven by one brush: ([0-9.]+%)", text)
if m:
    proven = m.group(1)
trace = occ = ""
m = re.search(r"engine traces ([0-9.]+) us .*occluder search \+ proofs ([0-9.]+) us", text)
if m:
    trace, occ = m.group(1), m.group(2)
result = "PROBLEMS" if "RESULT: PROBLEMS" in text else ("OK" if "RESULT: OK" in text else "MISSING")
occ_line = ""
occ_file = os.path.join(out, "occluders.txt")
if os.path.isfile(occ_file):
    lines = [ln.strip() for ln in open(occ_file, encoding="utf-8", errors="replace") if ln.strip()]
    if lines:
        occ_line = lines[-1]
proven_n = 0
proven_file = os.path.join(out, "proven.txt")
if os.path.isfile(proven_file):
    proven_n = sum(1 for ln in open(proven_file, encoding="utf-8", errors="replace") if ln.strip())
notes = ""
notes_file = os.path.join(out, "notes.txt")
if os.path.isfile(notes_file):
    notes = " ".join(ln.strip() for ln in open(notes_file, encoding="utf-8", errors="replace") if ln.strip())
fields = {
    "map": map_name,
    "result": result,
    "records": records,
    "proven_pct": proven,
    "trace_us": trace,
    "occ_us": occ,
    "proven_but_engine_sees": str(proven_n),
    "occluder": occ_line.replace("\n", " "),
    "notes": notes.replace("\n", " "),
    "min_records": min_records,
}
with open(os.path.join(out, "summary.txt"), "w", encoding="utf-8") as handle:
    for key, value in fields.items():
        handle.write("%s=%s\n" % (key, value))
print("summary map=%s result=%s records=%s proven=%s" % (map_name, result, records or "?", proven or "?"))
PY
}

run_map() {
  MAP="$1"
  valid_map "${MAP}" || { echo "FAIL: bad map name '${MAP}'" >&2; exit 1; }
  if [[ -z "${RCON_PASSWORD}" ]]; then
    RCON_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(8))')"
  fi
  OUT_DIR="${OUT_DIR:-${SERVER_DIR}/occ-out/${MAP}}"
  mkdir -p "${OUT_DIR}" "${SERVER_DIR}/cstrike/maps"
  : >"${OUT_DIR}/notes.txt"
  CUSTOM_MAP=0
  NAV_GENERATED=0
  if [[ ! -s "${SERVER_DIR}/cstrike/maps/${MAP}.bsp" ]]; then
    download_extra_map "${MAP}" || {
      echo "FAIL: ${MAP}.bsp is not in the smoke-test server tree and EXTRA_MAP_URLS has no ${MAP}=url" >&2
      exit 1
    }
  fi
  CONSOLE_LOG="${SERVER_DIR}/cstrike/console.log"
  SRCDS_OUT="${OUT_DIR}/srcds.out"
  rm -f "${CONSOLE_LOG}" "${SRCDS_OUT}"
  rm -f "${SERVER_DIR}/cstrike/addons/sourcemod/logs/"L*.log \
        "${SERVER_DIR}/cstrike/addons/sourcemod/logs/"errors_*.log || true
  case "${MODE}" in
    live) START_ARG=""; CSV_PREFIX="occ_dataset" ;;
    synth) START_ARG="synth"; CSV_PREFIX="occ_synth" ;;
    *) echo "FAIL: MODE must be live or synth, got '${MODE}'" >&2; exit 1 ;;
  esac
  rm -f "${SERVER_DIR}/cstrike/addons/sourcemod/data/${CSV_PREFIX}_${MAP}.csv" || true

  write_server_cfg
  local binary="./srcds_i686"
  if [[ ! -x "${SERVER_DIR}/srcds_i686" ]]; then
    if [[ -x "${SERVER_DIR}/srcds_i486" ]]; then
      binary="./srcds_i486"
    else
      echo "FAIL: no srcds_i686/srcds_i486 in ${SERVER_DIR}" >&2
      exit 1
    fi
  fi
  chmod +x "${SERVER_DIR}/srcds_i686" "${SERVER_DIR}/srcds_i486" 2>/dev/null || true

  # Same engine arguments as testing/scripts/console-probe.exp, plus enough
  # slots for bot_quota (the smoke probe uses +maxplayers 10).
  echo "Starting ${binary} on ${MAP} (127.0.0.1:${PORT}, maxplayers ${MAXPLAYERS})"
  (
    cd "${SERVER_DIR}"
    export LD_LIBRARY_PATH=".:bin:${LD_LIBRARY_PATH:-}"
    exec "${binary}" -game cstrike -console -condebug -nohltv \
      -nomaster -localcser -insecure -tickrate 66 \
      -ip 127.0.0.1 -port "${PORT}" +ip 127.0.0.1 +sv_lan 1 \
      +maxplayers "${MAXPLAYERS}" +map "${MAP}" \
      +rcon_password "${RCON_PASSWORD}" +sv_password "${RCON_PASSWORD}" \
      +log on +sv_logfile 1
  ) >"${SRCDS_OUT}" 2>&1 &
  SRCDS_PID=$!
  trap on_exit EXIT

  wait_map
  wait_rcon
  apply_cvars
  if [[ "${MODE}" == "live" ]]; then
    ensure_nav
    # Map restart after nav_generate needs the cvars again.
    if [[ "${NAV_GENERATED}" == "1" ]]; then
      wait_rcon
      apply_cvars
    fi
  fi
  capture_versions
  plugins_loaded
  if [[ "${MODE}" == "live" ]]; then
    wait_bots
  fi

  if [[ -s "${OUT_DIR}/occluders.txt" ]]; then
    :
  fi
  # Occluder line is written at map start, before sampling.
  save_logs
  echo "----- occluders -----"
  cat "${OUT_DIR}/occluders.txt" || true

  local start_reply
  start_reply="$(rcon_try "smac_occ_dataset_start ${START_ARG}" || true)"
  printf '%s\n' "${start_reply}" | tee "${OUT_DIR}/start.txt"
  if ! grep -E -q 'Writing |Already running' <<<"${start_reply}"; then
    echo "FAIL: smac_occ_dataset_start did not start the dataset" >&2
    echo "${start_reply}" >&2
    exit 1
  fi

  local total now next deadline
  total="$(python3 -c "print(int(float('${MINUTES}') * 60))")"
  if [[ "${total}" -lt 1 ]]; then
    echo "FAIL: MINUTES must be > 0" >&2
    exit 1
  fi
  now="$(date +%s)"
  deadline="$((now + total))"
  next="$((now + STATUS_EVERY))"
  : >"${OUT_DIR}/status.txt"
  echo "Sampling for ${total}s"
  while [[ "$(date +%s)" -lt "${deadline}" ]]; do
    now="$(date +%s)"
    if [[ "${now}" -ge "${next}" && "${now}" -lt "${deadline}" ]]; then
      echo "===== status $(date -u +%H:%M:%S) =====" | tee -a "${OUT_DIR}/status.txt"
      rcon_try "smac_occ_dataset_status" | tee -a "${OUT_DIR}/status.txt" || true
      next="$((next + STATUS_EVERY))"
    fi
    sleep 5
  done
  echo "===== status final =====" | tee -a "${OUT_DIR}/status.txt"
  rcon_try "smac_occ_dataset_status" | tee -a "${OUT_DIR}/status.txt" || true
  rcon_try "smac_occ_dataset_stop" | tee "${OUT_DIR}/stop.txt" || true

  local csv="${SERVER_DIR}/cstrike/addons/sourcemod/data/${CSV_PREFIX}_${MAP}.csv"
  if [[ ! -s "${csv}" ]]; then
    echo "FAIL: dataset file missing: ${csv}" >&2
    exit 1
  fi
  gzip -c "${csv}" >"${OUT_DIR}/${CSV_PREFIX}_${MAP}.csv.gz"
  local records
  records="$(($(wc -l <"${csv}") - 1))"
  echo "Records: ${records}"

  set +e
  python3 "${SMAC_DIR}/tools/occtest/check_dataset.py" \
    "${SERVER_DIR}/cstrike/maps/${MAP}.bsp" "${csv}" \
    >"${OUT_DIR}/check.txt" 2>&1
  local check_rc=$?
  set -e
  cat "${OUT_DIR}/check.txt"
  save_logs
  if [[ "${CUSTOM_MAP}" == "1" || "${NAV_GENERATED}" == "1" ]]; then
    mkdir -p "${OUT_DIR}/mapfiles"
    cp -f "${SERVER_DIR}/cstrike/maps/${MAP}.bsp" "${OUT_DIR}/mapfiles/" || true
    [[ -f "${SERVER_DIR}/cstrike/maps/${MAP}.nav" ]] && cp -f "${SERVER_DIR}/cstrike/maps/${MAP}.nav" "${OUT_DIR}/mapfiles/" || true
  fi
  write_summary

  local rc=0
  if [[ "${records}" -lt "${MIN_RECORDS}" ]]; then
    echo "FAIL: ${records} records, need at least ${MIN_RECORDS}" >&2
    rc=1
  fi
  if [[ "${check_rc}" -ne 0 ]]; then
    echo "check_dataset.py exit ${check_rc}" >&2
    rc=1
  fi
  exit "${rc}"
}

cmd="${1:-}"
case "${cmd}" in
  prepare) prepare_server ;;
  install) install_addons ;;
  run)
    shift
    [[ $# -ge 1 ]] || usage
    run_map "$1"
    ;;
  *) usage ;;
esac
