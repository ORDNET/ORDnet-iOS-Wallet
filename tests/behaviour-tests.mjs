// ORD/browser — behavioural tests.
//
// The structural suite in structure-tests.mjs greps the source. That caught
// nothing when the RPC relay stopped answering entirely, because the shape of
// the code was fine and the behaviour was broken. These tests lift the actual
// functions out and run them against a simulated window, so a regression that
// keeps the code looking right still fails here.
//
// Run: node tests/behaviour-tests.mjs

import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';

const html = fs.readFileSync(new URL('../ORDnet_WEB3_Browser.html', import.meta.url), 'utf8');
const script = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].pop()[1];

let pass = 0, fail = 0;
const t = (name, fn) => {
  try { fn(); console.log('  \u2713 ' + name); pass++; }
  catch (e) { console.log('  \u2717 ' + name + ' \u2014 ' + e.message); fail++; }
};

/** Lift a top-level function by brace counting, parameter list included. */
function lift(name) {
  const start = script.indexOf('function ' + name + '(');
  assert.ok(start !== -1, name + ' not found');
  let p = script.indexOf('(', start), pd = 0;
  for (; p < script.length; p++) {
    if (script[p] === '(') pd++;
    else if (script[p] === ')') { pd--; if (pd === 0) { p++; break; } }
  }
  let i = script.indexOf('{', p), depth = 0;
  for (; i < script.length; i++) {
    if (script[i] === '{') depth++;
    else if (script[i] === '}') { depth--; if (depth === 0) { i++; break; } }
  }
  return script.slice(start, i);
}

/** A window.postMessage that enforces the real targetOrigin rules. */
function makeWindow(actualOrigin) {
  const received = [];
  return {
    received,
    postMessage(msg, targetOrigin) {
      if (targetOrigin === undefined) throw new TypeError('targetOrigin required');
      if (targetOrigin !== '*' && targetOrigin !== '/') {
        // A browser throws SyntaxError on anything that is not a valid origin.
        // The string "null" is NOT a valid origin — this is the exact failure.
        let parsed;
        try { parsed = new URL(targetOrigin); }
        catch { throw new SyntaxError(`Invalid target origin '${targetOrigin}'`); }
        if (parsed.origin !== actualOrigin) return; // silently not delivered
      }
      received.push(msg);
    }
  };
}

const ctx = { console, URL, TypeError, SyntaxError, Array, String };
ctx.globalThis = ctx;
vm.createContext(ctx);
// The map must be evaluated before the functions that close over it.
vm.runInContext(
  script.slice(script.indexOf('const METHOD_PERMISSION'), script.indexOf('function methodPermission')),
  ctx);
vm.runInContext(lift('replyTarget'), ctx);
vm.runInContext(lift('methodPermission'), ctx);
vm.runInContext(lift('methodAllowed'), ctx);
// Expose it for the vocabulary check below.
vm.runInContext('globalThis.__MP = METHOD_PERMISSION;', ctx);
const { replyTarget, methodPermission, methodAllowed } = ctx;

/* ============================================================== *
 * A wallet answer must actually arrive
 * ============================================================== */
console.log('\nRPC responses reach the caller');

t('a reply to an OPAQUE origin is delivered, not swallowed', () => {
  // The content iframe is sandboxed without allow-same-origin, so the browser
  // reports its origin as the string "null". Passing that to postMessage
  // throws SyntaxError. This is the regression that broke every wallet call.
  const w = makeWindow('null');
  w.postMessage({ ok: true }, replyTarget('null'));
  assert.strictEqual(w.received.length, 1, 'the response never arrived');
});

t('an undefined origin still delivers', () => {
  const w = makeWindow('null');
  w.postMessage({ ok: true }, replyTarget(undefined));
  assert.strictEqual(w.received.length, 1);
});

t('a named origin is pinned exactly', () => {
  const w = makeWindow('https://app.example');
  w.postMessage({ ok: true }, replyTarget('https://app.example'));
  assert.strictEqual(w.received.length, 1);
});

