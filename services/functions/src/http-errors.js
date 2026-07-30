/**
 * Request-level error handling.
 *
 * WHY THIS FILE EXISTS: three malformed request bodies took the whole auth
 * service offline for every player, and it took ten seconds each time.
 *
 * MEASURED against live dev, 2026-07-30:
 *
 *   curl -X POST https://api.<domain>/functions/v1/auth/telegram \
 *     -H 'content-type: application/json' --data-binary '7'
 *   -> 500        (x3, inside thirty seconds)
 *
 *   ...then a PERFECTLY VALID request, from anyone:
 *   -> 503, 503, 503
 *
 * The chain, and every link is ordinary:
 *
 *   1. express.json() cannot parse the body and throws a SyntaxError.
 *   2. The generic error handler answers 500 -- reporting a CLIENT mistake as a
 *      server failure. Nothing in the log said "bad request"; it said
 *      "unhandled: Unexpected token '7'".
 *   3. Caddy proxies this upstream with `unhealthy_status 5xx` and
 *      `max_fails 3`, so three 500s inside thirty seconds take the upstream out
 *      of rotation for ten.
 *   4. There is exactly ONE upstream. Taking it out of rotation does not shed
 *      load onto a healthy peer, because there is no peer. It converts three
 *      bad requests from one caller into a total outage for everybody.
 *
 * So an unauthenticated caller could keep auth down indefinitely by sending
 * three junk bodies every ten seconds. No volume, no concurrency, no valid
 * credentials -- and it is the one route that must work for a player to get in.
 *
 * THE FIX IS THE STATUS CODE, not the health check. A body that does not parse
 * is a 400: it is the client's error, it tells the client something true, and it
 * never enters the 5xx bucket the health check watches. Correcting this removes
 * the amplification at its source rather than raising a threshold and hoping.
 *
 * The health check is separately questionable for a single upstream -- see the
 * note in services/caddy/Caddyfile -- but it is not the bug. The bug is calling
 * a client error a server error.
 */

/**
 * Express error handler for body-parser failures.
 *
 * MUST be registered immediately after express.json(), and AFTER the CORS
 * middleware. Ordering matters twice:
 *
 *   - after express.json(), because an error handler only sees errors raised by
 *     middleware registered before it;
 *   - after CORS, so the 400 carries Access-Control-Allow-Origin. A 400 without
 *     it reaches the browser as an opaque CORS failure, and the developer sees
 *     "blocked by CORS policy" for what is really a malformed body -- which is
 *     the kind of misdirection that costs an afternoon.
 *
 * Errors that are not body-parser errors are passed along untouched, so genuine
 * server faults still reach the 500 handler and still show up as 5xx. This
 * narrows what counts as a server error; it does not hide server errors.
 *
 * @param {(level: string, message: string, fields?: object) => void} log
 */
export function bodyParserErrorHandler(log) {
  // eslint-disable-next-line no-unused-vars -- Express identifies error handlers by arity
  return (err, req, res, next) => {
    // body-parser sets `type` on everything it raises. Keyed on that rather than
    // on `instanceof SyntaxError`, because a SyntaxError can also come from
    // application code, where it IS a server fault and must stay a 500.
    switch (err?.type) {
      case 'entity.parse.failed':
        log('warn', 'malformed request body', {
          path: req.path,
          // The body itself is not logged: on this route it would be initData,
          // which is credential material.
          bytes: err.body?.length ?? null,
        });
        return res.status(400).json({ error: 'request body is not valid JSON' });

      case 'entity.too.large':
        log('warn', 'request body too large', { path: req.path, limit: err.limit });
        return res.status(413).json({ error: 'request body too large' });

      case 'encoding.unsupported':
        log('warn', 'unsupported content encoding', { path: req.path });
        return res.status(415).json({ error: 'unsupported content encoding' });

      default:
        return next(err);
    }
  };
}
