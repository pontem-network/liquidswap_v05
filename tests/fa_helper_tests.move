#[test_only]
module liquidswap_v05::fa_helper_tests {
    use std::signer;
    use std::string;
    use std::string::utf8;

    use aptos_std::comparator;
    use aptos_std::string_utils;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object;

    use liquidswap_v05::curves::{Stable, Uncorrelated};
    use liquidswap_v05::fa_helper;
    use test_fa_admin::test_fas;

    #[test]
    fun test_end_to_end() {
        let fa_admin = test_fas::create_admin_with_fas();
        let fa_admin_addr = signer::address_of(&fa_admin);

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let btc_fa_obj_addr = object::create_object_address(&fa_admin_addr, b"BTC_FA_OBJ");
        assert!(object::object_exists<Metadata>(btc_fa_obj_addr), 1);

        let usdt_fa_obj_addr = object::create_object_address(&fa_admin_addr, b"USDT_FA_OBJ");
        assert!(object::object_exists<Metadata>(usdt_fa_obj_addr), 2);

        let fa_minted = test_fas::mint_fa(&fa_admin, b"USDT", 1000000000);

        let usdt_supply = fa_helper::fa_supply(fa_y_metadata);
        let btc_supply = fa_helper::fa_supply(fa_x_metadata);
        assert!(usdt_supply == 1000000000, 3);
        assert!(btc_supply == 0, 4);

        test_fas::burn_fa(&fa_admin, b"USDT", fa_minted);
        usdt_supply = fa_helper::fa_supply(fa_y_metadata);
        assert!(usdt_supply == 0, 5);

        assert!(fa_helper::is_fa_sorted(fa_x_metadata, fa_y_metadata), 6);
        assert!(!fa_helper::is_fa_sorted(fa_y_metadata, fa_x_metadata), 7);

        let cmp = fa_helper::compare_fa(fa_x_metadata, fa_y_metadata);
        assert!(comparator::is_smaller_than(&cmp), 8);
        cmp = fa_helper::compare_fa(fa_x_metadata, fa_x_metadata);
        assert!(comparator::is_equal(&cmp), 9);
        cmp = fa_helper::compare_fa(fa_y_metadata, fa_x_metadata);
        assert!(comparator::is_greater_than(&cmp), 10);
    }

    #[test]
    #[expected_failure(abort_code = 393218, location = aptos_framework::object)]
    fun test_non_existent_fa_interaction_shoul_fail() {
        let obj_addr = object::create_object_address(&@test_fa_admin, b"BTC");
        object::address_to_object<Metadata>(obj_addr);
    }

    #[test]
    #[expected_failure(abort_code = fa_helper::ERR_CANNOT_BE_THE_SAME_FA)]
    fun test_cant_be_same_fa_failure() {
        test_fas::create_admin_with_fas();

        let fa_usdt_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        fa_helper::is_fa_sorted(fa_usdt_metadata, fa_usdt_metadata);
    }

    #[test]
    fun generate_lp_name_btc_usdt() {
        let fa_admin = test_fas::create_fa_admin();

        let (_, _) = test_fas::register_fa(
            &fa_admin,
            b"Bitcoin",
            b"BTC",
            8,
            b"BTC_FA_OBJ",
        );
        let (_, _) = test_fas::register_fa(
            &fa_admin,
            b"Usdt",
            b"USDT",
            6,
            b"USDT_FA_OBJ",
        );

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (lp_name, lp_symbol) =
            fa_helper::fa_generate_lp_name_and_symbol<Uncorrelated>(fa_x_metadata, fa_y_metadata);
        assert!(lp_name == utf8(b"LS05 LP-BTC-USDT-U"), 0);
        assert!(lp_symbol == utf8(b"BTC-USDTU"), 1);
    }

    #[test]
    fun generate_lp_name_usdc_usdt() {
        let fa_admin = test_fas::create_fa_admin();

        let (_, _) = test_fas::register_fa(
            &fa_admin,
            b"USDC",
            b"USDC",
            4,
            b"USDC_FA_OBJ",
        );
        let (_, _) = test_fas::register_fa(
            &fa_admin,
            b"USDT",
            b"USDT",
            6,
            b"USDT_FA_OBJ",
        );

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (lp_name, lp_symbol) = fa_helper::fa_generate_lp_name_and_symbol<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(lp_name == utf8(b"LS05 LP-USDC-USDT-S"), 0);
        assert!(lp_symbol == utf8(b"USDC-USDTS"), 1);
    }

    #[test]
    fun generate_lp_name_usdc_usdt_prefix() {
        let fa_admin = test_fas::create_fa_admin();

        let (_, _) = test_fas::register_fa(
            &fa_admin,
            b"USDC",
            b"USDCSymbol",
            4,
            b"USDC_FA_OBJ",
        );
        let (_, _) = test_fas::register_fa(
            &fa_admin,
            b"USDT",
            b"USDTSymbol",
            6,
            b"USDT_FA_OBJ",
        );

        let fa_x_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fa_y_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");

        let (lp_name, lp_symbol) =
            fa_helper::fa_generate_lp_name_and_symbol<Stable>(fa_x_metadata, fa_y_metadata);
        assert!(lp_name == utf8(b"LS05 LP-USDCSymbol-USDTSymbol-S"), 0);
        assert!(lp_symbol == utf8(b"USDC-USDTS"), 1);
    }

