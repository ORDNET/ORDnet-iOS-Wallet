# Security fixes — ORD/browser, 13 August 2026

**Audit:** external GitHub review of 13 August 2026
**Supersedes:** every earlier copy of `ORDnet_WEB3_Browser.html`

This file had no tests and no mitigations. The review scored this repository
2/10 — the lowest in the organisation — and it was right to.

## Full origin breakout next to a key-holding wallet frame

**Was:**

```js
iframe.sandbox = 'allow-scripts allow-same-origin allow-downloads';
iframe.srcdoc  = preprocessHtmlContent(inscription.data);
```

`allow-scripts` together with `allow-same-origin` cancels the sandbox, and a
`srcdoc` document inherits the parent's origin. Arbitrary on-chain HTML —
inscribable by anyone for under a cent — therefore ran in the host origin, next
to the wallet iframe. From there: rewrite `localStorage[PLUGIN_STORE]` so the
wallet plugin points at an attacker URL and steal the key on the next unlock,
or simply

```js
walletFrame.contentWindow.postMessage({dir:'host2wallet', method:'pay', …})
```

This is the same bug the Chrome extension found, fixed and regression-tested in
`viewer.html` ("allow-same-origin is GONE, and it must stay gone"). It was never
ported here.

**Now:** `allow-same-origin` is absent from the content frame, which renders in
an opaque origin — its own scripts still run, but it has no access to this
document, its storage, or the wallet. `referrerpolicy="no-referrer"` added.

The wallet and tool frames keep `allow-same-origin`, and that is correct: they
load from their own https origin rather than from `srcdoc`, so the sandbox
grants them *their* origin, not ours. A comment now says so, because the next
reader will wonder.

## Attacker-controlled content type into innerHTML

`inscription.contentType` comes from the chain and went straight into
`innerHTML` in two places, while `escapeHtml()` sat unused twenty lines away.
Both call sites now use it.

## A permission screen that gated nothing

The install screen displayed `manifest.permissions`, stored them, and then
nothing ever consulted them: `perms` appeared nowhere else in 3016 lines. A
plugin declaring `wallet:read` received the full `host2wallet` RPC surface,
including `pay` and `sign`.

A permission screen that does not gate is worse than none — it manufactures
confidence. `METHOD_PERMISSION` now maps every RPC method to the permission it
requires, and the relay refuses anything the plugin did not declare. Unknown
methods fail closed to `wallet:write`, so a method added later cannot become
public by omission.

## Wallet replies broadcast to any window

Four `postMessage` calls used `targetOrigin: '*'`, including the path carrying
wallet RPC *responses* — which can contain an address or a signature. Replies
now go to the origin that actually asked, recorded per request id. The one
remaining `'*'` is the event broadcast to the sandboxed content frame, whose
origin is opaque by design; that path now carries only the fact that something
changed, never data.

## No CSP, no SRI

A Content-Security-Policy is now in the document: `script-src` limited to
`'self'` and two named CDNs, no `unsafe-eval`, `object-src 'none'`,
`base-uri 'none'`, `form-action 'none'`.

It does contain `'unsafe-inline'`, and that is worth stating plainly rather
than glossing: this file is one document whose entire logic is a single inline
`<script>`, so forbidding inline script would disable the application. The
policy therefore blocks remote script from unnamed hosts and blocks `eval`; it
does not block injected inline script. Extracting the script to a file with a
hash or nonce would close that, and is not done here.

The four CDN scripts carry `crossorigin` and `referrerpolicy`. The `integrity`
attributes are **deliberately not filled in**: an SRI hash must match the exact
bytes the CDN serves, and a wrong one silently blocks the script. Run
`bash tools/generate-sri.sh` and paste what it prints.

**On the on-chain copy:** those four remote scripts are what make the inscribed
version depend on the network, which sits awkwardly with the "no server of its
own" claim. They power the PDF, DOCX, XLSX and QR viewers only. Vendoring them
inline is the real fix and is not done here.

## Tests

```bash
node tests/structure-tests.mjs
```

18 structural assertions, in the style of the Chrome extension's suite: no
`srcdoc` frame may carry `allow-same-origin`, the content type must be escaped,
the CSP must contain no `unsafe-eval`, no fabricated SRI hash may ship. These
fail if a later edit undoes any of it — which is exactly how this bug survived
in the first place.
