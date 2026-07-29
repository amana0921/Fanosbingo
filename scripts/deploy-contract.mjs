/**
 * Deploy FanosBingoDeposit, signed by the KMS key.
 *
 * WHY A SCRIPT AND NOT A README STEP
 *
 * The contract sets `owner = msg.sender` in its constructor, and `addWinCredits`
 * — the only thing the backend ever calls — is `onlyOwner`. So the deploying
 * wallet becomes the owner, permanently. There is no transferOwnership recovery
 * if the wrong wallet deploys and you no longer control it.
 *
 * Deploying by hand from MetaMask, or from any key that is not the KMS one,
 * produces a contract the backend can never write to. Everything downstream then
 * fails with `revert` and no explanation. That is a mistake you make once and
 * pay for by redeploying and migrating balances.
 *
 * So the deployment is signed by the same non-exportable KMS key the service
 * uses, and ownership is correct BY CONSTRUCTION rather than by care.
 *
 * IT REFUSES RATHER THAN GUESSES
 *
 * Every precondition is checked and every one is fatal:
 *
 *   - the RPC serves the chain we think it does (a signature commits to a chain
 *     id; 56 is a live mainnet transaction wherever it was produced)
 *   - the KMS key derives to the address SSM publishes
 *   - the wallet has gas
 *   - AFTER deployment, owner() actually is the KMS address
 *
 * That last one is the point of the exercise. Deploying and assuming is how you
 * discover the problem weeks later.
 *
 * A NOTE ON THE SECURITY ALARM
 *
 * `fanosbingo-unexpected-kms-sign` fires on kms:Sign by any principal other than
 * <env>-task-functions. Running this from a workstation WILL trigger it. That is
 * the alarm working, not a false positive: a human signing with the wallet key is
 * exactly the rare, deliberate event it exists to surface. Expect the email, and
 * check CloudTrail shows your own principal.
 *
 * Usage:
 *   node scripts/deploy-contract.mjs dev [--broadcast]
 *
 * Without --broadcast it does everything except send the transaction, which is
 * how you check the preconditions and the gas estimate before committing.
 */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  createPublicClient,
  http as viemHttp,
  encodeDeployData,
  parseEther,
  formatEther,
  getAddress,
} from 'viem';

import { getSignerAddress, signTransaction } from '../services/functions/src/kms-signer.js';
import { verifyChainId, chainName } from '../services/functions/src/chain.js';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');

const ENVIRONMENT = process.argv[2] ?? 'dev';
const BROADCAST = process.argv.includes('--broadcast');

const RED = '\x1b[0;31m', GREEN = '\x1b[0;32m', YELLOW = '\x1b[0;33m', BOLD = '\x1b[1m', NC = '\x1b[0m';
const info = (m) => console.log(`${GREEN}==>${NC} ${m}`);
const warn = (m) => console.log(`${YELLOW}==>${NC} ${m}`);
const die = (m) => { console.error(`${RED}ERROR:${NC} ${m}`); process.exit(1); };

/** Read a parameter, failing loudly rather than returning undefined. */
function ssm(name) {
  try {
    return execFileSync('aws', [
      'ssm', 'get-parameter', '--name', `/fanosbingo-${ENVIRONMENT}/${name}`,
      '--query', 'Parameter.Value', '--output', 'text',
    ], { encoding: 'utf8' }).trim();
  } catch {
    die(`could not read /fanosbingo-${ENVIRONMENT}/${name} from SSM. Is the AWS session valid?`);
  }
}

console.log(`\n${BOLD}Deploy FanosBingoDeposit — ${ENVIRONMENT}${NC}`);
console.log(`  mode: ${BROADCAST ? `${RED}BROADCAST${NC}` : 'dry run (no transaction sent)'}\n`);

// ---------------------------------------------------------------------------
// 1. Chain, and whether the RPC agrees
// ---------------------------------------------------------------------------
const chainId = Number(ssm('bsc/chain_id'));
const rpcUrl = ssm('bsc/rpc_primary');
const keyId = `alias/fanosbingo-${ENVIRONMENT}-wallet-signing`;

info('Verifying the chain');
const chainCheck = await verifyChainId(rpcUrl, chainId);
if (!chainCheck.ok) die(chainCheck.reason);
console.log(`  ${chainId} — ${chainName(chainId)}, confirmed by the RPC`);

if (chainId === 56 && ENVIRONMENT !== 'prod') {
  die('refusing to deploy to BSC MAINNET from a non-prod environment');
}

// ---------------------------------------------------------------------------
// 2. The signer, and whether it is who SSM says it is
// ---------------------------------------------------------------------------
info('Resolving the signer');
const signer = await getSignerAddress(keyId);
const published = ssm('bsc/hot_wallet_address');

if (getAddress(published) !== signer) {
  die(
    `the KMS key derives to ${signer} but SSM publishes ${published}. ` +
    `Deploying would make the wrong address the contract owner.`,
  );
}
console.log(`  ${signer}  (matches the published hot wallet)`);

// ---------------------------------------------------------------------------
// 3. Gas
// ---------------------------------------------------------------------------
const client = createPublicClient({ transport: viemHttp(rpcUrl) });

const balance = await client.getBalance({ address: signer });
console.log(`  balance: ${formatEther(balance)} ${chainId === 97 ? 'tBNB' : 'BNB'}`);

