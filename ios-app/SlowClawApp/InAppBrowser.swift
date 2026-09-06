// InAppBrowser.swift — in-app web viewer for every link the app opens.
//
// The Reads tab articles (RSS, Nostr long-form, YouTube) used to bounce the
// user out to Safari via UIApplication.shared.open, losing the app context on
// every tap. This file provides the funnel that replaces those calls:
// SFSafariViewController wrapped for SwiftUI and presented as a sheet from the
// app shell, so all web links open INSIDE the app. SFSafariViewController is
// the platform-proven in-app browser — it ships Safari's reader mode, shared
// cookies/credentials, and sandboxing without WKWebView delegate plumbing
// (Proven-first per AGENTS §3.9; a custom WKWebView reader would be "New").
//
// Routing: AppState.activeWebLink is the single source of truth. Any view
// calls `state.openWebLink(url)`; AppShell owns the .sheet(item:) presentation
// so the browser presents above every tab.

import SwiftUI
import SafariServices
import UIKit

/// A web destination presented in the in-app browser. Identifiable so a
/// single `.sheet(item:)` at the app-shell level can present it.
struct WebLink: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }
}

/// SwiftUI wrapper for SFSafariViewController. `dismiss` is called by the
/// wrapper when the user taps Done so SwiftUI state stays in sync.
struct InAppBrowserView: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        // Reader-mode button when the page provides a reader-friendly form —
        // long-form Nostr/RSS articles benefit from it.
        config.entersReaderIfAvailable = true
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.delegate = context.coordinator
        // #16a37f (DS._accent) — the app's accent green.
        vc.preferredControlTintColor = UIColor(red: 0.086, green: 0.639, blue: 0.498, alpha: 1)
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDismiss()
        }
    }
}

/// Sheet content for an active WebLink. Keeps the item alive for the
/// presentation lifetime and routes Done → clearing AppState.activeWebLink.
struct InAppBrowserSheet: View {
    @EnvironmentObject private var state: AppState

    func dismiss() {
        state.activeWebLink = nil
    }

    var body: some View {
        if let link = state.activeWebLink {
            InAppBrowserView(url: link.url, onDismiss: dismiss)
                .ignoresSafeArea()
        }
    }
}
