# TokenDeals

Fixed-price ERC-20 escrow for Ethereum (chain ID **1**). Anyone can deposit a sale token, open a public or recipient-restricted deal, and sell it in one or more buys. Each buy atomically delivers tokens and pays the seller the full rounded price; the buyer pays the fee on top.

The application is [`src/TokenDeals.sol`](src/TokenDeals.sol). The launch deploys **TokenDeals only**. It is a direct, non-upgradeable contract, with a **nonpayable, zero-argument constructor**, no initialization transaction, no external constructor calls and no linked libraries. No launch token, pool or distributor is created.

## Build and check

```sh
forge build
FOUNDRY_FUZZ_SEED=0x85418f7cc939a04c698edeff24f1f353840822438cc0846fcf8eec49711d7e12 forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun EVM, optimizer runs **200**, IR compilation, and `bytecode_hash = "none"`. Fuzzing runs 256 cases per fuzz test. Stateful invariants run 128 sequences of depth 64, with unexpected handler reverts treated as failures. The seed above is the assignment's verification seed; tests do not read or modify environment variables.

All Solidity dependencies are vendored as ordinary files. No network, submodule, package install, FFI or filesystem permission is required to build or test with the pinned compiler installed. Versions, source archives, checksums and licenses are recorded in [`DEPENDENCIES.md`](DEPENDENCIES.md).

For a local deployment rehearsal, without a wallet, RPC or broadcast:

```sh
forge script script/DeployTokenDeals.s.sol:DeployTokenDeals
```

The script's `run()` is also tested directly. The independent launch service deploys the application's compiled creation bytecode through its factory after acceptance and review. This repository does not contain a launch manifest, mainnet deployment address or broadcast transaction. The launch handoff supplies the confirmed address and explorer verification.

## Fixed deployment parameters

| Parameter | Value |
| --- | --- |
| Application | `TokenDeals` |
| Network | Ethereum, chain ID 1 |
| Constructor arguments / value | None / 0 ETH |
| Permanent owner | `0x6c4c78f2c3bdf4c4318fe305fb1c8bc1694d19b5` |
| Permanent `FEE_TO` | NIGHTSHIFT FeeSplitter, `0x1119d5df2f046bc2d3c0f6279ef2e9ce49422d44` |
| Initial `feeBps` / `holderFeeBps` | 100 / 50 (1% / 0.5%) |
| `MAX_FEE_BPS` | 200 (2%), constant |
| `MAX_DEAL_LIFETIME` | 365 days |
| `MAX_PASS_LIFETIME` | 24 hours |
| `ETH_PUSH_GAS` | 50,000 per seller or FeeSplitter payout attempt |
| Initial `passSigner` | Unconfigured; nonempty passes revert until the owner sets it |

The administrator is compiled into the application. Neither the factory, transaction sender nor transaction origin receives ownership. There is no ownership transfer or renunciation function.

All five payment currencies are initially allowed:

| Coin | Ethereum address | Decimals | Initial cap in whole coins | `maxPay` in base units |
| --- | --- | ---: | ---: | ---: |
| ETH | `address(0)` | 18 | 1 | 1000000000000000000 |
| USDC | `0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48` | 6 | 2500 | 2500000000 |
| USDT | `0xdac17f958d2ee523a2206206994597c13d831ec7` | 6 | 2500 | 2500000000 |
| IMD | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` | 18 | 500 | 500000000000000000000 |
| SHIFT | `0xe5e58e53d0bb204aa62c995a6c8cc8a48e60c3ac` | 18 | 40000000 | 40000000000000000000000000 |

`maxPay` and the `max` argument to `setMaxPay` always use **payment-coin base units**, including wei for ETH. The cap includes both cost and fee. Zero disables the cap. An added coin initially has no cap unless one was set separately. No ERC-20 metadata is queried by the constructor or used in price arithmetic.

## Deal lifecycle and pricing

1. The seller approves TokenDeals for the desired sale amount and calls `open(token, amount, payCoin, price, minBuy, expiry, buyer)`. The token must have code and differ from the payment coin. Amount and price must be positive. The payment coin must currently be allowed. The expiry must be strictly in the future and at most 365 days away. `buyer = address(0)` makes the deal public.
2. The contract pulls from **msg.sender only** and measures its balance increase. That actual receipt becomes both `held` and `left`. `minBuy` can be zero, but cannot exceed the actual receipt. The first deal ID is 1; IDs are never reused.
3. A payer calls `buy(dealId, amount, recipient, maxTotal, passExpiry, pass)`. The recipient must be nonzero and must match the restricted buyer if one exists. The amount must be positive, at most `left`, and at least `minBuy`, except that the entire remainder can always be purchased. The deal must be open and `block.timestamp < expiry`.
4. Inventory decreases before settlement interactions. At zero inventory the deal closes automatically. `held` always remains the original receipt.
5. The seller may `update` an open deal's price, minimum and expiry. New price and expiry obey the opening rules; the new minimum must be at most **remaining** inventory. An expired but uncancelled deal may be renewed. Other fields never change.
6. The seller may `cancel` an open deal, including after expiry and during a pause. Cancellation sets `left = 0`, closes the deal and transfers the previous remainder to the seller. Filled or previously cancelled deals cannot be cancelled again.

