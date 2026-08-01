/*
  # Wallet login is deferred, so its entry point is closed
  #
  # db/20-post/004 allowlists get_or_create_wallet_user for `anon`, and does so
  # for a good reason it states plainly: the wallet-login path has no JWT at that
  # point by construction, so the function cannot be moved behind authentication
  # without redesigning the flow.
  #
  # That reason holds only while the flow EXISTS. Crypto is now deferred --
  # Ethiopian players overwhelmingly do not hold cryptocurrency, so birr through
  # TeleBirr and CBE is the currency that matters -- and the SPA gates every
  # wallet surface behind VITE_CRYPTO_ENABLED, which is off. Nothing calls this
  # function.
  #
  # An anon-callable SECURITY DEFINER function with no caller is precisely the
  # surface 004 exists to remove. It takes a wallet address as an unchecked
  # parameter and creates or returns a player row; leaving it reachable costs
  # nothing to close and is one forgotten line away from being the next entry in
  # 004's own list of eight.
  #
  # WHY A SEPARATE FILE rather than editing 004.
  #
  # 004 names this function in THREE places -- the anon list, the authenticated
  # list, and an assertion that deliberately restates the names rather than
  # reading the same variable, so that adding to one list and not the other
  # fails. Editing all three would erase the record of why it was allowlisted,
  # which is the thing worth keeping: when crypto returns, that reasoning is
  # exactly what has to be re-read.
  #
  # This file runs after 004 (010 > 004), so its revoke wins. 004's assertion is
  # unaffected: it fails on a function that IS anon-executable and should not be,
  # never on one that is not.
  #
  # ---------------------------------------------------------------------------
  # TO RESTORE, alongside setting VITE_CRYPTO_ENABLED=true:
  #
  #   delete this file, or invert it. Both lists in 004 already name the
  #   function, so nothing else has to change.
  #
  # This is one half of a coupled pair. The other half is the SPA flag, and the
  # notes in src/components/CryptoProvider.tsx and src/components/WalletPanel.tsx
  # point back here.
  # ---------------------------------------------------------------------------
  #
  # REPEATABLE migration: idempotent, re-applied whenever it changes.
*/

DO $$
DECLARE
  v_sig text;
BEGIN
  -- By signature, not by name. 004 learned this the expensive way: GRANT on a
  -- bare name raises "function is not unique" the moment an overload exists, and
  -- get_lobby_data_instant had three definitions disagreeing on arity.
  FOR v_sig IN
    SELECT format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid))
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'get_or_create_wallet_user'
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated', v_sig);
    RAISE NOTICE 'Revoked EXECUTE on % (wallet login deferred)', v_sig;
  END LOOP;
END $$;

DO $$
DECLARE
  v_bad text;
BEGIN
  SELECT string_agg(
           format('%s(%s)', p.proname, pg_get_function_identity_arguments(p.oid)), '; ')
    INTO v_bad
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.proname = 'get_or_create_wallet_user'
     AND (has_function_privilege('anon', p.oid, 'EXECUTE')
          OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));

  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION
      'get_or_create_wallet_user is still callable without privilege: %. Wallet login is deferred; nothing should reach it.',
      v_bad;
  END IF;

  RAISE NOTICE 'wallet login: entry point closed while crypto is deferred';
END $$;
