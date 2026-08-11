# Changelog — ORD/net Wallet for iOS (ORDplug iOS)

All notable changes to the iOS app, reconstructed from the 30 archived build
ZIPs in the `ORDPLUG iOS V1` and `ORDPLUG iOS V2` folders (v1.0 → v2.6.2),
based on each build's bundled release notes and cross-checked against the code.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Dates are build dates taken from the archive files.

> Archive notes: `ORDplug-iOS-v1.3_1.zip` is byte-identical to
> `ORDplug-iOS-v1.3.zip` (duplicate). `ORDplug-iOS-v2.0.0.zip` appears in both
> the V1 and V2 folders (same file). There is no v1.9.1 build in the archive.
> The iOS app tracks the Chrome extension and shares its JavaScript crypto
> engine; several releases are explicit parity ports of extension versions.

---

## [2.6.2] — 2026-08-06 (build 17)

### Changed
- Upload: the "Selected" section (preview, compression, fees and the Inscribe
  button) now sits directly under "Pick a file to inscribe" instead of below
  the "Or type it directly" editor — pick photo → inscribe is the common
  route. "Upload this text" auto-scrolls to the section, so the typed-text
  flow keeps working identically. Engine untouched (69/69 + 12/12 tests).

## [2.6.1] — 2026-08-06 (build 16)

### Fixed
- Wallet ↔ Domains inconsistency: a domain listed for sale via the Domains tab
  (v2 domain registry, USD) showed plain "held" in the SNS holdings — these
  are two separate marketplaces and the holdings only knew the ordinal
  listings (sats). Domain-registry listings are now merged when holdings load:
  green "For sale · $X" pill, counted in the "For sale" tab, and the row menu
  links to "Manage domain listing". Deliberately no second (ordinal) listing
  for a domain already on the domain registry.
- Upload: the success message after an inscribe existed in the code but was
  never visible (it lived in the file-selection section that is cleared right
  after success). Now a persistent "Inscribed successfully ✓" section with the
  full TXID (one tap = copy) and a pointer to the ORD/ner tab.
### Changed
- ORD/ner detail: one tap on TXID / Origin / Current UTXO copies the full
  value (long-press used to copy the truncated display text), with an inline
  "copied ✓" confirmation; new "Copy TXID" button between "Open in Browser"
  and the renamed "Copy all info".

## [2.6.0] — 2026-08-05 (build 15)

BRC-100 phase 3: money + grants management.

### Added
- `createAction` (outputs-only): toolbox-conform validation in the engine
  (custom inputs/inputBEEF, noSend, sendWith, signAndProcess:false and baskets
  refuse explicitly with standards-shaped `WERR_*` errors), build via the
  existing proven buildTx path (ordinal-protected UTXOs, service fees, dynamic
  fee, change), BRC-100 randomizeOutputs, broadcast via the chain mechanism,
  local action log per address.
- Money ≠ grant: every transaction gets its own native confirmation sheet with
  Face ID — destination(s), amount (sats/BSV/USD), miner fee and service fees;
  Reject returns a clean `WERR_PERMISSION_DENIED`. Never persistent — every
  transaction confirms again.
- `internalizeAction` (AtomicBEEF parsed by the extended SDK bundle; only
  'wallet payment' outputs that pay the wallet address directly; own
  confirmation sheet), `listOutputs` (live ordinal-protected UTXO set,
  'default' basket, pagination), `listActions` (local action log),
  `relinquishOutput` (outpoint persistently excluded from funding).
  `signAction`/`abortAction` refuse explicitly until the signable-transaction
  path really exists. Nothing the wallet doesn't track is answered with a
  silently empty list.
- Grants manager in Settings ("BRC-100 permissions"): inspect and revoke
  phase-2 grants per app; revoking simply means the app asks again next time.
### Changed
- The bundled BSV SDK regenerated with extra exports (Transaction, Beef,
  MerklePath, P2PKH) for BEEF support; phase-2 vectors unchanged green.
### Tests
- Engine tests 51 → 69; provider detection test 12/12.

## [2.5.2] — 2026-08-05 (build 14)

### Fixed
- Setting the content target (TXID) on a root domain always failed with
  `invalid_domain`, while subdomains and routes accepted the same domain
  string. Cause: `setDomainTarget()` was the only registry write that never
  moved to the shared signed-post path when the Domains tab moved to the v2
  platform — the v2 handler identifies the domain by the platform's canonical
  `name` field, so the old `domain` key fell through as an empty name. The app
  now sends `name` (keeping `domain` for compatibility); same fix for "Remove
  target". This corrects the v2.5.1 note that called it a server-side issue —
  it was an app bug; the registry behaved correctly.

