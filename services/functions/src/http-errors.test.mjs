/**
 * Tests for http-errors.js.
 *
 * Runs a real express app and makes real requests, in the same middleware order
 * index.js uses. A unit test that called the handler with a fake error object
 * would pass while the ordering was wrong -- and the ordering is the part that
 * was wrong in production: the handler has to sit after express.json() to see
 * its errors at all, and after the CORS middleware for the 400 to be readable by
 * a browser.
 *
 * THE ASSERTION THAT MATTERS is the last one. It is not "a bad body returns
 * 400"; it is "a bad body does not return 5xx", because 5xx is what Caddy's
 * passive health check counts, and three of them used to take the whole service
 * out of rotation for every player.
 *
 * Run: node src/http-errors.test.mjs
 */

import http from 'node:http';
import express from 'express';
import { bodyParserErrorHandler } from './http-errors.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

const logged = [];
const log = (level, message, fields) => logged.push({ level, message, fields });

/** The middleware order index.js uses, with one route behind it. */
function buildApp() {
  const app = express();
  app.disable('x-powered-by');

  app.use((req, res, next) => {
    res.set('Access-Control-Allow-Origin', 'https://app.example.org');
    if (req.method === 'OPTIONS') return res.sendStatus(204);
    return next();
  });

  app.use(express.json({ limit: '64kb' }));
  app.use(bodyParserErrorHandler(log));

  app.post('/auth/telegram', (req, res) => {
    if (typeof req.body?.initData !== 'string' || !req.body.initData) {
      return res.status(400).json({ error: 'initData is required' });
    }
    return res.json({ ok: true });
  });

  // A route that fails for a genuine server-side reason, to prove this change
  // narrows what counts as a 5xx without suppressing real ones.
  app.post('/boom', () => {
    throw new Error('a real server fault');
  });

  // eslint-disable-next-line no-unused-vars -- Express identifies error handlers by arity
  app.use((err, _req, res, _next) => res.status(500).json({ error: 'internal error' }));

  return app;
}

function request(port, { method = 'POST', path = '/auth/telegram', body, headers = {} }) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      { host: '127.0.0.1', port, path, method, headers: { 'content-type': 'application/json', ...headers } },
      (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () =>
          resolve({ status: res.statusCode, headers: res.headers, body: data }),
        );
      },
    );
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

const server = http.createServer(buildApp());
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const port = server.address().port;

console.log('\nbodyParserErrorHandler');

// The exact payload that caused the outage. xargs -I{} had substituted a loop
// counter into `-d '{}'`, so the body on the wire was a bare number.
const bare = await request(port, { body: '7' });
check('a bare number body answers 400, not 500', bare.status === 400);
check(
  'and NOT 5xx -- which is what the health check counts',
  bare.status < 500,
);
check(
  'says what is wrong',
  JSON.parse(bare.body).error === 'request body is not valid JSON',
);
check(
  'carries CORS headers, so a browser sees the 400 and not a CORS error',
  bare.headers['access-control-allow-origin'] === 'https://app.example.org',
);

const truncated = await request(port, { body: '{"initData":' });
check('a truncated object answers 400', truncated.status === 400);

const notJson = await request(port, { body: 'initData=abc' });
check('a form-encoded body sent as JSON answers 400', notJson.status === 400);

const tooBig = await request(port, { body: JSON.stringify({ initData: 'x'.repeat(70_000) }) });
check('a body over the 64kb limit answers 413, not 500', tooBig.status === 413);

const empty = await request(port, { body: '' });
check('an empty body answers 400', empty.status === 400);

// Valid requests must be unaffected.
const missing = await request(port, { body: '{}' });
check('a valid but empty object still reaches the route (400 from the route)', missing.status === 400);
check(
  'and that 400 is the route\'s message, not the parser\'s',
  JSON.parse(missing.body).error === 'initData is required',
);

const good = await request(port, { body: JSON.stringify({ initData: 'x' }) });
check('a valid body reaches the route', good.status === 200);

// A genuine server fault must STILL be a 500, or this change would have made
// the health check blind instead of accurate.
const boom = await request(port, { path: '/boom', body: '{}' });
check('a real server fault is still 500', boom.status === 500);

check('the malformed body was logged as a warning', logged.some((e) => e.level === 'warn' && e.message === 'malformed request body'));
check(
  'the body itself was not logged (it would be credential material)',
  !logged.some((e) => JSON.stringify(e).includes('initData')),
);

server.close();

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll assertions passed.');
process.exit(failures ? 1 : 0);
