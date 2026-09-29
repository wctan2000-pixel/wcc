import UIKit
import WebKit

final class RechargeViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    let plan: RechargePlan
    let reusePayer: Bool
    var onRequestPayerScan: (() -> Void)?
    var onGameSessionCleared: (() -> Void)?

    private var web: WKWebView!
    private let statusLabel = UILabel()
    private var phase = "preparing"
    private var payerInstalled = false
    private var cookiesReady = false
    private var warmupScheduled = false
    private var deferredInjected = false
    private var deferredAttempts = 0
    private var riskStopped = false
    private var observedPayerQQ = ""
    private var lastRole = ""
    private var lastServer = ""
    private var lastHTTPStatus = 0

    init(plan: RechargePlan, reusePayer: Bool) {
        self.plan = plan
        self.reusePayer = reusePayer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "充值页面 · \(plan.browserLabel)"
        view.backgroundColor = .systemBackground
        buildUI()
        beginPreparation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent { web.stopLoading() }
    }

    private func buildUI() {
        let config = WebContext.configuration()
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        if plan.browserLabel == "安卓", !plan.userAgent.isEmpty { web.customUserAgent = plan.userAgent }

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 3
        statusLabel.text = "正在准备登录状态…"

        let scan = button("重扫QQ", action: #selector(rescan))
        let check = button("核对信息", action: #selector(showCheck))
        let refresh = button("刷新", action: #selector(refreshPage))
        let clear = button("换号清理", action: #selector(clearGameSession))

        let bar = UIStackView(arrangedSubviews: [scan, check, refresh, clear])
        bar.axis = .horizontal
        bar.spacing = 8
        bar.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [statusLabel, bar, web])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(6, after: statusLabel)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            bar.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    private func button(_ title: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func beginPreparation() {
        guard plan.payerQQ.range(of: "^[0-9]{5,12}$", options: .regularExpression) != nil,
              !plan.cookies.isEmpty,
              let target = URL(string: plan.url), target.scheme == "https", isQQHost(target.host) else {
            fail("充值链接或付款 QQ 凭据无效，请返回检查。")
            return
        }
        Task { @MainActor in
            if reusePayer {
                let matched = await WebSessionManager.shared.payerCookieMatches(expectedQQ: plan.payerQQ, host: "pay.qq.com")
                guard matched else { fail("付款 QQ 登录已失效，请返回重新扫码。"); return }
            }
            if !plan.warmupURL.isEmpty {
                phase = "warming"
                let rows = reusePayer ? Array(plan.beforeWarmup.dropFirst(min(plan.cookies.count, plan.beforeWarmup.count))) : plan.beforeWarmup
                guard await WebSessionManager.shared.install(rows) else { fail("付款账号状态写入失败，请返回重试。"); return }
                payerInstalled = true
                WebSessionManager.shared.bind(payerQQ: plan.payerQQ, source: plan.sourceCookies)
                statusLabel.text = "正在初始化登录站点…"
                load(plan.warmupURL)
            } else {
                await prepareAllCookies()
            }
        }
    }

    private func prepareAllCookies() async {
        guard phase != "failed" else { return }
        phase = "preparing"
        if !(reusePayer || payerInstalled) {
            guard await WebSessionManager.shared.install(plan.cookies) else { fail("付款 QQ 凭据未完整载入，请返回重新扫码。"); return }
        }
        let base = await WebSessionManager.shared.payerCookieMatches(expectedQQ: plan.payerQQ, host: "pay.qq.com")
        let page = await WebSessionManager.shared.payerCookieMatches(expectedQQ: plan.payerQQ, host: "pagedoo.pay.qq.com")
        let api = await WebSessionManager.shared.payerCookieMatches(expectedQQ: plan.payerQQ, host: "storeapi.pay.qq.com")
        guard base else { fail("付款 QQ 凭据未完整载入，请返回重新扫码。"); return }
        guard page && api else { fail("付款子域凭据未就绪，请重扫QQ后再试。"); return }
        cookiesReady = true
        payerInstalled = true
        WebSessionManager.shared.bind(payerQQ: plan.payerQQ, source: plan.sourceCookies)
        phase = "ready"
        statusLabel.text = "付款 QQ 凭据已载入，正在打开网页；实际付款账号尚待确认。"
        load(plan.url)
    }

    private func load(_ raw: String) {
        guard let url = URL(string: raw) else { fail("页面地址无效。"); return }
        var request = URLRequest(url: url)
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        web.load(request)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard phase != "failed" else { return }
        lastHTTPStatus = 0
        if phase == "warming" { statusLabel.text = "正在初始化登录站点…" }
        else { statusLabel.text = "正在加载网页…" }
        if phase == "ready", let url = webView.url, maybeInjectDeferredCK(url) { return }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard phase != "failed" else { return }
        if phase == "warming" {
            guard !warmupScheduled else { return }
            warmupScheduled = true
            let delay: UInt64 = (URL(string: plan.warmupURL)?.host == "xinyue.qq.com") ? 1_200_000_000 : 250_000_000
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: delay)
                await prepareAllCookies()
            }
            return
        }
        guard phase == "ready" else { return }
        if let url = webView.url, maybeInjectDeferredCK(url) { return }
        detectRiskAndIdentity()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.detectRiskAndIdentity() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in self?.detectRiskAndIdentity() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" {
            if scheme == "https", !isQQHost(url.host) {
                // CK 只允许出现在 qq.com；非 QQ HTTPS 页面仍可由腾讯页面正常跳转，但本 App 不注入任何 CK。
            }
            if navigationAction.targetFrame?.isMainFrame == true, phase == "ready", maybeInjectDeferredCK(url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }
        let external: Set<String> = ["weixin", "mqq", "mqqapi", "mqqopensdkapi", "alipays"]
        if external.contains(scheme), navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse, navigationResponse.isForMainFrame {
            lastHTTPStatus = response.statusCode
            if response.statusCode >= 400 { statusLabel.text = "网页服务器返回 HTTP \(response.statusCode)，请返回检查链接或稍后重试。" }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        statusLabel.text = "网页加载失败：\(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        statusLabel.text = "网页加载失败：\(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" || url.scheme == "http" { webView.load(navigationAction.request) }
        return nil
    }

    private func maybeInjectDeferredCK(_ url: URL) -> Bool {
        guard plan.deferCkInjection, !riskStopped, !plan.ckParams.isEmpty,
              url.scheme == "https", url.host?.lowercased() == "pagedoo.pay.qq.com" else { return false }
        if urlContainsCurrentCK(url) { deferredInjected = true; return false }
        deferredInjected = false
        guard deferredAttempts < 3 else { fail("最终充值页登录信息融合失败，请返回重试。"); return true }
        guard let merged = mergeCK(into: url), merged != url else { fail("最终充值页登录信息融合失败，请返回重试。"); return true }
        deferredAttempts += 1
        statusLabel.text = "已到最终充值页，正在载入登录状态…"
        DispatchQueue.main.async { [weak self] in self?.load(merged.absoluteString) }
        return true
    }

    private func urlContainsCurrentCK(_ url: URL) -> Bool {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let items = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let expectedOpenid = plan.ckParams["openid"] ?? plan.ckParams["open_id"] ?? ""
        let expectedOpenkey = plan.ckParams["openkey"] ?? plan.ckParams["open_key"] ?? plan.ckParams["access_token"] ?? ""
        let gotOpenid = items["openid"] ?? items["open_id"] ?? ""
        let gotOpenkey = items["openkey"] ?? items["open_key"] ?? items["access_token"] ?? ""
        return !expectedOpenid.isEmpty && !expectedOpenkey.isEmpty && expectedOpenid == gotOpenid && expectedOpenkey == gotOpenkey
    }

    private func mergeCK(into url: URL) -> URL? {
        guard url.scheme == "https", isQQHost(url.host), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var order: [String] = []
        var merged: [String: String] = [:]
        for item in c.queryItems ?? [] {
            if merged[item.name] == nil { order.append(item.name) }
            merged[item.name] = item.value ?? ""
        }
        let original = merged
        for (key, value) in plan.ckParams where !key.isEmpty && !value.contains(";") && !value.contains("\n") && !value.contains("\r") {
            if merged[key] == nil { order.append(key) }
            merged[key] = value
        }
        guard let openid = merged["openid"], !openid.isEmpty, let openkey = merged["openkey"], !openkey.isEmpty else { return nil }
        c.queryItems = order.compactMap { key in merged[key].map { URLQueryItem(name: key, value: $0) } }
        guard let final = c.url, let check = URLComponents(url: final, resolvingAgainstBaseURL: false) else { return nil }
        let finalMap = Dictionary(uniqueKeysWithValues: (check.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        for (k, v) in original where plan.ckParams[k] == nil {
            guard finalMap[k] == v else { return nil }
        }
        return final
    }

    private func detectRiskAndIdentity() {
        let js = #"(function(){var t=document.body?document.body.innerText:'';var lines=t.split(/\r?\n/).map(function(x){return x.trim();}).filter(Boolean);var riskLine='';for(var i=0;i<lines.length;i++){if(/(交易风险|存在风险|风险提示|支付风险|交易存在风险)/.test(lines[i])){riskLine=lines[i].slice(0,180);break;}}var q=t.match(/(?:付款|支付)\s*(?:QQ|ＱＱ)(?:\s*(?:账号|帐号|号))?\s*[:：]?\s*([1-9][0-9]{4,11})(?![0-9])/i);var r=t.match(/(?:角色名|角色|昵称)\s*[:：]?\s*([^\n\r]{1,40})/);var s=t.match(/(?:区服|服务器|大区)\s*[:：]?\s*([^\n\r]{1,40})/);return {risk:!!riskLine,riskText:riskLine,qq:q?q[1]:'',role:r?r[1].trim():'',server:s?s[1].trim():''};})()"#
        web.evaluateJavaScript(js) { [weak self] value, _ in
            guard let self, let obj = value as? [String: Any], self.phase == "ready" else { return }
            if obj["risk"] as? Bool == true {
                self.riskStopped = true
                let riskText = (obj["riskText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.statusLabel.text = riskText.isEmpty ? "腾讯页面已提示交易风险，已停止本 App 的自动重试。" : "腾讯提示：\(riskText)｜已停止本 App 的自动重试。"
                return
            }
            if let qq = obj["qq"] as? String, qq.range(of: "^[0-9]{5,12}$", options: .regularExpression) != nil {
                self.observedPayerQQ = qq
                if qq != self.plan.payerQQ {
                    self.fail("网页付款 QQ 与所选账号不一致，请点“重扫QQ”重新登录。")
                    return
                }
            }
            self.lastRole = obj["role"] as? String ?? ""
            self.lastServer = obj["server"] as? String ?? ""
            var pieces: [String] = []
            if !self.lastRole.isEmpty { pieces.append("角色：\(self.lastRole)") }
            if !self.lastServer.isEmpty { pieces.append("区服：\(self.lastServer)") }
            if !self.observedPayerQQ.isEmpty { pieces.append("付款QQ：\(self.observedPayerQQ)") }
            self.statusLabel.text = pieces.isEmpty ? "网页已加载。付款前请在腾讯页面核对游戏角色、区服与实际付款 QQ。" : "请核对后再付款：" + pieces.joined(separator: " · ")
        }
    }

    @objc private func showCheck() {
        Task { @MainActor in
            let payOK = await WebSessionManager.shared.payerCookieMatches(expectedQQ: plan.payerQQ, host: "pay.qq.com")
            let message = "所选付款 QQ：\(plan.payerQQ)\n网页付款 QQ：\(observedPayerQQ.isEmpty ? "尚未识别，请在腾讯页面手动核对" : observedPayerQQ)\n游戏角色：\(lastRole.isEmpty ? "尚未识别，请在腾讯页面手动核对" : lastRole)\n区服：\(lastServer.isEmpty ? "尚未识别，请在腾讯页面手动核对" : lastServer)\n本地付款会话：\(payOK ? "与所选 QQ 匹配" : "缺失或不匹配")\n主页面 HTTP：\(lastHTTPStatus == 0 ? "未记录" : String(lastHTTPStatus))\nCK：\(plan.deferCkInjection ? (deferredInjected ? "已在最终 pagedoo 页融合" : "等待最终 pagedoo 页融合") : "入口已融合")"
            let a = UIAlertController(title: "付款前核对", message: message, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "关闭", style: .default))
            present(a, animated: true)
        }
    }

    @objc private func refreshPage() {
        guard phase == "ready" else { statusLabel.text = "请返回重新打开页面。"; return }
        if riskStopped { statusLabel.text = "腾讯已提示交易风险，本 App 已停止自动重试；请按页面提示处理。"; return }
        let a = UIAlertController(title: "刷新网页", message: "将重新加载当前腾讯页面；如刚完成操作，请先确认结果。", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "取消", style: .cancel))
        a.addAction(UIAlertAction(title: "刷新", style: .default) { [weak self] _ in self?.web.reload() })
        present(a, animated: true)
    }

    @objc private func rescan() {
        phase = "failed"
        web.stopLoading()
        onRequestPayerScan?()
    }

    @objc private func clearGameSession() {
        guard phase != "failed" else { return }
        phase = "clearing"
        web.stopLoading()
        statusLabel.text = "正在清理旧游戏数据，保留付款 QQ 登录…"
        Task { @MainActor in
            _ = await WebSessionManager.shared.clearGameKeepingPayer(source: plan.sourceCookies)
            phase = "cleared"
            onGameSessionCleared?()
            navigationController?.popViewController(animated: true)
        }
    }

    private func fail(_ text: String) {
        phase = "failed"
        statusLabel.text = text
        web?.stopLoading()
        let html = "<meta name='viewport' content='width=device-width'><p style='font:16px -apple-system;padding:20px'>\(escapeHTML(text))</p>"
        web?.loadHTMLString(html, baseURL: nil)
    }

    private func isQQHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "qq.com" || h.hasSuffix(".qq.com")
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
