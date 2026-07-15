import Foundation
import WebKit
import Observation

/// Správa Pinterest session — login přes WKWebView, persistentní cookies.
///
/// Port z eagle clonu (PixelFinder). Architektura (z reverzního inženýrství Eagle pluginu):
///   1. WKWebView načte pinterest.com → uživatel se přihlásí ručně.
///      (Používá DESKTOP UA viz PinterestLoginView — Google OAuth funguje jen s desktop login page.)
///   2. Cookies se persistují přes `WKWebsiteDataStore.default()` — přežijí restart appky.
///   3. Ty samé cookies pak používá `PinterestVisualClient` přes `URLSession` pro API call.
///
/// Jednorázový login → appka si vás pamatuje dokud session neexpirovala
/// (Pinterest session je dlouhá, typicky měsíce).
@MainActor @Observable
final class PinterestAuthStore {
    static let shared = PinterestAuthStore()

    /// iPhone User-Agent — shodný s Eagle Pinterest pluginem (ověřeno v RE).
    /// Pinterest rozeznává bot-like agenty a blockne je; iPhone UA projde.
    /// Pozn.: používá se jen pro API call, ne pro login WebView (tam je desktop UA nutné).
    nonisolated static let iphoneUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) " +
        "Version/17.1 Mobile/15E148 Safari/604.1"

    /// True pokud máme platné Pinterest cookies v persistent store.
    /// Rychlá kontrola — neoverujeme session platnost (to zjistí až API call vrátí 401).
    private(set) var isLoggedIn: Bool = false

    /// Probíhá právě login sheet? (pro view binding)
    var isLoginSheetPresented: Bool = false

    /// Proběhla už úvodní kontrola cookies? Aby view věděl, že může věřit isLoggedIn.
    /// Race condition: view dorazí rychleji než asynchronní checkLoginStatus v initu.
    private(set) var initialCheckDone: Bool = false

    private var cookieStore: WKHTTPCookieStore {
        WKWebsiteDataStore.default().httpCookieStore
    }

    private init() {
        // Při startu asynchronně ověříme, jestli už máme cookies.
        Task { [weak self] in
            await self?.checkLoginStatus()
        }
    }

    /// Načte cookies z WKWebView store a zjistí, jestli obsahují Pinterest session.
    /// Pozn.: tohle neoveruje platnost session — jen přítomnost cookies.
    @MainActor
    func checkLoginStatus() async {
        let cookies = await cookieStore.allCookies()
        let hasPinterestSession = cookies.contains { cookie in
            cookie.domain.contains("pinterest.com") &&
            (cookie.name == "sess" || cookie.name == "_pinterest_sess"
                || cookie.name == "_pinterest_www" || cookie.name == "_auth"
                || cookie.name == "csrftoken")
        }
        isLoggedIn = hasPinterestSession
        initialCheckDone = true
    }

    /// Vrátí všechny Pinterest cookies pro URLSession.
    /// Voláno z `PinterestVisualClient` před každým API call.
    func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                let cookies = await cookieStore.allCookies()
                continuation.resume(returning: cookies.filter { $0.domain.contains("pinterest.com") })
            }
        }
    }

    /// Otevře login sheet pokud nejsme přihlášeni. Čeká na dokončení.
    @MainActor
    func ensureLoggedIn() async {
        // Počkat, dokud nedoběhne úvodní cookie check z initu — jinak race condition,
        // kdy view dorazí dřív než víme, jestli jsme přihlášeni.
        var attempts = 0
        while !initialCheckDone && attempts < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        await checkLoginStatus()
        if isLoggedIn { return }
        isLoginSheetPresented = true
        // View (PinterestLoginView) po úspěšném loginu zavolá onLoginSuccess(),
        // což nastaví isLoggedIn = true a isLoginSheetPresented = false.
        // Čekáme dokud není login dokončen.
        while isLoginSheetPresented && !isLoggedIn {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled { break }
        }
    }

    /// Zavolá PinterestLoginView po úspěšném loginu.
    @MainActor
    func onLoginSuccess() async {
        await checkLoginStatus()
        isLoginSheetPresented = false
    }

    /// Odhlásí (smaže cookies) — pro debug/refresh session.
    @MainActor
    func logout() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        isLoggedIn = false
    }
}
