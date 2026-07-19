// SafariOpener.swift — in-app article reader bridge for the SlowClaw iOS app.
//
// Exposes a C-callable function (`slowclaw_open_safari_vc`) that the Rust
// core in `web/src-tauri/src/ios_safari.rs` calls via the C ABI. The
// implementation presents Apple's `SFSafariViewController` over the app's
// topmost view controller, so article links open inside the app with a native
// Done button + swipe-to-dismiss — the user is never trapped in the article.
//
// Why this exists: Tauri 2 mobile is restricted to a single webview/window,
// so the desktop-style second `WebviewWindow` reader cannot be closed on iOS
// (no native back affordance). `SFSafariViewController` is the idiomatic iOS
// primitive for in-app web browsing and gives us the dismiss control for free.
//
// BLOCKING UNTIL DISMISSAL (dwell measurement): the function presents the
// Safari VC on the main thread and then BLOCKS the calling thread on a
// DispatchSemaphore that is signalled from
// `SFSafariViewControllerDelegate.safariViewController(_:didFinish:)` — i.e.
// when the user taps Done or swipes the sheet away. The caller (Rust
// `open_in_app_webview`, itself run in `spawn_blocking`) therefore returns
// AFTER the user finishes reading, so the TS layer can measure true dwell with
// a before/after timestamp around the `await invoke(...)`. This mirrors the
// `transcription.rs` ↔ `SpeechTranscriber.swift` bridge pattern.
//
// Safety cap: a 30-minute timeout (MAX_WAIT_SECONDS) ensures a forgotten-open
// or a delegate that never fires (e.g. app force-quit recovery) can never wedge
// the command thread indefinitely. On timeout the function still returns 0
// (presentation succeeded) — the TS layer just sees a very long dwell, which
// the 30s engagement threshold and the cap-on-keyword-passes already bound.
//
// Threading: UI presentation MUST happen on the main thread. The main-thread
// dispatch presents the VC and wires the delegate; the calling (blocking)
// thread then waits on the semaphore. The delegate callback runs on main and
// signals the semaphore, unblocking the caller.
//
// Return contract (matches the Rust `extern "C"` declaration):
//   0  : the Safari view controller was presented (or queued on the main run
//        loop for presentation) AND has been dismissed (or the wait timed out).
//   -1 : failure before presentation. `outError` contains a UTF-8 NUL-
//        terminated diagnostic (when its capacity permits). Failures inside
//        the async main-thread block cannot be reported back (the out-buffer
//        is already read by then) and are logged via NSLog instead.
//
// Add this file to the iOS app target once via:
//   ruby scripts/ios-add-safari-opener.rb

import Foundation
import SafariServices
import UIKit

/// Upper bound on how long the bridge will block waiting for the user to
/// dismiss the Safari sheet. Generous for "read an article" but finite so a
/// lost delegate callback can never wedge the command thread forever.
private let MAX_WAIT_SECONDS: Int = 30 * 60

/// Retains the Safari VC + delegate for the lifetime of a single open session.
/// Kept as a strong ref on the bridge so neither is released while presented
/// (SFSafariViewController only holds a weak ref to its delegate).
private final class SafariSession {
    fileprivate let dismissSemaphore = DispatchSemaphore(value: 0)
    private weak var safari: SFSafariViewController?

    func attach(_ vc: SFSafariViewController) {
        safari = vc
        vc.delegate = SafariDismissDelegate { [weak self] in
            self?.dismissSemaphore.signal()
        }
    }
}

/// Single-purpose delegate whose only job is to signal the session semaphore
/// when the Safari VC is dismissed. `NSObject` base required by the protocol.
private final class SafariDismissDelegate: NSObject, SFSafariViewControllerDelegate {
    private let onDismiss: () -> Void
    init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

    func safariViewController(_: SFSafariViewController, didFinish _: SFSafariViewController.DismissButtonStyle) {
        // Runs on main when the user taps Done or swipes to dismiss. The
        // session is released once the presenter releases the VC.
        onDismiss()
    }

    // Keep the delegate alive for the full presentation; not all iOS versions
    // call didFinish on every dismiss path, but it is the documented signal.
    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        onDismiss()
    }
}

@_cdecl("slowclaw_open_safari_vc")
public func slowclaw_open_safari_vc(
    _ urlCStr: UnsafePointer<CChar>,
    _ outError: UnsafeMutablePointer<CChar>,
    _ outErrorLen: Int32
) -> Int32 {
    func writeError(_ message: String) {
        guard outErrorLen > 0 else { return }
        let nulTerminated = message + "\0"
        let bytes = Array(nulTerminated.utf8)
        let capacity = Int(outErrorLen)
        let copyCount = min(bytes.count, capacity)
        for i in 0..<copyCount {
            outError[i] = CChar(bitPattern: bytes[i])
        }
        if copyCount < capacity {
            outError[copyCount] = 0
        } else {
            outError[capacity - 1] = 0
        }
    }

    // Recover the URL string from the C string.
    let urlString = String(cString: urlCStr)
    guard let url = URL(string: urlString) else {
        writeError("invalid url")
        return -1
    }
    // Only http(s) is accepted (same guard as the Rust-side opener).
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
        writeError("only http(s) urls can be opened")
        return -1
    }

    // Resolve the topmost view controller to present from. We must be on the
    // main thread to touch UIKit state, so the whole lookup + present happens
    // inside the main-thread dispatch below.
    func topController(from controller: UIViewController) -> UIViewController {
        // Walk presented VCs and navigation/tab containers to find the one
        // that is actually on screen.
        if let presented = controller.presentedViewController {
            return topController(from: presented)
        }
        if let nav = controller as? UINavigationController, let last = nav.visibleViewController {
            return topController(from: last)
        }
        if let tab = controller as? UITabBarController, let selected = tab.selectedViewController {
            return topController(from: selected)
        }
        return controller
    }

    let session = SafariSession()

    DispatchQueue.main.async {
        let scenes = UIApplication.shared.connectedScenes
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let windowScene = activeScene as? UIWindowScene else {
            NSLog("slowclaw_open_safari_vc: no active window scene")
            // No presenter available — signal so the blocking caller doesn't
            // hang; the presentation just didn't happen.
            session.dismissSemaphore.signal()
            return
        }
        // Prefer the key window of the active scene (iOS 13+ window-scene API).
        let window = windowScene.windows.first { $0.isKeyWindow } ?? windowScene.windows.first
        guard let root = window?.rootViewController else {
            NSLog("slowclaw_open_safari_vc: no root view controller")
            session.dismissSemaphore.signal()
            return
        }

        let presenter = topController(from: root)
        let safari = SFSafariViewController(url: url)
        safari.modalPresentationStyle = .pageSheet
        session.attach(safari)
        presenter.present(safari, animated: true)
    }

    // BLOCK until the user dismisses the Safari sheet (delegate callback) or
    // the safety timeout fires. The caller runs this in spawn_blocking, so
    // holding this thread does not stall the async runtime. The main thread
    // stays free to run the present + the delegate callback.
    _ = session.dismissSemaphore.wait(timeout: .now() + .seconds(MAX_WAIT_SECONDS))

    // Return success once presentation+dismissal completes (or times out). The
    // TS layer measures dwell from before invoke() to this return.
    return 0
}
