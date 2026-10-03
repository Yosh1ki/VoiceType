import AppKit
import SwiftUI

// Keep the IME's marked text inside NSTextView until the user commits it.
struct DictionaryEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let editor = scroll.documentView as? NSTextView else { return scroll }
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 14)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.setAccessibilityLabel("ユーザー辞書。日本語と英語に対応")
        editor.string = text
        editor.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? NSTextView,
              !editor.hasMarkedText(), editor.string != text else { return }
        editor.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            text.wrappedValue = editor.string
        }

        func textDidEndEditing(_ notification: Notification) {
            textDidChange(notification)
        }
    }
}
