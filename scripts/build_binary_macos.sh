#!/bin/bash
set -e

LIB_NAME="sr25519crust"
SOURCES_DIR="rust"
HEADERS_DIR="${SOURCES_DIR}/include/sr25519"
OUTPUT_DIR="binaries"
FRAMEWORK_NAME="CSr25519"
MODULE_MAP="scripts/module.modulemap"

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="${DIR}/.."

HAS_CARGO_IN_PATH=`command -v cargo >/dev/null 2>&1; echo $?`

export MACOSX_DEPLOYMENT_TARGET=10.12
export IPHONEOS_DEPLOYMENT_TARGET=11
#export TVOS_DEPLOYMENT_TARGET=11

readonly SDK_MAPPINGS=(
  'ios-:iphoneos'
  'ios-simulator:iphonesimulator'
  'tvos-:appletvos'
  'tvos-simulator:appletvsimulator'
  'watchos-:watchos'
  'watchos-simulator:watchsimulator'
  'macos-:macosx'
)

function get_sdk_name() {
  for mapping in ${SDK_MAPPINGS[@]}; do
      IFS=: read -r platform sdk <<< "$mapping"
      if [ "$platform" == "$1-$2" ]; then
        echo "$sdk"
        break
      fi
  done
}

function print_plist_header() {
  echo '<?xml version="1.0" encoding="UTF-8"?>' > $1
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> $1
  echo '<plist version="1.0">' >> $1
  echo '<dict>' >> $1
  echo -e '\t<key>AvailableLibraries</key>' >> $1
  echo -e '\t<array>' >> $1
}

function print_plist_footer() {
  echo -e '\t</array>' >> $1
  echo -e '\t<key>CFBundlePackageType</key>' >> $1
  echo -e '\t<string>XFWK</string>' >> $1
  echo -e '\t<key>XCFrameworkFormatVersion</key>' >> $1
  echo -e '\t<string>1.0</string>' >> $1
  echo '</dict>' >> $1
  echo '</plist>' >> $1
}

