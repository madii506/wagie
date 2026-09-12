// WAGIE — payday runner (illustrative, unaudited)
// Runs every second Friday after 00:00 UTC: sweeps the creator fee share,
// swaps it to $WDAY, forwards it to WagieClock, then calls runPayday().
//
//   node payday.js            (dry run)
//   node payday.js --send     (broadcast)
//
// Requires: viem. Fill RPC, keys and addresses at launch.

import { createPublicClient, createWalletClient, http, parseAbi, formatUnits } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const CHAIN = { id: 4663, name: 'Robinhood Chain', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
                rpcUrls: { default: { http: [process.env.RPC_URL || ''] } } };

const ADDR = {
  clock:    process.env.WAGIE_CLOCK   || '0x0000000000000000000000000000000000000000',
  payroll:  process.env.WDAY_TOKEN    || '0x0000000000000000000000000000000000000000', // $WDAY stock token
  treasury: process.env.TREASURY      || '0x0000000000000000000000000000000000000000', // receives Pons creator share
};

const clockAbi = parseAbi([
  'function dayIndex(uint256 ts) view returns (uint32)',
  'function periodOf(uint32 d) pure returns (uint32)',
  'function periodPool(uint32) view returns (uint256)',
  'function periodShiftTotal(uint32) view returns (uint256)',
  'function runPayday(uint32 period)',
]);
const erc20Abi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function transfer(address,uint256) returns (bool)',
  'function decimals() view returns (uint8)',
]);

const send = process.argv.includes('--send');
const pub = createPublicClient({ chain: CHAIN, transport: http() });
const account = process.env.PRIVATE_KEY ? privateKeyToAccount(process.env.PRIVATE_KEY) : null;
const wallet = account ? createWalletClient({ account, chain: CHAIN, transport: http() }) : null;

async function main() {
  const now = BigInt(Math.floor(Date.now() / 1000));
  const d = await pub.readContract({ address: ADDR.clock, abi: clockAbi, functionName: 'dayIndex', args: [now] });
  const current = await pub.readContract({ address: ADDR.clock, abi: clockAbi, functionName: 'periodOf', args: [d] });
  const period = current - 1;                       // the period that just closed
  if (period < 0) return console.log('no closed period yet');

  const already = await pub.readContract({ address: ADDR.clock, abi: clockAbi, functionName: 'periodPool', args: [period] });
  if (already > 0n) return console.log(`period ${period} already paid`);

  const dec = await pub.readContract({ address: ADDR.payroll, abi: erc20Abi, functionName: 'decimals' });
  const treasuryBal = await pub.readContract({ address: ADDR.payroll, abi: erc20Abi, functionName: 'balanceOf', args: [ADDR.treasury] });
  const shifts = await pub.readContract({ address: ADDR.clock, abi: clockAbi, functionName: 'periodShiftTotal', args: [period] });

  console.log(`period ${period}: treasury holds ${formatUnits(treasuryBal, dec)} $WDAY, ${shifts} shifts credited`);
  if (treasuryBal === 0n) return console.log('pool is empty — payday pays 0.0000 $WDAY, exactly as advertised');
  if (shifts === 0n)      return console.log('nobody clocked in — pool rolls to next period');

  // 1) forward the period's pool to the clock. (The Pons creator share arrives in the pair
  //    asset already when the token is paired to $WDAY, so no swap step is needed here.)
  // 2) run payday so holders can claim().
  if (!send || !wallet) return console.log('dry run — pass --send to broadcast');

  const t1 = await wallet.writeContract({ address: ADDR.payroll, abi: erc20Abi, functionName: 'transfer', args: [ADDR.clock, treasuryBal] });
  console.log('forwarded pool:', t1);
  await pub.waitForTransactionReceipt({ hash: t1 });
  const t2 = await wallet.writeContract({ address: ADDR.clock, abi: clockAbi, functionName: 'runPayday', args: [period] });
  console.log('payday run:', t2);
}

main().catch(e => { console.error(e); process.exit(1); });
