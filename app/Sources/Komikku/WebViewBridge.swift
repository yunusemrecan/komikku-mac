// SPDX-License-Identifier: GPL-3.0-or-later
//
// Browser work requested by the Python backend (replacement for upstream's
// WebKitGTK webview): Cloudflare / captcha challenges, JS-rendered pages.

import AppKit
import WebKit

@MainActor
final class WebViewBridge {
    private static let challengeMonitorJS = """
    (() => {
        let intervalID = setInterval(() => {
            if (document.readyState === 'loading') { return; }
            if (document.getElementById('challenge-error-title')) {
                document.title = 'error'; clearInterval(intervalID);
            } else if (document.querySelector('.main-wrapper[role="main"] .main-content') || document.querySelector('.ray-id')) {
                document.title = 'cf_captcha';
            } else if (document.querySelector('#request-info')) {
                document.title = 'ddg_captcha';
            } else if (document.querySelector('.g-recaptcha') && !document.querySelector('form .g-recaptcha')) {
                document.title = 're_captcha';
            } else if (document.querySelector('#formVerify')) {
                document.title = 'ayh2_captcha';
            } else if (document.querySelector('script[src*="challange"]')) {
                document.title = 'challange_captcha';
            } else {
                document.title = 'ready'; clearInterval(intervalID);
            }
        }, 100);
    })();
    """

    /// Only one browser task at a time, like upstream.
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    func handle(method: String, params: [String: Any]) async throws -> Any? {
        await acquire()
        defer { release() }

        switch method {
        case "webview.challenge":
            return try await challenge(params)
        case "webview.get_page_html":
            return try await pageHTML(params)
        case "webview.eval_js":
            return try await evalJS(params)
        case "webview.get_page_resources":
            return try await pageResources(params)
        default:
            throw BackendError(code: "not_supported", message: "Desteklenmeyen istek: \(method)")
        }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty {
            busy = false
        } else {
            queue.removeFirst().resume()
        }
    }

    // MARK: - Tasks

    private func challenge(_ params: [String: Any]) async throws -> Any? {
        guard let urlString = params["url"] as? String, let url = URL(string: urlString) else {
            throw BackendError(code: "bad_request", message: "Geçersiz URL")
        }
        let serverName = params["server_name"] as? String ?? url.host ?? ""
        let session = BrowserSession(userAgent: params["user_agent"] as? String)
        defer { session.close() }

        session.onCommitOrFinish = { webView in
            webView.evaluateJavaScript(Self.challengeMonitorJS, completionHandler: nil)
        }

        var captchaReloads = 0
        AppLog.write("webview: challenge start \(serverName) \(url.absoluteString)")
        session.load(URLRequest(url: url))

        let finalTitle: String = try await session.waitForTitle(timeout: 300) { title in
            AppLog.write("webview: title '\(title)'")
            if title == "error" || title == "ready" { return true }
            if title.hasSuffix("_captcha") {
                if title == "cf_captcha" { captchaReloads += 1 }
                if captchaReloads > 3 { return true }
                AppLog.write("webview: captcha needs a human, showing window")
                session.showWindow(title: "Lütfen doğrulamayı tamamlayın — \(serverName)")
            }
            return false
        }

        AppLog.write("webview: challenge finished with '\(finalTitle)'")
        if finalTitle != "ready" {
            throw BackendError(code: "challenge_failed", message: "Doğrulama tamamlanamadı (\(serverName))")
        }

        let cookies = await session.cookies(for: url)
        let userAgent = try await session.evaluate("navigator.userAgent") as? String ?? ""
        let names = cookies.compactMap { $0["name"] as? String }.joined(separator: ",")
        AppLog.write("webview: challenge ok, \(cookies.count) cookies [\(names)]")
        return ["cookies": cookies, "user_agent": userAgent]
    }

    private func pageHTML(_ params: [String: Any]) async throws -> Any? {
        guard let urlString = params["url"] as? String, let url = URL(string: urlString) else {
            throw BackendError(code: "bad_request", message: "Geçersiz URL")
        }
        let session = BrowserSession(userAgent: nil)
        defer { session.close() }

        var request = URLRequest(url: url)
        for (key, value) in params["headers"] as? [String: String] ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        session.load(request)
        try await session.waitForLoad(timeout: 60)

        if let waitJS = params["wait_js_code"] as? String {
            _ = try? await session.evaluate(waitJS)
            let title = try await session.waitForTitle(timeout: 60) { $0 == "ready" || $0 == "abort" }
            if title == "abort" {
                throw BackendError(code: "aborted", message: "Sayfa yüklenemedi: \(urlString)")
            }
        }

        guard let html = try await session.evaluate("document.documentElement.outerHTML") as? String else {
            throw BackendError(code: "no_html", message: "Sayfa içeriği alınamadı: \(urlString)")
        }

        if params["with_cookies"] as? Bool == true {
            return ["html": html, "cookies": await session.cookies(for: url)]
        }
        return ["html": html]
    }

