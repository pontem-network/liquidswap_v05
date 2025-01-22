module liquidswap_v05::dao_storage {
    use std::signer;
    use std::string::{Self, String};

    use aptos_framework::account;
    use aptos_framework::account::SignerCapability;
    use aptos_framework::event;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{Metadata, FungibleAsset};
    use aptos_framework::object;
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store;
    use liquidswap_v05::fa_helper;

    use liquidswap_v05::global_config;

    friend liquidswap_v05::liquidity_pool;

    // Error codes.

    /// When storage doesn't exists
    const ERR_NOT_REGISTERED: u64 = 401;

    /// When invalid DAO admin account
    const ERR_NOT_ADMIN_ACCOUNT: u64 = 402;

    /// Unreachable, is a bug if thrown
    const ERR_UNREACHABLE: u64 = 403;

    // Constants.

    const STORAGE_SEED: vector<u8> = b"dao_fa_store_sig_cap_seed";

    // Public functions.

    /// Resource to store capability to create DAO FA storages objects.
    struct StoreObjectsCreatorCap has key { signer_cap: SignerCapability }

    /// Signer to create FA storage, stored in objects.
    struct FungibleStoreSigner has key {signer_cap: SignerCapability }

    /// Initializes DaoStorage contract.
    public(friend) fun initialize(liquidswap_admin: &signer) {
        assert!(signer::address_of(liquidswap_admin) == @liquidswap_v05, ERR_UNREACHABLE);

        let (_, storage_sig_cap) =
            account::create_resource_account(liquidswap_admin, STORAGE_SEED);
        move_to(liquidswap_admin, StoreObjectsCreatorCap { signer_cap: storage_sig_cap });
    }

    /// Register storage
    /// Parameters:
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public(friend) fun register<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) acquires StoreObjectsCreatorCap {
        let obj_creator_cap = borrow_global<StoreObjectsCreatorCap>(@liquidswap_v05);
        let obj_creator_acc = account::create_signer_with_capability(&obj_creator_cap.signer_cap);

        // Create fungible stores for X and Y FA's.
        let storage_seed = *string::bytes(&create_fa_storage_seed<Curve>(x_metadata, y_metadata));
        let store_obj_constructor_ref =
            object::create_named_object(&obj_creator_acc, storage_seed);
        object::set_untransferable(&store_obj_constructor_ref);
        let store_obj_acc = object::generate_signer(&store_obj_constructor_ref);

        let (fa_res_acc, fa_sig_cap) =
            account::create_resource_account(&obj_creator_acc, storage_seed);
        let fa_res_acc_addr = signer::address_of(&fa_res_acc);
        move_to(&store_obj_acc, FungibleStoreSigner { signer_cap: fa_sig_cap });

        primary_fungible_store::create_primary_store(fa_res_acc_addr, x_metadata);
        primary_fungible_store::create_primary_store(fa_res_acc_addr, y_metadata);

        let events_store = EventsStore<Curve> {
            storage_registered_handle: account::new_event_handle(&fa_res_acc),
            coin_deposited_handle: account::new_event_handle(&fa_res_acc),
            coin_withdrawn_handle: account::new_event_handle(&fa_res_acc)
        };

        // todo: gen 2 events?
        event::emit_event(
            &mut events_store.storage_registered_handle,
            StorageCreatedEvent<Curve> {
                x_metadata: object::object_address(&x_metadata),
                y_metadata: object::object_address(&y_metadata),
            }
        );

        // There is no coin generics for DAO assets storage.
        // So have to store DAO events for each pool at separate res account.
        move_to(&fa_res_acc, events_store);
    }

    /// Deposit FA's to storage from liquidity pool
    /// Parameters:
    /// * `fa_x` - X FA to deposit.
    /// * `fa_y` - Y FA to deposit.
    public(friend) fun deposit<Curve>(
        fa_x: FungibleAsset,
        fa_y: FungibleAsset,
    ) acquires StoreObjectsCreatorCap, FungibleStoreSigner, EventsStore {
        let x_metadata = fungible_asset::metadata_from_asset(&fa_x);
        let y_metadata = fungible_asset::metadata_from_asset(&fa_y);

        // Get FA storages address.
        let obj_creator_cap = borrow_global<StoreObjectsCreatorCap>(@liquidswap_v05);
        let obj_creator_addr = account::get_signer_capability_address(&obj_creator_cap.signer_cap);

        let storage_seed = *string::bytes(&create_fa_storage_seed<Curve>(x_metadata, y_metadata));
        let storage_obj_addr = object::create_object_address(&obj_creator_addr, storage_seed);

        // Check FA storages exists.
        assert!(object::object_exists<FungibleStoreSigner>(storage_obj_addr), ERR_NOT_REGISTERED);

        let storage_obj = borrow_global<FungibleStoreSigner>(storage_obj_addr);
        let fa_res_acc_addr = account::get_signer_capability_address(&storage_obj.signer_cap);

        let x_val = fungible_asset::amount(&fa_x);
        let y_val = fungible_asset::amount(&fa_y);

        primary_fungible_store::deposit(fa_res_acc_addr, fa_x);
        primary_fungible_store::deposit(fa_res_acc_addr, fa_y);

        let events_store = borrow_global_mut<EventsStore<Curve>>(fa_res_acc_addr);
        event::emit_event(
            &mut events_store.coin_deposited_handle,
            CoinDepositedEvent<Curve> {
                x_val,
                y_val,
                x_metadata: object::object_address(&x_metadata),
                y_metadata: object::object_address(&y_metadata),
            }
        );
    }

    /// Withdraw FA's from storage
    /// Parameters:
    /// * `dao_admin_acc` - DAO admin.
    /// * `x_val` - amount of X FA to withdraw.
    /// * `y_val` - amount of Y FA to withdraw.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns both withdrawn X and Y FA's: `(FungibleAsset, FungibleAsset)`.
    public fun withdraw<Curve>(
        dao_admin_acc: &signer,
        x_val: u64,
        y_val: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (FungibleAsset, FungibleAsset)
    acquires StoreObjectsCreatorCap, FungibleStoreSigner, EventsStore {
        assert!(signer::address_of(dao_admin_acc) == global_config::get_dao_admin(), ERR_NOT_ADMIN_ACCOUNT);

        // Get FA storages signer.
        let obj_creator_cap = borrow_global<StoreObjectsCreatorCap>(@liquidswap_v05);
        let obj_creator_addr = account::get_signer_capability_address(&obj_creator_cap.signer_cap);

        let storage_seed = *string::bytes(&create_fa_storage_seed<Curve>(x_metadata, y_metadata));
        let storage_obj_addr = object::create_object_address(&obj_creator_addr, storage_seed);
        let storage_obj = borrow_global<FungibleStoreSigner>(storage_obj_addr);
        let fa_res_acc = &account::create_signer_with_capability(&storage_obj.signer_cap);

        let fa_x = primary_fungible_store::withdraw(fa_res_acc, x_metadata, x_val);
        let fa_y = primary_fungible_store::withdraw(fa_res_acc, y_metadata, y_val);

        let fa_res_acc_addr = signer::address_of(fa_res_acc);
        let events_store = borrow_global_mut<EventsStore<Curve>>(fa_res_acc_addr);
        event::emit_event(
            &mut events_store.coin_withdrawn_handle,
            CoinWithdrawnEvent<Curve> {
                x_val,
                y_val,
                x_metadata: object::object_address(&x_metadata),
                y_metadata: object::object_address(&y_metadata),
            }
        );

        (fa_x, fa_y)
    }

    #[view]
    /// Creates a seed for FA's storage object.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun create_fa_storage_seed<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): String {
        let pool_obj_name = fa_helper::create_pool_obj_name<Curve>(x_metadata, y_metadata);
        string::append_utf8(&mut pool_obj_name, b"{}-DAO-FA-Storage");
        pool_obj_name
    }

    #[test_only]
    public fun get_storage_size<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) acquires StoreObjectsCreatorCap, FungibleStoreSigner {
        let obj_creator_cap = borrow_global<StoreObjectsCreatorCap>(@liquidswap_v05);
        let obj_creator_addr = account::get_signer_capability_address(&obj_creator_cap.signer_cap);

        let storage_seed = *string::bytes(&create_fa_storage_seed<Curve>(x_metadata, y_metadata));
        let storage_obj_addr = object::create_object_address(&obj_creator_addr, storage_seed);
        let storage_obj = borrow_global<FungibleStoreSigner>(storage_obj_addr);
        let fa_res_acc_addr = account::get_signer_capability_address(&storage_obj.signer_cap);

        let x_val = primary_fungible_store::balance(fa_res_acc_addr, x_metadata);
        let y_val = primary_fungible_store::balance(fa_res_acc_addr, y_metadata);

        (x_val, y_val)
    }

    #[test_only]
    public fun initialize_for_test(liquidswap_admin: &signer) {
        initialize(liquidswap_admin);
    }

    #[test_only]
    public fun register_for_test<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>
    ) acquires StoreObjectsCreatorCap {
        register<Curve>(x_metadata, y_metadata);
    }

    #[test_only]
    public fun deposit_for_test<Curve>(
        fa_x: FungibleAsset,
        fa_y: FungibleAsset,
    ) acquires StoreObjectsCreatorCap, FungibleStoreSigner, EventsStore {
        deposit<Curve>(fa_x, fa_y);
    }

    // Events

    struct EventsStore<phantom Curve> has key {
        storage_registered_handle: event::EventHandle<StorageCreatedEvent<Curve>>,
        coin_deposited_handle: event::EventHandle<CoinDepositedEvent<Curve>>,
        coin_withdrawn_handle: event::EventHandle<CoinWithdrawnEvent<Curve>>,
    }

    struct StorageCreatedEvent<phantom Curve> has store, drop {
        x_metadata: address,
        y_metadata: address,
    }

    struct CoinDepositedEvent<phantom Curve> has store, drop {
        x_val: u64,
        y_val: u64,
        x_metadata: address,
        y_metadata: address,
    }

    struct CoinWithdrawnEvent<phantom Curve> has store, drop {
        x_val: u64,
        y_val: u64,
        x_metadata: address,
        y_metadata: address,
    }
}
