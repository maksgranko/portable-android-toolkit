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
- `status` - detailed health/status dashboard
- `verify` - run post-check commands
- `open-studio` - run Android Studio with portable env

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

In interactive mode, use `7) Java Settings`.

Examples:

```bash
./setup-android-portable.sh --mode status
./setup-android-portable.sh --mode verify
./setup-android-portable.sh --mode open-studio
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

No changes are written to `~/.bashrc`. No global Android SDK install is used.

## Tested and guaranteed

Tested and guaranteed to work on:

- `Ubuntu 24.04.4 LTS (Noble Numbat)`
