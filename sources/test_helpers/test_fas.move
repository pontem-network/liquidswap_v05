#[test_only]
module test_fa_admin::test_fas {
    use std::option;
    use std::signer;
    use std::string;
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{BurnRef, FungibleAsset, Metadata, MintRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;

    struct RefsFA has key {
        mint_ref: MintRef,
        burn_ref: BurnRef,
    }

    public fun create_fa_admin(): signer {
        account::create_account_for_test(@test_fa_admin)
    }

    public fun create_admin_with_fas(): signer {
        let fa_admin = create_fa_admin();
        register_all_fa(&fa_admin);
        fa_admin
    }

    public fun register_fa(
        fa_admin: &signer,
        name: vector<u8>,
        symbol: vector<u8>,
        decimals: u8,
        seed: vector<u8>,
    ): (MintRef, BurnRef) {
        let constructor_ref = object::create_named_object(fa_admin, seed);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none() /* max supply */,
            string::utf8(name),
            string::utf8(symbol),
            decimals,
            string::utf8(b"http://www.example.com/favicon.ico"),
            string::utf8(b"http://www.example.com"),
        );
        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        (mint_ref, burn_ref)
    }

    public fun save_fa_refs(
        fa_admin: &signer,
        seed: vector<u8>,
        mint_ref: MintRef,
        burn_ref: BurnRef,
    ) {
        let refs_constructor_ref = object::create_named_object(fa_admin, seed);
        let refs_signer = object::generate_signer(&refs_constructor_ref);
        move_to(&refs_signer, RefsFA {
            mint_ref,
            burn_ref,
        });
    }

    // Register all known FA's in one func.
    public fun register_all_fa(fa_admin: &signer) {
        // Create USDT FA.
        let (mint_ref, burn_ref) = register_fa(
            fa_admin,
            b"USDT Fungible Asset",
            b"USDT",
            6,
            b"USDT_FA_OBJ"
        );
        save_fa_refs(fa_admin, b"USDT_REFS", mint_ref, burn_ref);

        // Create BTC FA.
        let (mint_ref, burn_ref) = register_fa(
            fa_admin,
            b"BTC Fungible Asset",
            b"BTC",
            8,
            b"BTC_FA_OBJ"
        );
        save_fa_refs(fa_admin, b"BTC_REFS", mint_ref, burn_ref);

        // Create USDC FA.
        let (mint_ref, burn_ref) = register_fa(
            fa_admin,
            b"USDC Fungible Asset",
            b"USDC",
            4,
            b"USDC_FA_OBJ"
        );
        save_fa_refs(fa_admin, b"USDC_REFS", mint_ref, burn_ref);
    }

    public fun get_fa_metadata_from_symbol(symbol: vector<u8>): Object<Metadata> {
        // Append `symbol` to contain "_FA_OBJ" to create metadata object name
        vector::append(&mut symbol, b"_FA_OBJ");

        let obj_addr = object::create_object_address(&@test_fa_admin, symbol);
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
}
