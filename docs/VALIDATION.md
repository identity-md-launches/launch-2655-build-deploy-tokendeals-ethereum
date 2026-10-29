# Validation and review notes

The production surface is `src/TokenDeals.sol` and its vendored OpenZeppelin dependencies. The deployment unit is the direct `TokenDeals` application; scripts, mocks, handlers and tests are not application contracts.

## Test map

| Test source | Behavior checked |
| --- | --- |
| `TokenDealsFlows.t.sol` | Fixed configuration and exact events; full ETH, USDC, USDT, IMD and SHIFT settlements; partial buys and remainder exemption; public/private and sponsored recipient buys; opening validation; expiry, unknown/cancelled/filled deals; maxTotal and inclusive caps; exact msg.value; seller-only updates/cancels; pause; removal of payment coins; 2% taxed deposits and outgoing transfers; no-return sale token; transfer failures and atomic rollback |
| `TokenDealsPasses.t.sol` | EIP-712 metadata; 1%/0.5% behavior and odd rounding; recipient-bound passes; wrong signer/recipient/chain/contract; live chain ID change; expiration boundaries; altered expiry; signer rotation/disable; empty/malformed/high-s/bad-v signatures; intentional pass reuse |
| `TokenDealsMath.t.sol` | Independent ceiling/floor arithmetic oracle; odd values and one-unit trades; 512-bit multiplication; large fees without intermediate overflow; unrepresentable cost/total; fuzzed quotes and exact ETH/coin payouts with and without passes |
| `TokenDealsAdmin.t.sol` | All admin access checks and setter events; fee bounds and fuzzed invalid settings; fee-change price protection; pause transitions; new payment coins; no custody/ownership/upgrade/fee-redirection selectors; unsolicited-token exclusion and no forced-ETH recovery |
| `TokenDealsAdversarial.t.sol` | Reentry from malicious tokens, sellers, fee receiver and recipient hooks; all 11 mutable entrypoints guarded; failed and gas-exhausting ETH pushes; large returndata; credit accumulation, failed claims, paused claims and double-claim prevention; seller also FeeSplitter; atomic failure of payment payouts; zero-fee payout omission; payment coins simultaneously held as sale escrow |
| `TokenDealsInvariant.t.sol` | Mixed stateful sequences across six assets, five payment currencies and four sellers: escrow backing, immutable held, complete inventory conservation, exact payouts, donated-token isolation and ETH credit coverage |
| `TokenDealsDeployment.t.sol` | Empty-chain factory/CREATE2 construction; fixed owner independent of factory and origin; local deployment script; EIP-170/EIP-3860 size bounds; reachable runtime excludes DELEGATECALL, CALLCODE and SELFDESTRUCT |

The invariant handler creates and buys five deals before fuzzing, including a taxed token, both fee tiers, all payment currencies and a rejecting ETH seller followed by a successful claim. Checks therefore cannot pass solely because there were no purchases. Each randomized successful buy independently computes the expected cost and fee and checks the payer, seller, FeeSplitter and recipient balance changes. For a failed ETH push, the payout assertion includes credited ETH. Random actions include opens, partial buys, updates, cancellations, donations, time changes, fee/cap/allowlist/pause changes and claims.

For each tracked sale token, invariants assert:

```text
actual escrow balance >= sum(left for every open deal in that token)
sum(left) == independently tracked remaining inventory
actual escrow balance == remaining inventory + unsolicited donations
held == original receipt == left + purchased + cancelled
deal.open == (deal.left > 0)
ETH balance == total owed to sellers and FeeSplitter
```

Unexpected handler reverts fail the campaign. Ordinary preconditions are checked before attempted successful operations; deterministic failure tests cover rejection paths separately. Tests use isolated local mocks and cheatcodes, do not fork a remote chain, and neither read nor set environment variables.

## Implementation review

