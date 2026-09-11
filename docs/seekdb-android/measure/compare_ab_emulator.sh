#!/usr/bin/env bash
# Side-by-side baseline vs optimized todo-app on an emulator (both installed).
#
# Usage:
#   ./compare_ab_emulator.sh [baseline_sha] [optimized_sha]
#
# Defaults:
#   baseline  32ee789be667d9d7c1dfeaee5ec5c9e19eb98130  (pre warm-manifest ms_* baseline)
#   optimized 68bb2c581661d95802abdeafe9f46ef999ac20a8  (slog + stale fix, ~770ms seekdb_open)
#
# Starts Medium_Phone_API_36.1 if no device is connected, builds both flavor APKs with
# pinned engines, installs them together, captures warm launches, and runs data-persist probes.
set -euo pipefail

BASELINE_SHA="${1:-32ee789be667d9d7c1dfeaee5ec5c9e19eb98130}"
OPT_SHA="${2:-68bb2c581661d95802abdeafe9f46ef999ac20a8}"
BASE_SHORT="${BASELINE_SHA:0:7}"
OPT_SHORT="${OPT_SHA:0:7}"
AVD="${AVD:-Medium_Phone_API_36.1}"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP_DIR="${REPO_ROOT}/examples/todo-app"
GP="${REPO_ROOT}/gradle.properties"
JNI_DIR="${REPO_ROOT}/seekdb-android/src/main/jniLibs/arm64-v8a"
JNI_SO="${JNI_DIR}/libseekdb.so"
GEN_JNI_DIR="${REPO_ROOT}/seekdb-android/build/generated/libseekdb/jniLibs/arm64-v8a"
URL_BASE="https://oceanbase-seekdb-builds.s3.ap-southeast-1.amazonaws.com/libseekdb/all_commits"
OUT_DIR="/tmp/seekdb_ab_compare_${BASE_SHORT}_vs_${OPT_SHORT}"
GP_BACKUP=""
JNI_BACKUP=""

PKG_BASE="com.example.seekdb_todo_app.baseline"
PKG_OPT="com.example.seekdb_todo_app.optimized"
ACT_BASE="${PKG_BASE}/.MainActivity"
ACT_OPT="${PKG_OPT}/.MainActivity"

restore_repo_state() {
  if [ -n "${GP_BACKUP}" ] && [ -f "${GP_BACKUP}" ]; then
    mv -f "${GP_BACKUP}" "${GP}"
  fi
  if [ -n "${JNI_BACKUP}" ]; then
    if [ -f "${JNI_BACKUP}" ]; then
      mkdir -p "${JNI_DIR}"
      mv -f "${JNI_BACKUP}" "${JNI_SO}"
    elif [ -f "${JNI_SO}" ]; then
      rm -f "${JNI_SO}"
    fi
  fi
}
trap restore_repo_state EXIT

extract_so_from_zip() {
  local zip_path="$1"
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  unzip -oq "${zip_path}" -d "${tmp_dir}" "lib/*/libseekdb.so" 2>/dev/null \
    || unzip -oq "${zip_path}" -d "${tmp_dir}" "*libseekdb.so"
  find "${tmp_dir}" -name libseekdb.so | head -1
}

fetch_zip() {
  local sha="$1"
  local short="${sha:0:7}"
  local zip="/tmp/${short}-libseekdb.zip"
  if [ -f "${zip}" ]; then
    echo "  reuse ${zip}"
    return 0
  fi
  local url="${URL_BASE}/${sha}/libseekdb-android-arm64-v8a.zip"
  echo "  download ${url}"
  curl -fsSL -o "${zip}" "${url}"
}

