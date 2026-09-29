import Foundation
import WebKit
import CryptoKit

final class WebSessionManager {
    static let shared = WebSessionManager()
    private let defaults = UserDefaults.standard
    private let payerKey = "wc-live-payer"
    private let sourceHashKey = "wc-live-source-hash"

    private let payerNames: Set<String> = ["uin", "skey", "p_uin", "p_skey", "pt4_token", "ptcz", "pt2gguin", "RK", "pgv_pvid", "pgv_info"]
    private let gameNames: Set<String> = ["appid", "access_token", "openid", "openkey", "eas_entry", "acctype"]

    func bind(payerQQ: String, source: [CookieRow]) {
        defaults.set(payerQQ, forKey: payerKey)
        defaults.set(hash(source), forKey: sourceHashKey)
    }

    func unbind() {
        defaults.removeObject(forKey: payerKey)
        defaults.removeObject(forKey: sourceHashKey)
    }

    func reusable(payerQQ: String, source: [CookieRow]) async -> Bool {
        guard defaults.string(forKey: payerKey) == payerQQ,
              defaults.string(forKey: sourceHashKey) == hash(source) else { return false }
        return await payerCookieMatches(expectedQQ: payerQQ, host: "pay.qq.com")
    }

    func payerCookieMatches(expectedQQ: String, host: String) async -> Bool {
        let cookies = await allCookies()
        var identityFound = false
        var keyFound = false
        for cookie in cookies where cookieApplies(cookie, to: host) {
            if (cookie.name == "skey" || cookie.name == "p_skey") && !cookie.value.isEmpty { keyFound = true }
            if cookie.name == "uin" || cookie.name == "p_uin" {
                let qq = normalizeQQ(cookie.value)
                if !qq.isEmpty && qq != expectedQQ { return false }
                if qq == expectedQQ { identityFound = true }
            }
        }
        return identityFound && keyFound
    }

    func install(_ rows: [CookieRow]) async -> Bool {
        guard !rows.isEmpty else { return false }
        let store = WebContext.dataStore.httpCookieStore
        for row in rows {
            guard !row.isExpired, valid(row: row), let cookie = row.asHTTPCookie() else { return false }
            await withCheckedContinuation { cont in store.setCookie(cookie) { cont.resume() } }
        }
        return true
    }

    func clearAllWebsiteData() async {
        unbind()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { cont in
            WebContext.dataStore.removeData(ofTypes: types, modifiedSince: .distantPast) { cont.resume() }
        }
    }

    func clearGameKeepingPayer(source: [CookieRow]) async -> Bool {
        let store = WebContext.dataStore.httpCookieStore
        let protected = Set(source.map(\.name)).union(payerNames)
        let cookies = await allCookies()
        for cookie in cookies {
            let host = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard host == "qq.com" || host.hasSuffix(".qq.com") else { continue }
            let shouldDelete = gameNames.contains(cookie.name) || !protected.contains(cookie.name)
            if shouldDelete {
                await withCheckedContinuation { cont in store.delete(cookie) { cont.resume() } }
            }
        }
        let nonCookieTypes = WKWebsiteDataStore.allWebsiteDataTypes().subtracting([WKWebsiteDataTypeCookies])
        await withCheckedContinuation { cont in
            WebContext.dataStore.removeData(ofTypes: nonCookieTypes, modifiedSince: .distantPast) { cont.resume() }
        }
        return true
    }

    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { cont in
            WebContext.dataStore.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }

    func normalizeQQ(_ raw: String) -> String {
        var v = raw
        if v.lowercased().hasPrefix("o") { v.removeFirst() }
        while v.count > 1 && v.first == "0" { v.removeFirst() }
        return v
    }

    func cookieApplies(_ cookie: HTTPCookie, to host: String) -> Bool {
        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let h = host.lowercased()
        return h == domain || h.hasSuffix("." + domain)
    }

    private func valid(row: CookieRow) -> Bool {
        let d = row.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard d == "qq.com" || d.hasSuffix(".qq.com") else { return false }
        guard row.path.hasPrefix("/"), !row.value.contains(";"), !row.value.contains("\n"), !row.value.contains("\r") else { return false }
        return row.name.range(of: "^[A-Za-z0-9_!#$%&'*+.^`|~-]+$", options: .regularExpression) != nil
    }

    private func hash(_ rows: [CookieRow]) -> String {
        let data = (try? JSONEncoder().encode(rows)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