Price is payment base units per **1e18 sale-token base units**, regardless of either token's decimals:

```text
cost  = ceil(amount * price / 1e18)       // full-precision Math.mulDiv
fee   = floor(cost * selectedBps / 10000)
total = cost + fee
```

Both multiplications use full-precision `Math.mulDiv`; an unrepresentable result or total reverts. Each buy rounds separately. Small fees can round to zero, and dividing a purchase into multiple transactions can change rounding dust.

For an 18-decimal sale token priced at 2 USDC per whole token, set `price = 2_000_000`. For a **6-decimal sale token** at the same 2 USDC per whole token, set `price = 2_000_000_000_000_000_000`: purchasing `1_000_000` sale base units costs `2_000_000` USDC base units. With the default normal fee the buyer pays `2_020_000` and the seller receives the full `2_000_000`.

`quote(dealId, amount, holder)` is an arithmetic preview using the current price and global fees. It rejects unknown IDs but does not validate inventory, minimum, expiry, pause, cap or holder eligibility. It accepts zero amounts and can preview closed deals. Use `deals` for availability and `maxTotal` to protect actual execution against price or fee changes.

`deals(id)` returns `(seller, token, payCoin, held, left, price, minBuy, expiry, buyer, open)`; unknown IDs return the default zero tuple. Unknown IDs revert in all deal actions and `quote`.

## Payment and recipient semantics

The **payer is msg.sender** and the **recipient receives the sale tokens**. They may differ, including on private deals. This supports a relayer or bridge service buying for a user without trusting it with any escrow privileges. A recipient-bound holder pass belongs to the recipient, not the payer.

For ETH deals, send exactly `total` as `msg.value`. Underpayment and overpayment both revert; there is no excess refund path. For coin deals, `msg.value` must be zero and the payer must approve at least `total` to TokenDeals. SafeERC20 supports USDT-style transfers that return no boolean. The contract pulls the total, delivers the sale tokens, then transfers cost to the seller and fee to the fixed FeeSplitter. Any ERC-20 transfer failure reverts the entire buy, including prior transfers and inventory changes.

Each ETH payout attempt forwards up to 50,000 gas. If the seller or FeeSplitter rejects ETH, runs out of that gas, or otherwise fails its call, that amount is added to `owed[beneficiary]`; the purchase still completes. This gas bound is a chosen operational constant to isolate hostile receivers. A recipient needing more gas can claim later.

`claimOwed()` clears the caller's credit before sending all of it **to the caller**, forwarding available gas. Failure reverts and restores the credit. Claims work while paused. A receiving contract must expose a way to call `claimOwed` and accept ETH during the claim. Credits cannot be redirected, claimed by an owner or third party, or paid to a different address. Multiple failed payouts accumulate; when the seller is also the FeeSplitter, both payments go to the same account.

## Holder passes

Holder eligibility is certified off chain by the owner's chosen ECDSA signer. TokenDeals does not inspect a holder's token balance or identify which holdings qualify.

The exact typed data is:

```text
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
    name              = "TokenDeals"
    version           = "1"
    chainId           = the live chain ID (1 for this launch)
    verifyingContract = the confirmed TokenDeals deployment address

HolderPass(address recipient,uint64 expiry)
```

Hash the struct with `abi.encode`, then sign the EIP-712 digest, not a personal-sign prefixed message. Supply the canonical **65-byte `r || s || v`** signature with low `s` and `v = 27` or `28`. Compact signatures and ERC-1271 contract signatures are not accepted. `eip712Domain()` exposes the live domain, and `HOLDER_PASS_TYPEHASH()` exposes the type hash.

A nonempty signature must recover the current nonzero `passSigner` for the specified recipient. At execution, `block.timestamp <= passExpiry <= block.timestamp + 24 hours`. Both endpoints are accepted. Wrong signer, recipient, expiry, chain, contract, encoding or malleable signature reverts; an invalid pass never silently falls back to normal fees.

Empty `pass` selects the normal fee and ignores `passExpiry`. Until a signer is configured, empty passes work and nonempty passes revert with `PassSignerNotConfigured`. Rotating the signer immediately revokes old signatures; setting it to zero explicitly disables passes again.

Passes intentionally have **no nonce and are reusable** for multiple buys and deals until expiry. They confer a fee discount, not spending authority. The payer must still supply payment on every call. Publishing a pass cannot redirect its recipient's discount to another recipient. Short expiries limit how long an attested holder can retain a discount after their qualifying holdings change.

## Administrative authority

The fixed owner can only:

