#[test_only]
module test_helpers::test_pool {
    use std::signer;

    use aptos_framework::account;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::FungibleAsset;
    use aptos_framework::genesis;
    use aptos_framework::primary_fungible_store;

    use liquidswap_v05::liquidity_pool;
    use test_fa_admin::test_fas;

    public fun create_lp_owner(): signer {
        let pool_owner = account::create_account_for_test(@test_lp_owner);
        pool_owner
    }

    public fun create_liquidswap_admin(): signer {
        let admin = account::create_account_for_test(@liquidswap_v05);
        admin
    }

    public fun initialize_liquidity_pool() {
        let liquidswap_admin = account::create_account_for_test(@liquidswap_v05);
        liquidity_pool::initialize(&liquidswap_admin);
    }

    public fun setup_fa_and_lp_owner(): (signer, signer) {
        genesis::setup();

        initialize_liquidity_pool();

        let fa_admin = test_fas::create_admin_with_fas();
        let lp_owner = create_lp_owner();
        (fa_admin, lp_owner)
    }

    public fun mint_liquidity<Curve>(lp_owner: &signer, fa_x: FungibleAsset, fa_y: FungibleAsset): u64 {
        let lp_owner_addr = signer::address_of(lp_owner);
        let lp_fa = liquidity_pool::mint<Curve>(fa_x, fa_y);
        let lp_fa_val = fungible_asset::amount(&lp_fa);
        primary_fungible_store::deposit(lp_owner_addr, lp_fa);
        lp_fa_val
    }
}
