import ApplicationServices
import AppKit
import Carbon
import Foundation

final class TextInserter {
    struct Target {
        let processID: pid_t
        let focusedElement: AXUIElement?
    }

    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApp = app
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.lastExternalApp = app
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func captureTarget() -> Target? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? lastExternalApp : frontmost
        guard let app else { return nil }
        lastExternalApp = app
        let application = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let element: AXUIElement?
        if AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &value) == .success,
           let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
            element = (value as! AXUIElement)
        } else {
            element = nil
        }
        return Target(processID: app.processIdentifier, focusedElement: element)
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func pasteFromClipboard(into target: Target?) async -> Bool {
        guard AXIsProcessTrusted() else {
            return false
        }
        guard let target,
              let app = NSRunningApplication(processIdentifier: target.processID) else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processID {
            guard app.activate(options: []) else { return false }
            for _ in 0..<10 {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else { return false }
        if let focusedElement = target.focusedElement {
            let application = AXUIElementCreateApplication(target.processID)
            var current: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &current) == .success,
               let current, CFGetTypeID(current) == AXUIElementGetTypeID(),
               !CFEqual(focusedElement, current) {
                _ = AXUIElementSetAttributeValue(focusedElement, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let keyCode = CGKeyCode(kVK_ANSI_V)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        guard let keyDown, let keyUp else { return false }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