- Set fees with `holderFeeBps <= feeBps <= 200`.
- Set or disable the holder-pass signer.
- Allow or disallow payment coins **for new deals only**.
- Change per-buy total caps, including for existing deals.
- Pause or unpause `open`, `update` and `buy`.

Those powers apply immediately. Fee changes affect buys of existing deals, with `maxTotal` bounding the buyer's payment. Removing a coin does not stop existing buys or updates. Raising or lowering its cap does affect them. Pausing does not stop seller cancellation or claims.

There are **no** functions for taking escrow, redirecting payments, closing someone else's deal, sweeping tokens, granting token allowances, changing `FEE_TO`, changing ownership, upgrading, delegatecalling, or destroying the contract. Tokens sent outside `open` are not assigned to any deal and remain in the contract permanently. Direct ETH sends are rejected; forcibly received ETH is not credited and has no recovery function.

Every state-changing application entrypoint has a reentrancy guard, including administrative functions. Buys, cancellations and claims apply state effects before interacting with recipients. Opening necessarily measures the deposit through external calls before recording its amount, with the same guard covering the entire operation.

## Supported tokens and assumptions

- Payment coins are plain, non-rebasing ERC-20s with exact transfers and honest balances. The owner must establish this before allowlisting a new one. Transfer-tax or rebasing payment coins are outside the supported model.
- Sale tokens may deduct tax from the transferred amount. Deposits use actual receipt; buys and cancellations debit their requested **gross** amount. A 2% tax delivers 98 of 100 units on deposit, then taxes outbound buys or cancellations again. There is no minimum-net-received parameter.
- Tokens that debit the sender more than the requested amount, rebase, lie about balances, arbitrarily confiscate funds or change to such behavior are not supported. A malicious ERC-20 can violate its own balance semantics; it cannot be made trustworthy by escrow accounting.
- A sale or payment token's pause, blocklist or transfer failure can stop operations involving it, including cancellation. Such failures roll back state; the owner cannot bypass token behavior or recover escrow through another path.
- Prices, caps and discounts are not exchange-rate oracles. The seller chooses the price; the owner configures payment policies. The signer operator determines holder eligibility.
- All fixed addresses are the requester's Ethereum addresses. Local tests install mock code at payment addresses and the FeeSplitter where needed; they do not establish the behavior of live third-party contracts.

## Events and indexing

The requested events and indexed fields are declared exactly in `TokenDeals.sol`: `DealOpened`, `Bought`, `DealUpdated`, `DealCancelled`, `OwedClaimed`, `FeesSet`, `PassSignerSet`, `PayCoinSet` and `MaxPaySet`.

Additional `OwedCredited(address indexed account, uint256 amount)` events make deferred ETH settlements explicit. OpenZeppelin's `Paused(address)` and `Unpaused(address)` expose pause changes. The constructor emits initial coin policies, caps, fees and the unconfigured signer. `Bought` reports gross sale amount, exact cost, fee and whether a valid pass was used. It is emitted before settlement interactions; any transaction revert removes all its logs. Indexers should also process `OwedCredited` and `OwedClaimed` to distinguish settled ETH from credited ETH.

## After launch

1. **Launch service:** deploy and attest the exact compiled TokenDeals bytecode; publish the confirmed address and verify source. No constructor arguments, ETH, dependency deployment order or initializer are required. Confirm chain ID 1 and the fixed owner, FeeSplitter, fees, allowlist and base-unit caps. The local deployment tests rehearse CREATE2, empty-chain construction, runtime size and forbidden runtime opcodes.
2. **Owner and signer operator:** choose the real holder-eligibility signer and call `setPassSigner(address)`. The owner obtains this address from its chosen signing service; no signer or key is invented by this project. Configure that service with the confirmed contract address and EIP-712 fields above. Normal-fee buys already work before this step. Protect the signing key, define holder checks, issue passes with no more than a 24-hour remaining lifetime, and rotate or disable the signer if required.
3. **Owner:** review third-party payment implementations and the FeeSplitter on Ethereum. Use `setPayCoin(coin, allowed)` for policy changes and `setMaxPay(coin, rawBaseUnitCap)` for limits. Check each added coin's actual decimals and transfer behavior; configure its cap before enabling new deals when a limit is wanted. Use `setFees(normal, holder)` only within the enforced bounds. Monitor policy events and use pause/unpause for incidents; cancellation and credits remain available.
4. **FeeSplitter operator and contract sellers:** monitor `OwedCredited` and `owed(account)`. A credited contract must call `claimOwed()` itself and accept the resulting ETH. The TokenDeals owner cannot redirect these credits.
5. **Integrators:** get the deployed address from the launch handoff, query current state, quote in raw units, choose an appropriate `maxTotal`, approve only the required tokens, and display gross versus expected net sale-token amounts for taxed tokens. Do not interpret a successful quote as a reservation or pass validation.

See [`docs/VALIDATION.md`](docs/VALIDATION.md) for the test map and review boundaries. An independent adversarial review remains a release responsibility; local tests are not that review.