    #[test]
    fun test_create_pool_obj_name() {
        let fa_admin = test_fas::create_admin_with_fas();

        // Create fake BTC FA.
        let (mint_ref, _) = test_fas::register_fa(
            &fa_admin,
            b"BTC Fungible Asset",
            b"BTC",
            8,
            b"FAKE_BTC_FA_OBJ",
        );

        // Get all FA's metadatas.
        let btc_metadata = test_fas::get_fa_metadata_from_symbol(b"BTC");
        let usdt_metadata = test_fas::get_fa_metadata_from_symbol(b"USDT");
        let usdc_metadata = test_fas::get_fa_metadata_from_symbol(b"USDC");
        let fake_btc_metadata = fungible_asset::mint_ref_metadata(&mint_ref);

        let btc_metadata_addr = object::object_address(&btc_metadata);
        let usdt_metadata_addr = object::object_address(&usdt_metadata);
        let usdc_metadata_addr = object::object_address(&usdc_metadata);
        let fake_btc_metadata_addr = object::object_address(&fake_btc_metadata);

        assert!(btc_metadata_addr == @0xde7426eb496bc9ad39e9840b8dc4012344f45ac420215e8204e7fd2f026b42f5, 1);
        assert!(usdt_metadata_addr == @0x7a54c5c4b35ae946f10beb158bd575f1700271c5f83a0e4096ee80970cf1bbb9, 2);
        assert!(usdc_metadata_addr == @0x493d04052d1bada2804bce92ba491b4b5312af2464f870cc8fe0325500b23c3f, 3);
        assert!(fake_btc_metadata_addr == @0x25712b83fe664899adcc0bd9d4e0ff3f542c78bbe415ffddf55a712d4ee7dc0c, 4);

        // Check BTC-USDT-Uncorrelated pool obj name.
        let pool_obj_name = fa_helper::create_pool_obj_name<Uncorrelated>(btc_metadata, usdt_metadata);
        let pool_obj_name_to_check =
            string_utils::format2(&b"BTC{}-USDT{}-Uncorrelated", btc_metadata_addr, usdt_metadata_addr);
        assert!(pool_obj_name == pool_obj_name_to_check, 1);
        assert!(pool_obj_name == string::utf8(b"BTC@0xde7426eb496bc9ad39e9840b8dc4012344f45ac420215e8204e7fd2f026b42f5-USDT@0x7a54c5c4b35ae946f10beb158bd575f1700271c5f83a0e4096ee80970cf1bbb9-Uncorrelated"), 1);

        // Check USDT-BTC-Uncorrelated pool obj name.
        // There is a check are FA's sorted in pool creation, but still.
        let pool_obj_name = fa_helper::create_pool_obj_name<Uncorrelated>(usdt_metadata, btc_metadata);
        let pool_obj_name_to_check =
            string_utils::format2(&b"USDT{}-BTC{}-Uncorrelated", usdt_metadata_addr, btc_metadata_addr);
        assert!(pool_obj_name == pool_obj_name_to_check, 1);
        assert!(pool_obj_name == string::utf8(b"USDT@0x7a54c5c4b35ae946f10beb158bd575f1700271c5f83a0e4096ee80970cf1bbb9-BTC@0xde7426eb496bc9ad39e9840b8dc4012344f45ac420215e8204e7fd2f026b42f5-Uncorrelated"), 1);

        // Check USDC-USDT-Stable pool obj name.
        let pool_obj_name = fa_helper::create_pool_obj_name<Stable>(usdc_metadata, usdt_metadata);
        let pool_obj_name_to_check =
            string_utils::format2(&b"USDC{}-USDT{}-Stable", usdc_metadata_addr, usdt_metadata_addr);
        assert!(pool_obj_name == pool_obj_name_to_check, 1);
        assert!(pool_obj_name == string::utf8(b"USDC@0x493d04052d1bada2804bce92ba491b4b5312af2464f870cc8fe0325500b23c3f-USDT@0x7a54c5c4b35ae946f10beb158bd575f1700271c5f83a0e4096ee80970cf1bbb9-Stable"), 1);

        // Check BTC-BTC-Stable pool obj name.
        // There is a check are the same in pool creation, but still.
        let pool_obj_name = fa_helper::create_pool_obj_name<Stable>(btc_metadata, btc_metadata);
        let pool_obj_name_to_check =
            string_utils::format2(&b"BTC{}-BTC{}-Stable", btc_metadata_addr, btc_metadata_addr);
        assert!(pool_obj_name == pool_obj_name_to_check, 1);
        assert!(pool_obj_name == string::utf8(b"BTC@0xde7426eb496bc9ad39e9840b8dc4012344f45ac420215e8204e7fd2f026b42f5-BTC@0xde7426eb496bc9ad39e9840b8dc4012344f45ac420215e8204e7fd2f026b42f5-Stable"), 1);

        // Check BTC-(FAKE)BTC-Uncorrelated pool obj name.
        // Could be situanions when diffents FA's has same symbols.
        let pool_obj_name = fa_helper::create_pool_obj_name<Uncorrelated>(fake_btc_metadata, btc_metadata);
        let pool_obj_name_to_check =
            string_utils::format2(&b"BTC{}-BTC{}-Uncorrelated", fake_btc_metadata_addr, btc_metadata_addr);
        assert!(pool_obj_name == pool_obj_name_to_check, 1);
        assert!(pool_obj_name == string::utf8(b"BTC@0x25712b83fe664899adcc0bd9d4e0ff3f542c78bbe415ffddf55a712d4ee7dc0c-BTC@0xde7426eb496bc9ad39e9840b8dc4012344f45ac420215e8204e7fd2f026b42f5-Uncorrelated"), 1);
    }
}
