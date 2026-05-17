# FHEVM Development Skill
> Production-ready instruction file for AI coding agents — Claude Code, Cursor, Windsurf, Aider
> Package versions: @fhevm/solidity v0.11.1 + @zama-fhe/relayer-sdk v0.4.2
> Validated against: ShieldFi (confidential supply chain finance) and EquiShield (confidential cap table) — both deployed live on Ethereum Sepolia

---

## A NOTE ON HOW THIS FILE WAS MADE

This SKILL.md was not written from documentation.

It was produced by building two production FHEVM dApps on Sepolia, then systematically cataloguing every failure — including failures made by Claude (the AI agent) itself when working only from docs and general knowledge.

Claude made 17 mistakes that documentation alone would never have caught. Those mistakes are documented here, clearly labelled as AGENT MISTAKE, with the exact error each produces and the exact fix. When you use this skill file, you are protected against the specific failure modes that AI agents — including Claude — produce when working on FHEVM without this lived context.

Every "AGENT MISTAKE" label below is something Claude got wrong from docs alone. Every fix is what actually worked on a live Sepolia deployment.

---

## SECTION 1 — MENTAL MODEL

**Standard Solidity:** `uint256 balance = 100` — the EVM sees 100. Anyone can read it.

**FHEVM:** `euint64 balance` — the EVM stores a 32-byte handle pointing to an encrypted value. The number 100 never appears anywhere on the chain. Nobody sees it without explicit cryptographic permission.

Four rules govern everything. Violating any one produces either a silent wrong result or a cryptic runtime error:

**Rule 1 — No plaintext onchain.** All computation happens on encrypted handles via FHE operations. You cannot use encrypted values in `if/else` — only in `FHE.select()`.

**Rule 2 — The contract must grant itself access after every write.** `FHE.allowThis(value)` must be called after every assignment to encrypted state. Without it, the contract cannot read its own data in the next transaction.

**Rule 3 — Every address that will ever decrypt must be explicitly granted access at write time.** `FHE.allow(value, address)` must be called for every party — the holder, the owner, the regulator. Missing this produces a decrypt that returns 0 with no error. This is the single most deceptive failure in the entire stack.

**Rule 4 — Decryption is async and off-chain.** Users decrypt via the Zama Relayer using an EIP-712 signature. There is no synchronous `FHE.decrypt()` in production. `writeContract` resolves before the transaction is mined — always use `waitForTransactionReceipt`.

---

## SECTION 2 — PACKAGES AND VERSIONS

Use exactly these versions together. Mismatching produces silent failures with no obvious error message.

```
@fhevm/solidity              v0.11.1
@zama-fhe/relayer-sdk        v0.4.2
@fhevm/hardhat-plugin        latest compatible with v0.11.1
vite-plugin-node-polyfills   latest
```

### AGENT MISTAKE #1 — Using the deprecated fhevmjs package

**What Claude does from docs:** installs `fhevmjs` because older documentation references it.

**What breaks:** `fhevmjs` v0.6.x has a CommonJS-first build incompatible with Vite's ESM pipeline. Its bundle wrapper checks `window.fhevmjs` which is never set in a Vite app. `createInstance` returns `undefined` silently. Every encrypt call then throws — but the error object shows as `{}` in the console because JavaScript `Error.message` is non-enumerable and disappears in JSON serialization. The real error never surfaces.

```bash
# WRONG
npm install fhevmjs

# CORRECT
npm install @zama-fhe/relayer-sdk
```

### AGENT MISTAKE #2 — Importing from the bare package name

**What Claude does from docs:** writes `import { initSDK } from '@zama-fhe/relayer-sdk'`

**What breaks:** The npm package's main entry point is a thin `window.relayerSDK` shim designed for script-tag injection. All named exports are `undefined` at runtime. No error at import time. The first function call throws `TypeError: initSDK is not a function` — which looks like a missing export, not an import path problem.

```typescript
// WRONG — all exports undefined at runtime, no error at import time
import { initSDK } from '@zama-fhe/relayer-sdk';

// CORRECT — always import from /bundle
import { initSDK, createEIP712 } from '@zama-fhe/relayer-sdk/bundle';
```

### AGENT MISTAKE #3 — Using the old Solidity import path

**What Claude does from docs:** writes `import "fhevm/lib/TFHE.sol"` from older documentation.

**What breaks:** The old unscoped package `fhevm` uses `TFHE` as the library name. The new scoped package `@fhevm/solidity` uses `FHE`. Mixing old and new produces `DeclarationNotFound` errors that look like missing contracts, not version mismatches.

