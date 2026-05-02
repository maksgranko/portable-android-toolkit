#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=""
TARGET_ROOT=""
ASSUME_YES=0

JDK_MAJOR="21"
JAVA_MODE="temurin"
JAVA_CUSTOM_URL=""
DOWNLOAD_CACHE_MODE="all"
PICK_FROM_INSTALLED_ONLY="0"
SDK_PACKAGE_CACHE="1"
ANDROID_PLATFORM="android-35"
BUILD_TOOLS="35.0.0"

CMDLINE_TOOLS_REV="11076708"
CMDLINE_TOOLS_ZIP="commandlinetools-linux-${CMDLINE_TOOLS_REV}_latest.zip"
CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/${CMDLINE_TOOLS_ZIP}"

STUDIO_VERSION="2024.3.1.13"
STUDIO_ARCHIVE="android-studio-${STUDIO_VERSION}-linux.tar.gz"
STUDIO_URL="https://redirector.gvt1.com/edgedl/android/studio/ide-zips/${STUDIO_VERSION}/${STUDIO_ARCHIVE}"

JDK17_URL="https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse"
JDK21_URL="https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse"

if [[ -t 1 ]]; then
  C_RESET="\033[0m"; C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_FAIL="\033[1;31m"; C_INFO="\033[1;36m"; C_DIM="\033[2m"
else
  C_RESET=""; C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_DIM=""
fi

log() { printf "%b[INFO]%b %s\n" "$C_INFO" "$C_RESET" "$*"; }
ok() { printf "%b[ OK ]%b %s\n" "$C_OK" "$C_RESET" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "$C_WARN" "$C_RESET" "$*"; }
fail() { printf "%b[FAIL]%b %s\n" "$C_FAIL" "$C_RESET" "$*" >&2; exit 1; }

hr() { printf "%b%s%b\n" "$C_DIM" "────────────────────────────────────────────────────────────" "$C_RESET"; }

dir_size_human() {
  local d="$1"
  if [[ -d "$d" ]]; then
    du -sh "$d" 2>/dev/null | awk '{print $1}'
  else
    printf "0"
  fi
}

usage() {
  cat <<USAGE
Portable Android setup

Usage:
  ./setup-android-portable.sh [install_dir] [options]

Options:
  --mode <all|base|studio|reinstall|status|versions|verify|open-studio|enter-env|clear-cache>
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
DOWNLOAD_CACHE_DIR="$SCRIPT_DIR/cache"
SDK_PACKAGE_CACHE_DIR="$DOWNLOAD_CACHE_DIR/sdk-packages"
TOOLS_DIR="$SDK_DIR/cmdline-tools/latest"
CONFIG_FILE="$ANDROID_DIR/.portable-android.conf"
JDK_META_FILE="$JAVA_DIR/.portable-jdk.meta"
LOCK_FILE="$ANDROID_DIR/.setup.lock"

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
DOWNLOAD_CACHE_MODE="$DOWNLOAD_CACHE_MODE"
PICK_FROM_INSTALLED_ONLY="$PICK_FROM_INSTALLED_ONLY"
SDK_PACKAGE_CACHE="$SDK_PACKAGE_CACHE"
ANDROID_PLATFORM="$ANDROID_PLATFORM"
BUILD_TOOLS="$BUILD_TOOLS"
EOF
}

load_config

normalize_settings() {
  if [[ -n "${USE_DOWNLOAD_CACHE:-}" && -z "${DOWNLOAD_CACHE_MODE:-}" ]]; then
    if [[ "$USE_DOWNLOAD_CACHE" == "1" ]]; then
      DOWNLOAD_CACHE_MODE="all"
    else
      DOWNLOAD_CACHE_MODE="none"
    fi
  fi
  case "${DOWNLOAD_CACHE_MODE:-all}" in
    all|java|none) ;;
    *) DOWNLOAD_CACHE_MODE="all" ;;
  esac
  case "${PICK_FROM_INSTALLED_ONLY:-0}" in
    0|1) ;;
    *) PICK_FROM_INSTALLED_ONLY="0" ;;
  esac
  case "${SDK_PACKAGE_CACHE:-1}" in
    0|1) ;;
    *) SDK_PACKAGE_CACHE="1" ;;
  esac
}

normalize_settings

need_cmd() { command -v "$1" >/dev/null 2>&1; }

release_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local lock_pid
    lock_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ "$lock_pid" == "$$" ]]; then
      rm -f "$LOCK_FILE"
    fi
  fi
}

acquire_lock() {
  mkdir -p "$ANDROID_DIR"
  if [[ -f "$LOCK_FILE" ]]; then
    local existing_pid
    existing_pid="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      warn "Another setup instance is already running (PID: $existing_pid)"
      if [[ -t 0 ]]; then
        read -r -p "Terminate previous instance and continue? [y/N]: " ans
        case "$ans" in
          y|Y|yes|YES)
            if kill "$existing_pid" 2>/dev/null; then
              ok "Previous instance terminated"
              sleep 1
            else
              fail "Could not terminate running instance: $existing_pid"
            fi
            ;;
          *)
            fail "Aborted to avoid concurrent setup runs"
            ;;
        esac
      else
        fail "Another setup instance is running (PID: $existing_pid). Stop it first."
      fi
    else
      warn "Found stale lock file, replacing it"
    fi
  fi

  printf "%s\n" "$$" > "$LOCK_FILE"
  trap release_lock EXIT INT TERM
}

acquire_lock

ensure_tools() {
  local missing=()
  need_cmd tar || missing+=(tar)
  need_cmd unzip || missing+=(unzip)
  need_cmd df || missing+=(df)
  if ! need_cmd curl && ! need_cmd wget; then missing+=("curl|wget"); fi
  (( ${#missing[@]} == 0 )) || fail "Missing required tools: ${missing[*]}"
}

cache_allowed_for() {
  local kind="$1"
  case "$DOWNLOAD_CACHE_MODE" in
    all) return 0 ;;
    java) [[ "$kind" == "java" ]] && return 0 || return 1 ;;
    none) return 1 ;;
    *) return 0 ;;
  esac
}

