# Testing and Release Plan

## 1. Test Pyramid

- Unit tests:
  - API argument validation.
  - index conversion and type mapping.
  - error mapping logic.
  - streaming policy default (`SeekdbStreamingPolicy` / `SeekdbSQLite` facade).
- Integration tests:
  - JNI wrapper lifecycle and resource management.
  - statement and result end-to-end flows.
- Instrumentation tests:
  - Room P0 functional scenarios.
  - compatibility matrix regressions.

## 2. CI Gates

- Build gate:
  - Android library compiles with JNI artifacts for target ABIs.
- Quality gate:
  - MustCompatible test suite must pass.
  - Room P0 suite must pass.
- Stability gate:
  - no known deterministic leak in automated stress run.

Current workflow (instrumented tests currently **paused** — degraded gate):

- GitHub Actions file: `.github/workflows/ci.yml` (workflow name `ci`)
- `permissions: contents: read`
- Triggers: **`on: [push, pull_request]`** (all branches)
- Runner: **`ubuntu-latest`** (no emulator)
- Steps: checkout (`fetch-depth: 1`) → JDK 17 (**`distribution: adopt`**) → install NDK `28.2.13676358` + CMake `3.22.1` (JNI glue via `externalNativeBuild`) → **`./gradlew :seekdb-android:testDebugUnitTest :seekdb-android:assembleDebug --stacktrace`** (JVM unit tests + debug assemble, packaging the arm64 engine from the pinned `LIBSEEKDB_URL_PREFIX`) → upload `**/build/reports/tests/**` → **`./gradlew publish`** when **`refs/heads/main` + `push`** with `SonatypeUsername` / `SonatypePassword` → `ORG_GRADLE_PROJECT_mavenCentral*`

**Why instrumentation is paused (and how to re-enable it):** the released engine ships `arm64-v8a` only, and GitHub hosted runners cannot boot any Android emulator — macOS runners moved to virtualized Apple Silicon (no nested virtualization / HVF for arm64 images, and x86 images are unsupported on aarch64 hosts), while an x86/x86_64 emulator would load no engine (no x86_64 `libseekdb.so` published), so every engine test would fail or silently skip. Plan to restore full engine coverage on hosted runners (this was the original upstream layout, kept as a commented-out step in `ci.yml`):
1. devdeps infra publishes the `android/26/x86_64` devdeps set (mirror currently has only `arm64`).
2. Engine CI (`build-libseekdb.yml` in the seekdb repo, android job matrixed over `arm64-v8a` + `x86_64` via `ANDROID_ABI`) publishes `libseekdb-android-x86_64.zip` for a new commit.
3. Point `gradle.properties` → `LIBSEEKDB_URL_PREFIX` at that commit and uncomment the emulator step in `ci.yml` (`ubuntu-latest` + KVM + `x86_64` image, `script` with `-PLIBSEEKDB_ABIS=x86_64`).

The engine-side plumbing (seekdb repo): `build.sh` / `dep_create.sh` / `package/libseekdb/libseekdb-build.sh` accept `ANDROID_ABI` (default `arm64-v8a`, unchanged) and `deps/init/oceanbase.android.x86_64.deps` exists, so re-enabling is a config-only change.

**Note:** Publishing is wired to the default branch **`main`**: on `push` to `main`, CI runs `./gradlew publish`, gated on the Sonatype secrets being configured — it stays skipped until §8.3 is ready (repo under a personal account, Central namespace pending). A `VERSION_NAME` ending in `-SNAPSHOT` is deployed to the Sonatype snapshot repository; a plain version is automatically closed and released on Maven Central (`automaticRelease = true`). Requires repo secrets `SonatypeUsername` / `SonatypePassword` plus the GPG signing secrets (`SigningInMemoryKey`, `SigningInMemoryKeyId`, `SigningInMemoryKeyPassword`).

**Tag release:** pushing a **`v*` semver tag** (`v[0-9]*.[0-9]*.[0-9]*`) triggers two things: (1) **JitPack** builds and serves the artifacts from that tag on demand (§8.6) — the adopted distribution channel; (2) `.github/workflows/release.yml` runs unit tests, builds both release AARs (`:seekdb-android:assembleRelease` + `:seekdb-android-inspection:assembleRelease`) and creates a **GitHub Release** with auto-generated notes and **both AARs attached** as a manual fallback. The version is derived from the tag (e.g. `v0.1.0`), so no `VERSION_NAME` bump is needed. When the Sonatype secrets (§8.3) are configured later, it additionally runs `./gradlew publish -PVERSION_NAME=${GITHUB_REF_NAME#v}`. Tag only after `main` is green (instrumentation is covered by ci.yml on `main`).