```solidity
// WRONG — old package, wrong library name, DeclarationNotFound errors
import "fhevm/lib/TFHE.sol";
TFHE.add(a, b);

// CORRECT — scoped package, correct library name
import { FHE } from "@fhevm/solidity/lib/FHE.sol";
FHE.add(a, b);
```

**Complete correct Solidity imports:**
```solidity
import { FHE, euint8, euint16, euint32, euint64, euint128, euint256, ebool, eaddress, externalEuint64, externalEuint32 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
```

---

## SECTION 3 — VITE CONFIGURATION

Every item here corresponds to a specific real failure. Nothing is cargo-culted.

### AGENT MISTAKE #4 — Manual Buffer polyfill misses other Node globals

**What Claude does from docs:** adds `import { Buffer } from 'buffer'; globalThis.Buffer = Buffer;` to `main.tsx`.

**What breaks:** This patches Buffer but misses `global.TextEncoder`, `global.crypto`, and other Node.js globals the SDK uses internally. Buffer errors disappear but new errors appear: `TextEncoder is not defined` or `crypto.getRandomValues is not available`.

```bash
# Install the correct polyfill package
npm install vite-plugin-node-polyfills
```

### AGENT MISTAKE #5 — Adding COOP/COEP headers

**What Claude does from docs:** adds `Cross-Origin-Embedder-Policy: require-corp` to Vite config because SharedArrayBuffer requires it.

**What breaks:** These headers block WASM loading behind any reverse proxy — Replit, Vercel previews, Netlify. The WASM fetch fails with `WebAssembly compilation aborted: Network error`. The fix is `thread: 0`, not headers.

**Complete correct vite.config.ts:**
```typescript
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import { nodePolyfills } from 'vite-plugin-node-polyfills';

export default defineConfig({
  plugins: [
    react(),
    nodePolyfills({
      buffer: true,  // Buffer used internally by SDK
      global: true,  // global.TextEncoder and global.crypto also needed
    }),
  ],
  resolve: {
    alias: {
      // Point to real ES module bundle, bypassing the thin shim wrapper
      '@zama-fhe/relayer-sdk/bundle': path.resolve(
        __dirname,
        'node_modules/@zama-fhe/relayer-sdk/bundle/relayer-sdk-js.js'
      ),
    },
  },
  optimizeDeps: {
    // Mandatory — esbuild rewrites import.meta.url paths inside the bundle,
    // breaking WASM loading. Without this, WASM silently never loads.
    exclude: ['@zama-fhe/relayer-sdk/bundle'],
    esbuildOptions: { target: 'es2020' },
  },
  define: { global: 'globalThis' },
  // DO NOT add COOP/COEP headers — they break WASM behind any reverse proxy
});
```

### WASM files — must be manually copied to public/

The SDK fetches these at absolute root paths. If missing, `initSDK` silently hangs — promise never resolves, no error thrown:

```bash
cp node_modules/@zama-fhe/relayer-sdk/bundle/tfhe_bg.wasm public/
cp node_modules/@zama-fhe/relayer-sdk/bundle/kms_lib_bg.wasm public/
cp node_modules/@zama-fhe/relayer-sdk/bundle/workerHelpers.js public/
```

Add as postinstall script so it runs automatically:
```json
{
  "scripts": {
    "postinstall": "cp node_modules/@zama-fhe/relayer-sdk/bundle/tfhe_bg.wasm public/ && cp node_modules/@zama-fhe/relayer-sdk/bundle/kms_lib_bg.wasm public/ && cp node_modules/@zama-fhe/relayer-sdk/bundle/workerHelpers.js public/"
  }
}
```

### Delete .vite cache after every config change

After changing `resolve.alias` or `optimizeDeps`, Vite's pre-bundle cache makes changes appear to have no effect — the old broken bundle is still being served:

```bash
rm -rf node_modules/.vite
# Then restart your dev server
```

---

## SECTION 4 — FHE INSTANCE INITIALIZATION

### AGENT MISTAKE #6 — Using createInstance instead of initSDK

**What Claude does from docs:** writes `createInstance(...)` — the correct name in deprecated fhevmjs v0.6.x.

**What breaks:** `createInstance` does not exist in `@zama-fhe/relayer-sdk/bundle`. Throws `TypeError: createInstance is not a function`.

```typescript
// WRONG — v0.6.x API name, does not exist in relayer-sdk
const instance = await createInstance({ ... });

// CORRECT — v0.4.2 API name
const instance = await initSDK({ ... });
```

