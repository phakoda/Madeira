#!/usr/bin/env bash
# Executes production mouse arithmetic, ownership and bridge lifecycle, with
# minimal framework boundaries. NOT a full UIKit/Apple SDK test.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/madeira-mouse.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
for module in UIKit Combine GameController; do
    swiftc -warnings-as-errors -parse-as-library -emit-module -emit-object \
        -module-name "$module" -emit-module-path "$OUT/$module.swiftmodule" \
        "$ROOT/tests/apple-input-stubs/$module.swift" -o "$OUT/$module.o"
done
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import re, sys
root, out = map(Path, sys.argv[1:])
text = (root / 'app/Madeira/PhysicalControllerBridge.swift').read_text()
match = re.search(r'protocol ControllerPointerTarget: AnyObject \{.*?\n\}', text, re.S)
if not match: raise SystemExit('Pointer target protocol not found')
(out / 'PointerTarget.swift').write_text(match[0] + '\n')
ui = (root / 'app/Madeira/ContentView.swift').read_text()
methods = re.findall(r'    func moveControllerPointer\(dx: Int32, dy: Int32\) \{.*?\n    \}', ui, re.S)
if len(methods) != 1: raise SystemExit('Expected one production pointer routing method')
# Compile the actual method, not a hand-reimplemented equivalent. This catches
# errors like using an unqualified static cursor from an instance method, which
# syntax parsing the full UIKit file alone cannot diagnose.
(out / 'PointerRouting.swift').write_text('''import Foundation
final class PointerRoutingUnderTest {
    static var cursor = CGPoint.zero
    var guestSize = CGSize(width: 1024, height: 768)
''' + methods[0] + '\n}\n')
PY
swiftc -warnings-as-errors -I "$OUT" -o "$OUT/mouse-test" \
    "$OUT/UIKit.o" "$OUT/Combine.o" "$OUT/GameController.o" "$OUT/PointerTarget.swift" "$OUT/PointerRouting.swift" \
    "$ROOT/app/Madeira/GuestInputState.swift" "$ROOT/app/Madeira/PointerMotion.swift" \
    "$ROOT/app/Madeira/PhysicalMouseBridge.swift" "$ROOT/tests/swift/MouseTests.swift"
"$OUT/mouse-test"
