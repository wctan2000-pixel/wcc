# Static verification report

Generated from the supplied Android WC source package.

## Preserved / implemented

- `Resources/login-context.js` is byte-for-byte identical to the supplied Android `login-context.js`.
- Normal Tencent recharge links merge the supplied CK into the entry URL immediately.
- `scp.qq.com/payr/jump.html` and direct Xinyue entry links keep the original entry URL first, warm the Xinyue session in the same WebKit data store, and defer CK merging until the final `pagedoo.pay.qq.com` URL.
- CK input is not written by this app to UserDefaults, Keychain, files, analytics, or logs. It is only held in the local control page/runtime and sent to the selected Tencent QQ destination as required by the original flow.
- Payer QQ login rows are stored locally in iOS Keychain; WKWebView uses one shared `WKWebsiteDataStore` for the recharge session.
- Payer QQ cookie identity is checked against the selected QQ. An explicit payment-QQ mismatch stops the page.
- Role/server/payment-QQ labels are inspected from the Tencent page for pre-payment checking; when automatic extraction is unavailable the UI tells the user to verify the Tencent page manually.
- Switching payer QQ / rescanning performs a full WebKit website-data clear before the next payer session. “换号清理” removes game/order WebKit state while retaining the verified payer login.
- If Tencent page text contains a transaction-risk warning, the app keeps the Tencent page visible, surfaces the matched warning line, and stops app-driven retry actions.
- No ChatGPT-hosted page, proxy, relay, or third-party forwarding service is included.

## Checks run in this environment

- Swift syntax parse: PASS (`swiftc -parse`; Linux Swift 6.2.1)
- `Info.plist`: PASS (`plutil -lint`)
- Xcode `project.pbxproj`: PASS (`plutil -lint`)
- Login/link JavaScript offline tests: PASS, 15 cases including 100 alternating payer accounts
- Android and iOS `login-context.js`: byte-for-byte identical

## Not verified here

This environment has no macOS/Xcode toolchain, Apple Development/Distribution certificate or provisioning profile, and no iPhone 18 attached. Therefore this package has NOT been:

- compiled with Xcode,
- Apple-signed,
- exported as a valid installable IPA,
- installed on an iPhone 18,
- live-tested against Tencent normal links, Xinyue, SCP, QQ scan-login, or payer switching.

Do not treat an unsigned IPA produced outside Xcode/signing as a tested deliverable.