Local / extra gates (not in upstream CI): run `./gradlew :seekdb-android:assembleDebug` and `./gradlew :seekdb-android:testDebugUnitTest` before push if desired.

## 3. Performance Baseline

- Statement execution latency baseline.
- Query cursor traversal baseline.
- Transaction throughput baseline.
- Performance smoke test:
  - `SeekdbCompatPerformanceSmokeTest` validates baseline insert+query budget.

Track delta between releases to avoid regressions.

## 4. Release Artifacts

- AAR package.
- Native libs for declared ABIs.
- API docs and compatibility matrix snapshot.
- Known limitations and migration notes.
- Maven publication via **`com.vanniktech.maven.publish`** (aligned with sqlite-android); local verify: `./gradlew :seekdb-android:publishToMavenLocal`. Because `signAllPublications()` also signs the local publication, provide signing properties for local verify (e.g. a throwaway key: `-PsigningInMemoryKey=... -PsigningInMemoryKeyPassword=...`). Central release additionally requires `ORG_GRADLE_PROJECT_mavenCentralUsername` / `Password` (repo secrets `SonatypeUsername` / `SonatypePassword`) plus `signingInMemoryKey` / `signingInMemoryKeyId` / `signingInMemoryKeyPassword` (see `.github/workflows/ci.yml` for the repo-secret names).

## 5. Versioning and Compatibility Notes

- Semantic versioning for library API.
- Compatibility note per release:
  - Room P0 status.
  - MustCompatible coverage status.
  - newly supported degraded/not-supported items if changed.

## 6. Release Checklist

- All P0 tests passing in CI.
- Compatibility matrix reviewed and updated.
- ABI package contents verified.
- Changelog prepared.

## 7. Local Execution Notes

Without Gradle wrapper in repository:

- Ensure local Gradle 8.13 is available in PATH.
- Run:
  - `gradle :seekdb-android:assembleDebug`
  - `gradle :seekdb-android:testDebugUnitTest`

For instrumentation tests:

- Use a connected Android device or emulator.
- Run:
  - `gradle :seekdb-android:connectedDebugAndroidTest`

Native requirement:

- `libseekdb.so` is fetched automatically at build time by the `downloadLibseekdb` task from the S3 URL prefix in `gradle.properties` (`LIBSEEKDB_URL_PREFIX`); the native library is unpacked into `build/generated/libseekdb/jniLibs/<abi>/` and into the published AAR.
- If downloads are disabled (`-PLIBSEEKDB_URL_PREFIX=`) or a configured ABI has no prebuilt artifact, the task skips/warns and builds proceed with manually placed files under `src/main/jniLibs/<abi>/`; tests with native availability assumptions will be skipped when the native library is absent.
- The build fails if the prefix is set but no ABI could be installed (avoids publishing an AAR without the engine). To refresh a stale engine binary: `./gradlew :seekdb-android:downloadLibseekdb -PLIBSEEKDB_FORCE_DOWNLOAD=true`.

Stale device state:

- If instrumentation fails after engine or schema changes (e.g. migration **downgrade** errors), clear the test package: `adb shell pm clear com.oceanbase.seekdb.android.test`, reinstall if needed, then rerun. See **`docs/seekdb-android/seekdb-engine-android.md`** for the full note.

Engine alignment:

- Android-specific behavior in the **seekdb** repository (RS reporting, DDL logging, signal/CPU startup, stmt write path) is summarized in **`docs/seekdb-android/seekdb-engine-android.md`** for reviewers and release notes.

## 8. One-time Publishing Setup (Maven Central)

OSSRH was shut down (June 30, 2025); all publishing goes through the **Central Portal** (`central.sonatype.com`). The build already routes there via `SONATYPE_HOST=DEFAULT` in `gradle.properties`. Do this once per organization; afterwards releases are tag-driven (§2, §8.5).

### 8.1 Sonatype account, namespace, user token

1. Sign in to `central.sonatype.com` (email or GitHub OAuth).
2. **Claim the namespace**: `Add Namespace` → `com.oceanbase`. The portal then verifies ownership via one of:
   - **GitHub org**: create a public repository under the `oceanbase` org with the exact name the portal gives you (proof of org ownership), or
   - **DNS**: add the TXT record shown in the portal to the `oceanbase.com` domain.
   Verification can take a few minutes. Publishing under `com.oceanbase.seekdb` only works after it passes.