download_file() {
  local url="$1" out="$2" kind="${3:-all}"
  if cache_allowed_for "$kind" && [[ -s "$out" ]]; then ok "Cached: $(basename "$out")"; return 0; fi
  if ! cache_allowed_for "$kind"; then
    rm -f "$out"
  fi
  mkdir -p "$(dirname "$out")"
  if need_cmd curl; then
    if ! curl -fL "$url" -o "$out"; then
      return 1
    fi
  else
    if ! wget -O "$out" "$url"; then
      return 1
    fi
  fi
}

show_settings_summary() {
  local java_summary="$JAVA_MODE"
  if [[ "$JAVA_MODE" == "temurin" ]]; then
    java_summary="$JAVA_MODE (JDK $JDK_MAJOR)"
  fi
  local pick_mode="available"
  [[ "$PICK_FROM_INSTALLED_ONLY" == "1" ]] && pick_mode="installed-only"
  local sdk_cache_mode="OFF"
  [[ "$SDK_PACKAGE_CACHE" == "1" ]] && sdk_cache_mode="ON"
  local pick_state="OFF"
  [[ "$PICK_FROM_INSTALLED_ONLY" == "1" ]] && pick_state="ON"
  printf "%bCurrent settings:%b " "$C_INFO" "$C_RESET"
  printf "%bJava:%b %s  %b|%b  %bCache:%b %s, %bPick:%b %s, %bSDK:%b %s" "$C_OK" "$C_RESET" "$java_summary" "$C_DIM" "$C_RESET" "$C_WARN" "$C_RESET" "$DOWNLOAD_CACHE_MODE" "$C_INFO" "$C_RESET" "$pick_state" "$C_INFO" "$C_RESET" "$sdk_cache_mode"
  printf "\n"
}

settings_menu() {
  echo
  printf "%bSettings:%b\n" "$C_INFO" "$C_RESET"
  printf "  %b1) Cache mode%b (current: %s)\n" "$C_WARN" "$C_RESET" "$DOWNLOAD_CACHE_MODE"
  printf "  %b2) Set Android platform%b (current: %s)\n" "$C_INFO" "$C_RESET" "$ANDROID_PLATFORM"
  printf "  %b3) Set build-tools version%b (current: %s)\n" "$C_INFO" "$C_RESET" "$BUILD_TOOLS"
  printf "  %b4) Pick from installed only%b (current: %s)\n" "$C_INFO" "$C_RESET" "$([[ "$PICK_FROM_INSTALLED_ONLY" == "1" ]] && echo ON || echo OFF)"
  printf "  %b5) SDK package cache%b (current: %s)\n" "$C_INFO" "$C_RESET" "$([[ "$SDK_PACKAGE_CACHE" == "1" ]] && echo ON || echo OFF)"
  printf "  %b6) Clear download cache%b\n" "$C_WARN" "$C_RESET"
  printf "  %b7) Clear SDK package cache%b\n" "$C_WARN" "$C_RESET"
  printf "  %b0) Back%b\n" "$C_DIM" "$C_RESET"
  read -r -p "> " schoice
  case "$schoice" in
    1)
      printf "%bCache mode:%b\n" "$C_INFO" "$C_RESET"
      printf "  %b1) all%b   (cache Java + SDK + Studio archives)\n" "$C_INFO" "$C_RESET"
      printf "  %b2) java%b  (cache only Java archives)\n" "$C_INFO" "$C_RESET"
      printf "  %b3) none%b  (always download fresh)\n" "$C_INFO" "$C_RESET"
      read -r -p "> " cmode
      case "$cmode" in
        1) DOWNLOAD_CACHE_MODE="all" ;;
        2) DOWNLOAD_CACHE_MODE="java" ;;
        3) DOWNLOAD_CACHE_MODE="none" ;;
        *) warn "Unknown cache mode" ;;
      esac
      save_config
      ok "Download cache mode is now: $DOWNLOAD_CACHE_MODE"
      ;;
    2)
      local platforms latest_platform installed_platforms
      platforms=""
      latest_platform=""
      installed_platforms=""
      installed_platforms="$(get_installed_platforms)"

      if [[ "$PICK_FROM_INSTALLED_ONLY" == "1" ]]; then
        platforms="$installed_platforms"
        latest_platform="$(printf "%s\n" "$platforms" | tail -n 1)"
      elif [[ -x "$TOOLS_DIR/bin/sdkmanager" ]]; then
        export_portable_env
        platforms="$(get_available_platforms)"
        latest_platform="$(printf "%s\n" "$platforms" | tail -n 1)"
      fi

      print_short_list "Available platforms:" "$platforms" "$ANDROID_PLATFORM"
      print_short_list "Installed platforms:" "$installed_platforms" "$ANDROID_PLATFORM"
      echo "Input rules:"
      echo "  - Enter empty value -> keep current ($ANDROID_PLATFORM)"
      if [[ -n "$latest_platform" ]]; then
        echo "  - Enter 0 -> use latest ($latest_platform)"
      else
        echo "  - Enter 0 -> try latest (if available later)"
      fi
      read -r -p "Platform (example: android-35): " pval

      if [[ -z "$pval" ]]; then
        ok "Platform unchanged: $ANDROID_PLATFORM"
      elif [[ "$pval" == "0" ]]; then
        if [[ -n "$latest_platform" ]]; then
          ANDROID_PLATFORM="$latest_platform"
          save_config
          ok "Platform set to latest: $ANDROID_PLATFORM"
        else
          warn "Could not resolve latest platform now; keeping: $ANDROID_PLATFORM"
        fi
      else
        if [[ -n "$platforms" ]] && ! printf "%s\n" "$platforms" | grep -qx "$pval"; then
          warn "Platform not available: $pval"
          warn "Keeping current: $ANDROID_PLATFORM"
        else
          ANDROID_PLATFORM="$pval"
          save_config
          ok "Platform set to $ANDROID_PLATFORM"
        fi
      fi
      ;;
    3)
      local build_tools_list latest_build_tools installed_build_tools
      build_tools_list=""
      latest_build_tools=""
      installed_build_tools=""
      installed_build_tools="$(get_installed_build_tools)"

      if [[ "$PICK_FROM_INSTALLED_ONLY" == "1" ]]; then
        build_tools_list="$installed_build_tools"
        latest_build_tools="$(printf "%s\n" "$build_tools_list" | tail -n 1)"
      elif [[ -x "$TOOLS_DIR/bin/sdkmanager" ]]; then
        export_portable_env
        build_tools_list="$(get_available_build_tools)"
        latest_build_tools="$(printf "%s\n" "$build_tools_list" | tail -n 1)"
      fi

      print_short_list "Available build-tools:" "$build_tools_list" "$BUILD_TOOLS"
      print_short_list "Installed build-tools:" "$installed_build_tools" "$BUILD_TOOLS"
      echo "Input rules:"
      echo "  - Enter empty value -> keep current ($BUILD_TOOLS)"
      if [[ -n "$latest_build_tools" ]]; then
        echo "  - Enter 0 -> use latest ($latest_build_tools)"
      else
        echo "  - Enter 0 -> try latest (if available later)"
      fi
      read -r -p "Build-tools version (example: 35.0.0): " bval

      if [[ -z "$bval" ]]; then
        ok "Build-tools unchanged: $BUILD_TOOLS"
      elif [[ "$bval" == "0" ]]; then
        if [[ -n "$latest_build_tools" ]]; then
          BUILD_TOOLS="$latest_build_tools"
          save_config
          ok "Build-tools set to latest: $BUILD_TOOLS"
        else
          warn "Could not resolve latest build-tools now; keeping: $BUILD_TOOLS"
        fi
      else
        if [[ -n "$build_tools_list" ]] && ! printf "%s\n" "$build_tools_list" | grep -qx "$bval"; then
          warn "Build-tools not available: $bval"
          warn "Keeping current: $BUILD_TOOLS"
        else
          BUILD_TOOLS="$bval"
          save_config
          ok "Build-tools set to $BUILD_TOOLS"
        fi
      fi
      ;;
    4)
      if [[ "$PICK_FROM_INSTALLED_ONLY" == "1" ]]; then
        PICK_FROM_INSTALLED_ONLY="0"
      else
        PICK_FROM_INSTALLED_ONLY="1"
      fi
      save_config
      ok "Pick from installed only: $([[ "$PICK_FROM_INSTALLED_ONLY" == "1" ]] && echo ON || echo OFF)"
      ;;
    5)
      if [[ "$SDK_PACKAGE_CACHE" == "1" ]]; then
        SDK_PACKAGE_CACHE="0"
      else
        SDK_PACKAGE_CACHE="1"
      fi
      save_config
      ok "SDK package cache: $([[ "$SDK_PACKAGE_CACHE" == "1" ]] && echo ON || echo OFF)"
      ;;
    6)
      clear_download_cache
      ;;
    7)
      mkdir -p "$SDK_PACKAGE_CACHE_DIR"
      rm -rf "$SDK_PACKAGE_CACHE_DIR"/*
      ok "SDK package cache cleared"
      ;;
    0)
      SKIP_PAUSE=1
      ;;
    *) warn "Unknown settings option: $schoice" ;;
  esac
}

studio_candidates() {
  cat <<EOF
https://redirector.gvt1.com/edgedl/android/studio/ide-zips/2024.3.1.13/android-studio-2024.3.1.13-linux.tar.gz
https://redirector.gvt1.com/edgedl/android/studio/ide-zips/2024.2.2.14/android-studio-2024.2.2.14-linux.tar.gz
https://redirector.gvt1.com/edgedl/android/studio/ide-zips/2024.1.1.13/android-studio-2024.1.1.13-linux.tar.gz
https://redirector.gvt1.com/edgedl/android/studio/ide-zips/2024.1.1.0/android-studio-2024.1.1.0-linux.tar.gz
EOF
}

resolve_studio_url() {
  local candidate
  for candidate in $(studio_candidates); do
    if need_cmd curl; then
      if curl -fsIL "$candidate" >/dev/null 2>&1; then
        STUDIO_URL="$candidate"
        STUDIO_ARCHIVE="$(basename "$candidate")"
        STUDIO_VERSION="$(echo "$candidate" | awk -F'/' '{print $(NF-1)}')"
        return 0
      fi
    else
      if wget --spider -q "$candidate" >/dev/null 2>&1; then
        STUDIO_URL="$candidate"
        STUDIO_ARCHIVE="$(basename "$candidate")"
        STUDIO_VERSION="$(echo "$candidate" | awk -F'/' '{print $(NF-1)}')"
        return 0
      fi
    fi
  done
  return 1
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

get_available_platforms() {
  sdkmanager --list 2>/dev/null | sed -n 's/^  platforms;\(android-[0-9][0-9]*\)[[:space:]]\+|.*/\1/p' | sort -uV
}

