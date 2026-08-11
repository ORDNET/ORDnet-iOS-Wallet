# Security fixes — external audit of 11 August 2026 (iOS wallet)

**Released in:** v2.7.0 (build 18)
**Audit date:** 11 August 2026

Findings H4 and H5 from the 11 Aug 2026 external audit, the H7 gap, and the
Android↔iOS drift items where iOS lagged the Android behaviour.

## H5 — JS injection via the scroll-to-fragment path

After a web3 navigation, `BrowserView.swift` scrolled to a page-supplied
fragment by interpolating it **raw** into a single-quoted JS string that was
then run with `evaluateJavaScript`. The fragment comes from a page-posted
`ordnetNavigate` message, so a `'` in it closed the string and ran arbitrary JS
in the page's origin (address spoofing on the next `ordplug.pay`, cross-origin
script execution). Android escaped this; iOS did not.

**Fix.** The fragment is escaped (`\`, `'`, U+2028, U+2029) before
interpolation. In addition, the `__brc100Deliver` / `__ordplugDeliver` payloads
now escape U+2028/U+2029 — legal in JSON but illegal inside a JS string literal
— matching what Android already did.

## H4 — BRC-100 originator was taken from the page

`handleBrc100Message` trusted `body["originator"]`. Grants and daily budgets key
on `address|origin|level|protocol`, so a page could impersonate a trusted
dApp's origin and inherit its grants. The `window.ordplug` path already used the
native `currentOrigin`.

**Fix.** The BRC-100 path uses `currentOrigin` and ignores the page-supplied
field.

## H7 — listActions / listOutputs / relinquishOutput were ungated

These three BRC-100 methods ran with no permission check: full history leak,
full UTXO leak, and a loopable, silent `relinquishOutput` that could brick the
wallet's spendability.

**Fix.**

- `listActions` / `listOutputs` now require an explicit **per-origin read
  consent** (persistent grant, revocable in Settings).
- `relinquishOutput` requires a **fresh Face ID / passcode confirmation per
  call**, naming the outpoint, after the outpoint is validated as owned.

## Android↔iOS drift (iOS brought up to Android's behaviour)

- **`removeAccount`** handled the removed-active case but not "an account
  before the active one was removed", so removing an earlier account silently
  switched the wallet to a different account's keys. Now matches Android.
- **`removeWallet`** wiped the address book and inscription log but left the
  BRC-100 stores behind (grants, action log, relinquished outpoints), so they
  could be inherited by the next wallet on the device. It now clears every
  BRC-100 store plus chain tips / spent-guard and cancels pending requests.
- **One approval sheet at a time.** A second provider request silently replaced
  the first, orphaning its callback until the dApp timeout. iOS now rejects the
  newcomer, as Android did.
- **Registry reachable-vs-empty.** `Api.listings()` returned `[]` for both an
  unreachable and a genuinely empty registry, so `registryDistricts()` leaned
  on a different endpoint's health flag and could misread a failed fetch as
  "empty". `Api.listings()` now returns `nil` when unreachable and the district
  check uses that directly.
