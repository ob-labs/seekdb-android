# Implementation Status

## Completed

- **Room / SupportSQLite on SeekDB** (see `docs/seekdb-android/room-sqlite-compat.md`): SQL normalization, `PRAGMA`/`sqlite_master` routing, nested transaction depth, invalidation DDL rewrites, statement bind quirks.
- **Android embed + engine alignment** (see `docs/seekdb-android/seekdb-engine-android.md`):
  - **seekdb** (Android cross-build): RS tablet reporting skipped on `__ANDROID__`; DDL log text suppressed for embedded; CPU topology and signal-handler behavior safe for app processes; DML `is_ignore_` + duplicate-key handling aligned with `INSERT IGNORE`; `seekdb_stmt_execute` routes write SQL through `seekdb_execute_update`.
  - **seekdb-android**: nested `beginTransaction` compatible with Room; JNI logs `dlopen` failure; androidTest Room classpath deps (`lifecycle-livedata`, `room-paging`); `libseekdb.so` auto-downloaded from S3 by the `downloadLibseekdb` Gradle task into `build/generated/libseekdb/jniLibs/` (gitignored).
- Android library project skeleton with Gradle module and JNI CMake build.
- Native API Java wrappers:
  - `SeekdbClient`
  - `SeekdbConnection`
  - `SeekdbResultSet`
- JNI bridge with dynamic loading support for `libseekdb.so`:
  - `seekdb_open`
  - `seekdb_close`
  - `seekdb_connect`
  - `seekdb_disconnect`
  - `seekdb_query_cstr`
  - `seekdb_result_free`
  - `seekdb_begin`
  - `seekdb_commit`
  - `seekdb_rollback`
- Room integration entry skeleton:
  - `SeekdbOpenHelperFactory`
  - `SeekdbOpenHelper`
  - `SeekdbCompatDatabase`
  - `SeekdbCompatStatement`
- Compat query path skeleton now wired to native:
  - execute SQL query
  - read result column names
  - fetch all rows as typed object matrix
  - populate `MatrixCursor` with typed values
  - `SupportSQLiteQuery.bindTo()` path is now routed through statement bind and execution
  - cancellation signal pre-check added for query overload with `CancellationSignal`
- Statement write path skeleton is now wired:
  - prepare statement
  - bind null/long/double/string/blob (1-based API adapted to 0-based C ABI)
  - execute statement and free result
  - close statement handle
- Statement result helpers wired:
  - statement affected rows
  - statement insert id
  - simpleQueryForLong/simpleQueryForString over first cell
- Compat DML APIs implemented:
  - `insert`
  - `update`
  - `delete`
  - transaction begin/commit/rollback mapping
- Initial instrumentation smoke test added:
  - open helper creation
  - writable database acquisition
  - simple create-table execution path
- Additional instrumentation coverage added:
  - insert and parameterized query roundtrip
  - transaction commit/rollback behavior check
  - conflict ignore behavior check
  - tests are gated by native library availability assumption
- Room DAO integration tests scaffold added:
  - `@Entity/@Dao/@Database` test model
  - `Room.databaseBuilder(...).openHelperFactory(SeekdbCompat.factory())`
  - insert/query, commit, and rollback scenarios
- Native unavailability strategy tightened:
  - explicit `nativeIsAvailable` probe
  - fail-fast on open/connect when `libseekdb.so` is unavailable
- Structured error mapping added:
  - `SeekdbSqliteErrorMapper` converts seekdb rc to Android SQLite exceptions
  - statement prepare/bind/execute paths now use mapped exception flow
- CI scaffold added:
  - `.github/workflows/ci.yml` (same shape as sqlite-android `ci.yml`)
  - includes assemble, unit test, and instrumentation stages
  - uses GitHub Action provisioned Gradle `8.13` (wrapper files not required for initial activation)
  - uploads test reports and emulator logcat as artifacts
