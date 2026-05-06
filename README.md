# Portable Android Environment (Linux/Ubuntu)

Local Android development environment without global SDK/Studio install.

## Quick start

```bash
./setup-android-portable.sh
```

Without arguments script opens interactive menu.

## One-line install (non-interactive)

```bash
./setup-android-portable.sh --mode all
```

Install to custom path:

```bash
./setup-android-portable.sh /mnt/big_disk/android-dev --mode all
```

## Modes

- `base` - JDK + Android SDK (for Gradle CLI builds)
- `studio` - only Android Studio
- `emulator` - install emulator package + selected system image profile
- `all` - alias of `ide-ready` (base + studio + emulator profile)
- `ide-ready` - canonical internal mode (same behavior as `all`)
- `reinstall` - smart reinstall of currently installed components
- `status` - detailed health/status dashboard
- `versions` - show installed tool/package versions
- `verify` - validate Java/SDK consistency and required components
- `cache-audit` - check autonomous/offline cache readiness and list missing local artifacts
- `perf` - print render performance diagnostics
- `perf-raw` - print full/raw render diagnostics (forced heavy refresh)
- `perf-compare` - compare optimized vs raw render collection timing
- `open-studio` - run Android Studio with portable env
- `enter-env` - open shell with portable env loaded
- `clear-cache` - clear download cache (`cache/`, including `cache/sdk-packages/`)

## Java selection

Default is portable Temurin 21.

- Portable Temurin: `--java-mode temurin --jdk 17|21`
- Use system Java: `--java-mode system`
- Use custom JDK archive URL: `--java-mode custom --java-url <tar.gz-url>`

Examples:

```bash
./setup-android-portable.sh --mode all --java-mode temurin --jdk 17
./setup-android-portable.sh --mode all --java-mode system
./setup-android-portable.sh --mode all --java-mode custom --java-url "https://example.com/jdk.tar.gz"
```

In interactive mode, use `6) Java Settings`.

In `Install` menu you can also choose `Reinstall component` and reinstall only:

- Java (JDK)
- Android SDK (cmdline-tools + packages)
- Android Studio
- Emulator components
- Env files (`env.sh`, `env`, `run-studio.sh`)

`Install` also includes `Fix only errors`:

- Runs checks similar to `Verify`
- Reinstalls only broken parts (Java / cmdline-tools / SDK packages / env files)

Examples:

```bash
./setup-android-portable.sh --mode status
./setup-android-portable.sh --mode versions
./setup-android-portable.sh --mode verify
./setup-android-portable.sh --mode cache-audit
./setup-android-portable.sh --mode reinstall
./setup-android-portable.sh --mode clear-cache
./setup-android-portable.sh --mode open-studio
./setup-android-portable.sh --mode enter-env
```

## Environment activation

After setup:

```bash
source android/env.sh
```

or (venv-style short form):

```bash
source android/env
```

Then use:

```bash
studio
./gradlew assembleDebug
```

Direct Studio launch without `source`:

```bash
./android/run-studio.sh
```

## Isolation guarantees

All important state goes into local `android/` directory:

- `android/sdk`
- `android/jdk`
- `android/android-studio`
- `android/.gradle`
- `android/.android`
- `android/.config`
- `android/.cache`

Download archives are cached near the setup script:

- `cache/` (JDK archives, cmdline-tools zip, Android Studio tar.gz)

You can configure cache behavior in interactive menu:

- `Settings` -> `Cache profile`

Cache modes in `Settings`:

- `Minimal` (default): Java archive ON, SDK tools archive ON, Studio installer OFF, SDK package OFF
- `Balanced`: Java archive ON, SDK tools archive ON, Studio installer OFF, SDK package ON
- `Aggressive`: all caches ON
- `No cache`: all caches OFF
- `Custom`: shown automatically when cache flags are changed manually

SDK package cache in `Settings`:

- `SDK package cache: ON` - cache installed SDK folders (`platform-tools`, selected `platforms`, selected `build-tools`) in `cache/sdk-packages/`
- `SDK package cache: OFF` - do not store/restore SDK package folders from cache

Emulator profile in `Settings`:

- `Emulator: OFF` by default (enabled by Aggressive cache preset or manually)
- Profile type:
  - `Default` - user-configurable API/Image/ABI
  - `Wizard compatible` - fixed to `android-35` + `google_apis` + `x86_64`
- API/Image/ABI selectors apply to `Default` profile
- Auto-create AVD: `ON` by default

You can also toggle:

- `Offline Mode` - strict autonomous mode (0 network requests). Uses only local cache/installed artifacts/local source paths.
- In strict autonomous mode, cache flags are ignored for required components: local artifacts must exist and are used directly.

In `Offline Mode`:

- No download/resolve/check via internet is performed.
- If required artifacts are missing locally, install fails fast with a clear message.
- Preflight runs before install and validates all required local artifacts for the selected mode.
- You can provide local file/dir sources in `Advanced Sources` (absolute or relative paths).

Advanced Sources in `Settings`:

- Toggle custom sources ON/OFF
- Override cmdline-tools source (URL or local path)
- Override Android Studio source (URL or local path)

Current settings are shown in the main dashboard menu.

No changes are written to `~/.bashrc`. No global Android SDK install is used.

## Tested and guaranteed

Tested and guaranteed to work on:

- `Ubuntu 24.04.4 LTS (Noble Numbat)`
