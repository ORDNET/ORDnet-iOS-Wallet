# Security fixes — ORDnet iOS Wallet v2.7.1

**Audit:** external GitHub review of 13 August 2026
**Supersedes:** v2.7.0 (build 18)

## One discarded return status in the only entropy source

```swift
var bytes = [UInt8](repeating: 0, count: max(0, count))
_ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)   // status ignored
return bytes.map { String(format: "%02x", $0) }.joined()
```

This block backs `crypto.getRandomValues` inside JavaScriptCore, and through it
`entropyToMnemonic()` and `PrivateKey.fromRandom()`. It is the only source of
randomness in the app.

If the call fails, `bytes` stays all-zero and the user receives — with no error,
no warning, nothing on screen — the all-zero seed: the wallet whose mnemonic is
`abandon abandon … about` and whose private keys are public knowledge. Silent,
catastrophic, irreversible.

**Now:**

```swift
guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
    fatalError("CSPRNG unavailable — refusing to generate key material")
}
```

Crashing is the only acceptable behaviour here. A wallet that cannot obtain
randomness must not produce key material. This is the single most serious
finding in the review and the smallest fix in this release.

Checked: it is the only `SecRandomCopyBytes` call in the codebase.

## Still open

Native test coverage. The 69 tests in `Tests/` are all JavaScript engine tests;
there are no XCTests, so the vault, the biometric flow, the WebView bridges and
origin handling — where the bugs actually live — have no automated coverage.
Tracked as an issue.
