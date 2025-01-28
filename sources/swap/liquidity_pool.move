/// Liquidswap liquidity pool module.
/// Implements mint/burn liquidity, swap of FA's.
module liquidswap_v05::liquidity_pool {
    use std::option;
    use std::signer;
    use std::string;

    use aptos_std::event;
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::fungible_asset::{Self, BurnRef, FungibleAsset, Metadata, MintRef};
    use aptos_framework::object;
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use uq64x64::uq64x64;

    use liquidswap_v05::curves;
    use liquidswap_v05::dao_storage;
    use liquidswap_v05::emergency::{Self, assert_no_emergency};
    use liquidswap_v05::fa_helper;
    use liquidswap_v05::global_config;
    use liquidswap_v05::math;
    use liquidswap_v05::stable_curve;

    // Error codes.

    /// When FA's used to create pair have wrong ordering.
    const ERR_WRONG_PAIR_ORDERING: u64 = 100;
    /// When pair already exists on account.
    const ERR_POOL_EXISTS_FOR_PAIR: u64 = 101;
    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_INITIAL_LIQUIDITY: u64 = 102;
    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_LIQUIDITY: u64 = 103;
    /// When both X and Y provided for swap are equal zero.
    const ERR_EMPTY_FA_IN: u64 = 104;
    /// When incorrect INs/OUTs arguments passed during swap and math doesn't work.
    const ERR_INCORRECT_SWAP: u64 = 105;
    /// Incorrect lp coin burn values.
    const ERR_INCORRECT_BURN_VALUES: u64 = 106;
    /// When pool doesn't exists for pair.
    const ERR_POOL_DOES_NOT_EXIST: u64 = 107;
    /// Should never occur.
    const ERR_UNREACHABLE: u64 = 108;
    /// When `initialize()` transaction is signed with any account other than @liquidswap.
    const ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE: u64 = 109;
    /// When both X and Y provided for flashloan are equal zero.
    const ERR_EMPTY_FA_LOAN: u64 = 110;
    /// When pool is locked.
    const ERR_POOL_IS_LOCKED: u64 = 111;
    /// When user is not admin.
    const ERR_NOT_ADMIN: u64 = 112;
    /// When user returns flashloan to wrong pool.
    const ERR_WRONG_POOL: u64 = 113;
    /// When pool is unlocked, but should be locked.
    const ERR_POOL_IS_UNLOCKED: u64 = 114;
    /// When not enough reserves for flashloan.
    const ERR_NOT_ENOUGH_RESERVES: u64 = 115;

    // Constants.

    /// Minimal liquidity.
    const MINIMAL_LIQUIDITY: u64 = 1000;
    /// Denominator to handle decimal points for fees.
    const FEE_SCALE: u64 = 10000;
    /// Denominator to handle decimal points for dao fee.
    const DAO_FEE_SCALE: u64 = 100;
    /// Liquidity fungible asset decimals.
    const LP_FA_DECIMALS: u8 = 6;

    // Public functions.

    // todo: recheck do we need #[resource_group_member(group = aptos_framework::object::ObjectGroup)]?
    // todo: do we need to track LP balance as with resources?
    // todo: we can create lp_metadata => pool_obj_address mapping to get rid of X & Y metadata passing on burn()
    // todo: check user able to transfer LP FA.

    /// Liquidity pool with reserve metadatas.
    struct LiquidityPool<phantom Curve> has key {
        // Signer capable of manage pool reserve FA stores.
        fa_signer_cap: SignerCapability,
        // Metadata of LP FA's.
        lp_metadata: Object<Metadata>,

        // todo: stop track reserves after AIP with FA adjustment.
        // Pool reserves. Should track them here because there is
        // an ability to replenish FungibleStore bypassing mint func.
        x_reserves: u64,
        y_reserves: u64,

        last_block_timestamp: u64,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        lp_mint_ref: MintRef,
        lp_burn_ref: BurnRef,
        // Scales are pow(10, token_decimals).
        x_scale: u64,
        y_scale: u64,
        locked: bool,
        fee: u64,           // 1 - 100 (0.01% - 1%)
        dao_fee: u64,       // 0 - 100 (0% - 100%)
    }

    /// Flash loan resource.
    /// There is no way in Move to pass calldata and make dynamic calls, but a resource can be used for this purpose.
    /// To make the execution into a single transaction, the flash loan function must return a resource
    /// that cannot be copied, cannot be saved, cannot be dropped, or cloned.
    struct Flashloan<phantom Curve> {
        x_loan: u64,
        y_loan: u64,

        // Address of related pool object to ensure correct return.
        attached_pool_obj_addr: address,
    }

    /// Stores resource account signer capability under Liquidswap account.
    struct PoolAccountCapability has key { signer_cap: SignerCapability }

    /// Initializes Liquidswap contracts.
    public entry fun initialize(liquidswap_admin: &signer) {
        assert!(signer::address_of(liquidswap_admin) == @liquidswap_v05, ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE);

        let (_, signer_cap) =
            account::create_resource_account(liquidswap_admin, b"liquidswap_account_seed");
        move_to(liquidswap_admin, PoolAccountCapability { signer_cap });

        global_config::initialize(liquidswap_admin);
        dao_storage::initialize(liquidswap_admin);
        emergency::initialize(liquidswap_admin);
    }