## [2.5.1] — 2026-08-05 (build 13)

### Fixed
- Stuck keyboard: the numeric keyboards (vout, prices, UTXO counts) have no
  return key on iPhone and there was no other way out. Every affected screen
  now has a "Done" bar above the keyboard plus swipe-down-while-scrolling to
  dismiss.

## [2.5.0] — 2026-08-04 (build 12)

BRC-100 phase 2: keys & crypto behind native permission grants.

### Added
- getPublicKey (incl. the identity key), encrypt, decrypt, createSignature,
  verifySignature, createHmac, verifyHmac — executed by the bundled BSV SDK
  ProtoWallet inside the JavaScriptCore engine (BRC-42/43 conform); key
  material never reaches the page and is wiped from the engine on lock.
- Permissions follow BRC-43 grants: level 0 open, level 1 one persistent grant
  per app per protocol, level 2 additionally per counterparty; the identity
  key has its own per-app grant. First use shows a native SwiftUI sheet
  (outside the page's reach) with Face ID on Allow; Deny returns a
  `WERR_PERMISSION_DENIED` rejection.
### Tests
- Engine suite 51/51; full-chain test 12/12 with the real WalletClient
  (deny path, allow path, unchanged phase-1 + error contract).

## [2.4.0] — 2026-08-04 (build 11)

BRC-100 phase 1: the wallet is detectable.

### Added
- The wallet now speaks the BRC-100 wallet-to-application interface as a
  provider, next to the existing ORDnet provider (untouched). A key-free
  `window.CWI` shim — the first substrate the BSV SDK's WalletClient('auto')
  probes — is injected into every page; all 28 methods exist on it.
- Phase 1 implemented (informative, no keys, no money): getVersion,
  getNetwork, getHeight, isAuthenticated / waitForAuthentication. Every other
  method fails explicitly with a standards-shaped WalletError delivered as a
  promise rejection — never a resolved error object; the two privacy-sensitive
  linkage methods carry their own explicit refusal.
- The BSV SDK is bundled into the engine (proven in Apple's own JavaScriptCore
  before landing), ready for phase 2. Keys stay in the engine, never in the
  page — the shim only relays messages.
### Tests
- New provider-detection suite runs the real WalletClient('auto') against the
  app's actual shim (8/8); engine tests 46/46.

## [2.3.2] — 2026-08-04 (build 10)

### Changed
- The bottom bar is the untouched native Apple TabView again, with exactly
  five tabs: Wallet · Browser · Domains · Upload · ORD/ner. Settings and the
  UTXO tools moved to the Wallet screen's top bar (settings first, then UTXO,
  top-left; the lock stays top-right) — the user's layout.
### Fixed
- "Open in Browser" from ORD/ner also works when the Browser tab was never
  opened yet.

## [2.3.1] — 2026-08-04 (build 9)

### Fixed
- v2.3.0 imitated the bottom bar with custom buttons and deviated from the
  v2.2 style. Replaced by the genuine iOS UITabBar (the same UIKit control
  SwiftUI rendered in v2.2) inside a scroll view — icons, fonts, colors and
  spacing identical to v2.2 by construction; swiping left reveals UTXO and
  Settings.

## [2.3.0] — 2026-08-04 (build 8)

### Added
- ORD/ner tab: the on-chain file browser, native. Accounts are folders; a
  folder shows every inscription the address currently holds (1Sat index,
  paged up to 500) with grid/list view, thumbnails and type icons. File
  detail: preview, TXID/origin/current-outpoint with copy, "Open in Browser",
  "Copy TX info" and "Send" via the existing 1-sat transfer. Index down →
  degrades inline to the app's own inscription log. "Inscribed with this
  wallet" moved from Upload to ORD/ner, with a "sent" label + hide toggle for
  items no longer held.
- UTXO tools tab: split (N × X sats to your own address, 2–200, live
  validation) and combine (all spendable UTXOs → one output), both on the
  ordinal-protected set and both with the standard service fees.
- Chain mechanism app-wide: after every broadcast the wallet registers its own
  change/split outputs as immediately-spendable chain tips and guards the
  inputs it just spent — Send, Inscribe, ordinal transfers and the UTXO tools
  run back-to-back without "no spendable UTXOs". Tips persist per address, are
  validated on unlock/account switch, and a mempool conflict drops the local
  chain with an inline retry message. 1-sat outputs are never chain tips.
### Changed
- Custom, horizontally swipeable bottom bar with 7 tools (5 visible).
### Tests
- Engine: buildConsolidate + txSpendInfo, 44/44 green.

## [2.2.3] — 2026-08-03 (build 7)