t('a reply is NOT delivered to a window that changed origin', () => {
  const w = makeWindow('https://evil.example');
  w.postMessage({ secret: 'signature' }, replyTarget('https://app.example'));
  assert.strictEqual(w.received.length, 0, 'a pinned origin must not reach another origin');
});

t('replyTarget never returns the literal string "null"', () => {
  for (const v of ['null', undefined, null, '']) {
    assert.notStrictEqual(replyTarget(v), 'null');
  }
});

t('a full request/response round trip completes', () => {
  // Mirrors the relay: remember the asking window and its origin, then answer.
  const rpcRoutes = {}, rpcOrigins = {};
  const content = makeWindow('null');
  rpcRoutes['1'] = content;
  rpcOrigins['1'] = 'null';           // what the browser reports for a sandbox
  const target = rpcRoutes['1'];
  target.postMessage({ __ordnet: 1, dir: 'res', id: '1', ok: true, result: { address: '1Abc' } },
    replyTarget(rpcOrigins['1']));
  assert.strictEqual(content.received.length, 1, 'the dApp got no answer');
  assert.strictEqual(content.received[0].result.address, '1Abc');
});

/* ============================================================== *
 * A normally installed wallet must still work
 * ============================================================== */
console.log('\npermissions match the vocabulary the installer stores');

// This is exactly what the install screen records when a manifest declares
// nothing: see defaultPerms in the installer.
const DEFAULT_WALLET = { perms: ['wallet:read', 'pay', 'inscribe', 'sign'] };

for (const m of ['connect', 'getAddress', 'getBalance', 'getUtxos', 'getPublicKey']) {
  t(`a default wallet may ${m}`, () => assert.ok(methodAllowed(DEFAULT_WALLET, m)));
}
for (const m of ['pay', 'sendTx', 'inscribe', 'signMessage', 'signTx', 'signAction']) {
  t(`a default wallet may ${m} — the happy path is not blocked`, () =>
    assert.ok(methodAllowed(DEFAULT_WALLET, m), `${m} requires "${methodPermission(m)}", which no installer grants`));
}

t('every permission this map requires exists in the installer vocabulary', () => {
  const known = new Set(['page:context', 'net:read', 'wallet:read', 'pay', 'inscribe', 'sign', 'storage']);
  for (const [method, perm] of Object.entries(ctx.__MP)) {
    assert.ok(known.has(perm), `${method} requires "${perm}", which PERMISSION_LABELS does not define`);
  }
});

console.log('\nbut a restricted plugin is still restricted');

const READ_ONLY = { perms: ['wallet:read'] };
t('a read-only plugin may read', () => assert.ok(methodAllowed(READ_ONLY, 'getAddress')));
t('a read-only plugin may NOT pay', () => assert.ok(!methodAllowed(READ_ONLY, 'pay')));
t('a read-only plugin may NOT inscribe', () => assert.ok(!methodAllowed(READ_ONLY, 'inscribe')));
t('a read-only plugin may NOT sign', () => assert.ok(!methodAllowed(READ_ONLY, 'signMessage')));

const PAY_ONLY = { perms: ['wallet:read', 'pay'] };
t('pay does not imply inscribe', () => assert.ok(!methodAllowed(PAY_ONLY, 'inscribe')));
t('pay does not imply sign', () => assert.ok(!methodAllowed(PAY_ONLY, 'signMessage')));

t('an unknown method falls back to the strictest permission', () => {
  assert.strictEqual(methodPermission('somethingNewAndDangerous'), 'sign');
  assert.ok(!methodAllowed(PAY_ONLY, 'somethingNewAndDangerous'));
});

t('a legacy plugin with no recorded permissions may read but not spend', () => {
  const legacy = { perms: [] };
  assert.ok(methodAllowed(legacy, 'getAddress'), 'existing installs must keep working for reads');
  assert.ok(!methodAllowed(legacy, 'pay'));
  assert.ok(!methodAllowed(legacy, 'signMessage'));
});

t('a plugin with no perms property at all is treated as legacy, not as trusted', () => {
  assert.ok(!methodAllowed({}, 'pay'));
  assert.ok(!methodAllowed(undefined, 'pay'));
});

console.log('\n' + '='.repeat(46));
console.log(`  ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
