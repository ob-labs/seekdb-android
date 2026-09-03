# Todo List App Example

A minimal Android app that uses **Room** on top of **seekdb-android** (`SeekdbCompat.factory()`).

## What it demonstrates

- Room `@Entity` / `@Dao` / `@Database` with `SeekdbCompat.factory()` as the open-helper factory
- MVVM with `ViewModel` + `LiveData`
- CRUD UI for a todo list (add, edit, delete, toggle completion)
- Optional **Database Inspector** via `seekdb-android-inspection` (debug builds only)

## Open & run

This directory is a **self-contained Gradle project**, so it can be opened directly:

1. In Android Studio choose **File → Open** and select this `examples/todo-list-app` directory.
2. Let Gradle Sync finish (JDK 17 and an Android SDK 36 platform are required).
3. After Sync completes, Android Studio creates the default **app** run configuration for the `:app` module automatically — pick it and press Run.

Or build from the command line:

```bash
cd examples/todo-list-app
./gradlew :app:assembleDebug
```

## How seekdb-android is wired

`app/build.gradle.kts` depends on the published-style coordinates
`com.oceanbase.seekdb:seekdb-android:0.1.0-SNAPSHOT` (and the `seekdb-android-inspection`
add-on for debug builds). `settings.gradle.kts` then declares
`includeBuild("../..")` — the root of this repository — and substitutes those coordinates
with the local `:seekdb-android` / `:seekdb-android-inspection` modules, so the sample always
tracks the checked-out library source. The path is relative, so no machine-specific path is
committed.

Once `seekdb-android` is published, delete the `includeBuild` block and point Gradle at the
published repository (JitPack / Maven Central) — no other change is needed.

The native engine (`libseekdb.so`) is packaged when the `seekdb-android` module builds: the
`downloadLibseekdb` task fetches the prebuilt binary from the S3 prefix in
[`gradle.properties`](../../gradle.properties) (`LIBSEEKDB_URL_PREFIX`). Without network
access, place a prebuilt `.so` manually and disable downloads as described in the root
[README](../../README.md).

## Key files

| File | Purpose |
|------|---------|
| `app/src/main/java/.../TodoDatabase.java` | Room database wired to SeekDB |
| `app/src/main/java/.../TodoDao.java` | DAO queries |
| `app/src/main/java/.../MainActivity.java` | UI entry point |

See the root [README](../../README.md) and [docs](../../docs/seekdb-android/) for library setup and migration notes.