if (balance === 0n) {
  console.error(`\n${RED}The signing wallet has no gas, so it cannot deploy.${NC}`);
  console.error(`\nFund ${BOLD}${signer}${NC}:`);
  if (chainId === 97) {
    console.error('  https://testnet.bnbchain.org/faucet-smart   (BSC testnet faucet)');
  } else {
    console.error('  Send BNB to that address from an exchange or another wallet.');
  }
  console.error('\nThen re-run this script. Nothing was signed or sent.\n');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// 4. Compile
// ---------------------------------------------------------------------------
info('Compiling');
const source = fs.readFileSync(path.join(REPO, 'contracts/FanosBingoDeposit.sol'), 'utf8');

const solc = (await import('solc')).default;
const output = JSON.parse(
  solc.compile(JSON.stringify({
    language: 'Solidity',
    sources: { 'FanosBingoDeposit.sol': { content: source } },
    settings: {
      optimizer: { enabled: true, runs: 200 },
      outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
    },
  })),
);

const errors = (output.errors ?? []).filter((e) => e.severity === 'error');
if (errors.length) die(`compilation failed:\n${errors.map((e) => e.formattedMessage).join('\n')}`);

const contract = output.contracts['FanosBingoDeposit.sol'].FanosBingoDeposit;
if (!contract) die('FanosBingoDeposit not found in the compiler output');

const abi = contract.abi;
const bytecode = `0x${contract.evm.bytecode.object}`;
console.log(`  ${(bytecode.length / 2 - 1).toLocaleString()} bytes of bytecode`);

// ---------------------------------------------------------------------------
// 5. Build the deployment transaction
//
// Constructor is (uint256 conversionRate, uint256 minimumDeposit). The values
// are the ones the migrations assume; changing them is a product decision, not
// a deployment detail, which is why they are explicit here rather than defaulted
// somewhere out of sight.
// ---------------------------------------------------------------------------
const CONVERSION_RATE = 1000n;                 // credits per BNB
const MINIMUM_DEPOSIT = parseEther('0.001');   // wei

info('Building the deployment transaction');
const data = encodeDeployData({ abi, bytecode, args: [CONVERSION_RATE, MINIMUM_DEPOSIT] });

const nonce = await client.getTransactionCount({ address: signer });
const fees = await client.estimateFeesPerGas();
const gas = await client.estimateGas({ account: signer, data });

// A 20% margin: estimateGas is exact for the state it sampled, and deployment
// runs against whatever state exists when it lands.
const gasLimit = (gas * 120n) / 100n;
const maxCost = gasLimit * (fees.maxFeePerGas ?? 0n);

console.log(`  nonce ${nonce}, gas ${gasLimit}, max cost ${formatEther(maxCost)}`);

if (balance < maxCost) {
  die(`balance ${formatEther(balance)} is below the maximum cost ${formatEther(maxCost)}`);
}

const tx = {
  type: 'eip1559',
  chainId,
  nonce,
  data,
  gas: gasLimit,
  maxFeePerGas: fees.maxFeePerGas,
  maxPriorityFeePerGas: fees.maxPriorityFeePerGas,
  value: 0n,
};

if (!BROADCAST) {
  console.log(`\n${YELLOW}Dry run complete.${NC} Every precondition passed and nothing was signed.`);
  console.log('Re-run with --broadcast to deploy.\n');
  process.exit(0);
}

// ---------------------------------------------------------------------------
// 6. Sign and send
// ---------------------------------------------------------------------------
warn('Signing with KMS — this WILL fire fanosbingo-unexpected-kms-sign, which is the alarm working');
const raw = await signTransaction(keyId, tx, signer);

info('Broadcasting');
const hash = await client.sendRawTransaction({ serializedTransaction: raw });
console.log(`  ${hash}`);

const receipt = await client.waitForTransactionReceipt({ hash, timeout: 180_000 });
if (receipt.status !== 'success') die(`deployment reverted: ${hash}`);

const address = getAddress(receipt.contractAddress);
console.log(`  deployed at ${BOLD}${address}${NC} in block ${receipt.blockNumber}`);

// ---------------------------------------------------------------------------
// 7. PROVE the owner is who we intended
//
// The entire reason for signing with KMS. Reading it back costs one call and
// turns an assumption into a fact.
// ---------------------------------------------------------------------------
info('Verifying ownership on chain');
const owner = await client.readContract({ address, abi, functionName: 'owner' });

if (getAddress(owner) !== signer) {
  die(
    `owner() is ${owner}, not ${signer}. The backend can never call addWinCredits ` +
    `on this contract — do not record this address.`,
  );
}
console.log(`  owner() == ${owner}  ${GREEN}correct${NC}`);

// ---------------------------------------------------------------------------
// 8. Record it where the application reads it
// ---------------------------------------------------------------------------
info('Publishing the address to SSM');
execFileSync('aws', [
  'ssm', 'put-parameter',
  '--name', `/fanosbingo-${ENVIRONMENT}/bsc/deposit_contract_address`,
  '--type', 'String', '--value', address, '--overwrite', '--no-cli-pager',
], { stdio: 'ignore' });

console.log(`
${GREEN}${BOLD}Deployed and verified.${NC}

  address   ${address}
  owner     ${signer}  (the KMS key)
  chain     ${chainId} — ${chainName(chainId)}
  tx        ${hash}

${BOLD}Next:${NC}
  - settings.deposit_contract_address still holds the OLD value. It is application
    data and must not be the source of truth for signing, but the SPA reads it.
  - Expect the unexpected-kms-sign alarm email. Confirm CloudTrail shows your
    principal and not something else.
`);
