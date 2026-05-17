# FHEVM SKILL.md — Built From Real Production Failures
### Zama Developer Program Season 2 — SKILL.md Bounty Track

> Most SKILL.md submissions are documentation reformatted for AI agents.
> This one was built differently.

---

## How This Was Built

We built **two production FHEVM dApps** deployed live on Ethereum Sepolia and debugged every failure end to end. Then we gave Claude the AI agent  the task of building FHEVM contracts using only documentation. It made **17 mistakes**.

Not hypothetical mistakes. Real failures. Each one with an exact error message, an exact cause, and an exact fix that was verified on a live Sepolia deployment, Those 17 mistakes plus every other production failure encountered across both dApps are the foundation of this SKILL.md.


## The 17 Mistakes Claude Makes Without This Skill File

Every row below is a confirmed AI agent failure something Claude produces when working from documentation alone. The error column is the exact message that appears. The fix column is what actually works on Sepolia.

### SDK & Package Failures

**MISTAKE #1 - Wrong package entirely**
```
What Claude does:  npm install fhevmjs
Error produced:    Error object shows as {} in console
                   (Error.message is non-enumerable disappears in JSON.stringify)
                   createInstance returns undefined silently
                   Every encrypt call throws with no visible message
Root cause:        fhevmjs v0.6.x bundle checks window.fhevmjs which is never
                   set in a Vite/ESM environment. The wrapper returns undefined.
Fix:               npm install @zama-fhe/relayer-sdk
```

**MISTAKE #2 — Importing from the bare package name**
```
What Claude does:  import { initSDK } from '@zama-fhe/relayer-sdk'
Error produced:    TypeError: initSDK is not a function
Root cause:        The npm package main entry is a window.relayerSDK shim for
                   script-tag injection. All exports are undefined in ESM context.
                   No error at import time fails silently until first use.
Fix:               import { initSDK } from '@zama-fhe/relayer-sdk/bundle'
```

**MISTAKE #3 — Wrong Solidity import path**
```
What Claude does:  import "fhevm/lib/TFHE.sol";  TFHE.add(a, b);
Error produced:    DeclarationNotFound looks like a missing contract error
Root cause:        Old unscoped package uses TFHE. New scoped package uses FHE.
                   Error message gives no indication it's a version mismatch.
Fix:               import { FHE } from "@fhevm/solidity/lib/FHE.sol";  FHE.add(a, b);
```

---

### Vite & Browser Environment Failures

**MISTAKE #4 — Incomplete Node.js polyfill**
```
What Claude does:  import { Buffer } from 'buffer'; globalThis.Buffer = Buffer;
Error produced:    TextEncoder is not defined
                   crypto.getRandomValues is not available
Root cause:        Manual Buffer patch misses global.TextEncoder, global.crypto,
                   and other Node globals the SDK uses internally.
Fix:               npm install vite-plugin-node-polyfills
                   nodePolyfills({ buffer: true, global: true }) in vite.config.ts
```

**MISTAKE #5 — COOP/COEP headers in Vite config**
```
What Claude does:  server: { headers: { 'Cross-Origin-Embedder-Policy': 'require-corp' } }
Error produced:    WebAssembly compilation aborted: Network error
Root cause:        COEP blocks cross-origin resources behind any reverse proxy
                   (Replit, Vercel previews, Netlify, GitHub Codespaces).
                   WASM fetch fails. No useful error message.
Fix:               Remove COOP/COEP headers entirely. Use thread: 0 in initSDK.
```

---

### FHE Instance Initialization Failures

**MISTAKE #6 — Wrong function name**
```
What Claude does:  const instance = await createInstance({ ... })
Error produced:    TypeError: createInstance is not a function
Root cause:        createInstance was the v0.6.x API name.
                   The relayer-sdk v0.4.2 renamed it to initSDK.
Fix:               const instance = await initSDK({ ... })
```

**MISTAKE #7 — Wrong relayer route version**
```
What Claude does:  relayerRouteVersion: 1
Error produced:    404 Not Found — fetch hangs then throws unstructured error
                   No indication in the error of which URL failed
Root cause:        /v1/keyurl endpoint no longer exists on the relayer.
Fix:               relayerRouteVersion: 2   (/v2/keyurl is the working endpoint)
```

