# ORDnet Wallet — iOS app (v2.7.0)

Full native iOS version of the **ORDnet Web3 Browser / ORD/net Wallet**
(originally the ORD/plug Chrome extension). Not a wrapper: the entire UI is
SwiftUI; the crypto engine (`bsv.min.js` + `wallet-core.js`) runs invisibly
inside Apple's JavaScriptCore.

On the engine: `wallet-core.js`, `bsv.min.js` and `bsv-sdk-bundle.js` are
**byte-identical to the Android app's copies**, and the two vendored libraries
are byte-identical to the Chrome extension's as well. The extension does not
use `wallet-core.js` — its wallet logic is a separate implementation in
`src/wallet.js`. So transactions built here are byte-for-byte identical to the
Android app's; against the extension the shared ground is the vendored
libraries and a common set of conformance vectors, not the same file.

## Requirements

- Xcode 16 or newer (the project uses filesystem-synchronized groups)
- iOS 17.0+ (iPhone and iPad)
- Apple Developer account (paid, or a free Apple ID) to run on a device

## Build & run

1. Open `ORDplug.xcodeproj` in Xcode.
2. Select the **ORDplug** target → **Signing & Capabilities** tab → pick
   your **Team** (Xcode manages the provisioning profile automatically).
3. Choose your iPhone (or a simulator) as the run destination and hit **⌘R**.

> Bundle identifier: `io.ordnet.browser` — register this App ID in your
> Apple Developer account / App Store Connect.

## Architecture

| Layer | Technology | Origin |
|---|---|---|
| UI | 100% native SwiftUI | new, 1-to-1 port of the wallet.html/viewer.html flows |
| Crypto engine | `bsv.min.js` + `wallet-core.js` in JavaScriptCore (no WebView) | **byte-identical to Android**; shares the vendored libraries and conformance vectors with the extension |
| Key storage | iOS Keychain (Secure Enclave) + Face ID | replaces the PBKDF2/AES-GCM password vault |
| Networking | URLSession (WhatsOnChain, bsvmap.io, domains.ordnet.io) | same endpoints, incl. 429 backoff and tx-hex cache |
| .web3 browser | WKWebView + WKURLSchemeHandler (`ordweb3://`) | replaces the service-worker router (sw.js) |
| dApp API | `window.ordplug` provider via WKUserScript + native approval sheets | same method set as inpage.js |

Domain management and the .web3 resolver talk to the ORDnet v2 platform on
its main domain **domains.ordnet.io** (since v2.0.0).

## Features (parity with the extension)

- Upload & Inscribe tab: inscribe images, text and HTML files on-chain
  (1Sat Ordinal, identical to the ORDnet HTML tools, 100MB max) with a
  per-wallet TXID history
- Wallet create (BIP39, 12 words) and import: BIP44, legacy V9, WIF, plus
  wallet presets (RelayX, Yours/Panda, Twetch, Money Button, Simply Cash,
  ElectrumSV, HandCash 1.x, Centbee incl. PIN, Edge, custom path) with
  address preview
- Multi-account: add (generate/import), rename, switch, remove,
  backup reveal (Face ID-gated; phrase kept in session memory only, like
  the extension)
- Send BSV with a safety layer: first-time-address warning, near-max
  warning, self-send detection, clipboard verification, send-max,
  QR scanner, address book
- Receive with QR, history via WhatsOnChain, balance + USD rate
- Holdings: SNS names & BSVmaps (ORDnet V30 indexer) with tabs, search,
  listed status + price (registry merge) — and since v2.0.0 pagination
  (20 per page) with a pager bar in the exact Chrome-extension pattern
- Ordinal transfer: true 1Sat transfer with ownership check, raw-script
  fetch (never the verbose endpoint) and local input verification before
  broadcast
- Marketplace: list (SIGHASH_SINGLE|ANYONECANPAY atomic swap), delist,
  bulk list/delist (300 max) — all with trust-but-verify checks on both
  server stores and self-heal for stuck listings
- .web3 domains: registry list with search + pagination, whois,
  set-target, subdomains, routes, marketplace (USD), transfer — every
  action signed in the exact `ordnet-registry|…` format
- ORDnet browser: .web3/TXID navigation, on-chain content rendering
  (HTML/image/video/audio/text), internal link router, security scanner,
  app catalog (ORD/domains, ORD/mail, ORD/app, ORD/clawd; ORD/swap is
  intentionally excluded from the iOS build per App Review guideline
  3.1.5(b))
- dApp provider: connect, getAddress, getPublicKey, getBalance, pay,
  inscribe, signMessage, purchase (ORDPAY), listOrdinal, buyOrdinal,
  sendTx (350 outputs max) — with native approval sheets and
  connected-sites management
- Service fees (3,996 sats across 11 addresses) and fee rate
  (0.15 sat/byte) identical to the extension
- Auto-lock (5/15/60 min or never), lock button, wallet removal with
  double confirmation

## Verification

The JS engine is tested against known test vectors (BIP44/Trezor,
WIF→address) and a simulated chain: send, inscribe + parser round-trip,
ordinal transfer (incl. rejected foreign key), listing partial + purchase
(incl. rejected price mismatch) and composed sendTx. See
`Tests/engine-tests.mjs` — run with:

```
node Tests/engine-tests.mjs
```

## App Store submission

- Version: 2.0.0 (see `CHANGELOG.md` for the full history v1.0 → v2.0.0)
- `PrivacyInfo.xcprivacy` present (no tracking, no data collection,
  UserDefaults/CA92.1)
- Export compliance pre-answered (`ITSAppUsesNonExemptEncryption = NO`)
- Build is 0 errors / 0 warnings (deprecated Keychain APIs replaced in
  v1.7.1)
- Required in App Store Connect: privacy policy URL, App Privacy
  questionnaire ("Data Not Collected"), age rating, and review notes with
  a test wallet
- Note: crypto apps must be submitted from an **Organization** developer
  account (Apple guideline 3.1.5(b)), not an individual account

## Security notes

- Keys live exclusively in the Keychain with `WhenUnlockedThisDeviceOnly`
  + user presence: no iCloud sync, no backup extraction, Face ID/passcode
  required on every unlock and on backup reveal.
- Recovery phrases are never stored on disk — only the WIF (encrypted);
  phrases live in RAM for the session only.
- All errors are shown inline in the UI; the app never uses blocking
  alerts.

## Tests

`Tests/engine-tests.mjs` runs the full crypto-engine suite (69 tests) on plain
Node. `Tests/brc100-detect-test.mjs` additionally requires `npm i @bsv/sdk`.

## License

Source-available — see [LICENSE](LICENSE). The code is published for
transparency, security review and audit. Copying, modification,
redistribution, or app-store submission is not permitted without written
permission from ORDnet.

Copyright (c) 2026 ORDnet / ODNCA
