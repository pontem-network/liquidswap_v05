#[test_only]
module liquidswap_v05::scripts_tests {
    use std::signer;

    use aptos_framework::primary_fungible_store;

    use liquidswap_v05::curves::Uncorrelated;
    use liquidswap_v05::liquidity_pool;
    use liquidswap_v05::router;
    use liquidswap_v05::scripts;
    use test_coin_admin::test_coins::{Self, USDT, BTC};
    use test_helpers::test_pool;

    fun register_pool_with_existing_liquidity(x_val: u64, y_val: u64): (signer, signer) {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        router::register_pool<BTC, USDT, Uncorrelated>(
            &lp_owner,
            fa_x_metadata,
            fa_y_metadata,
        );

        if (x_val != 0 && y_val != 0) {
            let btc_fa = test_coins::mint_fa(&fa_admin, b"BTC", x_val);
            let usdt_fa = test_coins::mint_fa(&fa_admin, b"USDT", y_val);
            let lp_fa =
                liquidity_pool::mint<BTC, USDT, Uncorrelated>(btc_fa, usdt_fa);
            primary_fungible_store::deposit(signer::address_of(&lp_owner), lp_fa);
        };
        (fa_admin, lp_owner)
    }

    #[test]
    public entry fun test_register_pool_with_script() {
        let (_, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        scripts::register_pool<BTC, USDT, Uncorrelated>(&lp_owner, fa_x_metadata, fa_y_metadata);

        assert!(liquidity_pool::is_pool_exists<BTC, USDT, Uncorrelated>(fa_x_metadata, fa_y_metadata), 1);
    }

    #[test]
    public entry fun test_register_and_add_liquidity_in_one_script() {
        let (fa_admin, lp_owner) = test_pool::setup_fa_and_lp_owner();

        let btc_fa = test_coins::mint_fa(&fa_admin, b"BTC", 101);
        let usdt_fa = test_coins::mint_fa(&fa_admin, b"USDT", 10100);

        let lp_owner_addr = signer::address_of(&lp_owner);
        primary_fungible_store::deposit(lp_owner_addr, btc_fa);
        primary_fungible_store::deposit(lp_owner_addr, usdt_fa);

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        scripts::register_pool_and_add_liquidity<BTC, USDT, Uncorrelated>(
            &lp_owner,
            101,
            101,
            10100,
            10100,
            fa_x_metadata,
            fa_y_metadata,
        );

        assert!(liquidity_pool::is_pool_exists<BTC, USDT, Uncorrelated>(fa_x_metadata, fa_y_metadata), 1);

        let lp_metadata =
            liquidity_pool::get_pool_lp_metadata<BTC, USDT, Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(primary_fungible_store::balance(lp_owner_addr, fa_x_metadata) == 0, 2);
        assert!(primary_fungible_store::balance(lp_owner_addr, fa_y_metadata) == 0, 3);
        assert!(primary_fungible_store::balance(lp_owner_addr, lp_metadata) == 10, 4);
    }

    #[test]
    public entry fun test_add_liquidity() {
        let (fa_admin, lp_owner) = register_pool_with_existing_liquidity(0, 0);

        let btc_fa = test_coins::mint_fa(&fa_admin, b"BTC", 101);
        let usdt_fa = test_coins::mint_fa(&fa_admin, b"USDT", 10100);

        let lp_owner_addr = signer::address_of(&lp_owner);
        primary_fungible_store::deposit(lp_owner_addr, btc_fa);
        primary_fungible_store::deposit(lp_owner_addr, usdt_fa);

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        scripts::add_liquidity<BTC, USDT, Uncorrelated>(
            &lp_owner,
            101,
            101,
            10100,
            10100,
            fa_x_metadata,
            fa_y_metadata,
        );

        let lp_metadata =
            liquidity_pool::get_pool_lp_metadata<BTC, USDT, Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(primary_fungible_store::balance(lp_owner_addr, fa_x_metadata) == 0, 1);
        assert!(primary_fungible_store::balance(lp_owner_addr, fa_y_metadata) == 0, 2);
        assert!(primary_fungible_store::balance(lp_owner_addr, lp_metadata) == 10, 3);
    }

    #[test]
    public entry fun test_remove_liquidity() {
        let (fa_admin, lp_owner) = register_pool_with_existing_liquidity(0, 0);

        let btc_fa = test_coins::mint_fa(&fa_admin, b"BTC", 101);
        let usdt_fa = test_coins::mint_fa(&fa_admin, b"USDT", 10100);

        let (btc, usdt, lp) =
            router::add_liquidity<BTC, USDT, Uncorrelated>(
                btc_fa,
                101,
                usdt_fa,
                10100,
            );

        let lp_owner_addr = signer::address_of(&lp_owner);
        primary_fungible_store::deposit(lp_owner_addr, btc);
        primary_fungible_store::deposit(lp_owner_addr, usdt);
        primary_fungible_store::deposit(lp_owner_addr, lp);

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        scripts::remove_liquidity<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            1,
            100,
            fa_x_metadata,
            fa_y_metadata,
        );

        let lp_metadata =
            liquidity_pool::get_pool_lp_metadata<BTC, USDT, Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(primary_fungible_store::balance(lp_owner_addr, lp_metadata) == 0, 1);
        assert!(primary_fungible_store::balance(lp_owner_addr, fa_x_metadata) == 1, 2);
        assert!(primary_fungible_store::balance(lp_owner_addr, fa_y_metadata) == 100, 3);
    }

