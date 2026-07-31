#!/bin/bash

set -e

echo "🚀 Bingo Stress Test Runner"
echo "==================================="
echo ""

if [ ! -f ../.env ]; then
  echo "❌ Error: .env file not found in parent directory"
  exit 1
fi

source ../.env

if [ -z "$VITE_SUPABASE_URL" ] || [ -z "$VITE_SUPABASE_ANON_KEY" ]; then
  echo "❌ Error: VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY must be set in .env"
  exit 1
fi

# k6 IS NOT AN npm PACKAGE, whatever the root package.json suggests.
#
# `k6: ^0.0.0` in devDependencies is the official autocomplete STUB -- its own
# description reads "Dummy package for autocompleting k6 scripts". Installing it
# gives you type hints and no binary, so `npm run stress:spike` has always failed
# with "k6: command not found" for anyone who assumed npm install was enough.
# That is part of why these tests have never run.
#
# Checked here rather than left to the shell so the message names the cause.
if ! command -v k6 >/dev/null 2>&1; then
  # Quoted heredoc: the install commands contain backslashes and quotes, and a
  # trailing backslash inside an echo "..." escapes the closing quote and
  # unbalances every line after it. <<'EOF' passes the text through untouched.
  cat <<'EOF'
k6 is not installed.

   It is a Go binary, not an npm package. The `k6` entry in package.json is the
   official autocomplete stub -- its own description reads "Dummy package for
   autocompleting k6 scripts" -- so `npm install` gives type hints and nothing
   runnable. That is part of why these tests have never been run.

   Debian/Ubuntu:
     sudo gpg -k
     sudo gpg --no-default-keyring \
       --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
       --keyserver hkp://keyserver.ubuntu.com:80 \
       --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
     echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
       | sudo tee /etc/apt/sources.list.d/k6.list
     sudo apt-get update && sudo apt-get install k6

   macOS:   brew install k6
   Docker:  docker run --rm -i grafana/k6 run - <script.js
EOF
  exit 1
fi

# Reachability, before spending a ramp on a URL that answers nothing. A load test
# against a dead endpoint reports beautiful latency and means nothing.
if ! curl -sS -m 10 -o /dev/null "${VITE_SUPABASE_URL}/healthz"; then
  echo "❌ ${VITE_SUPABASE_URL}/healthz is not reachable. Refusing to run."
  exit 1
fi

# THE CARD-SELECTION LEG NEEDS A PLAYER TOKEN AND DOES NOT HAVE ONE.
#
# /functions/v1/select-card now requires a JWT this system issued and derives the
# player, the display name and the card layout from it -- see
# services/functions/src/select-card.js. These scripts send VITE_SUPABASE_ANON_KEY,
# which that route correctly rejects with 401.
#
# The run is still useful: the lobby leg exercises the read path, which is most of
# a lobby's traffic. But every selection will fail, `card_selection_errors` will
# breach its threshold, and the run will be reported as failed. That is the
# scripts being honest, not a broken endpoint.
#
# Note the selection LATENCY figure stays green in that case, because the duration
# is recorded before the status is checked -- a 401 is fast. Read
# card_selection_errors, not card_selection_duration, until this is wired.
echo "⚠️  select-card requires a player JWT; these scripts send the anon key."
echo "    Expect every selection to 401. The lobby (read) numbers are still valid."
echo ""

TEST_TYPE="${1:-spike}"

case $TEST_TYPE in
  spike)
    echo "🔥 Running SPIKE test: 400 users in 10 seconds (40 users/sec)"
    k6 run --env VITE_SUPABASE_URL="$VITE_SUPABASE_URL" --env VITE_SUPABASE_ANON_KEY="$VITE_SUPABASE_ANON_KEY" k6-spike-test.js
    ;;
  sustained)
    echo "📊 Running SUSTAINED test: 400 users in 20 seconds (20 users/sec)"
    k6 run --env VITE_SUPABASE_URL="$VITE_SUPABASE_URL" --env VITE_SUPABASE_ANON_KEY="$VITE_SUPABASE_ANON_KEY" k6-sustained-test.js
    ;;
  gradual)
    echo "📈 Running GRADUAL test: 400 users in 30 seconds (13 users/sec)"
    k6 run --env VITE_SUPABASE_URL="$VITE_SUPABASE_URL" --env VITE_SUPABASE_ANON_KEY="$VITE_SUPABASE_ANON_KEY" k6-gradual-test.js
    ;;
  all)
    echo "🎯 Running ALL test scenarios sequentially..."
    echo ""
    echo "1/3 - Spike Test"
    k6 run --env VITE_SUPABASE_URL="$VITE_SUPABASE_URL" --env VITE_SUPABASE_ANON_KEY="$VITE_SUPABASE_ANON_KEY" k6-spike-test.js
    sleep 5
    echo ""
    echo "2/3 - Sustained Test"
    k6 run --env VITE_SUPABASE_URL="$VITE_SUPABASE_URL" --env VITE_SUPABASE_ANON_KEY="$VITE_SUPABASE_ANON_KEY" k6-sustained-test.js
    sleep 5
    echo ""
    echo "3/3 - Gradual Test"
    k6 run --env VITE_SUPABASE_URL="$VITE_SUPABASE_URL" --env VITE_SUPABASE_ANON_KEY="$VITE_SUPABASE_ANON_KEY" k6-gradual-test.js
    ;;
  *)
    echo "❌ Invalid test type: $TEST_TYPE"
    echo "Usage: ./run-test.sh [spike|sustained|gradual|all]"
    exit 1
    ;;
esac

echo ""
echo "✅ Test completed!"
