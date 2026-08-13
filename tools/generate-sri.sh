#!/usr/bin/env bash
# Generate Subresource Integrity attributes for the four CDN scripts.
#
# SRI hashes must match the exact bytes the CDN serves, so they cannot be
# written by hand or guessed — a wrong hash makes the browser refuse the
# script, and the PDF/DOCX/XLSX/QR viewers stop working.
#
# Usage:  bash tools/generate-sri.sh
# Then paste each printed integrity="..." into the matching <script> tag in
# ORDnet_WEB3_Browser.html.
set -euo pipefail

urls=(
  "https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js"
  "https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js"
  "https://cdnjs.cloudflare.com/ajax/libs/mammoth/1.6.0/mammoth.browser.min.js"
  "https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js"
)

for u in "${urls[@]}"; do
  hash=$(curl -sfL "$u" | openssl dgst -sha384 -binary | openssl base64 -A)
  echo ""
  echo "$u"
  echo "  integrity=\"sha384-${hash}\""
done

echo ""
echo "Re-run this whenever a pinned version changes."
