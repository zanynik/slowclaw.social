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
// Threading: UI presentation MUST happen on the main thread. This function
// dispatches the `present(_:animated:)` call onto `DispatchQueue.main` and
// returns immediately; it is intentionally fire-and-forget (unlike the speech
// bridge, which blocks on a semaphore). The Rust caller does not wait.
//
// Return contract (matches the Rust `extern "C"` declaration):
//   0  : the Safari view controller was presented (or queued on the main run
//        loop for presentation). The actual present is async on main.
//   -1 : failure. `outError` contains a UTF-8 NUL-terminated diagnostic
//        (when its capacity permits).
//
// Add this file to the iOS app target once via:
//   ruby scripts/ios-add-safari-opener.rb

import Foundation
import SafariServices
import UIKit

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

    DispatchQueue.main.async {
        let scenes = UIApplication.shared.connectedScenes
        let activeScene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let windowScene = activeScene as? UIWindowScene else {
            NSLog("slowclaw_open_safari_vc: no active window scene")
            return
        }
        // Prefer the key window of the active scene (iOS 13+ window-scene API).
        let window = windowScene.windows.first { $0.isKeyWindow } ?? windowScene.windows.first
        guard let root = window?.rootViewController else {
            NSLog("slowclaw_open_safari_vc: no root view controller")
            return
        }

        let presenter = topController(from: root)
        // Default configuration is fine — no custom Configuration needed.
        let safari = SFSafariViewController(url: url)
        safari.modalPresentationStyle = .pageSheet
        presenter.present(safari, animated: true)
    }

    // Return success once the presentation is queued on the main run loop. The
    // Rust side treats this as fire-and-forget; it does not block on the Safari
    // VC being presented or dismissed. (Note: failures inside the async block
    // cannot be reported back to the caller — the out-buffer is already read —
    // so they are logged via NSLog rather than written to outError.)
    return 0
}
