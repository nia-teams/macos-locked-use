import CoreGraphics
import Foundation

// All delays are bounded constants, never environment-controlled policy.
enum LockedUseInputTiming {
    static let focusRecordSettle: TimeInterval = 0.01
    static let skyClickDelayScale: Double = 1
    static let typeChunkDelay: TimeInterval = 0.005
    static let pressKeySettle: TimeInterval = 0.01
}

enum LockedUseKeyboardEvents {
    static let maxKeyboardUnicodeChunkLength = 20
    static func typeText(_ text: String, pid: pid_t) throws {
        for chunk in keyboardUnicodeChunks(for: text) {
            try requireUsableComputerUseSession()
            var mutableChunk = chunk
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw LockedUseError.message("Failed to create keyboard event.")
            }

            mutableChunk.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return
                }

                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: baseAddress)
            }
            try LockedUseActionScope.validate()
            down.postToPid(pid)
            try LockedUseActionScope.validate()
            up.postToPid(pid)
            if LockedUseInputTiming.typeChunkDelay > 0 {
                Thread.sleep(forTimeInterval: LockedUseInputTiming.typeChunkDelay)
            }
        }
    }

    static func keyboardUnicodeChunks(for text: String, maxUTF16Units: Int = maxKeyboardUnicodeChunkLength) -> [[UniChar]] {
        precondition(maxUTF16Units > 0, "maxUTF16Units must be positive")

        var chunks: [[UniChar]] = []
        var current: [UniChar] = []

        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maxUTF16Units {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }

            current.append(contentsOf: units)
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    static func pressKey(_ specification: String, pid: pid_t) throws {
        try requireUsableComputerUseSession()
        let parsed = try LockedUseKeyPressParser.parse(specification)
        var activeFlags: CGEventFlags = []

        for modifier in parsed.modifiers {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: modifier.keyCode, keyDown: true) else {
                throw LockedUseError.message("Failed to create modifier key down event.")
            }

            activeFlags.insert(modifier.flag)
            event.flags = activeFlags
            try LockedUseActionScope.validate()
            event.postToPid(pid)
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: false) else {
            throw LockedUseError.message("Failed to create key event.")
        }

        keyDown.flags = activeFlags
        keyUp.flags = activeFlags
        try LockedUseActionScope.validate()
        keyDown.postToPid(pid)
        try LockedUseActionScope.validate()
        keyUp.postToPid(pid)

        for modifier in parsed.modifiers.reversed() {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: modifier.keyCode, keyDown: false) else {
                throw LockedUseError.message("Failed to create modifier key up event.")
            }

            event.flags = activeFlags
            try LockedUseActionScope.validate()
            event.postToPid(pid)
            activeFlags.remove(modifier.flag)
        }

        if LockedUseInputTiming.pressKeySettle > 0 {
            Thread.sleep(forTimeInterval: LockedUseInputTiming.pressKeySettle)
        }
    }

}
