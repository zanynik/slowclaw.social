#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUDIO_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$STUDIO_TEST_ROOT"' EXIT
python3 - "$APP_ROOT" "$STUDIO_TEST_ROOT" <<'PY'
import json, pathlib, sys
app, root = map(pathlib.Path, sys.argv[1:])
paths = [app/'SlowClawApp/TimedTranscript.swift', app/'SlowClawApp/StudioRenderer.swift', app/'Tests/StudioMediaTests.swift']
host = [app/'Tests/StudioUIHost.swift'] + [app/'SlowClawApp'/name for name in ['ShareStudioView.swift', 'StudioRenderer.swift', 'TimedTranscript.swift', 'CreateIdeas.swift', 'JevIdeas.swift', 'JevMemory.swift', 'JevBatch.swift', 'JevPersona.swift']]
lines = ['name: StudioSmoke', 'options:', '  deploymentTarget:', '    iOS: "18.0"', 'targets:', '  StudioSmokeHost:', '    type: application', '    platform: iOS', '    sources:']
lines += ['      - path: '+json.dumps(str(p)) for p in host]
lines += ['    settings:', '      base:', '        GENERATE_INFOPLIST_FILE: YES', '        PRODUCT_BUNDLE_IDENTIFIER: com.slowclaw.studio-smoke-host', '        INFOPLIST_KEY_UILaunchScreen_Generation: YES', '        TARGETED_DEVICE_FAMILY: \"1,2\"', '        SWIFT_VERSION: "5.9"', '        CODE_SIGNING_ALLOWED: NO', '  StudioSmoke:', '    type: bundle.unit-test', '    platform: iOS', '    sources:']
lines += ['      - path: '+json.dumps(str(p)) for p in paths]
lines += ['    dependencies:', '      - target: StudioSmokeHost', '    settings:', '      base:', '        TEST_HOST: $(BUILT_PRODUCTS_DIR)/StudioSmokeHost.app/StudioSmokeHost', '        BUNDLE_LOADER: $(TEST_HOST)', '        GENERATE_INFOPLIST_FILE: YES', '        PRODUCT_BUNDLE_IDENTIFIER: com.slowclaw.studio-smoke', '        SWIFT_VERSION: "5.9"', '        CODE_SIGNING_ALLOWED: NO', '  StudioUI:', '    type: bundle.ui-testing', '    platform: iOS', '    sources:', '      - path: '+json.dumps(str(app/'Tests/StudioUITests.swift')), '    dependencies:', '      - target: StudioSmokeHost', '    settings:', '      base:', '        GENERATE_INFOPLIST_FILE: YES', '        PRODUCT_BUNDLE_IDENTIFIER: com.slowclaw.studio-ui-tests', '        TEST_TARGET_NAME: StudioSmokeHost', '        SWIFT_VERSION: "5.9"', '        CODE_SIGNING_ALLOWED: NO', 'schemes:', '  StudioSmoke:', '    build:', '      targets:', '        StudioSmoke: [test]', '        StudioUI: [test]', '    test:', '      targets: [StudioSmoke, StudioUI]']
(root/'project.yml').write_text('\n'.join(lines)+'\n')
PY
xcodegen generate --spec "$STUDIO_TEST_ROOT/project.yml"
STUDIO_DEVICE="$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["udid"] for key,values in d["devices"].items() if "iOS" in key for x in values if "iPhone" in x["name"]))')"
mkdir -p /tmp/slowclaw-studio-evidence
set +e
xcodebuild test -project "$STUDIO_TEST_ROOT/StudioSmoke.xcodeproj" -scheme StudioSmoke -destination "platform=iOS Simulator,id=$STUDIO_DEVICE" -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 -resultBundlePath /tmp/slowclaw-studio-evidence/results.xcresult -test-timeouts-enabled YES -default-test-execution-time-allowance 120
STUDIO_RESULT=$?
set -e
xcrun xcresulttool get test-results summary --path /tmp/slowclaw-studio-evidence/results.xcresult || true
xcrun xcresulttool export attachments --path /tmp/slowclaw-studio-evidence/results.xcresult --output-path /tmp/slowclaw-studio-evidence/attachments || true
python3 - "$STUDIO_DEVICE" <<'PY'
import os, pathlib, shutil, sys
root=pathlib.Path(os.environ['HOME'])/'Library/Developer/CoreSimulator/Devices'/sys.argv[1]/'data'
for p in root.rglob('StudioSmoke/*'):
    if p.is_file() and p.suffix in {'.png','.mp4'}:
        shutil.copy2(p,pathlib.Path('/tmp/slowclaw-studio-evidence')/p.name)
PY

exit "$STUDIO_RESULT"