    /// Register liquidity pool for `X`/`Y` FA's with `Curve`.
    /// * `acc` - pool creator signer.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun register<Curve>(
        acc: &signer,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) acquires PoolAccountCapability {
        assert_no_emergency();
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        curves::assert_valid_curve<Curve>();
        assert!(!is_pool_exists<Curve>(x_metadata, y_metadata), ERR_POOL_EXISTS_FOR_PAIR);

        let pool_cap = borrow_global<PoolAccountCapability>(@liquidswap_v05);
        let pool_account = account::create_signer_with_capability(&pool_cap.signer_cap);

        // Creates a non-deletable object with a named address based on our LP seed.
        let pool_obj_name =
            string::bytes(&fa_helper::create_pool_obj_name<Curve>(x_metadata, y_metadata));
        let lp_fa_obj_seed = string::utf8(*pool_obj_name);
        string::append_utf8( &mut lp_fa_obj_seed, b"-LP");
        let lp_fa_construnctor_ref =
            &object::create_named_object(&pool_account, *string::bytes(&lp_fa_obj_seed));
        object::set_untransferable(lp_fa_construnctor_ref);

        // Create the FA's LP Metadata with name, symbol, icon, etc.
        let (lp_name, lp_symbol) =
             fa_helper::fa_generate_lp_name_and_symbol<Curve>(x_metadata, y_metadata);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            lp_fa_construnctor_ref,
            option::none(), // todo: is it good?
            lp_name,
            lp_symbol,
            LP_FA_DECIMALS,
            string::utf8(b""), /* icon uri */ // todo: is it good?
            string::utf8(b""), /* project uri */ // todo: is it good?
        );

        let lp_mint_ref = fungible_asset::generate_mint_ref(lp_fa_construnctor_ref);
        let lp_burn_ref = fungible_asset::generate_burn_ref(lp_fa_construnctor_ref);
        let lp_metadata = fungible_asset::mint_ref_metadata(&lp_mint_ref);

        // Create fungible stores for X, Y and LP FA's.
        let (fa_res_acc, fa_sig_cap) =
            account::create_resource_account(&pool_account,*pool_obj_name);
        let fa_res_acc_addr = signer::address_of(&fa_res_acc);

        primary_fungible_store::create_primary_store(fa_res_acc_addr, x_metadata);
        primary_fungible_store::create_primary_store(fa_res_acc_addr, y_metadata);
        primary_fungible_store::create_primary_store(fa_res_acc_addr, lp_metadata);

        let x_scale = 0;
        let y_scale = 0;

        if (curves::is_stable<Curve>()) {
            x_scale = math::pow_10(fungible_asset::decimals(x_metadata));
            y_scale = math::pow_10(fungible_asset::decimals(y_metadata));
        };

        let pool = LiquidityPool<Curve> {
            fa_signer_cap: fa_sig_cap,
            lp_metadata,
            x_reserves: 0,
            y_reserves: 0,
            last_block_timestamp: 0,
            last_price_x_cumulative: 0,
            last_price_y_cumulative: 0,
            lp_mint_ref,
            lp_burn_ref,
            x_scale,
            y_scale,
            locked: false,
            fee: global_config::get_default_fee<Curve>(),
            dao_fee: global_config::get_default_dao_fee(),
        };

        // Create object to store pool.
        let pool_constructor_ref =
            object::create_named_object(&pool_account, *pool_obj_name);
        object::set_untransferable(&pool_constructor_ref);
        let pool_signer = object::generate_signer(&pool_constructor_ref);
        move_to(&pool_signer, pool);

        dao_storage::register<Curve>(x_metadata, y_metadata);

        // todo: events 2 gen
        let events_store = EventsStore<Curve> {
            pool_created_handle: account::new_event_handle(&fa_res_acc),
            liquidity_added_handle: account::new_event_handle(&fa_res_acc),
            liquidity_removed_handle: account::new_event_handle(&fa_res_acc),
            swap_handle: account::new_event_handle(&fa_res_acc),
            flashloan_handle: account::new_event_handle(&fa_res_acc),
            oracle_updated_handle: account::new_event_handle(&fa_res_acc),
            update_fee_handle: account::new_event_handle(&fa_res_acc),
            update_dao_fee_handle: account::new_event_handle(&fa_res_acc),
        };

        event::emit_event(
            &mut events_store.pool_created_handle,
            PoolCreatedEvent<Curve> {
                creator: signer::address_of(acc),
                x_metadata: object::object_address(&x_metadata),
                y_metadata: object::object_address(&y_metadata),
            },
        );
        // There is no coin generics in LiquidityPool. So have to store events for each pool at separate res account.
        move_to(&fa_res_acc, events_store);
    }

    /// Mint new liquidity FA.
    /// * `fa_x` - FungibleAsset X to add to liquidity reserves.
    /// * `fa_y` - FungibleAsset Y to add to liquidity reserves.
    /// Returns LP FA: `FungibleAsset`.
    public fun mint<Curve>(fa_x: FungibleAsset, fa_y: FungibleAsset): FungibleAsset
    acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert_no_emergency();

        let x_metadata = fungible_asset::metadata_from_asset(&fa_x);
        let y_metadata = fungible_asset::metadata_from_asset(&fa_y);

        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(is_pool_exists<Curve>(x_metadata, y_metadata), ERR_POOL_DOES_NOT_EXIST);

        let pool_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        let pool = borrow_global_mut<LiquidityPool<Curve>>(pool_addr);

        assert_pool_unlocked<Curve>(pool);

        let fa_res_acc_addr =
            account::get_signer_capability_address(&pool.fa_signer_cap);

        let x_reserve_size = pool.x_reserves;
        let y_reserve_size = pool.y_reserves;

        let x_provided_val = fungible_asset::amount(&fa_x);
        let y_provided_val = fungible_asset::amount(&fa_y);

        let lp_fa_total = fa_helper::fa_supply(pool.lp_metadata);

        let provided_liq = if (lp_fa_total == 0) {
            let initial_liq = math::sqrt(math::mul_to_u128(x_provided_val, y_provided_val));
            assert!(initial_liq > MINIMAL_LIQUIDITY, ERR_NOT_ENOUGH_INITIAL_LIQUIDITY);

            let lp_reserved_fa =
                fungible_asset::mint(&pool.lp_mint_ref, MINIMAL_LIQUIDITY);
            primary_fungible_store::deposit(fa_res_acc_addr, lp_reserved_fa);

            initial_liq - MINIMAL_LIQUIDITY
        } else {
            let x_liq = math::mul_div_u128((x_provided_val as u128), lp_fa_total, (x_reserve_size as u128));
            let y_liq = math::mul_div_u128((y_provided_val as u128), lp_fa_total, (y_reserve_size as u128));
            if (x_liq < y_liq) {
                x_liq
            } else {
                y_liq
            }
        };
        assert!(provided_liq > 0, ERR_NOT_ENOUGH_LIQUIDITY);

        // Deposit into fungible stores of X and Y FA's.
        primary_fungible_store::deposit(fa_res_acc_addr, fa_x);
        primary_fungible_store::deposit(fa_res_acc_addr, fa_y);

        // Track virtual reserves changes.
        pool.x_reserves = pool.x_reserves + x_provided_val;
        pool.y_reserves = pool.y_reserves + y_provided_val;

        let lp_fa = fungible_asset::mint(&pool.lp_mint_ref, provided_liq);

        update_oracle<Curve>(pool, x_reserve_size, y_reserve_size, x_metadata, y_metadata);

        let events_store = borrow_global_mut<EventsStore<Curve>>(fa_res_acc_addr);
        event::emit_event(
            &mut events_store.liquidity_added_handle,
            LiquidityAddedEvent<Curve> {
                added_x_val: x_provided_val,
                added_y_val: y_provided_val,
                lp_tokens_received: provided_liq,
                x_metadata: object::object_address(&x_metadata),
                y_metadata: object::object_address(&y_metadata),
            });

        lp_fa
    }

    /// Burn liquidity FA (LP) and get back X and Y FA's from reserves.
    /// * `lp_fa` - LP FA to burn.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns both X and Y FA's - `(FungibleAsset, FungibleAsset)`.
    public fun burn<Curve>(
        lp_fa: FungibleAsset,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (FungibleAsset, FungibleAsset)
    acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(is_pool_exists<Curve>(x_metadata, y_metadata), ERR_POOL_DOES_NOT_EXIST);

        let pool_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        let pool = borrow_global_mut<LiquidityPool<Curve>>(pool_addr);

        // As LP FA don't have coin generics, it could be passed to any pool.
        // Check that LP passed to correct pool.
        let lp_fa_metadata = fungible_asset::metadata_from_asset(&lp_fa);
        assert!(lp_fa_metadata == pool.lp_metadata, ERR_WRONG_POOL);

        assert_pool_unlocked<Curve>(pool);

        let burned_lp_fa_val = fungible_asset::amount(&lp_fa);
        let lp_coins_total = fa_helper::fa_supply(pool.lp_metadata);

        let fa_res_acc =
            account::create_signer_with_capability(&pool.fa_signer_cap);
        let fa_res_acc_addr = signer::address_of(&fa_res_acc);

        let x_reserve_val = pool.x_reserves;
        let y_reserve_val = pool.y_reserves;

        // Compute X and Y FA values for provided lp_fa value.
        let x_to_return_val =
            math::mul_div_u128((burned_lp_fa_val as u128), (x_reserve_val as u128), lp_coins_total);
        let y_to_return_val =
            math::mul_div_u128((burned_lp_fa_val as u128), (y_reserve_val as u128), lp_coins_total);
        assert!(x_to_return_val > 0 && y_to_return_val > 0, ERR_INCORRECT_BURN_VALUES);

        // Track virtual reserves changes.
        pool.x_reserves = pool.x_reserves - x_to_return_val;
        pool.y_reserves = pool.y_reserves - y_to_return_val;

        // Withdraw from fungible stores of X and Y FA's.
        let x_fa_to_return =
            primary_fungible_store::withdraw(&fa_res_acc, x_metadata, x_to_return_val);
        let y_fa_to_return =
            primary_fungible_store::withdraw(&fa_res_acc, y_metadata, y_to_return_val);

        update_oracle<Curve>(pool, x_reserve_val, y_reserve_val, x_metadata, y_metadata);

        fungible_asset::burn(&pool.lp_burn_ref, lp_fa);

        let events_store = borrow_global_mut<EventsStore<Curve>>(fa_res_acc_addr);
        event::emit_event(
            &mut events_store.liquidity_removed_handle,
            LiquidityRemovedEvent<Curve> {
                returned_x_val: x_to_return_val,
                returned_y_val: y_to_return_val,
                lp_tokens_burned: burned_lp_fa_val,
                x_metadata: object::object_address(&x_metadata),
                y_metadata: object::object_address(&y_metadata),
            });

        (x_fa_to_return, y_fa_to_return)
    }

    /// Swap FA's (can swap both x and y in the same time).
    /// In the most of situation only X or Y FA argument has value (similar with *_out, only one _out will be non-zero).
    /// Because an user usually exchanges only one FA, yet function allow to exchange both FA's.
    /// * `x_in` - X FA to swap.
    /// * `x_out` - expected amount of X FA to get out.
    /// * `y_in` - Y FA to swap.
    /// * `y_out` - expected amount of Y FA to get out.
    /// Returns both exchanged X and Y FA's: `(FungibleAsset, FungibleAsset)`.
    public fun swap<Curve>(
        x_in: FungibleAsset,
        x_out: u64,
        y_in: FungibleAsset,
        y_out: u64
    ): (FungibleAsset, FungibleAsset) acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert_no_emergency();

        let x_metadata = fungible_asset::metadata_from_asset(&x_in);
        let y_metadata = fungible_asset::metadata_from_asset(&y_in);

        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(is_pool_exists<Curve>(x_metadata, y_metadata), ERR_POOL_DOES_NOT_EXIST);

        let pool_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        let pool = borrow_global_mut<LiquidityPool<Curve>>(pool_addr);

        assert_pool_unlocked<Curve>(pool);

        let x_in_val = fungible_asset::amount(&x_in);
        let y_in_val = fungible_asset::amount(&y_in);

        assert!(x_in_val > 0 || y_in_val > 0, ERR_EMPTY_FA_IN);

        let fa_res_acc =
            account::create_signer_with_capability(&pool.fa_signer_cap);
        let fa_res_acc_addr = signer::address_of(&fa_res_acc);

        let x_reserve_size = pool.x_reserves;
        let y_reserve_size = pool.y_reserves;

        // Deposit new FA's into fungible stores of X and Y.
        primary_fungible_store::deposit(fa_res_acc_addr, x_in);
        primary_fungible_store::deposit(fa_res_acc_addr, y_in);

        // Withdraw expected amount from fungible stores of X and Y FA's.
        let x_swapped = primary_fungible_store::withdraw(&fa_res_acc, x_metadata, x_out);
        let y_swapped = primary_fungible_store::withdraw(&fa_res_acc, y_metadata, y_out);

        // Track virtual reserves changes.
        pool.x_reserves = pool.x_reserves + x_in_val - x_out;
        pool.y_reserves = pool.y_reserves + y_in_val - y_out;

        // Confirm that lp_value for the pool hasn't been reduced.
        // For that, we compute lp_value with old reserves and lp_value with reserves after swap is done,
        // and make sure lp_value doesn't decrease
        let (x_res_new_after_fee, y_res_new_after_fee) =
            new_reserves_after_fees_scaled<Curve>(
                pool.x_reserves,
                pool.y_reserves,
                x_in_val,
                y_in_val,
                pool.fee
            );
        assert_lp_value_is_increased<Curve>(
            pool.x_scale,
            pool.y_scale,
            (x_reserve_size as u128),
            (y_reserve_size as u128),
            x_res_new_after_fee,
            y_res_new_after_fee,
        );

        split_fee_to_dao(pool, &fa_res_acc, x_in_val, y_in_val, x_metadata, y_metadata);

        update_oracle<Curve>(pool, x_reserve_size, y_reserve_size, x_metadata, y_metadata);

        let events_store = borrow_global_mut<EventsStore<Curve>>(fa_res_acc_addr);
        event::emit_event(
            &mut events_store.swap_handle,
            SwapEvent<Curve> {
                x_in: x_in_val,
                y_in: y_in_val,
                x_out,
                y_out,
                x_metadata: object::object_address(&x_metadata),
                y_metadata: object::object_address(&y_metadata),
            });

        // Return swapped amount.
        (x_swapped, y_swapped)
    }

    /// Get flash loan FA's.
    /// In the most of situation only X or Y FA argument has value.
    /// Because an user usually loans only one FA, yet function allow to loans both FA's.
    /// * `x_loan` - expected amount of X FA to loan.
    /// * `y_loan` - expected amount of Y FA to loan.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns both loaned X and Y FA's: `(FungibleAsset, FungibleAsset, Flashloan<Curve>)`.
    public fun flashloan<Curve>(
        x_loan: u64,
        y_loan: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (FungibleAsset, FungibleAsset, Flashloan<Curve>)
    acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert_no_emergency();

        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(is_pool_exists<Curve>(x_metadata, y_metadata), ERR_POOL_DOES_NOT_EXIST);

        let pool_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        let pool = borrow_global_mut<LiquidityPool<Curve>>(pool_addr);
        let fa_res_acc =
            account::create_signer_with_capability(&pool.fa_signer_cap);

        assert_pool_unlocked<Curve>(pool);
        assert!(x_loan > 0 || y_loan > 0, ERR_EMPTY_FA_LOAN);

        let reserve_x = pool.x_reserves;
        let reserve_y = pool.y_reserves;

        assert!(reserve_x >= x_loan && reserve_y >= y_loan, ERR_NOT_ENOUGH_RESERVES);

        // Track virtual reserves changes.
        pool.x_reserves = pool.x_reserves - x_loan;
        pool.y_reserves = pool.y_reserves - y_loan;

        // Withdraw expected amount  from fungible stores of X and Y FA's.
        let x_loaned = primary_fungible_store::withdraw(&fa_res_acc, x_metadata, x_loan);
        let y_loaned = primary_fungible_store::withdraw(&fa_res_acc, y_metadata, y_loan);

        // The pool will be locked after the loan until payment.
        pool.locked = true;

        update_oracle(pool, reserve_x, reserve_y, x_metadata, y_metadata);

        // Return loaned amount.
        (x_loaned, y_loaned, Flashloan<Curve> { x_loan, y_loan, attached_pool_obj_addr: pool_addr })
    }

    /// Pay flash loan FA's.
    /// In the most of situation only X or Y FA argument has value.
    /// Because an user usually loans only one FA, yet function allow to loans both FA's.
    /// * `x_in` - X FA to pay.
    /// * `y_in` - Y FA to pay.
    /// * `loan` - data about flashloan.
    public fun pay_flashloan<Curve>(
        x_in: FungibleAsset,
        y_in: FungibleAsset,
        loan: Flashloan<Curve>
    ) acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert_no_emergency();

        let x_metadata = fungible_asset::metadata_from_asset(&x_in);
        let y_metadata = fungible_asset::metadata_from_asset(&y_in);

        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(is_pool_exists<Curve>(x_metadata, y_metadata), ERR_POOL_DOES_NOT_EXIST);

        let pool_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        let pool = borrow_global_mut<LiquidityPool<Curve>>(pool_addr);

        let Flashloan { x_loan, y_loan, attached_pool_obj_addr } = loan;

        // There is no coin generics in Flashloan anymore, so it could be passed to any pool.
        // Check that loan returned to the same pool.
        assert!(pool.locked, ERR_POOL_IS_UNLOCKED);
        assert!(pool_addr == attached_pool_obj_addr, ERR_WRONG_POOL);

        let x_in_val = fungible_asset::amount(&x_in);
        let y_in_val = fungible_asset::amount(&y_in);

        assert!(x_in_val > 0 || y_in_val > 0, ERR_EMPTY_FA_IN);

        let fa_res_acc =
            account::create_signer_with_capability(&pool.fa_signer_cap);
        let fa_res_acc_addr = signer::address_of(&fa_res_acc);

        let x_reserve_size = pool.x_reserves;
        let y_reserve_size = pool.y_reserves;

        // Reserve sizes before loan out.
        x_reserve_size = x_reserve_size + x_loan;
        y_reserve_size = y_reserve_size + y_loan;

        // Deposit into fungible stores of X and Y FA's.
        primary_fungible_store::deposit(fa_res_acc_addr, x_in);
        primary_fungible_store::deposit(fa_res_acc_addr, y_in);

        // Track virtual reserves changes.
        pool.x_reserves = pool.x_reserves + x_in_val;
        pool.y_reserves = pool.y_reserves + y_in_val;

        // Confirm that lp_value for the pool hasn't been reduced.
        // For that, we compute lp_value with old reserves and lp_value with reserves after swap is done,
        // and make sure lp_value doesn't decrease
        let (x_res_new_after_fee, y_res_new_after_fee) =
            new_reserves_after_fees_scaled<Curve>(
                pool.x_reserves,
                pool.y_reserves,
                x_in_val,
                y_in_val,
                pool.fee,
            );
        assert_lp_value_is_increased<Curve>(
            pool.x_scale,
            pool.y_scale,
            (x_reserve_size as u128),
            (y_reserve_size as u128),
            x_res_new_after_fee,
            y_res_new_after_fee,
        );

        // Third of all fees goes into DAO.
        split_fee_to_dao(pool, &fa_res_acc, x_in_val, y_in_val, x_metadata, y_metadata);

        // As we are in same block, don't need to update oracle, it's already updated during flashloan initalization.

        // The pool will be unlocked after payment.
        pool.locked = false;

        let events_store = borrow_global_mut<EventsStore<Curve>>(fa_res_acc_addr);
        event::emit_event(
            &mut events_store.flashloan_handle,
            FlashloanEvent<Curve> {
                x_in: x_in_val,
                x_out: x_loan,
                y_in: y_in_val,
                y_out: y_loan,
                x_metadata: object::object_address(&x_metadata),
                y_metadata: object::object_address(&y_metadata),
            });
    }

    // Private functions.

    /// Get reserves after fees.
    /// * `x_reserve` - reserve X.
    /// * `y_reserve` - reserve Y.
    /// * `x_in_val` - amount of X FA's added to reserves.
    /// * `y_in_val` - amount of Y FA's added to reserves.
    /// * `fee` - amount of fee.
    /// Returns both X and Y reserves after fees.
    fun new_reserves_after_fees_scaled<Curve>(
        x_reserve: u64,
        y_reserve: u64,
        x_in_val: u64,
        y_in_val: u64,
        fee: u64,
    ): (u128, u128) {
        let x_res_new_after_fee = if (curves::is_uncorrelated<Curve>()) {
            math::mul_to_u128(x_reserve, FEE_SCALE) - math::mul_to_u128(x_in_val, fee)
        } else if (curves::is_stable<Curve>()) {
            ((x_reserve - math::mul_div(x_in_val, fee, FEE_SCALE)) as u128)
        } else {
            abort ERR_UNREACHABLE
        };

        let y_res_new_after_fee = if (curves::is_uncorrelated<Curve>()) {
            math::mul_to_u128(y_reserve, FEE_SCALE) - math::mul_to_u128(y_in_val, fee)
        } else if (curves::is_stable<Curve>()) {
            ((y_reserve - math::mul_div(y_in_val, fee, FEE_SCALE)) as u128)
        } else {
            abort ERR_UNREACHABLE
        };

        (x_res_new_after_fee, y_res_new_after_fee)
    }

    /// Depositing part of fees to DAO Storage.
    /// * `pool` - pool to extract FA's.
    /// * `x_in_val` - how much X FA was deposited to pool.
    /// * `y_in_val` - how much Y FA was deposited to pool.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    fun split_fee_to_dao<Curve>(
        pool: &mut LiquidityPool<Curve>,
        fa_res_acc: &signer,
        x_in_val: u64,
        y_in_val: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        let fee_multiplier = pool.fee;
        let dao_fee = pool.dao_fee;
        // Split dao_fee_multiplier% of fee multiplier of provided coins to the DAOStorage
        let dao_fee_multiplier = if (fee_multiplier * dao_fee % DAO_FEE_SCALE != 0) {
            (fee_multiplier * dao_fee / DAO_FEE_SCALE) + 1
        } else {
            fee_multiplier * dao_fee / DAO_FEE_SCALE
        };
        let dao_x_fee_val = math::mul_div(x_in_val, dao_fee_multiplier, FEE_SCALE);
        let dao_y_fee_val = math::mul_div(y_in_val, dao_fee_multiplier, FEE_SCALE);

        // Track virtual reserves changes.
        pool.x_reserves = pool.x_reserves - dao_x_fee_val;
        pool.y_reserves = pool.y_reserves - dao_y_fee_val;

        // Withdraw DAO fee from FA stores.
        let dao_x_in = primary_fungible_store::withdraw(fa_res_acc, x_metadata, dao_x_fee_val);
        let dao_y_in = primary_fungible_store::withdraw(fa_res_acc, y_metadata, dao_y_fee_val);

        dao_storage::deposit<Curve>(dao_x_in, dao_y_in);
    }

    /// Compute and verify LP value after and before swap, in nutshell, _k function.
    /// * `x_scale` - 10 pow by X FA decimals.
    /// * `y_scale` - 10 pow by Y FA decimals.
    /// * `x_res` - X reserves before swap.
    /// * `y_res` - Y reserves before swap.
    /// * `x_res_with_fees` - X reserves after swap.
    /// * `y_res_with_fees` - Y reserves after swap.
    /// Aborts if swap can't be done.
    fun assert_lp_value_is_increased<Curve>(
        x_scale: u64,
        y_scale: u64,
        x_res: u128,
        y_res: u128,
        x_res_with_fees: u128,
        y_res_with_fees: u128,
    ) {
        if (curves::is_stable<Curve>()) {
            let lp_value_before_swap = stable_curve::lp_value(x_res, x_scale, y_res, y_scale);
            let lp_value_after_swap_and_fee = stable_curve::lp_value(x_res_with_fees, x_scale, y_res_with_fees, y_scale);

            assert!(lp_value_after_swap_and_fee > lp_value_before_swap, ERR_INCORRECT_SWAP);
        } else if (curves::is_uncorrelated<Curve>()) {
            let lp_value_before_swap = x_res * y_res;
            let lp_value_before_swap = (lp_value_before_swap as u256) * 100000000; // FEE_SCALE * FEE_SCALE
            let lp_value_after_swap_and_fee = (x_res_with_fees as u256) * (y_res_with_fees as u256);

            assert!(lp_value_after_swap_and_fee > lp_value_before_swap, ERR_INCORRECT_SWAP);
        } else {
            abort ERR_UNREACHABLE
        };
    }

    /// Update current cumulative prices.
    /// Important: If you want to use the following function take into account prices can be overflowed.
    /// So it's important to use same logic in your math/algo (as Move doesn't allow overflow). See math::overflow_add.
    /// * `pool` - Liquidity pool to update prices.
    /// * `x_reserve` - FA X reserves.
    /// * `y_reserve` - FA Y reserves.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    fun update_oracle<Curve>(
        pool: &mut LiquidityPool<Curve>,
        x_reserve: u64,
        y_reserve: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) acquires EventsStore {
        let last_block_timestamp = pool.last_block_timestamp;

        let block_timestamp = timestamp::now_seconds();

        let time_elapsed = ((block_timestamp - last_block_timestamp) as u128);

        if (time_elapsed > 0 && x_reserve != 0 && y_reserve != 0) {
            let last_price_x_cumulative = uq64x64::to_u128(uq64x64::fraction(y_reserve, x_reserve)) * time_elapsed;
            let last_price_y_cumulative = uq64x64::to_u128(uq64x64::fraction(x_reserve, y_reserve)) * time_elapsed;

            pool.last_price_x_cumulative = math::overflow_add(pool.last_price_x_cumulative, last_price_x_cumulative);
            pool.last_price_y_cumulative = math::overflow_add(pool.last_price_y_cumulative, last_price_y_cumulative);

            let fa_res_acc_addr =
                account::get_signer_capability_address(&pool.fa_signer_cap);
            let events_store = borrow_global_mut<EventsStore<Curve>>(fa_res_acc_addr);
            event::emit_event(
                &mut events_store.oracle_updated_handle,
                OracleUpdatedEvent<Curve> {
                    last_price_x_cumulative: pool.last_price_x_cumulative,
                    last_price_y_cumulative: pool.last_price_y_cumulative,
                    x_metadata: object::object_address(&x_metadata),
                    y_metadata: object::object_address(&y_metadata),
                });
        };

        pool.last_block_timestamp = block_timestamp;
    }

    /// Aborts if pool is locked.
    /// * `pool` - pool to extract `locked` state.
    fun assert_pool_unlocked<Curve>(pool: &LiquidityPool<Curve>) {
        assert!(pool.locked == false, ERR_POOL_IS_LOCKED);
    }

    // Getters.

    /// Check if pool is locked.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun is_pool_locked<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): bool acquires LiquidityPool, PoolAccountCapability {
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        let pool_obj_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global<LiquidityPool<Curve>>(pool_obj_addr);
        pool.locked
    }

    /// Get reserves of a pool.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns both (X, Y) reserves.
    public fun get_reserves_size<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) acquires LiquidityPool, PoolAccountCapability {
        assert_no_emergency();
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        let pool_obj_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global<LiquidityPool<Curve>>(pool_obj_addr);

        assert_pool_unlocked(pool);

        (pool.x_reserves, pool.y_reserves)
    }

    /// Get current cumulative prices.
    /// Cumulative prices can be overflowed, so take it into account before work with the following function.
    /// It's important to use same logic in your math/algo (as Move doesn't allow overflow).
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns (X price, Y price, block_timestamp).
    public fun get_cumulative_prices<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u128, u128, u64)
    acquires LiquidityPool, PoolAccountCapability {
        assert_no_emergency();
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        let pool_obj_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        assert!(exists<LiquidityPool<Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let liquidity_pool = borrow_global<LiquidityPool<Curve>>(pool_obj_addr);

        assert_pool_unlocked<Curve>(liquidity_pool);

        let last_price_x_cumulative = *&liquidity_pool.last_price_x_cumulative;
        let last_price_y_cumulative = *&liquidity_pool.last_price_y_cumulative;
        let last_block_timestamp = liquidity_pool.last_block_timestamp;

        (last_price_x_cumulative, last_price_y_cumulative, last_block_timestamp)
    }

    /// Get decimals scales (10^X decimals, 10^Y decimals) for stable curve.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// For uncorrelated curve would return just zeros.
    public fun get_decimals_scales<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) acquires LiquidityPool, PoolAccountCapability {
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        let pool_obj_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        assert!(exists<LiquidityPool<Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global<LiquidityPool<Curve>>(pool_obj_addr);
        (pool.x_scale, pool.y_scale)
    }

    /// Check if liquidity pool exists.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun is_pool_exists<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): bool acquires PoolAccountCapability {
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        let pool_obj_addr = get_pool_addr<Curve>(x_metadata, y_metadata);

        object::object_exists<LiquidityPool<Curve>>(pool_obj_addr)
    }

    /// Get fee for specific pool together with denominator (numerator, denominator).
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun get_fees_config<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) acquires LiquidityPool, PoolAccountCapability {
        (get_fee<Curve>(x_metadata, y_metadata), FEE_SCALE)
    }

    /// Get fee for specific pool.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun get_fee<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 acquires LiquidityPool, PoolAccountCapability {
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<PoolAccountCapability>(@liquidswap_v05), ERR_POOL_DOES_NOT_EXIST);

        let pool_obj_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global<LiquidityPool<Curve>>(pool_obj_addr);
        pool.fee
    }

    /// Set fee for specific pool.
    /// * `fee_admin` - signer, able to set fee.
    /// * `fee` - new fee to set.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public entry fun set_fee<Curve>(
        fee_admin: &signer,
        fee: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<PoolAccountCapability>(@liquidswap_v05), ERR_POOL_DOES_NOT_EXIST);

        let pool_obj_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global_mut<LiquidityPool<Curve>>(pool_obj_addr);
        assert_pool_unlocked<Curve>(pool);

        assert!(signer::address_of(fee_admin) == global_config::get_fee_admin(), ERR_NOT_ADMIN);
        global_config::assert_valid_fee(fee);

        pool.fee = fee;


        let fa_res_acc_addr =
            account::get_signer_capability_address(&pool.fa_signer_cap);
        let events_store = borrow_global_mut<EventsStore<Curve>>(fa_res_acc_addr);
        event::emit_event(
            &mut events_store.update_fee_handle,
            UpdateFeeEvent<Curve> {
                new_fee: fee,
                x_metadata: object::object_address(&x_metadata),
                y_metadata: object::object_address(&y_metadata),
            }
        );
    }

    /// Get DAO fee for specific pool together with denominator (numerator, denominator).
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun get_dao_fees_config<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) acquires LiquidityPool, PoolAccountCapability {
        (get_dao_fee<Curve>(x_metadata, y_metadata), DAO_FEE_SCALE)
    }

    /// Get DAO fee for specific pool.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun get_dao_fee<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 acquires LiquidityPool, PoolAccountCapability {
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<PoolAccountCapability>(@liquidswap_v05), ERR_POOL_DOES_NOT_EXIST);

        let pool_obj_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global<LiquidityPool<Curve>>(pool_obj_addr);
        pool.dao_fee
    }

    /// Set DAO fee for specific pool.
    /// * `fee_admin` - signer, able to set dao fee.
    /// * `dao_fee` - new dao fee to set.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public entry fun set_dao_fee<Curve>(
        fee_admin: &signer,
        dao_fee: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<PoolAccountCapability>(@liquidswap_v05), ERR_POOL_DOES_NOT_EXIST);

        let pool_obj_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global_mut<LiquidityPool<Curve>>(pool_obj_addr);
        assert_pool_unlocked<Curve>(pool);

        assert!(signer::address_of(fee_admin) == global_config::get_fee_admin(), ERR_NOT_ADMIN);
        global_config::assert_valid_dao_fee(dao_fee);

        pool.dao_fee = dao_fee;

        let fa_res_acc_addr =
            account::get_signer_capability_address(&pool.fa_signer_cap);
        let events_store = borrow_global_mut<EventsStore<Curve>>(fa_res_acc_addr);
        event::emit_event(
            &mut events_store.update_dao_fee_handle,
            UpdateDAOFeeEvent<Curve> {
                new_fee: dao_fee,
                x_metadata: object::object_address(&x_metadata),
                y_metadata: object::object_address(&y_metadata),
            }
        );
    }

    #[view]
    /// Returns LiquidityPool object address.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun get_pool_addr<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): address acquires PoolAccountCapability {
        let pool_cap = borrow_global<PoolAccountCapability>(@liquidswap_v05);
        let pool_acc_addr = account::get_signer_capability_address(&pool_cap.signer_cap);
        let pool_obj_name = fa_helper::create_pool_obj_name<Curve>(x_metadata, y_metadata);

        object::create_object_address(&pool_acc_addr, *string::bytes(&pool_obj_name))
    }

    #[view]
    /// Returns LP supply of given pool.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun get_pool_lp_supply<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u128 acquires LiquidityPool, PoolAccountCapability {
        let pool_obj_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        let pool = borrow_global<LiquidityPool<Curve>>(pool_obj_addr);

        fa_helper::fa_supply(pool.lp_metadata)
    }

    #[view]
    /// Returns LP Metadata object of given pool.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun get_pool_lp_metadata<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): Object<Metadata> acquires LiquidityPool, PoolAccountCapability {
        let pool_obj_addr = get_pool_addr<Curve>(x_metadata, y_metadata);
        let pool = borrow_global<LiquidityPool<Curve>>(pool_obj_addr);

        pool.lp_metadata
    }

    // Events
    struct EventsStore<phantom Curve> has key {
        pool_created_handle: event::EventHandle<PoolCreatedEvent<Curve>>,
        liquidity_added_handle: event::EventHandle<LiquidityAddedEvent<Curve>>,
        liquidity_removed_handle: event::EventHandle<LiquidityRemovedEvent<Curve>>,
        swap_handle: event::EventHandle<SwapEvent<Curve>>,
        flashloan_handle: event::EventHandle<FlashloanEvent<Curve>>,
        oracle_updated_handle: event::EventHandle<OracleUpdatedEvent<Curve>>,
        update_fee_handle: event::EventHandle<UpdateFeeEvent<Curve>>,
        update_dao_fee_handle: event::EventHandle<UpdateDAOFeeEvent<Curve>>,
    }

    struct PoolCreatedEvent<phantom Curve> has drop, store {
        creator: address,
        x_metadata: address,
        y_metadata: address,
    }

    struct LiquidityAddedEvent<phantom Curve> has drop, store {
        added_x_val: u64,
        added_y_val: u64,
        lp_tokens_received: u64,
        x_metadata: address,
        y_metadata: address,
    }

    struct LiquidityRemovedEvent<phantom Curve> has drop, store {
        returned_x_val: u64,
        returned_y_val: u64,
        lp_tokens_burned: u64,
        x_metadata: address,
        y_metadata: address,
    }

    struct SwapEvent<phantom Curve> has drop, store {
        x_in: u64,
        x_out: u64,
        y_in: u64,
        y_out: u64,
        x_metadata: address,
        y_metadata: address,
    }

    struct FlashloanEvent<phantom Curve> has drop, store {
        x_in: u64,
        x_out: u64,
        y_in: u64,
        y_out: u64,
        x_metadata: address,
        y_metadata: address,
    }

    struct OracleUpdatedEvent<phantom Curve> has drop, store {
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        x_metadata: address,
        y_metadata: address,
    }

    struct UpdateFeeEvent<phantom Curve> has drop, store {
        new_fee: u64,
        x_metadata: address,
        y_metadata: address,
    }

    struct UpdateDAOFeeEvent<phantom Curve> has drop, store {
        new_fee: u64,
        x_metadata: address,
        y_metadata: address,
    }

    #[test_only]
    public fun compute_and_verify_lp_value_for_test<Curve>(
        x_scale: u64,
        y_scale: u64,
        x_res: u128,
        y_res: u128,
        x_res_new: u128,
        y_res_new: u128,
    ) {
        assert_lp_value_is_increased<Curve>(
            x_scale,
            y_scale,
            x_res,
            y_res,
            x_res_new,
            y_res_new,
        )
    }

    #[test_only]
    public fun update_cumulative_price_for_test(
        test_account: &signer,
        prev_last_block_timestamp: u64,
        prev_last_price_x_cumulative: u128,
        prev_last_price_y_cumulative: u128,
        x_reserve: u64,
        y_reserve: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u128, u128, u64) acquires EventsStore, LiquidityPool, PoolAccountCapability {
        register<curves::Uncorrelated>(test_account, x_metadata, y_metadata);

        let pool_obj_addr = get_pool_addr<curves::Uncorrelated>(x_metadata, y_metadata);
        assert!(exists<LiquidityPool<curves::Uncorrelated>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool =
            borrow_global_mut<LiquidityPool<curves::Uncorrelated>>(pool_obj_addr);
        pool.last_block_timestamp = prev_last_block_timestamp;
        pool.last_price_x_cumulative = prev_last_price_x_cumulative;
        pool.last_price_y_cumulative = prev_last_price_y_cumulative;

        update_oracle(pool, x_reserve, y_reserve, x_metadata, y_metadata);

        (pool.last_price_x_cumulative, pool.last_price_y_cumulative, pool.last_block_timestamp)
    }

    #[test_only]
    public fun get_reserved_value<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 acquires LiquidityPool, PoolAccountCapability {
        let pool_obj_addr = get_pool_addr<curves::Uncorrelated>(x_metadata, y_metadata);
        let pool = borrow_global_mut<LiquidityPool<Curve>>(pool_obj_addr);

        let fa_res_acc_addr =
            account::get_signer_capability_address(&pool.fa_signer_cap);

        let lp_metadata = get_pool_lp_metadata<Curve>(x_metadata, y_metadata);
        primary_fungible_store::balance(fa_res_acc_addr, lp_metadata)
    }
}
