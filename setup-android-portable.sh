#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=""
TARGET_ROOT=""
ASSUME_YES=0

JDK_MAJOR="21"
JAVA_MODE="temurin"
JAVA_CUSTOM_URL=""
ANDROID_PLATFORM="android-35"
BUILD_TOOLS="35.0.0"

CMDLINE_TOOLS_REV="11076708"
CMDLINE_TOOLS_ZIP="commandlinetools-linux-${CMDLINE_TOOLS_REV}_latest.zip"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/${CMDLINE_TOOLS_ZIP}"

STUDIO_VERSION="2024.1.1.0"
STUDIO_ARCHIVE="android-studio-${STUDIO_VERSION}-linux.tar.gz"
STUDIO_URL="https://redirector.gvt1.com/edgedl/android/studio/ide-zips/${STUDIO_VERSION}/${STUDIO_ARCHIVE}"

JDK17_URL="https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse"
JDK21_URL="https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse"

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_FAIL="\033[1;31m"; C_INFO="\033[1;36m"
else
  C_RESET=""; C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""
fi

log() { printf "%b[INFO]%b %s\n" "$C_INFO" "$C_RESET" "$*"; }
ok() { printf "%b[ OK ]%b %s\n" "$C_OK" "$C_RESET" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$C_WARN" "$C_RESET" "$*"; }
fail() { printf "%b[FAIL]%b %s\n" "$C_FAIL" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Portable Android setup

Usage:
  ./setup-android-portable.sh [install_dir] [options]

Options:
  --mode <all|base|studio|status|verify|open-studio>
  --dir <path>
  --jdk <17|21>
  --java-mode <temurin|system|custom>
  --java-url <https://...tar.gz>   (required for --java-mode custom)
  --platform <android-35|android-36>
  --build-tools <version>
  --yes
  --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --dir) TARGET_ROOT="${2:-}"; shift 2 ;;
    --jdk) JDK_MAJOR="${2:-}"; shift 2 ;;
    --java-mode) JAVA_MODE="${2:-}"; shift 2 ;;
    --java-url) JAVA_CUSTOM_URL="${2:-}"; shift 2 ;;
    --platform) ANDROID_PLATFORM="${2:-}"; shift 2 ;;
    --build-tools) BUILD_TOOLS="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      if [[ -z "$TARGET_ROOT" ]]; then TARGET_ROOT="$1"; shift; else fail "Unknown arg: $1"; fi
      ;;
  esac
done

TARGET_ROOT="${TARGET_ROOT:-$PWD}"
ANDROID_DIR="$TARGET_ROOT/android"
SDK_DIR="$ANDROID_DIR/sdk"
JAVA_DIR="$ANDROID_DIR/jdk"
STUDIO_DIR="$ANDROID_DIR/android-studio"
CACHE_DIR="$ANDROID_DIR/.cache"
TOOLS_DIR="$SDK_DIR/cmdline-tools/latest"
CONFIG_FILE="$ANDROID_DIR/.portable-android.conf"

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

save_config() {
  mkdir -p "$ANDROID_DIR"
  cat > "$CONFIG_FILE" <<EOF
JAVA_MODE="$JAVA_MODE"
JDK_MAJOR="$JDK_MAJOR"
JAVA_CUSTOM_URL="$JAVA_CUSTOM_URL"
ANDROID_PLATFORM="$ANDROID_PLATFORM"
BUILD_TOOLS="$BUILD_TOOLS"
EOF
}

load_config

