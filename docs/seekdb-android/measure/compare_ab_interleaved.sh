#!/usr/bin/env bash
# Interleaved A/B of two pinned libseekdb engine commits on one device.
#
# Usage:
#   ./compare_ab_interleaved.sh <sha_a> <sha_b> [rounds] [start_index]
#
#   sha_a, sha_b  full 40-hex engine commits in oceanbase/seekdb (Build libseekdb
#                 artifacts). Each round runs sha_a then sha_b, alternating so the
#                 device's drift (thermal, background load) is spread over both arms.
#   rounds        number of rounds; default 5 -> n=10 warm samples per arm.
#   start_index   first run number; default 1 -> run tags ab01, ab02, ...  Pass the
#                 next free index to append a batch without clobbering earlier /tmp
#                 artifacts (e.g. `... 5 5` for ab05..ab14).
#
# Why this exists next to compare_ab_emulator.sh: that script installs both flavors
# side by side and measures them on one boot; this one rebuilds and reinstalls a
# single flavor per run and wipes the app store before every run, so both arms start
# from an identical fresh-bootstrap state. Use it when the question is "did commit B
# regress commit A on warm start", not "what do baseline and optimized look like".
#
# Artifacts per run (in /tmp):
#   abNN_<short>_run.txt            full remeasure.sh output (== [N/7] markers)
#   abNN_<short>_launch{1,2,3}_logcat.txt
#   abNN_<short>_launch{1,2,3}_engine.log   device seekdb.log (DBA 14-step anchors)
# Log file: /tmp/ab_cross_<sha_a_short>_vs_<sha_b_short>.log
#
# Then parse with:
#   python3 docs/seekdb-android/measure/parse_startup.py /tmp/abNN_<short>_launch{2,3}_logcat.txt
#
# Notes:
#   - The engine zip is fetched from S3 once per arm and reused, so the measurement
#     does not depend on a later S3 refresh.
#   - MIUI rejects APK installs until the user taps "allow"; a rejected run is
#     reported as FAILED and the batch continues.
set -uo pipefail

SHA_A="${1:?usage: compare_ab_interleaved.sh <sha_a> <sha_b> [rounds] [start_index]}"
SHA_B="${2:?usage: compare_ab_interleaved.sh <sha_a> <sha_b> [rounds] [start_index]}"
ROUNDS="${3:-5}"
START="${4:-1}"

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MEASURE_DIR="${REPO_ROOT}/docs/seekdb-android/measure"
URL_BASE="https://oceanbase-seekdb-builds.s3.ap-southeast-1.amazonaws.com/libseekdb/all_commits"
PKG="${PKG:-com.example.seekdb_todo_app.baseline}"
FLAVOR="${FLAVOR:-baseline}"

SHORT_A="${SHA_A:0:7}"
SHORT_B="${SHA_B:0:7}"
ZIP_A="/tmp/${SHORT_A}-libseekdb.zip"
ZIP_B="/tmp/${SHORT_B}-libseekdb.zip"
LOG="/tmp/ab_cross_${SHORT_A}_vs_${SHORT_B}.log"

if [ -z "${ANDROID_SERIAL:-}" ]; then
  echo "ANDROID_SERIAL is not set; export the target device serial first."; exit 1
fi
if ! adb get-state >/dev/null 2>&1; then
  echo "device ${ANDROID_SERIAL} is not connected."; exit 1
fi

# A long batch used to end in `unzip: write error (disk full?)` around the 4th
# run (ab19-ab22, ab28): every round stages a 148 MB libseekdb.so and rebuilds
# the APK (~1.2 GB), so sweeps leftovers of our own runs and refuses to start
# without headroom. Safety rules: only $TMPDIR/tmp.* dirs that still hold a
# libseekdb.so are ours, and dirs touched in the last 15 min are skipped so an
# in-flight remeasure.sh is never disturbed.
sweep_stale_temp() {
  local tmp_root="${TMPDIR:-/tmp}" dir marker sz freed=0
  marker="$(mktemp)"
  touch -t "$(date -v-15M '+%Y%m%d%H%M.%S')" "${marker}"
  for dir in "${tmp_root%/}"/tmp.*; do
    [ -d "${dir}" ] || continue
    [ "${dir}" -nt "${marker}" ] && continue
    find "${dir}" -name libseekdb.so -print -quit 2>/dev/null | grep -q . || continue
    sz="$(du -sm "${dir}" 2>/dev/null | cut -f1)"
    freed=$((freed + ${sz:-0}))
    rm -rf "${dir}"
  done
  rm -f "${marker}"
  if [ "${freed}" -gt 0 ]; then
    echo "  swept ${freed} MB of stale engine temp dirs under ${tmp_root%/}"
  fi
  return 0
}

