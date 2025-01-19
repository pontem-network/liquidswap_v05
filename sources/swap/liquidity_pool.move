/// Liquidswap liquidity pool module.
/// Implements mint/burn liquidity, swap of coins.
module liquidswap_v05::liquidity_pool {
    use std::signer;
    use std::string;

    use aptos_std::event;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::object;
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use liquidswap_lp::lp_coin::LP;
    use uq64x64::uq64x64;

    use liquidswap_v05::coin_helper;
    use liquidswap_v05::curves;
    use liquidswap_v05::dao_storage;
    use liquidswap_v05::emergency::{Self, assert_no_emergency};
    use liquidswap_v05::global_config;
    use liquidswap_v05::lp_account;
    use liquidswap_v05::math;
    use liquidswap_v05::stable_curve;

    // Error codes.

    /// When coins used to create pair have wrong ordering.
    const ERR_WRONG_PAIR_ORDERING: u64 = 100;

    /// When pair already exists on account.
    const ERR_POOL_EXISTS_FOR_PAIR: u64 = 101;

    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_INITIAL_LIQUIDITY: u64 = 102;

    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_LIQUIDITY: u64 = 103;

    /// When both X and Y provided for swap are equal zero.
    const ERR_EMPTY_COIN_IN: u64 = 104;

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
    const ERR_EMPTY_COIN_LOAN: u64 = 110;

    /// When pool is locked.
    const ERR_POOL_IS_LOCKED: u64 = 111;

    /// When user is not admin.
    const ERR_NOT_ADMIN: u64 = 112;

    /// When user returns flashloan to wrong pool.
    const ERR_WRONG_POOL: u64 = 113;

    // Constants.

    /// Minimal liquidity.
    const MINIMAL_LIQUIDITY: u64 = 1000;

    /// Denominator to handle decimal points for fees.
    const FEE_SCALE: u64 = 10000;

    /// Denominator to handle decimal points for dao fee.
    const DAO_FEE_SCALE: u64 = 100;

    // Public functions.

    /// Liquidity pool with reserve metadatas.
    struct LiquidityPool<phantom X, phantom Y, phantom Curve> has key {
        //todo: move this?
        fa_signer_cap: SignerCapability,

        fa_x_metadata: address,
        fa_y_metadata: address,

        last_block_timestamp: u64,
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
        lp_mint_cap: coin::MintCapability<LP<X, Y, Curve>>,
        lp_burn_cap: coin::BurnCapability<LP<X, Y, Curve>>,
        lp_coins_reserved: coin::Coin<LP<X, Y, Curve>>,
        // Scales are pow(10, token_decimals).
        x_scale: u64,
        y_scale: u64,
        locked: bool,
        fee: u64,           // 1 - 100 (0.01% - 1%)
        dao_fee: u64,       // 0 - 100 (0% - 100%)
    }

    // todo: rework description
    /// Flash loan resource.
    /// There is no way in Move to pass calldata and make dynamic calls, but a resource can be used for this purpose.
    /// To make the execution into a single transaction, the flash loan function must return a resource
    /// that cannot be copied, cannot be saved, cannot be dropped, or cloned.
    struct Flashloan<phantom Curve> {
        x_loan: u64,
        y_loan: u64,
        attached_pool_addr: address,
    }

    /// Stores resource account signer capability under Liquidswap account.
    struct PoolAccountCapability has key { signer_cap: SignerCapability }

    /// Initializes Liquidswap contracts.
    public entry fun initialize(liquidswap_admin: &signer) {
        assert!(signer::address_of(liquidswap_admin) == @liquidswap_v05, ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE);

        let signer_cap = lp_account::retrieve_signer_cap(liquidswap_admin);
        move_to(liquidswap_admin, PoolAccountCapability { signer_cap });

        global_config::initialize(liquidswap_admin);
        // todo: check in pool init test that dao resource created
        dao_storage::initialize(liquidswap_admin);
        emergency::initialize(liquidswap_admin);
    }

