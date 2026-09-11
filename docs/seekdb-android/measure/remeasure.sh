#!/usr/bin/env bash
# Remeasure todo-app startup with a pinned libseekdb engine commit.
#
# Usage:
#   ./remeasure.sh <engine_full_sha> [fresh|keep] [local_zip]
#
#   engine_full_sha  full 40-hex commit in oceanbase/seekdb whose
#                    all_commits/<sha>/libseekdb-android-arm64-v8a.zip
#                    exists on S3 (Build libseekdb CI artifact).
#   fresh|keep       (default fresh) whether the first launch should run on a
#                    brand-new store (bootstrap, like the 3ebbab1f baseline) or
#                    keep the currently installed app data.
#   local_zip        optional path to a local libseekdb-android-arm64-v8a.zip
#                    (e.g. downloaded from a GitHub Actions run with
#                    `gh run download <run> -n libseekdb-android-arm64-v8a`)
#                    to measure before the CI artifact reaches S3. The .so is
#                    staged into build/generated/libseekdb/jniLibs/arm64-v8a/
#                    and the build runs with -PLIBSEEKDB_URL_PREFIX= (download
#                    disabled); a pre-existing manual .so under
#                    seekdb-android/src/main/jniLibs/arm64-v8a/ is restored on
#                    exit.
#
# The engine prefix is always passed as the Gradle property
# -PLIBSEEKDB_URL_PREFIX=<prefix>, never by editing the tracked
# gradle.properties: an aborted run would otherwise leave the repo file empty
# (this happened with MIUI rejecting the APK install).
#
# Workflow: download zip -> rebuild examples/todo-app debug APK with the engine
# prefix as a Gradle property -> verify the .so
# inside the APK matches the zip -> install -> capture launch #1 (fresh store)
# + launch #2/#3 (warm) -> pull on-device seekdb.log each time.
#
# Artifacts (per launch): /tmp/seekdb_<shortsha>_launch{1,2,3}_logcat.txt and
# the matching _engine.log (device seekdb.log). Then run parse_startup.py.
set -euo pipefail

SHA="${1:?usage: remeasure.sh <engine_full_sha> [fresh|keep] [local_zip]}"
MODE="fresh"
LOCAL_ZIP=""
if [ "${2:-}" = "fresh" ] || [ "${2:-}" = "keep" ]; then
  MODE="${2}"
  LOCAL_ZIP="${3:-}"
elif [ -n "${2:-}" ]; then
  if [ -f "${2}" ]; then
    LOCAL_ZIP="${2}"
  else
    echo "unknown arg2 (expected fresh|keep or path to zip): ${2}"; exit 1
  fi
fi
SHORT="${SHA:0:7}"
FLAVOR="${FLAVOR:-optimized}"
FLAVOR_CAP="$(echo "${FLAVOR}" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
PKG="com.example.seekdb_todo_app.${FLAVOR}"
ACTIVITY="${PKG}/com.example.seekdb_todo_app.MainActivity"
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"   # seekdb-android repo root
URL_BASE="https://oceanbase-seekdb-builds.s3.ap-southeast-1.amazonaws.com/libseekdb/all_commits"
ZIP="/tmp/${SHORT}-libseekdb.zip"
APK="${REPO_ROOT}/examples/todo-app/app/build/outputs/apk/${FLAVOR}/debug/app-${FLAVOR}-debug.apk"
PREFIX_PROP="-PLIBSEEKDB_URL_PREFIX="
JNI_DIR="${REPO_ROOT}/seekdb-android/src/main/jniLibs/arm64-v8a"
JNI_SO="${JNI_DIR}/libseekdb.so"
GEN_JNI_DIR="${REPO_ROOT}/seekdb-android/build/generated/libseekdb/jniLibs/arm64-v8a"
JNI_BACKUP=""

# Everything extracted from the engine zip (two ~148 MB copies of libseekdb.so
# per run) lives under WORK_TMP and is removed on exit. The old per-call
# `mktemp -d` never cleaned up, so a 6-round batch leaked ~1.8 GB and filled the
# disk mid-batch (`unzip: write error (disk full?)`, see ab19-ab22 / ab28).
# The manual-.so backup below is kept inside WORK_TMP for the same reason: a
# standalone `mktemp` file is a 148 MB leak whenever the trap does not run.
WORK_TMP="$(mktemp -d)"

