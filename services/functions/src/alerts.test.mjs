/**
 * Tests for alerts.js.
 *
 * The assertions that matter are not "it forwards a message". This route is
 * UNAUTHENTICATED and sits on the service that moves money, so what is being
 * tested is that it refuses:
 *
 *   - a forged signature, using a real keypair rather than a stub, so the
 *     verification path is genuinely exercised
 *   - a signing certificate hosted anywhere but Amazon -- otherwise a forger
 *     supplies both the signature and the key that validates it
 *   - a SubscribeURL pointing anywhere but Amazon, which is otherwise an SSRF
 *     primitive pointed at whatever the task role can reach
 *   - a topic that is not ours, which a valid signature does NOT establish:
 *     any AWS account can sign a message with their own topic
 *
 * And that it answers 200 to things it drops, because SNS disables a
 * subscription that keeps returning non-2xx -- so being loud in the wrong place
 * costs the channel.
 *
 * Run: node src/alerts.test.mjs
 */

import crypto from 'node:crypto';
import { createSnsAlertHandler, __testing } from './alerts.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

console.log('\nSNS alert route');

// A real keypair and a real self-signed certificate, so verify() does actual
// RSA work. Stubbing it would test the plumbing and not the control.
const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const pem = publicKey.export({ type: 'spki', format: 'pem' });

const TOPIC = 'arn:aws:sns:us-east-1:292123551166:fanosbingo-dev-alerts';
const CERT_URL = 'https://sns.us-east-1.amazonaws.com/SimpleNotificationService-abc.pem';

function sign(msg) {
  const payload = __testing.stringToSign(msg);
  const signer = crypto.createSign('RSA-SHA256');
  signer.update(payload, 'utf8');
  return signer.sign(privateKey, 'base64');
}

function notification(overrides = {}) {
  const msg = {
    Type: 'Notification',
    MessageId: 'm-1',
    TopicArn: TOPIC,
    Subject: 'ALARM: fanosbingo-dev-game-loop-stalled',
    Message: JSON.stringify({
      AlarmName: 'fanosbingo-dev-game-loop-stalled',
      AlarmDescription: 'Players are watching a frozen board.',
      NewStateValue: 'ALARM',
      NewStateReason: 'Threshold crossed',
      StateChangeTime: '2026-08-05T13:00:00.000+0000',
    }),
    Timestamp: '2026-08-05T13:00:00.000Z',
    SignatureVersion: '2',
    SigningCertURL: CERT_URL,
    ...overrides,
  };
  msg.Signature = sign(msg);
  return msg;
}

/** Records what was fetched, so SSRF attempts are observable rather than inferred. */
function makeFetch({ certPem = pem, telegramOk = true } = {}) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push(String(url));
    if (String(url).includes('api.telegram.org')) {
      return {
        ok: telegramOk,
        status: telegramOk ? 200 : 400,
        text: async () => (telegramOk ? '{"ok":true}' : '{"description":"bad"}'),
        _body: init?.body,
      };
    }
    return { ok: true, status: 200, text: async () => certPem };
  };
  impl.calls = calls;
  return impl;
}

function makeRes() {
  const res = {
    statusCode: null,
    body: null,
    status(c) {
      res.statusCode = c;
      return res;
    },
    json(b) {
      res.body = b;
      return res;
    },
  };
  return res;
}

const makeReq = (msg) => ({
  body: typeof msg === 'string' ? msg : JSON.stringify(msg),
  log: { warn() {}, error() {} },
});

const run = async (handler, msg) => {
  const res = makeRes();
  await handler(makeReq(msg), res);
  return res;
};

// --- the happy path -------------------------------------------------------
{
  const f = makeFetch();
  const h = createSnsAlertHandler({
    botToken: 'bot-token',
    chatId: '12345',
    allowedTopicArns: [TOPIC],
    fetchImpl: f,
  });

  const res = await run(h, notification());
  const tg = f.calls.find((u) => u.includes('api.telegram.org'));

  check('a genuine alarm is accepted', res.statusCode === 200);
  check('and is forwarded to Telegram', Boolean(tg));
  check('using the bot token in the path', String(tg).includes('/botbot-token/sendMessage'));
}

// --- a forged signature ---------------------------------------------------
{
  const f = makeFetch();
  const h = createSnsAlertHandler({
    botToken: 't',
    chatId: '1',
    allowedTopicArns: [TOPIC],
    fetchImpl: f,
  });

  const forged = notification();
  forged.Message = JSON.stringify({ AlarmName: 'all clear', NewStateValue: 'OK' });

  const res = await run(h, forged);
  check('a tampered message is refused with 403', res.statusCode === 403);
  check('and nothing is sent to Telegram', !f.calls.some((u) => u.includes('telegram')));
}

// --- a signature that is simply wrong -------------------------------------
{
  const f = makeFetch();
  const h = createSnsAlertHandler({
    botToken: 't',
    chatId: '1',
    allowedTopicArns: [TOPIC],
    fetchImpl: f,
  });
  // Stripped AFTER signing. Passing Signature through notification()'s
  // overrides would not work: it re-signs at the end, so the field would be
  // replaced by a valid signature and the test would assert nothing.
  const unsigned = notification();
  delete unsigned.Signature;

  const res = await run(h, unsigned);
  check('a message carrying no signature at all is refused', res.statusCode === 403);

  // And a syntactically valid signature over the wrong content.
  const wrong = notification();
  wrong.Signature = Buffer.from('not a signature').toString('base64');
  const res2 = await run(h, wrong);
  check('as is a signature that does not verify', res2.statusCode === 403);
}

