#[test_only]
module liquidswap_v05::compare_tests {
    use std::option;

    use aptos_std::comparator;
    use aptos_framework::account::create_signer_for_test;
    use aptos_framework::aptos_coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;

    use liquidswap_v05::fa_helper;
    use test_fa_admin::test_fas;

    fun create_fake_apt(fa_admin: &signer): Object<Metadata> {
        // Create fake APT FA.
        let (mint_ref, _) = test_fas::register_fa(
            fa_admin,
            b"Aptos Coin",
            b"APT",
            8,
            b"FAKE_APT_FA_OBJ"
        );

        fungible_asset::mint_ref_metadata(&mint_ref)
    }

    #[test]
    fun test_fas_equal() {
        // Create AptosCoin.
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();

        test_fas::create_admin_with_fas();

        let btc_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let usdt_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");
        let usdc_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let apt_metadata = option::extract(&mut coin::paired_metadata<AptosCoin>());

        assert!(comparator::is_equal(&fa_helper::compare_fa(btc_metadata, btc_metadata)), 1);
        assert!(comparator::is_equal(&fa_helper::compare_fa(usdc_metadata, usdc_metadata)), 2);
        assert!(comparator::is_equal(&fa_helper::compare_fa(usdt_metadata, usdt_metadata)), 3);
        assert!(comparator::is_equal(&fa_helper::compare_fa(apt_metadata, apt_metadata)), 4);
    }

    #[test]
    fun test_fas_compared_with_symb_first() {
        // Create AptosCoin.
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();

        test_fas::create_admin_with_fas();

        let btc_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let usdt_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");
        let usdc_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let apt_metadata = option::extract(&mut coin::paired_metadata<AptosCoin>());

        assert!(comparator::is_smaller_than(&fa_helper::compare_fa(btc_metadata, usdc_metadata)), 1);
        assert!(comparator::is_smaller_than(&fa_helper::compare_fa(usdc_metadata, usdt_metadata)), 2);
        assert!(comparator::is_smaller_than(&fa_helper::compare_fa(apt_metadata, btc_metadata)), 3);

        assert!(comparator::is_greater_than(&fa_helper::compare_fa(usdc_metadata, btc_metadata)), 4);
        assert!(comparator::is_greater_than(&fa_helper::compare_fa(usdt_metadata, usdc_metadata)), 5);
        assert!(comparator::is_greater_than(&fa_helper::compare_fa(usdt_metadata, apt_metadata)), 6);
    }

    #[test]
    fun test_fas_compared_with_metadata_address_if_symbs_are_equal() {
        // Create AptosCoin.
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();

        let apt_metadata = option::extract(&mut coin::paired_metadata<AptosCoin>());
        let fake_apt_metadata = create_fake_apt(&create_signer_for_test(@test_fa_admin));

        assert!(comparator::is_smaller_than(&fa_helper::compare_fa(apt_metadata, fake_apt_metadata)), 1);
        assert!(comparator::is_greater_than(&fa_helper::compare_fa(fake_apt_metadata, apt_metadata)), 2);
    }

    #[test]
    fun test_is_fa_sorted() {
        // Create AptosCoin.
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();

        test_fas::create_admin_with_fas();

        let btc_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let usdt_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");
        let usdc_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let apt_metadata = option::extract(&mut coin::paired_metadata<AptosCoin>());
        let fake_apt_metadata = create_fake_apt(&create_signer_for_test(@test_fa_admin));

        assert!(fa_helper::is_fa_sorted(apt_metadata, btc_metadata), 1);
        assert!(fa_helper::is_fa_sorted(usdc_metadata, usdt_metadata), 2);
        assert!(fa_helper::is_fa_sorted(apt_metadata, fake_apt_metadata), 3);

        assert!(!fa_helper::is_fa_sorted(btc_metadata, apt_metadata), 4);
        assert!(!fa_helper::is_fa_sorted(usdt_metadata, usdc_metadata), 5);
    }

    #[test]
    #[expected_failure(abort_code = fa_helper::ERR_CANNOT_BE_THE_SAME_FA)]
    fun test_is_sorted_cannot_be_equal() {
        // Create AptosCoin.
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        let apt_metadata = option::extract(&mut coin::paired_metadata<AptosCoin>());

        assert!(fa_helper::is_fa_sorted(apt_metadata, apt_metadata), 1);
    }
}
