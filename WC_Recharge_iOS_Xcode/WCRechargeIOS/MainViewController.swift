import UIKit
import WebKit

final class MainViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private let store = AppStore()
    private var panel: WKWebView!
    private var qrSession: QRPayerSession?
    private var qrImage: UIImage?
    private var busy = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "WC充值"
        view.backgroundColor = .systemBackground
        configurePanel()
        loadPanel()
    }

    deinit {
        panel?.configuration.userContentController.removeScriptMessageHandler(forName: "native")
        qrSession?.cancel()
    }

    private func configurePanel() {
        let config = WebContext.configuration()
        config.userContentController.add(self, name: "native")
        panel = WKWebView(frame: .zero, configuration: config)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.navigationDelegate = self
        panel.allowsBackForwardNavigationGestures = false
        view.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            panel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func loadPanel() {
        guard let url = Bundle.main.url(forResource: "panel", withExtension: "html") else {
            showFatal("本地页面资源缺失。")
            return
        }
        panel.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 主面板只允许本地 bundle 页面，避免 CK 输入框被任何远程页面读取。
        if let url = navigationAction.request.url, url.isFileURL { decisionHandler(.allow) }
        else { decisionHandler(.cancel) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "native", let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        if busy && action != "ready" { emit("status", "正在准备账号，请稍候再操作。"); return }
        switch action {
        case "ready": sendInitialState()
        case "qr": startQR()
        case "browserPlatform":
            if let value = body["value"] as? String, value == "ios" || value == "android" {
                store.setBrowserPlatform(value)
                emit("status", value == "ios" ? "已选择苹果，下次打开充值链接时生效。" : "已选择安卓，下次打开充值链接时生效。")
            }
        case "balance": queryBalance(body["qq"] as? String ?? "")
        case "saveConfig": saveConfig(body)
        case "importConfigs": importConfigs(body["text"] as? String ?? "")
        case "exportConfigs": exportConfigs()
        case "deleteConfig": deleteConfig(Int(number(body["index"])))
        case "recharge", "records": openRecharge(body)
        case "pasteCredential": pasteCredential()
        case "copyQR": copyQR()
        case "clearSession": clearGameKeepingPayer(body["qq"] as? String ?? "")
        case "selectAccount":
            Task { @MainActor in
                busy = true
                await WebSessionManager.shared.clearAllWebsiteData()
                busy = false
                emit("status", "上一付款 QQ 的网页凭据已清理，打开充值页时载入所选 QQ。")
            }
        case "deleteAccount": deleteAccount(body["qq"] as? String ?? "")
        default: break
        }
    }

    private func sendInitialState() {
        emit("init", [
            "configs": configsJSON(store.configs()),
            "accounts": store.publicAccounts(),
            "version": "iOS 1.0.0（本机 WKWebView 版）",
            "browserPlatform": store.browserPlatform()
        ])
    }

    private func startQR() {
        qrSession?.cancel()
        qrImage = nil
        emit("qr", "")
        Task { @MainActor in
            busy = true
            await WebSessionManager.shared.clearAllWebsiteData()
            busy = false
            let session = QRPayerSession()
            qrSession = session
            session.onStatus = { [weak self] in self?.emit("status", $0) }
            session.onQRCode = { [weak self] image in
                self?.qrImage = image
                if let data = image.pngData() { self?.emit("qr", data.base64EncodedString()) }
            }
            session.onFailure = { [weak self] in self?.emit("status", "二维码登录失败：\($0)") }
            session.onSuccess = { [weak self] result in self?.completeQRLogin(result) }
            session.start()
        }
    }

    private func completeQRLogin(_ result: QRPayerSession.Result) {
        var accounts = store.accounts()
        let oldBalance = accounts[result.qq]?.balance
        accounts[result.qq] = AccountRecord(cookies: result.values, cookieRows: result.rows, cookieSchema: 2, balance: oldBalance)
        store.saveAccounts(accounts)
        emit("accounts", store.publicAccounts())
        emit("selectedAccount", result.qq)
        emit("status", "登录成功，正在查询余额...")
        queryBalance(result.qq)
    }

    private func queryBalance(_ qq: String) {
        guard qq.range(of: "^[0-9]{5,12}$", options: .regularExpression) != nil,
              let account = store.accounts()[qq] else { emit("status", "账号信息不完整，请重新扫码。"); return }
        let key = account.cookies["skey"].flatMap { $0.isEmpty ? nil : $0 } ?? account.cookies["p_skey"] ?? ""
        guard !key.isEmpty else { emit("status", "账号信息不完整，请重新扫码。"); return }
        var c = URLComponents(string: "https://api.unipay.qq.com/v1/r/1450000186/wechat_query")!
        c.queryItems = [
            .init(name: "cmd", value: "4"), .init(name: "pf", value: "vip_m-pay_html5-html5"),
            .init(name: "pfkey", value: "pfkey"), .init(name: "from_h5", value: "1"),
            .init(name: "from_https", value: "1"), .init(name: "format", value: "jsonp__getQBBalance"),
            .init(name: "openid", value: qq), .init(name: "openkey", value: key),
            .init(name: "session_id", value: "uin"), .init(name: "session_type", value: "skey"), .init(name: "qq_appid", value: "")
        ]
        guard let url = c.url else { return }
        let originalRows = account.cookieRows
        emit("status", "正在刷新余额...")
        Task {
            do {
                var req = URLRequest(url: url)
                req.setValue("https://pay.qq.com/", forHTTPHeaderField: "Referer")
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let text = String(data: data, encoding: .utf8),
                      let l = text.firstIndex(of: "("), let r = text.lastIndex(of: ")"), l < r,
                      let json = String(text[text.index(after: l)..<r]).data(using: .utf8),
                      let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any],
                      number(obj["ret"]) == 0, let rawBalance = obj["qb_balance"] else { throw WCError.message("余额查询未成功") }
                let amount = number(rawBalance) / 100.0
                await MainActor.run {
                    var latest = self.store.accounts()
                    guard latest[qq]?.cookieRows == originalRows else { return }
                    latest[qq]?.balance = amount
                    self.store.saveAccounts(latest)
                    self.emit("accounts", self.store.publicAccounts())
                    self.emit("status", "余额已刷新")
                }
            } catch {
                await MainActor.run { self.emit("status", "余额查询未成功，请检查登录状态。") }
            }
        }
    }

    private func saveConfig(_ body: [String: Any]) {
        var configs = store.configs()
        let index = Int(number(body["index"]))
        let title = (body["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let type = body["type"] as? String ?? ""
        let url = (body["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard index >= -1, index < configs.count, !title.isEmpty, !title.contains("\n"), !url.contains("\n"), ["充值官网", "心悦"].contains(type) else {
            emit("status", "请填写标题并选择有效类型。"); return
        }
        guard !configs.enumerated().contains(where: { $0.offset != index && $0.element.title == title }) else {
            emit("status", "已有同名配置，请使用其他标题。"); return
        }
        let item = RechargeConfig(title: title, type: type, url: url)
        let selected: Int
        if index == -1 { configs.append(item); selected = configs.count - 1 } else { configs[index] = item; selected = index }
        store.saveConfigs(configs)
        emit("configs", configsJSON(configs))
        emit("selectedConfig", selected)
        emit("status", "返利标题和链接已保存")
    }

    private func importConfigs(_ text: String) {
        guard !text.isEmpty, text.count <= 200_000 else { emit("status", "配置文本为空或过长。"); return }
        var incoming: [RechargeConfig] = []
        var current: RechargeConfig?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("游戏=") {
                if let current { incoming.append(current) }
                current = RechargeConfig(title: String(line.dropFirst(3)), type: "充值官网", url: "")
            } else if line.hasPrefix("目标网址="), current != nil {
                current!.url = String(line.dropFirst(5))
            } else if line.hasPrefix("类型="), current != nil {
                current!.type = String(line.dropFirst(3))
            } else { emit("status", "配置文本包含无法识别的行，未导入。"); return }
        }
        if let current { incoming.append(current) }
        let titles = Set(incoming.map(\.title))
        guard !incoming.isEmpty, incoming.count <= 200, titles.count == incoming.count,
              incoming.allSatisfy({ !$0.title.isEmpty && ["充值官网", "心悦"].contains($0.type) }) else {
            emit("status", "存在空标题、重复标题或无效类型，未导入。"); return
        }
        let alert = UIAlertController(title: "导入配置", message: "同名配置将更新，其他现有配置保留。是否继续？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "导入", style: .default) { [weak self] _ in
            guard let self else { return }
            var merged = self.store.configs()
            for item in incoming {
                if let idx = merged.firstIndex(where: { $0.title == item.title }) { merged[idx] = item } else { merged.append(item) }
            }
            self.store.saveConfigs(merged)
            self.emit("configs", self.configsJSON(merged))
            self.emit("status", "配置已导入。")
        })
        present(alert, animated: true)
    }

    private func exportConfigs() {
        let text = store.configs().map { "游戏=\($0.title)\n目标网址=\($0.url)\n类型=\($0.type)" }.joined(separator: "\n\n")
        UIPasteboard.general.string = text
        emit("status", "配置文本已复制。")
    }

    private func deleteConfig(_ index: Int) {
        let snapshot = store.configs()
        guard snapshot.indices.contains(index) else { return }
        guard snapshot.count > 1 else { emit("status", "至少保留一项配置。"); return }
        let alert = UIAlertController(title: "删除配置", message: snapshot[index].title, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            var current = self.store.configs()
            guard current.indices.contains(index) else { return }
            current.remove(at: index)
            self.store.saveConfigs(current)
            self.emit("configs", self.configsJSON(current))
        })
        present(alert, animated: true)
    }

    private func deleteAccount(_ qq: String) {
        guard !qq.isEmpty else { return }
        let alert = UIAlertController(title: "删除账号", message: "仅删除本机保存的该账号信息，是否继续？", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
            guard let self else { return }
            var all = self.store.accounts(); all.removeValue(forKey: qq); self.store.saveAccounts(all)
            self.emit("accounts", self.store.publicAccounts())
        })
        present(alert, animated: true)
    }

    private func pasteCredential() {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            emit("credential", text)
            emit("status", "已粘贴替换登录信息。")
        } else { emit("status", "剪贴板没有文字。") }
    }

    private func copyQR() {
        guard let qrImage else { emit("status", "请先获取二维码。"); return }
        UIPasteboard.general.image = qrImage
        emit("status", "二维码图片已复制。")
    }

    private func clearGameKeepingPayer(_ qq: String) {
        guard let account = store.accounts()[qq] else {
            emit("credential", ""); emit("status", "未选择付款 QQ，已清空输入框。"); return
        }
        Task { @MainActor in
            busy = true
            let ok = await WebSessionManager.shared.clearGameKeepingPayer(source: account.cookieRows)
            busy = false
            emit("credential", "")
            emit("status", ok ? "旧游戏数据已清理，付款 QQ 登录已保留。" : "部分网页数据未清理成功，请重试。")
        }
    }


    private func openRecharge(_ body: [String: Any]) {
        let index = Int(number(body["index"]))
        let configs = store.configs()
        guard configs.indices.contains(index) else { return }
        let qq = body["qq"] as? String ?? ""
        guard let account = store.accounts()[qq], account.cookieSchema == 2, !account.cookieRows.isEmpty else {
            emit("status", "请重新扫码付款 QQ：保存的凭据不完整。"); return
        }
        let platform = body["browserPlatform"] as? String ?? ""
        guard platform == "ios" || platform == "android" else { emit("status", "请选择安卓或苹果。"); return }
        store.setBrowserPlatform(platform)
        var config: [String: Any] = ["title": configs[index].title, "type": configs[index].type, "url": configs[index].url,
                                     "browserPlatform": platform, "payerQQ": qq]
        if (body["action"] as? String) == "records" { config["purpose"] = "records" }
        let credential = body["credential"] as? String ?? ""
        Task { @MainActor in
            config["reusePayer"] = await WebSessionManager.shared.reusable(payerQQ: qq, source: account.cookieRows)
            buildPlan(config: config, credential: credential, saved: account.cookieRows) { [weak self] result in
                switch result {
                case .failure(let error): self?.emit("status", error.localizedDescription)
                case .success(let plan): self?.launch(plan)
                }
            }
        }
    }

    private func buildPlan(config: [String: Any], credential: String, saved: [CookieRow], completion: @escaping (Result<RechargePlan, Error>) -> Void) {
        guard let configText = jsonString(config), let savedText = jsonString(cookieRowsJSON(saved)), let credentialText = jsonString(credential) else {
            completion(.failure(WCError.message("页面准备失败。"))); return
        }
        let js = "(function(){try{return {ok:true,plan:SCLoginContext.build(\(configText),\(credentialText),\(savedText))};}catch(e){return {ok:false,error:String(e&&e.message||e)};}})()"
        panel.evaluateJavaScript(js) { value, error in
            if let error { completion(.failure(error)); return }
            guard let result = value as? [String: Any] else { completion(.failure(WCError.message("页面准备失败。"))); return }
            if (result["ok"] as? Bool) != true { completion(.failure(WCError.message(result["error"] as? String ?? "页面准备失败。"))); return }
            guard let p = result["plan"] as? [String: Any], let plan = self.decodePlan(p) else { completion(.failure(WCError.message("页面准备失败。"))); return }
            completion(.success(plan))
        }
    }

    private func launch(_ plan: RechargePlan) {
        guard let url = URL(string: plan.url), url.scheme == "https", isQQHost(url.host) else { emit("status", "链接格式错误。"); return }
        guard let account = store.accounts()[plan.payerQQ] else { return }
        Task { @MainActor in
            busy = true
            let reuse = await WebSessionManager.shared.reusable(payerQQ: plan.payerQQ, source: plan.sourceCookies)
            if reuse {
                _ = await WebSessionManager.shared.clearGameKeepingPayer(source: account.cookieRows)
            } else {
                await WebSessionManager.shared.clearAllWebsiteData()
            }
            busy = false
            let vc = RechargeViewController(plan: plan, reusePayer: reuse)
            vc.onRequestPayerScan = { [weak self] in guard let self else { return }; self.navigationController?.popToViewController(self, animated: true); self.startQR() }
            vc.onGameSessionCleared = { [weak self] in
                self?.emit("credential", "")
                self?.emit("status", "旧游戏数据已清理，付款 QQ 登录已保留，请填写新的游戏登录信息。")
            }
            navigationController?.pushViewController(vc, animated: true)
        }
    }

    private func decodePlan(_ p: [String: Any]) -> RechargePlan? {
        guard let url = p["url"] as? String, let payer = p["payerQQ"] as? String else { return nil }
        return RechargePlan(url: url, payerQQ: payer,
                            sourceCookies: decodeRows(p["sourceCookies"]), cookies: decodeRows(p["cookies"]),
                            userAgent: p["userAgent"] as? String ?? "", browserLabel: p["browserLabel"] as? String ?? "苹果",
                            warmupURL: p["warmupURL"] as? String ?? "", beforeWarmup: decodeRows(p["beforeWarmup"]),
                            deferCkInjection: p["deferCkInjection"] as? Bool ?? false,
                            ckParams: (p["ckParams"] as? [String: Any] ?? [:]).reduce(into: [String:String]()) { if let v = $1.value as? String { $0[$1.key] = v } })
    }

    private func decodeRows(_ any: Any?) -> [CookieRow] {
        guard let list = any as? [[String: Any]], let data = try? JSONSerialization.data(withJSONObject: list),
              let rows = try? JSONDecoder().decode([CookieRow].self, from: data) else { return [] }
        return rows
    }

    private func emit(_ event: String, _ value: Any) {
        guard let e = jsonString(event), let v = jsonString(value) else { return }
        panel.evaluateJavaScript("window.nativeEvent(\(e),\(v))", completionHandler: nil)
    }

    private func configsJSON(_ configs: [RechargeConfig]) -> [[String: String]] {
        configs.map { ["title": $0.title, "type": $0.type, "url": $0.url] }
    }

    private func cookieRowsJSON(_ rows: [CookieRow]) -> [[String: Any]] {
        guard let data = try? JSONEncoder().encode(rows), let obj = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return obj
    }

    private func jsonString(_ value: Any) -> String? {
        if value is String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]), let text = String(data: data, encoding: .utf8) else { return nil }
            return String(text.dropFirst().dropLast())
        }
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func number(_ value: Any?) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    private func isQQHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "qq.com" || h.hasSuffix(".qq.com")
    }

    private func showFatal(_ text: String) {
        let label = UILabel(); label.text = text; label.textAlignment = .center; label.numberOfLines = 0; label.frame = view.bounds; view.addSubview(label)
    }
}
