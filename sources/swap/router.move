/// Router v2 for Liquidity Pool, similar to Uniswap router.
module liquidswap_v05::router {
    use aptos_framework::coin::Coin;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{Metadata, FungibleAsset};
    use aptos_framework::object::Object;

    use liquidswap_v05::fa_helper::{Self, supply};
    use liquidswap_v05::curves;
    use liquidswap_v05::math;
    use liquidswap_v05::stable_curve;
    use liquidswap_v05::liquidity_pool;
    use liquidswap_lp::lp_coin::LP;

    // Errors codes.

    /// Wrong amount used.
    const ERR_WRONG_AMOUNT: u64 = 200;
    /// Wrong reserve used.
    const ERR_WRONG_RESERVE: u64 = 201;
    /// Insufficient amount in Y reserves.
    const ERR_INSUFFICIENT_Y_AMOUNT: u64 = 202;
    /// Insufficient amount in X reserves.
    const ERR_INSUFFICIENT_X_AMOUNT: u64 = 203;
    /// Overlimit of X FA to swap.
    const ERR_OVERLIMIT_X: u64 = 204;
    /// Amount out less than minimum.
    const ERR_FA_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM: u64 = 205;
    /// Needed amount in greater than maximum.
    const ERR_FA_VAL_MAX_LESS_THAN_NEEDED: u64 = 206;
    /// Marks the unreachable place in code.
    const ERR_UNREACHABLE: u64 = 207;
    /// Provided FA amount cannot be converted without the overflow at the current price
    const ERR_FA_CONVERSION_OVERFLOW: u64 = 208;
    /// Wrong order of FA parameters.
    const ERR_WRONG_FA_ORDER: u64 = 208;

    // Consts.

    const MAX_U64: u128 = 18446744073709551615;

    // Public functions.