**MISTAKE #8 — Wrong relayer domain**
```
What Claude does:  relayerUrl: 'https://gateway.sepolia.zama.ai'
                   relayerUrl: 'https://relayer.testnet.zama.ai'
Error produced:    Impossible to fetch public key: wrong gateway url
Root cause:        Both .ai domains return NXDOMAIN verified against Google DNS
                   (8.8.8.8) and Cloudflare (1.1.1.1). They simply do not exist.
Fix:               relayerUrl: 'https://relayer.testnet.zama.org'  (.org not .ai)
```

**MISTAKE #9 — Wrong ACL address checksum**
```
What Claude does:  aclContractAddress: '0xFee8407e2f5e3Ee68ad77cAE98c434e637f516EC'
Error produced:    ACL contract address is not valid or empty
Root cause:        SDK calls viem's isAddress() on every config address.
                   EIP-55 checksum is case-sensitive. One wrong character = false.
Fix:               aclContractAddress: '0xFeE8407E2F5E3ee68AD77cAE98C434e637f516ec'
                   (exact case required copy this exactly)
```

**MISTAKE #10 — Calling initSDK multiple times**
```
What Claude does:  Calls initSDK() inside components or per-transaction
Error produced:    Random WASM memory corruption crashes vary each run
Root cause:        Multiple parallel initSDK calls race and corrupt internal
                   WASM memory. Symptoms are non-deterministic and impossible
                   to reproduce reliably.
Fix:               Singleton pattern call initSDK once on app startup, cache result
```

---

### Input Handling Failures

**MISTAKE #11 — inputProof at wrong position**
```
What Claude does:  function issue(externalEuint64 a, externalEuint64 b, bytes proof)
Error produced:    FHE: invalid proof  (custom precompile error, no further detail)
Root cause:        Each inputProof must immediately follow its externalEuintX handle.
                   Grouping proofs at the end fails proof verification silently.
Fix:               function issue(externalEuint64 a, bytes proofA,
                                  externalEuint64 b, bytes proofB)
```

**MISTAKE #12 — Bit width mismatch**
```
What Claude does:  input.add64(amount)  for a contract param typed externalEuint32
Error produced:    Type mismatch revert on-chain. No compile-time warning.
Root cause:        Client-side encrypt bit width must match Solidity parameter type exactly.
Fix:               input.add32(amount)  for externalEuint32
                   input.add64(amount)  for externalEuint64
```

---

### Access Control (ACL) Failures

**MISTAKE #13 — Missing FHE.allow for the value holder**
```
What Claude does:  Calls FHE.allowThis() but forgets FHE.allow(value, holder)
Error produced:    NO ERROR this is the most dangerous failure in the stack
                   userDecrypt returns a valid response
                   The decrypted value is 0
                   The relayer silently returns meaningless data
Root cause:        The relayer verifies ACL access. Without FHE.allow(value, holder),
                   the reencryption key lookup finds nothing and returns 0.
                   There is no access denied message. You only discover it when
                   you decrypt and get wrong values.
Fix:               After every encrypted state write three calls mandatory:
                   FHE.allowThis(value);        // contract access
                   FHE.allow(value, holder);    // holder can decrypt
                   FHE.allow(value, owner());   // owner/regulator can audit
```

---

### Decryption Failures

**MISTAKE #14 — App contract address in EIP-712 domain**
```
What Claude does:  instance.createEIP712(publicKey, APP_CONTRACT_ADDRESS)
Error produced:    signature verification failed  (no further detail from relayer)
Root cause:        The EIP-712 domain verifyingContract must be the ACL contract
                   address, not the application contract address.
Fix:               const ACL = '0xFeE8407E2F5E3ee68AD77cAE98C434e637f516ec'
                   instance.createEIP712(publicKey, ACL)
```

**MISTAKE #15 — Accessing .value on userDecrypt result**
```
What Claude does:  const amount = BigInt(clearValues[handle].value)
Error produced:    TypeError: Cannot convert undefined to BigInt
Root cause:        ClearValueType IS the value a bigint directly.
                   It is not a wrapper object. .value does not exist.
                   TypeScript types in the package are misleading here.
Fix:               const amount = clearValues[handle] as bigint
```