get_available_build_tools() {
  sdkmanager --list 2>/dev/null | sed -n 's/^  build-tools;\([0-9]\+\.[0-9]\+\.[0-9]\+\)[[:space:]]\+|.*/\1/p' | sort -uV
}

get_installed_platforms() {
  if [[ -d "$SDK_DIR/platforms" ]]; then
    for p in "$SDK_DIR"/platforms/android-*; do
      [[ -d "$p" ]] && basename "$p"
    done | sort -uV
  fi
}

get_installed_build_tools() {
  if [[ -d "$SDK_DIR/build-tools" ]]; then
    for b in "$SDK_DIR"/build-tools/*; do
      [[ -d "$b" ]] && basename "$b"
    done | sort -uV
  fi
}

get_cached_jdk_versions() {
  if [[ -d "$DOWNLOAD_CACHE_DIR" ]]; then
    for f in "$DOWNLOAD_CACHE_DIR"/jdk-*.tar.gz; do
      [[ -f "$f" ]] || continue
      basename "$f" | sed -n 's/^jdk-\([0-9][0-9]*\)\.tar\.gz$/\1/p'
    done | sort -uV
  fi
}

print_short_list() {
  local title="$1" values="$2" current="$3"
  echo "$title"
  if [[ -z "$values" ]]; then
    echo "  - (none)"
    return
  fi
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if [[ "$v" == "$current" ]]; then
      echo "  - $v (current)"
    else
      echo "  - $v"
    fi
  done <<< "$values"
}

ensure_dirs() {
  mkdir -p "$ANDROID_DIR" "$SDK_DIR" "$CACHE_DIR" "$ANDROID_DIR/.android" "$ANDROID_DIR/.gradle" "$ANDROID_DIR/.config" "$ANDROID_DIR/.cache" "$DOWNLOAD_CACHE_DIR" "$SDK_PACKAGE_CACHE_DIR"
}

sync_sdk_packages_to_cache() {
  [[ "$SDK_PACKAGE_CACHE" == "1" ]] || return 0
  mkdir -p "$SDK_PACKAGE_CACHE_DIR/platform-tools" "$SDK_PACKAGE_CACHE_DIR/platforms" "$SDK_PACKAGE_CACHE_DIR/build-tools"
  if [[ -d "$SDK_DIR/platform-tools" ]]; then
    rm -rf "$SDK_PACKAGE_CACHE_DIR/platform-tools"
    cp -a "$SDK_DIR/platform-tools" "$SDK_PACKAGE_CACHE_DIR/platform-tools"
  fi
  if [[ -d "$SDK_DIR/platforms/${ANDROID_PLATFORM}" ]]; then
    rm -rf "$SDK_PACKAGE_CACHE_DIR/platforms/${ANDROID_PLATFORM}"
    cp -a "$SDK_DIR/platforms/${ANDROID_PLATFORM}" "$SDK_PACKAGE_CACHE_DIR/platforms/${ANDROID_PLATFORM}"
  fi
  if [[ -d "$SDK_DIR/build-tools/${BUILD_TOOLS}" ]]; then
    rm -rf "$SDK_PACKAGE_CACHE_DIR/build-tools/${BUILD_TOOLS}"
    cp -a "$SDK_DIR/build-tools/${BUILD_TOOLS}" "$SDK_PACKAGE_CACHE_DIR/build-tools/${BUILD_TOOLS}"
  fi
}

restore_sdk_packages_from_cache() {
  [[ "$SDK_PACKAGE_CACHE" == "1" ]] || return 0
  local restored=0
  if [[ -d "$SDK_PACKAGE_CACHE_DIR/platform-tools" && ! -d "$SDK_DIR/platform-tools" ]]; then
    mkdir -p "$SDK_DIR"
    cp -a "$SDK_PACKAGE_CACHE_DIR/platform-tools" "$SDK_DIR/platform-tools"
    restored=1
  fi
  if [[ -d "$SDK_PACKAGE_CACHE_DIR/platforms/${ANDROID_PLATFORM}" && ! -d "$SDK_DIR/platforms/${ANDROID_PLATFORM}" ]]; then
    mkdir -p "$SDK_DIR/platforms"
    cp -a "$SDK_PACKAGE_CACHE_DIR/platforms/${ANDROID_PLATFORM}" "$SDK_DIR/platforms/${ANDROID_PLATFORM}"
    restored=1
  fi
  if [[ -d "$SDK_PACKAGE_CACHE_DIR/build-tools/${BUILD_TOOLS}" && ! -d "$SDK_DIR/build-tools/${BUILD_TOOLS}" ]]; then
    mkdir -p "$SDK_DIR/build-tools"
    cp -a "$SDK_PACKAGE_CACHE_DIR/build-tools/${BUILD_TOOLS}" "$SDK_DIR/build-tools/${BUILD_TOOLS}"
    restored=1
  fi
  [[ "$restored" -eq 1 ]] && ok "Restored SDK packages from cache"
}

root_rel() {
  local p="$1"
  if [[ "$p" == "$TARGET_ROOT"* ]]; then
    printf "(Root)%s" "${p#"$TARGET_ROOT"}"
  else
    printf "%s" "$p"
  fi
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
  local desired_tag
  if [[ "$JAVA_MODE" == "custom" ]]; then
    desired_tag="mode=custom,url=$JAVA_CUSTOM_URL"
  else
    desired_tag="mode=$JAVA_MODE,jdk=$JDK_MAJOR"
  fi

  if [[ -x "$JAVA_DIR/bin/java" && -f "$JDK_META_FILE" ]]; then
    local current_tag
    current_tag="$(cat "$JDK_META_FILE" 2>/dev/null || true)"
    if [[ "$current_tag" == "$desired_tag" ]]; then
      ok "JDK already installed"
      return
    fi
    warn "JDK config changed, reinstalling"
    rm -rf "$JAVA_DIR"
  fi

  local archive
  if [[ "$JAVA_MODE" == "custom" ]]; then
    local url_hash
    if command -v sha256sum >/dev/null 2>&1; then
      url_hash="$(printf "%s" "$JAVA_CUSTOM_URL" | sha256sum | cut -d' ' -f1)"
    else
      url_hash="custom"
    fi
    archive="$DOWNLOAD_CACHE_DIR/jdk-custom-${url_hash}.tar.gz"
    log "Downloading custom JDK archive"
  else
    archive="$DOWNLOAD_CACHE_DIR/jdk-${JDK_MAJOR}.tar.gz"
    log "Downloading JDK $JDK_MAJOR"
  fi
  download_file "$url" "$archive" "java"
  if ! tar -tzf "$archive" >/dev/null 2>&1; then
    warn "Cached JDK archive is invalid, re-downloading"
    rm -f "$archive"
    download_file "$url" "$archive" "java"
    tar -tzf "$archive" >/dev/null 2>&1 || fail "Downloaded JDK archive is invalid"
  fi
  rm -rf "$JAVA_DIR"
  mkdir -p "$JAVA_DIR"
  tar -xzf "$archive" -C "$JAVA_DIR" --strip-components=1
  printf "%s\n" "$desired_tag" > "$JDK_META_FILE"
  ok "Installed JDK"
}

install_cmdline_tools() {
  if [[ -x "$TOOLS_DIR/bin/sdkmanager" ]]; then ok "cmdline-tools already installed"; return; fi
  local zip_path="$DOWNLOAD_CACHE_DIR/$CMDLINE_TOOLS_ZIP"
  log "Downloading Android cmdline-tools"
  download_file "$CMDLINE_TOOLS_URL" "$zip_path" "all"
  mkdir -p "$SDK_DIR/cmdline-tools"
  rm -rf "$SDK_DIR/cmdline-tools/latest"
  unzip -q -o "$zip_path" -d "$SDK_DIR/cmdline-tools"
  mv "$SDK_DIR/cmdline-tools/cmdline-tools" "$SDK_DIR/cmdline-tools/latest"
  ok "Installed cmdline-tools"
}

install_sdk_packages() {
  export_portable_env
  restore_sdk_packages_from_cache

  local available_platforms available_build_tools
  available_platforms="$(get_available_platforms || true)"
  available_build_tools="$(get_available_build_tools || true)"

  if [[ -n "$available_platforms" ]] && ! printf "%s\n" "$available_platforms" | grep -qx "$ANDROID_PLATFORM"; then
    warn "Requested platform is unavailable: $ANDROID_PLATFORM"
    warn "Use Settings -> Set Android platform (0 for latest valid)"
    return 1
  fi

  if [[ -n "$available_build_tools" ]] && ! printf "%s\n" "$available_build_tools" | grep -qx "$BUILD_TOOLS"; then
    warn "Requested build-tools is unavailable: $BUILD_TOOLS"
    warn "Use Settings -> Set build-tools version (0 for latest valid)"
    return 1
  fi

  yes | sdkmanager --sdk_root="$SDK_DIR" --licenses >/dev/null || true
  sdkmanager --sdk_root="$SDK_DIR" \
    "platform-tools" \
    "platforms;${ANDROID_PLATFORM}" \
    "build-tools;${BUILD_TOOLS}"

  local sdk_ok=1
  [[ -x "$SDK_DIR/platform-tools/adb" ]] || sdk_ok=0
  [[ -d "$SDK_DIR/platforms/${ANDROID_PLATFORM}" ]] || sdk_ok=0
  [[ -d "$SDK_DIR/build-tools/${BUILD_TOOLS}" ]] || sdk_ok=0

  if [[ "$sdk_ok" -eq 1 ]]; then
    sync_sdk_packages_to_cache
    ok "Installed SDK packages"
  else
    warn "SDK package install incomplete (requested platform/build-tools may be unavailable)"
    return 1
  fi
}

install_studio() {
  if [[ -x "$STUDIO_DIR/bin/studio.sh" ]]; then ok "Android Studio already installed"; return; fi
  if ! resolve_studio_url; then
    warn "Could not resolve a working Android Studio URL from official candidates"
    return 1
  fi
  local archive="$DOWNLOAD_CACHE_DIR/$STUDIO_ARCHIVE"
  log "Downloading Android Studio ${STUDIO_VERSION}"
  if ! download_file "$STUDIO_URL" "$archive" "all"; then
    warn "Failed to download Android Studio: $STUDIO_URL"
    return 1
  fi
  if ! tar -tzf "$archive" >/dev/null 2>&1; then
    warn "Cached Android Studio archive is invalid, re-downloading"
    rm -f "$archive"
    if ! download_file "$STUDIO_URL" "$archive" "all"; then
      warn "Failed to re-download Android Studio archive"
      return 1
    fi
    if ! tar -tzf "$archive" >/dev/null 2>&1; then
      warn "Downloaded Android Studio archive is invalid"
      return 1
    fi
  fi
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
  printf "Root: %s\n" "$TARGET_ROOT"
  printf "Android dir: %s\n" "$(root_rel "$ANDROID_DIR")"
  printf "Download cache: %s (%s)\n" "$(root_rel "$DOWNLOAD_CACHE_DIR")" "$(dir_size_human "$DOWNLOAD_CACHE_DIR")"
  printf "Runtime cache: %s (%s)\n\n" "$(root_rel "$CACHE_DIR")" "$(dir_size_human "$CACHE_DIR")"

  # Fresh state: no install traces yet. Keep output short and beginner-friendly.
  if [[ ! -x "$JAVA_DIR/bin/java" && ! -x "$TOOLS_DIR/bin/sdkmanager" && ! -x "$SDK_DIR/platform-tools/adb" && ! -x "$STUDIO_DIR/bin/studio.sh" ]]; then
    printf "%bFRESH SETUP%b No Android components installed yet.\n" "$C_INFO" "$C_RESET"
    echo
    echo "Quick start for beginners:"
    echo "  - Press 4 (Install)"
    echo "  - Choose what you want: Base / Studio / All"
    return
  fi

  local bad=0
  if [[ "$JAVA_MODE" == "system" ]]; then
    if command -v java >/dev/null 2>&1; then
      check_line "System Java" OK "$(java -version 2>&1 | head -n 1)"
    else
      check_line "System Java" FAIL "java not found in PATH"
      bad=1
    fi
  else
    [[ -x "$JAVA_DIR/bin/java" ]] && check_line "JDK" OK "$(root_rel "$JAVA_DIR")" || { check_line "JDK" FAIL "missing"; bad=1; }
  fi
  [[ -x "$TOOLS_DIR/bin/sdkmanager" ]] && check_line "cmdline-tools" OK "$(root_rel "$TOOLS_DIR/bin/sdkmanager")" || { check_line "cmdline-tools" FAIL "missing"; bad=1; }
  [[ -x "$SDK_DIR/platform-tools/adb" ]] && check_line "platform-tools" OK "$(root_rel "$SDK_DIR/platform-tools/adb")" || { check_line "platform-tools" FAIL "missing"; bad=1; }
  [[ -d "$SDK_DIR/platforms/${ANDROID_PLATFORM}" ]] && check_line "platform ${ANDROID_PLATFORM}" OK "installed" || { check_line "platform ${ANDROID_PLATFORM}" WARN "not installed"; bad=1; }
  [[ -d "$SDK_DIR/build-tools/${BUILD_TOOLS}" ]] && check_line "build-tools ${BUILD_TOOLS}" OK "installed" || { check_line "build-tools ${BUILD_TOOLS}" WARN "not installed"; bad=1; }
  [[ -x "$STUDIO_DIR/bin/studio.sh" ]] && check_line "Android Studio" OK "$(root_rel "$STUDIO_DIR")" || check_line "Android Studio" WARN "not installed"

  local iso_missing=0
  for d in .gradle .android .config .cache; do
    [[ -d "$ANDROID_DIR/$d" ]] || iso_missing=1
  done
  if [[ "$iso_missing" -eq 0 ]]; then
    check_line "isolation dirs" OK ".gradle .android .config .cache"
  else
    check_line "isolation dirs" WARN "some missing"
    bad=1
  fi

  echo
  if [[ "$bad" -eq 0 ]]; then
    printf "%bHEALTHY%b Portable environment looks good.\n" "$C_OK" "$C_RESET"
  else
    printf "%bNEEDS FIX%b Some components are missing or incomplete.\n" "$C_WARN" "$C_RESET"
    echo "Fix:"
    echo "  - Install -> Fix only errors"
    echo "  - Verify"
  fi
}

show_versions() {
  export_portable_env
  echo
  echo "Installed versions"
  echo "Root: $TARGET_ROOT"
  echo

  if command -v java >/dev/null 2>&1; then
    echo "Java: $(java -version 2>&1 | head -n 1)"
  else
    echo "Java: not found"
  fi

  if [[ -x "$TOOLS_DIR/bin/sdkmanager" ]]; then
    echo "sdkmanager: $(sdkmanager --version 2>/dev/null || echo unknown)"
  else
    echo "sdkmanager: not found"
  fi

  if [[ -x "$SDK_DIR/platform-tools/adb" ]]; then
    echo "adb: $(adb version 2>/dev/null | head -n 1)"
  else
    echo "adb: not found"
  fi

  if [[ -x "$STUDIO_DIR/bin/studio.sh" ]]; then
    echo "Android Studio: installed at $STUDIO_DIR"
  else
    echo "Android Studio: not installed"
  fi

  echo
  echo "Download cache: $(root_rel "$DOWNLOAD_CACHE_DIR")"
  echo "Download cache size: $(dir_size_human "$DOWNLOAD_CACHE_DIR")"
  echo "Runtime cache size: $(dir_size_human "$CACHE_DIR")"

  echo
  echo "SDK packages (installed):"
  if [[ -d "$SDK_DIR/platform-tools" ]]; then
    echo "  - platform-tools"
  fi
  if [[ -d "$SDK_DIR/platforms" ]]; then
    for p in "$SDK_DIR"/platforms/android-*; do
      [[ -d "$p" ]] && echo "  - platforms;$(basename "$p")"
    done
  fi
  if [[ -d "$SDK_DIR/build-tools" ]]; then
    for b in "$SDK_DIR"/build-tools/*; do
      [[ -d "$b" ]] && echo "  - build-tools;$(basename "$b")"
    done
  fi

  echo
  echo "Tip: for full remote list use: sdkmanager --list"
}

verify_install() {
  export_portable_env
  echo
  echo "Verify portable environment"
  hr

  local failed=0

  if command -v java >/dev/null 2>&1; then
    local java_line
    java_line="$(java -version 2>&1 | head -n 1)"
    check_line "Java binary" OK "$java_line"

    if [[ "$JAVA_MODE" == "temurin" ]]; then
      if [[ "$java_line" == *"\"$JDK_MAJOR."* || "$java_line" == *"\"$JDK_MAJOR\""* ]]; then
        check_line "Java version target" OK "matches expected major $JDK_MAJOR"
      else
        check_line "Java version target" FAIL "expected major $JDK_MAJOR"
        failed=1
      fi
      if [[ "$JAVA_HOME" == "$JAVA_DIR" ]]; then
        check_line "JAVA_HOME" OK "$(root_rel "$JAVA_HOME")"
      else
        check_line "JAVA_HOME" FAIL "expected $(root_rel "$JAVA_DIR")"
        failed=1
      fi
    elif [[ "$JAVA_MODE" == "system" ]]; then
      check_line "Java mode" OK "using system Java"
      check_line "JAVA_HOME" OK "$JAVA_HOME"
    else
      check_line "Java mode" OK "custom URL"
    fi
  else
    check_line "Java binary" FAIL "not found in PATH"
    failed=1
  fi

  if [[ -x "$TOOLS_DIR/bin/sdkmanager" ]] && sdkmanager --version >/dev/null 2>&1; then
    check_line "sdkmanager" OK "available"
  else
    check_line "sdkmanager" FAIL "missing or not responding"
    failed=1
  fi

  if [[ -x "$SDK_DIR/platform-tools/adb" ]] && adb version >/dev/null 2>&1; then
    check_line "adb" OK "available"
  else
    check_line "adb" FAIL "missing or not responding"
    failed=1
  fi

  [[ -d "$SDK_DIR/platforms/${ANDROID_PLATFORM}" ]] && check_line "platform ${ANDROID_PLATFORM}" OK "installed" || { check_line "platform ${ANDROID_PLATFORM}" FAIL "missing"; failed=1; }
  [[ -d "$SDK_DIR/build-tools/${BUILD_TOOLS}" ]] && check_line "build-tools ${BUILD_TOOLS}" OK "installed" || { check_line "build-tools ${BUILD_TOOLS}" FAIL "missing"; failed=1; }
  [[ -f "$ANDROID_DIR/env.sh" ]] && check_line "env.sh" OK "present" || { check_line "env.sh" FAIL "missing"; failed=1; }
  [[ -x "$ANDROID_DIR/run-studio.sh" ]] && check_line "run-studio.sh" OK "present" || { check_line "run-studio.sh" FAIL "missing"; failed=1; }

  echo
  if [[ "$failed" -eq 0 ]]; then
    printf "%bVERIFY OK%b Environment is consistent and ready.\n" "$C_OK" "$C_RESET"
  else
    printf "%bVERIFY FAILED%b Fix missing items via Install menu.\n" "$C_FAIL" "$C_RESET"
  fi
}

collect_issues() {
  export_portable_env
  ISSUE_JAVA=0
  ISSUE_SDKMANAGER=0
  ISSUE_ADB=0
  ISSUE_PLATFORM=0
  ISSUE_BUILD_TOOLS=0
  ISSUE_ENV_FILES=0
  HAS_BASE=0
  HAS_STUDIO=0

  [[ -x "$JAVA_DIR/bin/java" || -x "$TOOLS_DIR/bin/sdkmanager" || -x "$SDK_DIR/platform-tools/adb" || -d "$SDK_DIR/platforms" || -d "$SDK_DIR/build-tools" ]] && HAS_BASE=1
  [[ -x "$STUDIO_DIR/bin/studio.sh" ]] && HAS_STUDIO=1

  if [[ "$HAS_BASE" -eq 1 ]]; then
    if ! command -v java >/dev/null 2>&1; then
      ISSUE_JAVA=1
    elif [[ "$JAVA_MODE" == "temurin" ]]; then
      local java_line
      java_line="$(java -version 2>&1 | head -n 1)"
      if [[ "$java_line" != *"\"$JDK_MAJOR."* && "$java_line" != *"\"$JDK_MAJOR\""* ]]; then
        ISSUE_JAVA=1
      fi
      [[ "$JAVA_HOME" == "$JAVA_DIR" ]] || ISSUE_JAVA=1
    fi
  fi

  if [[ "$HAS_BASE" -eq 1 ]]; then
    [[ -x "$TOOLS_DIR/bin/sdkmanager" ]] && sdkmanager --version >/dev/null 2>&1 || ISSUE_SDKMANAGER=1
    [[ -x "$SDK_DIR/platform-tools/adb" ]] && adb version >/dev/null 2>&1 || ISSUE_ADB=1
    [[ -d "$SDK_DIR/platforms/${ANDROID_PLATFORM}" ]] || ISSUE_PLATFORM=1
    [[ -d "$SDK_DIR/build-tools/${BUILD_TOOLS}" ]] || ISSUE_BUILD_TOOLS=1
  fi

  [[ -f "$ANDROID_DIR/env.sh" && -x "$ANDROID_DIR/run-studio.sh" ]] || ISSUE_ENV_FILES=1

  local total=0
  total=$((total + ISSUE_JAVA + ISSUE_SDKMANAGER + ISSUE_ADB + ISSUE_PLATFORM + ISSUE_BUILD_TOOLS + ISSUE_ENV_FILES))
  return "$total"
}

fix_only_errors() {
  ensure_tools
  ensure_dirs
  check_space
  collect_issues || true

  local total=$((ISSUE_JAVA + ISSUE_SDKMANAGER + ISSUE_ADB + ISSUE_PLATFORM + ISSUE_BUILD_TOOLS + ISSUE_ENV_FILES))
  if [[ "$HAS_BASE" -eq 0 && "$HAS_STUDIO" -eq 0 && "$ISSUE_ENV_FILES" -eq 1 ]]; then
    warn "No installed components detected. Nothing to fix yet."
    echo "Tip: use Install to set up Base, Studio, or All."
    return 0
  fi

  if [[ "$total" -eq 0 ]]; then
    ok "No errors detected. Nothing to fix."
    return 0
  fi

  warn "Detected $total issue group(s). Fixing only broken components..."

  if [[ "$HAS_BASE" -eq 1 && "$ISSUE_JAVA" -eq 1 ]]; then
    warn "Fixing Java"
    rm -rf "$JAVA_DIR"
    install_jdk
  fi

  if [[ "$HAS_BASE" -eq 1 && "$ISSUE_SDKMANAGER" -eq 1 ]]; then
    warn "Fixing cmdline-tools"
    rm -rf "$SDK_DIR/cmdline-tools"
    install_cmdline_tools
  fi

  if [[ "$HAS_BASE" -eq 1 && ( "$ISSUE_ADB" -eq 1 || "$ISSUE_PLATFORM" -eq 1 || "$ISSUE_BUILD_TOOLS" -eq 1 ) ]]; then
    warn "Fixing SDK packages"
    install_sdk_packages || true
  fi

  if [[ "$ISSUE_ENV_FILES" -eq 1 ]]; then
    warn "Regenerating env files"
    write_env_files
  fi

  if [[ "$HAS_STUDIO" -eq 0 ]]; then
    ok "Studio skipped (not installed by user)"
  fi

  ok "Fix completed. Running Verify..."
  verify_install
}

clear_download_cache() {
  mkdir -p "$DOWNLOAD_CACHE_DIR"
  local before after
  before="$(dir_size_human "$DOWNLOAD_CACHE_DIR")"
  rm -rf "$DOWNLOAD_CACHE_DIR"/*
  after="$(dir_size_human "$DOWNLOAD_CACHE_DIR")"
  ok "Download cache cleared: $before -> $after"
}

reinstall_all() {
  # Smart reinstall: only what user currently has.
  local has_java=0 has_sdk=0 has_studio=0
  [[ -x "$JAVA_DIR/bin/java" ]] && has_java=1
  [[ -x "$TOOLS_DIR/bin/sdkmanager" || -x "$SDK_DIR/platform-tools/adb" ]] && has_sdk=1
  [[ -x "$STUDIO_DIR/bin/studio.sh" ]] && has_studio=1

  if [[ "$has_java" -eq 0 && "$has_sdk" -eq 0 && "$has_studio" -eq 0 ]]; then
    warn "No existing components found, running full install"
    install_all
    return
  fi

  if [[ "$has_java" -eq 1 || "$has_sdk" -eq 1 ]]; then
    warn "Reinstalling Base components (JDK + SDK)"
    rm -rf "$JAVA_DIR" "$SDK_DIR"
    install_base
  fi

  if [[ "$has_studio" -eq 1 ]]; then
    warn "Reinstalling Android Studio"
    rm -rf "$STUDIO_DIR"
    install_studio
    write_env_files
  fi
}

reinstall_component_menu() {
  echo
  printf "%bReinstall component:%b\n" "$C_INFO" "$C_RESET"
  printf "  %b1) Java (JDK)%b\n" "$C_INFO" "$C_RESET"
  printf "  %b2) Android SDK (cmdline-tools + packages)%b\n" "$C_INFO" "$C_RESET"
  printf "  %b3) Android Studio%b\n" "$C_INFO" "$C_RESET"
  printf "  %b4) Env files (env.sh, env, run-studio.sh)%b\n" "$C_INFO" "$C_RESET"
  printf "  %b5) All components%b\n" "$C_INFO" "$C_RESET"
  printf "  %b0) Back%b\n" "$C_DIM" "$C_RESET"
  read -r -p "> " rchoice

  case "$rchoice" in
    1)
      rm -rf "$JAVA_DIR"
      install_jdk
      export_portable_env
      write_env_files
      ;;
    2)
      rm -rf "$SDK_DIR"
      mkdir -p "$SDK_DIR"
      install_cmdline_tools
      export_portable_env
      install_sdk_packages
      write_env_files
      ;;
    3)
      rm -rf "$STUDIO_DIR"
      install_studio
      write_env_files
      ;;
    4)
      write_env_files
      ;;
    5)
      reinstall_all
      ;;
    0)
      SKIP_PAUSE=1
      return 0
      ;;
    *)
      warn "Unknown reinstall option: $rchoice"
      ;;
  esac
}

open_studio() {
  write_env_files
  [[ -x "$ANDROID_DIR/run-studio.sh" ]] || fail "run-studio.sh missing"
  [[ -x "$STUDIO_DIR/bin/studio.sh" ]] || fail "Android Studio is not installed. Use: Install -> Studio only"
  exec "$ANDROID_DIR/run-studio.sh"
}

open_studio_safe() {
  write_env_files
  if [[ ! -x "$STUDIO_DIR/bin/studio.sh" ]]; then
    warn "Android Studio is not installed yet"
    echo "Tip: choose 5) Install -> 2) Studio only"
    return 0
  fi
  "$ANDROID_DIR/run-studio.sh"
}

run_menu_action() {
  local label="$1"
  shift
  if "$@"; then
    return 0
  fi
  warn "$label failed. You are still in menu."
  return 0
}

enter_env_shell() {
  write_env_files
  if [[ ! -f "$ANDROID_DIR/env.sh" ]]; then
    fail "env.sh not found: $ANDROID_DIR/env.sh"
  fi
  echo
  echo "Entering portable Android shell..."
  echo "Type 'exit' to return."
  echo
  bash --rcfile <(cat <<EOF
source "$ANDROID_DIR/env.sh"
PS1="(android-portable) \u@\h:\w\\$ "
EOF
)
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

install_studio_only() {
  ensure_tools
  ensure_dirs
  check_space
  install_studio
  write_env_files
}

reinstall_component_checked() {
  ensure_tools
  ensure_dirs
  check_space
  reinstall_component_menu
}

interactive_menu() {
  ensure_dirs
  write_env_files
  while true; do
    SKIP_PAUSE=0
    if [[ -t 1 ]]; then
      clear
    fi
    printf "%b╔══════════════════════════════════════════════════════════╗%b\n" "$C_INFO" "$C_RESET"
    printf "%b║              Portable Android Setup Dashboard            ║%b\n" "$C_INFO" "$C_RESET"
    printf "%b╚══════════════════════════════════════════════════════════╝%b\n" "$C_INFO" "$C_RESET"
    echo
    show_status
    echo
    hr
    show_settings_summary
    hr
    printf "%bActions:%b\n" "$C_INFO" "$C_RESET"
    printf "  %-28b %-28b %-26b %-22b %-14b\n" \
      "${C_OK}1) Enter env${C_RESET}" \
      "${C_WARN}3) Verify${C_RESET}" \
      "${C_INFO}5) Settings${C_RESET}" \
      "${C_DIM}8) Status${C_RESET}" \
      "${C_FAIL}0) Exit${C_RESET}"
    printf "  %-28b %-28b %-26b %-22b\n" \
      "${C_OK}2) Open Studio${C_RESET}" \
      "${C_WARN}4) Install${C_RESET}" \
      "${C_INFO}6) Java Settings${C_RESET}" \
      "${C_DIM}9) Versions${C_RESET}"
    read -r -p "> " choice

    case "$choice" in
      1) run_menu_action "Enter env shell" enter_env_shell ;;
      2) run_menu_action "Open Android Studio" open_studio_safe ;;
      3) run_menu_action "Verify" verify_install ;;
      4)
        echo
        printf "%bInstall mode:%b\n" "$C_INFO" "$C_RESET"
        printf "  %b1) Base%b (JDK + SDK)\n" "$C_INFO" "$C_RESET"
        printf "  %b2) Studio only%b\n" "$C_INFO" "$C_RESET"
        printf "  %b3) All%b (Base + Studio)\n" "$C_INFO" "$C_RESET"
        printf "  %b4) Reinstall component%b\n" "$C_INFO" "$C_RESET"
        printf "  %b5) Reinstall all%b (smart)\n" "$C_WARN" "$C_RESET"
        printf "  %b6) Fix only errors%b\n" "$C_INFO" "$C_RESET"
        printf "  %b0) Back%b\n" "$C_DIM" "$C_RESET"
        read -r -p "> " ichoice
        case "$ichoice" in
          1) run_menu_action "Install Base" install_base ;;
          2) run_menu_action "Install Studio" install_studio_only ;;
          3) run_menu_action "Install All" install_all ;;
          4) run_menu_action "Reinstall Component" reinstall_component_checked ;;
          5) run_menu_action "Reinstall All" reinstall_all ;;
          6) run_menu_action "Fix only errors" fix_only_errors ;;
          0) SKIP_PAUSE=1 ;;
          *) warn "Unknown install option: $ichoice" ;;
        esac
        ;;
      5) run_menu_action "Settings" settings_menu ;;
      6)
        echo
        local cached_jdks
        cached_jdks="$(get_cached_jdk_versions)"
        printf "%bJava mode:%b\n" "$C_INFO" "$C_RESET"
        printf "  %b1) temurin%b (portable)\n" "$C_INFO" "$C_RESET"
        printf "  %b2) system%b\n" "$C_INFO" "$C_RESET"
        printf "  %b3) custom URL%b (.tar.gz)\n" "$C_INFO" "$C_RESET"
        if [[ -n "$cached_jdks" ]]; then
          printf "  Cached JDK versions: %s\n" "$(printf "%s" "$cached_jdks" | tr '\n' ',' | sed 's/,$//')"
        fi
        read -r -p "> " jchoice
        case "$jchoice" in
          1)
            JAVA_MODE="temurin"
            read -r -p "JDK version (17/21) [${JDK_MAJOR}]: " jv
            JDK_MAJOR="${jv:-$JDK_MAJOR}"
            ;;
          2) JAVA_MODE="system" ;;
          3) JAVA_MODE="custom"; read -r -p "Enter JDK tar.gz URL: " ju; JAVA_CUSTOM_URL="$ju" ;;
          *) warn "Unknown Java option" ;;
        esac
        save_config
        ensure_tools
        ensure_dirs
        check_space
        install_jdk
        export_portable_env
        write_env_files
        ok "Java settings applied"
        ;;
      8) ;;
      9) run_menu_action "Check versions" show_versions ;;
      0) exit 0 ;;
      *)
        warn "Unknown menu item: $choice"
        ;;
    esac

    if [[ "$choice" != "8" && "$SKIP_PAUSE" -eq 0 ]]; then
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
  reinstall) reinstall_all ;;
  status) ensure_dirs; write_env_files; show_status ;;
  versions) ensure_dirs; write_env_files; show_versions ;;
  verify) ensure_dirs; write_env_files; verify_install ;;
  open-studio) ensure_dirs; open_studio ;;
  enter-env) ensure_dirs; enter_env_shell ;;
  clear-cache) ensure_dirs; clear_download_cache ;;
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