- **Authority:** the only mutable external application functions are `open`, `buy`, `update`, `cancel`, `claimOwed`, the four setters, and pause/unpause. All carry the same guard. The owner is a constant; no inherited Ownable transfer functions exist. The administrator cannot access another account's escrow or credits.
- **Accounting:** deposit receipt is a balance delta; donations are excluded. Purchases decrement inventory before any payment or sale-token transfer. Cancellation closes before return; claims clear credit before ETH transfer. Failed ERC-20 operations and failed claims revert all associated state. Successful coin settlements retain no payment surplus.
- **Reentry:** callbacks cannot enter any mutating function, including setters, during deposit reads/transfers, payment collection, token delivery, payouts, cancellation or claims. Recipient callbacks see already-decremented inventory.
- **Payment failures:** bounded ETH push gas prevents a hostile seller from consuming the entire transaction allocation. Unused low-level returndata is not copied. Failed pushes credit the original beneficiary; claims do not accept an alternate destination.
- **Signatures:** OpenZeppelin EIP712 binds chain and contract; ECDSA rejects malformed/high-s signatures. An explicitly unconfigured signer cannot accidentally validate a recovered zero address. Recipient and uint64 expiry are signed. No nonce is required by this discount-pass design; reuse is deliberate and documented.
- **Arithmetic:** sale amounts use the specified fixed 1e18 denominator, not inferred token decimals. Full-precision multiplication covers both cost and fee; price rounds up and fee rounds down. Caps and maxTotal apply to their sum.
- **Dependencies:** source-only, version-pinned OpenZeppelin and Forge Standard Library are included with licenses. Production library functions used by the application are internal and require no bytecode links.

This is an implementation self-review with executable regressions, not an independent audit. Slither and Mythril have not been run. Live token implementations, proxy changes, blocklists, rebasing behavior, the FeeSplitter's actual receiving/claiming behavior and the holder-eligibility service are external operational responsibilities. The requested fixed Ethereum addresses have not been substituted or inferred from third-party address tables. No mainnet transaction or explorer verification was performed by the worker.

## Reproduction

Use the three commands in the README with Solidity 0.8.26. The assigned fuzz seed is `0x85418f7cc939a04c698edeff24f1f353840822438cc0846fcf8eec49711d7e12`. Foundry uses 256 fuzz cases and 128 invariant sequences of 64 calls in the committed configuration. Runtime and deployment-size checks run as tests, independent of any saved artifact.

The completed local run used Foundry 1.8.3 and the pinned compiler:

| Check | Result |
| --- | --- |
| `forge build` | Passed |
| `forge test` with the assigned seed | 82 reported tests passed, 0 failed, 0 skipped, across 7 suites |
| Stateful campaign | All 3 invariants passed together; 128 runs, 8,192 calls, 0 unexpected reverts |
| `forge fmt --check` | Passed |
| Local `forge script` rehearsal | Passed, without broadcast |
| Application creation/runtime size | 9,634 / 7,443 bytes |
| Bytecode library link references | None |
| Dependency import closure | Every Solidity import resolves to an ordinary repository file |

`forge build` also reports heuristic lint warnings. These were reviewed rather than suppressed: timestamp comparisons implement the requested deadlines; zero is an intentional signer-disable value; ETH destinations are the recorded seller, fixed FeeSplitter or caller's own credit; all mutation paths hold the guard, and claims clear credit before interacting. Credit events necessarily follow the failed ETH call whose result they record. Payout calls ignore returndata; the adversarial suite exercises both large returndata and gas exhaustion. Test-time timestamp warnings concern `vm.warp`; the suite explicitly checks expired, renewed and boundary-time behavior. The build exits successfully with these diagnostics.

The supplied protected tests were read as inputs. Their environment-dependent launch attestation harness is run by the launch verifier, which supplies the factory, creation bytecode, salts and owner-check support. Local deployment tests rehearse the same size, opcode and empty-chain construction properties without requiring that environment. No supplied check was modified.