need_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_tools() {
  local missing=()
  need_cmd tar || missing+=(tar)
  need_cmd unzip || missing+=(unzip)
  need_cmd df || missing+=(df)
  if ! need_cmd curl && ! need_cmd wget; then missing+=("curl|wget"); fi
  (( ${#missing[@]} == 0 )) || fail "Missing required tools: ${missing[*]}"
}

download_file() {
  local url="$1" out="$2"
  if [[ -s "$out" ]]; then ok "Cached: $(basename "$out")"; return 0; fi
  mkdir -p "$(dirname "$out")"
  if need_cmd curl; then
    curl -fL "$url" -o "$out"
  else
    wget -O "$out" "$url"
  fi
}

check_space() {
  local avail_kb
  avail_kb="$(df -Pk "$TARGET_ROOT" | awk 'NR==2{print $4}')"
  local need_kb=$((12 * 1024 * 1024))
  if [[ -n "$avail_kb" && "$avail_kb" -lt "$need_kb" ]]; then
    fail "Not enough free space in $TARGET_ROOT. Need >=12GB."
  fi
  ok "Free space check passed"
}

ensure_dirs() {
  mkdir -p "$ANDROID_DIR" "$SDK_DIR" "$CACHE_DIR" "$ANDROID_DIR/.android" "$ANDROID_DIR/.gradle" "$ANDROID_DIR/.config" "$ANDROID_DIR/.cache"
}

write_env_files() {
  mkdir -p "$ANDROID_DIR"
  local env_java
  if [[ "$JAVA_MODE" == "system" ]]; then
    env_java='if command -v java >/dev/null 2>&1; then export JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"; fi'
  else
    env_java='export JAVA_HOME="$ROOT_DIR/jdk"'
  fi
  cat > "$ANDROID_DIR/env.sh" <<EOF
#!/usr/bin/env bash

ROOT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export ANDROID_HOME="\$ROOT_DIR/sdk"
export ANDROID_SDK_ROOT="\$ROOT_DIR/sdk"
export ANDROID_STUDIO="\$ROOT_DIR/android-studio"

$env_java

export ANDROID_USER_HOME="\$ROOT_DIR/.android"
export GRADLE_USER_HOME="\$ROOT_DIR/.gradle"
export XDG_CONFIG_HOME="\$ROOT_DIR/.config"
export XDG_CACHE_HOME="\$ROOT_DIR/.cache"

if [[ -n "\${JAVA_HOME:-}" ]]; then
  export PATH="\$JAVA_HOME/bin:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$PATH"
else
  export PATH="\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$PATH"
fi

studio() {
  "\$ANDROID_STUDIO/bin/studio.sh"
}
EOF
  chmod +x "$ANDROID_DIR/env.sh"

  cat > "$ANDROID_DIR/env" <<'EOF'
#!/usr/bin/env bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
EOF
  chmod +x "$ANDROID_DIR/env"

  cat > "$ANDROID_DIR/run-studio.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/env.sh"
if [[ ! -x "$ANDROID_STUDIO/bin/studio.sh" ]]; then
  echo "[FAIL] Android Studio not installed: $ANDROID_STUDIO"
  exit 1
fi
exec "$ANDROID_STUDIO/bin/studio.sh"
EOF
  chmod +x "$ANDROID_DIR/run-studio.sh"
  ok "Created env files"
}

export_portable_env() {
  export ANDROID_HOME="$SDK_DIR"
  export ANDROID_SDK_ROOT="$SDK_DIR"
  if [[ "$JAVA_MODE" == "system" ]]; then
    if command -v java >/dev/null 2>&1; then
      export JAVA_HOME
      JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    else
      fail "JAVA_MODE=system but no system java found in PATH"
    fi
  else
    export JAVA_HOME="$JAVA_DIR"
  fi
  export ANDROID_STUDIO="$STUDIO_DIR"
  export ANDROID_USER_HOME="$ANDROID_DIR/.android"
  export GRADLE_USER_HOME="$ANDROID_DIR/.gradle"
  export XDG_CONFIG_HOME="$ANDROID_DIR/.config"
  export XDG_CACHE_HOME="$ANDROID_DIR/.cache"
  export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
}

install_jdk() {
  if [[ "$JAVA_MODE" == "system" ]]; then
    if command -v java >/dev/null 2>&1; then
      ok "Using system Java: $(java -version 2>&1 | head -n 1)"
      return
    fi
    fail "JAVA_MODE=system but java is not installed"
  fi

  local url
  if [[ "$JAVA_MODE" == "custom" ]]; then
    [[ -n "$JAVA_CUSTOM_URL" ]] || fail "--java-url is required for --java-mode custom"
    url="$JAVA_CUSTOM_URL"
  else
    case "$JDK_MAJOR" in
      17) url="$JDK17_URL" ;;
      21) url="$JDK21_URL" ;;
      *) fail "Unsupported JDK: $JDK_MAJOR" ;;
    esac
  fi
  if [[ -x "$JAVA_DIR/bin/java" ]]; then ok "JDK already installed"; return; fi
  local archive
  if [[ "$JAVA_MODE" == "custom" ]]; then
    archive="$CACHE_DIR/jdk-custom.tar.gz"
    log "Downloading custom JDK archive"
  else
    archive="$CACHE_DIR/jdk-${JDK_MAJOR}.tar.gz"
    log "Downloading JDK $JDK_MAJOR"
  fi
  download_file "$url" "$archive"
  if ! tar -tzf "$archive" >/dev/null 2>&1; then
    warn "Cached JDK archive is invalid, re-downloading"
    rm -f "$archive"
    download_file "$url" "$archive"
    tar -tzf "$archive" >/dev/null 2>&1 || fail "Downloaded JDK archive is invalid"
  fi
  rm -rf "$JAVA_DIR"
  mkdir -p "$JAVA_DIR"
  tar -xzf "$archive" -C "$JAVA_DIR" --strip-components=1
  ok "Installed JDK"
}

