# seekdb-android Design Docs Index

- `seekdb-android-design.md`: end-to-end architecture and phase plan.
- User-facing migration (Room / SQLite): see repository root [`README.md`](../../README.md#migration-guide); `migration-from-room-and-sqlite.md` is a short index only.
- `api-compat-layer.md`: SQLite/Room compatibility layer design.
- `room-sqlite-compat.md`: Room / SupportSQLite adaptation points (SQL rewrites, PRAGMA/sqlite_master routing, transactions, invalidation).
- `api-native-layer.md`: SeekDB native layer design.
- `compat-contract-matrix.md`: compatibility levels and verification contract.
- `room-p0-scope.md`: Room P0 scope and done definition.
- `jni-memory-threading.md`: JNI ownership, memory, and threading rules.
- `testing-and-release.md`: quality gates, CI, and release checklist.
- `implementation-status.md`: current implementation progress and next tasks.
- `inspector-setup.md`: Database Inspector (`debugImplementation` + AndroidX snapshot repo for `androidx.inspection`).
- `local-dev-guide.md`: local build/test workflow without Gradle wrapper.
- `seekdb-engine-android.md`: SeekDB engine (`seekdb` repo) + Android embed required changes, build, and verification (`libseekdb.so`, pm clear, cold instrument run).
- `android-startup-timeline-measurement-2026-09-07.md`: on-device cold/warm startup timeline measurements (`SeekdbStartup` logcat stages), A/B batches per engine commit, and the engine-side drill-down that followed.
- `measure/`: measurement tooling — `parse_startup.py` (logcat timeline parser) plus `remeasure.sh`, `compare_ab_interleaved.sh`, `compare_ab_emulator.sh`, and `test_data_persist.sh` (each script's header documents its usage and artifacts).