### AGENT MISTAKE #7 — Using relayerRouteVersion: 1

**What Claude does from docs:** passes `relayerRouteVersion: 1` because v1 appears first in documentation.

**What breaks:** `/v1/keyurl` returns 404 Not Found. The SDK promise hangs then throws an unstructured fetch error with no indication of which URL failed.

```typescript
// WRONG — /v1/keyurl returns 404
relayerRouteVersion: 1

// CORRECT — /v2/keyurl is the working endpoint
relayerRouteVersion: 2
```

### AGENT MISTAKE #8 — Using the wrong relayer domain

**What Claude does from docs:** uses `gateway.sepolia.zama.ai` or `relayer.testnet.zama.ai`.

**What breaks:** Both domains return NXDOMAIN — verified against Google DNS (8.8.8.8) and Cloudflare (1.1.1.1). The error appears as `Impossible to fetch public key: wrong gateway url`.

```typescript
// WRONG — domains do not exist in DNS
relayerUrl: 'https://gateway.sepolia.zama.ai'
relayerUrl: 'https://relayer.testnet.zama.ai'

// CORRECT — .org not .ai
relayerUrl: 'https://relayer.testnet.zama.org'
```

### AGENT MISTAKE #9 — Wrong ACL address checksum

**What Claude does from docs:** uses `0xFee8407e2f5e3Ee68ad77cAE98c434e637f516EC`.

**What breaks:** The SDK calls viem's `isAddress()` on every config address. EIP-55 checksum is case-sensitive. One wrong character causes `isAddress()` to return false. The SDK throws `ACL contract address is not valid or empty` — even though the address points to the correct contract.

```typescript
// WRONG — invalid EIP-55 checksum
aclContractAddress: '0xFee8407e2f5e3Ee68ad77cAE98c434e637f516EC'

// CORRECT — exact case required
aclContractAddress: '0xFeE8407E2F5E3ee68AD77cAE98C434e637f516ec'
```

### AGENT MISTAKE #10 — Calling initSDK multiple times

**What Claude does:** calls `initSDK` inside components or per-transaction.

**What breaks:** Multiple parallel calls race and corrupt internal WASM memory, producing random crashes impossible to reproduce reliably.

**Complete correct initSDK — singleton pattern:**
```typescript
// fhevm.ts — call once, cache forever
import { initSDK } from '@zama-fhe/relayer-sdk/bundle';

let _instance: Awaited<ReturnType<typeof initSDK>> | null = null;

export async function getFhevmInstance() {
  if (_instance) return _instance;

  _instance = await initSDK({
    relayerUrl: 'https://relayer.testnet.zama.org',  // .org not .ai
    relayerRouteVersion: 2,                           // v1 returns 404
    thread: 0,                                        // mandatory without COOP/COEP
    network: publicClient,                            // viem PublicClient on Sepolia
    aclContractAddress: '0xFeE8407E2F5E3ee68AD77cAE98C434e637f516ec',
  });

  // Gate "ready" on an actual test call — initSDK may resolve before WASM fully compiled
  _instance.generateKeypair(); // if this succeeds, instance is truly ready

  return _instance;
}
```

---

## SECTION 5 — ENCRYPTED TYPES

| Type | Use for | Bit size |
|---|---|---|
| `euint8` | Flags, small counters | 8 |
| `euint16` | Percentages, small amounts | 16 |
| `euint32` | Counters, IDs, timestamps | 32 |
| `euint64` | **Financial amounts, token balances** | 64 |
| `euint128` | Large financial values | 128 |
| `euint256` | Rarely needed — high gas cost | 256 |
| `ebool` | Encrypted boolean flags | 1 |
| `eaddress` | Encrypted addresses | 160 |
| `externalEuintX` | **User input ONLY — never store directly** | varies |

Default to `euint64` for financial amounts. It covers values up to ~18.4 quadrillion.

---

## SECTION 6 — CORE FHE OPERATIONS

```solidity
// Arithmetic
euint64 sum     = FHE.add(a, b);
euint64 diff    = FHE.sub(a, b);    // wraps on underflow — use FHE.select for safety
euint64 product = FHE.mul(a, b);

// Comparisons — all return ebool
ebool lt  = FHE.lt(a, b);
ebool lte = FHE.lte(a, b);
ebool gt  = FHE.gt(a, b);
ebool gte = FHE.gte(a, b);
ebool eq  = FHE.eq(a, b);
ebool ne  = FHE.ne(a, b);

// Encrypted conditional — THE ONLY WAY to branch on encrypted values
euint64 result = FHE.select(condition, valueIfTrue, valueIfFalse);

// Boolean operations on ebool
ebool both     = FHE.and(condA, condB);
ebool either   = FHE.or(condA, condB);
ebool inverted = FHE.not(cond);

// Min / Max
euint64 smaller = FHE.min(a, b);
euint64 larger  = FHE.max(a, b);
```

