/**
 * Tests for chain.js.
 *
 * Runs a real HTTP server rather than stubbing fetch, so the JSON-RPC handling,
 * the error paths and the timeout are exercised as they will be in production.
 * A stub would pass with code that cannot parse an actual response.
 *
 * The case that matters most is the third one: an RPC serving mainnet while the
 * environment is configured for testnet must be REFUSED. That is the arrangement
 * in which every signature produced is a live mainnet transaction.
 *
 * Run: node src/chain.test.mjs
 */

import http from 'node:http';
import { fetchChainId, verifyChainId, chainName } from './chain.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

/** A JSON-RPC endpoint that answers however the test needs. */
function rpcServer(handler) {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => handler(JSON.parse(body), res));
    });
    server.listen(0, '127.0.0.1', () =>
      resolve({ url: `http://127.0.0.1:${server.address().port}`, server }),
    );
  });
}

const ok = (result) => (_req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ jsonrpc: '2.0', id: 1, result }));
};

console.log('\nfetchChainId');
{
  const { url, server } = await rpcServer(ok('0x61'));
  check('parses a hex chain id (0x61 -> 97)', (await fetchChainId(url)) === 97);
  server.close();
}
{
  const { url, server } = await rpcServer(ok('0x38'));
  check('parses mainnet (0x38 -> 56)', (await fetchChainId(url)) === 56);
  server.close();
}
{
  const { url, server } = await rpcServer((_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ jsonrpc: '2.0', id: 1, error: { message: 'boom' } }));
  });
  let threw = false;
  try { await fetchChainId(url); } catch { threw = true; }
  check('throws on a JSON-RPC error', threw);
  server.close();
}
{
  const { url, server } = await rpcServer((_req, res) => {
    res.writeHead(500);
    res.end('nope');
  });
  let threw = false;
  try { await fetchChainId(url); } catch { threw = true; }
  check('throws on a non-200 response', threw);
  server.close();
}

console.log('\nverifyChainId');
{
  const { url, server } = await rpcServer(ok('0x61'));
  const r = await verifyChainId(url, 97);
  check('accepts a matching chain', r.ok === true && r.chainId === 97);
  server.close();
}
{
  // THE CASE THIS MODULE EXISTS FOR. Configured for testnet, RPC serves
  // mainnet -- or the reverse. Either way, signing is not safe.
  const { url, server } = await rpcServer(ok('0x38'));
  const r = await verifyChainId(url, 97);
  check('REFUSES mainnet RPC when configured for testnet', r.ok === false);
  check('reports what the RPC actually served', r.actual === 56);
  check('explains the consequence, not just the mismatch', /mainnet/i.test(r.reason));
  server.close();
}
{
  const { url, server } = await rpcServer(ok('0x61'));
  const r = await verifyChainId(url, 56);
  check('REFUSES testnet RPC when configured for mainnet', r.ok === false);
  server.close();
}
{
  // Unreachable must be distinguishable from mismatched: one is an outage to
  // retry, the other is a configuration error to fix.
  const r = await verifyChainId('http://127.0.0.1:1', 97);
  check('marks an unreachable RPC as unreachable, not mismatched', r.ok === false && r.unreachable === true);
}
{
  const r = await verifyChainId('http://127.0.0.1:1', 0);
  check('rejects a nonsensical configured chain id without calling out', r.ok === false && !r.unreachable);
}

console.log('\nchainName');
check('names mainnet', chainName(56) === 'BSC mainnet');
check('names testnet', chainName(97) === 'BSC testnet');
check('falls back for an unknown chain', chainName(1) === 'chain 1');

console.log('');
if (failures) {
  console.error(`${failures} assertion(s) failed.`);
  process.exit(1);
}
console.log('All assertions passed.');
