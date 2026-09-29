# WC Recharge iOS (WKWebView local build)

This project is a native iOS port of the supplied Android WC source. It uses only bundled local HTML/JavaScript for the control panel and Apple's WKWebView for Tencent pages.

## Implemented flow

- Local CK input; the CK text is not written to UserDefaults, Keychain, files, analytics, or logs.
- QQ payer session QR login using Tencent QQ endpoints, then cookie rows are transferred locally into WKWebView.
- Normal Tencent rebate links: CK is merged into the entry URL immediately.
- Xinyue and `scp.qq.com/payr/jump.html`: preserve the original entry URL, establish Xinyue state first, and only merge CK when the redirect reaches `pagedoo.pay.qq.com`.
- Same default `WKWebsiteDataStore` is shared by recharge WebViews.
- Before payment, the app checks the selected payer QQ against payer cookies and attempts to read explicit payment-QQ / role / server labels from the Tencent page. If the payment QQ is different, the page is stopped.
- “换号清理” removes game/order WebKit state while retaining the payer session. Selecting/rescanning a different payer performs full WebKit data clearing.
- If Tencent page text contains a transaction-risk warning, app-driven automatic retry/injection stops and the warning is shown as-is.
- No ChatGPT-hosted page, proxy, or third-party relay is used.

## Build/sign on a Mac

1. Open `WCRechargeIOS.xcodeproj` in Xcode 16 or newer.
2. Select target `WCRechargeIOS` → Signing & Capabilities.
3. Choose your Apple Development team and change Bundle Identifier if your account requires it.
4. Connect the target iPhone, select it as the run destination, and Run.
5. For an IPA, use Product → Archive → Distribute App, then export with your valid signing profile.

## Required real-device verification

The source package was produced in a Linux build environment. It has static source/JavaScript checks, but it has **not** been compiled by Xcode, Apple-signed, installed on an iPhone 18, or verified against live Tencent normal/Xinyue/SCP/QR flows. Do not treat any unsigned archive as a tested IPA.