**Safe subtraction — always use this pattern:**
```solidity
ebool canSubtract  = FHE.gte(a, b);
euint64 safeResult = FHE.select(canSubtract, FHE.sub(a, b), a);
```

---

## SECTION 7 — INPUT HANDLING

### AGENT MISTAKE #11 — inputProof passed in wrong position

**What Claude does from docs:** passes both proofs at the end of the function, or omits the proof entirely.

**What breaks:** `FHE.fromExternal(encShares, inputProof)` reverts with `FHE: invalid proof` — a custom error from the FHEVM precompile with no further detail.

```solidity
// WRONG — proof at wrong position
function issueShares(address holder, externalEuint64 encShares, externalEuint64 encPrice, bytes calldata proof)

// CORRECT — each proof immediately follows its value
function issueShares(
    address holder,
    externalEuint64 encShares,
    bytes calldata sharesProof,  // immediately after encShares
    externalEuint64 encPrice,
    bytes calldata priceProof    // immediately after encPrice
) external onlyOwner {
    euint64 shares = FHE.fromExternal(encShares, sharesProof);
    euint64 price  = FHE.fromExternal(encPrice, priceProof);
}
```

### AGENT MISTAKE #12 — Bit width mismatch between client and Solidity

**What Claude does:** calls `input.add64()` for a value the contract receives as `externalEuint32`.

**What breaks:** `FHE.fromExternal` reverts with a type mismatch error on-chain. No compile-time warning.

```typescript
// Match the bit width in your encrypt call to the Solidity parameter type
input.add64(BigInt(amount)); // for externalEuint64
input.add32(amount);         // for externalEuint32
input.add8(amount);          // for externalEuint8
```

**Complete correct client-side encrypt:**
```typescript
const instance = await getFhevmInstance();
const input = await instance.createEncryptedInput(CONTRACT_ADDRESS, userAddress);
input.add64(BigInt(sharesAmount));
const encrypted = await input.encrypt();

await contract.issueShares(
  holderAddress,
  encrypted.handles[0],   // externalEuint64
  encrypted.inputProof,   // bytes calldata — immediately after
  priceEncrypted.handles[0],
  priceEncrypted.inputProof,
);
```

---

## SECTION 8 — ACCESS CONTROL (ACL)

### AGENT MISTAKE #13 — Missing FHE.allow for the value holder

**What Claude does from docs:** calls `FHE.allowThis()` after every write (correct) but forgets `FHE.allow(value, holderAddress)`.

**What breaks:** This is the most deceptive failure in the entire stack. The relayer returns a valid-looking response. No error is thrown. The decrypted value is 0. There is no access denied message — the relayer silently returns meaningless data because the reencryption key lookup finds nothing valid for that address.

**Three calls required after every encrypted state write:**
```solidity
balances[holder] = FHE.add(balances[holder], amount);

FHE.allowThis(balances[holder]);     // contract can use in future txs
FHE.allow(balances[holder], holder); // holder can decrypt their own balance
FHE.allow(balances[holder], owner()); // owner can audit
```

**ACL grants are permanent.** `FHE.allow` writes to the ACL contract storage. In v0.11.x there is no revoke. Design contracts with this in mind.

**ACL checklist — run for every function that writes encrypted state:**
- [ ] `FHE.allowThis(value)` after every assignment?
- [ ] `FHE.allow(value, holder)` for every party that will decrypt?
- [ ] `FHE.allow(value, owner())` for compliance access?
- [ ] If value is reassigned in a later tx, are ACL grants re-applied to the new handle?

---

## SECTION 9 — USER DECRYPTION

User decryption uses the Zama Relayer. The user signs an EIP-712 message proving wallet ownership. The relayer verifies ACL access on-chain, re-encrypts the plaintext under an ephemeral key, returns it. Total time: 4–15 seconds. This is real cryptography, not a local lookup.

### AGENT MISTAKE #14 — App contract address in EIP-712 domain

**What Claude does from docs:** passes the application contract address as `verifyingContract`.

**What breaks:** The relayer rejects with `Error: signature verification failed` — no further detail. The domain must use the ACL contract address.