    private func evalJS(_ params: [String: Any]) async throws -> Any? {
        let code = params["code"] as? String ?? ""
        let uri = params["uri"] as? String ?? "about:blank"
        let waitReady = params["wait_ready"] as? Bool ?? false

        let session = BrowserSession(userAgent: nil)
        defer { session.close() }
        session.load(URLRequest(url: URL(string: uri) ?? URL(string: "about:blank")!))
        try await session.waitForLoad(timeout: 60)

        if waitReady {
            let wrapped = """
            (() => {
                let count = 0;
                let intervalID = setInterval(() => {
                    if (count > 50) { document.title = 'ready'; clearInterval(intervalID); return; }
                    if (document.readyState === 'loading') { count += 1; return; }
                    window.eval_js_result = \(code);
                    document.title = 'ready';
                    clearInterval(intervalID);
                }, 100);
            })();
            """
            _ = try? await session.evaluate(wrapped)
            let title = try await session.waitForTitle(timeout: 60) { $0 == "ready" || $0 == "abort" }
            if title == "abort" { return nil }
            return try await session.evaluate("window.eval_js_result") as? String
        }
        return try await session.evaluate(code) as? String
    }

    private func pageResources(_ params: [String: Any]) async throws -> Any? {
        guard let urlString = params["url"] as? String, let url = URL(string: urlString) else {
            throw BackendError(code: "bad_request", message: "Geçersiz URL")
        }
        let paths = params["paths"] as? [String] ?? []
        let timeout = params["timeout"] as? Double ?? 20

        let session = BrowserSession(userAgent: nil)
        defer { session.close() }
        session.load(URLRequest(url: url))
        try await session.waitForLoad(timeout: timeout)

        let uris = try await session.evaluate(
            "JSON.stringify(performance.getEntriesByType('resource').map(e => e.name))"
        ) as? String ?? "[]"
        let all = (try? JSONSerialization.jsonObject(with: Data(uris.utf8))) as? [String] ?? []
        var seen = Set<String>()
        return all.filter { uri in
            paths.contains { uri.contains($0) } && seen.insert(uri).inserted
        }.map { ["uri": $0] }
    }
}

// MARK: - One WKWebView + optional window

@MainActor
private final class BrowserSession: NSObject, WKNavigationDelegate, NSWindowDelegate {
    let webView: WKWebView
    private var window: NSWindow?
    private var titleObservation: NSKeyValueObservation?
    private var titleWaiter: ((String) -> Void)?
    private var loadWaiter: ((Error?) -> Void)?
    private var loadFinished = false
    private var loadError: Error?
    private var closedByUser = false

    var onCommitOrFinish: ((WKWebView) -> Void)?

    init(userAgent: String?) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800), configuration: configuration)
        if let userAgent, !userAgent.isEmpty {
            webView.customUserAgent = userAgent
        }
        super.init()
        webView.navigationDelegate = self
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            let title = webView.title ?? ""
            Task { @MainActor in self?.titleWaiter?(title) }
        }
    }

    func load(_ request: URLRequest) {
        loadFinished = false
        loadError = nil
        webView.load(request)
    }

    func close() {
        titleObservation?.invalidate()
        titleObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func showWindow(title: String) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.title = title
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        closedByUser = true
        titleWaiter?("__closed__")
    }

    // MARK: Waiting

    func waitForLoad(timeout: Double) async throws {
        if loadFinished { return }
        if let loadError { throw loadError }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                if self.loadFinished { return }
                if let error = self.loadError { throw error }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.loadWaiter = { error in
                        self.loadWaiter = nil
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw BackendError(code: "timeout", message: "Sayfa yükleme zaman aşımı")
            }
            defer { group.cancelAll() }
            do {
                try await group.next()
            } catch {
                // Release the pending continuation so the group can finish
                self.loadWaiter?(error)
                throw error
            }
        }
    }

    /// Waits until `accept(title)` returns true; returns that title.
    func waitForTitle(timeout: Double, accept: @escaping (String) -> Bool) async throws -> String {
        let current = webView.title ?? ""
        if !current.isEmpty && accept(current) { return current }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                let now = self.webView.title ?? ""
                if !now.isEmpty && accept(now) { return now }
                return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                    self.titleWaiter = { title in
                        if title == "__closed__" {
                            self.titleWaiter = nil
                            continuation.resume(throwing: BackendError(code: "cancelled", message: "Pencere kapatıldı"))
                        } else if accept(title) {
                            self.titleWaiter = nil
                            continuation.resume(returning: title)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw BackendError(code: "timeout", message: "Zaman aşımı")
            }
            defer { group.cancelAll() }
            do {
                let title = try await group.next() ?? ""
                return title
            } catch {
                self.titleWaiter?("__closed__")
                throw error
            }
        }
    }

    func evaluate(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: SendableBox(value: result).value)
                }
            }
        }
    }

    func cookies(for url: URL) async -> [[String: Any]] {
        let host = url.host ?? ""
        let all: [HTTPCookie] = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        return all.filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }.map { cookie in
            var item: [String: Any] = [
                "name": cookie.name,
                "value": cookie.value,
                "domain": cookie.domain,
                "path": cookie.path,
                "secure": cookie.isSecure,
                "http_only": cookie.isHTTPOnly,
            ]
            if let expires = cookie.expiresDate {
                item["expires"] = Int(expires.timeIntervalSince1970)
            }
            return item
        }
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            onCommitOrFinish?(webView)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loadFinished = true
            onCommitOrFinish?(webView)
            loadWaiter?(nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { failed(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { failed(error) }
    }

    private func failed(_ error: Error) {
        // Cancelled navigations (redirects, challenge reloads) are not failures
        if (error as NSError).code == NSURLErrorCancelled { return }
        loadError = error
        loadWaiter?(error)
    }
}

private struct SendableBox: @unchecked Sendable {
    let value: Any?
}