echo "=== pre-flight ==="
sweep_stale_temp
echo "  disk: $(df -h "${REPO_ROOT}" | awk 'NR==2 {printf "%s free on %s (%s used)", $4, $1, $5}')"

fetch_zip() {
  local sha="$1" zip="$2" url
  if [ -f "${zip}" ]; then
    echo "  using cached zip: ${zip}"
    return 0
  fi
  url="${URL_BASE}/${sha}/libseekdb-android-arm64-v8a.zip"
  echo "  downloading ${url}"
  curl -fsSL -o "${zip}" "${url}"
}

echo "=== interleaved A/B: ${SHORT_A} (a) vs ${SHORT_B} (b), ${ROUNDS} rounds, tags from ab$(printf '%02d' "${START}") ==="
echo "device: ${ANDROID_SERIAL}  flavor: ${FLAVOR}  pkg: ${PKG}"
echo "=== [0/2] fetch engine zips ==="
fetch_zip "${SHA_A}" "${ZIP_A}" || { echo "cannot fetch zip for ${SHA_A}"; exit 1; }
fetch_zip "${SHA_B}" "${ZIP_B}" || { echo "cannot fetch zip for ${SHA_B}"; exit 1; }

wipe_store() {
  for d in databases files shared_prefs; do
    adb shell run-as "${PKG}" rm -rf "${d}" >/dev/null 2>&1 || true
  done
}

run_idx=$((START - 1))
: > "${LOG}"
for round in $(seq 1 "${ROUNDS}"); do
  for arm in a b; do
    if [ "${arm}" = "a" ]; then sha="${SHA_A}"; zip="${ZIP_A}"; else sha="${SHA_B}"; zip="${ZIP_B}"; fi
    short="${sha:0:7}"
    run_idx=$((run_idx + 1))
    tag="$(printf 'ab%02d' "${run_idx}")"
    {
      echo "########## ${tag} round=${round} arm=${arm} sha=${short} ##########"
    } | tee -a "${LOG}"

    wipe_store
    cd "${REPO_ROOT}" || exit 1
    if FLAVOR="${FLAVOR}" bash "${MEASURE_DIR}/remeasure.sh" "${sha}" keep "${zip}" \
        > "/tmp/${tag}_${short}_run.txt" 2>&1; then
      echo "${tag}: remeasure OK" | tee -a "${LOG}"
    else
      echo "${tag}: remeasure FAILED (see /tmp/${tag}_${short}_run.txt)" | tee -a "${LOG}"
      continue
    fi

    # remeasure.sh overwrites these on every invocation, so copy each run's before
    # the next one starts (the engine log carries the DBA 14-step anchors).
    for i in 1 2 3; do
      src="/tmp/seekdb_${short}_launch${i}_logcat.txt"
      [ -f "${src}" ] && cp -f "${src}" "/tmp/${tag}_${short}_launch${i}_logcat.txt"
      src="/tmp/seekdb_${short}_launch${i}_engine.log"
      [ -f "${src}" ] && cp -f "${src}" "/tmp/${tag}_${short}_launch${i}_engine.log"
    done

    grep -E "^== \[5/7\]|^== \[6/7\]|^== \[7/7\]|TotalTime:|\.so in APK" \
      "/tmp/${tag}_${short}_run.txt" | tail -8 | tee -a "${LOG}"
  done
done

echo "AB_DONE runs=${run_idx} log=${LOG}" | tee -a "${LOG}"
echo "  disk after: $(df -h "${REPO_ROOT}" | awk 'NR==2 {printf "%s free on %s (%s used)", $4, $1, $5}')" | tee -a "${LOG}"
echo
echo "Parse the warm launches, e.g.:"
echo "  python3 ${MEASURE_DIR}/parse_startup.py /tmp/ab*_${SHORT_A}_launch{2,3}_logcat.txt"
echo "  python3 ${MEASURE_DIR}/parse_startup.py /tmp/ab*_${SHORT_B}_launch{2,3}_logcat.txt"