```typescript
// WRONG — app contract address
const eip712 = instance.createEIP712(publicKey, APP_CONTRACT_ADDRESS);

// CORRECT — ACL contract address
const ACL = '0xFeE8407E2F5E3ee68AD77cAE98C434e637f516ec' as `0x${string}`;
const eip712 = instance.createEIP712(publicKey, ACL);
```

### AGENT MISTAKE #15 — Accessing .value on userDecrypt result

**What Claude does:** TypeScript types mislead Claude into writing `clearValues[handle].value`.

**What breaks:** `TypeError: Cannot convert undefined to BigInt`. The `ClearValueType` is the plaintext value directly — a `bigint` for `euint64`. It has no `.value` property.

```typescript
// WRONG — .value does not exist
const amount = BigInt(clearValues[handle].value);

// CORRECT — the result IS the value
const amount = clearValues[handle] as bigint;
```

### AGENT MISTAKE #16 — Un-padded handles passed to userDecrypt

**What Claude does:** passes the handle as returned by wagmi without padding.

**What breaks:** wagmi returns `bytes32` as `0x`-prefixed hex. The numeric value may be shorter than 32 bytes. Un-padded handles produce garbled decrypt results or relayer errors.

```typescript
// Always pad to 32 bytes (64 hex chars)
const padded = ('0x' + BigInt(rawHandle).toString(16).padStart(64, '0')) as `0x${string}`;
```

**Complete correct userDecrypt:**
```typescript
async function decryptValue(
  rawHandle: `0x${string}`,
  contractAddress: `0x${string}`,
  signer: WalletClient
): Promise<bigint> {
  if (BigInt(rawHandle) === 0n) return 0n; // filter zero handles

  const instance = await getFhevmInstance();
  const handle = ('0x' + BigInt(rawHandle).toString(16).padStart(64, '0')) as `0x${string}`;

  const { publicKey, privateKey } = instance.generateKeypair();
  const ACL = '0xFeE8407E2F5E3ee68AD77cAE98C434e637f516ec' as `0x${string}`;
  const eip712 = instance.createEIP712(publicKey, ACL); // ACL address, not app contract
  const signature = await signer.signTypedData(eip712);

  const results = await instance.userDecrypt(
    [{ handle, contractAddress }],
    privateKey, publicKey, signature, contractAddress, signer.account.address,
  );

  return results[handle] as bigint; // IS the value — no .value wrapper
}
```

**Decrypt multiple handles in ONE signature — never call userDecrypt once per handle:**
```typescript
async function decryptMultiple(
  rawHandles: `0x${string}`[],
  contractAddress: `0x${string}`,
  signer: WalletClient
): Promise<bigint[]> {
  const instance = await getFhevmInstance();
  const { publicKey, privateKey } = instance.generateKeypair();
  const ACL = '0xFeE8407E2F5E3ee68AD77cAE98C434e637f516ec' as `0x${string}`;
  const signature = await signer.signTypedData(instance.createEIP712(publicKey, ACL));

  const validPairs = rawHandles
    .filter(h => BigInt(h) !== 0n)
    .map(h => ({
      handle: ('0x' + BigInt(h).toString(16).padStart(64, '0')) as `0x${string}`,
      contractAddress,
    }));

  if (validPairs.length === 0) return rawHandles.map(() => 0n);

  const results = await instance.userDecrypt(
    validPairs, privateKey, publicKey, signature, contractAddress, signer.account.address,
  );

  return rawHandles.map(h => {
    const padded = ('0x' + BigInt(h).toString(16).padStart(64, '0')) as `0x${string}`;
    return BigInt(h) === 0n ? 0n : (results[padded] as bigint ?? 0n);
  });
}
```

**BigInt serialization — prevent crashes before React state or JSON:**
```typescript
// WRONG
setState({ shares: decryptedBigInt }); // JSON.stringify crashes

// CORRECT
setState({ shares: Number(decryptedBigInt) });
// or for large values:
setState({ shares: decryptedBigInt.toString() });
```

---

