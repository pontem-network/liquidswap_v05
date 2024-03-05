#[test_only]
module liquidswap_v05::scripts_v3_tests {
    use std::option;
    use std::signer;
    use aptos_framework::account;
    use aptos_framework::aptos_account;

    use aptos_framework::coin;

    use liquidswap_v05::curves::Uncorrelated;
    use liquidswap_v05::liquidity_pool;
    use liquidswap_v05::router_v3;
    use liquidswap_v05::scripts_v3;
    use test_coin_admin::test_coins::{Self, USDT, BTC};
    use test_helpers::test_pool;
    use liquidswap_lp::lp_coin::LP;

    fun register_pool_with_existing_liquidity(x_val: u64, y_val: u64): (signer, signer) {
        let (coin_admin, lp_owner) = test_pool::setup_coins_and_lp_owner();

        router_v3::register_pool<BTC, USDT, Uncorrelated>(&lp_owner);

        if (x_val != 0 && y_val != 0) {
            let btc_coins = test_coins::mint<BTC>(&coin_admin, x_val);
            let usdt_coins = test_coins::mint<USDT>(&coin_admin, y_val);
            let lp_coins =
                liquidity_pool::mint<BTC, USDT, Uncorrelated>(btc_coins, usdt_coins);
            coin::register<LP<BTC, USDT, Uncorrelated>>(&lp_owner);
            coin::deposit<LP<BTC, USDT, Uncorrelated>>(signer::address_of(&lp_owner), lp_coins);
        };
        (coin_admin, lp_owner)
    }

    #[test]
    public entry fun test_register_pool_with_script() {
        let (_, lp_owner) = test_pool::setup_coins_and_lp_owner();

        scripts_v3::register_pool<BTC, USDT, Uncorrelated>(&lp_owner);

        assert!(liquidity_pool::is_pool_exists<BTC, USDT, Uncorrelated>(), 1);
    }

    #[test]
    public entry fun test_register_and_add_liquidity_in_one_script() {
        let (coin_admin, lp_owner) = test_pool::setup_coins_and_lp_owner();

        let btc_coins = test_coins::mint<BTC>(&coin_admin, 101);
        let usdt_coins = test_coins::mint<USDT>(&coin_admin, 10100);

        coin::register<BTC>(&lp_owner);
        coin::register<USDT>(&lp_owner);

        let lp_owner_addr = signer::address_of(&lp_owner);
        coin::deposit(lp_owner_addr, btc_coins);
        coin::deposit(lp_owner_addr, usdt_coins);

        scripts_v3::register_pool_and_add_liquidity<BTC, USDT, Uncorrelated>(
            &lp_owner,
            101,
            101,
            10100,
            10100,
        );

        assert!(liquidity_pool::is_pool_exists<BTC, USDT, Uncorrelated>(), 1);

        assert!(coin::balance<BTC>(lp_owner_addr) == 0, 2);
        assert!(coin::balance<USDT>(lp_owner_addr) == 0, 3);
        assert!(coin::balance<LP<BTC, USDT, Uncorrelated>>(lp_owner_addr) == 10, 4);
    }

    #[test]
    public entry fun test_add_liquidity() {
        let (coin_admin, _) = register_pool_with_existing_liquidity(0, 0);
        let lp_account = account::create_account_for_test(@0xabc);

        let btc_coins = test_coins::mint<BTC>(&coin_admin, 101);
        let usdt_coins = test_coins::mint<USDT>(&coin_admin, 10100);

        coin::register<BTC>(&lp_account);
        coin::register<USDT>(&lp_account);

        let lp_account_addr = signer::address_of(&lp_account);
        coin::deposit(lp_account_addr, btc_coins);
        coin::deposit(lp_account_addr, usdt_coins);

        scripts_v3::add_liquidity<BTC, USDT, Uncorrelated>(
            &lp_account,
            101,
            101,
            10100,
            10100,
        );

        assert!(coin::balance<BTC>(lp_account_addr) == 0, 1);
        assert!(coin::balance<USDT>(lp_account_addr) == 0, 2);
        assert!(coin::balance<LP<BTC, USDT, Uncorrelated>>(lp_account_addr) == 10, 3);
    }

    #[test]
    public entry fun test_remove_liquidity() {
        let (coin_admin, lp_owner) = register_pool_with_existing_liquidity(0, 0);

        let btc_coins = test_coins::mint<BTC>(&coin_admin, 101);
        let usdt_coins = test_coins::mint<USDT>(&coin_admin, 10100);

        let (btc, usdt, lp) =
            router_v3::add_liquidity<BTC, USDT, Uncorrelated>(
                btc_coins,
                101,
                usdt_coins,
                10100,
            );

        let lp_owner_addr = signer::address_of(&lp_owner);
        aptos_account::deposit_coins(lp_owner_addr, lp);

        scripts_v3::remove_liquidity<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            98,
            10000,
        );

        coin::deposit(lp_owner_addr, btc);
        coin::deposit(lp_owner_addr, usdt);