// --- the certificate host is pinned --------------------------------------
{
  const f = makeFetch();
  const h = createSnsAlertHandler({
    botToken: 't',
    chatId: '1',
    allowedTopicArns: [TOPIC],
    fetchImpl: f,
  });

  const evil = notification({ SigningCertURL: 'https://attacker.example.com/cert.pem' });
  const res = await run(h, evil);

  check('a certificate from a non-Amazon host is refused', res.statusCode === 403);
  check(
    'and that host is never fetched -- the check is BEFORE the request',
    !f.calls.some((u) => u.includes('attacker.example.com')),
  );
}

// --- the topic allowlist --------------------------------------------------
{
  const f = makeFetch();
  const h = createSnsAlertHandler({
    botToken: 't',
    chatId: '1',
    allowedTopicArns: [TOPIC],
    fetchImpl: f,
  });

  // Correctly signed, but somebody else's topic. A valid signature only proves
  // AWS sent it, not that it is ours.
  const other = notification({ TopicArn: 'arn:aws:sns:us-east-1:999999999999:their-topic' });
  const res = await run(h, other);

  check('a foreign topic is dropped', !f.calls.some((u) => u.includes('telegram')));
  check('with 200, so SNS does not disable the subscription', res.statusCode === 200);
  check('and without paying for verification first', f.calls.length === 0);
}

// --- subscription confirmation -------------------------------------------
{
  const f = makeFetch();
  const h = createSnsAlertHandler({
    botToken: 't',
    chatId: '1',
    allowedTopicArns: [TOPIC],
    fetchImpl: f,
  });

  const sub = {
    Type: 'SubscriptionConfirmation',
    MessageId: 's-1',
    TopicArn: TOPIC,
    Token: 'tok',
    SubscribeURL: 'https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription',
    Message: 'You have chosen to subscribe',
    Timestamp: '2026-08-05T13:00:00.000Z',
    SignatureVersion: '2',
    SigningCertURL: CERT_URL,
  };
  sub.Signature = sign(sub);

  const res = await run(h, sub);
  check('a signed confirmation is accepted', res.statusCode === 200);
  check('and the SubscribeURL is fetched', f.calls.some((u) => u.includes('ConfirmSubscription')));
}

// --- SubscribeURL is pinned too ------------------------------------------
{
  const f = makeFetch();
  const h = createSnsAlertHandler({
    botToken: 't',
    chatId: '1',
    allowedTopicArns: [TOPIC],
    fetchImpl: f,
  });

  const evil = {
    Type: 'SubscriptionConfirmation',
    MessageId: 's-2',
    TopicArn: TOPIC,
    Token: 'tok',
    // The SSRF: an internal address a task role can reach.
    SubscribeURL: 'http://169.254.169.254/latest/meta-data/',
    Message: 'confirm',
    Timestamp: '2026-08-05T13:00:00.000Z',
    SignatureVersion: '2',
    SigningCertURL: CERT_URL,
  };
  evil.Signature = sign(evil);

  const res = await run(h, evil);
  check('a SubscribeURL pointing at the metadata service is refused', res.statusCode === 403);
  check(
    'and is never fetched',
    !f.calls.some((u) => u.includes('169.254.169.254')),
  );
}

// --- a Telegram outage must not cost the subscription --------------------
{
  const f = makeFetch({ telegramOk: false });
  const h = createSnsAlertHandler({
    botToken: 't',
    chatId: '1',
    allowedTopicArns: [TOPIC],
    fetchImpl: f,
  });

  const res = await run(h, notification());
  check(
    'a Telegram failure still answers 200 -- non-2xx would disable the channel',
    res.statusCode === 200,
  );
}

// --- unconfigured chat id -------------------------------------------------
{
  const f = makeFetch();
  const h = createSnsAlertHandler({
    botToken: 't',
    chatId: undefined,
    allowedTopicArns: [TOPIC],
    fetchImpl: f,
  });

  const res = await run(h, notification());
  check('no chat id configured is a no-op, not an error', res.statusCode === 200);
  check('and nothing is sent', !f.calls.some((u) => u.includes('telegram')));
}

// --- rendering ------------------------------------------------------------
{
  const text = __testing.renderAlarm(
    JSON.stringify({
      AlarmName: 'fanosbingo-dev-withdrawals-waiting-too-long',
      AlarmDescription: 'This is money owed to a player.',
      NewStateValue: 'ALARM',
    }),
    'ALARM: something',
  );

  check('the state is legible at a glance', text.startsWith('🔴 ALARM'));
  check('the description survives', text.includes('money owed to a player'));

  const passthrough = __testing.renderAlarm('not json at all', 'Subject line');
  check('a non-alarm notification is passed through, not dropped', passthrough.includes('not json at all'));

  const long = __testing.renderAlarm(JSON.stringify({
    AlarmName: 'x',
    AlarmDescription: 'y'.repeat(9000),
    NewStateValue: 'ALARM',
  }), '');
  check('and the result stays under the Telegram 4096 cap', long.length <= 3900);
}

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll alert tests passed.');
process.exit(failures ? 1 : 0);