## SECTION 10 — CONTRACT STRUCTURE TEMPLATE

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint64, externalEuint64, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ConfidentialVault is ZamaEthereumConfig, Ownable {

    mapping(address => euint64) private balances;

    event Deposited(address indexed holder);
    event Transferred(address indexed from, address indexed to);

    constructor() Ownable(msg.sender) {}

    function deposit(externalEuint64 inputHandle, bytes calldata inputProof) external {
        euint64 amount = FHE.fromExternal(inputHandle, inputProof);
        balances[msg.sender] = FHE.add(balances[msg.sender], amount);

        FHE.allowThis(balances[msg.sender]);
        FHE.allow(balances[msg.sender], msg.sender);
        FHE.allow(balances[msg.sender], owner());

        emit Deposited(msg.sender);
    }

    function transfer(address to, externalEuint64 inputHandle, bytes calldata inputProof) external {
        euint64 amount = FHE.fromExternal(inputHandle, inputProof);
        ebool canTransfer = FHE.gte(balances[msg.sender], amount);
        euint64 newSender   = FHE.select(canTransfer, FHE.sub(balances[msg.sender], amount), balances[msg.sender]);
        euint64 newReceiver = FHE.select(canTransfer, FHE.add(balances[to], amount), balances[to]);

        balances[msg.sender] = newSender;
        balances[to] = newReceiver;

        FHE.allowThis(balances[msg.sender]);
        FHE.allow(balances[msg.sender], msg.sender);
        FHE.allow(balances[msg.sender], owner());

        FHE.allowThis(balances[to]);
        FHE.allow(balances[to], to);
        FHE.allow(balances[to], owner());

        emit Transferred(msg.sender, to);
    }

    function getBalance() external view returns (euint64) {
        return balances[msg.sender];
    }
}
```

---

## SECTION 11 — HARDHAT TESTING

```typescript
import { ethers } from "hardhat";
import { fhevm } from "hardhat";
import { FhevmType } from "@fhevm/hardhat-plugin";

describe("ConfidentialVault", () => {
  it("deposits and reads balance", async () => {
    const [, user] = await ethers.getSigners();
    const vault = await (await ethers.getContractFactory("ConfidentialVault")).deploy();

    const enc = await fhevm
      .createEncryptedInput(await vault.getAddress(), user.address)
      .add64(1000n)
      .encrypt();

    await vault.connect(user).deposit(enc.handles[0], enc.inputProof);

    const handle = await vault.connect(user).getBalance();
    const decrypted = await fhevm.userDecryptEuint(
      FhevmType.euint64, handle, await vault.getAddress(), user
    );
    expect(decrypted).to.equal(1000n);
  });
});
```

**Hardhat compile hangs on license prompt in scripts — fix:**
```bash
echo "n" | npx hardhat compile
```

---

## SECTION 12 — FRONTEND TRANSACTION PATTERN

### AGENT MISTAKE #17 — Showing success before transaction is mined

**What Claude does:** shows success immediately when `writeContract` returns a hash.

**What breaks:** `writeContract` resolves the moment the transaction hits the mempool — before mining, before success or revert. If the transaction reverts on-chain, the user sees success in the UI and failure on Etherscan.

```typescript
// WRONG
const hash = await writeContractAsync({ ... });
setSuccess(true); // fires before tx is mined