**MISTAKE #16 — Un-padded handles passed to userDecrypt**
```
What Claude does:  Passes handle as returned by wagmi directly to userDecrypt
Error produced:    Garbled decrypt result or relayer error no clear message
Root cause:        wagmi returns bytes32 as 0x-prefixed hex. Numeric value may be
                   shorter than 32 bytes. Un-padded handle = wrong key lookup.
Fix:               const padded = ('0x' + BigInt(handle).toString(16).padStart(64,'0'))
                   Always pad to 64 hex characters (32 bytes) before userDecrypt
```

---

### Transaction Failures

**MISTAKE #17 — Showing success before transaction is mined**
```
What Claude does:  const hash = await writeContractAsync({...}); setSuccess(true)
Error produced:    UI shows success. Etherscan shows failed transaction.
Root cause:        writeContractAsync resolves when tx hits mempool — before mining.
                   If tx reverts on-chain, user sees success in UI, failure on-chain.
Fix:               const receipt = await waitForTransactionReceipt(client, { hash })
                   if (receipt.status === 'success') setSuccess(true)
```

---

## A Discovery Nobody Else Will Have

**`Gateway.sol` does not exist in `@fhevm/solidity v0.11.1`.**

We discovered this by trying to compile a contract that imported it. Running:
```bash
find node_modules/@fhevm -name "Gateway*"
```
Returns empty. The file is simply not in the package — confirmed across `@fhevm/solidity`, `@fhevm/host-contracts`, `@fhevm/mock-utils`, and `@fhevm/hardhat-plugin`.

Public decryption via on-chain Gateway callback was removed from v0.11.1. All decryption including owner/regulator audit access happens off-chain via the Zama Relayer using `userDecrypt()`. The SKILL.md documents the correct alternative pattern and flags this version-specific behavior explicitly.

No documentation mentions this. You only find it by compiling.

---

## Additional Production Findings

Beyond the 17 agent mistakes, real deployment revealed:

- **getLogs block range limit** - public Sepolia RPC rejects `eth_getLogs` with range >50,000 blocks. Error: `exceeded maximum block range: 50000`. Cap at 49,000.
- **Stale Vite cache** - after changing `resolve.alias` or `optimizeDeps`, the old broken bundle is still served. Run `rm -rf node_modules/.vite` after every config change.
- **WASM silent hang** — if WASM files are missing from `public/`, `initSDK` promise never resolves. No error thrown. Three files required: `tfhe_bg.wasm`, `kms_lib_bg.wasm`, `workerHelpers.js`.
- **FHE ready before WASM compiled** — `initSDK` can resolve before internal WASM compilation completes. Gate "FHE Ready" on `instance.generateKeypair()` succeeding, not just `instance !== null`.
- **Hardhat compile hangs in CI** — interactive license prompt blocks non-interactive environments. Fix: `echo "n" | npx hardhat compile`.
- **BigInt serialization crash** — passing decrypted `bigint` to React state or `JSON.stringify` throws. Convert with `Number(val)` or `.toString()` first.
- **Zero handle filtering** — un-issued encrypted values are stored as `bytes32(0)`. Passing to `userDecrypt` causes relayer error. Always filter: `BigInt(handle) !== 0n`.

---

## What the SKILL.md Covers

17 sections, 23 documented anti-patterns, complete coverage of the Zama judging criteria:

| Judging Criterion | Covered In |
|---|---|
| FHEVM architecture overview | Section 1 |
| Encrypted types | Section 5 |
| FHE operations | Section 6 |
| Access control | Section 8 |
| Input proofs | Section 7 |
| User decryption EIP-712 | Section 9 |
| Public decryption | Section 14 |
| Frontend integration | Sections 3, 9 |
| Hardhat testing | Section 11 |
| Anti-patterns | Section 17 (23 rows) |
| ERC-7984 confidential token | Section 15 |
| OpenZeppelin Confidential Contracts | Section 16 |
| Dev environment setup | Sections 2, 3 |
| Deployment checklist | Section 13 |

---

## Validated Against

```
@fhevm/solidity              v0.11.1
@zama-fhe/relayer-sdk        v0.4.2
Ethereum Sepolia             chainId 11155111
Relayer                      https://relayer.testnet.zama.org (v2 endpoint)
AI agents tested             Claude (claude.ai, Claude Code)
```

---

## Demo Video

[Watch →](#) *(https://youtube.com/shorts/b8xt9TlC8no?feature=share)*

Shows Claude generating a correct FHEVM contract from a natural language prompt using only this SKILL.md — compiled with zero errors on first generation.

---

*Zama Developer Program Season 2 — May 2026*
