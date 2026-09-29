import Foundation
import UIKit

final class QRPayerSession: NSObject, URLSessionTaskDelegate {
    struct Result {
        let qq: String
        let values: [String: String]
        let rows: [CookieRow]
    }

    var onStatus: ((String) -> Void)?
    var onQRCode: ((UIImage) -> Void)?
    var onSuccess: ((Result) -> Void)?
    var onFailure: ((String) -> Void)?

    private let cookieStorage = HTTPCookieStorage.shared
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = true
        c.httpCookieAcceptPolicy = .always
        c.httpCookieStorage = cookieStorage
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    private var task: Task<Void, Never>?
    private var redirectCounts: [Int: Int] = [:]
    private var generation = UUID()

    private let pcUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private let androidUA = "Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Mobile Safari/537.36"

    func start() {
        cancel()
        let token = UUID(); generation = token
        clearQQCookies()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                await status("正在获取二维码...")
                let login = "https://xui.ptlogin2.qq.com/cgi-bin/xlogin?daid=307&hide_title_bar=1&low_login=0&qlogin_auto_login=1&no_verifyimg=1&link_target=blank&appid=11000101&style=22&target=self&s_url=https%3A%2F%2Fpay.qq.com%2Fh5%2Fh5_login_jump.shtml&pt_no_auth=1"
                _ = try await get(login, referer: nil, userAgent: pcUA)
                try check(token)

                let ts = String(format: "%.6f", Date().timeIntervalSince1970)
                let qr = "https://ssl.ptlogin2.qq.com/ptqrshow?appid=11000101&e=2&l=M&s=3&d=72&v=4&t=\(ts)&daid=307&pt_3rd_aid=0"
                let imageData = try await get(qr, referer: login, userAgent: pcUA)
                guard imageData.count > 50, let image = UIImage(data: imageData) else { throw WCError.message("服务器未返回二维码图片") }
                guard let qrsig = cookieValue("qrsig", for: URL(string: qr)!), !qrsig.isEmpty else { throw WCError.message("响应缺少 qrsig，请刷新二维码") }
                let qrToken = ptqrtoken(qrsig)
                await MainActor.run { self.onQRCode?(image); self.onStatus?("二维码已获取，请扫码") }

                for _ in 0..<180 {
                    try check(token)
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let u = "https://ssl.ptlogin2.qq.com/ptqrlogin?u1=https%3A%2F%2Fpay.qq.com%2Fh5%2Fh5_login_jump.shtml&ptqrtoken=\(qrToken)&ptredirect=0&h=1&t=1&g=1&from_ui=1&ptlang=2052&action=0-0-\(Int(Date().timeIntervalSince1970 * 1000))&js_ver=10204&js_type=1&login_sig=&pt_uistyle=40&aid=11000101&daid=307&"
                    let data = try await get(u, referer: "https://xui.ptlogin2.qq.com/", userAgent: pcUA)
                    let text = String(data: data, encoding: .utf8) ?? ""
                    let parsed = parseCallback(text)
                    if parsed.code == "66" { await status("等待扫码"); continue }
                    if parsed.code == "67" { await status("扫码成功，请确认登录"); continue }
                    if parsed.code == "0", let target = parsed.url {
                        try await finishLogin(target: target, token: token)
                        return
                    }
                    throw WCError.message("二维码已失效或登录未完成，请刷新。")
                }
                throw WCError.message("二维码已过期，请刷新。")
            } catch is CancellationError {
            } catch {
                await MainActor.run { self.onFailure?(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        generation = UUID()
    }

    private func finishLogin(target: String, token: UUID) async throws {
        guard let targetURL = URL(string: target), targetURL.scheme == "https", isQQHost(targetURL.host) else { throw WCError.message("登录跳转地址无效，请重新扫码。") }
        _ = try await get(target, referer: "https://xui.ptlogin2.qq.com/", userAgent: pcUA)
        let pages: [(String, String)] = [
            ("https://pay.qq.com/", pcUA),
            ("https://pay.qq.com/index.shtml", pcUA),
            ("https://pay.qq.com/h5/h5_login_jump.shtml", androidUA),
            ("https://pay.qq.com/pc/account/index.shtml", pcUA)
        ]
        for (idx, page) in pages.enumerated() {
            try check(token)
            await status("扫码已确认，正在准备付款会话（\(idx + 1)/4）…")
            _ = try? await get(page.0, referer: idx == 0 ? target : "https://pay.qq.com/", userAgent: page.1)
        }
        let result = try makeResult()
        await MainActor.run { self.onSuccess?(result) }
    }

    private func makeResult() throws -> Result {
        let payURL = URL(string: "https://pay.qq.com/")!
        let payCookies = cookieStorage.cookies(for: payURL) ?? []
        var values: [String: String] = [:]
        let names: Set<String> = ["uin", "skey", "p_uin", "p_skey", "pt4_token", "ptcz", "pt2gguin", "RK", "pgv_pvid", "pgv_info"]
        for c in payCookies where names.contains(c.name) { values[c.name] = c.value }
        var qq = values["uin"] ?? values["p_uin"] ?? ""
        qq = WebSessionManager.shared.normalizeQQ(qq)
        guard qq.range(of: "^[0-9]{5,12}$", options: .regularExpression) != nil,
              !(values["skey"] ?? values["p_skey"] ?? "").isEmpty else { throw WCError.message("未取得完整账号信息，请重新扫码。") }

        let now = Date().timeIntervalSince1970 * 1000
        let rows = (cookieStorage.cookies ?? []).compactMap { c -> CookieRow? in
            let d = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            guard (d == "qq.com" || d.hasSuffix(".qq.com")), c.name != "qrsig" else { return nil }
            let exp = c.expiresDate?.timeIntervalSince1970 ?? 0
            if exp > 0 && exp * 1000 <= now { return nil }
            return CookieRow(name: c.name, value: c.value, domain: d, path: c.path.isEmpty ? "/" : c.path,
                             hostOnly: !c.domain.hasPrefix("."), secure: c.isSecure, httpOnly: c.isHTTPOnly,
                             sameSite: "", expiresAt: exp > 0 ? exp * 1000 : 0)
        }
        return Result(qq: qq, values: values, rows: rows)
    }

    private func get(_ raw: String, referer: String?, userAgent: String) async throws -> Data {
        guard let url = URL(string: raw), url.scheme == "https", isQQHost(url.host) else { throw WCError.message("HTTPS 地址无效") }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw WCError.message("腾讯服务器返回异常状态")
        }
        return data
    }

    private func parseCallback(_ text: String) -> (code: String?, url: String?) {
        let pattern = #"ptuiCB\('([0-9]+)'\s*,\s*'[^']*'\s*,\s*'([^']*)'"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r1 = Range(m.range(at: 1), in: text), let r2 = Range(m.range(at: 2), in: text) else { return (nil, nil) }
        return (String(text[r1]), String(text[r2]))
    }

    private func ptqrtoken(_ sig: String) -> Int {
        var value: UInt32 = 0
        for scalar in sig.unicodeScalars { value = value &* 33 &+ UInt32(scalar.value) }
        return Int(value & 0x7fffffff)
    }

    private func cookieValue(_ name: String, for url: URL) -> String? {
        (cookieStorage.cookies(for: url) ?? []).first(where: { $0.name == name })?.value
    }

    private func clearQQCookies() {
        for c in cookieStorage.cookies ?? [] {
            let d = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if d == "qq.com" || d.hasSuffix(".qq.com") { cookieStorage.deleteCookie(c) }
        }
    }

    private func isQQHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "qq.com" || h.hasSuffix(".qq.com")
    }

    private func check(_ token: UUID) throws {
        if Task.isCancelled || token != generation { throw CancellationError() }
    }

    private func status(_ text: String) async { await MainActor.run { self.onStatus?(text) } }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let count = (redirectCounts[task.taskIdentifier] ?? 0) + 1
        redirectCounts[task.taskIdentifier] = count
        guard count <= 8, request.url?.scheme == "https", isQQHost(request.url?.host) else { completionHandler(nil); return }
        completionHandler(request)
    }
}
