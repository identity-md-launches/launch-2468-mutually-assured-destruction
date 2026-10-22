# Mutually Assured Destruction (MAD)

A plain, fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum (chain id 1).

| Item | Value |
|---|---|
| Solidity contract | `MADToken` (`src/MADToken.sol`) |
| `name()` | `Mutually Assured Destruction` |
| `symbol()` | `MAD` |
| `decimals()` | 18 |
| Total supply | 1,000,000,000 MAD = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Minted to | `msg.sender` of the deployment, once, in the constructor |
| Owner / admin | none |

## Behaviour

- The constructor mints the whole supply to `msg.sender` and emits the standard `Transfer(0x0, deployer, supply)`
  plus a one-off `SupplyMinted(deployer, supply)` event. The constructor calls no other contract.
- Transfers, allowances and `transferFrom` are OpenZeppelin Contracts v5.4.0 `ERC20`, unmodified: no fee, no tax,
  no burn on transfer, no reflections, no max-wallet or cooldown. Every launch flow (factory to distributor,
  distributor to claimant, pool seed, swaps through the PoolManager) moves exactly the stated amount.
- There is no `mint`, `burn`, `burnFrom`, `pause`, blocklist, freeze, seize, fee setter, owner or upgrade path.
  The supply can never grow, and no address can move or freeze another holder's balance. The only way a balance
  moves is the holder's own `transfer`, or `transferFrom` under an allowance the holder granted.
- The contract has no `receive` or `fallback`, so plain ETH sent to it is refused.
- No `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in the runtime; no proxies; no external library calls.

## Assumptions

- The launch's token constructor takes no arguments. Because the token has no fee or restriction, it does not need
  the `$factory`, `$poolManager` or `$launchNumber` exemption arguments the launch offers.
- The deployer of the launch is IdentityMD's ProjectFactory, which receives the whole supply and pays it out:
  10% to the launch's MerkleDistributor (the swarm's share), `poolBps` = 80% into the single-sided Uniswap v4 pool,
  and the remaining 10% to `economics.remainderTo` (`0x1ee3ffadfe138415a2ddaedeebe5f46616fa413d`). None of this is
  encoded in the token; the token simply mints to whoever deploys it.
- The pool pairs MAD with FWA (`0xa0df17b5ac76ababa36e1450e2cbcd18a620c845`, 18 decimals), fee 12500 (1.25%),
  tick spacing 60, opening at a 2,000,000 FWA market cap. These are the launch's values, consumed by the manifest
  step, not by this code.
- Compiler pinned to `solc = "0.8.26"`, `bytecode_hash = "none"`, `cbor_metadata = false`, optimizer on with
  200 runs, EVM version `cancun`. The launch compares deployed bytes without a metadata hash.

## Deployment parameters

The IdentityMD launch deploys `MADToken` from its built creation code through the ProjectFactory. Nothing in this
repository broadcasts a transaction, and no `launch.json` is written here; the manifest step writes it after
acceptance with:

- `token.contract`: `MADToken`
- `token.name`: `Mutually Assured Destruction`
- `token.symbol`: `MAD`
- `token.decimals`: `18`
- `token.constructorArgs`: `[]`
- `token.totalSupply`: `1000000000000000000000000000`
- `contracts`: `[]` (this launch has no application contracts)

`script/DeployMADToken.s.sol` is a reviewable reference deployment for local forks and reviews only. Its
`deploy()` function takes no configuration and is what the tests call; `run()` only wraps it in a broadcast using
the signer forge is given on the command line. It reads no environment variables.

```bash
forge script script/DeployMADToken.s.sol --rpc-url <fork-url> --account <keystore>
```

## After launch

There is nothing to configure. The token has no owner-settable values, no outside-contract addresses, and no
setters. Once deployed, its behaviour is fixed.

## Operational responsibilities

- **No admin key exists.** Nobody, including the requester and IdentityMD, can mint, pause, freeze, blocklist or
  recover tokens. Tokens sent to a wrong address or to the token contract itself are unrecoverable; the OpenZeppelin
  implementation refuses only the zero address.
- **Remainder wallet.** The 10% remainder goes to `economics.remainderTo`. The requester must control that wallet and
  keep its key safe; the token offers no clawback.
- **Allowances.** Holders are responsible for the allowances they grant. Infinite approvals (`type(uint256).max`) are
  honoured and never decremented, as in the ERC-20 standard; approve only trusted spenders.
- **Source verification** on the block explorer after launch belongs to the network's deployer (`forge
  verify-contract` with the pinned compiler settings). It is an open item for the launch, not something this
  repository performs.
- **Audit status.** Tests passing are not a security audit. The token's logic is OpenZeppelin's audited `ERC20`
  plus a constructor mint and a `decimals()` override; the independent review step still applies before release.
  Static analyzers (Slither, Mythril) were not run on this machine; only `forge build`, `forge test` and
  `forge fmt --check` ran.

## Project layout

```
foundry.toml                     compiler pins and remappings
src/MADToken.sol                 the token
script/DeployMADToken.s.sol      reference deploy script (deploy() is test-callable)
test/MADToken.t.sol              token behaviour: metadata, mint, transfers, allowances, no admin power, fuzz
test/DeployMADToken.t.sol        the deploy script's deploy() called directly
lib/forge-std                    forge-std v1.9.7 (src/ only), vendored as plain files
lib/openzeppelin-contracts       OpenZeppelin Contracts v5.4.0, only the ERC20 files the token imports
```

## Checks

```bash
forge build
FOUNDRY_FUZZ_SEED=0xa67e632046178c2741f96ce098239348798defebeb7efb44d5ed3ad7930be689 forge test
forge fmt --check
```

Tests read no environment variables and do not depend on the caller of the script, so they pass in any order, in
parallel, and with an empty environment.