        assert!(coin::balance<LP<BTC, USDT, Uncorrelated>>(lp_owner_addr) == 0, 1);
        assert!(coin::balance<BTC>(lp_owner_addr) == 101, 2);
        assert!(coin::balance<USDT>(lp_owner_addr) == 10100, 3);
    }

    #[test]
    public entry fun test_swap_exact_btc_for_usdt() {
        let (coin_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_coins_to_swap = test_coins::mint<BTC>(&coin_admin, 10);
        coin::register<BTC>(&lp_owner);

        let lp_owner_addr = signer::address_of(&lp_owner);
        coin::deposit(lp_owner_addr, btc_coins_to_swap);

        scripts_v3::swap<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            900,
            option::none(),
        );

        assert!(coin::balance<BTC>(lp_owner_addr) == 0, 1);
        assert!(coin::balance<USDT>(lp_owner_addr) == 907, 2);
    }

    #[test]
    public entry fun test_swap_exact_btc_for_usdt_recipient() {
        let (coin_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_coins_to_swap = test_coins::mint<BTC>(&coin_admin, 10);
        coin::register<BTC>(&lp_owner);

        let lp_owner_addr = signer::address_of(&lp_owner);
        coin::deposit(lp_owner_addr, btc_coins_to_swap);

        let recipient_addr = @0xabc;

        scripts_v3::swap<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            900,
            option::some(recipient_addr),
        );

        assert!(coin::balance<BTC>(lp_owner_addr) == 0, 1);
        assert!(coin::balance<USDT>(recipient_addr) == 907, 2);
    }

    #[test]
    public entry fun test_swap_btc_for_exact_usdt_recipient() {
        let (coin_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_coins_to_swap = test_coins::mint<BTC>(&coin_admin, 10);
        coin::register<BTC>(&lp_owner);

        let lp_owner_addr = signer::address_of(&lp_owner);
        coin::deposit(lp_owner_addr, btc_coins_to_swap);

        let recipient_addr = @0xabc;

        scripts_v3::swap_into<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            700,
            option::some(recipient_addr),
        );

        assert!(coin::balance<BTC>(lp_owner_addr) == 2, 1);
        assert!(coin::balance<USDT>(recipient_addr) == 700, 2);
    }

    #[test]
    public entry fun test_unchecked_swap_common() {
        let (coin_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_coins_to_swap = test_coins::mint<BTC>(&coin_admin, 10);
        coin::register<BTC>(&lp_owner);

        let lp_owner_addr = signer::address_of(&lp_owner);
        coin::deposit(lp_owner_addr, btc_coins_to_swap);

        scripts_v3::swap_unchecked<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            907,
            option::none(),
        );

        assert!(coin::balance<BTC>(lp_owner_addr) == 0, 1);
        assert!(coin::balance<USDT>(lp_owner_addr) == 907, 2);
    }

    #[test]
    public entry fun test_unchecked_swap_common_recipient() {
        let (coin_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_coins_to_swap = test_coins::mint<BTC>(&coin_admin, 10);

        let lp_owner_addr = signer::address_of(&lp_owner);
        coin::register<BTC>(&lp_owner);
        coin::deposit(lp_owner_addr, btc_coins_to_swap);

        let recipient_addr = @0xabc;

        scripts_v3::swap_unchecked<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            907,
            option::some(recipient_addr),
        );

        assert!(coin::balance<BTC>(lp_owner_addr) == 0, 1);
        assert!(coin::balance<USDT>(recipient_addr) == 907, 2);
    }

    #[test]
    public entry fun test_unchecked_swap_can_use_worse_price() {
        let (coin_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_coins_to_swap = test_coins::mint<BTC>(&coin_admin, 10);
        coin::register<BTC>(&lp_owner);
        coin::register<USDT>(&lp_owner);

        let lp_owner_addr = signer::address_of(&lp_owner);
        coin::deposit(lp_owner_addr, btc_coins_to_swap);

        scripts_v3::swap_unchecked<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            700,
            option::none(),
        );

        assert!(coin::balance<BTC>(lp_owner_addr) == 0, 1);
        assert!(coin::balance<USDT>(lp_owner_addr) == 700, 2);
    }

    #[test]
    #[expected_failure(abort_code = liquidity_pool::ERR_INCORRECT_SWAP)]
    public entry fun test_unchecked_swap_fails_if_price_better_than_available_requested() {
        let (coin_admin, lp_owner) = register_pool_with_existing_liquidity(101, 10100);

        let btc_coins_to_swap = test_coins::mint<BTC>(&coin_admin, 10);
        coin::register<BTC>(&lp_owner);
        coin::register<USDT>(&lp_owner);

        let lp_owner_addr = signer::address_of(&lp_owner);
        coin::deposit(lp_owner_addr, btc_coins_to_swap);

        scripts_v3::swap_unchecked<BTC, USDT, Uncorrelated>(
            &lp_owner,
            10,
            1100,
            option::none(),
        );
    }
}
