#[test_only]
module liquidswap_v05::dao_storage_tests {
    use std::signer;
    use std::string;
    use aptos_framework::account;

    use aptos_framework::coin;
    use aptos_framework::fungible_asset;
    use aptos_framework::object;
    use aptos_framework::primary_fungible_store;
    use liquidswap_lp::lp_coin::LP;

    use liquidswap_v05::curves::Uncorrelated;
    use liquidswap_v05::dao_storage::{Self, FungibleStoreSigner};
    use liquidswap_v05::liquidity_pool;
    use liquidswap_v05::router;
    use test_coin_admin::test_coins::{Self, BTC, USDT};
    use test_helpers::test_account::create_account;
    use test_helpers::test_pool;
    use liquidswap_v05::global_config;

    #[test]
    fun test_register() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        dao_storage::register_for_test<Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);

        let (x_val, y_val) =
            dao_storage::get_storage_size<Uncorrelated>(
                fa_x_metadata,
                fa_y_metadata,
            );
        assert!(x_val == 0, 1);
        assert!(y_val == 0, 2);

        // Check FA storages signer store object.
        let obj_creator_addr =
            account::create_resource_address(&@liquidswap_v05, b"dao_fa_store_sig_cap_seed");
        let storage_seed =
            *string::bytes(&dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata));
        let obj_addr = object::create_object_address(&obj_creator_addr, storage_seed);
        assert!(object::object_exists<FungibleStoreSigner>(obj_addr), 3);
        assert!(object::is_untransferable(object::address_to_object<FungibleStoreSigner>(obj_addr)), 4);

        // Check DAO FA stores directly.
        let storage_seed =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let fa_res_acc_addr =
            account::create_resource_address(&obj_creator_addr, *string::bytes(&storage_seed));
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr, fa_x_metadata), 5);
        assert!(primary_fungible_store::primary_store_exists(fa_res_acc_addr, fa_y_metadata), 6);
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_x_metadata) == 0, 7);
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_y_metadata) == 0, 8);
    }

    #[test]
    fun test_deposit() {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        dao_storage::register_for_test<Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata,
        );

        let lp_owner_addr = signer::address_of(&lp_owner);
        let btc_fa = test_coins::mint_fa(&fa_admin, b"BTC", 100000000);
        let usdt_fa = test_coins::mint_fa(&fa_admin, b"USDT", 1000000);

        let (x_val, y_val) =
            dao_storage::get_storage_size<Uncorrelated>(
                fa_x_metadata,
                fa_y_metadata,
            );
        assert!(x_val == 0, 1);
        assert!(y_val == 0, 2);

        dao_storage::deposit_for_test<Uncorrelated>(lp_owner_addr, btc_fa, usdt_fa);
        (x_val, y_val) =
            dao_storage::get_storage_size<Uncorrelated>(
                fa_x_metadata,
                fa_y_metadata,
            );
        assert!(x_val == 100000000, 3);
        assert!(y_val == 1000000, 4);

        // Check DAO FA stores directly.
        let obj_creator_addr =
            account::create_resource_address(&@liquidswap_v05, b"dao_fa_store_sig_cap_seed");
        let storage_seed =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let fa_res_acc_addr =
            account::create_resource_address(&obj_creator_addr, *string::bytes(&storage_seed));
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_x_metadata) == 100000000, 5);
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_y_metadata) == 1000000, 6);
    }

    #[test]
    #[expected_failure(abort_code = dao_storage::ERR_NOT_REGISTERED)]
    fun test_deposit_fail_if_not_registered() {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let lp_owner_addr = signer::address_of(&lp_owner);
        let btc_fa = test_coins::mint_fa(&fa_admin, b"BTC", 100000000);
        let usdt_fa = test_coins::mint_fa(&fa_admin, b"USDT", 1000000);

        dao_storage::deposit_for_test<Uncorrelated>(lp_owner_addr, btc_fa, usdt_fa);
    }

    #[test(dao_admin_acc = @dao_admin)]
    fun test_withdraw(dao_admin_acc: signer) {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        dao_storage::register_for_test<Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata,
        );

        create_account(&dao_admin_acc);

        let lp_owner_addr = signer::address_of(&lp_owner);
        let btc_fa = test_coins::mint_fa(&fa_admin, b"BTC", 100000000);
        let usdt_fa = test_coins::mint_fa(&fa_admin, b"USDT", 1000000);

        dao_storage::deposit_for_test<Uncorrelated>(lp_owner_addr, btc_fa, usdt_fa);

        let (x, y) =
            dao_storage::withdraw<Uncorrelated>(
                &dao_admin_acc,
                lp_owner_addr,
                100000000,
                0,
                fa_x_metadata,
                fa_y_metadata,
            );
        assert!(fungible_asset::amount(&x) == 100000000, 1);
        assert!(fungible_asset::amount(&y) == 0, 2);

        let (x_val, y_val) =
            dao_storage::get_storage_size<Uncorrelated>(
                fa_x_metadata,
                fa_y_metadata,
            );
        assert!(x_val == 0, 3);
        assert!(y_val == 1000000, 4);

        // Check DAO FA stores directly.
        let obj_creator_addr =
            account::create_resource_address(&@liquidswap_v05, b"dao_fa_store_sig_cap_seed");
        let storage_seed =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let fa_res_acc_addr =
            account::create_resource_address(&obj_creator_addr, *string::bytes(&storage_seed));
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_x_metadata) == 0, 5);
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_y_metadata) == 1000000, 6);

        global_config::set_dao_admin(&dao_admin_acc, signer::address_of(&fa_admin));
        let (x0, y0) =
            dao_storage::withdraw<Uncorrelated>(
                &fa_admin,
                lp_owner_addr,
                0,
                1000000,
                fa_x_metadata,
                fa_y_metadata,
            );
        assert!(fungible_asset::amount(&x0) == 0, 4);
        assert!(fungible_asset::amount(&y0) == 1000000, 5);

        // Check DAO FA stores directly.
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_x_metadata) == 0, 6);
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_y_metadata) == 0, 7);

        test_coins::burn_fa(&fa_admin, b"BTC", x);
        test_coins::burn_fa(&fa_admin, b"USDT", y);
        test_coins::burn_fa(&fa_admin, b"BTC", x0);
        test_coins::burn_fa(&fa_admin, b"USDT", y0);
    }

    #[test(dao_admin_acc = @dao_admin)]
    #[expected_failure(abort_code = 65540, location = aptos_framework::fungible_asset)]
    fun test_withdraw_fail_if_more_deposited(dao_admin_acc: signer) {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        dao_storage::register_for_test<Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata
        );

        create_account(&dao_admin_acc);

        let lp_owner_addr = signer::address_of(&lp_owner);
        let btc_fa = test_coins::mint_fa(&fa_admin, b"BTC", 100000000);
        let usdt_fa = test_coins::mint_fa(&fa_admin, b"USDT", 1000000);

        dao_storage::deposit_for_test<Uncorrelated>(lp_owner_addr, btc_fa, usdt_fa);

        let (x, y) =
            dao_storage::withdraw<Uncorrelated>(
                &dao_admin_acc,
                lp_owner_addr,
                200000000,
                0,
                fa_x_metadata,
                fa_y_metadata,
            );

        test_coins::burn_fa(&fa_admin, b"BTC", x);
        test_coins::burn_fa(&fa_admin, b"USDT", y);
    }

    #[test(dao_admin_acc = @0xca)]
    #[expected_failure(abort_code = dao_storage::ERR_NOT_ADMIN_ACCOUNT)]
    fun test_withdraw_fail_if_not_dao_admin(dao_admin_acc: signer) {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        dao_storage::register_for_test<Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata,
        );

        create_account(&dao_admin_acc);

        let lp_owner_addr = signer::address_of(&lp_owner);
        let btc_fa = test_coins::mint_fa(&fa_admin, b"BTC", 100000000);
        let usdt_fa = test_coins::mint_fa(&fa_admin, b"USDT", 1000000);

        dao_storage::deposit_for_test<Uncorrelated>(
            lp_owner_addr,
            btc_fa,
            usdt_fa
        );

        let (x, y) =
            dao_storage::withdraw<Uncorrelated>(
                &dao_admin_acc,
                lp_owner_addr,
                100000000,
                0,
                fa_x_metadata,
                fa_y_metadata,
            );

        test_coins::burn_fa(&fa_admin, b"BTC", x);
        test_coins::burn_fa(&fa_admin, b"USDT", y);
    }

    #[test(dao_admin_acc = @dao_admin)]
    fun test_split_third_of_fees_into_dao_storage_account(dao_admin_acc: signer) {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        create_account(&dao_admin_acc);

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        // 0.3% fee
        router::register_pool<BTC, USDT, Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata,
        );

        let btc_fa = test_coins::mint_fa(&fa_admin, b"BTC", 100000);
        let usdt_fa = test_coins::mint_fa(&fa_admin, b"USDT", 100000);

        let lp_coins =
            liquidity_pool::mint<BTC, USDT, Uncorrelated>(btc_fa, usdt_fa);
        coin::register<LP<BTC, USDT, Uncorrelated>>(&lp_owner);
        coin::deposit(signer::address_of(&lp_owner), lp_coins);

        let btc_fa_to_exchange = test_coins::mint_fa(&fa_admin, b"BTC", 1000);
        let (zero, usdt_coins) =
            liquidity_pool::swap<BTC, USDT, Uncorrelated>(
                btc_fa_to_exchange, 0,
                fungible_asset::zero(fa_y_metadata), 960
            );

        let (x_res, y_res) =
            liquidity_pool::get_reserves_size<BTC, USDT, Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(x_res == 100999, 1);
        assert!(y_res == 99040, 2);

        let (dao_x, dao_y) =
            dao_storage::get_storage_size<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(dao_x == 1, 3);
        assert!(dao_y == 0, 4);

        // Check DAO FA stores directly.
        let obj_creator_addr =
            account::create_resource_address(&@liquidswap_v05, b"dao_fa_store_sig_cap_seed");
        let storage_seed =
            dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        let fa_res_acc_addr =
            account::create_resource_address(&obj_creator_addr, *string::bytes(&storage_seed));
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_x_metadata) == 1, 5);
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_y_metadata) == 0, 6);

        let (x, y) =
            dao_storage::withdraw<Uncorrelated>(
                &dao_admin_acc,
                @liquidswap_pool_account,
                1,
                0,
                fa_x_metadata,
                fa_y_metadata,
            );
        assert!(fungible_asset::amount(&x) == 1, 6);
        assert!(fungible_asset::amount(&y) == 0, 7);

        // Check DAO FA stores directly.
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_x_metadata) == 0, 7);
        assert!(primary_fungible_store::balance(fa_res_acc_addr, fa_y_metadata) == 0, 8);

        test_coins::burn_fa(&fa_admin, b"BTC", x);
        test_coins::burn_fa(&fa_admin, b"USDT", y);

        fungible_asset::destroy_zero(zero);
        test_coins::burn_fa(&fa_admin, b"USDT", usdt_coins);
    }

    #[test]
    fun test_create_fa_storage_seed() {
        let _ = test_coins::create_admin_with_fas();

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        let seed = dao_storage::create_fa_storage_seed<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(seed == string::utf8(b"BTC@0xde7426eb496bc9ad39e9840b8dc4012344f45ac420215e8204e7fd2f026b42f5-USDT@0x7a54c5c4b35ae946f10beb158bd575f1700271c5f83a0e4096ee80970cf1bbb9-Uncorrelated{}-DAO-FA-Storage"), 1);
    }
}