### Fixed
- False `stale_outpoint` refusals on busy holder addresses: the old check
  looked the outpoint up in the holder address's unspent list, which the block
  explorer silently truncates for busy addresses. New primitive: query the
  outpoint's spent-status directly — spent / unspent / unknown, where unknown
  is never reported as "spent". SNS payments proceed on unknown with an inline
  note (the signed resolver answer is the authority); OpNS payments fail
  closed with an honest "could not verify — try again".

## [2.2.2] — 2026-08-03 (build 6)

### Changed
- No separator between the two holdings picker bars and half the gap.

## [2.2.1] — 2026-08-03 (build 5)

### Fixed
- Picker rounding: each segmented bar is its own list row again (the shared
  row in v2.2.0 clipped the top bar's rounding).
### Changed
- Row order per user request: row 1 SNS + OpNS, row 2 BSVmaps + For sale.

## [2.2.0] — 2026-08-03 (build 4)

### Added
- Paying to SNS names from Send: type `name.tld` or `mailbox@name.tld` and the
  wallet resolves it via the signed SNS resolver at level "prove" — the
  resolver's ECDSA signature is verified against a pre-pinned key inside the
  existing JS engine (both specification test vectors enforced in the test
  suite, incl. a 9-way field-mutation test); the pay-to address is derived
  from the signed holder script (the unsigned address field is never trusted);
  the 300-second expiry is enforced and the outpoint is checked unspent right
  before broadcast; two-tap confirm re-resolves at signing so a name sold in
  between is refused. Unknown mailbox (fallback) is shown inline, not an
  error; resolver errors arrive with readable inline messages; the TLD list is
  never hardcoded.
- Key rotation: an unknown signer triggers a cryptographic verification of the
  succession-deed chain from the pinned key; only a closing chain re-pins —
  a broken or tampered chain is refused and the pin stays.
### Changed
- Holdings picker on Home is now two stacked segmented bars (user design) with
  full labels and counters.
### Security
- Recognition strictly separated: dotted names → SNS resolver, bare names →
  OpNS, anything else with @ → inline paymail refusal; ASCII-lowercase input
  by construction, so homograph strings never reach a payment path.

## [2.1.0] — 2026-08-03 (build 3)

### Added
- OpNS names as third holdings category: new "OpNS" segment on Home — bare
  names (no TLD) from the OpNS index, deliberately without the ✓ mark
  (reserved for ORDnet's own inscriptions). Its own status flag and error
  handling: a broken OpNS API only affects the OpNS tab. Sending an OpNS name
  is the existing 1-sat ordinal transfer, with an inline warning that a
  paymail binding expires on transfer.
- Paying **to** an OpNS name from Send under four hard rules: exact match only
  (a fallback answer becomes an inline "did you mean …?" error, never a
  payment); the outpoint is checked unspent right before broadcast; the holder
  address is recomputed from the outpoint's on-chain locking script and must
  equal the index's claim; paymail forms are rejected as payment target.
  Two-tap confirm always shows the exact name + verified holder address.
- No marketplace flows for OpNS (deliberately absent); display, resolve and
  send only.

## [2.0.0] — 2026-07-24 (build 2) — release candidate

### Changed
- Domain management and the .web3 resolver now use the ORDnet v2 platform's
  main production domain (previously the staging alias, which keeps working).
- SNS names and BSVmaps lists got pagination (20 per page) with a pager bar
  above the list — the exact pattern of the Chrome extension; "For sale"
  intentionally stays unpaged.
- All documentation rewritten in English for App Store submission.

## [1.10.0] — 2026-07-21

### Changed
- The Domains tab (registry list, whois, set-target, subdomains, routes,
  marketplace, transfer) moved from the old central registry to the ORDnet v2
  platform — same signed registry actions, verified 1-to-1 against the v2
  server.
### Added
- Domains tab search field + pagination (10 per page) in the SNS-list pattern.

## [1.9.2] — 2026-07-17

### Changed
- Bundle identifier changed (wallet → browser identity), incl. Keychain
  service and engine-queue label. Note: a new bundle ID is a new app on iOS —
  existing test installs do not keep their wallet; re-import from the recovery
  phrase/WIF.

## [1.9.0] — 2026-07-17

Review hardening — external code review processed.

### Fixed
- Crash fix in the web3 scheme handler: stopped scheme tasks are tracked and
  checked before every callback — navigating away quickly during a load can no
  longer crash the app.
- Camera permission denied is no longer a black screen: explicit authorization
  check with inline explanation and an "Open Settings" button.
- The SNS link in holdings no longer force-unwraps a URL — names with odd
  characters cannot crash; the link hides itself if the URL cannot be built.
### Changed
- Caches bounded: tx-hex cache and web3-content cache each 64 MB max, items
  over 16 MB are not cached, FIFO eviction.
- Removing the wallet now also clears the address book and inscription log —
  nothing is left behind.
### Added
- A single marketplace feature flag that hides every buy/sell flow in case App
  Review objects — viewing holdings keeps working.

## [1.8.0] — 2026-07-16

### Fixed
- Browser: subdomains of the project's own web2 domain (api, mail, swap, …)
  now load correctly as websites — the web3-TLD detection accidentally matched
  a TLD inside the hostname; the TLD must now be exactly the last host label.
- Upload: staged inscriptions no longer fall out of view — the app dismisses
  the keyboard, auto-scrolls to the staged inscription and shows "Staged
  below ✓".
### Added
- Upload: image compression with a slider (JPEG/PNG sources, quality 10–100%,
  live "original → compressed" size; GIF/WebP untouched; compression can never
  make the file bigger).
### Changed
- All amounts and fees displayed in BSV (with sats sublines); unlock text
  mentions the passcode fallback.

## [1.7.1] — 2026-07-16 — App Store submission prep

### Changed
- Keychain: deprecated APIs replaced — the build is now 0 warnings, 0 errors.
- Privacy manifest added (no tracking, no data collection); export compliance
  declared (standard, exempt encryption only); marketing version aligned.

## [1.7] — 2026-07-16

### Changed
- Every button capsule-shaped (the ORDnet signature); browser app catalog on a
  fixed 3-column grid with equal card sizes.
- Full app list in the catalog (domains, app, mail, search, whois, templates,
  nodes, api, swap, clawd + new mcp); all catalog links point to the regular
  web addresses.

## [1.6] — 2026-07-16

### Fixed
- Compile fixes: invalid SwiftUI Section syntax replaced (3 errors) and
  lock usage in async context replaced by synchronous helpers (5 warnings).

## [1.5] — 2026-07-16

### Added
- Upload tab "Or type it directly": editor for HTML/code/text with a Text/HTML
  toggle that sets the ordinal envelope's content type, live size/cost
  indication.
### Changed
- All secondary buttons: brand beige background with black outline (inverted
  in dark mode).

## [1.4] — 2026-07-16

### Changed
- App renamed to ORD/net (Wallet) everywhere; technically unchanged bundle ID,
  Keychain service and `window.ordplug` dApp API for compatibility.
### Added
- Fifth tab Upload: inscribe images (JPEG/PNG/GIF/WebP), text and HTML files
  as 1Sat Ordinals — identical envelope, OP_RETURN and fees as the web tools,
  100 MB limit.
- Per-wallet inscription history: every TXID made through the app, newest
  first, tap → explorer, long-press → copy.

## [1.3] — 2026-07-14

### Changed
- App icon taken exactly from the extension's original 128px icon: vectorized
  and rendered at 1024×1024 on the measured original brand beige — nothing
  redrawn. (The archive's `v1.3_1` ZIP is an identical duplicate of this
  build.)

## [1.2] — 2026-07-14

### Changed
- Bulk mode now shows the extension's message explaining why SNS cannot be
  bulk-listed yet; first app icon added (replaced in v1.3).

## [1.1] — 2026-07-13

### Changed
- Send/Receive/History: equal button widths, icon above text, programmatic
  navigation without list chevrons; brand beige as the background throughout
  the app (with a dark-mode counterpart).
### Added
- Browser supports web2: regular domains load as websites, loose text becomes
  a search; .web3/TXID stays on-chain; own back/forward + swipe for web2.

## [1.0] — 2026-07-13

Full native port of the Chrome extension (V3.4).

### Added
- 100% SwiftUI UI; crypto engine = the extension's original JS engine running
  in JavaScriptCore (no WebView wrapper) — fees and transactions
  byte-identical to the extension.
- Wallet: create (BIP39), import (BIP44 / legacy / WIF / wallet presets incl.
  PIN-based, with address preview), multi-account, backup reveal.
- Send with safety layer, QR scanner, address book, send-max; Receive with QR;
  History.
- Holdings (SNS/BSVmaps/For sale), ordinal transfer with ownership check and
  local verification, marketplace list/delist/bulk with trust-but-verify and
  self-heal.
- .web3 domain management (set-target, subdomains, routes, marketplace,
  transfer) — signed in the exact registry message format.
- ORDnet browser with a native scheme handler as the service-worker
  replacement, security scanner, app catalog; `window.ordplug` dApp provider
  with native approval sheets.
- Keys in the Secure Enclave Keychain with Face ID; engine verified with 28/28
  tests (BIP44/Trezor vectors, simulated chain, all tx builders).
