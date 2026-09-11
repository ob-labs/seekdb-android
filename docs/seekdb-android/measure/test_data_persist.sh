#!/usr/bin/env bash
# Direct-insert embed data-persist probe (no UI automation).
#
# Uses two instrumentation tests in separate processes:
#   DataPersistSeedTest  — Room insert, exit without seekdb_close
#   force-stop           — simulates user killing the app
#   DataPersistVerifyTest — new process, reopen DB, assert row count
#
# Usage:
#   export ANDROID_SERIAL=98305968
#   ./test_data_persist.sh [engine_zip]
#
# engine_zip defaults to /tmp/23c10ad-artifacts/libseekdb-android-arm64-v8a.zip
# (pre-staleness-fix). Pass a 42a07+ zip to verify the fix.
set -euo pipefail

ENGINE_ZIP="${1:-/tmp/23c10ad-artifacts/libseekdb-android-arm64-v8a.zip}"
SHA="$(unzip -p "${ENGINE_ZIP}" libseekdb.so 2>/dev/null | shasum -a 256 | cut -c1-40)"
# When using local zip, caller usually knows SHA; fall back to basename hint.
if [ -f /tmp/23c10ad-artifacts/libseekdb-android-arm64-v8a.zip ] \
   && [ "${ENGINE_ZIP}" = /tmp/23c10ad-artifacts/libseekdb-android-arm64-v8a.zip ]; then
  SHA="23c10ad73f37c67f46f699ce05a0706b10b01745"
fi
if [ -f /tmp/42a07b-artifacts/libseekdb-android-arm64-v8a.zip ] \
   && [ "${ENGINE_ZIP}" = /tmp/42a07b-artifacts/libseekdb-android-arm64-v8a.zip ]; then
  SHA="42a07b59ca827bf723ff82e722c4801747ad9598"
fi

FLAVOR="${FLAVOR:-optimized}"
PKG="com.example.seekdb_todo_app.${FLAVOR}"
TEST_PKG="${PKG}.test"
RUNNER="androidx.test.runner.AndroidJUnitRunner"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP_DIR="${REPO_ROOT}/examples/todo-app"
APK="${APP_DIR}/app/build/outputs/apk/${FLAVOR}/debug/app-${FLAVOR}-debug.apk"
TEST_APK="${APP_DIR}/app/build/outputs/apk/androidTest/${FLAVOR}/debug/app-${FLAVOR}-debug-androidTest.apk"

install_apks() {
  for i in $(seq 1 20); do
    if adb install -r "${APK}" 2>&1 | tee /tmp/install_app.txt | grep -q Success \
       && adb install -r "${TEST_APK}" 2>&1 | tee /tmp/install_test.txt | grep -q Success; then
      return 0
    fi
    echo "  install attempt $i — 请在手机上点「允许安装」"
    sleep 5
  done
  echo "install failed"; exit 1
}

run_instrument() {
  local class="$1"
  adb shell am instrument -w -e class "${class}" "${TEST_PKG}/${RUNNER}" 2>&1 | tee "/tmp/instrument_${class##*.}.txt"
  grep -q "OK (1 test)" "/tmp/instrument_${class##*.}.txt"
}

echo "== [1/5] stage engine ${SHA:0:7} + build APKs =="
bash "${REPO_ROOT}/docs/seekdb-android/measure/remeasure.sh" "${SHA}" fresh "${ENGINE_ZIP}" \
  | awk '/^== \[5\/7\]/ { exit } { print }'
pushd "${APP_DIR}" >/dev/null
FLAVOR_CAP="$(echo "${FLAVOR}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
./gradlew ":app:assemble${FLAVOR_CAP}DebugAndroidTest" --console=plain -q
popd >/dev/null

echo "== [2/5] install app + androidTest =="
install_apks

echo "== [3/5] seed (direct Room insert, no seekdb_close) =="
if run_instrument "com.example.seekdb_todo_app.DataPersistSeedTest"; then
  echo "  SEED: OK"
else
  echo "  SEED: FAILED"; exit 1
fi

echo "== [4/5] force-stop (simulate kill without shutdown) =="
adb shell am force-stop "${PKG}"
adb shell am force-stop "${TEST_PKG}" >/dev/null 2>&1 || true
sleep 2

echo "== [5/5] verify in new process =="
if run_instrument "com.example.seekdb_todo_app.DataPersistVerifyTest"; then
  echo "RESULT: PASS — data persisted after relaunch"
  exit 0
else
  echo "RESULT: FAIL — data missing after relaunch"
  echo "  (expected on engines before stale-manifest fix, e.g. 23c10ad)"
  adb shell "run-as ${PKG} cat databases/log/seekdb.log" 2>/dev/null \
    | grep -iE 'warm snapshot stale|embed warm snapshot|mls_palf_warm_fast|unexpected file.*warm_manifest' \
    | tail -10 || true
  exit 1
fi
