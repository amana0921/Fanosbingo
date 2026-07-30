#!/usr/bin/env node
/**
 * Static check over the migration set: find functions that end up with MORE THAN
 * ONE live signature.
 *
 * WHY THIS EXISTS, and it is not hypothetical.
 *
 * `CREATE OR REPLACE FUNCTION` only replaces a function with a MATCHING
 * signature. Add a parameter and you have not replaced anything -- you have
 * created an OVERLOAD, and the old body is still there, still callable, still
 * carrying whatever it did before.
 *
 * This has cost this project three separate times:
 *
 *   get_lobby_data_instant   Three migrations define it; 20260216092910 added a
 *                            second parameter, so the one-argument version
 *                            survived. db/20-post/004 rewrote the two-argument
 *                            version to take identity from the JWT -- and the
 *                            one-argument version kept trusting the request body.
 *                            PostgREST resolves {"user_telegram_id": N} to it by
 *                            exact arity, so the security fix would have shipped
 *                            bypassable by omitting a field.
 *
 *   select_card_atomic       Reached three signatures before
 *                            20260216113940 dropped two, titled "Remove Ambiguous
 *                            Function Overloads" -- because users saw "Unable to
 *                            select this card" and the cause was
 *                            "function is not unique".
 *
 *   the migration itself     `GRANT ... ON FUNCTION public.<name>` fails outright
 *                            when the name is not unique. That is how the first
 *                            of these was found: by a migration failing against
 *                            the real database, after passing every local check.
 *
 * All three were invisible in review, because the diff that causes it looks like
 * an ordinary edit to an existing function. Nothing about `CREATE OR REPLACE`
 * hints that changing the parameter list changes its meaning entirely.
 *
 * This reads the files rather than a database, so it runs in milliseconds, needs
 * no postgres, and can gate a pull request.
 *
 * IT IS NOT A PARSER. It matches CREATE/DROP FUNCTION statements textually and
 * normalises the parameter TYPES to compare signatures, which is enough for this
 * class of bug and cannot be fooled by anything in this repository. If it ever
 * disagrees with the database, believe the database.
 *
 * Usage:
 *   node scripts/check-migrations.mjs           # report and exit non-zero on any
 *   node scripts/check-migrations.mjs --list    # list every function signature
 */

import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..');

// Applied in this order by scripts/db-migrate.sh.
const DIRS = [
  'db/00-bootstrap',
  'supabase/migrations',
  'db/20-post',
];

const files = DIRS.flatMap((d) => {
  const abs = path.join(ROOT, d);
  if (!fs.existsSync(abs)) return [];
  return fs.readdirSync(abs).filter((f) => f.endsWith('.sql')).sort()
    .map((f) => ({ rel: `${d}/${f}`, abs: path.join(abs, f) }));
});

/** Balanced-paren capture of the argument list starting at an open paren. */
function argsAt(text, openIdx) {
  let depth = 0;
  for (let i = openIdx; i < text.length; i++) {
    if (text[i] === '(') depth++;
    else if (text[i] === ')') {
      depth--;
      if (depth === 0) return text.slice(openIdx + 1, i);
    }
  }
  return '';
}

/**
 * Reduce an argument list to a comparable type signature.
 *
 * PostgreSQL identifies a function by its argument TYPES, not by parameter names
 * or defaults, so `(p_id uuid, p_n integer DEFAULT 1)` and `(game uuid, num int)`
 * are the same function. Normalising to `uuid,integer` is what makes the
 * comparison mean what Postgres means.
 */
const TYPE_WORDS = /\b(bigint|int8|integer|int4|int|smallint|uuid|text|varchar|jsonb|json|boolean|bool|numeric|decimal|timestamptz|timestamp|date|bytea|record|trigger|void|interval|real|double\s+precision)\b(\s*\[\s*\])?/gi;

function signatureOf(args) {
  if (!args.trim()) return '';
  return args
    .split(/,(?![^()]*\))/)          // split on top-level commas only
    .map((p) => {
      const m = [...p.matchAll(TYPE_WORDS)];
      if (m.length === 0) return '?';
      // The FIRST type word after the parameter name is the parameter's type; a
      // later one belongs to a DEFAULT expression such as `DEFAULT 1::integer`.
      let t = m[0][0].toLowerCase().replace(/\s+/g, ' ');
      const arr = m[0][2] ? '[]' : '';
      const alias = { int8: 'bigint', int4: 'integer', int: 'integer', bool: 'boolean', decimal: 'numeric', varchar: 'text' };
      t = alias[t] ?? t;
      return t + arr;
    })
    .join(',');
}

/** name -> Set of live signatures, and where each came from. */
const live = new Map();
const origin = new Map();

const CREATE_RE = /CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:(?:public|auth)\.)?("?[a-zA-Z_][a-zA-Z0-9_]*"?)\s*\(/gi;
const DROP_RE = /DROP\s+FUNCTION\s+(?:IF\s+EXISTS\s+)?(?:(?:public|auth)\.)?("?[a-zA-Z_][a-zA-Z0-9_]*"?)\s*(\(|;)/gi;

for (const f of files) {
  const sql = fs.readFileSync(f.abs, 'utf8');

  for (const m of sql.matchAll(DROP_RE)) {
    const name = m[1].replace(/"/g, '');
    if (m[2] === ';') {
      // DROP FUNCTION name;  -- only legal when unique; removes whatever is there.
      live.delete(name);
      continue;
    }
    const sig = signatureOf(argsAt(sql, m.index + m[0].length - 1));
    live.get(name)?.delete(sig);
    if (live.get(name)?.size === 0) live.delete(name);
  }

  for (const m of sql.matchAll(CREATE_RE)) {
    const name = m[1].replace(/"/g, '');
    const sig = signatureOf(argsAt(sql, m.index + m[0].length - 1));
    if (!live.has(name)) live.set(name, new Set());
    live.get(name).add(sig);
    origin.set(`${name}(${sig})`, f.rel);
  }
}

if (process.argv.includes('--list')) {
  for (const [name, sigs] of [...live].sort()) {
    for (const s of sigs) console.log(`${name}(${s})  <- ${origin.get(`${name}(${s})`)}`);
  }
  process.exit(0);
}

const overloaded = [...live].filter(([, sigs]) => sigs.size > 1).sort();

if (overloaded.length === 0) {
  console.log('No function ends the migration set with more than one signature.');
  process.exit(0);
}

console.error(`\n${overloaded.length} function(s) end the migration set with MULTIPLE SIGNATURES:\n`);
for (const [name, sigs] of overloaded) {
  console.error(`  ${name}  -- ${sigs.size} signatures`);
  for (const s of sigs) {
    console.error(`      (${s})   from ${origin.get(`${name}(${s})`)}`);
  }
  console.error('');
}
console.error(`Each of these means an older body is still live and still callable.

If that is deliberate, DROP the ones you do not want in a migration -- as
20260216113940 did for select_card_atomic and db/20-post/004 did for
get_lobby_data_instant. If it is not deliberate, one of these is a function you
believed you had replaced.

Note also that GRANT ... ON FUNCTION <name> fails outright on an ambiguous name.
`);
process.exit(1);