    // todo: where to paste this func?
    // todo: descr
    fun get_pool_addr<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): address acquires PoolAccountCapability {
        let pool_cap = borrow_global<PoolAccountCapability>(@liquidswap_v05);
        let pool_acc_addr = account::get_signer_capability_address(&pool_cap.signer_cap);
        let pool_obj_name = coin_helper::create_pool_obj_name<Curve>(x_metadata, y_metadata);

        object::create_object_address(&pool_acc_addr, *string::bytes(&pool_obj_name))
    }

    /// Register liquidity pool `X`/`Y`.
    public fun register<X, Y, Curve>(
        acc: &signer,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) acquires PoolAccountCapability {
        // todo: same metadata handle?
        // todo: check symbols differ, should differ due to the later on primary fungible store seed creation <--------------------

        assert_no_emergency();

        // todo: some check is it fungable asset here
        // todo: seems if we pass Metadata it's always FA
        // todo: remove this lines after check that Metadata cannot exist separate from FA
        // coin_helper::assert_is_coin<X>();
        // coin_helper::assert_is_coin<Y>();

        // todo: coin_helper => fa_helper
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        curves::assert_valid_curve<Curve>();
        assert!(!is_pool_exists<X, Y, Curve>(x_metadata, y_metadata), ERR_POOL_EXISTS_FOR_PAIR);

        let pool_cap = borrow_global<PoolAccountCapability>(@liquidswap_v05);
        let pool_account = account::create_signer_with_capability(&pool_cap.signer_cap);

        let (lp_name, lp_symbol) = coin_helper::fa_generate_lp_name_and_symbol<Curve>(x_metadata, y_metadata);
        let (lp_burn_cap, lp_freeze_cap, lp_mint_cap) =
            coin::initialize<LP<X, Y, Curve>>(
                &pool_account,
                lp_name,
                lp_symbol,
                6,
                true
            );
        coin::destroy_freeze_cap(lp_freeze_cap);

        let x_scale = 0;
        let y_scale = 0;

        if (curves::is_stable<Curve>()) {
            x_scale = math::pow_10(fungible_asset::decimals(x_metadata));
            y_scale = math::pow_10(fungible_asset::decimals(y_metadata));
        };

        // Create fungible stores for X and Y FA's.
        // todo: print obj than addr here to check
        // todo: edit seed to use curve etc
        // todo: add seed generator helper here
        // todo: disable obj transfer ability. May be there is other abilities like burn. Recheck.
        let pool_obj_name =
            string::bytes(&coin_helper::create_pool_obj_name<Curve>(x_metadata, y_metadata));
        let (fa_res_acc, fa_sig_cap) =
            account::create_resource_account(&pool_account,*pool_obj_name);
        let fa_res_acc_addr = signer::address_of(&fa_res_acc);

        // todo: add check in register tests <================================
        primary_fungible_store::create_primary_store(fa_res_acc_addr, x_metadata);
        primary_fungible_store::create_primary_store(fa_res_acc_addr, y_metadata);

        let pool = LiquidityPool<X, Y, Curve> {
            // todo: remove fa_signer from here or at all?
            fa_signer_cap: fa_sig_cap,
            fa_x_metadata: object::object_address(&x_metadata),
            fa_y_metadata: object::object_address(&y_metadata),
            last_block_timestamp: 0,
            last_price_x_cumulative: 0,
            last_price_y_cumulative: 0,
            lp_mint_cap,
            lp_burn_cap,
            lp_coins_reserved: coin::zero(),
            x_scale,
            y_scale,
            locked: false,
            fee: global_config::get_default_fee<Curve>(),
            dao_fee: global_config::get_default_dao_fee(),
        };
        // todo: check pool_account usage. Do we need it?
        // todo: this line was old pool with generics storing
        // move_to(&pool_account, pool);

        // todo: disable obj transfer ability. May be there is other abilities like burn. Recheck.
        let pool_constructor_ref = object::create_named_object(&pool_account, *pool_obj_name);
        let pool_signer = object::generate_signer(&pool_constructor_ref);
        move_to(&pool_signer, pool);

        dao_storage::register<Curve>(&pool_account, x_metadata, y_metadata);

        let events_store = EventsStore<X, Y, Curve> {
            pool_created_handle: account::new_event_handle(&pool_account),
            liquidity_added_handle: account::new_event_handle(&pool_account),
            liquidity_removed_handle: account::new_event_handle(&pool_account),
            swap_handle: account::new_event_handle(&pool_account),
            flashloan_handle: account::new_event_handle(&pool_account),
            oracle_updated_handle: account::new_event_handle(&pool_account),
            update_fee_handle: account::new_event_handle(&pool_account),
            update_dao_fee_handle: account::new_event_handle(&pool_account),
        };
        // todo: change event to contain obj data? thre would not be X Y generics anymore
        event::emit_event(
            &mut events_store.pool_created_handle,
            PoolCreatedEvent<X, Y, Curve> {
                creator: signer::address_of(acc)
            },
        );
        move_to(&pool_account, events_store);
    }

    // todo: update description
    /// Mint new liquidity coins.
    /// * `coin_x` - coin X to add to liquidity reserves.
    /// * `coin_y` - coin Y to add to liquidity reserves.
    /// Returns LP coins: `Coin<LP<X, Y, Curve>>`.
    public fun mint<X, Y, Curve>(fa_x: FungibleAsset, fa_y: FungibleAsset): Coin<LP<X, Y, Curve>>
    acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert_no_emergency();

        let x_metadata = fungible_asset::metadata_from_asset(&fa_x);
        let y_metadata = fungible_asset::metadata_from_asset(&fa_y);
        // todo: coin_helper => fa_helper
        // todo: test this case?
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        assert!(is_pool_exists<X, Y, Curve>(x_metadata, y_metadata), ERR_POOL_DOES_NOT_EXIST);

        let lp_coins_total = coin_helper::supply<LP<X, Y, Curve>>();

        let pool_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(pool_addr);

        // todo: test assert after move from above
        assert_pool_unlocked<X, Y, Curve>(pool);

        let fa_res_acc_addr =
            account::get_signer_capability_address(&pool.fa_signer_cap);

        let x_reserve_size = primary_fungible_store::balance(fa_res_acc_addr, x_metadata);
        let y_reserve_size = primary_fungible_store::balance(fa_res_acc_addr, y_metadata);

        let x_provided_val = fungible_asset::amount(&fa_x);
        let y_provided_val = fungible_asset::amount(&fa_y);

        let provided_liq = if (lp_coins_total == 0) {
            let initial_liq = math::sqrt(math::mul_to_u128(x_provided_val, y_provided_val));
            assert!(initial_liq > MINIMAL_LIQUIDITY, ERR_NOT_ENOUGH_INITIAL_LIQUIDITY);

            let lp_reserved_coins = coin::mint<LP<X, Y, Curve>>(MINIMAL_LIQUIDITY, &pool.lp_mint_cap);
            coin::merge(&mut pool.lp_coins_reserved, lp_reserved_coins);

            initial_liq - MINIMAL_LIQUIDITY
        } else {
            let x_liq = math::mul_div_u128((x_provided_val as u128), lp_coins_total, (x_reserve_size as u128));
            let y_liq = math::mul_div_u128((y_provided_val as u128), lp_coins_total, (y_reserve_size as u128));
            if (x_liq < y_liq) {
                x_liq
            } else {
                y_liq
            }
        };
        assert!(provided_liq > 0, ERR_NOT_ENOUGH_LIQUIDITY);

        // Deposit into fungible stores of X and Y FA's.
        // todo: add check in mint tests <================================
        primary_fungible_store::deposit(fa_res_acc_addr, fa_x);
        primary_fungible_store::deposit(fa_res_acc_addr, fa_y);

        let lp_coins = coin::mint<LP<X, Y, Curve>>(provided_liq, &pool.lp_mint_cap);

        update_oracle<X, Y, Curve>(pool, x_reserve_size, y_reserve_size);

        // todo: update event to display FA indo
        let events_store = borrow_global_mut<EventsStore<X, Y, Curve>>(@liquidswap_pool_account);
        event::emit_event(
            &mut events_store.liquidity_added_handle,
            LiquidityAddedEvent<X, Y, Curve> {
                added_x_val: x_provided_val,
                added_y_val: y_provided_val,
                lp_tokens_received: provided_liq
            });

        lp_coins
    }

    // todo: upd descr
    /// Burn liquidity coins (LP) and get back X and Y coins from reserves.
    /// * `lp_coins` - LP coins to burn.
    /// Returns both X and Y coins - `(Coin<X>, Coin<Y>)`.
    public fun burn<X, Y, Curve>(
        lp_coins: Coin<LP<X, Y, Curve>>,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (FungibleAsset, FungibleAsset)
    acquires LiquidityPool, PoolAccountCapability, EventsStore {
        // todo: where is emergency assert?

        // todo: seems we have to check that LP's are attached to current pool.
        // todo: after LP's rework add that ^ test.

        // todo: coin_helper => fa_helper
        // todo: test this case?
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        // todo: maybe store x and y FA's metadata in LP FA metadata so no need to provide metadata args when burn?
        assert!(is_pool_exists<X, Y, Curve>(x_metadata, y_metadata), ERR_POOL_DOES_NOT_EXIST);

        let burned_lp_coins_val = coin::value(&lp_coins);

        let pool_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(pool_addr);

       // todo: test assert after move from above
        assert_pool_unlocked<X, Y, Curve>(pool);

        let lp_coins_total = coin_helper::supply<LP<X, Y, Curve>>();

        let fa_res_acc =
            account::create_signer_with_capability(&pool.fa_signer_cap);
        let fa_res_acc_addr = signer::address_of(&fa_res_acc);

        let x_reserve_val = primary_fungible_store::balance(fa_res_acc_addr, x_metadata);
        let y_reserve_val = primary_fungible_store::balance(fa_res_acc_addr, y_metadata);

        // Compute x, y coin values for provided lp_coins value
        let x_to_return_val =
            math::mul_div_u128((burned_lp_coins_val as u128), (x_reserve_val as u128), lp_coins_total);
        let y_to_return_val =
            math::mul_div_u128((burned_lp_coins_val as u128), (y_reserve_val as u128), lp_coins_total);
        assert!(x_to_return_val > 0 && y_to_return_val > 0, ERR_INCORRECT_BURN_VALUES);

        // todo: check that provided LP FA are attached to x\y FA's?
        // Withdraw those values from reserves
        // let fa_signer = account::create_signer_with_capability(&pool.fa_signer_cap);

        // let fa_x_metadata_obj = fungible_asset::store_metadata(object::address_to_object<Metadata>(pool.fa_x_metadata));
        // let fa_y_metadata_obj = fungible_asset::store_metadata(object::address_to_object<Metadata>(pool.fa_y_metadata));
        // std::debug::print(&aptos_std::string_utils::format1(&b"================> fa_x_metadata_obj = {}", fa_x_metadata_obj));

        // Withdraw from fungible stores of X and Y FA's.
        // todo: add check in burn tests <================================
        let x_fa_to_return = primary_fungible_store::withdraw(&fa_res_acc, x_metadata, x_to_return_val);
        let y_fa_to_return = primary_fungible_store::withdraw(&fa_res_acc, y_metadata, y_to_return_val);

        // todo: recheck oracle correctness
        update_oracle<X, Y, Curve>(pool, x_reserve_val, y_reserve_val);
        coin::burn(lp_coins, &pool.lp_burn_cap);

        // todo: upd event too display FA like info
        let events_store = borrow_global_mut<EventsStore<X, Y, Curve>>(@liquidswap_pool_account);
        event::emit_event(
            &mut events_store.liquidity_removed_handle,
            LiquidityRemovedEvent<X, Y, Curve> {
                returned_x_val: x_to_return_val,
                returned_y_val: y_to_return_val,
                lp_tokens_burned: burned_lp_coins_val
            });

        (x_fa_to_return, y_fa_to_return)
    }

    // todo: upd descr
    /// Swap coins (can swap both x and y in the same time).
    /// In the most of situation only X or Y coin argument has value (similar with *_out, only one _out will be non-zero).
    /// Because an user usually exchanges only one coin, yet function allow to exchange both coin.
    /// * `x_in` - X coins to swap.
    /// * `x_out` - expected amount of X coins to get out.
    /// * `y_in` - Y coins to swap.
    /// * `y_out` - expected amount of Y coins to get out.
    /// Returns both exchanged X and Y coins: `(Coin<X>, Coin<Y>)`.
    public fun swap<X, Y, Curve>(
        x_in: FungibleAsset,
        x_out: u64,
        y_in: FungibleAsset,
        y_out: u64
    ): (FungibleAsset, FungibleAsset) acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert_no_emergency();

        let x_metadata = fungible_asset::metadata_from_asset(&x_in);
        let y_metadata = fungible_asset::metadata_from_asset(&y_in);

        // todo: coin_helper => fa_helper
        // todo: test this case?
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        assert!(is_pool_exists<X, Y, Curve>(x_metadata, y_metadata), ERR_POOL_DOES_NOT_EXIST);

        let pool_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(pool_addr);

       // todo: test assert after move from above
        assert_pool_unlocked<X, Y, Curve>(pool);

        let x_in_val = fungible_asset::amount(&x_in);
        let y_in_val = fungible_asset::amount(&y_in);

        assert!(x_in_val > 0 || y_in_val > 0, ERR_EMPTY_COIN_IN);

        let fa_res_acc =
            account::create_signer_with_capability(&pool.fa_signer_cap);
        let fa_res_acc_addr = signer::address_of(&fa_res_acc);

        let x_reserve_size = primary_fungible_store::balance(fa_res_acc_addr, x_metadata);
        let y_reserve_size = primary_fungible_store::balance(fa_res_acc_addr, y_metadata);

        // Deposit new FA's into fungible stores of X and Y.
        // todo: add check in swap tests <================================
        primary_fungible_store::deposit(fa_res_acc_addr, x_in);
        primary_fungible_store::deposit(fa_res_acc_addr, y_in);

        // Withdraw expected amount from fungible stores of X and Y FA's.
        // todo: add check in swap tests <================================
        let x_swapped = primary_fungible_store::withdraw(&fa_res_acc, x_metadata, x_out);
        let y_swapped = primary_fungible_store::withdraw(&fa_res_acc, y_metadata, y_out);

        // Confirm that lp_value for the pool hasn't been reduced.
        // For that, we compute lp_value with old reserves and lp_value with reserves after swap is done,
        // and make sure lp_value doesn't decrease
        let (x_res_new_after_fee, y_res_new_after_fee) =
            new_reserves_after_fees_scaled<Curve>(
                primary_fungible_store::balance(fa_res_acc_addr, x_metadata),
                primary_fungible_store::balance(fa_res_acc_addr, y_metadata),
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

        // todo: ADD CHECK FOR DAO FA'S STORES
        split_fee_to_dao(pool, &fa_res_acc, x_in_val, y_in_val, x_metadata, y_metadata);

        update_oracle<X, Y, Curve>(pool, x_reserve_size, y_reserve_size);

        // todo: upd event with FA staff
        let events_store = borrow_global_mut<EventsStore<X, Y, Curve>>(@liquidswap_pool_account);
        event::emit_event(
            &mut events_store.swap_handle,
            SwapEvent<X, Y, Curve> {
                x_in: x_in_val,
                y_in: y_in_val,
                x_out,
                y_out,
            });

        // Return swapped amount.
        (x_swapped, y_swapped)
    }

    // todo: upd description
    /// Get flash loan coins.
    /// In the most of situation only X or Y coin argument has value.
    /// Because an user usually loans only one coin, yet function allow to loans both coin.
    /// * `x_loan` - expected amount of X coins to loan.
    /// * `y_loan` - expected amount of Y coins to loan.
    /// Returns both loaned X and Y coins: `(Coin<X>, Coin<Y>, Flashloan<X, Y>)`.
    public fun flashloan<X, Y, Curve>(
        x_loan: u64,
        y_loan: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (FungibleAsset, FungibleAsset, Flashloan<Curve>)
    acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert_no_emergency();

        // todo: HERE IS NO TEST FOR THIS CASE
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(is_pool_exists<X, Y, Curve>(x_metadata, y_metadata), ERR_POOL_DOES_NOT_EXIST);

        let pool_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(pool_addr);

        // todo: test assert after move from above
        assert_pool_unlocked<X, Y, Curve>(pool);
        assert!(x_loan > 0 || y_loan > 0, ERR_EMPTY_COIN_LOAN);

        let fa_res_acc =
            account::create_signer_with_capability(&pool.fa_signer_cap);
        let fa_res_acc_addr = signer::address_of(&fa_res_acc);

        let reserve_x = primary_fungible_store::balance(fa_res_acc_addr, x_metadata);
        let reserve_y = primary_fungible_store::balance(fa_res_acc_addr, y_metadata);

        // Withdraw expected amount  from fungible stores of X and Y FA's.
        // todo: add check in flashloan tests <================================
        let x_loaned = primary_fungible_store::withdraw(&fa_res_acc, x_metadata, x_loan);
        let y_loaned = primary_fungible_store::withdraw(&fa_res_acc, y_metadata, y_loan);

        // The pool will be locked after the loan until payment.
        pool.locked = true;

        update_oracle(pool, reserve_x, reserve_y);

        // Return loaned amount.
        (x_loaned, y_loaned, Flashloan<Curve> { x_loan, y_loan, attached_pool_addr: pool_addr })
    }

    // todo: upd descr
    /// Pay flash loan coins.
    /// In the most of situation only X or Y coin argument has value.
    /// Because an user usually loans only one coin, yet function allow to loans both coin.
    /// * `x_in` - X coins to pay.
    /// * `y_in` - Y coins to pay.
    /// * `loan` - data about flashloan.
    public fun pay_flashloan<X, Y, Curve>(
        x_in: FungibleAsset,
        y_in: FungibleAsset,
        loan: Flashloan<Curve>
    ) acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert_no_emergency();

        let x_metadata = fungible_asset::metadata_from_asset(&x_in);
        let y_metadata = fungible_asset::metadata_from_asset(&y_in);

        // todo: HERE IS NO TEST FOR THIS CASE
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(is_pool_exists<X, Y, Curve>(x_metadata, y_metadata), ERR_POOL_DOES_NOT_EXIST);

        let pool_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(pool_addr);

        let Flashloan { x_loan, y_loan, attached_pool_addr } = loan;

        // todo: TEST this!
        assert!(pool_addr == attached_pool_addr, ERR_WRONG_POOL);

        let x_in_val = fungible_asset::amount(&x_in);
        let y_in_val = fungible_asset::amount(&y_in);

        assert!(x_in_val > 0 || y_in_val > 0, ERR_EMPTY_COIN_IN);

        let fa_res_acc =
            account::create_signer_with_capability(&pool.fa_signer_cap);
        let fa_res_acc_addr = signer::address_of(&fa_res_acc);

        let x_reserve_size = primary_fungible_store::balance(fa_res_acc_addr, x_metadata);
        let y_reserve_size = primary_fungible_store::balance(fa_res_acc_addr, y_metadata);

        // Reserve sizes before loan out
        x_reserve_size = x_reserve_size + x_loan;
        y_reserve_size = y_reserve_size + y_loan;

        // Deposit into fungible stores of X and Y FA's.
        // todo: add check in flashloan tests <================================
        primary_fungible_store::deposit(fa_res_acc_addr, x_in);
        primary_fungible_store::deposit(fa_res_acc_addr, y_in);

        // Confirm that lp_value for the pool hasn't been reduced.
        // For that, we compute lp_value with old reserves and lp_value with reserves after swap is done,
        // and make sure lp_value doesn't decrease
        let (x_res_new_after_fee, y_res_new_after_fee) =
            new_reserves_after_fees_scaled<Curve>(
                primary_fungible_store::balance(fa_res_acc_addr, x_metadata),
                primary_fungible_store::balance(fa_res_acc_addr, y_metadata),
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
        // todo: ADD CHECK FOR DAO FA'S STORES?
        split_fee_to_dao(pool, &fa_res_acc, x_in_val, y_in_val, x_metadata, y_metadata);

        // As we are in same block, don't need to update oracle, it's already updated during flashloan initalization.

        // The pool will be unlocked after payment.
        pool.locked = false;

        // todo: upd event
        let events_store = borrow_global_mut<EventsStore<X, Y, Curve>>(@liquidswap_pool_account);
        event::emit_event(
            &mut events_store.flashloan_handle,
            FlashloanEvent<X, Y, Curve> {
                x_in: x_in_val,
                x_out: x_loan,
                y_in: y_in_val,
                y_out: y_loan,
            });
    }

    // Private functions.

    /// Get reserves after fees.
    /// * `x_reserve` - reserve X.
    /// * `y_reserve` - reserve Y.
    /// * `x_in_val` - amount of X coins added to reserves.
    /// * `y_in_val` - amount of Y coins added to reserves.
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

    // todo: update description
    /// Depositing part of fees to DAO Storage.
    /// * `pool` - pool to extract coins.
    /// * `x_in_val` - how much X coins was deposited to pool.
    /// * `y_in_val` - how much Y coins was deposited to pool.
    fun split_fee_to_dao<X, Y, Curve>(
        pool: &mut LiquidityPool<X, Y, Curve>,
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

        // Withdraw DAO fee from FA stores.
        // todo: add check in SWAP DAO FEE tests <================================
        let dao_x_in = primary_fungible_store::withdraw(fa_res_acc, x_metadata, dao_x_fee_val);
        let dao_y_in = primary_fungible_store::withdraw(fa_res_acc, y_metadata, dao_y_fee_val);

        dao_storage::deposit<Curve>(@liquidswap_pool_account, dao_x_in, dao_y_in);
    }

    /// Compute and verify LP value after and before swap, in nutshell, _k function.
    /// * `x_scale` - 10 pow by X coin decimals.
    /// * `y_scale` - 10 pow by Y coin decimals.
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
    /// * `x_reserve` - coin X reserves.
    /// * `y_reserve` - coin Y reserves.
    fun update_oracle<X, Y, Curve>(
        pool: &mut LiquidityPool<X, Y, Curve>,
        x_reserve: u64,
        y_reserve: u64
    ) acquires EventsStore {
        let last_block_timestamp = pool.last_block_timestamp;

        let block_timestamp = timestamp::now_seconds();

        let time_elapsed = ((block_timestamp - last_block_timestamp) as u128);

        if (time_elapsed > 0 && x_reserve != 0 && y_reserve != 0) {
            let last_price_x_cumulative = uq64x64::to_u128(uq64x64::fraction(y_reserve, x_reserve)) * time_elapsed;
            let last_price_y_cumulative = uq64x64::to_u128(uq64x64::fraction(x_reserve, y_reserve)) * time_elapsed;

            pool.last_price_x_cumulative = math::overflow_add(pool.last_price_x_cumulative, last_price_x_cumulative);
            pool.last_price_y_cumulative = math::overflow_add(pool.last_price_y_cumulative, last_price_y_cumulative);

            // todo: upd event to FA style
            let events_store = borrow_global_mut<EventsStore<X, Y, Curve>>(@liquidswap_pool_account);
            event::emit_event(
                &mut events_store.oracle_updated_handle,
                OracleUpdatedEvent<X, Y, Curve> {
                    last_price_x_cumulative: pool.last_price_x_cumulative,
                    last_price_y_cumulative: pool.last_price_y_cumulative,
                });
        };

        pool.last_block_timestamp = block_timestamp;
    }

    // todo: update descr
    /// Aborts if pool is locked.
    fun assert_pool_unlocked<X, Y, Curve>(pool: &LiquidityPool<X, Y, Curve>) {
        assert!(pool.locked == false, ERR_POOL_IS_LOCKED);
    }

    // Getters.

    // todo: update descr
    /// Check if pool is locked.
    public fun is_pool_locked<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): bool acquires LiquidityPool, PoolAccountCapability {
        // todo: coin_helper => fa_helper?
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        // todo: remove PoolAccountCapability usage?
        let pool_obj_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<X, Y, Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global<LiquidityPool<X, Y, Curve>>(pool_obj_addr);
        pool.locked
    }

    /// Get reserves of a pool.
    /// Returns both (X, Y) reserves.
    public fun get_reserves_size<X, Y, Curve>(x_metadata: Object<Metadata>, y_metadata: Object<Metadata>): (u64, u64)
    acquires LiquidityPool, PoolAccountCapability {
        assert_no_emergency();

        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        // todo: remove PoolAccountCapability usage?
        let pool_obj_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<X, Y, Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let liquidity_pool = borrow_global<LiquidityPool<X, Y, Curve>>(pool_obj_addr);

        // todo: test after move of this line?
        assert_pool_unlocked(liquidity_pool);

        let fa_res_acc_addr =
            account::get_signer_capability_address(&liquidity_pool.fa_signer_cap);

        let x_reserve = primary_fungible_store::balance(fa_res_acc_addr, x_metadata);
        let y_reserve = primary_fungible_store::balance(fa_res_acc_addr, y_metadata);

        (x_reserve, y_reserve)
    }

    // todo: update descr
    /// Get current cumulative prices.
    /// Cumulative prices can be overflowed, so take it into account before work with the following function.
    /// It's important to use same logic in your math/algo (as Move doesn't allow overflow).
    /// Returns (X price, Y price, block_timestamp).
    public fun get_cumulative_prices<X, Y, Curve>(x_metadata: Object<Metadata>, y_metadata: Object<Metadata>): (u128, u128, u64)
    acquires LiquidityPool, PoolAccountCapability {
        assert_no_emergency();

        // todo: coin_helper => fa_helper?
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        // todo: remove PoolAccountCapability usage?
        let pool_obj_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        assert!(exists<LiquidityPool<X, Y, Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let liquidity_pool = borrow_global<LiquidityPool<X, Y, Curve>>(pool_obj_addr);
        // todo: test after line move from above
        assert_pool_unlocked<X, Y, Curve>(liquidity_pool);

        let last_price_x_cumulative = *&liquidity_pool.last_price_x_cumulative;
        let last_price_y_cumulative = *&liquidity_pool.last_price_y_cumulative;
        let last_block_timestamp = liquidity_pool.last_block_timestamp;

        (last_price_x_cumulative, last_price_y_cumulative, last_block_timestamp)
    }

    // todo: upd descr
    /// Get decimals scales (10^X decimals, 10^Y decimals) for stable curve.
    /// For uncorrelated curve would return just zeros.
    public fun get_decimals_scales<X, Y, Curve>(x_metadata: Object<Metadata>, y_metadata: Object<Metadata>): (u64, u64)
    acquires LiquidityPool, PoolAccountCapability {
        // todo: coin_helper => fa_helper?
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        // todo: remove PoolAccountCapability usage?
        let pool_obj_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        assert!(exists<LiquidityPool<X, Y, Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global<LiquidityPool<X, Y, Curve>>(pool_obj_addr);
        (pool.x_scale, pool.y_scale)
    }

    /// Check if liquidity pool exists.
    public fun is_pool_exists<X, Y, Curve>(x_metadata: Object<Metadata>, y_metadata: Object<Metadata>): bool
    acquires PoolAccountCapability {
        // todo: coin_helper => fa_helper
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);

        let pool_obj_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);

        object::object_exists<LiquidityPool<X, Y, Curve>>(pool_obj_addr)
    }

    // todo: upd descr
    /// Get fee for specific pool together with denominator (numerator, denominator).
    public fun get_fees_config<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) acquires LiquidityPool, PoolAccountCapability {
        (get_fee<X, Y, Curve>(x_metadata, y_metadata), FEE_SCALE)
    }

    // todo: update descr
    /// Get fee for specific pool.
    public fun get_fee<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 acquires LiquidityPool, PoolAccountCapability {
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<PoolAccountCapability>(@liquidswap_v05), ERR_POOL_DOES_NOT_EXIST);

        let pool_obj_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<X, Y, Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global<LiquidityPool<X, Y, Curve>>(pool_obj_addr);
        pool.fee
    }

    // todo: upd params in description
    /// Set fee for specific pool.
    public entry fun set_fee<X, Y, Curve>(
        fee_admin: &signer,
        fee: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) acquires LiquidityPool, PoolAccountCapability, EventsStore {
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<PoolAccountCapability>(@liquidswap_v05), ERR_POOL_DOES_NOT_EXIST);

        let pool_obj_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<X, Y, Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(pool_obj_addr);
        assert_pool_unlocked<X, Y, Curve>(pool);

        assert!(signer::address_of(fee_admin) == global_config::get_fee_admin(), ERR_NOT_ADMIN);
        global_config::assert_valid_fee(fee);

        pool.fee = fee;

        // todo: upd event to FA style
        let events_store = borrow_global_mut<EventsStore<X, Y, Curve>>(@liquidswap_pool_account);
        event::emit_event(
            &mut events_store.update_fee_handle,
            UpdateFeeEvent<X, Y, Curve> { new_fee: fee }
        );
    }

    // todo: upd descr
    /// Get DAO fee for specific pool together with denominator (numerator, denominator).
    public fun get_dao_fees_config<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) acquires LiquidityPool, PoolAccountCapability {
        (get_dao_fee<X, Y, Curve>(x_metadata, y_metadata), DAO_FEE_SCALE)
    }

    // todo: upd descr
    /// Get DAO fee for specific pool.
    public fun get_dao_fee<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 acquires LiquidityPool, PoolAccountCapability {
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<PoolAccountCapability>(@liquidswap_v05), ERR_POOL_DOES_NOT_EXIST);

        let pool_obj_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<X, Y, Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global<LiquidityPool<X, Y, Curve>>(pool_obj_addr);
        pool.dao_fee
    }

    // todo: upd descr
    /// Set DAO fee for specific pool.
    public entry fun set_dao_fee<X, Y, Curve>(
        fee_admin: &signer,
        dao_fee: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) acquires LiquidityPool, PoolAccountCapability, EventsStore {
        // todo: recheck fa sorted test exists
        assert!(coin_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_PAIR_ORDERING);
        assert!(exists<PoolAccountCapability>(@liquidswap_v05), ERR_POOL_DOES_NOT_EXIST);

        let pool_obj_addr = get_pool_addr<X, Y, Curve>(x_metadata, y_metadata);
        assert!(object::object_exists<LiquidityPool<X, Y, Curve>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool = borrow_global_mut<LiquidityPool<X, Y, Curve>>(pool_obj_addr);
        assert_pool_unlocked<X, Y, Curve>(pool);

        assert!(signer::address_of(fee_admin) == global_config::get_fee_admin(), ERR_NOT_ADMIN);
        global_config::assert_valid_dao_fee(dao_fee);

        pool.dao_fee = dao_fee;

        // todo: upd event FA style
        let events_store = borrow_global_mut<EventsStore<X, Y, Curve>>(@liquidswap_pool_account);
        event::emit_event(
            &mut events_store.update_dao_fee_handle,
            UpdateDAOFeeEvent<X, Y, Curve> { new_fee: dao_fee }
        );
    }

    // Events
    struct EventsStore<phantom X, phantom Y, phantom Curve> has key {
        pool_created_handle: event::EventHandle<PoolCreatedEvent<X, Y, Curve>>,
        liquidity_added_handle: event::EventHandle<LiquidityAddedEvent<X, Y, Curve>>,
        liquidity_removed_handle: event::EventHandle<LiquidityRemovedEvent<X, Y, Curve>>,
        swap_handle: event::EventHandle<SwapEvent<X, Y, Curve>>,
        flashloan_handle: event::EventHandle<FlashloanEvent<X, Y, Curve>>,
        oracle_updated_handle: event::EventHandle<OracleUpdatedEvent<X, Y, Curve>>,
        update_fee_handle: event::EventHandle<UpdateFeeEvent<X, Y, Curve>>,
        update_dao_fee_handle: event::EventHandle<UpdateDAOFeeEvent<X, Y, Curve>>,
    }

    struct PoolCreatedEvent<phantom X, phantom Y, phantom Curve> has drop, store {
        creator: address,
    }

    struct LiquidityAddedEvent<phantom X, phantom Y, phantom Curve> has drop, store {
        added_x_val: u64,
        added_y_val: u64,
        lp_tokens_received: u64,
    }

    struct LiquidityRemovedEvent<phantom X, phantom Y, phantom Curve> has drop, store {
        returned_x_val: u64,
        returned_y_val: u64,
        lp_tokens_burned: u64,
    }

    struct SwapEvent<phantom X, phantom Y, phantom Curve> has drop, store {
        x_in: u64,
        x_out: u64,
        y_in: u64,
        y_out: u64,
    }

    struct FlashloanEvent<phantom X, phantom Y, phantom Curve> has drop, store {
        x_in: u64,
        x_out: u64,
        y_in: u64,
        y_out: u64,
    }

    struct OracleUpdatedEvent<phantom X, phantom Y, phantom Curve> has drop, store {
        last_price_x_cumulative: u128,
        last_price_y_cumulative: u128,
    }

    struct UpdateFeeEvent<phantom X, phantom Y, phantom Curve> has drop, store {
        new_fee: u64,
    }

    struct UpdateDAOFeeEvent<phantom X, phantom Y, phantom Curve> has drop, store {
        new_fee: u64,
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
    public fun update_cumulative_price_for_test<X, Y>(
        test_account: &signer,
        prev_last_block_timestamp: u64,
        prev_last_price_x_cumulative: u128,
        prev_last_price_y_cumulative: u128,
        x_reserve: u64,
        y_reserve: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u128, u128, u64) acquires EventsStore, LiquidityPool, PoolAccountCapability {
        register<X, Y, curves::Uncorrelated>(test_account, x_metadata, y_metadata);

        // todo: remove PoolAccountCapability usage?
        let pool_obj_addr = get_pool_addr<X, Y, curves::Uncorrelated>(x_metadata, y_metadata);
        assert!(exists<LiquidityPool<X, Y, curves::Uncorrelated>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool =
            borrow_global_mut<LiquidityPool<X, Y, curves::Uncorrelated>>(pool_obj_addr);
        pool.last_block_timestamp = prev_last_block_timestamp;
        pool.last_price_x_cumulative = prev_last_price_x_cumulative;
        pool.last_price_y_cumulative = prev_last_price_y_cumulative;

        update_oracle(pool, x_reserve, y_reserve);

        (pool.last_price_x_cumulative, pool.last_price_y_cumulative, pool.last_block_timestamp)
    }

    // todo: remove this and use other func?
    #[test_only]
    public fun get_reserved_value<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 acquires LiquidityPool, PoolAccountCapability {
        // todo: remove PoolAccountCapability usage?
        let pool_obj_addr = get_pool_addr<X, Y, curves::Uncorrelated>(x_metadata, y_metadata);
        assert!(exists<LiquidityPool<X, Y, curves::Uncorrelated>>(pool_obj_addr), ERR_POOL_DOES_NOT_EXIST);

        let pool =
            borrow_global_mut<LiquidityPool<X, Y, curves::Uncorrelated>>(pool_obj_addr);
        coin::value(&pool.lp_coins_reserved)
    }
}
