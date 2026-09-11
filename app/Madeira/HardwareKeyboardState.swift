import Foundation

/// USB keyboard usages -> guest US-layout VK codes. Shift/Ctrl/Alt sides share
/// the legacy bridge's generic VK but keep separate owners; releasing one side
/// cannot release the other. Unsupported usages are left for UIKit to handle.
enum HIDKeyMap {
    static func virtualKey(for usage: Int) -> Int32? {
        switch usage {
        case 0x04...0x1D: return Int32(0x41 + usage - 0x04)
        case 0x1E...0x26: return Int32(0x31 + usage - 0x1E)
        case 0x27: return 0x30
        case 0x3A...0x45: return Int32(0x70 + usage - 0x3A)
        case 0x68...0x73: return Int32(0x7C + usage - 0x68)
        case 0x59...0x61: return Int32(0x61 + usage - 0x59)
        default: return special[usage]
        }
    }
    static func isRepeatable(_ usage: Int) -> Bool {
        virtualKey(for: usage) != nil && !(0xE0...0xE7).contains(usage)
            && ![0x39, 0x47, 0x53].contains(usage)
    }
    private static let special: [Int: Int32] = [
        0x28: 0x0D, 0x29: 0x1B, 0x2A: 0x08, 0x2B: 0x09, 0x2C: 0x20,
        0x2D: 0xBD, 0x2E: 0xBB, 0x2F: 0xDB, 0x30: 0xDD, 0x31: 0xDC,
        0x33: 0xBA, 0x34: 0xDE, 0x35: 0xC0, 0x36: 0xBC, 0x37: 0xBE, 0x38: 0xBF,
        0x39: 0x14, 0x46: 0x2C, 0x47: 0x91, 0x48: 0x13, 0x49: 0x2D,
        0x4A: 0x24, 0x4B: 0x21, 0x4C: 0x2E, 0x4D: 0x23, 0x4E: 0x22,
        0x4F: 0x27, 0x50: 0x25, 0x51: 0x28, 0x52: 0x26, 0x53: 0x90,
        0x54: 0x6F, 0x55: 0x6A, 0x56: 0x6D, 0x57: 0x6B, 0x58: 0x0D,
        0x62: 0x60, 0x63: 0x6E, 0x64: 0xE2, 0x65: 0x5D, 0x75: 0x2F,
        0xE0: 0x11, 0xE1: 0x10, 0xE2: 0x12, 0xE3: 0x5B,
        0xE4: 0x11, 0xE5: 0x10, 0xE6: 0x12, 0xE7: 0x5C,
    ]
}

final class HardwareKeyboardState {
    private let input: GuestInputState
    private var sources: [Int: UUID] = [:]
    var heldKeyCount: Int { sources.count }
    init(input: GuestInputState) { self.input = input }
    @discardableResult func press(usage: Int) -> Bool {
        guard let vk = HIDKeyMap.virtualKey(for: usage) else { return false }
        if let source = sources[usage] {
            if HIDKeyMap.isRepeatable(usage) { input.repeatKey(vk, source: source) }
        } else {
            let source = UUID()
            sources[usage] = source
            input.set(.key(vk), down: true, source: source)
        }
        return true
    }
    @discardableResult func release(usage: Int) -> Bool {
        guard HIDKeyMap.virtualKey(for: usage) != nil else { return false }
        if let source = sources.removeValue(forKey: usage) { input.release(source: source) }
        return true
    }
    func releaseAll() {
        for source in sources.values { input.release(source: source) }
        sources.removeAll(keepingCapacity: true)
    }
}
