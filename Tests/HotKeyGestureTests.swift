import CoreGraphics

// Run with swiftc VoiceType/HotKeyManager.swift Tests/HotKeyGestureTests.swift -o /tmp/voicetype-hotkey-tests
@main
struct HotKeyGestureTests {
    static func main() {
        for shortcut in [RecordingShortcut.fn, .leftShift, .rightShift] {
            var gesture = ShortcutGesture(shortcut: shortcut)
            for _ in 0..<2 {
                assert(!gesture.handle(type: .flagsChanged, keyCode: shortcut.keyCode, flags: shortcut.flag))
                assert(gesture.handle(type: .flagsChanged, keyCode: shortcut.keyCode, flags: []))
                assert(!gesture.handle(type: .flagsChanged, keyCode: shortcut.keyCode, flags: []))
            }

            // Typing with a modifier must not toggle recording on release.
            assert(!gesture.handle(type: .flagsChanged, keyCode: shortcut.keyCode, flags: shortcut.flag))
            assert(!gesture.handle(type: .keyDown, keyCode: 0, flags: shortcut.flag))
            assert(!gesture.handle(type: .flagsChanged, keyCode: shortcut.keyCode, flags: []))

            // A modifier already held, or pressed during the gesture, cancels it.
            assert(!gesture.handle(type: .flagsChanged, keyCode: shortcut.keyCode, flags: [shortcut.flag, .maskCommand]))
            assert(!gesture.handle(type: .flagsChanged, keyCode: shortcut.keyCode, flags: .maskCommand))
            assert(!gesture.handle(type: .flagsChanged, keyCode: shortcut.keyCode, flags: shortcut.flag))
            assert(!gesture.handle(type: .flagsChanged, keyCode: 59, flags: [shortcut.flag, .maskControl]))
            assert(!gesture.handle(type: .flagsChanged, keyCode: shortcut.keyCode, flags: .maskControl))

            // Event tap recovery discards an incomplete gesture.
            assert(!gesture.handle(type: .flagsChanged, keyCode: shortcut.keyCode, flags: shortcut.flag))
            gesture.reset()
            assert(!gesture.handle(type: .flagsChanged, keyCode: shortcut.keyCode, flags: []))
        }

        var left = ShortcutGesture(shortcut: .leftShift)
        assert(!left.handle(type: .flagsChanged, keyCode: 60, flags: .maskShift))
        assert(!left.handle(type: .flagsChanged, keyCode: 56, flags: .maskShift))
        assert(!left.handle(type: .flagsChanged, keyCode: 60, flags: .maskShift))
        assert(!left.handle(type: .flagsChanged, keyCode: 56, flags: []))

        var caps = ShortcutGesture(shortcut: .capsLock)
        assert(caps.handle(type: .flagsChanged, keyCode: 57, flags: .maskAlphaShift))
        assert(caps.handle(type: .flagsChanged, keyCode: 57, flags: []))
        assert(!caps.handle(type: .flagsChanged, keyCode: 63, flags: .maskSecondaryFn))

        // Switching the shortcut while held must not treat its release as a tap.
        var switched = ShortcutGesture(shortcut: .fn)
        assert(!switched.handle(type: .flagsChanged, keyCode: 63, flags: []))
        print("HotKeyGestureTests: all checks passed")
    }
}
