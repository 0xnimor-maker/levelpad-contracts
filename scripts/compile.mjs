import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import solc from 'solc';

export const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export function compileHook() {
  assert.equal(solc.version(), '0.8.30+commit.73712a01.Emscripten.clang', 'Wrong compiler');
  const input = JSON.parse(fs.readFileSync(path.join(root, 'verification/StockFeeHook.standard-input.json')));
  for (const [name, entry] of Object.entries(input.sources)) {
    if (name.startsWith('contracts/')) assert.equal(fs.readFileSync(path.join(root, name), 'utf8'), entry.content, `Source differs: ${name}`);
  }
  const output = JSON.parse(solc.compile(JSON.stringify(input)));
  const errors = (output.errors ?? []).filter(e => e.severity === 'error');
  assert.equal(errors.length, 0, errors.map(e => e.formattedMessage).join('\n'));
  return output.contracts['contracts/StockFeeHook.sol'].StockFeeHook;
}

function compileRelated() {
  const sources = Object.fromEntries(fs.readdirSync(path.join(root, 'contracts')).filter(n => n.endsWith('.sol'))
    .map(n => [`contracts/${n}`, { content: fs.readFileSync(path.join(root, 'contracts', n), 'utf8') }]));
  const output = JSON.parse(solc.compile(JSON.stringify({ language: 'Solidity', sources,
    settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true, evmVersion: 'shanghai',
      outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object'] } } } }), {
    import: name => {
      try { return { contents: fs.readFileSync(path.join(root, 'node_modules', name), 'utf8') }; }
      catch { return { error: `Missing pinned dependency: ${name}` }; }
    }
  }));
  const errors = (output.errors ?? []).filter(e => e.severity === 'error');
  assert.equal(errors.length, 0, errors.map(e => e.formattedMessage).join('\n'));
  return output;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const hook = compileHook(), related = compileRelated();
  fs.mkdirSync(path.join(root, 'artifacts'), { recursive: true });
  fs.writeFileSync(path.join(root, 'artifacts/StockFeeHook.json'), JSON.stringify(hook, null, 2));
  fs.writeFileSync(path.join(root, 'artifacts/related-contracts.json'), JSON.stringify(related.contracts, null, 2));
  console.log(JSON.stringify({ compiler: solc.version(), hookRuntimeBytes: hook.evm.deployedBytecode.object.length / 2,
    relatedSourceFiles: Object.keys(related.contracts).filter(n => n.startsWith('contracts/')).length }));
}