# Only a manual .so overridden for a local-zip build is restored on exit;
# gradle.properties is never mutated, so there is nothing to put back there.
restore_manual_so() {
  if [ -n "${JNI_BACKUP}" ]; then
    if [ -f "${JNI_BACKUP}" ]; then
      mkdir -p "${JNI_DIR}"
      mv -f "${JNI_BACKUP}" "${JNI_SO}"
    elif [ -f "${JNI_SO}" ]; then
      rm -f "${JNI_SO}"
    fi
  fi
}

cleanup() {
  restore_manual_so
  if [ -n "${WORK_TMP}" ]; then
    rm -rf "${WORK_TMP}"
  fi
}
trap cleanup EXIT

# A run rebuilds the APK (~1.2 GB of Gradle output) on top of the staged engine;
# when the volume fills up mid-batch the failing runs are only noticed afterwards
# as truncated launches, so refuse to start without headroom.
require_free_space() {
  local need_mb="${1:-5120}" avail_mb volume
  volume="$(df -h "${REPO_ROOT}" | awk 'NR==2 {print $1}')"
  avail_mb="$(df -m "${REPO_ROOT}" | awk 'NR==2 {print $4}')"
  if [ "${avail_mb}" -lt "${need_mb}" ]; then
    echo "ERROR: only ${avail_mb} MB free on ${volume}; need >= ${need_mb} MB."
    echo "       Reclaim first, e.g.: rm -rf \${TMPDIR}/tmp.*"
    echo "                            rm -rf ${REPO_ROOT}/examples/todo-app/app/build ${REPO_ROOT}/seekdb-android/build"
    exit 1
  fi
  echo "  free on ${volume}: ${avail_mb} MB"
}
require_free_space 5120

extract_so_from_zip() {
  local zip_path="$1"
  unzip -oq "${zip_path}" -d "${WORK_TMP}/zip" "lib/*/libseekdb.so" 2>/dev/null \
    || unzip -oq "${zip_path}" -d "${WORK_TMP}/zip" "*libseekdb.so"
  find "${WORK_TMP}/zip" -name libseekdb.so | head -1
}

echo "== [1/7] fetch engine zip for ${SHA} =="
if [ -n "${LOCAL_ZIP}" ]; then
  if [ ! -f "${LOCAL_ZIP}" ]; then
    echo "local zip not found: ${LOCAL_ZIP}"; exit 1
  fi
  if [ "$(cd "$(dirname "${LOCAL_ZIP}")" && pwd)/$(basename "${LOCAL_ZIP}")" != "$(cd "$(dirname "${ZIP}")" && pwd)/$(basename "${ZIP}")" ]; then
    cp -f "${LOCAL_ZIP}" "${ZIP}"
  fi
  echo "  using local zip: ${LOCAL_ZIP}"
else
  ZIP_URL="${URL_BASE}/${SHA}/libseekdb-android-arm64-v8a.zip"
  for i in $(seq 1 60); do
    if curl -fsSL -o "${ZIP}" "${ZIP_URL}"; then break; fi
    if [ "${i}" -eq 60 ]; then echo "zip not on S3 after 10min: ${ZIP_URL}"; exit 1; fi
    echo "  not ready yet ($i), retry in 10s..."; sleep 10
  done
fi
echo "  zip: $(shasum -a 256 "${ZIP}" | cut -c1-16)…  $(du -h "${ZIP}" | cut -f1)"
SO_IN_ZIP="$(extract_so_from_zip "${ZIP}")"
echo "  .so in zip: $(shasum -a 256 "${SO_IN_ZIP}" | cut -c1-16)…"

echo "== [2/7] stage engine (engine prefix passed as a Gradle property) =="
if [ -n "${LOCAL_ZIP}" ]; then
  if [ -f "${JNI_SO}" ]; then
    JNI_BACKUP="${WORK_TMP}/libseekdb.so.orig"
    cp -f "${JNI_SO}" "${JNI_BACKUP}"
    rm -f "${JNI_SO}"
  else
    JNI_BACKUP="__none__"
  fi
  PREFIX_PROP="-PLIBSEEKDB_URL_PREFIX="
  echo "  local zip mode: will stage .so after clean (no S3 download)"
else
  PREFIX_PROP="-PLIBSEEKDB_URL_PREFIX=${URL_BASE}/${SHA}/"
  echo "  S3 mode: engine will be downloaded from ${URL_BASE}/${SHA}/"
fi

