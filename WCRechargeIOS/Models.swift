import Foundation
import WebKit

struct CookieRow: Encodable, Equatable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var hostOnly: Bool
    var secure: Bool
    var httpOnly: Bool
    var sameSite: String
    var expiresAt: Double

    var isExpired: Bool { expiresAt > 0 && expiresAt <= Date().timeIntervalSince1970 * 1000 }

    func matches(host: String, path requestPath: String = "/") -> Bool {
        let d = domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let h = host.lowercased()
        let domainOK = h == d || (!hostOnly && h.hasSuffix("." + d))
        guard domainOK else { return false }
        let p = path.isEmpty ? "/" : path
        return requestPath == p || requestPath.hasPrefix(p.hasSuffix("/") ? p : p + "/") || p == "/"
    }

    func asHTTPCookie() -> HTTPCookie? {
        guard !name.isEmpty, !value.isEmpty, !domain.isEmpty, path.hasPrefix("/") else { return nil }
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .path: path,
            .secure: secure ? "TRUE" : "FALSE"
        ]
        if hostOnly {
            props[.originURL] = URL(string: "https://\(domain)\(path)") as Any
            props[.domain] = domain
        } else {
            props[.domain] = domain.hasPrefix(".") ? domain : "." + domain
        }
        if expiresAt > 0 { props[.expires] = Date(timeIntervalSince1970: expiresAt / 1000) }
        return HTTPCookie(properties: props)
    }
}


extension CookieRow: Decodable {
    enum CodingKeys: String, CodingKey {
        case name, value, domain, path, hostOnly, secure, httpOnly, sameSite, expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        value = try c.decode(String.self, forKey: .value)
        domain = try c.decode(String.self, forKey: .domain)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? "/"
        hostOnly = try c.decodeIfPresent(Bool.self, forKey: .hostOnly) ?? true
        secure = try c.decodeIfPresent(Bool.self, forKey: .secure) ?? true
        httpOnly = try c.decodeIfPresent(Bool.self, forKey: .httpOnly) ?? false
        sameSite = try c.decodeIfPresent(String.self, forKey: .sameSite) ?? ""
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt) ?? 0
    }
}

struct AccountRecord: Codable {
    var cookies: [String: String]
    var cookieRows: [CookieRow]
    var cookieSchema: Int
    var balance: Double?
}

struct RechargeConfig: Codable {
    var title: String
    var type: String
    var url: String
}

struct RechargePlan {
    let url: String
    let payerQQ: String
    let sourceCookies: [CookieRow]
    let cookies: [CookieRow]
    let userAgent: String
    let browserLabel: String
    let warmupURL: String
    let beforeWarmup: [CookieRow]
    let deferCkInjection: Bool
    let ckParams: [String: String]
}

enum WCError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return "操作失败"
    }
}

enum WebContext {
    static let processPool = WKProcessPool()
    static let dataStore = WKWebsiteDataStore.default()

    static func configuration() -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.processPool = processPool
        c.websiteDataStore = dataStore
        c.preferences.javaScriptCanOpenWindowsAutomatically = true
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        return c
    }
}
