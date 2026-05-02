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

- `all` - JDK + Android SDK + Android Studio
- `base` - JDK + Android SDK (for Gradle CLI builds)
- `studio` - only Android Studio
- `reinstall` - smart reinstall of currently installed components
- `status` - detailed health/status dashboard
- `versions` - show installed tool/package versions
- `verify` - validate Java/SDK consistency and required components
- `open-studio` - run Android Studio with portable env
- `enter-env` - open shell with portable env loaded
- `clear-cache` - clear download cache (`cache/`)

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

In interactive mode, use `3) Java Settings`.

In `Install` menu you can also choose `Reinstall component` and reinstall only:

- Java (JDK)
- Android SDK (cmdline-tools + packages)
- Android Studio
- Env files (`env.sh`, `env`, `run-studio.sh`)

`Install` also includes `Fix only errors`:

- Runs checks similar to `Verify`
- Reinstalls only broken parts (Java / cmdline-tools / SDK packages / env files)

Examples:

```bash
./setup-android-portable.sh --mode status
./setup-android-portable.sh --mode versions
./setup-android-portable.sh --mode verify
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

You can configure download cache behavior in interactive menu:

- `Settings` -> `Cache mode`

Cache modes in `Settings`:

- `all` - cache Java + SDK + Studio archives
- `java` - cache only Java archives
- `none` - disable archive cache

SDK package cache in `Settings`:

- `SDK package cache: ON` - cache installed SDK folders (`platform-tools`, selected `platforms`, selected `build-tools`) in `cache/sdk-packages/`
- `SDK package cache: OFF` - do not store/restore SDK package folders from cache

You can also toggle:

- `Pick from installed only` - choose platform/build-tools only from locally installed versions

Current settings are shown in the main dashboard menu.

No changes are written to `~/.bashrc`. No global Android SDK install is used.

## Tested and guaranteed

Tested and guaranteed to work on:

- `Ubuntu 24.04.4 LTS (Noble Numbat)`
