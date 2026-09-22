import SwiftUI
import UIKit

/// Same trailing control on transcripts, ideas and drafts. No modal alert.
struct CopyTextButton: View {
    let text: String
    @State private var copied = false
    @State private var reset: Task<Void, Never>?
    var body: some View {
        Button {
            UIPasteboard.general.string = text
            reset?.cancel()
            copied = true
            UIAccessibility.post(notification: .announcement, argument: "Copied")
            reset = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                if copied { Text("Copied").font(.caption) }
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }.frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(copied ? "Copied" : "Copy text")
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .onDisappear { reset?.cancel(); copied = false }
    }
}