    /// Register new liquidity pool for `X`/`Y` pair on signer address with `LP` coin.
    /// * `account` - pool creator signer.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Note: X, Y generic coin parameters must be sorted.
    public fun register_pool<X, Y, Curve>(
        account: &signer,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_FA_ORDER);
        liquidity_pool::register<X, Y, Curve>(account, x_metadata, y_metadata);
    }

    /// Add liquidity to pool `X`/`Y` with rationality checks.
    /// * `fa_x` - FA X to add as liquidity.
    /// * `min_fa_x_val` - minimum amount of FA X to add as liquidity.
    /// * `fa_y` - FA Y to add as liquidity.
    /// * `min_fa_y_val` - minimum amount of FA Y to add as liquidity.
    /// Returns remainders of FA X and Y, and LP coins: `(FungibleAsset, FungibleAsset, Coin<LP<X, Y, Curve>>)`.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public fun add_liquidity<X, Y, Curve>(
        fa_x: FungibleAsset,
        min_fa_x_val: u64,
        fa_y: FungibleAsset,
        min_fa_y_val: u64,
    ): (FungibleAsset, FungibleAsset, Coin<LP<X, Y, Curve>>) {
        let x_metadata = fungible_asset::metadata_from_asset(&fa_x);
        let y_metadata = fungible_asset::metadata_from_asset(&fa_y);

        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_FA_ORDER);

        let fa_x_val = fungible_asset::amount(&fa_x);
        let fa_y_val = fungible_asset::amount(&fa_y);

        assert!(fa_x_val >= min_fa_x_val, ERR_INSUFFICIENT_X_AMOUNT);
        assert!(fa_y_val >= min_fa_y_val, ERR_INSUFFICIENT_Y_AMOUNT);

        let (optimal_x, optimal_y) =
            calc_optimal_coin_values<X, Y, Curve>(
                fa_x_val,
                fa_y_val,
                min_fa_x_val,
                min_fa_y_val,
                x_metadata,
                y_metadata,
            );

        let fa_x_opt = fungible_asset::extract(&mut fa_x, optimal_x);
        let fa_y_opt = fungible_asset::extract(&mut fa_y, optimal_y);

        let lp_coins = liquidity_pool::mint<X, Y, Curve>(fa_x_opt, fa_y_opt);
        (fa_x, fa_y, lp_coins)
    }

    /// Burn liquidity coins `LP` and get FA's `X` and `Y` back.
    /// * `lp_coins` - `LP` coins to burn.
    /// * `min_x_out_val` - minimum amount of `X` coins must be out.
    /// * `min_y_out_val` - minimum amount of `Y` coins must be out.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns both FA X and FA Y: `(FungibleAsset, FungibleAsset)`.
    ///
    /// Note: X, Y generic coin parameteres should be sorted.
    public fun remove_liquidity<X, Y, Curve>(
        lp_coins: Coin<LP<X, Y, Curve>>,
        min_x_out_val: u64,
        min_y_out_val: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (FungibleAsset, FungibleAsset) {
        // todo: fetch metadata from LP?

        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_FA_ORDER);

        let (x_out, y_out) =
            liquidity_pool::burn<X, Y, Curve>(lp_coins, x_metadata, y_metadata);

        assert!(
            fungible_asset::amount(&x_out) >= min_x_out_val,
            ERR_FA_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
        );
        assert!(
            fungible_asset::amount(&y_out) >= min_y_out_val,
            ERR_FA_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
        );
        (x_out, y_out)
    }

    /// Swap exact amount of FA `X` for FA `Y`.
    /// * `fa_in` - FA X to swap.
    /// * `fa_out_min_val` - minimum amount of FA Y to get out.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns FungibleAsset Y.
    public fun swap_exact_coin_for_coin<X, Y, Curve>(
        fa_in: FungibleAsset,
        fa_out_min_val: u64,
        y_metadata: Object<Metadata>,
    ): FungibleAsset {
        let x_metadata = fungible_asset::metadata_from_asset(&fa_in);
        let fa_in_val = fungible_asset::amount(&fa_in);
        let fa_out_val = get_amount_out<X, Y, Curve>(fa_in_val, x_metadata, y_metadata);

        assert!(
            fa_out_val >= fa_out_min_val,
            ERR_FA_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM,
        );
        swap_coin_for_coin_unchecked<X, Y, Curve>(
            fa_in,
            fa_out_val,
            y_metadata,
        )
    }

    /// Swap max FA amount `X` for exact FA `Y`.
    /// * `fa_max_in` - maximum amount of FA X to swap to get `fa_out_val` of FA Y.
    /// * `fa_out_val` - exact amount of FA Y to get.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns remainder of `fa_max_in` as FA X and FA Y: `(FungibleAsset, FungibleAsset)`.
    public fun swap_coin_for_exact_coin<X, Y, Curve>(
        fa_max_in: FungibleAsset,
        fa_out_val: u64,
        y_metadata: Object<Metadata>,
    ): (FungibleAsset, FungibleAsset) {
        let x_metadata = fungible_asset::metadata_from_asset(&fa_max_in);
        let fa_in_val_needed = get_amount_in<X, Y, Curve>(fa_out_val, x_metadata, y_metadata);

        let fa_val_max = fungible_asset::amount(&fa_max_in);
        assert!(
            fa_in_val_needed <= fa_val_max,
            ERR_FA_VAL_MAX_LESS_THAN_NEEDED
        );

        let fa_in = fungible_asset::extract(&mut fa_max_in, fa_in_val_needed);
        let fa_out =
            swap_coin_for_coin_unchecked<X, Y, Curve>(fa_in, fa_out_val, y_metadata);

        (fa_max_in, fa_out)
    }

    /// Swap FA `X` for FA `Y` WITHOUT CHECKING input and output amount.
    /// So use the following function only on your own risk.
    /// * `fa_in` - FA X to swap.
    /// * `fa_out_val` - amount of FA Y to get out.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns FA Y.
    public fun swap_coin_for_coin_unchecked<X, Y, Curve>(
        fa_in: FungibleAsset,
        fa_out_val: u64,
        y_metadata: Object<Metadata>,
    ): FungibleAsset {
        let x_metadata = fungible_asset::metadata_from_asset(&fa_in);
        let (zero, fa_out);
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            (zero, fa_out) = liquidity_pool::swap<X, Y, Curve>(
                fa_in,
                0,
                fungible_asset::zero(y_metadata),
                fa_out_val,
            );
        } else {
            (fa_out, zero) = liquidity_pool::swap<Y, X, Curve>(
                fungible_asset::zero(y_metadata),
                fa_out_val,
                fa_in,
                0
            );
        };
        fungible_asset::destroy_zero(zero);

        fa_out
    }

    // Getters.

    /// Get decimals scales for stable curve, for uncorrelated curve would return zeros.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns `X` and `Y` FA decimals scales.
    public fun get_decimals_scales<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) {
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_decimals_scales<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            let (y, x) = liquidity_pool::get_decimals_scales<Y, X, Curve>(y_metadata, x_metadata);
            (x, y)
        }
    }

    /// Get current cumulative prices in liquidity pool `X`/`Y`.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns (X price, Y price, block_timestamp).
    public fun get_cumulative_prices<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u128, u128, u64) {
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_cumulative_prices<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            let (y, x, t) =
                liquidity_pool::get_cumulative_prices<Y, X, Curve>(y_metadata, x_metadata);
            (x, y, t)
        }
    }

    /// Get reserves of liquidity pool (`X` and `Y`).
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns current reserves (`X`, `Y`).
    public fun get_reserves_size<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) {
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_reserves_size<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            let (y_res, x_res) = liquidity_pool::get_reserves_size<Y, X, Curve>(y_metadata, x_metadata);
            (x_res, y_res)
        }
    }

    /// Get fee for specific pool together with denominator (numerator, denominator).
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun get_fees_config<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) {
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_fees_config<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            liquidity_pool::get_fees_config<Y, X, Curve>(y_metadata, x_metadata)
        }
    }

    /// Get fee for specific pool.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun get_fee<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 {
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_fee<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            liquidity_pool::get_fee<Y, X, Curve>(y_metadata, x_metadata)
        }
    }

    /// Get DAO fee for specific pool together with denominator (numerator, denominator).
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun get_dao_fees_config<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) {
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_dao_fees_config<X, Y, Curve>(
                x_metadata,
                y_metadata,
            )
        } else {
            liquidity_pool::get_dao_fees_config<Y, X, Curve>(
                y_metadata,
                x_metadata,
            )
        }
    }

    /// Get DAO fee for specific pool.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public fun get_dao_fee<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 {
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_dao_fee<X, Y, Curve>(
                x_metadata,
                y_metadata,
            )
        } else {
            liquidity_pool::get_dao_fee<Y, X, Curve>(
                y_metadata,
                x_metadata
            )
        }
    }

    /// Check swap for pair `X` and `Y` exists.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// If pool exists returns true, otherwise false.
    public fun is_swap_exists<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): bool {
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::is_pool_exists<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            liquidity_pool::is_pool_exists<Y, X, Curve>(y_metadata, x_metadata)
        }
    }

    // Math.

    /// Calculate optimal amounts of `X`, `Y` FA's to add as a new liquidity.
    /// * `x_desired` - provided value of FA `X`.
    /// * `y_desired` - provided value of FA `Y`.
    /// * `x_min` - minimum of FA X expected.
    /// * `y_min` - minimum of FA Y expected.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns both `X` and `Y` FA's amounts.
    public fun calc_optimal_coin_values<X, Y, Curve>(
        x_desired: u64,
        y_desired: u64,
        x_min: u64,
        y_min: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) {
        let (reserves_x, reserves_y) = get_reserves_size<X, Y, Curve>(x_metadata, y_metadata);

        if (reserves_x == 0 && reserves_y == 0) {
            return (x_desired, y_desired)
        } else {
            let y_returned = convert_with_current_price(x_desired, reserves_x, reserves_y);
            if (y_returned <= y_desired) {
                // amount of `y` received from `x_desired` on a current price is less than `y_desired`
                assert!(y_returned >= y_min, ERR_INSUFFICIENT_Y_AMOUNT);
                return (x_desired, y_returned)
            } else {
                // not enough in `y_desired`, use it as a cap
                let x_returned = convert_with_current_price(y_desired, reserves_y, reserves_x);
                // ERR_OVERLIMIT_X should never occur here, added just in case
                assert!(x_returned <= x_desired, ERR_OVERLIMIT_X);
                assert!(x_returned >= x_min, ERR_INSUFFICIENT_X_AMOUNT);
                return (x_returned, y_desired)
            }
        }
    }

    /// Return amount of liquidity (LP) need for `coin_in`.
    /// * `fa_in` - amount to swap.
    /// * `reserve_in` - reserves of coin to swap.
    /// * `reserve_out` - reserves of coin to get.
    public fun convert_with_current_price(fa_in: u64, reserve_in: u64, reserve_out: u64): u64 {
        assert!(fa_in > 0, ERR_WRONG_AMOUNT);
        assert!(reserve_in > 0 && reserve_out > 0, ERR_WRONG_RESERVE);

        // exchange_price = reserve_out / reserve_in_size
        // amount_returned = fa_in_val * exchange_price
        let res = (fa_in as u128) * (reserve_out as u128) / (reserve_in as u128);
        assert!(res <= MAX_U64, ERR_FA_CONVERSION_OVERFLOW);
        (res as u64)
    }

    /// Convert `LP` coins to `X` and `Y` FA's, useful to calculate amount the user recieve after removing liquidity.
    /// * `lp_to_burn_val` - amount of `LP` coins to burn.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns both `X` and `Y` FA amounts.
    public fun get_reserves_for_lp_coins<X, Y, Curve>(
        lp_to_burn_val: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>
    ): (u64, u64) {
        let (x_reserve, y_reserve) = get_reserves_size<X, Y, Curve>(x_metadata, y_metadata);
        let lp_coins_total = supply<LP<X, Y, Curve>>();

        let x_to_return_val = math::mul_div_u128((lp_to_burn_val as u128), (x_reserve as u128), lp_coins_total);
        let y_to_return_val = math::mul_div_u128((lp_to_burn_val as u128), (y_reserve as u128), lp_coins_total);

        assert!(x_to_return_val > 0 && y_to_return_val > 0, ERR_WRONG_AMOUNT);

        (x_to_return_val, y_to_return_val)
    }

    /// Get amount out for `amount_in` of X FA's.
    /// So if FungibleAsset::USDC is X and FungibleAsset::USDT is Y, it will
    ///     get amount of USDT you will get after swap `amount_x` USDC.
    /// !Important!: This function can eat a lot of gas if you querying it for stable curve pool, so be aware.
    /// We recommend to do implement such kind of logic offchain.
    /// * `amount_in` - amount to swap.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns amount of `Y` FA getting after swap.
    public fun get_amount_out<X, Y, Curve>(
        amount_in: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 {
        let (reserve_x, reserve_y) = get_reserves_size<X, Y, Curve>(x_metadata, y_metadata);
        let (scale_x, scale_y) = get_decimals_scales<X, Y, Curve>(x_metadata, y_metadata);

        get_coin_out_with_fees<X, Y, Curve>(
            amount_in,
            reserve_x,
            reserve_y,
            scale_x,
            scale_y,
            x_metadata,
            y_metadata,
        )
    }

    /// Get amount in for `amount_out` of X FA.
    /// So if FungibleAsset::USDT is X and FungibleAsset::USDC is Y, you pass how much USDC you want to get and
    ///     it returns amount of USDT you have to swap (include fees).
    /// !Important!: This function can eat a lot of gas if you querying it for stable curve pool, so be aware.
    /// We recommend to do implement such kind of logic offchain.
    /// * `amount_x` - amount to swap.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns amount of `X` FA needed.
    public fun get_amount_in<X, Y, Curve>(
        amount_out: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 {
        let (reserve_x, reserve_y) = get_reserves_size<X, Y, Curve>(x_metadata, y_metadata);
        let (scale_x, scale_y) = get_decimals_scales<X, Y, Curve>(x_metadata, y_metadata);
        get_coin_in_with_fees<X, Y, Curve>(
            amount_out,
            reserve_y,
            reserve_x,
            scale_y,
            scale_x,
            x_metadata,
            y_metadata,
        )
    }

    // Private functions (contains part of math).

    /// Get coin amount out by passing amount in (include fees). Pass all data manually.
    /// * `fa_in` - exactly amount of FA to swap.
    /// * `reserve_in` - reserves of FA we are going to swap.
    /// * `reserve_out` - reserves of FA we are going to get.
    /// * `scale_in` - 10 pow by decimals amount of FA we going to swap.
    /// * `scale_out` - 10 pow by decimals amount of FA we going to get.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Returns amount of FA out after swap.
    fun get_coin_out_with_fees<X, Y, Curve>(
        fa_in: u64,
        reserve_in: u64,
        reserve_out: u64,
        scale_in: u64,
        scale_out: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 {
        let (fee_pct, fee_scale) =
            get_fees_config<X, Y, Curve>(x_metadata, y_metadata);
        let fee_multiplier = fee_scale - fee_pct;

        let reserve_in_u128 = (reserve_in as u128);
        let reserve_out_u128 = (reserve_out as u128);

        if (curves::is_stable<Curve>()) {
            let fa_in_val_scaled = math::mul_to_u128(fa_in, fee_multiplier);
            let fa_in_val_after_fees = if (fa_in_val_scaled % (fee_scale as u128) != 0) {
                (fa_in_val_scaled / (fee_scale as u128)) + 1
            } else {
                fa_in_val_scaled / (fee_scale as u128)
            };

            (stable_curve::coin_out(
                fa_in_val_after_fees,
                scale_in,
                scale_out,
                reserve_in_u128,
                reserve_out_u128
            ) as u64)
        } else if (curves::is_uncorrelated<Curve>()) {
            let fa_in_val_after_fees = math::mul_to_u128(fa_in, fee_multiplier);
            let new_reserve_in = math::mul_to_u128(reserve_in, fee_scale) + fa_in_val_after_fees;

            // Multiply fa_in by the current exchange rate:
            // current_exchange_rate = reserve_out / reserve_in
            // amount_in_after_fees * current_exchange_rate -> amount_out
            math::mul_div_u128(fa_in_val_after_fees,
                reserve_out_u128,
                new_reserve_in)
        } else {
            abort ERR_UNREACHABLE
        }
    }

    /// Get FA amount in by amount out. Pass all data manually.
    /// * `fa_out` - exactly amount of FA we want to get.
    /// * `reserve_out` - reserves of FA we are going to get.
    /// * `reserve_in` - reserves of FA we are going to swap.
    /// * `scale_out` - 10 pow by decimals amount of FA we get.
    /// * `scale_in` - 10 pow by decimals amount of FA we swap.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    ///
    /// This computation is a reverse of get_coin_out formula for uncorrelated assets:
    ///     y = x * (fee_scale - fee_pct) * ry / (rx + x * (fee_scale - fee_pct))
    ///
    /// solving it for x returns this formula:
    ///     x = y * rx / ((ry - y) * (fee_scale - fee_pct)) or
    ///     x = y * rx * (fee_scale) / ((ry - y) * (fee_scale - fee_pct)) which implemented in this function
    ///
    ///  For stable curve math described in `coin_in` func into `../libs/StableCurve.move`.
    ///
    /// Returns amount of FA needed for swap.
    fun get_coin_in_with_fees<X, Y, Curve>(
        fa_out: u64,
        reserve_out: u64,
        reserve_in: u64,
        scale_out: u64,
        scale_in: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 {
        assert!(reserve_out > fa_out, ERR_INSUFFICIENT_Y_AMOUNT);

        let (fee_pct, fee_scale) =
            get_fees_config<X, Y, Curve>(x_metadata, y_metadata);
        let fee_multiplier = fee_scale - fee_pct;

        let fa_out_u128 = (fa_out as u128);
        let reserve_in_u128 = (reserve_in as u128);
        let reserve_out_u128 = (reserve_out as u128);

        if (curves::is_stable<Curve>()) {
            let coin_in = (stable_curve::coin_in(
                fa_out_u128,
                scale_out,
                scale_in,
                reserve_out_u128,
                reserve_in_u128,
            ) as u64) + 1;
            math::mul_div(coin_in, fee_scale, fee_multiplier) + 1

        } else if (curves::is_uncorrelated<Curve>()) {
            let new_reserves_out = (reserve_out_u128 - fa_out_u128) * (fee_multiplier as u128);

            // fa_out * reserve_in * fee_scale / new reserves out
            let fa_in = math::mul_div_u128(
                fa_out_u128,
                reserve_in_u128 * (fee_scale as u128),
                new_reserves_out
            ) + 1;
            fa_in
        } else {
            abort ERR_UNREACHABLE
        }
    }

    #[test_only]
    public fun current_price<X, Y, Curve>(x_metadata: Object<Metadata>, y_metadata: Object<Metadata>): u128 {
        let (x_reserve, y_reserve) = get_reserves_size<X, Y, Curve>(x_metadata, y_metadata);
        ((x_reserve / y_reserve) as u128)
    }
}
