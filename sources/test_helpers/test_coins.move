#[test_only]
// todo: rename to FA?
module test_coin_admin::test_coins {
    use std::option;
    use std::string::utf8;
    use std::signer;
    use std::string;
    use std::vector;
    use aptos_std::type_info;

    use aptos_framework::coin::{Self, Coin, MintCapability, BurnCapability};
    use aptos_framework::account;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{MintRef, BurnRef, Metadata, FungibleAsset};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;

    struct BTC {}

    struct USDT {}

    struct USDC {}

    struct RefsFA has key {
        mint_ref: MintRef,
        burn_ref: BurnRef,
    }

    struct Capabilities<phantom CoinType> has key {
        mint_cap: MintCapability<CoinType>,
        burn_cap: BurnCapability<CoinType>,
    }

    // Register one coin with custom details.
    public fun register_coin<CoinType>(coin_admin: &signer, name: vector<u8>, symbol: vector<u8>, decimals: u8) {
        let (burn_cap, freeze_cap, mint_cap, ) = coin::initialize<CoinType>(
            coin_admin,
            utf8(name),
            utf8(symbol),
            decimals,
            true,
        );
        coin::destroy_freeze_cap(freeze_cap);

        move_to(coin_admin, Capabilities<CoinType> {
            mint_cap,
            burn_cap,
        });
    }

    public fun create_coin_admin(): signer {
        account::create_account_for_test(@test_coin_admin)
    }

    public fun create_admin_with_coins(): signer {
        let coin_admin = create_coin_admin();
        register_coins(&coin_admin);
        coin_admin
    }

    // todo: refactor this file
    // todo: change coin admin to fa admin?
    public fun create_admin_with_fas(): signer {
        let fa_admin = create_coin_admin();
        register_fa(&fa_admin);
        fa_admin
    }

    // Register all known FA's in one func.
    public fun register_fa(fa_admin: &signer) {
        let constructor_ref = object::create_named_object(fa_admin, b"USDT_FA_OBJ");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none() /* max supply */,
            string::utf8(b"USDT Fungible Asset"),
            string::utf8(b"USDT"),
            6,
            string::utf8(b"http://www.example.com/favicon.ico"),
            string::utf8(b"http://www.example.com"),
        );
        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        let usdt_refs_constructor_ref = object::create_named_object(fa_admin, b"USDT_REFS");
        let usdt_refs_signer = object::generate_signer(&usdt_refs_constructor_ref);
        move_to(&usdt_refs_signer, RefsFA {
            mint_ref,
            burn_ref,
        });

        let constructor_ref = object::create_named_object(fa_admin, b"BTC_FA_OBJ");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none() /* max supply */,
            string::utf8(b"BTC Fungible Asset"),
            string::utf8(b"BTC"),
            8,
            string::utf8(b"http://www.example.com/favicon.ico"),
            string::utf8(b"http://www.example.com"),
        );
        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        let btc_refs_constructor_ref = object::create_named_object(fa_admin, b"BTC_REFS");
        let btc_refs_signer = object::generate_signer(&btc_refs_constructor_ref);
        move_to(&btc_refs_signer, RefsFA {
            mint_ref,
            burn_ref,
        });

        let constructor_ref = object::create_named_object(fa_admin, b"USDC_FA_OBJ");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none() /* max supply */,
            string::utf8(b"USDC Fungible Asset"),
            string::utf8(b"USDC"),
            4,
            string::utf8(b"http://www.example.com/favicon.ico"),
            string::utf8(b"http://www.example.com"),
        );
        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        let usdc_refs_constructor_ref = object::create_named_object(fa_admin, b"USDC_REFS");
        let usdc_refs_signer = object::generate_signer(&usdc_refs_constructor_ref);
        move_to(&usdc_refs_signer, RefsFA {
            mint_ref,
            burn_ref,
        });
    }

    // Register all known coins in one func.
    public fun register_coins(coin_admin: &signer) {
        let (usdt_burn_cap, usdt_freeze_cap, usdt_mint_cap) =
            coin::initialize<USDT>(
                coin_admin,
                utf8(b"USDT"),
                utf8(b"USDT"),
                6,
                true
            );

        let (btc_burn_cap, btc_freeze_cap, btc_mint_cap) =
            coin::initialize<BTC>(
                coin_admin,
                utf8(b"BTC"),
                utf8(b"BTC"),
                8,
                true
            );

        let (usdc_burn_cap, usdc_freeze_cap, usdc_mint_cap) =
            coin::initialize<USDC>(
                coin_admin,
                utf8(b"USDC"),
                utf8(b"USDC"),
                4,
                true,
            );

        move_to(coin_admin, Capabilities<USDT> {
            mint_cap: usdt_mint_cap,
            burn_cap: usdt_burn_cap,
        });

        move_to(coin_admin, Capabilities<BTC> {
            mint_cap: btc_mint_cap,
            burn_cap: btc_burn_cap,
        });

        move_to(coin_admin, Capabilities<USDC> {
            mint_cap: usdc_mint_cap,
            burn_cap: usdc_burn_cap,
        });

        coin::destroy_freeze_cap(usdt_freeze_cap);
        coin::destroy_freeze_cap(usdc_freeze_cap);
        coin::destroy_freeze_cap(btc_freeze_cap);
    }

    public fun get_fa_metadata_from_symbol(symbol: vector<u8>): Object<Metadata> {
        // Append `symbol` to contain "_FA_OBJ" to create metadata object name
        vector::append(&mut symbol, b"_FA_OBJ");

        let obj_addr = object::create_object_address(&@test_coin_admin, symbol);
        object::address_to_object<Metadata>(obj_addr)
    }

    public fun mint_fa(fa_admin: &signer, symbol: vector<u8>, amount: u64): FungibleAsset acquires RefsFA {
        let fa_admin_addr = signer::address_of(fa_admin);

        // Append `symbol` to contain "_REFS" to create refs object name
        vector::append(&mut symbol, b"_REFS");

        let fa_refs_obj_addr = object::create_object_address(&fa_admin_addr, symbol);
        let fa_refs = borrow_global_mut<RefsFA>(fa_refs_obj_addr);

        fungible_asset::mint(&fa_refs.mint_ref, amount)
    }

    public fun burn_fa(fa_admin: &signer, symbol: vector<u8>, fa: FungibleAsset) acquires RefsFA {
        let fa_admin_addr = signer::address_of(fa_admin);

        // Append `symbol` to contain "_REFS" to create refs object name
        vector::append(&mut symbol, b"_REFS");

        let fa_refs_obj_addr = object::create_object_address(&fa_admin_addr, symbol);
        let fa_refs = borrow_global_mut<RefsFA>(fa_refs_obj_addr);

        fungible_asset::burn(&fa_refs.burn_ref, fa)
    }

    public fun mint<CoinType>(coin_admin: &signer, amount: u64): Coin<CoinType> acquires Capabilities {
        let caps = borrow_global<Capabilities<CoinType>>(signer::address_of(coin_admin));
        coin::mint(amount, &caps.mint_cap)
    }

    public fun burn<CoinType>(coin_admin: &signer, coins: Coin<CoinType>) acquires Capabilities {
        if (coin::value(&coins) == 0) {
            coin::destroy_zero(coins);
        } else {
            let caps = borrow_global<Capabilities<CoinType>>(signer::address_of(coin_admin));
            coin::burn(coins, &caps.burn_cap);
        };
    }
}