function platform_identifier() {
  platform=$1
  arch=${2//,/_}
  variant=$3
  
  IDENTIFIER="${platform}-${arch}"
  if [ -n "${variant}" ]; then
    IDENTIFIER="${IDENTIFIER}-${variant}"
  fi
  echo "${IDENTIFIER}"
}

function print_plist_library() {
  file=$1
  name=$2
  platform=$3
  arch=$4
  variant=$5
  IDENTIFIER=$(platform_identifier "${platform}" "$arch" "$variant")
  OIFS="$IFS"
  IFS=, archs=($arch)
  IFS="$OIFS"
  echo -e "\t<dict>" >> $file
  echo -e "\t\t<key>HeadersPath</key>" >> $file
  echo -e "\t\t<string>Headers</string>" >> $file
  echo -e "\t\t<key>LibraryIdentifier</key>" >> $file
  echo -e "\t\t<string>${IDENTIFIER}</string>" >> $file
  echo -e "\t\t<key>LibraryPath</key>" >> $file
  echo -e "\t\t<string>${name}</string>" >> $file
  echo -e "\t\t<key>SupportedArchitectures</key>" >> $file
  echo -e "\t\t<array>" >> $file
  for arch in "${archs[@]}" ; do
    echo -e "\t\t\t<string>${arch}</string>" >> $file
  done
  echo -e "\t\t</array>" >> $file
  echo -e "\t\t<key>SupportedPlatform</key>" >> $file
  echo -e "\t\t<string>${platform}</string>" >> $file
  if [ -n "${variant}" ]; then
    echo -e "\t\t<key>SupportedPlatformVariant</key>" >> $file
    echo -e "\t\t<string>${variant}</string>" >> $file
  fi
  echo -e "\t</dict>" >> $file
}

function add_library_to_xcframework() {
  fmwk_path=$1
  headers=$2
  lib_path=$3
  platform=$4
  arch=$5
  variant=$6
  IDENTIFIER=$(platform_identifier "${platform}" "$arch" "$variant")
  out="${fmwk_path}/${IDENTIFIER}"
  lib=`basename "${lib_path}"`
  mkdir -p "${out}"/Headers
  cp -rf "${headers}"/ "${out}"/Headers/
  cp -f "${lib_path}" "${out}"/
  print_plist_library "${fmwk_path}/Info.plist" "${lib}" "${platform}" "${arch}" "${variant}"
}

if [ "${HAS_CARGO_IN_PATH}" -ne 0 ]; then
    source $HOME/.cargo/env
fi

if [ "$1" == "debug" ]; then
  RELEASE=""
  CONFIGURATION="debug"
else
  RELEASE="--release"
  CONFIGURATION="release"
fi


# Removed TV OS for now. TV OS target is Tier 3 target in Rust
#
#'tvos::arm64:aarch64-apple-ios'
#'tvos:simulator:arm64,x86_64:aarch64-apple-tvos,x86_64-apple-tvos'

if [ "$2" == "no-arm64" ]; then
  readonly BUILD_TARGETS=(
    'ios::arm64:aarch64-apple-ios'
    'ios:simulator:arm64,x86_64:aarch64-apple-ios,x86_64-apple-ios'
    'macos::x86_64:x86_64-apple-darwin'
  )
else
  readonly BUILD_TARGETS=(
    'ios::arm64:aarch64-apple-ios'
    'ios:simulator:arm64,x86_64:aarch64-apple-ios,x86_64-apple-ios'
    'macos::arm64,x86_64:aarch64-apple-darwin,x86_64-apple-darwin'
  )
fi

XCFRAMEWORK_PATH="${ROOT_DIR}/${OUTPUT_DIR}/${FRAMEWORK_NAME}.xcframework"

rm -rf "${XCFRAMEWORK_PATH}"
mkdir -p "${XCFRAMEWORK_PATH}"

cd "${ROOT_DIR}/${SOURCES_DIR}"

print_plist_header "${XCFRAMEWORK_PATH}/Info.plist"

mkdir -p "${ROOT_DIR}/${HEADERS_DIR}"
cp -f "${ROOT_DIR}/${MODULE_MAP}" "${ROOT_DIR}/${HEADERS_DIR}/"

export LIBRARY_PATH="$(xcrun -sdk macosx --show-sdk-path)/usr/lib:${LIBRARY_PATH:-}"

for BTARGET in ${BUILD_TARGETS[@]}; do
  IFS=: read -r platform variant archs targets <<< "$BTARGET"
  
  SDK_NAME=$(get_sdk_name "$platform" "$variant")
  
  echo "Building for: ${SDK_NAME}..."
  
  export SDKROOT="$(xcrun -sdk "$SDK_NAME" --show-sdk-path)"
  
  RUST_TARGET_DIR="${ROOT_DIR}/${SOURCES_DIR}/target"
  OUT_LIB_DIR="${RUST_TARGET_DIR}/universal"

  cargo clean
  mkdir -p "${OUT_LIB_DIR}"
  
  BUILT_LIBS=""
  OLD_IFS="${IFS}"
  IFS=, targets=($targets)
  IFS="${OLD_IFS}"
  for target in "${targets[@]}"; do
    echo "Building target: ${target}..."
    cargo build --lib $RELEASE --target $target
    BUILT_LIBS="${BUILT_LIBS} ${RUST_TARGET_DIR}/${target}/${CONFIGURATION}/lib${LIB_NAME}.a"
  done
  
  BUILT_LIBS="${BUILT_LIBS:1}"
  
  lipo ${BUILT_LIBS} -create -output "${OUT_LIB_DIR}/lib${LIB_NAME}.a"
  
  add_library_to_xcframework "${XCFRAMEWORK_PATH}" \
    "${ROOT_DIR}/${HEADERS_DIR}/" \
    "${OUT_LIB_DIR}/lib${LIB_NAME}.a" \
    "${platform}" "${archs}" "${variant}"
done

print_plist_footer "${XCFRAMEWORK_PATH}/Info.plist"

exit 0
