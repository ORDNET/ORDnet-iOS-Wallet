// Structurele regressietests op het HTML-bestand zelf.
import fs from 'node:fs';
const s = fs.readFileSync(process.argv[2] || 'ORDnet_WEB3_Browser.html','utf8');
let pass=0, fail=0;
const t=(n,c)=>{ c?(pass++,console.log('  ✓ '+n)):(fail++,console.log('  ✗ '+n)); };

console.log('\ninscription sandbox');
const inscr = s.match(/iframe\.sandbox\s*=\s*'([^']+)'/);
t('content iframe is sandboxed', !!inscr);
t('content iframe has NO allow-same-origin', inscr && !/allow-same-origin/.test(inscr[1]));
t('content iframe still allows its own scripts', inscr && /allow-scripts/.test(inscr[1]));

console.log('\nno srcdoc frame gets an origin');
for (const m of s.matchAll(/<iframe[^>]*>/g)) {
  const tag=m[0];
  if (/srcdoc/i.test(tag)) t('srcdoc iframe without same-origin: '+tag.slice(0,40), !/allow-same-origin/.test(tag));
}

console.log('\ncontent type escaping');
t('contentType is escaped where interpolated', !/\$\{inscription\.contentType\}/.test(s));
t('escapeHtml is used on it', /escapeHtml\(inscription\.contentType\)/.test(s));

console.log('\npostMessage targets');
t('wallet replies are not broadcast with *', !/dir:'res'[^}]*\}, '\*'\)/.test(s.replace(/\s+/g,' ')) || /rpcOrigins/.test(s));
t('rpcOrigins table exists', /const rpcOrigins/.test(s));

console.log('\npermission enforcement');
t('METHOD_PERMISSION map exists', /METHOD_PERMISSION/.test(s));
t('methodAllowed gates the relay', /if \(!methodAllowed\(w, d\.method\)\)/.test(s));
// The fallback must be a permission the installer actually grants, and the
// strictest one in the vocabulary. behaviour-tests.mjs checks what it DOES;
// this only checks that a fallback exists at all.
const fallback = (s.match(/METHOD_PERMISSION\[m\]\s*\|\|\s*'([^']+)'/)||[])[1];
t('unknown methods fall back to a permission', !!fallback);
t('the fallback is one the installer can grant', ['wallet:read','pay','inscribe','sign'].includes(fallback));
t('the fallback is not the weakest one', fallback !== 'wallet:read');

console.log('\ncontent security policy');
t('CSP meta tag present', /http-equiv="Content-Security-Policy"/.test(s));
t('object-src none', /object-src 'none'/.test(s));
t('base-uri none', /base-uri 'none'/.test(s));
// Only the policy itself matters here, not the comment explaining it.
const csp = (s.match(/http-equiv="Content-Security-Policy" content="([\s\S]*?)"/)||[])[1]||'';
t('policy contains no unsafe-eval', !/unsafe-eval/.test(csp));
t('policy pins script-src', /script-src/.test(csp));

console.log('\nCDN scripts');
const cdn=[...s.matchAll(/<script src="https:\/\/[^"]+"[^>]*>/g)];
t('all CDN scripts carry crossorigin', cdn.every(m=>/crossorigin/.test(m[0])));
t('all CDN scripts carry referrerpolicy', cdn.every(m=>/referrerpolicy/.test(m[0])));
// SRI is all-or-nothing here. Zero attributes means the hashes have not been
// generated yet (tools/generate-sri.sh); four means they have. Anything in
// between is a partially applied fix and is the state worth failing on.
//
// The earlier version of this assertion demanded ZERO, which meant that anyone
// following our own instructions — run generate-sri.sh, paste the four lines —
// turned the CI red. A test that forbids its own fix cements the bug.
const sriCount = (s.match(/integrity="sha\d{3}-/g) || []).length;
t(`SRI is all-or-nothing (found ${sriCount} of ${cdn.length})`,
  sriCount === 0 || sriCount === cdn.length);
if (sriCount === 0) {
  console.log('    note: run tools/generate-sri.sh and paste the four integrity attributes');
}

console.log('\n'+'='.repeat(40));
console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail?1:0);