3. **User token**: account menu → **User Token** → *Generate*. It returns a username (e.g. `user-9f3c…`) and a password. These two values — **not your login password** — are what the plugin reads as `mavenCentralUsername` / `mavenCentralPassword`.

### 8.2 GPG signing key

Central requires signed artifacts, and the **public key must be published to a keyserver** so the signature can be verified.

```bash
gpg --quick-generate-key "SeekDB Release <release@oceanbase.com>" rsa4096 sign 2y
gpg --list-secret-keys --keyid-format=long                 # KEYID = the 16-hex id
gpg --keyserver keyserver.ubuntu.com --send-keys <KEYID>   # publish public key (required)
gpg --export-secret-keys --armor <KEYID> > signing.key     # private key → secret only
```

Note down the passphrase chosen at generation time (or generate without one).

### 8.3 Configure GitHub secrets

`Settings → Secrets and variables → Actions` (or `gh secret set`):

| Secret | Value |
|---|---|
| `SonatypeUsername` | user-token username (§8.1.3) |
| `SonatypePassword` | user-token password (§8.1.3) |
| `SigningInMemoryKey` | content of `signing.key` (§8.2) |
| `SigningInMemoryKeyId` | the 16-hex KEYID (§8.2) |
| `SigningInMemoryKeyPassword` | the key passphrase, if any |

CLI equivalent (needs `gh auth login` with repo scope):

```bash
gh secret set SonatypeUsername
gh secret set SonatypePassword
gh secret set SigningInMemoryKey < signing.key
gh secret set SigningInMemoryKeyId
gh secret set SigningInMemoryKeyPassword
```

### 8.4 Verify

Push to `main` → ci.yml publishes `0.1.0-SNAPSHOT` to the snapshot repository — skipped until the §8.3 secrets are configured; until then tag releases ship AARs via §8.6. Local `publishToMavenLocal` also needs signing properties (§4).

### 8.5 First release

**Current — JitPack (repo at `ob-labs/seekdb-android`):** when `main` is green: `git tag v0.1.0 && git push origin v0.1.0`. Request the build once on https://jitpack.io (Look Up `ob-labs/seekdb-android` → *Get it*); consumers then add the `jitpack.io` repository and the module-scoped coordinates (README → "JitPack (distribution)"). `release.yml` additionally attaches both release AARs (`seekdb-android-release.aar`, `seekdb-android-inspection-release.aar`) to the GitHub Release as a manual fallback.

**After Central is enabled** (namespace §8.1 + secrets §8.3): the same tag additionally runs `./gradlew publish -PVERSION_NAME=0.1.0`, auto-releasing both artifacts — `com.oceanbase.seekdb:seekdb-android` and `com.oceanbase.seekdb:seekdb-android-inspection` (`./gradlew publish` publishes every module that applies the maven-publish plugin). Confirm both artifacts on `search.maven.org`.

### 8.6 Adopted channel: JitPack (repo under `ob-labs`)

The distribution decision is **JitPack**: once the repository lives at `ob-labs/seekdb-android` (creation requested through a community vote PR — see the `votes/` proposals in `oceanbase/community`, e.g. #87), the JitPack coordinate is stable, so each `v*` tag is served from https://jitpack.io with no Sonatype account, signing key, or release AAR:

- `jitpack.yml` pins JDK 17 for AGP 8. JitPack builds every tag on demand via `./gradlew build publishToMavenLocal`; both modules publish through the existing `com.vanniktech.maven.publish` setup. Verified locally that `publishToMavenLocal` succeeds **without** signing keys — signing is only wired into the Central path.
- Multi-module coordinates (README → "JitPack (distribution)"): main library `com.github.ob-labs.seekdb-android:seekdb-android:<tag>`; the aggregate `com.github.ob-labs:seekdb-android:<tag>` pulls every module incl. the inspection add-on. Confirm the module list on https://jitpack.io after the first tag.
- `release.yml` still builds both release AARs and attaches them to the GitHub Release as a **manual fallback** (consumers who do not use JitPack).
- Maven Central (`com.oceanbase.seekdb`) remains an optional later step: claiming the `com.oceanbase` namespace (§8.1) needs an `oceanbase`-org public repo or the `oceanbase.com` DNS proof; once the §8.3 secrets exist, the same tag also runs `./gradlew publish`.
