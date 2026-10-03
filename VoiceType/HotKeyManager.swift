import AppKit
import CoreGraphics
import Foundation

enum RecordingShortcut: String, CaseIterable, Identifiable {
    case capsLock
    case fn
    case leftShift
    case rightShift

    var id: String { rawValue }

    var label: String {
        switch self {
        case .capsLock: return "Caps Lock"
        case .fn: return "fn（地球儀）"
        case .leftShift: return "左 Shift"
        case .rightShift: return "右 Shift"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .capsLock: return 57
        case .fn: return 63
        case .leftShift: return 56
        case .rightShift: return 60
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .capsLock: return .maskAlphaShift
        case .fn: return .maskSecondaryFn
        case .leftShift, .rightShift: return .maskShift
        }
    }
}

// Modifier shortcuts trigger once on release, only if used on their own.
struct ShortcutGesture {
    let shortcut: RecordingShortcut
    private var isPressed = false
    private var isEligible = false

    init(shortcut: RecordingShortcut) {
        self.shortcut = shortcut
    }

    mutating func reset() {
        isPressed = false
        isEligible = false
    }

    mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard type == .flagsChanged, keyCode == shortcut.keyCode else {
            if isPressed { isEligible = false }
            return false
        }

        if shortcut == .capsLock { return true }

        if isPressed {
            let shouldTrigger = isEligible
            reset()
            return shouldTrigger
        }

        guard flags.contains(shortcut.flag) else { return false }
        isPressed = true
        let modifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        isEligible = flags.intersection(modifiers).subtracting(shortcut.flag).isEmpty
        // The aggregate Shift flag cannot distinguish the other Shift key.
        if shortcut == .leftShift || shortcut == .rightShift {
            let otherShift: CGKeyCode = shortcut == .leftShift ? 60 : 56
            if CGEventSource.keyState(.combinedSessionState, key: otherShift) {
                isEligible = false
            }
        }
        return false
    }
}

final class HotKeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventRunLoop: CFRunLoop?
    private var callbackContextPointer: UnsafeMutableRawPointer?
    private var eventTapThread: Thread?
    private let handler: () -> Void
    private let gestureLock = NSLock()
    private var gesture: ShortcutGesture

    init(shortcut: RecordingShortcut, handler: @escaping () -> Void) {
        gesture = ShortcutGesture(shortcut: shortcut)
        self.handler = handler
        install()
    }

    func setShortcut(_ shortcut: RecordingShortcut) {
        gestureLock.lock()
        defer { gestureLock.unlock() }
        gesture = ShortcutGesture(shortcut: shortcut)
    }

    var isAvailable: Bool { eventTap != nil }

    func retryInstall() {
        guard eventTap == nil else { return }
        install()
    }

    deinit {
        guard let eventRunLoop else { return }
        let eventTap = self.eventTap
        let runLoopSource = self.runLoopSource
        let callbackContextPointer = self.callbackContextPointer

        // Tear down on the tap's own run loop so its callback context remains
        // alive until no callback can still be using it.
        CFRunLoopPerformBlock(eventRunLoop, CFRunLoopMode.commonModes!.rawValue as CFTypeRef) {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
            }
            if let runLoopSource {
                CFRunLoopRemoveSource(eventRunLoop, runLoopSource, .commonModes)
            }
            if let callbackContextPointer {
                Unmanaged<HotKeyEventTapContext>
                    .fromOpaque(callbackContextPointer)
                    .release()
            }
            CFRunLoopStop(eventRunLoop)
        }
        CFRunLoopWakeUp(eventRunLoop)
    }

    private func install() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            let installed = self?.installOnCurrentRunLoop() ?? false
            ready.signal()
            if installed { CFRunLoopRun() }
        }
        thread.name = "VoiceType.HotKeyEventTap"
        eventTapThread = thread
        thread.start()
        ready.wait()
    }

    private func installOnCurrentRunLoop() -> Bool {
        let eventRunLoop = CFRunLoopGetCurrent()

        let eventMask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)
        )

        let contextPointer = Unmanaged.passRetained(HotKeyEventTapContext(manager: self)).toOpaque()
        let callback: CGEventTapCallBack = {
            _, type, event, userInfo in

            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let context = Unmanaged<HotKeyEventTapContext>
                .fromOpaque(userInfo)
                .takeUnretainedValue()
            guard let manager = context.manager else {
                return Unmanaged.passUnretained(event)
            }

            // macOSによってEvent Tapが無効化された場合は復帰
            if type == .tapDisabledByTimeout ||
                type == .tapDisabledByUserInput {

                manager.resetGesture()
                if let eventTap = manager.eventTap {
                    CGEvent.tapEnable(
                        tap: eventTap,
                        enable: true
                    )
                }

                return Unmanaged.passUnretained(event)
            }

            // Preserve IME switching and modifier editing inside VoiceType windows.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                manager.resetGesture()
                return Unmanaged.passUnretained(event)
            }

            let keyCode = event.getIntegerValueField(
                .keyboardEventKeycode
            )

            let result = manager.handle(type: type, keyCode: keyCode, flags: event.flags)
            if result.shouldTrigger {
                DispatchQueue.main.async {
                    manager.handler()
                }
            }

            // Shift/fn events must reach applications for normal key combinations.
            if result.shortcut == .capsLock,
               type == .flagsChanged, keyCode == RecordingShortcut.capsLock.keyCode {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: contextPointer
        ) else {
            Unmanaged<HotKeyEventTapContext>.fromOpaque(contextPointer).release()
            print("ショートカット Event Tapの作成に失敗しました")
            return false
        }

        callbackContextPointer = contextPointer
        self.eventTap = eventTap
        self.eventRunLoop = eventRunLoop

        let runLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            eventTap,
            0
        )

        self.runLoopSource = runLoopSource

        CFRunLoopAddSource(
            eventRunLoop,
            runLoopSource,
            .commonModes
        )

        CGEvent.tapEnable(
            tap: eventTap,
            enable: true
        )
        return true
    }

    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> (shouldTrigger: Bool, shortcut: RecordingShortcut) {
        gestureLock.lock()
        defer { gestureLock.unlock() }
        let shouldTrigger = gesture.handle(type: type, keyCode: keyCode, flags: flags)
        return (shouldTrigger, gesture.shortcut)
    }

    private func resetGesture() {
        gestureLock.lock()
        defer { gestureLock.unlock() }
        gesture.reset()
    }
}

private final class HotKeyEventTapContext {
    weak var manager: HotKeyManager?

    init(manager: HotKeyManager) {
        self.manager = manager
    }
}
