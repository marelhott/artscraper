import AppKit
import WebKit

/// Pinterest login v samostatném, **resizelném** NSWindow (místo ne-resizelného sheetu).
///
/// Proč NSWindow a ne SwiftUI sheet:
///   - macOS sheet nejde uživatelsky roztáhnout → login page se ořezával.
///   - Potřebujeme vlastní `WKUIDelegate.createWebViewWith` pro Google OAuth popup
///     (viz níže) — v sheetu/NSViewRepresentable to neumíme spolehlivě.
///
/// Google přihlášení:
///   Pinterest po kliknutí na „Continue with Google" zavolá `window.open(oauthURL)`.
///   Pokud popup načteme zpět do stejného WebView (vrácení `nil` z createWebViewWith),
///   zanikne `window.opener`, přes který OAuth pošle výsledek zpět → tok zamrzne.
///   Řešení: pro popup vytvoříme **nový WKWebView v novém okně** se stejným
///   `WKWebViewConfiguration` (sdílí persistentní cookie store), takže cookies
///   z Google redirectu přistanou ve sdíleném storeu a `window.opener` funguje.
@MainActor
final class PinterestLoginWindowController: NSObject {
    static let shared = PinterestLoginWindowController()

    private var loginWindow: NSWindow?
    private var loginWebView: WKWebView?
    /// Popup okna otevřená během OAuth (Google). Zavřeme je po úspěšném loginu.
    private var popupWindows: [NSWindow] = []
    private var firedSuccess = false

    /// Reálný desktop Chrome UA — Google blokuje OAuth v embedded WebView,
    /// pokud UA vypadá jako WebKit/bot. Tím projde základní kontrolou.
    private static let desktopUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    private override init() { super.init() }

    /// Zobrazí login okno (nebo přenese existující do popředí).
    func show() {
        if let window = loginWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let authStore = PinterestAuthStore.shared

        // Konfigurace WebView — persistentní store (cookies přežijí restart appky).
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = PinterestLoginWindowController.desktopUA
        webView.allowsBackForwardNavigationGestures = true
        let coordinator = LoginCoordinator(
            onDidFinish: { [weak self] url in
                self?.handleNavigationFinished(url: url, in: webView)
            },
            onCreatePopup: { [weak self] configuration, navigationAction in
                self?.createPopupWindow(configuration: configuration, navigationAction: navigationAction)
            }
        )
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        // coordinator musí přežít — držíme ho na webView přes asociaci.
        objc_setAssociatedObject(webView, &Self.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        loginWebView = webView

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Přihlášení do Pinterestu — ArtScraper"
        window.contentView = contentView
        window.minSize = NSSize(width: 440, height: 640)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        loginWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Načíst login page.
        if let url = URL(string: "https://www.pinterest.com/login/") {
            webView.load(URLRequest(url: url))
        }

        _ = authStore  // reference (lhostejné)
    }

    /// Zavře vše (login + popupy).
    func close() {
        popupWindows.forEach { $0.close() }
        popupWindows.removeAll()
        loginWindow?.close()
    }

    // MARK: - Navigace

    private func handleNavigationFinished(url: URL?, in webView: WKWebView) {
        guard let urlStr = url?.absoluteString else { return }
        let isLoginPage = urlStr.contains("/login") || urlStr.contains("/signup")
            || urlStr.contains("/business") || urlStr.contains("/account-chooser")
        let isPinterest = urlStr.contains("pinterest.com")
        // Úspěch = jsme zpět na pinterest.com mimo login-related stránky.
        if isPinterest && !isLoginPage && !firedSuccess {
            firedSuccess = true
            // Počkat, ať se session cookies uloží do WKWebsiteDataStore.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    await PinterestAuthStore.shared.onLoginSuccess()
                    self.close()
                }
            }
        }
        _ = webView
    }

    // MARK: - OAuth popup

    private func createPopupWindow(
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction
    ) -> WKWebView? {
        guard let requestURL = navigationAction.request.url else { return nil }

        // Popup WebView se STEJNOU konfigurací → sdílí persistentní cookie store.
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 700), configuration: configuration)
        popup.customUserAgent = PinterestLoginWindowController.desktopUA
        let coordinator = LoginCoordinator(
            onDidFinish: { [weak self] url in
                // Popup redirecty (Google → Pinterest) hlídáme taky — po úspěšném
                // OAuth se Pinterest vrátí s cookies ve sdíleném store.
                if let url, url.absoluteString.contains("pinterest.com") {
                    self?.handleNavigationFinished(url: url, in: popup)
                }
            },
            onCreatePopup: { [weak self] config, action in
                self?.createPopupWindow(configuration: config, navigationAction: action)
            }
        )
        popup.navigationDelegate = coordinator
        popup.uiDelegate = coordinator
        objc_setAssociatedObject(popup, &Self.coordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Pinterest — přihlášení"
        window.contentView = popup
        window.minSize = NSSize(width: 380, height: 540)
        window.center()
        window.isReleasedWhenClosed = false
        popupWindows.append(window)
        window.makeKeyAndOrderFront(nil)

        popup.load(URLRequest(url: requestURL))
        return popup
    }

    private static var coordinatorKey: UInt8 = 0
}

extension PinterestLoginWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let loginWindow, notification.object as? NSWindow === loginWindow {
            self.loginWindow = nil
            self.loginWebView = nil
            firedSuccess = false
        }
        popupWindows.removeAll { ($0) === (notification.object as? NSWindow) }
    }
}

// MARK: - Koordinátoři pro WKWebView

private final class LoginCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    let onDidFinish: (URL?) -> Void
    let onCreatePopup: (WKWebViewConfiguration, WKNavigationAction) -> WKWebView?

    init(onDidFinish: @escaping (URL?) -> Void,
         onCreatePopup: @escaping (WKWebViewConfiguration, WKNavigationAction) -> WKWebView?) {
        self.onDidFinish = onDidFinish
        self.onCreatePopup = onCreatePopup
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onDidFinish(webView.url)
    }

    // Google OAuth: `window.open()` → vytvoříme NOVÉ okno s WebView (sdílí cookies).
    // Nesmíme vracet nil a načítat do sebe — rozbilo by to window.opener a OAuth zamrzne.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        return onCreatePopup(configuration, navigationAction)
    }

    // Zavření popup okna přes window.close().
    func webViewDidClose(_ webView: WKWebView) {
        if let hostWindow = webView.window { hostWindow.close() }
    }
}
