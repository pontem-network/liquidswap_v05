# Liquidswap v0.5

**Liquidswap v0.5** is AMM protocol for [Aptos](https://www.aptos.com/) blockchain.

The newest version of Liquidswap. 

Interim release between v1 and v0. We still use [Liquidswap v0](https://github.com/pontem-network/liquidswap) 
for Aptos mainnet, but for the creation of new pools or stable swaps, we would use v0.5

It contains the following changes:

* Native u256 for stable swaps and for `x*y>k` constant formula.
* Fix for `initial liquidity loss of precision bug.`
* Updated LP coin symbol and name logic to have difference from v0.5

Changes reviewed by Ottersec team.

## Documentation

Vist our [docs](https://docs.liquidswap.com) portal.

## Add as dependency

To integrate Liquidswap into your project vist [integration](https://docs.liquidswap.com/integration) docs.

### Build

[Aptos CLI](https://github.com/aptos-labs/aptos-core/releases) required:

    aptos move compile

### Test

    aptos move test

### Security Audits

Look at [section](https://docs.liquidswap.com/#security-audits) in our doc.

### Bounty Program

Read details about our bounty program launched on the [Immunefi platform](https://immunefi.com/bounty/liquidswap/).

### License

See [LICENSE](LICENSE)