- Local developer runbook added:
  - `docs/seekdb-android/local-dev-guide.md`
  - covers build/unit/androidTest commands and native dependency caveats
- Unit test layer bootstrapped (`src/test`):
  - contract behavior tests (`needUpgrade`, WAL toggles)
  - error mapper tests
- Session manager baseline added:
  - `SeekdbSessionManager` in `com.oceanbase.seekdb.android.runtime` for thread-bound shared connection reuse
- Full SQLite replacement track (initial):
  - `docs/seekdb-android/abi-parity-checklist.md`, `sqlite-android-parity-matrix.md`, `engine-features-matrix.md`, `engine-milestones-jni-requirements.md`, `seekdb-android/NOTICE`
  - JNI ABI version **1** (see `SeekdbNativeBridge.nativeAbiVersion()` / `abi-parity-checklist.md`); optional `seekdb_stmt_reset` / `seekdb_stmt_clear_bindings`; `nativeResultReadNextRowTyped` for streaming rows
  - `SeekdbResultScanner`, `SeekdbConnectionPool`, `SeekdbSerializedSession`, `SeekdbRuntime` (`globalExclusiveLock`), `SeekdbCursorWindowUtil` / `fillChunk`, cursor-driver stubs (`SeekdbSQLiteCursorDriver`, `SeekdbDefaultCursorDriver`), `SeekdbFrameworkOpenHelper`, public `SeekdbSQLite` facade (`frameworkOpenHelperFactory`, `createFrameworkOpenHelper`)
  - `seekdb-android-inspection`: fork of sqlite-android-inspection (`androidx.sqlite.inspection`) wired to [SeekdbCompatDatabase](../../seekdb-android/src/main/java/com/oceanbase/seekdb/android/compat/SeekdbCompatDatabase.java); see [inspector-setup.md](inspector-setup.md)
  - Optional windowed query `Cursor`: `SeekdbWindowedCursor` (`AbstractWindowedCursor`) + `SeekdbStreamingPolicy` / `SeekdbSQLite.setStreamingQueryCursorsEnabled` (default off); integrates with `SeekdbCompatStatement.executeQueryCursor`
  - `com.vanniktech.maven.publish` for release coordinates (replaces manual `afterEvaluate` `maven-publish` block)
- Performance baseline smoke test added:
  - `SeekdbCompatPerformanceSmokeTest`
- Release engineering baseline added:
  - `maven-publish` configuration for release component

## In Progress

- Add execution-time cancel/interrupt support from `CancellationSignal` into native query path.
- Add flaky retry strategy for emulator stage in CI.

## Strategic goal: full SQLite capability replacement (not Room-only)

Product expectation is to **substitute sqlite-android / framework SQLite** for apps that need the full Java stack (`SQLiteDatabase`, windowed cursors, connection pool, hooks where supported), not only Room. See `seekdb-android-design.md` §13–§14 for phased delivery and ABI prerequisites.

**Reference implementation:** [sqlite-android](https://github.com/requery/sqlite-android) (`io.requery.android.database.sqlite.*`, `io.requery.android.database.CursorWindow`, connection pool/session).

**Current gap (summary):** seekdb-android exposes SupportSQLite + thin native API; sqlite-android exposes ~30 Java types and compiles SQLite into the AAR. Closing the gap requires **both** SeekDB C ABI growth (step/reset/cancel, long-lived results, pool-friendly connections) **and** a large Java port or attributed fork of the sqlite-android layer wired to SeekDB JNI.

## Next

- Maintain Room/SupportSQLite regression tests as the safety net.
- Improve typed mapping coverage for date/time/blob/vector edge types.
- Add stricter transaction nesting semantics compatible with `SupportSQLiteDatabase`.
- Add migration stress scenarios and large-result memory regression tests.
- **Full-replacement track:** publish class-level parity checklist vs sqlite-android; implement streaming cursor + windowed reads; then connection pool/session; then `SQLiteDatabase` public surface.
