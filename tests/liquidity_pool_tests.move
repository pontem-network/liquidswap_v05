#[test_only]
module liquidswap_v05::liquidity_pool_tests {
    use std::option;
    use std::signer;
    use std::string;
    use std::string::utf8;

    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object;
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use liquidswap_v05::liquidity_pool::LiquidityPool;
    use liquidswap_v05::fa_helper;
    use liquidswap_v05::dao_storage;

    use liquidswap_v05::curves::{Uncorrelated, Stable};
    use liquidswap_v05::emergency;
    use liquidswap_v05::global_config;
    use liquidswap_v05::liquidity_pool;
    use liquidswap_v05::curves;
    use test_fa_admin::test_fas;
    use test_helpers::test_pool::{Self, create_liquidswap_admin};
    use aptos_framework::aptos_coin::{Self, AptosCoin};

    // todo: optimize imports

    const MINIMAL_LIQUIDITY: u64 = 1000;

    fun setup_btc_usdt_pool(): (signer, signer) {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata,
        );
        (fa_admin, lp_owner)
    }

    fun setup_usdc_usdt_pool(): (signer, signer) {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Stable>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata,
        );
        (fa_admin, lp_owner)
    }

    fun get_lp_fa_metadata_obj_addr_from_x_y_metadatas<Curve>(
        fa_x_metadata: Object<Metadata>,
        fa_y_metadata: Object<Metadata>,
    ): address {
        // Create LP metadata.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Curve>(fa_x_metadata, fa_y_metadata));
        let lp_fa_obj_seed = string::utf8(*pool_obj_name);
        string::append_utf8( &mut lp_fa_obj_seed, b"-LP");

        object::create_object_address(&@liquidswap_pool_account, *string::bytes(&lp_fa_obj_seed))
    }

    fun get_lp_fa_metadata_from_x_y_metadatas<Curve>(
        fa_x_metadata: Object<Metadata>,
        fa_y_metadata: Object<Metadata>,
    ): Object<Metadata> {
        // Create LP metadata.
        let lp_fa_obj_addr =
            get_lp_fa_metadata_obj_addr_from_x_y_metadatas<Curve>(fa_x_metadata, fa_y_metadata);
        object::address_to_object<Metadata>(lp_fa_obj_addr)
    }

    // Register pool tests.

    #[test]
    fun test_liquidswap_pool_account_address() {
        let liquidswap_admin = create_liquidswap_admin();
        let (liquidswap_pool_acc, _) =
            account::create_resource_account(&liquidswap_admin, b"liquidswap_account_seed");
        assert!(signer::address_of(&liquidswap_pool_acc) == @liquidswap_pool_account, 1);
    }

    #[test]
    fun test_create_empty_pool_uncorrelated() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        // Check no object before pool creation
        assert!(!liquidity_pool::is_pool_exists<Uncorrelated>(fa_x_metadata, fa_y_metadata), 1);

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);

        // Check LP FA obj created and cannot be transfered.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let lp_fa_obj_seed = string::utf8(*pool_obj_name);
        string::append_utf8( &mut lp_fa_obj_seed, b"-LP");
        let lp_fa_obj_addr =
            object::create_object_address(&@liquidswap_pool_account, *string::bytes(&lp_fa_obj_seed));
        let lp_fa_obj = object::address_to_object<Metadata>(lp_fa_obj_addr);
        assert!(object::object_exists<Metadata>(lp_fa_obj_addr), 2);
        assert!(object::is_untransferable(lp_fa_obj), 3);

        // Check LP FA store created.
        let fa_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name);
        let lp_metadata =
            get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr, lp_metadata), 4);

        // Check pool stores correct LP metadata address.
        assert!(liquidity_pool::get_pool_lp_metadata<Uncorrelated>(fa_x_metadata, fa_y_metadata) == lp_metadata, 5);

        // Check pool exists with getter.
        assert!(liquidity_pool::is_pool_exists<Uncorrelated>(fa_x_metadata, fa_y_metadata), 6);

        let (x_res_val, y_res_val) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res_val == 0, 7);
        assert!(y_res_val == 0, 8);

        let (x_price, y_price, _) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_price == 0, 9);
        assert!(y_price == 0, 10);

        // todo: recheck LP
        // Check created LP.
        let lp_name = fungible_asset::name(lp_metadata);
        assert!(lp_name == utf8(b"LS05 LP-BTC-USDT-U"), 11);
        let lp_symbol = fungible_asset::symbol(lp_metadata);
        assert!(lp_symbol == utf8(b"BTC-USDTU"), 12);
        let lp_supply = fungible_asset::supply(lp_metadata);
        assert!(option::is_some(&lp_supply), 13);
        assert!(*option::borrow(&lp_supply) == 0, 14);

        // Check cumulative prices.
        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 0, 15);
        assert!(y_cum_price == 0, 16);
        assert!(ts == 0, 17);

        // Check if it's locked.
        assert!(!liquidity_pool::is_pool_locked<Uncorrelated>(fa_x_metadata, fa_y_metadata), 18);

        // Check DAO stores initialized correctly.
        let storage_creator_addr =
            account::create_resource_address(&@liquidswap_v05, b"dao_fa_store_sig_cap_seed");
        let storage_seed =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let fa_res_acc_addr =
            account::create_resource_address(&storage_creator_addr, *string::bytes(&storage_seed));

        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr, fa_x_metadata), 19);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr, fa_y_metadata), 20);

        // Check pool object created.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let pool_obj_addr =
            object::create_object_address(&@liquidswap_pool_account, *pool_obj_name);
        assert!(object::object_exists<LiquidityPool<Uncorrelated>>(pool_obj_addr), 21);
        let pool_obj =
            object::address_to_object<LiquidityPool<Uncorrelated>>(pool_obj_addr);
        assert!(object::owner(pool_obj) == @liquidswap_pool_account, 22);
        assert!(object::is_untransferable(pool_obj), 23);

        // Check pool FA stores created.
        let pool_fa_store_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name);
        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr, fa_x_metadata), 24);
        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr, fa_y_metadata), 25);
    }

    #[test(emergency_acc = @emergency_admin)]
    #[expected_failure(abort_code = emergency::ERR_EMERGENCY)]
    fun test_create_pool_emergency_fails(emergency_acc: signer) {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        emergency::pause(&emergency_acc);
        liquidity_pool::register<Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata
        );
    }

    #[test]
    fun test_create_empty_pool_stable() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Stable>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata
        );

        let (x_res_val, y_res_val) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res_val == 0, 0);
        assert!(y_res_val == 0, 1);

        // Check scales.
        let (x_scale, y_scale) =
            liquidity_pool::get_decimals_scales<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_scale == 10000, 2);
        assert!(y_scale == 1000000, 3);

        // Check created LP.
        let lp_metadata = get_lp_fa_metadata_from_x_y_metadatas<Stable>(fa_x_metadata, fa_y_metadata);
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Stable>(fa_x_metadata, fa_y_metadata));
        let fa_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr, lp_metadata), 4);

        let lp_name = fungible_asset::name(lp_metadata);
        // todo: recheck LP
        assert!(lp_name == utf8(b"LS05 LP-USDC-USDT-S"), 6);
        let lp_symbol = fungible_asset::symbol(lp_metadata);
        assert!(lp_symbol == utf8(b"USDC-USDTS"), 7);
        let lp_supply = fungible_asset::supply(lp_metadata);
        assert!(option::is_some(&lp_supply), 8);

        // Get cummulative prices.
        let (x_cumm_price, y_cumm_price, ts) =
            liquidity_pool::get_cumulative_prices<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_cumm_price == 0, 9);
        assert!(y_cumm_price == 0, 10);
        assert!(ts == 0, 11);

        // Check if it's locked.
        assert!(!liquidity_pool::is_pool_locked<Stable>(fa_x_metadata, fa_y_metadata), 12);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_PAIR_ORDERING)]
    fun test_fail_if_coin_generics_provided_in_the_wrong_order() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata
        );

        // here generics are provided as USDT-BTC, but pool is BTC-USDT. `reverse` parameter is irrelevant
        let (_, _, _) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_y_metadata, fa_x_metadata);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_POOL_EXISTS_FOR_PAIR)]
    fun test_fail_if_pool_already_exists() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata
        );

        liquidity_pool::register<Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata
        );
    }

    #[test]
    #[expected_failure(abort_code = fa_helper::ERR_CANNOT_BE_THE_SAME_FA)]
    fun test_fail_if_same_metadata_used_to_create_pool() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");

        liquidity_pool::register<Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_x_metadata
        );
    }

    #[test]
    fun test_same_symbol_fas_used_to_create_pool() {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        // Create same another BTC FA.
        let (mint_ref, _) = test_fas::register_fa(
            &fa_admin,
            b"BTC Fungible Asset",
            b"BTC",
            8,
            b"BTC2_FA_OBJ"
        );

        let fa_x_metadata = fungible_asset::mint_ref_metadata(&mint_ref);
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");

        liquidity_pool::register<Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata
        );

        // Check created LP.
        let lp_metadata = get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let fa_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr, lp_metadata), 1);

        // todo: check LP
        let lp_name = fungible_asset::name(lp_metadata);
        assert!(lp_name == utf8(b"LS05 LP-BTC-BTC-U"), 2);
        let lp_symbol = fungible_asset::symbol(lp_metadata);
        assert!(lp_symbol == utf8(b"BTC-BTCU"), 3);
        let lp_supply = fungible_asset::supply(lp_metadata);
        assert!(option::is_some(&lp_supply), 4);
        assert!(*option::borrow(&lp_supply) == 0, 5);

        // Check cumulative prices.
        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 0, 6);
        assert!(y_cum_price == 0, 7);
        assert!(ts == 0, 8);

        // Check if it's locked.
        assert!(!liquidity_pool::is_pool_locked<Uncorrelated>(fa_x_metadata, fa_y_metadata), 9);

        // Check DAO stores initialized correctly.
        let storage_creator_addr =
            account::create_resource_address(&@liquidswap_v05, b"dao_fa_store_sig_cap_seed");
        let storage_seed =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let fa_res_acc_addr =
            account::create_resource_address(&storage_creator_addr, *string::bytes(&storage_seed));

        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr, fa_x_metadata), 10);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr, fa_y_metadata), 11);

        // Check pool object created.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let pool_obj_addr =
            object::create_object_address(&@liquidswap_pool_account, *pool_obj_name);
        assert!(object::object_exists<LiquidityPool<Uncorrelated>>(pool_obj_addr), 12);
        let pool_obj =
            object::address_to_object<LiquidityPool<Uncorrelated>>(pool_obj_addr);
        assert!(object::owner(pool_obj) == @liquidswap_pool_account, 13);
        assert!(object::is_untransferable(pool_obj), 14);

        // Check pool FA stores created.
        let pool_fa_store_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name);
        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr, fa_x_metadata), 15);
        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr, fa_y_metadata), 16);
    }

    #[test]
    fun test_create_two_pools_same_metadata_diff_curves() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        // Check no objects before pool creation
        assert!(!liquidity_pool::is_pool_exists<Uncorrelated>(fa_x_metadata, fa_y_metadata), 1);
        assert!(!liquidity_pool::is_pool_exists<Stable>(fa_x_metadata, fa_y_metadata), 2);

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);
        liquidity_pool::register<Stable>(&lp_owner, fa_x_metadata, fa_y_metadata);

        assert!(liquidity_pool::is_pool_exists<Uncorrelated>(fa_x_metadata, fa_y_metadata), 3);
        assert!(liquidity_pool::is_pool_exists<Stable>(fa_x_metadata, fa_y_metadata), 4);

        let lp_metadata_u =
            get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let pool_obj_name_u =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let fa_res_acc_addr_u =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name_u);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_u, lp_metadata_u), 5);
        assert!(!object::object_exists<Metadata>(
            get_lp_fa_metadata_obj_addr_from_x_y_metadatas<Uncorrelated>(fa_y_metadata, fa_x_metadata)), 6);

        let lp_metadata_s =
            get_lp_fa_metadata_from_x_y_metadatas<Stable>(fa_x_metadata, fa_y_metadata);
        let pool_obj_name_s =
            string::bytes(&fa_helper::create_pool_obj_name<Stable>(fa_x_metadata, fa_y_metadata));
        let fa_res_acc_addr_s =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name_s);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_s, lp_metadata_s), 7);
        assert!(!object::object_exists<Metadata>(
            get_lp_fa_metadata_obj_addr_from_x_y_metadatas<Stable>(fa_y_metadata, fa_x_metadata)), 8);

        let (x_res_val, y_res_val) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res_val == 0, 9);
        assert!(y_res_val == 0, 10);
        let (x_res_val, y_res_val) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res_val == 0, 11);
        assert!(y_res_val == 0, 12);

        let (x_price, y_price, _) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_price == 0, 13);
        assert!(y_price == 0, 14);
        let (x_price, y_price, _) =
            liquidity_pool::get_cumulative_prices<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_price == 0, 15);
        assert!(y_price == 0, 16);

        // Check Uncorrelated LP created.
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_u, lp_metadata_u), 17);
        // todo: recheck LP
        let lp_name = fungible_asset::name(lp_metadata_u);
        assert!(lp_name == utf8(b"LS05 LP-BTC-USDT-U"), 18);
        let lp_symbol = fungible_asset::symbol(lp_metadata_u);
        assert!(lp_symbol == utf8(b"BTC-USDTU"), 19);
        let lp_supply = fungible_asset::supply(lp_metadata_u);
        assert!(option::is_some(&lp_supply), 20);
        assert!(*option::borrow(&lp_supply) == 0, 21);

        // Check Stable LP created.
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_s, lp_metadata_s), 22);
        // todo: recheck LP
        let lp_name = fungible_asset::name(lp_metadata_s);
        assert!(lp_name == utf8(b"LS05 LP-BTC-USDT-S"), 23);
        let lp_symbol = fungible_asset::symbol(lp_metadata_s);
        assert!(lp_symbol == utf8(b"BTC-USDTS"), 24);
        let lp_supply = fungible_asset::supply(lp_metadata_s);
        assert!(option::is_some(&lp_supply), 25);
        assert!(*option::borrow(&lp_supply) == 0, 26);

        // Check cumulative prices.
        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 0, 27);
        assert!(y_cum_price == 0, 28);
        assert!(ts == 0, 29);
        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 0, 30);
        assert!(y_cum_price == 0, 31);
        assert!(ts == 0, 32);

        // Check if it's locked.
        assert!(!liquidity_pool::is_pool_locked<Uncorrelated>(fa_x_metadata, fa_y_metadata), 33);
        assert!(!liquidity_pool::is_pool_locked<Stable>(fa_x_metadata, fa_y_metadata), 34);

        // Check DAO stores initialized correctly.
        let storage_creator_addr =
            account::create_resource_address(&@liquidswap_v05, b"dao_fa_store_sig_cap_seed");
        let storage_seed_u =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let fa_dao_res_acc_addr_u =
            account::create_resource_address(&storage_creator_addr, *string::bytes(&storage_seed_u));
        let storage_seed_s =
            dao_storage::create_fa_storage_seed<Stable>(fa_x_metadata, fa_y_metadata);
        let fa_dao_res_acc_addr_s =
            account::create_resource_address(&storage_creator_addr, *string::bytes(&storage_seed_s));

        // Check seeds and res accs are differ for diff curves.
        assert!(storage_seed_u != storage_seed_s, 35);
        assert!(fa_dao_res_acc_addr_u != fa_dao_res_acc_addr_s, 36);

        // Check FA DAO stores has diff addresses.
        let fa_x_store_addr_u =
            primary_fungible_store::primary_store_address(fa_dao_res_acc_addr_u, fa_x_metadata);
        let fa_y_store_addr_u =
            primary_fungible_store::primary_store_address(fa_dao_res_acc_addr_u, fa_y_metadata);
        let fa_x_store_addr_s =
            primary_fungible_store::primary_store_address(fa_dao_res_acc_addr_s, fa_x_metadata);
        let fa_y_store_addr_s =
            primary_fungible_store::primary_store_address(fa_dao_res_acc_addr_s, fa_y_metadata);
        assert!(fa_x_store_addr_u != fa_x_store_addr_s, 37);
        assert!(fa_y_store_addr_u != fa_y_store_addr_s, 38);

        assert!(primary_fungible_store::primary_store_exists(fa_dao_res_acc_addr_u, fa_x_metadata), 39);
        assert!(primary_fungible_store::primary_store_exists(fa_dao_res_acc_addr_u, fa_y_metadata), 40);
        assert!(primary_fungible_store::primary_store_exists(fa_dao_res_acc_addr_s, fa_x_metadata), 41);
        assert!(primary_fungible_store::primary_store_exists(fa_dao_res_acc_addr_s, fa_y_metadata), 42);

        // Check pool objects created.
        let pool_obj_addr_u =
            object::create_object_address(&@liquidswap_pool_account, *pool_obj_name_u);
        assert!(object::object_exists<LiquidityPool<Uncorrelated>>(pool_obj_addr_u), 43);
        let pool_obj_addr_s =
            object::create_object_address(&@liquidswap_pool_account, *pool_obj_name_s);
        assert!(object::object_exists<LiquidityPool<Stable>>(pool_obj_addr_s), 44);

        // Check pool object addresses and names are different.
        assert!(pool_obj_name_u != pool_obj_name_s, 45);
        assert!(pool_obj_addr_u != pool_obj_addr_s, 46);

        // Check pool objects owners and is_untransferable is on.
        let pool_obj_u =
            object::address_to_object<LiquidityPool<Uncorrelated>>(pool_obj_addr_u);
        assert!(object::owner(pool_obj_u) == @liquidswap_pool_account, 47);
        assert!(object::is_untransferable(pool_obj_u), 48);
        let pool_obj_s =
            object::address_to_object<LiquidityPool<Stable>>(pool_obj_addr_s);
        assert!(object::owner(pool_obj_s) == @liquidswap_pool_account, 49);
        assert!(object::is_untransferable(pool_obj_s), 50);

        // Check pool FA stores created.
        let pool_fa_store_res_acc_addr_u =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name_u);
        let pool_fa_store_res_acc_addr_s =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name_s);

        // Check pools FA stores has diff addrs.
        let fa_x_pool_store_addr_u =
            primary_fungible_store::primary_store_address(pool_fa_store_res_acc_addr_u, fa_x_metadata);
        let fa_y_pool_store_addr_u =
            primary_fungible_store::primary_store_address(pool_fa_store_res_acc_addr_u, fa_y_metadata);
        let fa_x_pool_store_addr_s =
            primary_fungible_store::primary_store_address(pool_fa_store_res_acc_addr_s, fa_x_metadata);
        let fa_y_pool_store_addr_s =
            primary_fungible_store::primary_store_address(pool_fa_store_res_acc_addr_s, fa_y_metadata);
        assert!(fa_x_pool_store_addr_u != fa_x_pool_store_addr_s, 51);
        assert!(fa_y_pool_store_addr_u != fa_y_pool_store_addr_s, 52);

        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr_u, fa_x_metadata), 53);
        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr_u, fa_y_metadata), 54);
        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr_s, fa_x_metadata), 55);
        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr_s, fa_y_metadata), 56);

        // Check LP objects created.
        let lp_fa_obj_seed_u = string::utf8(*pool_obj_name_u);
        string::append_utf8( &mut lp_fa_obj_seed_u, b"-LP");
        let lp_fa_obj_addr_u =
            object::create_object_address(&@liquidswap_pool_account, *string::bytes(&lp_fa_obj_seed_u));
        let lp_fa_obj_u = object::address_to_object<Metadata>(lp_fa_obj_addr_u);
        assert!(object::object_exists<Metadata>(lp_fa_obj_addr_u), 57);
        assert!(object::is_untransferable(lp_fa_obj_u), 58);

        let lp_fa_obj_seed_s = string::utf8(*pool_obj_name_s);
        string::append_utf8( &mut lp_fa_obj_seed_s, b"-LP");
        let lp_fa_obj_addr_s =
            object::create_object_address(&@liquidswap_pool_account, *string::bytes(&lp_fa_obj_seed_s));
        let lp_fa_obj_s = object::address_to_object<Metadata>(lp_fa_obj_addr_s);
        assert!(object::object_exists<Metadata>(lp_fa_obj_addr_s), 59);
        assert!(object::is_untransferable(lp_fa_obj_s), 60);

        // Check LP objects differ.
        assert!(lp_fa_obj_seed_u != lp_fa_obj_seed_s, 61);
        assert!(lp_fa_obj_addr_u != lp_fa_obj_addr_s, 62);

        // Check LP FA stores created.
        let fa_res_acc_addr_u =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name_u);
        let lp_metadata_u =
            get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_u, lp_metadata_u), 63);

        let fa_res_acc_addr_s =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name_s);
        let lp_metadata_s =
            get_lp_fa_metadata_from_x_y_metadatas<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_s, lp_metadata_s), 64);

        // Check LP FA stores are different.
        assert!(lp_metadata_u != lp_metadata_s, 65);

        // Check pools store correct LP metadata addresses.
        assert!(liquidity_pool::get_pool_lp_metadata<Uncorrelated>(fa_x_metadata, fa_y_metadata) == lp_metadata_u, 66);
        assert!(liquidity_pool::get_pool_lp_metadata<Stable>(fa_x_metadata, fa_y_metadata) == lp_metadata_s, 67);
    }

    #[test]
    fun test_create_two_pools_same_symbols_same_curves() {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        // Create fake BTC FA.
        let (mint_ref, _) = test_fas::register_fa(
            &fa_admin,
            b"BTC Fungible Asset",
            b"BTC",
            8,
            b"FAKE_BTC_FA_OBJ"
        );

        let fa_x_fake_metadata = fungible_asset::mint_ref_metadata(&mint_ref);
        let fa_x_real_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        // Check no objects before pool creation
        assert!(!liquidity_pool::is_pool_exists<Uncorrelated>(fa_x_fake_metadata, fa_y_metadata), 1);
        assert!(!liquidity_pool::is_pool_exists<Uncorrelated>(fa_x_real_metadata, fa_y_metadata), 2);

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_fake_metadata, fa_y_metadata);
        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_real_metadata, fa_y_metadata);

        assert!(liquidity_pool::is_pool_exists<Uncorrelated>(fa_x_fake_metadata, fa_y_metadata), 3);
        assert!(liquidity_pool::is_pool_exists<Uncorrelated>(fa_x_real_metadata, fa_y_metadata), 4);

        let lp_metadata_f =
            get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_fake_metadata, fa_y_metadata);
        let pool_obj_name_f =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_fake_metadata, fa_y_metadata));
        let fa_res_acc_addr_f =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name_f);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_f, lp_metadata_f), 5);
        assert!(!object::object_exists<Metadata>(
            get_lp_fa_metadata_obj_addr_from_x_y_metadatas<Uncorrelated>(fa_y_metadata, fa_x_fake_metadata)), 6);

        let lp_metadata_r =
            get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_real_metadata, fa_y_metadata);
        let pool_obj_name_r =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_real_metadata, fa_y_metadata));
        let fa_res_acc_addr_r =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name_r);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_r, lp_metadata_r), 7);
        assert!(!object::object_exists<Metadata>(
            get_lp_fa_metadata_obj_addr_from_x_y_metadatas<Uncorrelated>(fa_y_metadata, fa_x_real_metadata)), 8);

        let (x_res_val, y_res_val) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_fake_metadata, fa_y_metadata);
        assert!(x_res_val == 0, 9);
        assert!(y_res_val == 0, 10);
        let (x_res_val, y_res_val) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_real_metadata, fa_y_metadata);
        assert!(x_res_val == 0, 11);
        assert!(y_res_val == 0, 12);

        let (x_price, y_price, _) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_fake_metadata, fa_y_metadata);
        assert!(x_price == 0, 13);
        assert!(y_price == 0, 14);
        let (x_price, y_price, _) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_real_metadata, fa_y_metadata);
        assert!(x_price == 0, 15);
        assert!(y_price == 0, 16);

        // Check fake btc pool LP created.
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_f, lp_metadata_f), 17);
        // todo: recheck LP
        let lp_name = fungible_asset::name(lp_metadata_f);
        assert!(lp_name == utf8(b"LS05 LP-BTC-USDT-U"), 18);
        let lp_symbol = fungible_asset::symbol(lp_metadata_f);
        assert!(lp_symbol == utf8(b"BTC-USDTU"), 19);
        let lp_supply = fungible_asset::supply(lp_metadata_f);
        assert!(option::is_some(&lp_supply), 20);
        assert!(*option::borrow(&lp_supply) == 0, 21);

        // Check real btc pool LP created.
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_r, lp_metadata_r), 22);
        // todo: recheck LP
        let lp_name = fungible_asset::name(lp_metadata_r);
        assert!(lp_name == utf8(b"LS05 LP-BTC-USDT-U"), 23);
        let lp_symbol = fungible_asset::symbol(lp_metadata_r);
        assert!(lp_symbol == utf8(b"BTC-USDTU"), 24);
        let lp_supply = fungible_asset::supply(lp_metadata_r);
        assert!(option::is_some(&lp_supply), 25);
        assert!(*option::borrow(&lp_supply) == 0, 26);

        // Check cumulative prices.
        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_fake_metadata, fa_y_metadata);
        assert!(x_cum_price == 0, 27);
        assert!(y_cum_price == 0, 28);
        assert!(ts == 0, 29);
        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_real_metadata, fa_y_metadata);
        assert!(x_cum_price == 0, 30);
        assert!(y_cum_price == 0, 31);
        assert!(ts == 0, 32);

        // Check if it's locked.
        assert!(!liquidity_pool::is_pool_locked<Uncorrelated>(fa_x_fake_metadata, fa_y_metadata), 33);
        assert!(!liquidity_pool::is_pool_locked<Uncorrelated>(fa_x_real_metadata, fa_y_metadata), 34);

        // Check DAO stores initialized correctly.
        let storage_creator_addr =
            account::create_resource_address(&@liquidswap_v05, b"dao_fa_store_sig_cap_seed");
        let storage_seed_f =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_fake_metadata, fa_y_metadata);
        let fa_dao_res_acc_addr_f =
            account::create_resource_address(&storage_creator_addr, *string::bytes(&storage_seed_f));
        let storage_seed_r =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_real_metadata, fa_y_metadata);
        let fa_dao_res_acc_addr_r =
            account::create_resource_address(&storage_creator_addr, *string::bytes(&storage_seed_r));

        // Check seeds and res accs are differ for diff curves.
        assert!(storage_seed_f != storage_seed_r, 35);
        assert!(fa_dao_res_acc_addr_f != fa_dao_res_acc_addr_r, 36);

        // Check FA DAO stores has diff addresses.
        let fa_x_store_addr_f =
            primary_fungible_store::primary_store_address(fa_dao_res_acc_addr_f, fa_x_fake_metadata);
        let fa_y_store_addr_f =
            primary_fungible_store::primary_store_address(fa_dao_res_acc_addr_f, fa_y_metadata);
        let fa_x_store_addr_r =
            primary_fungible_store::primary_store_address(fa_dao_res_acc_addr_r, fa_x_real_metadata);
        let fa_y_store_addr_r =
            primary_fungible_store::primary_store_address(fa_dao_res_acc_addr_r, fa_y_metadata);
        assert!(fa_x_store_addr_f != fa_x_store_addr_r, 37);
        assert!(fa_y_store_addr_f!= fa_y_store_addr_r, 38);

        assert!(primary_fungible_store::primary_store_exists(fa_dao_res_acc_addr_f, fa_x_fake_metadata), 39);
        assert!(primary_fungible_store::primary_store_exists(fa_dao_res_acc_addr_f, fa_y_metadata), 40);
        assert!(primary_fungible_store::primary_store_exists(fa_dao_res_acc_addr_r, fa_x_real_metadata), 41);
        assert!(primary_fungible_store::primary_store_exists(fa_dao_res_acc_addr_r, fa_y_metadata), 42);

        // Check pool objects created.
        let pool_obj_addr_f =
            object::create_object_address(&@liquidswap_pool_account, *pool_obj_name_f);
        assert!(object::object_exists<LiquidityPool<Uncorrelated>>(pool_obj_addr_f), 43);
        let pool_obj_addr_r =
            object::create_object_address(&@liquidswap_pool_account, *pool_obj_name_r);
        assert!(object::object_exists<LiquidityPool<Uncorrelated>>(pool_obj_addr_r), 44);

        // Check pool object addresses and names are different.
        assert!(pool_obj_name_f != pool_obj_name_r, 45);
        assert!(pool_obj_addr_f != pool_obj_addr_r, 46);

        // Check pool objects owners and is_untransferable is on.
        let pool_obj_f =
            object::address_to_object<LiquidityPool<Uncorrelated>>(pool_obj_addr_f);
        assert!(object::owner(pool_obj_f) == @liquidswap_pool_account, 47);
        assert!(object::is_untransferable(pool_obj_f), 4);
        let pool_obj_r =
            object::address_to_object<LiquidityPool<Uncorrelated>>(pool_obj_addr_r);
        assert!(object::owner(pool_obj_r) == @liquidswap_pool_account, 49);
        assert!(object::is_untransferable(pool_obj_r), 50);

        // Check pool FA stores created.
        let pool_fa_store_res_acc_addr_f =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name_f);
        let pool_fa_store_res_acc_addr_r =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name_r);

        // Check pools FA stores has diff addrs.
        let fa_x_pool_store_addr_f =
            primary_fungible_store::primary_store_address(pool_fa_store_res_acc_addr_f, fa_x_fake_metadata);
        let fa_y_pool_store_addr_f =
            primary_fungible_store::primary_store_address(pool_fa_store_res_acc_addr_f, fa_y_metadata);
        let fa_x_pool_store_addr_r =
            primary_fungible_store::primary_store_address(pool_fa_store_res_acc_addr_r, fa_x_real_metadata);
        let fa_y_pool_store_addr_r =
            primary_fungible_store::primary_store_address(pool_fa_store_res_acc_addr_r, fa_y_metadata);
        assert!(fa_x_pool_store_addr_f != fa_x_pool_store_addr_r, 51);
        assert!(fa_y_pool_store_addr_f != fa_y_pool_store_addr_r, 52);

        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr_f, fa_x_fake_metadata), 53);
        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr_f, fa_y_metadata), 54);
        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr_r, fa_x_real_metadata), 55);
        assert!(primary_fungible_store::primary_store_exists(pool_fa_store_res_acc_addr_r, fa_y_metadata), 56);

        // Check LP objects created.
        let lp_fa_obj_seed_f = string::utf8(*pool_obj_name_f);
        string::append_utf8( &mut lp_fa_obj_seed_f, b"-LP");
        let lp_fa_obj_addr_f =
            object::create_object_address(&@liquidswap_pool_account, *string::bytes(&lp_fa_obj_seed_f));
        let lp_fa_obj_f = object::address_to_object<Metadata>(lp_fa_obj_addr_f);
        assert!(object::object_exists<Metadata>(lp_fa_obj_addr_f), 57);
        assert!(object::is_untransferable(lp_fa_obj_f), 58);

        let lp_fa_obj_seed_r = string::utf8(*pool_obj_name_r);
        string::append_utf8( &mut lp_fa_obj_seed_r, b"-LP");
        let lp_fa_obj_addr_r =
            object::create_object_address(&@liquidswap_pool_account, *string::bytes(&lp_fa_obj_seed_r));
        let lp_fa_obj_r = object::address_to_object<Metadata>(lp_fa_obj_addr_r);
        assert!(object::object_exists<Metadata>(lp_fa_obj_addr_r), 59);
        assert!(object::is_untransferable(lp_fa_obj_r), 60);

        // Check LP objects differ.
        assert!(lp_fa_obj_seed_f != lp_fa_obj_seed_r, 61);
        assert!(lp_fa_obj_addr_f != lp_fa_obj_addr_r, 62);

        // Check LP FA stores created.
        let fa_res_acc_addr_f =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name_f);
        let lp_metadata_f =
            get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_fake_metadata, fa_y_metadata);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_f, lp_metadata_f), 63);

        let fa_res_acc_addr_r =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name_r);
        let lp_metadata_r =
            get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_real_metadata, fa_y_metadata);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr_r, lp_metadata_r), 64);

        // Check LP FA stores are different.
        assert!(lp_metadata_f != lp_metadata_r, 65);

        // Check pools store correct LP metadata addresses.
        assert!(liquidity_pool::get_pool_lp_metadata<Uncorrelated>(fa_x_fake_metadata, fa_y_metadata) == lp_metadata_f, 66);
        assert!(liquidity_pool::get_pool_lp_metadata<Uncorrelated>(fa_x_real_metadata, fa_y_metadata) == lp_metadata_r, 67);
    }

    // Add liquidity tests.
    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_POOL_DOES_NOT_EXIST)]
    fun test_fail_if_pool_for_this_pair_does_not_exist() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_liq_val = 100000000;
        let usdc_liq_val = 28000000000;
        let btc_liq = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val);
        let usdc_liq = test_fas::mint_fa(&fa_admin, b"USDC", usdc_liq_val);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_liq, usdc_liq);
    }

    #[test]
    fun test_add_liquidity_to_empty_pool() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let btc_liq_val = 100000000;
        let usdt_liq_val = 28000000000;
        let btc_liq = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val);
        let usdt_liq = test_fas::mint_fa(&fa_admin, b"USDT", usdt_liq_val);

        timestamp::fast_forward_seconds(1660338836);

        // Check directly that pool LP FA store is empty before first mint.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let pool_fa_store_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name);
        let lp_metadata =
            get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, lp_metadata) == 0, 1);

        // Check LP supply getter before first mint.
        assert!(liquidity_pool::get_pool_lp_supply<Uncorrelated>(fa_x_metadata, fa_y_metadata) == 0, 2);

        let lp_fa_val =
            test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_liq, usdt_liq);

        let expected_liquidity = 1673320053;
        assert!(lp_fa_val == expected_liquidity - MINIMAL_LIQUIDITY, 3);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == btc_liq_val, 4);
        assert!(y_res == usdt_liq_val, 5);

        // Check pool FA stores directly.
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_x_metadata) == btc_liq_val, 6);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_y_metadata) == usdt_liq_val, 7);

        // Check directly that pool LP FA store contains MINIMAL_LIQUIDITY amount.
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, lp_metadata) == MINIMAL_LIQUIDITY, 8);

        // Check LP supply getter before after mint.
        assert!(option::extract(&mut fungible_asset::supply(lp_metadata)) ==
            (expected_liquidity as u128), 9);
        assert!(liquidity_pool::get_pool_lp_supply<Uncorrelated>(fa_x_metadata, fa_y_metadata) ==
            (expected_liquidity as u128), 10);

        let (x_price, y_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_price == 0, 11);
        assert!(y_price == 0, 12);
        assert!(ts == 1660338836, 13);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_NOT_ENOUGH_INITIAL_LIQUIDITY)]
    fun test_add_liquidity_less_than_minimal() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_liq_val = 1000;
        let usdt_liq_val = 1000;
        let btc_liq = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val);
        let usdt_liq = test_fas::mint_fa(&fa_admin, b"USDT", usdt_liq_val);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_liq, usdt_liq);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_NOT_ENOUGH_INITIAL_LIQUIDITY)]
    fun test_fail_if_adding_zero_liquidity_initially() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_liq_val = 0;
        let usdt_liq_val = 0;
        let btc_liq = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val);
        let usdt_liq = test_fas::mint_fa(&fa_admin, b"USDT", usdt_liq_val);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_liq, usdt_liq);
    }

    #[test]
    fun test_add_liquidity_minimal() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_liq_val = 1001;
        let usdt_liq_val = 1001;
        let btc_liq = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val);
        let usdt_liq = test_fas::mint_fa(&fa_admin, b"USDT", usdt_liq_val);

        let lp_fa_val =
            test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_liq, usdt_liq);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let expected_liquidity = 1001;
        assert!(lp_fa_val == expected_liquidity - MINIMAL_LIQUIDITY, 0);
        assert!(liquidity_pool::get_pool_lp_supply<Uncorrelated>(fa_x_metadata, fa_y_metadata) ==
            (expected_liquidity as u128), 1);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == btc_liq_val, 2);
        assert!(y_res == usdt_liq_val, 3);
    }

    #[test(emergency_acc = @emergency_admin)]
    #[expected_failure(abort_code = emergency::ERR_EMERGENCY)]
    fun test_add_liquidity_emergency_stop_fails(emergency_acc: signer) {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_liq_val = 1001;
        let usdt_liq_val = 1001;
        let btc_liq = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val);
        let usdt_liq = test_fas::mint_fa(&fa_admin, b"USDT", usdt_liq_val);

        emergency::pause(&emergency_acc);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_liq, usdt_liq);
    }

    #[test]
    fun test_add_liquidity_after_initial_liquidity_added() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_liq_val = 100000000;
        let usdt_liq_val = 28000000000;
        let btc_liq = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val);
        let usdt_liq = test_fas::mint_fa(&fa_admin, b"USDT", usdt_liq_val);

        let initial_ts = 1660338836;
        timestamp::fast_forward_seconds(initial_ts);

        let lp_fa_val =
            test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_liq, usdt_liq);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let expected_liquidity = 1673320053;
        assert!(lp_fa_val == expected_liquidity - MINIMAL_LIQUIDITY, 0);
        assert!(liquidity_pool::get_pool_lp_supply<Uncorrelated>(fa_x_metadata, fa_y_metadata) ==
            (expected_liquidity as u128), 1);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == btc_liq_val, 2);
        assert!(y_res == usdt_liq_val, 3);

        // Check pool FA stores directly.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let pool_fa_store_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_x_metadata) == btc_liq_val, 4);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_y_metadata) == usdt_liq_val, 5);

        let (x_price, y_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_price == 0, 6);
        assert!(y_price == 0, 7);
        assert!(ts == initial_ts, 8);

        timestamp::fast_forward_seconds(360);

        let expected_liquidity_2 = 3346640106;
        let btc_liq = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val * 2);
        let usdt_liq = test_fas::mint_fa(&fa_admin, b"USDT", usdt_liq_val * 2);

        let lp_fa_val =
            test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_liq, usdt_liq);

        assert!(lp_fa_val == expected_liquidity_2, 9);
        assert!(liquidity_pool::get_pool_lp_supply<Uncorrelated>(fa_x_metadata, fa_y_metadata) ==
            ((expected_liquidity_2 + expected_liquidity) as u128), 10);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == btc_liq_val * 3, 11);
        assert!(y_res == usdt_liq_val * 3, 12);

        // Check pool FA stores directly.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let pool_fa_store_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_x_metadata) == btc_liq_val * 3, 14);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_y_metadata) == usdt_liq_val * 3, 15);

        let (x_price, y_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_price == 1859431802629922802792000, 16);
        assert!(y_price == 23717242380483709200, 17);
        assert!(ts == initial_ts + 360, 18);
    }

    #[test]
    fun test_add_liquidity_aptos_coin() {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        // Create AptosCoin.
        let aptos_framework = account::create_signer_for_test(@aptos_framework);
        let (apt_burn_cap, apt_mint_cap) =
            aptos_coin::initialize_for_test_without_aggregator_factory(&aptos_framework);

        let fa_x_metadata = option::extract(&mut coin::paired_metadata<AptosCoin>());
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);

        // Check APT <=> BTC pool LP created.
        let lp_metadata =
            get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let fa_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account,*pool_obj_name);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr, lp_metadata), 1);
        assert!(!object::object_exists<Metadata>(
            get_lp_fa_metadata_obj_addr_from_x_y_metadatas<Uncorrelated>(fa_y_metadata, fa_x_metadata)), 2);

        // todo: recheck LP
        let lp_name = fungible_asset::name(lp_metadata);
        assert!(lp_name == utf8(b"LS05 LP-APT-BTC-U"), 3);
        let lp_symbol = fungible_asset::symbol(lp_metadata);
        assert!(lp_symbol == utf8(b"APT-BTCU"), 4);
        let lp_supply = fungible_asset::supply(lp_metadata);
        assert!(option::is_some(&lp_supply), 5);
        assert!(*option::borrow(&lp_supply) == 0, 6);

        let apt_liq_val = 100000000;
        let btc_liq_val = 28000000000;

        let apt_liq_coins = coin::mint<AptosCoin>(apt_liq_val, &apt_mint_cap);
        let apt_liq_fa = coin::coin_to_fungible_asset(apt_liq_coins);
        let btc_liq_fa = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val);

        timestamp::fast_forward_seconds(1660338836);

        // Check directly that pool LP FA store is empty before first mint.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let pool_fa_store_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name);
        let lp_metadata =
            get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, lp_metadata) == 0, 7);

        // Check LP supply getter before first mint.
        assert!(liquidity_pool::get_pool_lp_supply<Uncorrelated>(fa_x_metadata, fa_y_metadata) == 0, 8);

        let lp_fa_val =
            test_pool::mint_liquidity<Uncorrelated>(&lp_owner, apt_liq_fa, btc_liq_fa);

        let expected_liquidity = 1673320053;
        assert!(lp_fa_val == expected_liquidity - MINIMAL_LIQUIDITY, 9);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == apt_liq_val, 10);
        assert!(y_res == btc_liq_val, 11);

        // Check pool FA stores directly.
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_x_metadata) == apt_liq_val, 12);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_y_metadata) == btc_liq_val, 13);

        // Check directly that pool LP FA store contains MINIMAL_LIQUIDITY amount.
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, lp_metadata) == MINIMAL_LIQUIDITY, 14);

        // Check LP supply getter before after mint.
        assert!(option::extract(&mut fungible_asset::supply(lp_metadata)) ==
            (expected_liquidity as u128), 15);
        assert!(liquidity_pool::get_pool_lp_supply<Uncorrelated>(fa_x_metadata, fa_y_metadata) ==
            (expected_liquidity as u128), 16);

        let (x_price, y_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_price == 0, 17);
        assert!(y_price == 0, 18);
        assert!(ts == 1660338836, 19);

        coin::destroy_burn_cap(apt_burn_cap);
        coin::destroy_mint_cap(apt_mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_NOT_ENOUGH_LIQUIDITY)]
    fun test_add_liquidity_zero_for_pool_with_existing_liquidity() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 100100);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100100);

        let lp_fa_val =
            test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);
        assert!(lp_fa_val == 99100, 0);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 100100, 1);
        assert!(y_res == 100100, 2);

        test_pool::mint_liquidity<Uncorrelated>(
            &lp_owner,
            fungible_asset::zero(fa_x_metadata),
            fungible_asset::zero(fa_y_metadata))
        ;
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_PAIR_ORDERING)]
    fun test_add_liquidity_wrong_fa_ordering() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_liq_val = 1000;
        let usdt_liq_val = 1000;
        let btc_liq = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val);
        let usdt_liq = test_fas::mint_fa(&fa_admin, b"USDT", usdt_liq_val);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, usdt_liq, btc_liq);
    }

    // Test burn liquidity.
    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_BURN_VALUES)]
    fun test_fail_if_trying_to_burn_zero_values() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 2000000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 560000000000000);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let lp_metadata = get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let (btc_return, usdt_return) =
            liquidity_pool::burn<Uncorrelated>(
                fungible_asset::zero(lp_metadata),
                fa_x_metadata,
                fa_y_metadata,
            );

        test_fas::burn_fa(&fa_admin, b"BTC", btc_return);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_return);
    }

    // Test burn liquidity.
    #[test]
    fun test_burn_liquidity_at_pool_registration() {
        let (fa_admin, _) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 2000000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 560000000000000);

        let lp_fa =
            liquidity_pool::mint<Uncorrelated>(btc_fa, usdt_fa);
        assert!(fungible_asset::amount(&lp_fa) == 33466401060363, 0);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 2000000000000, 1);
        assert!(y_res == 560000000000000, 2);

        let (btc_return, usdt_return) =
            liquidity_pool::burn<Uncorrelated>(lp_fa, fa_x_metadata, fa_y_metadata);

        assert!(fungible_asset::amount(&btc_return) == 1999999999940, 3);
        assert!(fungible_asset::amount(&usdt_return) == 559999999983266, 4);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 60, 5);
        assert!(y_res == 16734, 6);

        // Check pool FA stores directly.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let pool_fa_store_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_x_metadata) == 60, 7);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_y_metadata) == 16734, 8);

        test_fas::burn_fa(&fa_admin, b"BTC", btc_return);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_return);
    }

    #[test]
    fun test_burn_liquidity_after_initial() {
        let (fa_admin, _) = setup_btc_usdt_pool();

        // Initial liquidity

        timestamp::fast_forward_seconds(1660517742);

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 2000000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 560000000000000);

        let lp_fa_initial =
            liquidity_pool::mint<Uncorrelated>(btc_fa, usdt_fa);

        // Additional liquidity

        timestamp::fast_forward_seconds(7200);

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 50000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 14000000000);

        let lp_fa_user =
            liquidity_pool::mint<Uncorrelated>(btc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (btc_return, usdt_return) =
            liquidity_pool::burn<Uncorrelated>(lp_fa_initial, fa_x_metadata, fa_y_metadata);

        assert!(fungible_asset::amount(&btc_return) == 1999999999940, 0);
        assert!(fungible_asset::amount(&usdt_return) == 559999999983275, 1);

        test_fas::burn_fa(&fa_admin, b"BTC", btc_return);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_return);

        let (btc_return, usdt_return) =
            liquidity_pool::burn<Uncorrelated>(lp_fa_user, fa_x_metadata, fa_y_metadata);

        assert!(fungible_asset::amount(&btc_return) == 50000000, 2);
        assert!(fungible_asset::amount(&usdt_return) == 13999999991, 3);

        test_fas::burn_fa(&fa_admin, b"BTC", btc_return);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_return);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 60, 4);
        assert!(y_res == 16734, 5);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 37188636052598456055840000, 6);
        assert!(y_cum_price == 474344847609674184000, 7);
        assert!(ts == 1660517742 + 7200, 8);
    }

    #[test]
    fun test_overflow_and_emergency_exit() {
        let (fa_admin, _) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 18446744073709551615);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 18446744073709551615);

        // Now we can't swap or add liquidity, if cumulative price is still has space, it wouldn never overflow,
        // we are able to exit.

        let lp_fa =
            liquidity_pool::mint<Uncorrelated>(btc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (btc_return, usdt_return) =
            liquidity_pool::burn<Uncorrelated>(lp_fa, fa_x_metadata, fa_y_metadata);

        assert!(fungible_asset::amount(&btc_return) == 18446744073709550615, 0);
        assert!(fungible_asset::amount(&usdt_return) == 18446744073709550615, 1);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 1000, 2);
        assert!(y_res == 1000, 3);

        test_fas::burn_fa(&fa_admin, b"BTC", btc_return);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_return);
    }

    #[test(emergency_acc = @emergency_admin)]
    fun test_emergency_exit(emergency_acc: signer) {
        let (fa_admin, _) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 18446744073709551615);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 18446744073709551615);

        // Now we can't swap or add liquidity, if cumulative price is still has space, it wouldn never overflow,
        // we are able to exit.

        let lp_fa =
            liquidity_pool::mint<Uncorrelated>(btc_fa, usdt_fa);

        emergency::pause(&emergency_acc);
        assert!(emergency::is_emergency() == true, 0);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (btc_return, usdt_return) =
            liquidity_pool::burn<Uncorrelated>(lp_fa, fa_x_metadata, fa_y_metadata);

        assert!(fungible_asset::amount(&btc_return) == 18446744073709550615, 1);
        assert!(fungible_asset::amount(&usdt_return) == 18446744073709550615, 2);

        test_fas::burn_fa(&fa_admin, b"BTC", btc_return);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_return);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_PAIR_ORDERING)]
    fun test_burn_liquidity_wrong_fa_ordering() {
        let (fa_admin, _) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 2000000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 560000000000000);

        let lp_fa =
            liquidity_pool::mint<Uncorrelated>(btc_fa, usdt_fa);
        assert!(fungible_asset::amount(&lp_fa) == 33466401060363, 0);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (btc_return, usdt_return) =
            liquidity_pool::burn<Uncorrelated>(lp_fa, fa_y_metadata, fa_x_metadata);

        test_fas::burn_fa(&fa_admin, b"BTC", btc_return);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_return);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_POOL)]
    fun test_burn_liquidity_fails_when_wrong_lp_passed() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        // Create fake BTC FA.
        let (mint_ref, _) = test_fas::register_fa(
            &fa_admin,
            b"BTC Fungible Asset",
            b"BTC",
            8,
            b"BTC2_FA_OBJ"
        );

        let fa_x_fake_metadata = fungible_asset::mint_ref_metadata(&mint_ref);
        let fa_x_real_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        // Create fake BTC pool.
        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_fake_metadata, fa_y_metadata);

        // Mint fake BTC liquidity.
        let fake_btc_fa = fungible_asset::mint(&mint_ref, 2000000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 560000000000000);

        let fake_lp_fa =
            liquidity_pool::mint<Uncorrelated>(fake_btc_fa, usdt_fa);
        assert!(fungible_asset::amount(&fake_lp_fa) == 33466401060363, 1);

        // Try to get real BTC for fake LP.
        let (btc_return, usdt_return) =
            liquidity_pool::burn<Uncorrelated>(fake_lp_fa, fa_x_real_metadata, fa_y_metadata);

        primary_fungible_store::deposit(signer::address_of(&lp_owner), btc_return);
        primary_fungible_store::deposit(signer::address_of(&lp_owner), usdt_return);
    }

    // Test swap.
    #[test]
    fun test_swap_coins() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 100100);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100100);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let btc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 2);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 1
            );
        assert!(fungible_asset::amount(&usdt_fa) == 1, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 100102, 1);
        assert!(y_res == 100099, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test(emergency_acc = @emergency_admin)]
    #[expected_failure(abort_code = emergency::ERR_EMERGENCY)]
    fun test_swap_coins_emergency_fails(emergency_acc: signer) {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 100100);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100100);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        emergency::pause(&emergency_acc);

        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let btc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 2);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 1
            );

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    fun test_swap_coins_max_amounts() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 18446744073709550615);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 18446744073709551615);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let btc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 1000);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 0
            );

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    fun test_swap_coins_1() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 10000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 2800000000000);

        timestamp::fast_forward_seconds(1660545565);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        timestamp::fast_forward_seconds(20);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let btc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 100000000);
        let (btc_zero, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 27640424963
            );
        assert!(fungible_asset::amount(&usdt_fa) == 27640424963, 1);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 10099900000, 2);
        assert!(y_res == 2772359575037, 3);

        // Check pool FA stores directly.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let pool_fa_store_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_x_metadata) == 10099900000, 4);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_y_metadata) == 2772359575037, 5);

        // Check DAO FA stores directly.
        let storage_creator_addr =
            account::create_resource_address(&@liquidswap_v05, b"dao_fa_store_sig_cap_seed");
        let storage_seed =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let fa_res_acc_addr =
            account::create_resource_address(&storage_creator_addr, *string::bytes(&storage_seed));
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_x_metadata) == 100000, 6);
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_y_metadata) == 0, 7);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 103301766812773489044000, 8);
        assert!(y_cum_price == 1317624576693539400, 9);
        assert!(ts == 1660545565 + 20, 10);

        timestamp::fast_forward_seconds(3600);

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 1000000);
        let (btc_fa, usdt_zero) =
            liquidity_pool::swap<Uncorrelated>(
                fungible_asset::zero(fa_x_metadata), 3632,
                usdt_fa_to_exchange, 0
            );

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 10099896368, 11);
        assert!(y_res == 2772360574037, 12);

        // Check pool FA stores directly.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let pool_fa_store_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_x_metadata) == 10099896368, 13);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_y_metadata) == 2772360574037, 14);

        // Check DAO FA stores directly.
        let storage_creator_addr =
            account::create_resource_address(&@liquidswap_v05, b"dao_fa_store_sig_cap_seed");
        let storage_seed =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let fa_res_acc_addr =
            account::create_resource_address(&storage_creator_addr, *string::bytes(&storage_seed));
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_x_metadata) == 100000, 15);
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_y_metadata) == 1000, 16);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 18331960191116039718441600, 17);
        assert!(y_cum_price == 243247632405227595000, 18);
        assert!(ts == 1660545565 + 20 + 3600, 19);

        fungible_asset::destroy_zero(btc_zero);
        fungible_asset::destroy_zero(usdt_zero);
        test_fas::burn_fa(&fa_admin, b"BTC", btc_fa);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_swap_coins_1_fail() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 10000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 2800000000000);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let btc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 100000000);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 27640424964
            );
        assert!(fungible_asset::amount(&usdt_fa) == 27640424964, 0);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_EMPTY_FA_IN)]
    fun test_swap_coins_zero_fail() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 10000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 2800000000000);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (btc_fa, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                fungible_asset::zero(fa_x_metadata), 1,
                fungible_asset::zero(fa_y_metadata), 1
            );

        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
        test_fas::burn_fa(&fa_admin, b"BTC", btc_fa);
    }

    #[test]
    fun test_swap_coins_vice_versa() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 10000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 2800000000000);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 28000000000);
        let (btc_fa, zero) =
            liquidity_pool::swap<Uncorrelated>(
                fungible_asset::zero(fa_x_metadata), 98715803,
                usdt_fa_to_exchange, 0
            );
        assert!(fungible_asset::amount(&btc_fa) == 98715803, 0);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 9901284197, 1);
        assert!(y_res == 2827972000000, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"BTC", btc_fa);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_swap_coins_vice_versa_fail() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 10000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 2800000000000);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 28000000000);
        let (btc_fa, zero) =
            liquidity_pool::swap<Uncorrelated>(
                fungible_asset::zero(fa_x_metadata), 98715804,
                usdt_fa_to_exchange, 0
            );
        assert!(fungible_asset::amount(&btc_fa) == 98715804, 0);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"BTC", btc_fa);
    }

    #[test]
    fun test_swap_two_coins_success() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 10000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 2800000000000);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 28000000000);
        let btc_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 100000000);
        let (btc_fa, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_to_exchange, 99900003,
                usdt_fa_to_exchange, 27859998039
            );

        assert!(fungible_asset::amount(&btc_fa) == 99900003, 0);
        assert!(fungible_asset::amount(&usdt_fa) == 27859998039, 1);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 9999999997, 2);
        assert!(y_res == 2800112001961, 3);

        // Check pool FA stores directly.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let pool_fa_store_res_acc_addr =
            account::create_resource_address(&@liquidswap_pool_account, *pool_obj_name);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_x_metadata) == 9999999997, 4);
        assert!(primary_fungible_store::balance(pool_fa_store_res_acc_addr, fa_y_metadata) == 2800112001961, 5);

        // Check DAO FA stores directly.
        let storage_creator_addr =
            account::create_resource_address(&@liquidswap_v05, b"dao_fa_store_sig_cap_seed");
        let storage_seed =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let fa_res_acc_addr =
            account::create_resource_address(&storage_creator_addr, *string::bytes(&storage_seed));
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_x_metadata) == 100000, 6);
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_y_metadata) == 28000000, 7);

        test_fas::burn_fa(&fa_admin, b"BTC", btc_fa);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_swap_two_coins_failure() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 10000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 2800000000000);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 28000000000);
        let btc_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 100000000);
        let (btc_fa, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_to_exchange, 99900003,
                usdt_fa_to_exchange, 27859998040
            );

        assert!(fungible_asset::amount(&btc_fa) == 99900003, 0);
        assert!(fungible_asset::amount(&usdt_fa) == 27859998040, 1);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 9999999997, 2);
        assert!(y_res == 2800112001960, 3);

        test_fas::burn_fa(&fa_admin, b"BTC", btc_fa);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_cannot_swap_coins_and_reduce_value_of_pool() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 100100);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100100);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        // 1 minus fee for 1
        let btc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 1);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 1
            );
        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    fun test_swap_coins_with_stable_curve_type() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 1000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let usdc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDC", 1);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Stable>(
                usdc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 99
            );
        assert!(fungible_asset::amount(&usdt_fa) == 99, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 1000001, 1);
        assert!(y_res == 99999901, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    fun test_swap_coins_with_stable_curve_type_1() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 15000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 1500000000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let usdc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDC", 7078017525);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Stable>(
                usdc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 672790928423
            );
        assert!(fungible_asset::amount(&usdt_fa) == 672790928423, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 22076601922, 1);
        assert!(y_res == 827209071577, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    fun test_swap_coins_with_stable_curve_type_2() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 15000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 1500000000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let usdc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDC", 152);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Stable>(
                usdc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 15199
            );
        assert!(fungible_asset::amount(&usdt_fa) == 15199, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 15000000152, 1);
        assert!(y_res == 1499999984801, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    fun test_swap_coins_with_stable_curve_type_3() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 15000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 1500000000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let usdc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDC", 6748155);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Stable>(
                usdc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 672791099
            );
        assert!(fungible_asset::amount(&usdt_fa) == 672791099, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 15006746806, 1);
        assert!(y_res == 1499327208901, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    fun test_swap_coins_with_stable_curve_type_1_unit() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 1000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let usdc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDC", 10000);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Stable>(
                usdc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 996999
            );
        assert!(fungible_asset::amount(&usdt_fa) == 996999, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 1009998, 1);
        assert!(y_res == 99003001, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_swap_coins_with_stable_curve_type_1_unit_fail() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 1000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let usdc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDC", 10000);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Stable>(
                usdc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 999600
            );
        assert!(fungible_asset::amount(&usdt_fa) == 999600, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 1009990, 1);
        assert!(y_res == 99003000, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_swap_coins_with_stable_curve_type_fails() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 1000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let usdc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDC", 1);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Stable>(
                usdc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 100
            );
        assert!(fungible_asset::amount(&usdt_fa) == 100, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 1000001, 1);
        assert!(y_res == 99999901, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    fun test_swap_coins_with_stable_curve_type_vice_versa() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 1000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 999901);
        let (usdc_fa, zero) =
            liquidity_pool::swap<Stable>(
                fungible_asset::zero(fa_x_metadata), 9969,
                usdt_fa_to_exchange, 0
            );
        assert!(fungible_asset::amount(&usdc_fa) == 9969, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(y_res == 100999702, 1);
        assert!(x_res == 990031, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDC", usdc_fa);
    }

    #[test]
    fun test_swap_coins_two_coins_with_stable_curve() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 1000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 1000000);
        let usdc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDC", 10000);

        let (usdc_fa, usdt_fa) =
            liquidity_pool::swap<Stable>(
                usdc_fa_to_exchange, 9969,
                usdt_fa_to_exchange, 997099
            );

        assert!(fungible_asset::amount(&usdc_fa) == 9969, 0);
        assert!(fungible_asset::amount(&usdt_fa) == 997099, 1);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 1000029, 2);
        assert!(y_res == 100002701, 3);

        test_fas::burn_fa(&fa_admin, b"USDC", usdc_fa);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_swap_coins_two_coins_with_stable_curve_fail() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 1000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 1000000);
        let usdc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDC", 10000);

        let (usdc_fa, usdt_fa) =
            liquidity_pool::swap<Stable>(
                usdc_fa_to_exchange, 9996,
                usdt_fa_to_exchange, 999699
            );

        assert!(fungible_asset::amount(&usdc_fa) == 9996, 0);
        assert!(fungible_asset::amount(&usdt_fa) == 999699, 1);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 1000020, 2);
        assert!(y_res == 100001901, 3);

        test_fas::burn_fa(&fa_admin, b"USDC", usdc_fa);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    fun test_swap_coins_with_stable_curve_type_vice_versa_1() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 15000000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 1500000000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 125804314);
        let (usdc_fa, zero) =
            liquidity_pool::swap<Stable>(
                fungible_asset::zero(fa_x_metadata), 1254269,
                usdt_fa_to_exchange, 0
            );
        assert!(fungible_asset::amount(&usdc_fa) == 1254269, 0);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDC", usdc_fa);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_swap_coins_with_stable_curve_type_vice_versa_fail() {
        let (fa_admin, lp_owner) = setup_usdc_usdt_pool();

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 1000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 1000000);
        let (usdc_fa, zero) =
            liquidity_pool::swap<Stable>(
                fungible_asset::zero(fa_x_metadata), 9996,
                usdt_fa_to_exchange, 0
            );
        assert!(fungible_asset::amount(&usdc_fa) == 9996, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(y_res == 100999000, 1);
        assert!(x_res == 990030, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDC", usdc_fa);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_PAIR_ORDERING)]
    fun test_swap_wrong_fa_ordering() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 100100);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 100100);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let btc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 2);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                fungible_asset::zero(fa_y_metadata), 0,
                btc_fa_to_exchange, 1
            );

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    // Getters.

    #[test(emergency_acc = @emergency_admin)]
    #[expected_failure(abort_code = emergency::ERR_EMERGENCY)]
    fun test_get_reserves_emergency_fails(emergency_acc: signer) {
        let (_, _) = setup_btc_usdt_pool();

        emergency::pause(&emergency_acc);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (_, _) = liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
    }

    #[test(emergency_acc = @emergency_admin)]
    #[expected_failure(abort_code = emergency::ERR_EMERGENCY)]
    fun test_get_cumulative_price_emergency_fails(emergency_acc: signer) {
        let (_, _) = setup_btc_usdt_pool();

        emergency::pause(&emergency_acc);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (_, _, _) = liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
    }

    #[test]
    fun test_pool_exists() {
        let (_, _) = setup_btc_usdt_pool();

        let btc_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let usdc_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let usdt_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        assert!(liquidity_pool::is_pool_exists<Uncorrelated>(btc_metadata, usdt_metadata), 0);
        assert!(!liquidity_pool::is_pool_exists<Uncorrelated>(usdc_metadata, usdt_metadata), 1);
    }

    #[test]
    fun test_fees_config() {
        setup_btc_usdt_pool();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (fee_pct, fee_scale) =
            liquidity_pool::get_fees_config<Uncorrelated>(fa_x_metadata, fa_y_metadata);

        assert!(fee_pct == 30, 0);
        assert!(fee_scale == 10000, 1);
    }

    // End to end.

    #[test]
    fun test_end_to_end() {
        let (fa_admin, _) = setup_btc_usdt_pool();

        let btc_fa_initial = test_fas::mint_fa(&fa_admin, b"BTC", 10000000000);
        let usdt_fa_initial = test_fas::mint_fa(&fa_admin, b"USDT", 2800000000000);

        timestamp::fast_forward_seconds(1660545565);

        let lp_fa_initial =
            liquidity_pool::mint<Uncorrelated>(btc_fa_initial, usdt_fa_initial);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 10000000000, 0);
        assert!(y_res == 2800000000000, 1);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 0, 2);
        assert!(y_cum_price == 0, 3);
        assert!(ts == 1660545565, 4);

        let btc_fa_user = test_fas::mint_fa(&fa_admin, b"BTC", 1500000000);
        let usdt_fa_user = test_fas::mint_fa(&fa_admin, b"USDT", 420000000000);

        let lp_fa_user =
            liquidity_pool::mint<Uncorrelated>(btc_fa_user, usdt_fa_user);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 11500000000, 5);
        assert!(y_res == 3220000000000, 6);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 0, 7);
        assert!(y_cum_price == 0, 8);
        assert!(ts == 1660545565, 9);

        timestamp::fast_forward_seconds(3600);

        let btc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 2500000000);
        let (btc_zero, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 573582276219
            );
        assert!(fungible_asset::amount(&usdt_fa) == 573582276219, 10);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 13997500000, 11);
        assert!(y_res == 2646417723781, 12);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 18594318026299228027920000, 12);
        assert!(y_cum_price == 237172423804837092000, 13);
        assert!(ts == 1660549165, 14);

        let lp_fa_user_val = fungible_asset::amount(&lp_fa_user);
        let lp_fa_to_burn_part =
            fungible_asset::extract(&mut lp_fa_user, lp_fa_user_val / 2);
        let (btc_earned_user, usdt_earned_user) =
            liquidity_pool::burn<Uncorrelated>(
                lp_fa_to_burn_part,
                fa_x_metadata,
                fa_y_metadata,
        );

        assert!(fungible_asset::amount(&btc_earned_user) == 912880434, 15);
        assert!(fungible_asset::amount(&usdt_earned_user) == 172592460234, 16);

        test_fas::burn_fa(&fa_admin, b"BTC", btc_earned_user);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_earned_user);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 13084619566, 17);
        assert!(y_res == 2473825263547, 18);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 18594318026299228027920000, 19);
        assert!(y_cum_price == 237172423804837092000, 20);
        assert!(ts == 1660549165, 21);

        timestamp::fast_forward_seconds(3600);

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 10000000000);
        let (btc_fa, usdt_zero) =
            liquidity_pool::swap<Uncorrelated>(
                fungible_asset::zero(fa_x_metadata), 52521904,
                usdt_fa_to_exchange, 0
            );

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 13032097662, 22);
        assert!(y_res == 2483815263547, 23);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 31149706178195224153700400, 24);
        assert!(y_cum_price == 588420782034956560800, 25);
        assert!(ts == 1660552765, 26);

        timestamp::fast_forward_seconds(3600);

        let (btc_earned_user, usdt_earned_user) =
            liquidity_pool::burn<Uncorrelated>(
                lp_fa_user,
                fa_x_metadata,
                fa_y_metadata,
            );
        assert!(fungible_asset::amount(&btc_earned_user) == 909216115, 27);
        assert!(fungible_asset::amount(&usdt_earned_user) == 173289436992, 28);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 12122881547, 29);
        assert!(y_res == 2310525826555, 30);

        let (btc_earned_initial, usdt_earned_initial) =
            liquidity_pool::burn<Uncorrelated>(
                lp_fa_initial,
                fa_x_metadata,
                fa_y_metadata
            );
        assert!(fungible_asset::amount(&btc_earned_initial) == 12122881474, 31);
        assert!(fungible_asset::amount(&usdt_earned_initial) == 2310525812746, 32);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 73, 33);
        assert!(y_res == 13809, 34);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 43806601518678425423523600, 35);
        assert!(y_cum_price == 936852159292991150400, 36);
        assert!(ts == 1660556365, 37);

        fungible_asset::destroy_zero(btc_zero);
        fungible_asset::destroy_zero(usdt_zero);
        test_fas::burn_fa(&fa_admin, b"BTC", btc_fa);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
        test_fas::burn_fa(&fa_admin, b"BTC", btc_earned_user);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_earned_user);
        test_fas::burn_fa(&fa_admin, b"BTC", btc_earned_initial);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_earned_initial);
    }

    #[test(emergency_acc = @emergency_admin)]
    fun test_end_to_end_emergency(emergency_acc: signer) {
        let (fa_admin, _) = setup_btc_usdt_pool();

        let btc_fa_initial = test_fas::mint_fa(&fa_admin, b"BTC", 10000000000);
        let usdt_fa_initial = test_fas::mint_fa(&fa_admin, b"USDT", 2800000000000);

        timestamp::fast_forward_seconds(1660545565);

        let lp_fa_initial =
            liquidity_pool::mint<Uncorrelated>(btc_fa_initial, usdt_fa_initial);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 10000000000, 0);
        assert!(y_res == 2800000000000, 1);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 0, 2);
        assert!(y_cum_price == 0, 3);
        assert!(ts == 1660545565, 4);

        let btc_fa_user = test_fas::mint_fa(&fa_admin, b"BTC", 1500000000);
        let usdt_fa_user = test_fas::mint_fa(&fa_admin, b"USDT", 420000000000);

        let lp_fa_user =
            liquidity_pool::mint<Uncorrelated>(btc_fa_user, usdt_fa_user);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 11500000000, 5);
        assert!(y_res == 3220000000000, 6);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 0, 7);
        assert!(y_cum_price == 0, 8);
        assert!(ts == 1660545565, 9);

        timestamp::fast_forward_seconds(3600);

        let btc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 2500000000);
        let (btc_zero, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 573582276219
            );
        assert!(fungible_asset::amount(&usdt_fa) == 573582276219, 10);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 13997500000, 11);
        assert!(y_res == 2646417723781, 12);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 18594318026299228027920000, 13);
        assert!(y_cum_price == 237172423804837092000, 14);
        assert!(ts == 1660549165, 15);

        emergency::pause(&emergency_acc);
        let lp_fa_user_val = fungible_asset::amount(&lp_fa_user);
        let lp_fa_to_burn_part = fungible_asset::extract(&mut lp_fa_user, lp_fa_user_val / 2);
        let (btc_earned_user, usdt_earned_user) =
            liquidity_pool::burn<Uncorrelated>(
                lp_fa_to_burn_part,
                fa_x_metadata,
                fa_y_metadata,
            );

        assert!(fungible_asset::amount(&btc_earned_user) == 912880434, 16);
        assert!(fungible_asset::amount(&usdt_earned_user) == 172592460234, 17);

        test_fas::burn_fa(&fa_admin, b"BTC", btc_earned_user);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_earned_user);

        emergency::resume(&emergency_acc);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 13084619566, 18);
        assert!(y_res == 2473825263547, 19);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 18594318026299228027920000, 20);
        assert!(y_cum_price == 237172423804837092000, 21);
        assert!(ts == 1660549165, 22);

        timestamp::fast_forward_seconds(3600);

        let usdt_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDT", 10000000000);
        let (btc_fa, usdt_zero) =
            liquidity_pool::swap<Uncorrelated>(
                fungible_asset::zero(fa_x_metadata), 52521904,
                usdt_fa_to_exchange, 0
            );

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 13032097662, 23);
        assert!(y_res == 2483815263547, 24);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 31149706178195224153700400, 25);
        assert!(y_cum_price == 588420782034956560800, 26);
        assert!(ts == 1660552765, 27);

        timestamp::fast_forward_seconds(3600);

        emergency::pause(&emergency_acc);

        let (btc_earned_user, usdt_earned_user) =
            liquidity_pool::burn<Uncorrelated>(
                lp_fa_user,
                fa_x_metadata,
                fa_y_metadata
            );
        assert!(fungible_asset::amount(&btc_earned_user) == 909216115, 28);
        assert!(fungible_asset::amount(&usdt_earned_user) == 173289436992, 29);

        let (btc_earned_initial, usdt_earned_initial) =
            liquidity_pool::burn<Uncorrelated>(
                lp_fa_initial,
                fa_x_metadata,
                fa_y_metadata
            );
        assert!(fungible_asset::amount(&btc_earned_initial) == 12122881474, 30);
        assert!(fungible_asset::amount(&usdt_earned_initial) == 2310525812746, 31);

        emergency::resume(&emergency_acc);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 73, 32);
        assert!(y_res == 13809, 33);

        let (x_cum_price, y_cum_price, ts) =
            liquidity_pool::get_cumulative_prices<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_cum_price == 43806601518678425423523600, 34);
        assert!(y_cum_price == 936852159292991150400, 35);
        assert!(ts == 1660556365, 36);

        fungible_asset::destroy_zero(btc_zero);
        fungible_asset::destroy_zero(usdt_zero);
        test_fas::burn_fa(&fa_admin, b"BTC", btc_fa);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
        test_fas::burn_fa(&fa_admin, b"BTC", btc_earned_user);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_earned_user);
        test_fas::burn_fa(&fa_admin, b"BTC", btc_earned_initial);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_earned_initial);
    }

    // Compute LP
    #[test]
    fun test_compute_lp_uncorrelated() {
        let x_res = 100;
        let y_res = 100;
        let x_res_new = 101 * 10000;
        let y_res_new = 101 * 10000;

        liquidity_pool::compute_and_verify_lp_value_for_test<Uncorrelated>(
            0,
            0,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );

        let x_res = 18446744073709551615;
        let y_res = 18446744073709551515;
        let x_res_new = 18446744073709551615 * 10000;
        let y_res_new = 18446744073709551615 * 10000;

        liquidity_pool::compute_and_verify_lp_value_for_test<Uncorrelated>(
            0,
            0,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );

        let x_res = 18446744073709551115;
        let y_res = 18446744073709551115;
        let x_res_new = 18446744073709551615 * 10000;
        let y_res_new = 18446744073709551615 * 10000;

        liquidity_pool::compute_and_verify_lp_value_for_test<Uncorrelated>(
            10000,
            10000,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_compute_lp_uncorrelated_fails_equal() {
        let x_res = 0;
        let y_res = 0;
        let x_res_new = 0;
        let y_res_new = 0;

        liquidity_pool::compute_and_verify_lp_value_for_test<Uncorrelated>(
            0,
            0,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_compute_lp_uncorrelated_fails_equal_1() {
        let x_res = 18446744073709551615;
        let y_res = 18446744073709551615;
        let x_res_new = 18446744073709551615 * 10000;
        let y_res_new = 18446744073709551615 * 10000;

        liquidity_pool::compute_and_verify_lp_value_for_test<Uncorrelated>(
            0,
            0,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_compute_lp_uncorrelated_fails_equal_2() {
        let x_res = 18446744073709551615;
        let y_res = 1;
        let x_res_new = 1 * 10000;
        let y_res_new = 18446744073709551615 * 10000;

        liquidity_pool::compute_and_verify_lp_value_for_test<Uncorrelated>(
            0,
            0,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_compute_lp_uncorrelated_fails_less() {
        let x_res = 100;
        let y_res = 99;
        let x_res_new = 100 * 10000;
        let y_res_new = 99 * 10000;

        liquidity_pool::compute_and_verify_lp_value_for_test<Uncorrelated>(
            0,
            0,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_compute_lp_uncorrelated_fails_less_1() {
        let x_res = 18446744073709551615;
        let y_res = 10;
        let x_res_new = 18446744073709551613 * 10000;
        let y_res_new = 10 * 10000;

        liquidity_pool::compute_and_verify_lp_value_for_test<Uncorrelated>(
            0,
            0,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );
    }

    #[test]
    fun test_compute_lp_stable() {
        let x_res = 10000;
        let y_res = 100;
        let x_res_new = 9999;
        let y_res_new = 101;

        liquidity_pool::compute_and_verify_lp_value_for_test<Stable>(
            100,
            10,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );

        let x_res = 10000;
        let y_res = 100;
        let x_res_new = 10001;
        let y_res_new = 100;

        liquidity_pool::compute_and_verify_lp_value_for_test<Stable>(
            100,
            10,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );

        let x_res = 1000000001;
        let y_res = 100;
        let x_res_new = 1000000001;
        let y_res_new = 101;

        liquidity_pool::compute_and_verify_lp_value_for_test<Stable>(
            1000000000,
            10,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );

        let x_res = 100000000000000000;
        let y_res = 100000000000000000;
        let x_res_new = 100000000000000001;
        let y_res_new = 100000000000000001;

        liquidity_pool::compute_and_verify_lp_value_for_test<Stable>(
            100000000,
            100000000,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_compute_lp_stable_less_fails() {
        let x_res = 10000;
        let y_res = 100;
        let x_res_new = 10001;
        let y_res_new = 99;

        liquidity_pool::compute_and_verify_lp_value_for_test<Stable>(
            10000,
            100,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_compute_lp_stable_less_fails_1() {
        let x_res = 10000;
        let y_res = 10;
        let x_res_new = 10001;
        let y_res_new = 9;

        liquidity_pool::compute_and_verify_lp_value_for_test<Stable>(
            10000,
            10,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_compute_lp_stable_equal_fails() {
        let x_res = 1000000001;
        let y_res = 100;
        let x_res_new = 1000000009;
        let y_res_new = 100;

        liquidity_pool::compute_and_verify_lp_value_for_test<Stable>(
            1000000000,
            10,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    fun test_compute_lp_stable_equal_fails_1() {
        let x_res = 0;
        let y_res = 0;
        let x_res_new = 0;
        let y_res_new = 0;

        liquidity_pool::compute_and_verify_lp_value_for_test<Stable>(
            1000000000,
            10,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        );
    }

    // Update cumulative price itself.
    #[test]
    fun test_cumulative_price_0() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        timestamp::fast_forward_seconds(1660545565);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_cum_price, y_cum_price, ts) = liquidity_pool::update_cumulative_price_for_test(
            &lp_owner,
            1660545565 - 3600,
            18446744073709551615,
            18446744073709551615,
            8500000000000000,
            126000000000000,
            fa_x_metadata,
            fa_y_metadata
        );

        assert!(ts == 1660545565, 0);
        assert!(x_cum_price == 1002851816054256914415, 1);
        assert!(y_cum_price == 4479942007502107673191215, 2);
    }

    #[test]
    fun test_cumulative_price_1() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        timestamp::fast_forward_seconds(1660545565);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_cum_price, y_cum_price, ts) = liquidity_pool::update_cumulative_price_for_test(
            &lp_owner,
            1660545565 - 3600,
            0,
            0,
            1123123,
            255666393,
            fa_x_metadata,
            fa_y_metadata,
        );

        assert!(ts == 1660545565, 0);
        assert!(x_cum_price == 15117102108771710567580000, 1);
        assert!(y_cum_price == 291726512367500775600, 2);
    }

    #[test]
    fun test_cumulative_price_2() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        timestamp::fast_forward_seconds(1660545565);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_cum_price, y_cum_price, ts) = liquidity_pool::update_cumulative_price_for_test(
            &lp_owner,
            0,
            10,
            10,
            583,
            984,
            fa_x_metadata,
            fa_y_metadata,
        );

        assert!(ts == 1660545565, 0);
        assert!(x_cum_price == 51700776184088875072100447870 + 10, 1);
        assert!(y_cum_price == 18148635398524546874446331270 + 10, 2);
    }

    #[test]
    fun test_cumulative_price_3() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        timestamp::fast_forward_seconds(3600);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_cum_price, y_cum_price, ts) = liquidity_pool::update_cumulative_price_for_test(
            &lp_owner,
            0,
            0,
            0,
            0,
            0,
            fa_x_metadata,
            fa_y_metadata,
        );

        assert!(ts == 3600, 0);
        assert!(x_cum_price == 0, 1);
        assert!(y_cum_price == 0, 2);
    }

    #[test]
    fun test_cumulative_price_max_time() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        timestamp::update_global_time_for_test(18446744073709551615);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_cum_price, y_cum_price, ts) = liquidity_pool::update_cumulative_price_for_test(
            &lp_owner,
            0,
            18446744073709551615,
            18446744073709551615,
            18446744073709551615,
            18446744073709551615,
            fa_x_metadata,
            fa_y_metadata,
        );

        assert!(ts == 18446744073709, 0);
        assert!(x_cum_price == 340282366920946734669822609541650, 1);
        assert!(y_cum_price == 340282366920946734669822609541650, 2);
    }

    #[test]
    fun test_cumulative_price_overflow_0() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        timestamp::fast_forward_seconds(1);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_cum_price, y_cum_price, ts) = liquidity_pool::update_cumulative_price_for_test(
            &lp_owner,
            0,
            340282366920938463463374607431768211455,
            340282366920938463463374607431768211455,
            18446744073709551615,
            18446744073709551615,
            fa_x_metadata,
            fa_y_metadata,
        );

        assert!(ts == 1, 0);
        assert!(x_cum_price == 18446744073709551614, 1);
        assert!(y_cum_price == 18446744073709551614, 2);
    }

    #[test]
    fun test_cumulative_price_overflow_1() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        timestamp::update_global_time_for_test(18446744073709551615);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_cum_price, y_cum_price, ts) = liquidity_pool::update_cumulative_price_for_test(
            &lp_owner,
            0,
            340282366920938463463374607431768211455,
            340282366920938463463374607431768211455,
            18446744073709551615,
            18446744073709551615,
            fa_x_metadata,
            fa_y_metadata,
        );

        assert!(ts == 18446744073709, 0);
        assert!(x_cum_price == 340282366920928287925748899990034, 1);
        assert!(y_cum_price == 340282366920928287925748899990034, 2);
    }

    struct InvalidCurve {}

    #[test]
    #[expected_failure(abort_code = curves::ERR_INVALID_CURVE)]
    fun test_fail_if_invalid_curve_is_passed() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<InvalidCurve>(&lp_owner, fa_x_metadata, fa_y_metadata);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE)]
    fun test_cannot_initialize_pool_with_non_admin_account() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        liquidity_pool::initialize(&lp_owner);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_PAIR_ORDERING)]
    fun test_get_fee_fail_if_pair_is_not_sorted() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);
        let _ = liquidity_pool::get_fee<Uncorrelated>(fa_y_metadata, fa_x_metadata);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_POOL_DOES_NOT_EXIST)]
    fun test_get_fee_fail_if_pool_does_not_exists() {
        let _ = test_fas::create_admin_with_fas();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let _ = liquidity_pool::get_fee<Uncorrelated>(fa_x_metadata, fa_y_metadata);
    }

    #[test(fee_admin = @fee_admin)]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_PAIR_ORDERING)]
    fun test_set_fee_fail_if_pair_is_not_sorted(fee_admin: signer) {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);
        liquidity_pool::set_fee<Uncorrelated>(&fee_admin, 10, fa_y_metadata, fa_x_metadata);
    }

    #[test(fee_admin = @fee_admin)]
    #[expected_failure(abort_code = liquidity_pool::ERR_POOL_DOES_NOT_EXIST)]
    fun test_set_fee_fail_if_pool_does_not_exists(fee_admin: signer) {
        let _ = test_fas::create_admin_with_fas();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::set_fee<Uncorrelated>(&fee_admin, 10, fa_x_metadata, fa_y_metadata);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_NOT_ADMIN)]
    fun test_set_fee_fail_if_user_is_not_admin() {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);
        liquidity_pool::set_fee<Uncorrelated>(&fa_admin, 10, fa_x_metadata, fa_y_metadata);
    }

    #[test(fee_admin = @fee_admin)]
    #[expected_failure(abort_code = global_config::ERR_INVALID_FEE)]
    fun test_set_fee_fail_if_invalid_amount_of_fee(fee_admin: signer) {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);
        liquidity_pool::set_fee<Uncorrelated>(&fee_admin, 0, fa_x_metadata, fa_y_metadata);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_PAIR_ORDERING)]
    fun test_get_dao_fee_fail_if_pair_is_not_sorted() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);
        let _ = liquidity_pool::get_dao_fee<Uncorrelated>(fa_y_metadata, fa_x_metadata);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_POOL_DOES_NOT_EXIST)]
    fun test_get_dao_fee_fail_if_pool_does_not_exists() {
        let _ = test_fas::create_admin_with_fas();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let _ = liquidity_pool::get_dao_fee<Uncorrelated>(fa_x_metadata, fa_y_metadata);
    }

    #[test(dao_admin = @dao_admin)]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_PAIR_ORDERING)]
    fun test_set_dao_fee_fail_if_pair_is_not_sorted(dao_admin: signer) {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);
        liquidity_pool::set_dao_fee<Uncorrelated>(
            &dao_admin,
            10,
            fa_y_metadata,
            fa_x_metadata,
        );
    }

    #[test(dao_admin = @dao_admin)]
    #[expected_failure(abort_code = liquidity_pool::ERR_POOL_DOES_NOT_EXIST)]
    fun test_set_dao_fee_fail_if_pool_does_not_exists(dao_admin: signer) {
        let _ = test_fas::create_admin_with_fas();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::set_dao_fee<Uncorrelated>(
            &dao_admin,
            10,
            fa_x_metadata,
            fa_y_metadata
        );
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_NOT_ADMIN)]
    fun test_set_dao_fee_fail_if_user_is_not_admin() {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);
        liquidity_pool::set_dao_fee<Uncorrelated>(
            &fa_admin,
            10,
            fa_x_metadata,
            fa_y_metadata
        );
    }

    #[test(fee_admin = @fee_admin)]
    #[expected_failure(abort_code = global_config::ERR_INVALID_FEE)]
    fun test_set_dao_fee_fail_if_invalid_amount_of_fee(fee_admin: signer) {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);
        liquidity_pool::set_dao_fee<Uncorrelated>(&fee_admin, 101, fa_x_metadata, fa_y_metadata);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_PAIR_ORDERING)]
    fun test_cannot_fetch_fees_config_with_unsorted_generics() {
        let (_, _) = setup_btc_usdt_pool();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (_, _) = liquidity_pool::get_fees_config<Uncorrelated>(fa_y_metadata, fa_x_metadata);
    }

    #[test(fee_admin = @fee_admin, dao_admin = @dao_admin)]
    fun test_get_fee_config(fee_admin: signer, dao_admin: signer) {
        let (_, _) = setup_btc_usdt_pool();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (fee, d) =
            liquidity_pool::get_fees_config<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 30, 1);
        assert!(d == 10000, 2);

        let fee = liquidity_pool::get_fee<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 30, 3);

        liquidity_pool::set_fee<Uncorrelated>(&fee_admin, 32, fa_x_metadata, fa_y_metadata);

        let (fee, d) =
            liquidity_pool::get_fees_config<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 32, 4);
        assert!(d == 10000, 5);

        let fee = liquidity_pool::get_fee<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 32, 6);

        // Change fee admin to dao admin
        global_config::set_fee_admin(&fee_admin, signer::address_of(&dao_admin));

        liquidity_pool::set_fee<Uncorrelated>(&dao_admin, 30, fa_x_metadata, fa_y_metadata);

        let (fee, d) =
            liquidity_pool::get_fees_config<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 30, 7);
        assert!(d == 10000, 8);

        let fee = liquidity_pool::get_fee<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 30, 9);
    }

    #[test(fee_admin = @fee_admin, dao_admin = @dao_admin)]
    fun test_get_stable_fee_config(fee_admin: signer, dao_admin: signer) {
        let (_, _) = setup_usdc_usdt_pool();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (fee, d) = liquidity_pool::get_fees_config<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 4, 1);
        assert!(d == 10000, 2);

        let fee = liquidity_pool::get_fee<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 4, 3);

        liquidity_pool::set_fee<Stable>(&fee_admin, 5, fa_x_metadata, fa_y_metadata);

        let (fee, d) = liquidity_pool::get_fees_config<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 5, 4);
        assert!(d == 10000, 5);

        let fee = liquidity_pool::get_fee<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 5, 6);

        // Change fee admin to dao admin
        global_config::set_fee_admin(&fee_admin, signer::address_of(&dao_admin));

        liquidity_pool::set_fee<Stable>(&dao_admin, 6, fa_x_metadata, fa_y_metadata);

        let (fee, d) = liquidity_pool::get_fees_config<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 6, 7);
        assert!(d == 10000, 8);

        let fee = liquidity_pool::get_fee<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 6, 9);
    }

    #[test(fee_admin = @fee_admin, dao_admin = @dao_admin)]
    fun test_dao_fee_config(fee_admin: signer, dao_admin: signer) {
        let (_, _) = setup_btc_usdt_pool();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let fee = liquidity_pool::get_dao_fee<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 33, 1);

        liquidity_pool::set_dao_fee<Uncorrelated>(&fee_admin, 35, fa_x_metadata, fa_y_metadata);

        let fee = liquidity_pool::get_dao_fee<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 35, 2);

        // Change fee admin to dao admin
        global_config::set_fee_admin(&fee_admin, signer::address_of(&dao_admin));

        liquidity_pool::set_dao_fee<Uncorrelated>(
            &dao_admin,
            30,
            fa_x_metadata,
            fa_y_metadata
        );

        let fee = liquidity_pool::get_dao_fee<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 30, 3);
    }

    #[test(fee_admin = @fee_admin, dao_admin = @dao_admin)]
    fun test_get_dao_fees_config(fee_admin: signer, dao_admin: signer) {
        let (_, _) = setup_btc_usdt_pool();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (fee, d) =
            liquidity_pool::get_dao_fees_config<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 33, 1);
        assert!(d == 100, 2);

        // Change fee admin to dao admin
        global_config::set_fee_admin(&fee_admin, signer::address_of(&dao_admin));
        liquidity_pool::set_dao_fee<Uncorrelated>(
            &dao_admin,
            30,
            fa_x_metadata,
            fa_y_metadata
        );

        let (fee, d) =
            liquidity_pool::get_dao_fees_config<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 30, 3);
        assert!(d == 100, 4);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_POOL_DOES_NOT_EXIST)]
    fun test_get_dao_fees_config_fail_doesnt_exists() {
        let _ = test_fas::create_admin_with_fas();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (_, _) =
            liquidity_pool::get_dao_fees_config<Uncorrelated>(fa_x_metadata, fa_y_metadata);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_PAIR_ORDERING)]
    fun test_get_dao_fees_config_fails_wrong_ordering() {
        let (_, _) = setup_btc_usdt_pool();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (_fee, _d) = liquidity_pool::get_dao_fees_config<Uncorrelated>(fa_y_metadata, fa_x_metadata);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_WRONG_PAIR_ORDERING)]
    fun test_get_fees_config_fails_wrong_ordering() {
        let (_, _) = setup_btc_usdt_pool();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (_fee, _d) = liquidity_pool::get_dao_fees_config<Uncorrelated>(fa_y_metadata, fa_x_metadata);
    }

    #[test(fee_admin = @fee_admin)]
    fun test_pool_with_custom_default_fee(fee_admin: signer) {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        global_config::set_default_fee<Uncorrelated>(&fee_admin, 33);
        global_config::set_default_dao_fee(&fee_admin, 66);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);

        let (fee, _) = liquidity_pool::get_fees_config<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 33, 1);
        let fee = liquidity_pool::get_fee<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 33, 1);

        let dao_fee = liquidity_pool::get_dao_fee<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(dao_fee == 66, 1);
    }

    #[test(fee_admin = @fee_admin)]
    fun test_stable_pool_with_custom_default_fee(fee_admin: signer) {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        global_config::set_default_fee<Stable>(&fee_admin, 6);
        global_config::set_default_dao_fee(&fee_admin, 66);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Stable>(&lp_owner, fa_x_metadata, fa_y_metadata);

        let (fee, _) = liquidity_pool::get_fees_config<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 6, 1);
        let fee = liquidity_pool::get_fee<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(fee == 6, 1);

        let dao_fee = liquidity_pool::get_dao_fee<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(dao_fee == 66, 1);
    }

    #[test(fee_admin = @fee_admin)]
    fun test_swap_coins_with_min_fees(fee_admin: signer) {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        global_config::set_default_fee<Uncorrelated>(&fee_admin, 1);
        global_config::set_default_dao_fee(&fee_admin, 0);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 100000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 28000000000);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let btc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 100000);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 27969233
            );
        assert!(fungible_asset::amount(&usdt_fa) == 27969233, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 100100000, 1);
        assert!(y_res == 27972030767, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test(fee_admin = @fee_admin)]
    fun test_swap_coins_with_max_fees(fee_admin: signer) {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        global_config::set_default_fee<Uncorrelated>(&fee_admin, 35);
        global_config::set_default_dao_fee(&fee_admin, 100);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);

        let btc_fa = test_fas::mint_fa(&fa_admin, b"BTC", 100000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 28000000000);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_fa, usdt_fa);

        let btc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"BTC", 100000);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Uncorrelated>(
                btc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 27874223
            );
        assert!(fungible_asset::amount(&usdt_fa) == 27874223, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 100099650, 1);
        assert!(y_res == 27972125777, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test(fee_admin = @fee_admin)]
    fun test_swap_coins_with_min_fees_for_stable_curve(fee_admin: signer) {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        global_config::set_default_fee<Stable>(&fee_admin, 1);
        global_config::set_default_dao_fee(&fee_admin, 0);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Stable>(&lp_owner, fa_x_metadata, fa_y_metadata);

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 100000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 10000000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let usdc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDC", 100000);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Stable>(
                usdc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 9998999
            );
        assert!(fungible_asset::amount(&usdt_fa) == 9998999, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 100100000, 1);
        assert!(y_res == 9990001001, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test(fee_admin = @fee_admin)]
    fun test_swap_coins_with_max_fees_for_stable_curve(fee_admin: signer) {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        global_config::set_default_fee<Stable>(&fee_admin, 35);
        global_config::set_default_dao_fee(&fee_admin, 100);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        liquidity_pool::register<Stable>(&lp_owner, fa_x_metadata, fa_y_metadata);

        let usdc_fa = test_fas::mint_fa(&fa_admin, b"USDC", 100000000);
        let usdt_fa = test_fas::mint_fa(&fa_admin, b"USDT", 10000000000);

        test_pool::mint_liquidity<Stable>(&lp_owner, usdc_fa, usdt_fa);

        let usdc_fa_to_exchange = test_fas::mint_fa(&fa_admin, b"USDC", 100000);
        let (zero, usdt_fa) =
            liquidity_pool::swap<Stable>(
                usdc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 9964999
            );
        assert!(fungible_asset::amount(&usdt_fa) == 9964999, 0);

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 100099650, 1);
        assert!(y_res == 9990035001, 2);

        fungible_asset::destroy_zero(zero);
        test_fas::burn_fa(&fa_admin, b"USDT", usdt_fa);
    }

    #[test]
    fun test_reserved_liquidity() {
        let (fa_admin, lp_owner) = setup_btc_usdt_pool();

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let btc_liq_val = 100000000;
        let usdt_liq_val = 28000000000;
        let btc_liq = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val);
        let usdt_liq = test_fas::mint_fa(&fa_admin, b"USDT", usdt_liq_val);

        timestamp::fast_forward_seconds(1660338836);

        let lp_fa_val =
            test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_liq, usdt_liq);

        let expected_liquidity = 1673320053;
        assert!(lp_fa_val == expected_liquidity - MINIMAL_LIQUIDITY, 0);
        assert!(liquidity_pool::get_pool_lp_supply<Uncorrelated>(fa_x_metadata, fa_y_metadata) ==
            (expected_liquidity as u128), 1);

        let lp_metadata = get_lp_fa_metadata_from_x_y_metadatas<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let lp_fa = primary_fungible_store::withdraw(&lp_owner, lp_metadata, lp_fa_val);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (x_fa, y_fa) =
            liquidity_pool::burn<Uncorrelated>(lp_fa, fa_x_metadata, fa_y_metadata);

        let lp_owner_addr = signer::address_of(&lp_owner);

        primary_fungible_store::deposit(lp_owner_addr, x_fa);
        primary_fungible_store::deposit(lp_owner_addr, y_fa);

        assert!(liquidity_pool::get_pool_lp_supply<Uncorrelated>(fa_x_metadata, fa_y_metadata) ==
            (MINIMAL_LIQUIDITY as u128), 2);
        assert!(liquidity_pool::get_reserved_value<Uncorrelated>(fa_x_metadata, fa_y_metadata) ==
            MINIMAL_LIQUIDITY, 3);

        let btc_liq_val = 100000000;
        let usdt_liq_val = 28000000000;
        let btc_liq = test_fas::mint_fa(&fa_admin, b"BTC", btc_liq_val);
        let usdt_liq = test_fas::mint_fa(&fa_admin, b"USDT", usdt_liq_val);

        test_pool::mint_liquidity<Uncorrelated>(&lp_owner, btc_liq, usdt_liq);
        assert!(liquidity_pool::get_reserved_value<Uncorrelated>(fa_x_metadata, fa_y_metadata) ==
            MINIMAL_LIQUIDITY, 4);

        let expected_liquidity = 1673319053;
        assert!(lp_fa_val == expected_liquidity, 5);
    }
}
