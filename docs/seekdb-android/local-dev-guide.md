# Local Development Guide

## Prerequisites

- JDK 17
- Android SDK and platform tools
- Use project `./gradlew` (Gradle wrapper, pinned to 9.3.1)
- Optional for full integration: `libseekdb.so` available to runtime loader (fetched automatically by the `downloadLibseekdb` Gradle task from S3; disable with `-PLIBSEEKDB_URL_PREFIX=` to use manually placed files)
- See **`docs/seekdb-android/seekdb-engine-android.md`** for how `libseekdb.so` is fetched/packaged, how to build it in the **seekdb** repo (source of the S3 artifacts), and why **`pm clear`** may be needed before instrumentation runs.

## Build

```bash
./gradlew :seekdb-android:assembleDebug
# Optional: Database Inspector placeholder AAR
./gradlew :seekdb-android-inspection:assembleDebug
```

## Unit Tests

```bash
./gradlew :seekdb-android:testDebugUnitTest
```

## Instrumentation Tests

Start an emulator or connect a device, then run:

```bash
./gradlew :seekdb-android:connectedDebugAndroidTest
```

## Notes on Native Availability

- If `libseekdb.so` is missing, native-dependent tests are skipped via assumptions.
- For meaningful Room/compat integration validation, ensure native library is available.
- After swapping `libseekdb.so` or when migration tests fail with odd version errors, clear the test app data: `adb shell pm clear com.oceanbase.seekdb.android.test`, then rerun instrumentation (see `seekdb-engine-android.md` §5).

## Recommended Iteration Loop

- Modify JNI or compat code
- Run unit tests
- Run instrumentation tests for compat + Room scenarios
- Update `implementation-status.md` with behavior changes
