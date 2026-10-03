import AppKit
import SwiftUI

@main
struct DictionaryEditorTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var saved = "Supabase\n"
        let coordinator = DictionaryEditor.Coordinator(text: Binding(get: { saved }, set: { saved = $0 }))
        let editor = NSTextView()
        editor.string = saved
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.setMarkedText("やまだ", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        assert(editor.hasMarkedText())
        assert(saved == "Supabase\n", "Composition must not publish incomplete Japanese")
        editor.insertText("山田太郎", replacementRange: editor.markedRange())
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        assert(!editor.hasMarkedText())
        assert(saved == "Supabase\n山田太郎")
        let suite = "VoiceType.DictionaryTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(saved, forKey: "dictionary")
        assert(defaults.string(forKey: "dictionary") == "Supabase\n山田太郎")
        print("DictionaryEditorTests: Japanese composition and persistence passed")
    }
}