install_cmdline_tools() {
  if [[ -x "$TOOLS_DIR/bin/sdkmanager" ]]; then ok "cmdline-tools already installed"; return; fi
  local zip_path="$CACHE_DIR/$CMDLINE_TOOLS_ZIP"
  log "Downloading Android cmdline-tools"
  download_file "$CMDLINE_TOOLS_URL" "$zip_path"
  mkdir -p "$SDK_DIR/cmdline-tools"
  rm -rf "$SDK_DIR/cmdline-tools/latest"
  unzip -q -o "$zip_path" -d "$SDK_DIR/cmdline-tools"
  mv "$SDK_DIR/cmdline-tools/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"
  ok "Installed cmdline-tools"
}

install_sdk_packages() {
  export_portable_env
  yes | sdkmanager --sdk_root="$SDK_DIR" --licenses >/dev/null || true
  sdkmanager --sdk_root="$SDK_DIR" \
    "platform-tools" \
    "platforms;${ANDROID_PLATFORM}" \
    "build-tools;${BUILD_TOOLS}"
  ok "Installed SDK packages"
}

install_studio() {
  if [[ -x "$STUDIO_DIR/bin/studio.sh" ]]; then ok "Android Studio already installed"; return; fi
  local archive="$CACHE_DIR/$STUDIO_ARCHIVE"
  log "Downloading Android Studio ${STUDIO_VERSION}"
  download_file "$STUDIO_URL" "$archive"
  rm -rf "$STUDIO_DIR"
  mkdir -p "$STUDIO_DIR"
  tar -xzf "$archive" -C "$STUDIO_DIR" --strip-components=1
  ok "Installed Android Studio"
}

check_line() {
  local label="$1" state="$2" details="$3"
  case "$state" in
    OK) printf "%b%-7s%b %-22s %s\n" "$C_OK" "[OK]" "$C_RESET" "$label" "$details" ;;
    WARN) printf "%b%-7s%b %-22s %s\n" "$C_WARN" "[WARN]" "$C_RESET" "$label" "$details" ;;
    FAIL) printf "%b%-7s%b %-22s %s\n" "$C_FAIL" "[FAIL]" "$C_RESET" "$label" "$details" ;;
  esac
}

show_status() {
  echo
  printf "Portable Android status\n"
  printf "Root: %s\n" "$TARGET_ROOT"
  printf "Android dir: %s\n\n" "$ANDROID_DIR"
  printf "Java mode: %s"
  if [[ "$JAVA_MODE" == "temurin" ]]; then printf " (Temurin %s)\n\n" "$JDK_MAJOR"; else printf "\n\n"; fi

  local bad=0
  if [[ "$JAVA_MODE" == "system" ]]; then
    if command -v java >/dev/null 2>&1; then
      check_line "System Java" OK "$(java -version 2>&1 | head -n 1)"
    else
      check_line "System Java" FAIL "java not found in PATH"
      bad=1
    fi
  else
    [[ -x "$JAVA_DIR/bin/java" ]] && check_line "JDK" OK "$JAVA_DIR" || { check_line "JDK" FAIL "missing"; bad=1; }
  fi
  [[ -x "$TOOLS_DIR/bin/sdkmanager" ]] && check_line "cmdline-tools" OK "$TOOLS_DIR/bin/sdkmanager" || { check_line "cmdline-tools" FAIL "missing"; bad=1; }
  [[ -x "$SDK_DIR/platform-tools/adb" ]] && check_line "platform-tools" OK "$SDK_DIR/platform-tools/adb" || { check_line "platform-tools" FAIL "missing"; bad=1; }
  [[ -d "$SDK_DIR/platforms/${ANDROID_PLATFORM}" ]] && check_line "platform ${ANDROID_PLATFORM}" OK "installed" || { check_line "platform ${ANDROID_PLATFORM}" WARN "not installed"; bad=1; }
  [[ -d "$SDK_DIR/build-tools/${BUILD_TOOLS}" ]] && check_line "build-tools ${BUILD_TOOLS}" OK "installed" || { check_line "build-tools ${BUILD_TOOLS}" WARN "not installed"; bad=1; }
  [[ -x "$STUDIO_DIR/bin/studio.sh" ]] && check_line "Android Studio" OK "$STUDIO_DIR" || check_line "Android Studio" WARN "not installed"
  [[ -f "$ANDROID_DIR/env.sh" ]] && check_line "env.sh" OK "$ANDROID_DIR/env.sh" || { check_line "env.sh" FAIL "missing"; bad=1; }
  [[ -f "$ANDROID_DIR/env" ]] && check_line "env" OK "$ANDROID_DIR/env" || { check_line "env" WARN "missing"; bad=1; }
  [[ -x "$ANDROID_DIR/run-studio.sh" ]] && check_line "run-studio.sh" OK "$ANDROID_DIR/run-studio.sh" || check_line "run-studio.sh" WARN "missing"

  for d in .gradle .android .config .cache; do
    [[ -d "$ANDROID_DIR/$d" ]] && check_line "isolation dir $d" OK "exists" || { check_line "isolation dir $d" WARN "missing"; bad=1; }
  done

  echo
  if [[ "$bad" -eq 0 ]]; then
    printf "%bHEALTHY%b Portable environment looks good.\n" "$C_OK" "$C_RESET"
  else
    printf "%bNEEDS FIX%b Run: ./setup-android-portable.sh --mode all --dir \"%s\"\n" "$C_WARN" "$C_RESET" "$TARGET_ROOT"
  fi
}

