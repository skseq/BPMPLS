#!/bin/bash
# BPMPLS build script: single-invocation swiftc builds (no xcodebuild project).
#
#   ./build.sh            # universal BPMPLS.app (arm64 + x86_64 via lipo)
#   ./build.sh test       # compile + run unit and integration harnesses
#   ./build.sh gate       # compile + run the corpus gate (needs the corpus)
#   ./build.sh probe      # compile the per-file diagnostic probe to /tmp/probe
#   ./build.sh all        # app + test + gate
set -euo pipefail
cd "$(dirname "$0")"
trap 'rm -f /tmp/BPMPLS-arm64 /tmp/BPMPLS-x86_64' EXIT

TARGET="${1:-app}"

SDK="$(xcrun --show-sdk-path)"
APP=BPMPLS.app

FLAGS=(
  -swift-version 5
  -sdk "$SDK"
  -O
  -framework SwiftUI
  -framework AppKit
  -framework AVFoundation
  -framework Accelerate
  -framework UniformTypeIdentifiers
)

# The app entry point conflicts with the test/tool @main symbols, so harnesses
# compile against Sources minus BPMPLSApp.swift. The gate/probe only need the
# engine-core subset (no UI layer).
ALL_SOURCES=(Sources/*.swift)
TEST_SOURCES=()
for f in "${ALL_SOURCES[@]}"; do
  [[ "$(basename "$f")" == "BPMPLSApp.swift" ]] || TEST_SOURCES+=("$f")
done
CORE_SOURCES=(
  Sources/BPMEngine.swift Sources/FolderAffinity.swift
  Sources/MultiCandidateTracker.swift Sources/BeatTracker.swift
  Sources/OnsetClassification.swift Sources/MetadataService.swift
  Sources/AppServices.swift Sources/Asides.swift Sources/AsidesBuiltin.swift
  Sources/SkipList.swift
)

# Re-bake the compiled-in aside pool from Resources/asides.md when it changed.
# The .md is the source of truth; AsidesBuiltin.swift is generated from it so
# every executable ships with the current pool. When the .md is absent the
# existing baked table is kept, so builds work from a source-only checkout.
bake_asides() {
  python3 - << 'BAKE'
import base64, os
md = "Resources/asides.md"
if not os.path.exists(md):
    print("NOTE: Resources/asides.md missing — keeping existing AsidesBuiltin.swift")
    raise SystemExit(0)
items = []
for line in open(md, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    items.append(line)
blob = base64.b64encode("\n".join(items).encode("utf-8")).decode("ascii")
chunks = [blob[i:i+96] for i in range(0, len(blob), 96)]
out = ("// GENERATED FILE — do not edit by hand.\n\n"
       "import Foundation\n\n"
       "let asideTableB64 = [\n"
       + ",\n".join('    "%s"' % c for c in chunks) + "\n].joined()\n\n"
       "let asidesBuiltin: [String] = {\n"
       "    guard let data = Data(base64Encoded: asideTableB64),\n"
       "          let text = String(data: data, encoding: .utf8) else { return [] }\n"
       "    return text.split(separator: \"\\n\").map(String.init)\n"
       "}()\n")
existing = open("Sources/AsidesBuiltin.swift", encoding="utf-8").read() if os.path.exists("Sources/AsidesBuiltin.swift") else ""
if out != existing:
    open("Sources/AsidesBuiltin.swift", "w", encoding="utf-8").write(out)
    print(f"ASIDE TABLE RE-BAKED: {len(items)} lines")
else:
    print(f"aside table unchanged ({len(items)} lines)")
BAKE
}

build_app() {
  bake_asides
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  swiftc Sources/*.swift -target arm64-apple-macosx14.0  "${FLAGS[@]}" -o /tmp/BPMPLS-arm64
  swiftc Sources/*.swift -target x86_64-apple-macosx14.0 "${FLAGS[@]}" -o /tmp/BPMPLS-x86_64
  lipo -create /tmp/BPMPLS-arm64 /tmp/BPMPLS-x86_64 -output "$APP/Contents/MacOS/BPMPLS"
  cp Info.plist "$APP/Contents/Info.plist"
  if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  fi
  touch "$APP"
  echo "Built $APP (universal: $(lipo -archs "$APP/Contents/MacOS/BPMPLS"))"
}

run_tests() {
  swiftc "${TEST_SOURCES[@]}" Tests/TestHarness.swift Tests/UnitTests.swift -O -parse-as-library \
    -framework Foundation -framework AVFoundation -framework AudioToolbox -framework Accelerate \
    -o /tmp/unit_tests
  /tmp/unit_tests
  swiftc "${TEST_SOURCES[@]}" Tests/TestHarness.swift Tests/IntegrationTests.swift -O -parse-as-library \
    -framework Foundation -framework AVFoundation -framework AudioToolbox -framework Accelerate \
    -o /tmp/int_tests
  /tmp/int_tests
}

run_gate() {
  swiftc "${CORE_SOURCES[@]}" Tools/corpus_gate.swift -O -parse-as-library \
    -framework Foundation -framework AVFoundation -framework AudioToolbox -framework Accelerate \
    -o /tmp/corpus_gate
  /tmp/corpus_gate Tests/corpus_manifest.json
}

build_probe() {
  # Probe/main.swift uses top-level statements: no -parse-as-library.
  swiftc "${CORE_SOURCES[@]}" Probe/main.swift -O \
    -framework Foundation -framework AVFoundation -framework AudioToolbox -framework Accelerate \
    -o /tmp/probe
  echo "Built /tmp/probe (usage: /tmp/probe <file.mp3>)"
}

case "$TARGET" in
  app)   build_app ;;
  test)  run_tests ;;
  gate)  run_gate ;;
  probe) build_probe ;;
  all)   build_app; run_tests; run_gate ;;
  *) echo "usage: $0 [app|test|gate|probe|all]" >&2; exit 2 ;;
esac