    #[test]
    public entry fun test_swap_exact_btc_for_usdt() {
        let (fa_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_fa_to_swap = test_coins::mint_fa(&fa_admin, b"BTC", 10);

        let lp_owner_addr = signer::address_of(&lp_owner);
        primary_fungible_store::deposit(lp_owner_addr, btc_fa_to_swap);

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        scripts::swap<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            900,
            fa_x_metadata,
            fa_y_metadata,
        );

        assert!(primary_fungible_store::balance(lp_owner_addr, fa_x_metadata) == 0, 1);
        assert!(primary_fungible_store::balance(lp_owner_addr, fa_y_metadata) == 907, 2);
    }

    #[test]
    public entry fun test_swap_btc_for_exact_usdt() {
        let (fa_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_fa_to_swap = test_coins::mint_fa(&fa_admin, b"BTC", 10);

        let lp_owner_addr = signer::address_of(&lp_owner);
        primary_fungible_store::deposit(lp_owner_addr, btc_fa_to_swap);

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        scripts::swap_into<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            700,
            fa_x_metadata,
            fa_y_metadata,
        );

        assert!(primary_fungible_store::balance(lp_owner_addr, fa_x_metadata) == 2, 1);
        assert!(primary_fungible_store::balance(lp_owner_addr, fa_y_metadata) == 700, 2);
    }

    #[test]
    public entry fun test_unchecked_swap_common() {
        let (fa_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_fa_to_swap = test_coins::mint_fa(&fa_admin, b"BTC", 10);

        let lp_owner_addr = signer::address_of(&lp_owner);
        primary_fungible_store::deposit(lp_owner_addr, btc_fa_to_swap);

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        scripts::swap_unchecked<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            907,
            fa_x_metadata,
            fa_y_metadata,
        );

        assert!(primary_fungible_store::balance(lp_owner_addr, fa_x_metadata) == 0, 1);
        assert!(primary_fungible_store::balance(lp_owner_addr, fa_y_metadata) == 907, 2);

    }

    #[test]
    public entry fun test_unchecked_swap_can_use_worse_price() {
        let (fa_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_fa_to_swap = test_coins::mint_fa(&fa_admin, b"BTC", 10);

        let lp_owner_addr = signer::address_of(&lp_owner);
        primary_fungible_store::deposit(lp_owner_addr, btc_fa_to_swap);

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        scripts::swap_unchecked<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            700,
            fa_x_metadata,
            fa_y_metadata,
        );

        assert!(primary_fungible_store::balance(lp_owner_addr, fa_x_metadata) == 0, 1);
        assert!(primary_fungible_store::balance(lp_owner_addr, fa_y_metadata) == 700, 2);

    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    public entry fun test_unchecked_swap_fails_if_price_better_than_available_requested() {
        let (fa_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_fa_to_swap = test_coins::mint_fa(&fa_admin, b"BTC", 10);

        let lp_owner_addr = signer::address_of(&lp_owner);
        primary_fungible_store::deposit(lp_owner_addr, btc_fa_to_swap);

        let fa_x_metadata = test_coins::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_coins::get_fa_metadata_from_symbol(b"USDT");

        scripts::swap_unchecked<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            1100,
            fa_x_metadata,
            fa_y_metadata,
        );
    }
}
