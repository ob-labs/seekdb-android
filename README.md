# seekdb-android

[![ci](https://github.com/ob-labs/seekdb-android/actions/workflows/ci.yml/badge.svg)](https://github.com/ob-labs/seekdb-android/actions/workflows/ci.yml)

Android library: **SeekDB** over JNI, with a **Room / `SupportSQLite`** surface similar to typical SQLite-on-Android usage (broader `SQLiteDatabase`-shaped APIs are on the roadmap).

## Room integration

Use **`SeekdbCompat.factory()`** as the `SupportSQLiteOpenHelper.Factory` when building your `RoomDatabase`. Room’s `@Entity` / `@Dao` / `@Database` stay the same; only the open-helper factory and native packaging change.

### 1. Gradle

**JitPack (current distribution):** add the JitPack repository and depend on the module-scoped coordinate — the AAR (with `libseekdb.so` already packaged) is built on demand from each `v*` tag:

```gradle
// settings.gradle
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven { url "https://jitpack.io" }
    }
}

// app/build.gradle
dependencies {
    implementation "com.github.ob-labs.seekdb-android:seekdb-android:${version}"
}
```

See the **JitPack (distribution)** section below for details (including the inspection add-on).

Local checkout:

```bash
./gradlew :seekdb-android:assembleDebug
./gradlew :seekdb-android:publishToMavenLocal
```

### 2. Native engine (`libseekdb.so`)

Since the engine binary is packaged into the published AAR at build time, consumers get it automatically. In a **local checkout**, the `downloadLibseekdb` Gradle task fetches prebuilt `libseekdb.so` from the S3 prefix configured in `gradle.properties` (`LIBSEEKDB_URL_PREFIX`) into `build/generated/libseekdb/jniLibs/<abi>/` (Gradle-incremental: re-runs only when inputs change; `-PLIBSEEKDB_FORCE_DOWNLOAD=true` to refresh). To use a manually placed binary instead, disable downloads with `-PLIBSEEKDB_URL_PREFIX=` and put the `.so` under `src/main/jniLibs/<abi>/`.

Without the native library, `SeekdbClient.isNativeAvailable()` is false and the compat layer cannot open the engine.

At runtime you can probe:

```java
import com.oceanbase.seekdb.android.nativeapi.SeekdbClient;

if (!SeekdbClient.isNativeAvailable()) {
    // Show error or fall back; do not build Room with SeekdbCompat in this state.
}
```

(`com.oceanbase.seekdb.android.sqlite.SeekdbSQLite` also exposes `isNativeLibraryAvailable()` if you use that entry point.)

### 3. Wire Room

```java
import androidx.room.Room;
import com.oceanbase.seekdb.android.compat.SeekdbCompat;

AppDatabase db = Room.databaseBuilder(context, AppDatabase.class, "app.db")
        .openHelperFactory(SeekdbCompat.factory())
        .build();
```

**Database name / path**

| `Room.databaseBuilder(..., name)` | Effect |
|-----------------------------------|--------|
| **Relative** name (e.g. `"app.db"`) | Resolved with `Context.getDatabasePath` — data under app-private internal storage. |
| **Absolute** path (e.g. `new File(context.getFilesDir(), "seekdb/app.db").getAbsolutePath()`) | SeekDB uses **the parent directory of that file** as the engine root (`store/`, `log/`, etc. sit next to the `.db`). |

Prefer **internal** paths (`getFilesDir()`, `getDatabasePath`) first when validating; some devices or engine builds are sensitive to **app-specific external** roots (`getExternalFilesDir`). See [`docs/seekdb-android/room-sqlite-compat.md`](docs/seekdb-android/room-sqlite-compat.md) for dialect / `PRAGMA` notes.

### 4. Optional APIs

- **Streaming large cursors** (off by default): `com.oceanbase.seekdb.android.sqlite.SeekdbSQLite.setStreamingQueryCursorsEnabled(true)` — only if you use the `SeekdbSQLite` helpers.
- **Full native teardown** when no seekdb-backed DB is needed anymore: `SeekdbCompat.shutdownEmbeddedEngine()` (not the same as closing a single `SupportSQLiteOpenHelper`; see Javadoc).

### 5. Database Inspector (debug)

Add **`seekdb-android-inspection`** as `debugImplementation` — e.g. `debugImplementation "com.github.ob-labs.seekdb-android:seekdb-android-inspection:${version}"` (or `debugImplementation files("libs/seekdb-android-inspection-<version>.aar")` when using the GitHub Release AAR fallback) — and follow [`docs/seekdb-android/inspector-setup.md`](docs/seekdb-android/inspector-setup.md) (includes the AndroidX inspection snapshot repository).

---

## Documentation

Design notes, testing, release: [`docs/seekdb-android/`](docs/seekdb-android/README.md).

## Examples

- **[Todo List App](examples/todo-list-app/)** — Room + MVVM sample wired to `SeekdbCompat.factory()`. It is a **self-contained Gradle project**: open `examples/todo-list-app` directly in Android Studio and press Run, or build from the command line:

  ```bash
  cd examples/todo-list-app && ./gradlew :app:assembleDebug
  ```

  It builds `seekdb-android` from source in this repository via `includeBuild("../..")`, so the sample stays in sync with the library without needing a published artifact.

## Alternative factory (`SeekdbSQLite`)

If you standardize on the `SeekdbSQLite` entry point:

```java
import com.oceanbase.seekdb.android.sqlite.SeekdbSQLite;

Room.databaseBuilder(context, AppDb.class, "app.db")
        .openHelperFactory(SeekdbSQLite.supportOpenHelperFactory())
        .build();
```

Do **not** mix sqlite-android and seekdb-android on the same classpath expecting two SQLite backends.

## JitPack (distribution)

The repository distributes through **JitPack** (`jitpack.yml` pins JDK 17 for AGP 8). Pushing a `v*` tag makes the artifacts available on https://jitpack.io, built on demand by JitPack — no Sonatype account, signing key, or release AAR required. Both `:seekdb-android` and `:seekdb-android-inspection` are published.

This is a **multi-module Gradle project**, so JitPack exposes one coordinate per module (form `com.github.<org>.<repo>:<module>`), plus an aggregate coordinate that pulls every module:

```gradle
// main library only (recommended — the inspection add-on is debug-only)
implementation "com.github.ob-labs.seekdb-android:seekdb-android:${version}"

// inspection add-on (Database Inspector, debug builds only)
debugImplementation "com.github.ob-labs.seekdb-android:seekdb-android-inspection:${version}"

// aggregate: every published module (includes the inspection add-on)
implementation "com.github.ob-labs:seekdb-android:${version}"
```

`${version}` is a release tag such as `0.1.0`. After the first tag, look up `ob-labs/seekdb-android` on https://jitpack.io to confirm the exact module list and coordinates.

## GitHub Release AAR (fallback)

Tag releases additionally attach both release AARs to the GitHub Release (`release.yml`): download `seekdb-android-release.aar` (the library; the engine `libseekdb.so` is already packaged inside) and, if needed, `seekdb-android-inspection-release.aar`, then consume them as file dependencies:

1. Put the AAR under `app/libs/` (renaming with the version helps, e.g. `seekdb-android-0.1.0.aar`).
2. Declare it:

```groovy
dependencies {
    implementation files("libs/seekdb-android-0.1.0.aar")
}
```

A file-based AAR has **no POM**, so Gradle does not resolve transitive dependencies: the app must also declare what the module's API references (`androidx.sqlite:sqlite` — normally already present via Room — and `androidx.annotation:annotation`).

For the inspector AAR, add it as `debugImplementation files(...)` and follow [`docs/seekdb-android/inspector-setup.md`](docs/seekdb-android/inspector-setup.md), which covers the `androidx.inspection` snapshot repository and the extra dependencies the file AAR does not pull in on its own (the `seekdb-android` AAR, `protobuf-javalite`, `jspecify`).

## Maven Central (future, optional)

Can be enabled later once the `com.oceanbase` namespace membership and the Sonatype secrets are in place (see `docs/seekdb-android/testing-and-release.md` §8). Releases use **`com.vanniktech.maven.publish`**; on a tag push, `release.yml` runs **`./gradlew publish`** when the Sonatype credentials (`SonatypeUsername` / `SonatypePassword`) and the GPG signing keys (`SigningInMemoryKey` / `SigningInMemoryKeyId` / `SigningInMemoryKeyPassword`) are configured as repo secrets, publishing `com.oceanbase.seekdb:seekdb-android`. Until then the **JitPack** channel above is the distribution.

---

## Migration (concise)

### From stock Room (framework SQLite)

1. Add **seekdb-android** (the engine `.so` is packaged into the published AAR; nothing extra to ship).  
2. Add **`.openHelperFactory(SeekdbCompat.factory())`** (or `SeekdbSQLite.supportOpenHelperFactory()`) to `Room.databaseBuilder(...)`.  
3. Run your usual schema / CRUD / invalidation tests; fix SQL only where the engine dialect differs from SQLite ([compat matrix](docs/seekdb-android/compat-contract-matrix.md), [Room notes](docs/seekdb-android/room-sqlite-compat.md)).

Direct `android.database.sqlite.SQLiteDatabase` usage outside Room is unchanged only if you keep using framework SQLite for those paths; long-term, prefer `SupportSQLite` / Room or future seekdb-shaped APIs.

### From Room + sqlite-android

1. **Remove** the `io.requery:sqlite-android` dependency (and orphans).  
2. **Add** seekdb-android (engine `.so` included in the AAR); attach **`SeekdbCompat.factory()`** (or `SeekdbSQLite.supportOpenHelperFactory()`) to `Room.databaseBuilder`.  
3. Replace any **`io.requery.android.database.*`** imports with this library’s APIs or access DB only through Room / `SupportSQLite`.  
4. **Inspector:** add **`seekdb-android-inspection`** per [inspector-setup.md](docs/seekdb-android/inspector-setup.md).

Finer behavior tiers: [compat contract matrix](docs/seekdb-android/compat-contract-matrix.md).

## License

See [`LICENSE`](LICENSE) and [`seekdb-android/NOTICE`](seekdb-android/NOTICE).