ensure_emulator() {
  if adb devices | awk 'NR>1 && $2=="device" { found=1 } END { exit !found }'; then
    echo "== emulator: device already connected =="
    adb devices -l
    return 0
  fi
  echo "== emulator: starting ${AVD} =="
  nohup emulator -avd "${AVD}" -no-snapshot-load -gpu host >/tmp/emulator_${AVD}.log 2>&1 &
  adb wait-for-device
  for _ in $(seq 1 90); do
    if [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      break
    fi
    sleep 2
  done
  adb devices -l
}

stage_engine_zip() {
  local zip="$1"
  GP_BACKUP="$(mktemp)"
  cp -f "${GP}" "${GP_BACKUP}"
  if [ -f "${JNI_SO}" ]; then
    JNI_BACKUP="$(mktemp)"
    cp -f "${JNI_SO}" "${JNI_BACKUP}"
    rm -f "${JNI_SO}"
  else
    JNI_BACKUP="__none__"
  fi
  sed -i '' 's#^LIBSEEKDB_URL_PREFIX=.*#LIBSEEKDB_URL_PREFIX=#' "${GP}"
  local so_in_zip
  so_in_zip="$(extract_so_from_zip "${zip}")"
  pushd "${REPO_ROOT}/examples/todo-app" >/dev/null
  ./gradlew :seekdb-android:seekdb-android:clean --console=plain -q
  mkdir -p "${GEN_JNI_DIR}"
  cp -f "${so_in_zip}" "${GEN_JNI_DIR}/libseekdb.so"
  ./gradlew ":app:assemble${2}Debug" -PLIBSEEKDB_URL_PREFIX= --console=plain -q
  popd >/dev/null
}

verify_apk_so() {
  local apk="$1"
  local zip="$2"
  local tmp
  tmp="$(mktemp -d)"
  unzip -oq "${apk}" "lib/arm64-v8a/libseekdb.so" -d "${tmp}"
  local so_apk so_zip
  so_apk="$(find "${tmp}" -name libseekdb.so | head -1)"
  so_zip="$(extract_so_from_zip "${zip}")"
  if [ "$(shasum -a 256 "${so_apk}" | cut -d' ' -f1)" != "$(shasum -a 256 "${so_zip}" | cut -d' ' -f1)" ]; then
    echo "ERROR: .so mismatch in ${apk}"; exit 1
  fi
  echo "  verified .so $(shasum -a 256 "${so_apk}" | cut -c1-16)… in $(basename "${apk}")"
}

capture_launch() {
  local label="$1" pkg="$2" activity="$3" idx="$4" wait_s="$5"
  local lc="${OUT_DIR}/${label}_launch${idx}_logcat.txt"
  local el="${OUT_DIR}/${label}_launch${idx}_engine.log"
  adb shell am force-stop "${pkg}" >/dev/null
  adb logcat -c
  adb shell am start -W -n "${activity}" 2>&1 | tee "${OUT_DIR}/${label}_launch${idx}_am.txt"
  sleep "${wait_s}"
  adb shell am force-stop "${pkg}" >/dev/null
  adb logcat -d -v threadtime > "${lc}"
  adb shell "run-as ${pkg} cat databases/log/seekdb.log" > "${el}" 2>/dev/null || true
  echo "  ${label} launch #${idx}: ${lc}"
}

run_persist_probe() {
  local label="$1" pkg="$2" flavor_cap="$3"
  local test_pkg="${pkg}.test"
  local runner="androidx.test.runner.AndroidJUnitRunner"
  local app_apk="${APP_DIR}/app/build/outputs/apk/${label}/debug/app-${label}-debug.apk"
  local test_apk="${APP_DIR}/app/build/outputs/apk/androidTest/${label}/debug/app-${label}-debug-androidTest.apk"

  adb uninstall "${pkg}" >/dev/null 2>&1 || true
  adb uninstall "${test_pkg}" >/dev/null 2>&1 || true
  adb install -r "${app_apk}"
  adb install -r "${test_apk}"

  echo "== persist ${label}: seed =="
  adb shell am instrument -w -e class com.example.seekdb_todo_app.DataPersistSeedTest \
    "${test_pkg}/${runner}" 2>&1 | tee "${OUT_DIR}/${label}_persist_seed.txt"
  grep -q "OK (1 test)" "${OUT_DIR}/${label}_persist_seed.txt" || { echo "  ${label} SEED failed"; return 1; }

  adb shell am force-stop "${pkg}"
  adb shell am force-stop "${test_pkg}" >/dev/null 2>&1 || true
  sleep 2

  echo "== persist ${label}: verify =="
  adb shell am instrument -w -e class com.example.seekdb_todo_app.DataPersistVerifyTest \
    "${test_pkg}/${runner}" 2>&1 | tee "${OUT_DIR}/${label}_persist_verify.txt"
  if grep -q "OK (1 test)" "${OUT_DIR}/${label}_persist_verify.txt"; then
    echo "  ${label} persist: PASS"
    return 0
  fi
  echo "  ${label} persist: FAIL"
  return 1
}

mkdir -p "${OUT_DIR}"
echo "Artifacts -> ${OUT_DIR}"

ensure_emulator

echo "== [1/6] fetch engine zips =="
fetch_zip "${BASELINE_SHA}"
fetch_zip "${OPT_SHA}"
ZIP_BASE="/tmp/${BASE_SHORT}-libseekdb.zip"
ZIP_OPT="/tmp/${OPT_SHORT}-libseekdb.zip"

echo "== [2/6] build baseline APK (${BASE_SHORT}) =="
stage_engine_zip "${ZIP_BASE}" "Baseline"
APK_BASE="${APP_DIR}/app/build/outputs/apk/baseline/debug/app-baseline-debug.apk"
verify_apk_so "${APK_BASE}" "${ZIP_BASE}"

echo "== [3/6] build optimized APK (${OPT_SHORT}) =="
stage_engine_zip "${ZIP_OPT}" "Optimized"
APK_OPT="${APP_DIR}/app/build/outputs/apk/optimized/debug/app-optimized-debug.apk"
verify_apk_so "${APK_OPT}" "${ZIP_OPT}"

pushd "${APP_DIR}" >/dev/null
./gradlew :app:assembleBaselineDebugAndroidTest :app:assembleOptimizedDebugAndroidTest \
  -PLIBSEEKDB_URL_PREFIX= --console=plain -q
popd >/dev/null

echo "== [4/6] install both apps (side by side) =="
adb uninstall "${PKG_BASE}" >/dev/null 2>&1 || true
adb uninstall "${PKG_OPT}" >/dev/null 2>&1 || true
adb install -r "${APK_BASE}"
adb install -r "${APK_OPT}"
adb shell pm list packages | grep seekdb_todo_app

echo "== [5/6] warm launch capture (bootstrap #1, warm #2/#3) =="
adb logcat -G 16M >/dev/null 2>&1 || true
capture_launch baseline "${PKG_BASE}" "${ACT_BASE}" 1 18
capture_launch optimized "${PKG_OPT}" "${ACT_OPT}" 1 18
capture_launch baseline "${PKG_BASE}" "${ACT_BASE}" 2 12
capture_launch optimized "${PKG_OPT}" "${ACT_OPT}" 2 12
capture_launch baseline "${PKG_BASE}" "${ACT_BASE}" 3 12
capture_launch optimized "${PKG_OPT}" "${ACT_OPT}" 3 12

echo "== [6/6] data persist probes =="
PERSIST_BASE=0 PERSIST_OPT=0
run_persist_probe baseline "${PKG_BASE}" "Baseline" && PERSIST_BASE=1 || true
run_persist_probe optimized "${PKG_OPT}" "Optimized" && PERSIST_OPT=1 || true

PARSE="${REPO_ROOT}/docs/seekdb-android/measure/parse_startup.py"
echo
echo "========== seekdb_open (launch #3 warm) =========="
python3 "${PARSE}" "${OUT_DIR}/baseline_launch3_logcat.txt" 2>/dev/null | rg -i "seekdb_open|mls_palf|total" || true
python3 "${PARSE}" "${OUT_DIR}/optimized_launch3_logcat.txt" 2>/dev/null | rg -i "seekdb_open|mls_palf|total" || true
echo
echo "========== summary =========="
echo "baseline  (${BASE_SHORT}) persist: $([ "${PERSIST_BASE}" = 1 ] && echo PASS || echo FAIL)"
echo "optimized (${OPT_SHORT}) persist: $([ "${PERSIST_OPT}" = 1 ] && echo PASS || echo FAIL)"
echo "logs: ${OUT_DIR}"
echo
echo "Full parse:"
echo "  python3 ${PARSE} ${OUT_DIR}/baseline_launch{1,2,3}_logcat.txt"
echo "  python3 ${PARSE} ${OUT_DIR}/optimized_launch{1,2,3}_logcat.txt"