// CORRECT
const hash = await writeContractAsync({ ... });
const receipt = await waitForTransactionReceipt(publicClient, { hash });
if (receipt.status === 'success') {
  setSuccess(true);
} else {
  setError('Transaction reverted on-chain — check Etherscan');
}
```

**getLogs block range — public Sepolia RPC rejects ranges over 50,000 blocks:**
```typescript
const latestBlock = await publicClient.getBlockNumber();
const logs = await publicClient.getLogs({
  address: CONTRACT_ADDRESS,
  fromBlock: latestBlock - 49000n > 0n ? latestBlock - 49000n : 0n,
  toBlock: latestBlock,
});
```

---

## SECTION 13 — SEPOLIA DEPLOYMENT CONFIG

```typescript
// Verified correct for @fhevm/solidity v0.11.1 + @zama-fhe/relayer-sdk v0.4.2
// Wrong checksum on any address causes isAddress() to return false — silent failure
const SEPOLIA_CONFIG = {
  aclContractAddress:           '0xFeE8407E2F5E3ee68AD77cAE98C434e637f516ec',
  kmsContractAddress:           '0x9D6AdBFC60F55C1B3b694F3FbdD2497e23B35f1f',
  inputVerifierContractAddress: '0x3a2DA6e1D3c6a8bB2e2bA35f21C8d4c45e7F8A3a',
  relayerUrl:                   'https://relayer.testnet.zama.org',
  relayerRouteVersion:          2,
  chainId:                      11155111,
};
```

**Full deployment checklist:**
- [ ] Contract extends `ZamaEthereumConfig`
- [ ] All inputs use `FHE.fromExternal(handle, proof)` before use
- [ ] Every state write followed by `FHE.allowThis()` + `FHE.allow()` for all consumers
- [ ] No `if/else` on encrypted values — only `FHE.select()`
- [ ] No `FHE.decrypt()` for dynamic values
- [ ] Deployed on Sepolia (chainId 11155111)
- [ ] Verified on Etherscan
- [ ] WASM files in `public/`
- [ ] `optimizeDeps.exclude` set
- [ ] `nodePolyfills({ buffer: true, global: true })` in Vite plugins
- [ ] SDK alias pointing to `relayer-sdk-js.js`
- [ ] `.vite` cache cleared after config changes
- [ ] `initSDK` called once as singleton
- [ ] `relayerRouteVersion: 2`
- [ ] `thread: 0`
- [ ] All handles padded to 64 hex chars before userDecrypt
- [ ] Zero handles filtered before userDecrypt
- [ ] ACL address (not app contract) in EIP-712 domain
- [ ] `waitForTransactionReceipt` used before showing success

---

## SECTION 14 — PUBLIC DECRYPTION

Use when a value should become visible to everyone after a reveal phase — election results, auction winners.

```solidity
contract ConfidentialVote is ZamaEthereumConfig {

    euint64 private encryptedTally;
    uint64 public revealedTally;
    bool public tallyRevealed;

    function revealTally() external onlyOwner {
        FHE.allowThis(encryptedTally); // mandatory before gateway request

        uint256[] memory cts = new uint256[](1);
        cts[0] = Gateway.toUint256(encryptedTally);
        Gateway.requestDecryption(cts, this.tallyCallback.selector, 0, block.timestamp + 100, false);
    }

    function tallyCallback(uint256 /*requestId*/, uint64 plaintext) public onlyGateway {
        revealedTally = plaintext;
        tallyRevealed = true;
        emit TallyRevealed(plaintext);
    }

    event TallyRevealed(uint64 tally);
}
```

Rules:
- `FHE.allowThis(value)` must be called before `Gateway.requestDecryption`
- Callback must be `onlyGateway`
- Public decryption is async — plaintext not available in same transaction
- Once revealed the value is public forever

---

## SECTION 15 — ERC-7984: CONFIDENTIAL TOKEN STANDARD

ERC-7984 is the encrypted equivalent of ERC-20. Balances and amounts are always encrypted.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint64, externalEuint64, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract ConfidentialToken is ZamaEthereumConfig, Ownable {

    mapping(address => euint64) private _balances;
    string public name;
    string public symbol;

    event Transfer(address indexed from, address indexed to);  // no amount
    event Approval(address indexed owner, address indexed spender); // no amount

    constructor(string memory _name, string memory _symbol) Ownable(msg.sender) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, externalEuint64 inputHandle, bytes calldata inputProof) external onlyOwner {
        euint64 amount = FHE.fromExternal(inputHandle, inputProof);
        _balances[to] = FHE.add(_balances[to], amount);
        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allow(_balances[to], owner());
        emit Transfer(address(0), to);
    }

    function transfer(address to, externalEuint64 inputHandle, bytes calldata inputProof) external returns (bool) {
        euint64 amount = FHE.fromExternal(inputHandle, inputProof);
        ebool canTransfer = FHE.gte(_balances[msg.sender], amount);
        euint64 actual = FHE.select(canTransfer, amount, FHE.asEuint64(0));

        _balances[msg.sender] = FHE.sub(_balances[msg.sender], actual);
        _balances[to] = FHE.add(_balances[to], actual);

        FHE.allowThis(_balances[msg.sender]);
        FHE.allow(_balances[msg.sender], msg.sender);
        FHE.allow(_balances[msg.sender], owner());

        FHE.allowThis(_balances[to]);
        FHE.allow(_balances[to], to);
        FHE.allow(_balances[to], owner());

        emit Transfer(msg.sender, to);
        return true;
    }

    // Returns handle — caller must have FHE.allow() grant to decrypt
    function balanceOf(address account) external view returns (euint64) {
        return _balances[account];
    }
}
```

**Key ERC-7984 differences from ERC-20:**
- `balanceOf()` returns `euint64` handle, not plaintext `uint256`
- Events emit only addresses — no amounts (amounts are encrypted)
- Wrap/unwrap reveals the wrap amount publicly — this is by design

---

## SECTION 16 — OPENZEPPELIN CONFIDENTIAL CONTRACTS

```bash
npm install @openzeppelin/contracts-fhevm @openzeppelin/contracts
```

