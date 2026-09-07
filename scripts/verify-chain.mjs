import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { AbiCoder, Contract, FetchRequest, Interface, JsonRpcProvider, getCreate2Address,
  getBytes, hexlify, keccak256, parseEther, toQuantity, zeroPadValue } from 'ethers';
import { compileHook, root } from './compile.mjs';

const evidence = JSON.parse(fs.readFileSync(path.join(root, 'evidence/test-pool.json')));
const verified = JSON.parse(fs.readFileSync(path.join(root, 'verification/source-verification.json')));
const addr = { manager: verified.poolManager, hook: verified.address,
  router: '0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99', quoter: '0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94',
  stateView: '0xF3334192D15450CdD385c8B70e03f9A6bD9E673b', permit2: '0x000000000022D473030F116dDEE9F6B43aC78BA3' };
const keyType = 'tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)';
const coder = AbiCoder.defaultAbiCoder();
let rpc, phase = 'initialization';
const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();

async function main() {
  const url = new URL(process.env.RPC_URL || 'https://rpc.mainnet.chain.robinhood.com');
  assert.equal(url.protocol, 'https:', 'HTTPS RPC required');
  assert.ok(!url.username && !url.password && !url.hash, 'Unsupported URL format');
  const request = new FetchRequest(url.href); request.timeout = 20000;
  rpc = new JsonRpcProvider(request, undefined, { batchMaxCount: 4, cacheTimeout: -1 });
  assert.equal((await rpc.getNetwork()).chainId, 4663n, 'Wrong chain');
  const block = process.env.VERIFY_BLOCK ? Number(process.env.VERIFY_BLOCK) : await rpc.getBlockNumber();
  assert.ok(Number.isSafeInteger(block) && block >= verified.deploymentBlock, 'Invalid block');
  const blockTag = toQuantity(block), at = { blockTag: block };
  phase = 'hook compilation and complete runtime match';
  const artifact = compileHook();
  const runtime = getBytes('0x' + artifact.evm.deployedBytecode.object);
  const immutableRefs = Object.values(artifact.evm.deployedBytecode.immutableReferences).flat();
  assert.ok(immutableRefs.length > 0, 'Missing immutable references');
  for (const ref of immutableRefs) {
    assert.equal(ref.length, 32, 'Unexpected immutable width');
    runtime.set(getBytes(zeroPadValue(addr.manager, 32)), ref.start);
  }
  const chainCode = await rpc.getCode(addr.hook, block);
  assert.equal(chainCode.toLowerCase(), hexlify(runtime).toLowerCase(), 'Complete runtime mismatch');
  assert.equal(keccak256(chainCode), verified.runtimeCodeHash, 'Recorded code hash mismatch');
  const hook = new Contract(addr.hook, artifact.abi, rpc);
  assert.ok(same(await hook.poolManager(at), addr.manager), 'Wrong manager');

  phase = 'CREATE2 deployment verification';
  const deployment = await rpc.getTransaction(verified.deploymentTransaction);
  const initCode = '0x' + artifact.evm.bytecode.object + verified.constructorArguments.slice(2);
  assert.ok(deployment && same(deployment.to, verified.create2Factory), 'Wrong CREATE2 factory');
  assert.equal(deployment.data.toLowerCase(), (verified.create2Salt + initCode.slice(2)).toLowerCase(), 'CREATE2 input mismatch');
  assert.ok(same(getCreate2Address(verified.create2Factory, verified.create2Salt, keccak256(initCode)), addr.hook), 'CREATE2 address mismatch');

  phase = 'example pool and historical receipts';
  const lock = new Contract(evidence.lock, [`function poolKey() view returns(${keyType})`,
    'function poolId() view returns(bytes32)', 'function liquidity() view returns(uint128)',
    'function positionAmounts() view returns(uint256,uint256,uint160)'], rpc);
  const keyResult = await lock.poolKey(at);
  const key = { currency0: keyResult.currency0, currency1: keyResult.currency1, fee: keyResult.fee,
    tickSpacing: keyResult.tickSpacing, hooks: keyResult.hooks };
  assert.ok(same(key.hooks, addr.hook), 'Pool uses another hook');
  assert.equal(keccak256(coder.encode([keyType], [key])), evidence.poolId, 'Pool ID mismatch');
  assert.equal(await lock.poolId(at), evidence.poolId, 'Lock Pool ID mismatch');
  const state = new Contract(addr.stateView, ['function getLiquidity(bytes32) view returns(uint128)'], rpc);
  const liquidity = await state.getLiquidity(evidence.poolId, at);
  assert.ok(liquidity > 0n, 'No active liquidity at selected block');
  const amounts = await lock.positionAmounts(at);
  for (const saved of evidence.receipts) {
    const receipt = await rpc.getTransactionReceipt(saved.transaction);
    assert.equal(receipt?.status, 1, 'Recorded transaction is not successful');
    assert.equal(receipt.blockNumber, saved.block, 'Recorded block differs');
    assert.ok(receipt.logs.some(l => same(l.address, addr.manager) && l.topics[1] === evidence.poolId), 'Missing pool event');
    if (saved.event === 'Swap') assert.ok(same(receipt.to, addr.router), 'Swap bypassed expected router');
  }
  console.log(JSON.stringify({ phase: 'source-and-pool', block, chainId: 4663, hook: addr.hook,
    codeHash: keccak256(chainCode), runtimeMatches: true, deploymentInputMatches: true,
    poolId: evidence.poolId, activeLiquidity: String(liquidity), positionAmounts: amounts.map(String),
    successfulRecordedReceipts: evidence.receipts.length }));

  phase = 'read-only sell simulations';
  const account = evidence.routerSimulation.account, amount = parseEther(evidence.routerSimulation.amountInTEST);
  const token = new Contract(evidence.token, ['function balanceOf(address) view returns(uint256)',
    'function allowance(address,address) view returns(uint256)'], rpc);
  const permit = new Contract(addr.permit2, ['function allowance(address,address,address) view returns(uint160,uint48,uint48)'], rpc);
  const [balance, allowance, grant, head] = await Promise.all([token.balanceOf(account, at),
    token.allowance(account, addr.permit2, at), permit.allowance(account, evidence.token, addr.router, at), rpc.getBlock(block)]);
  assert.ok(head, 'Block unavailable');
  if (balance < amount || allowance < amount || grant[0] < amount || Number(grant[1]) <= head.timestamp) {
    console.log(JSON.stringify({ phase, skipped: true, reason: 'Recorded account lacks balance or allowance at selected block; use an archive RPC with VERIFY_BLOCK for historical reproduction.' }));
    return;
  }
  const quoter = new Contract(addr.quoter, [`function quoteExactInputSingle(tuple(${keyType} poolKey,bool zeroForOne,uint128 exactAmount,bytes hookData)) returns(uint256 amountOut,uint256 gasEstimate)`], rpc);
  const zeroForOne = same(key.currency0, evidence.token);
  const [quote] = await quoter.quoteExactInputSingle.staticCall({ poolKey: key, zeroForOne, exactAmount: amount, hookData: '0x' }, at);
  const minimum = quote * 99n / 100n; assert.ok(minimum > 0n, 'Zero minimum output');
  const swap = coder.encode([`tuple(${keyType} poolKey,bool zeroForOne,uint128 amountIn,uint128 amountOutMinimum,uint256 minHopPriceX36,bytes hookData)`],
    [{ poolKey: key, zeroForOne, amountIn: amount, amountOutMinimum: minimum, minHopPriceX36: 0n, hookData: '0x' }]);
  const settle = coder.encode(['address', 'uint256', 'bool'], [evidence.token, amount, true]);
  const settleAll = coder.encode(['address', 'uint256'], [evidence.token, amount]);
  const take = coder.encode(['address', 'uint256'], [evidence.poolKey.currency1, minimum]);
  const router = new Interface(['function execute(bytes commands,bytes[] inputs,uint256 deadline) payable']);
  const results = {};
  for (const [name, actions, params] of [['settleThenSwap', '0x0b060f', [settle, swap, take]], ['swapThenSettle', '0x060c0f', [swap, settleAll, take]]]) {
    const input = coder.encode(['bytes', 'bytes[]'], [actions, params]);
    const data = router.encodeFunctionData('execute', ['0x10', [input], head.timestamp + 300]);
    try {
      const result = await rpc.send('eth_call', [{ from: account, to: addr.router, data, gas: '0x2dc6c0' }, blockTag]);
      results[name] = { success: true, result };
    } catch (error) {
      const revertData = error.data ?? error.info?.error?.data?.data ?? error.info?.error?.data;
      const raw = typeof revertData === 'string' && /^0x[0-9a-f]*$/i.test(revertData) ? revertData : undefined;
      let message = String(error.info?.error?.message ?? error.shortMessage ?? 'RPC call failed').replace(/https?:\/\/[^\s"']+/g, '[RPC endpoint]');
      for (const secret of [...url.pathname.split('/'), ...url.searchParams.values()]) if (secret.length >= 16) message = message.replaceAll(secret, '[redacted]');
      results[name] = { success: false, code: String(error.code ?? 'RPC_ERROR'), message, ...(raw ? { revertData: raw } : {}) };
    }
  }
  console.log(JSON.stringify({ phase, block, account, amountIn: String(amount), quoteOut: String(quote), minimumOut: String(minimum), results }));
  assert.equal(results.settleThenSwap.success, true, 'Settle-first simulation failed');
  assert.equal(results.swapThenSettle.success, false, 'Swap-first behavior changed');
  assert.ok(results.swapThenSettle.revertData?.includes(Buffer.from('SellInputMustBeSettled').toString('hex')),
    'Swap-first failure did not provide the expected hook revert reason');
}

try { await main(); }
catch (error) {
  // Do not print provider objects, URLs, response bodies, or credentials.
  console.error(JSON.stringify({ failed: true, phase, code: String(error?.code ?? 'CHECK_FAILED'),
    message: error?.code === 'ERR_ASSERTION' ? error.message.split('\n')[0] : 'Read or verification failed. Check RPC availability and archive support.' }));
  process.exitCode = 1;
} finally { rpc?.destroy(); }
