import AppKit
import CswitchCore
import WebKit

/// The model owns this window independently of the transient menu bar popover.
/// Every login gets a fresh in-memory browser session; Safari is never automated.
@MainActor
final class SignInWindow: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private var browser: WKWebView?
    private let address = NSTextField(labelWithString: "claude.ai")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private var children: [SignInWindow] = []
    private var finished = false
    private var onCancel: (() -> Void)?
    private let onCallback: (URL) throws -> Void
    private let signInURL: URL

    init(url: URL, configuration: WKWebViewConfiguration? = nil, onCancel: @escaping () -> Void,
         onCallback: @escaping (URL) throws -> Void) {
        signInURL = url
        self.onCancel = onCancel
        self.onCallback = onCallback
        let configuration = configuration ?? {
            let value = WKWebViewConfiguration()
            value.websiteDataStore = .nonPersistent()
            return value
        }()
        let browser = WKWebView(frame: .zero, configuration: configuration)
        self.browser = browser
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Cswitch · Sign in to Claude"
        window.minSize = NSSize(width: 440, height: 520)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        browser.navigationDelegate = self
        browser.uiDelegate = self
        browser.allowsBackForwardNavigationGestures = true
        browser.allowsLinkPreview = false

        address.font = .systemFont(ofSize: 12)
        address.lineBreakMode = .byTruncatingMiddle
        address.isSelectable = true
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let back = NSButton(title: "Back", target: self, action: #selector(goBack))
        let reload = NSButton(title: "Reload", target: self, action: #selector(reloadPage))
        let header = NSStackView(views: [back, address, progress, reload])
        header.spacing = 10
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.stringValue = "Private sign-in"
        let copy = NSButton(title: "Copy sign-in link", target: self, action: #selector(copyLink))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelLogin))
        cancel.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [status, copy, cancel])
        footer.spacing = 10
        let content = NSView()
        window.contentView = content
        for view in [header, browser, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            browser.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            browser.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            address.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16)
        ])
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open() throws {
        guard signInURL.scheme == "https", signInURL.host == "claude.ai", signInURL.path == "/oauth/authorize" else {
            throw CswitchError.message("Invalid sign-in link.")
        }
        present()
        browser?.load(URLRequest(url: signInURL))
    }

    func present() {
        guard !finished else { return }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Programmatic closure does not turn a successful callback into cancellation.
    func finish() {
        guard !finished else { return }
        finished = true
        onCancel = nil
        for child in children { child.finish() }
        children.removeAll()
        browser?.stopLoading()
        browser?.navigationDelegate = nil
        browser?.uiDelegate = nil
        browser?.removeFromSuperview()
        browser = nil
        window?.delegate = nil
        close()
    }

    func windowWillClose(_ notification: Notification) {
        let cancel = onCancel
        finish()
        cancel?()
    }

    @objc private func goBack() { browser?.goBack() }
    @objc private func reloadPage() { browser?.reload() }
    @objc private func cancelLogin() { window?.performClose(nil) }
    @objc private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(signInURL.absoluteString, forType: .string)
        status.stringValue = "Sign-in link copied"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if ["localhost", "127.0.0.1"].contains(url.host ?? "") {
            decisionHandler(.cancel)
            do { try onCallback(url); status.stringValue = "Saving your account…" }
            catch { showFailure(error.localizedDescription) }
            return
        }
        // Google explicitly rejects embedded OAuth browsers. Do not disguise the
        // web view or silently launch a browser when the user chooses Google.
        if url.host == "accounts.google.com" {
            decisionHandler(.cancel)
            showFailure("Google requires a browser for sign-in. Use Claude’s email sign-in here, or copy the sign-in link into a private browser window.")
            return
        }
        guard url.scheme == "https" || url.absoluteString == "about:blank" else {
            decisionHandler(.cancel)
            showFailure("This link cannot open in the sign-in window.")
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true {
            address.stringValue = url.host.map { "https://" + $0 } ?? "Private sign-in"
            status.textColor = .secondaryLabelColor
            status.stringValue = "Private sign-in"
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progress.startAnimation(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.stopAnimation(nil)
        if let host = webView.url?.host { address.stringValue = "https://" + host }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showFailure("The sign-in page stopped. Click Reload to try again.")
    }

    private func navigationFailed(_ error: Error) {
        progress.stopAnimation(nil)
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        // Do not display error userInfo, which can contain callback codes/URLs.
        showFailure("The sign-in page could not load. Check your connection and click Reload.")
    }

    private func showFailure(_ message: String) {
        progress.stopAnimation(nil)
        status.textColor = .systemRed
        status.stringValue = message
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // SSO popups share only this login's temporary cookies and keep their
        // window.opener relationship. They never escape into Safari.
        children.removeAll { $0.finished }
        guard navigationAction.targetFrame == nil, children.count < 4 else { return nil }
        let child = SignInWindow(url: signInURL, configuration: configuration, onCancel: {}, onCallback: onCallback)
        children.append(child)
        child.present()
        return child.browser
    }

    func webViewDidClose(_ webView: WKWebView) { finish() }
}