```solidity
import { ConfidentialERC20 } from "@openzeppelin/contracts-fhevm/token/ERC20/ConfidentialERC20.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

// OZ base implements transfer/approve with correct FHE patterns — do not rewrite these
contract MyToken is ConfidentialERC20, ZamaEthereumConfig, Ownable {
    constructor(string memory name, string memory symbol)
        ConfidentialERC20(name, symbol) Ownable(msg.sender) {}

    function mint(address to, uint64 amount) external onlyOwner {
        _mint(to, amount); // OZ base handles allowThis and allow internally
    }
}
```

```solidity
import { ConfidentialERC20Wrapped } from "@openzeppelin/contracts-fhevm/token/ERC20/extensions/ConfidentialERC20Wrapped.sol";

// wrap() and unwrap() inherited — wrap public ERC-20 into confidential
contract WrappedUSDC is ConfidentialERC20Wrapped, ZamaEthereumConfig {
    constructor(address usdcAddress)
        ConfidentialERC20Wrapped("Confidential USDC", "cUSDC", usdcAddress) {}
}
```

Rules:
- Always extend `ZamaEthereumConfig` alongside OZ base — it does not include it
- Do not override `_transfer()` unless you re-implement all ACL grants correctly
- OZ base uses `euint64` — write your own base for larger amounts

---

## SECTION 17 — COMPLETE ANTI-PATTERN REFERENCE

Every row below is a real failure encountered during production development. Rows marked **[AGENT]** are mistakes Claude made when working from documentation alone.

| # | Never do this | Exact error produced | Correct alternative |
|---|---|---|---|
| 1 [AGENT] | `npm install fhevmjs` | Error shows as `{}` — Error.message non-enumerable | `npm install @zama-fhe/relayer-sdk` |
| 2 [AGENT] | Import from bare package name | `TypeError: initSDK is not a function` | Import from `@zama-fhe/relayer-sdk/bundle` |
| 3 [AGENT] | `import "fhevm/lib/TFHE.sol"` | `DeclarationNotFound` | `import { FHE } from "@fhevm/solidity/lib/FHE.sol"` |
| 4 [AGENT] | Manual `globalThis.Buffer` only | `TextEncoder is not defined` | `nodePolyfills({ buffer: true, global: true })` |
| 5 [AGENT] | COOP/COEP headers in Vite | `WebAssembly compilation aborted: Network error` | Remove headers, use `thread: 0` |
| 6 [AGENT] | `createInstance(...)` | `TypeError: createInstance is not a function` | `initSDK(...)` |
| 7 [AGENT] | `relayerRouteVersion: 1` | 404 on `/v1/keyurl`, silent hang | `relayerRouteVersion: 2` |
| 8 [AGENT] | `zama.ai` domain | NXDOMAIN, `wrong gateway url` | `relayer.testnet.zama.org` |
| 9 [AGENT] | Wrong ACL address checksum | `ACL contract address is not valid` | Use exact EIP-55 checksum |
| 10 [AGENT] | Multiple `initSDK` calls | Random WASM memory corruption | Singleton pattern |
| 11 [AGENT] | inputProof at wrong position | `FHE: invalid proof` revert | Proof immediately after each externalEuintX |
| 12 [AGENT] | `add64()` for `euint32` param | Type mismatch revert on-chain | Match bit width exactly |
| 13 [AGENT] | Missing `FHE.allow(value, holder)` | Decrypt succeeds, returns 0 silently | Three ACL calls after every write |
| 14 [AGENT] | App contract in EIP-712 domain | `signature verification failed` | ACL contract address in domain |
| 15 [AGENT] | `clearValues[handle].value` | `Cannot convert undefined to BigInt` | `clearValues[handle] as bigint` |
| 16 [AGENT] | Un-padded handle to userDecrypt | Garbled decrypt or relayer error | Pad to 64 hex chars |
| 17 [AGENT] | Show success on `writeContract` hash | Success shown for reverted txs | `waitForTransactionReceipt` first |
| 18 | `if (encryptedVal > 0)` | Compile error | `FHE.select(FHE.gt(val, zero), ...)` |
| 19 | Store `externalEuintX` in state | Unverified ciphertext stored | `FHE.fromExternal()` before any use |
| 20 | `getLogs` with >50k block range | `exceeded maximum block range: 50000` | Cap at 49,000 blocks |
| 21 | Missing `optimizeDeps.exclude` | WASM silently never loads, no error | Exclude `@zama-fhe/relayer-sdk/bundle` |
| 22 | Stale `.vite` cache after config change | Old broken bundle still served | `rm -rf node_modules/.vite` |
| 23 | WASM files missing from `public/` | `initSDK` promise never resolves | Copy 3 WASM files to `public/` |