verify_install() {
  export_portable_env
  [[ -x "$JAVA_DIR/bin/java" ]] && java -version || warn "java not found"
  [[ -x "$TOOLS_DIR/bin/sdkmanager" ]] && sdkmanager --list >/dev/null && ok "sdkmanager --list OK" || warn "sdkmanager unavailable"
  [[ -x "$SDK_DIR/platform-tools/adb" ]] && adb version || warn "adb unavailable"
}

open_studio() {
  write_env_files
  [[ -x "$ANDROID_DIR/run-studio.sh" ]] || fail "run-studio.sh missing"
  exec "$ANDROID_DIR/run-studio.sh"
}

install_base() {
  ensure_tools
  ensure_dirs
  check_space
  install_jdk
  install_cmdline_tools
  export_portable_env
  install_sdk_packages
  write_env_files
}

install_all() {
  install_base
  install_studio
  write_env_files
}

interactive_menu() {
  ensure_dirs
  write_env_files
  while true; do
    if [[ -t 1 ]]; then
      clear
    fi
    echo "=========================================="
    echo "  Portable Android Setup (interactive)"
    echo "=========================================="
    echo
    show_status
    echo
    echo "Select action:"
    echo "  1) Install Base (JDK + SDK)"
    echo "  2) Install Studio"
    echo "  3) Install All"
    echo "  4) Status (refresh)"
    echo "  5) Verify"
    echo "  6) Open Studio"
    echo "  7) Java Settings"
    echo "  0) Exit"
    read -r -p "> " choice

    case "$choice" in
      1) install_base ;;
      2) ensure_tools; ensure_dirs; check_space; install_studio; write_env_files ;;
      3) install_all ;;
      4) ;;
      5) verify_install ;;
      6) open_studio ;;
      7)
        echo
        echo "Java mode:"
        echo "  1) temurin (portable)"
        echo "  2) system"
        echo "  3) custom URL (.tar.gz)"
        read -r -p "> " jchoice
        case "$jchoice" in
          1) JAVA_MODE="temurin"; read -r -p "JDK version (17/21) [${JDK_MAJOR}]: " jv; JDK_MAJOR="${jv:-$JDK_MAJOR}" ;;
          2) JAVA_MODE="system" ;;
          3) JAVA_MODE="custom"; read -r -p "Enter JDK tar.gz URL: " ju; JAVA_CUSTOM_URL="$ju" ;;
          *) warn "Unknown Java option" ;;
        esac
        save_config
        write_env_files
        ;;
      0) exit 0 ;;
      *)
        warn "Unknown menu item: $choice"
        ;;
    esac

    if [[ "$choice" != "4" ]]; then
      echo
      read -r -p "Press Enter to continue..." _
    fi
  done
}

if [[ -z "$MODE" ]]; then
  if [[ -t 0 ]]; then
    interactive_menu
  else
    MODE="all"
  fi
fi

case "$MODE" in
  base) install_base ;;
  studio) ensure_tools; ensure_dirs; check_space; install_studio; write_env_files ;;
  all) install_all ;;
  status) ensure_dirs; write_env_files; show_status ;;
  verify) ensure_dirs; write_env_files; verify_install ;;
  open-studio) ensure_dirs; open_studio ;;
  *) fail "Unsupported mode: $MODE" ;;
esac

save_config

if [[ "$MODE" == "base" || "$MODE" == "studio" || "$MODE" == "all" ]]; then
  echo
  show_status
  echo
  echo "Quick start:"
  echo "  source "$ANDROID_DIR/env.sh""
  echo "  studio"
  echo "  ./gradlew assembleDebug"
fi
