# ORD/browser — the ORDnet Web3 Browser

A complete web3 browser in **one HTML file**: type `name.web3` and browse
on-chain sites, files, and apps served straight from the BSV blockchain —
tabs, history, a viewer for on-chain PDF/Word/Excel/image/audio/video
content, an app launcher for the on-chain ORDnet tools, QR sharing, and a
developer mode. No install, no build, no server of its own: open the file
and you're browsing the chain.

**The browser itself lives on-chain.** This exact application is inscribed
on the BSV blockchain as 1Sat Ordinals — the code has been fully public
from day one by construction. This repository is its official,
discoverable home: the canonical source, published by its author.

## Try it

1. Download `ORDnet_WEB3_Browser.html`.
2. Open it in any modern browser (desktop or mobile — it installs as a
   home-screen web app on iOS/Android).
3. Type a web3 name — `ordnet.web3` — and go.

## What's inside

- **Name resolution** for the recognised TLD set (`web3, bitcoin, crypto,
  blockchain, ordnet` + resolve-only `bsv, bitcoinsv`), per the ODNCA
  standards ([ODNCA-standards](https://github.com/ORDNET/ODNCA-standards)).
- **On-chain content loading** — sites and files are 1Sat Ordinals
  inscriptions, fetched by txid and rendered in the browser: HTML, images,
  PDF, Word, Excel, audio, video.
- **Browser chrome** — tabs, history, bookmarks-style app grid, light/dark
  theme, security indicator, QR sharing of any on-chain address.
- **On-chain app launcher** — the ORDnet tool family (HTML creator,
  inscribers, QR generator, …), each itself an on-chain app opened by
  inscription id.
- **Developer mode** — inspect what you're looking at: txids, outpoints,
  content types.

Public chain data arrives via WhatsOnChain and the ORDnet content router;
both are configuration in the file's constants, not trust — the content is
addressed by txid, so what loads is what was inscribed.

## License

**Source-available, not open source.** The code is published here (and
permanently on-chain) for transparency and audit — read it, verify it,
learn from how it works — but copying, modification, redistribution, and
use in other products require written permission from ORDnet. See
[LICENSE](LICENSE).

## Related

- [ORDnet-Chrome-Wallet](https://github.com/ORDNET/ORDnet-Chrome-Wallet) — ORD/plug, the companion wallet extension
- [ODNCA-standards](https://github.com/ORDNET/ODNCA-standards) — the naming standards this browser implements
- [ORDnet-SNS-client](https://github.com/ORDNET/ORDnet-SNS-client) — the standalone resolution library (MIT) for building your own