echo "== [3/7] rebuild todo-app debug APK =="
pushd "${REPO_ROOT}/examples/todo-app" >/dev/null
if [ -n "${LOCAL_ZIP}" ]; then
  ./gradlew :seekdb-android:seekdb-android:clean --console=plain
  mkdir -p "${GEN_JNI_DIR}"
  cp -f "${SO_IN_ZIP}" "${GEN_JNI_DIR}/libseekdb.so"
  ./gradlew ":app:assemble${FLAVOR_CAP}Debug" "${PREFIX_PROP}" --console=plain
else
  ./gradlew ":app:assemble${FLAVOR_CAP}Debug" "${PREFIX_PROP}" -PLIBSEEKDB_FORCE_DOWNLOAD=true --console=plain
fi
popd >/dev/null
SO_IN_APK="${WORK_TMP}/apk"
if unzip -oq "${APK}" "lib/arm64-v8a/libseekdb.so" -d "${SO_IN_APK}" 2>/dev/null; then
  SO_IN_APK="$(find "${SO_IN_APK}" -name libseekdb.so | head -1)"
else
  SO_IN_APK="${GEN_JNI_DIR}/libseekdb.so"
  if [ ! -f "${SO_IN_APK}" ]; then
    SO_IN_APK="$(find "${REPO_ROOT}/seekdb-android/build" -path '*/jniLibs/arm64-v8a/libseekdb.so' | head -1)"
  fi
fi
echo "  .so in APK: $(shasum -a 256 "${SO_IN_APK}" | cut -c1-16)…"
if [ "$(shasum -a 256 "${SO_IN_APK}" | cut -d' ' -f1)" != "$(shasum -a 256 "${SO_IN_ZIP}" | cut -d' ' -f1)" ]; then
  echo "ERROR: .so inside APK != zip (stale engine packaged)"; exit 1
fi

echo "== [4/7] reset app data + install =="
if [ "${MODE}" = "fresh" ]; then
  adb uninstall "${PKG}" >/dev/null 2>&1 || true
fi
# MIUI rejects streamed installs while the screen is locked
# (INSTALL_FAILED_USER_RESTRICTED: Install canceled by user), so a bare
# `adb install` can abort the run before a single launch is captured.
install_apk_with_retry() {
  local out=""
  local i=""
  for i in $(seq 1 20); do
    out="$(adb install -r "${APK}" 2>&1)" || true
    if echo "${out}" | grep -q "Success"; then
      echo "  install ok (attempt ${i})"
      return 0
    fi
    if echo "${out}" | grep -q "INSTALL_FAILED_USER_RESTRICTED"; then
      echo "  install attempt ${i}: unlock the phone and tap 允许安装"
    fi
    sleep 5
  done
  echo "ERROR: install failed after 20 attempts: ${out}"
  return 1
}
install_apk_with_retry
adb logcat -G 16M >/dev/null 2>&1 || true

capture_launch() {  # $1=launch index  $2=sleep seconds
  local idx="$1" wait_s="$2"
  local lc="/tmp/seekdb_${SHORT}_launch${idx}_logcat.txt"
  local el="/tmp/seekdb_${SHORT}_launch${idx}_engine.log"
  adb shell am force-stop "${PKG}" >/dev/null
  adb logcat -c
  adb shell am start -W -n "${ACTIVITY}" 2>&1 | tee "/tmp/seekdb_${SHORT}_launch${idx}_am.txt"
  sleep "${wait_s}"
  adb shell am force-stop "${PKG}" >/dev/null
  adb logcat -d -v threadtime > "${lc}"
  adb shell "run-as ${PKG} cat databases/log/seekdb.log" > "${el}" 2>/dev/null || true
  echo "  ${lc} ($(wc -l < "${lc}") lines), ${el}"
}

echo "== [5/7] launch #1 (fresh store bootstrap, wait 18s) =="
capture_launch 1 18
echo "== [6/7] launch #2 (warm, wait 30s) =="
# Warm start after a fresh-store bootstrap intermittently stalls in
# wait_metadata_ready (documented in android-startup-timeline-measurement-*.md:
# 16.65 s when it recovers, worse when it does not). With the old 12 s window
# those runs were silently dropped as missing samples and biased the batch; 30 s
# keeps a recovering stall in the data as an outlier.
capture_launch 2 30
echo "== [7/7] launch #3 (warm, wait 12s) =="
capture_launch 3 12

echo
echo "Done. Parse with:"
echo "  python3 ${REPO_ROOT}/docs/seekdb-android/measure/parse_startup.py /tmp/seekdb_${SHORT}_launch{1,2,3}_logcat.txt"
