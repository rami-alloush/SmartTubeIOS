#if os(macOS)
import AppKit
import AuthenticationServices

// MARK: - MacPresentationAnchor
//
// Satisfies ASWebAuthenticationPresentationContextProviding so that
// ASWebAuthenticationSession can attach its in-app browser sheet to the
// active macOS window.  Used by SignInView on macOS only.

final class MacPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding,
                                    @unchecked Sendable {

    static let shared = MacPresentationAnchor()
    private override init() { super.init() }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
    }
}
#endif
