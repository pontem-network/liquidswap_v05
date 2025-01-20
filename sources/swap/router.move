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
    /// Overlimit of X coins to swap.
    const ERR_OVERLIMIT_X: u64 = 204;
    /// Amount out less than minimum.
    const ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM: u64 = 205;
    /// Needed amount in great than maximum.
    const ERR_COIN_VAL_MAX_LESS_THAN_NEEDED: u64 = 206;
    /// Marks the unreachable place in code
    const ERR_UNREACHABLE: u64 = 207;
    /// Provided coins amount cannot be converted without the overflow at the current price
    const ERR_COIN_CONVERSION_OVERFLOW: u64 = 208;
    /// Wrong order of coin parameters.
    const ERR_WRONG_COIN_ORDER: u64 = 208;

    // Consts
    const MAX_U64: u128 = 18446744073709551615;

    // Public functions.

    // todo: upd descr
    /// Register new liquidity pool for `X`/`Y` pair on signer address with `LP` coin.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public fun register_pool<X, Y, Curve>(
        account: &signer,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        // todo: check test exists
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_COIN_ORDER);
        liquidity_pool::register<X, Y, Curve>(account, x_metadata, y_metadata);
    }

    // todo: upd descr
    /// Add liquidity to pool `X`/`Y` with rationality checks.
    /// * `coin_x` - coin X to add as liquidity.
    /// * `min_coin_x_val` - minimum amount of coin X to add as liquidity.
    /// * `coin_y` - coin Y to add as liquidity.
    /// * `min_coin_y_val` - minimum amount of coin Y to add as liquidity.
    /// Returns remainders of coins X and Y, and LP coins: `(Coin<X>, Coin<Y>, Coin<LP<X, Y, Curve>>)`.
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

        // todo: recheck test exists
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_COIN_ORDER);

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

    // todo: upd descr
    /// Burn liquidity coins `LP` and get coins `X` and `Y` back.
    /// * `lp_coins` - `LP` coins to burn.
    /// * `min_x_out_val` - minimum amount of `X` coins must be out.
    /// * `min_y_out_val` - minimum amount of `Y` coins must be out.
    /// Returns both `Coin<X>` and `Coin<Y>`: `(Coin<X>, Coin<Y>)`.
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

        // todo: recheck test exists
        assert!(fa_helper::is_fa_sorted(x_metadata, y_metadata), ERR_WRONG_COIN_ORDER);

        let (x_out, y_out) =
            liquidity_pool::burn<X, Y, Curve>(lp_coins, x_metadata, y_metadata);

        assert!(
            fungible_asset::amount(&x_out) >= min_x_out_val,
            ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
        );
        assert!(
            fungible_asset::amount(&y_out) >= min_y_out_val,
            ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
        );
        (x_out, y_out)
    }

    // todo: upd descr
    /// Swap exact amount of coin `X` for coin `Y`.
    /// * `coin_in` - coin X to swap.
    /// * `coin_out_min_val` - minimum amount of coin Y to get out.
    /// Returns `Coin<Y>`.
    public fun swap_exact_coin_for_coin<X, Y, Curve>(
        fa_in: FungibleAsset,
        coin_out_min_val: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): FungibleAsset {
        let fa_in_val = fungible_asset::amount(&fa_in);
        let fa_out_val = get_amount_out<X, Y, Curve>(fa_in_val, x_metadata, y_metadata);

        assert!(
            fa_out_val >= coin_out_min_val,
            ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM,
        );
        swap_coin_for_coin_unchecked<X, Y, Curve>(
            fa_in,
            fa_out_val,
            x_metadata,
            y_metadata,
        )
    }

    // todo: upd description
    /// Swap max coin amount `X` for exact coin `Y`.
    /// * `coin_max_in` - maximum amount of coin X to swap to get `coin_out_val` of coins Y.
    /// * `coin_out_val` - exact amount of coin Y to get.
    /// Returns remainder of `coin_max_in` as `Coin<X>` and `Coin<Y>`: `(Coin<X>, Coin<Y>)`.
    public fun swap_coin_for_exact_coin<X, Y, Curve>(
        fa_max_in: FungibleAsset,
        fa_out_val: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (FungibleAsset, FungibleAsset) {
        let fa_in_val_needed = get_amount_in<X, Y, Curve>(fa_out_val, x_metadata, y_metadata);

        let coin_val_max = fungible_asset::amount(&fa_max_in);
        assert!(
            fa_in_val_needed <= coin_val_max,
            ERR_COIN_VAL_MAX_LESS_THAN_NEEDED
        );

        let fa_in = fungible_asset::extract(&mut fa_max_in, fa_in_val_needed);
        let fa_out =
            swap_coin_for_coin_unchecked<X, Y, Curve>(fa_in, fa_out_val, x_metadata, y_metadata);

        (fa_max_in, fa_out)
    }

    // todo: upd descr
    /// Swap coin `X` for coin `Y` WITHOUT CHECKING input and output amount.
    /// So use the following function only on your own risk.
    /// * `coin_in` - coin X to swap.
    /// * `coin_out_val` - amount of coin Y to get out.
    /// Returns `Coin<Y>`.
    public fun swap_coin_for_coin_unchecked<X, Y, Curve>(
        fa_in: FungibleAsset,
        fa_out_val: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): FungibleAsset {
        let (zero, coin_out);
        // todo: check is_sorted test
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            (zero, coin_out) = liquidity_pool::swap<X, Y, Curve>(
                fa_in,
                0,
                fungible_asset::zero(y_metadata),
                fa_out_val,
            );
        } else {
            (coin_out, zero) = liquidity_pool::swap<Y, X, Curve>(
                fungible_asset::zero(y_metadata),
                fa_out_val,
                fa_in,
                0
            );
        };
        fungible_asset::destroy_zero(zero);

        coin_out
    }

    // Getters.

    // todo: update desc
    /// Get decimals scales for stable curve, for uncorrelated curve would return zeros.
    /// Returns `X` and `Y` coins decimals scales.
    public fun get_decimals_scales<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) {
        // todo: test fa sort
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_decimals_scales<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            let (y, x) = liquidity_pool::get_decimals_scales<Y, X, Curve>(y_metadata, x_metadata);
            (x, y)
        }
    }

    // todo: update desc
    /// Get current cumulative prices in liquidity pool `X`/`Y`.
    /// Returns (X price, Y price, block_timestamp).
    public fun get_cumulative_prices<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u128, u128, u64) {
        // todo: test fa_sorted with this func
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_cumulative_prices<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            let (y, x, t) =
                liquidity_pool::get_cumulative_prices<Y, X, Curve>(y_metadata, x_metadata);
            (x, y, t)
        }
    }

    // todo: update description
    // todo: add extra test for is_fa_sorted part here
    /// Get reserves of liquidity pool (`X` and `Y`).
    /// Returns current reserves (`X`, `Y`).
    public fun get_reserves_size<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) {
        // todo: add some test?
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_reserves_size<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            let (y_res, x_res) = liquidity_pool::get_reserves_size<Y, X, Curve>(y_metadata, x_metadata);
            (x_res, y_res)
        }
    }

    // todo: upd descr
    /// Get fee for specific pool together with denominator (numerator, denominator).
    public fun get_fees_config<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) {
        // todo: add extra test for is_fa_sorted part here
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_fees_config<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            liquidity_pool::get_fees_config<Y, X, Curve>(y_metadata, x_metadata)
        }
    }

    // todo: upd descr
    /// Get fee for specific pool.
    public fun get_fee<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 {
        // todo: add extra test for is_fa_sorted part here
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::get_fee<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            liquidity_pool::get_fee<Y, X, Curve>(y_metadata, x_metadata)
        }
    }

    // todo: upd descr
    /// Get DAO fee for specific pool together with denominator (numerator, denominator).
    public fun get_dao_fees_config<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (u64, u64) {
        // todo: test is_fa_sorted here?
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

    // todo: upd descr
    /// Get DAO fee for specific pool.
    public fun get_dao_fee<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 {
        // todo: test is_fa_sorted here?
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

    // todo: upd descr
    /// Check swap for pair `X` and `Y` exists.
    /// If pool exists returns true, otherwise false.
    public fun is_swap_exists<X, Y, Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): bool {
        // todo: add extra test for is_fa_sorted part here
        if (fa_helper::is_fa_sorted(x_metadata, y_metadata)) {
            liquidity_pool::is_pool_exists<X, Y, Curve>(x_metadata, y_metadata)
        } else {
            liquidity_pool::is_pool_exists<Y, X, Curve>(y_metadata, x_metadata)
        }
    }

    // Math.

    // todo: update descr
    /// Calculate optimal amounts of `X`, `Y` coins to add as a new liquidity.
    /// * `x_desired` - provided value of coins `X`.
    /// * `y_desired` - provided value of coins `Y`.
    /// * `x_min` - minimum of coins X expected.
    /// * `y_min` - minimum of coins Y expected.
    /// Returns both `X` and `Y` coins amounts.
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
    /// * `coin_in` - amount to swap.
    /// * `reserve_in` - reserves of coin to swap.
    /// * `reserve_out` - reserves of coin to get.
    public fun convert_with_current_price(coin_in: u64, reserve_in: u64, reserve_out: u64): u64 {
        assert!(coin_in > 0, ERR_WRONG_AMOUNT);
        assert!(reserve_in > 0 && reserve_out > 0, ERR_WRONG_RESERVE);

        // exchange_price = reserve_out / reserve_in_size
        // amount_returned = coin_in_val * exchange_price
        let res = (coin_in as u128) * (reserve_out as u128) / (reserve_in as u128);
        assert!(res <= MAX_U64, ERR_COIN_CONVERSION_OVERFLOW);
        (res as u64)
    }

    // todo: update description
    /// Convert `LP` coins to `X` and `Y` coins, useful to calculate amount the user recieve after removing liquidity.
    /// * `lp_to_burn_val` - amount of `LP` coins to burn.
    /// Returns both `X` and `Y` coins amounts.
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

    // todo: update descr
    /// Get amount out for `amount_in` of X coins (see generic).
    /// So if Coins::USDC is X and Coins::USDT is Y, it will get amount of USDT you will get after swap `amount_x` USDC.
    /// !Important!: This function can eat a lot of gas if you querying it for stable curve pool, so be aware.
    /// We recommend to do implement such kind of logic offchain.
    /// * `amount_x` - amount to swap.
    /// Returns amount of `Y` coins getting after swap.
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

    // todo: upd descr
    /// Get amount in for `amount_out` of X coins (see generic).
    /// So if Coins::USDT is X and Coins::USDC is Y, you pass how much USDC you want to get and
    /// it returns amount of USDT you have to swap (include fees).
    /// !Important!: This function can eat a lot of gas if you querying it for stable curve pool, so be aware.
    /// We recommend to do implement such kind of logic offchain.
    /// * `amount_x` - amount to swap.
    /// Returns amount of `X` coins needed.
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

    // todo: upd description
    /// Get coin amount out by passing amount in (include fees). Pass all data manually.
    /// * `coin_in` - exactly amount of coins to swap.
    /// * `reserve_in` - reserves of coin we are going to swap.
    /// * `reserve_out` - reserves of coin we are going to get.
    /// * `scale_in` - 10 pow by decimals amount of coin we going to swap.
    /// * `scale_out` - 10 pow by decimals amount of coin we going to get.
    /// Returns amount of coins out after swap.
    fun get_coin_out_with_fees<X, Y, Curve>(
        coin_in: u64,
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
            let coin_in_val_scaled = math::mul_to_u128(coin_in, fee_multiplier);
            let coin_in_val_after_fees = if (coin_in_val_scaled % (fee_scale as u128) != 0) {
                (coin_in_val_scaled / (fee_scale as u128)) + 1
            } else {
                coin_in_val_scaled / (fee_scale as u128)
            };

            (stable_curve::coin_out(
                coin_in_val_after_fees,
                scale_in,
                scale_out,
                reserve_in_u128,
                reserve_out_u128
            ) as u64)
        } else if (curves::is_uncorrelated<Curve>()) {
            let coin_in_val_after_fees = math::mul_to_u128(coin_in, fee_multiplier);
            let new_reserve_in = math::mul_to_u128(reserve_in, fee_scale) + coin_in_val_after_fees;

            // Multiply coin_in by the current exchange rate:
            // current_exchange_rate = reserve_out / reserve_in
            // amount_in_after_fees * current_exchange_rate -> amount_out
            math::mul_div_u128(coin_in_val_after_fees,
                reserve_out_u128,
                new_reserve_in)
        } else {
            abort ERR_UNREACHABLE
        }
    }

    // todo: upd descr
    /// Get coin amount in by amount out. Pass all data manually.
    /// * `coin_out` - exactly amount of coins we want to get.
    /// * `reserve_out` - reserves of coin we are going to get.
    /// * `reserve_in` - reserves of coin we are going to swap.
    /// * `scale_in` - 10 pow by decimals amount of coin we swap.
    /// * `scale_out` - 10 pow by decimals amount of coin we get.
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
    /// Returns amount of coins needed for swap.
    fun get_coin_in_with_fees<X, Y, Curve>(
        coin_out: u64,
        reserve_out: u64,
        reserve_in: u64,
        scale_out: u64,
        scale_in: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): u64 {
        assert!(reserve_out > coin_out, ERR_INSUFFICIENT_Y_AMOUNT);

        let (fee_pct, fee_scale) =
            get_fees_config<X, Y, Curve>(x_metadata, y_metadata);
        let fee_multiplier = fee_scale - fee_pct;

        let coin_out_u128 = (coin_out as u128);
        let reserve_in_u128 = (reserve_in as u128);
        let reserve_out_u128 = (reserve_out as u128);

        if (curves::is_stable<Curve>()) {
            let coin_in = (stable_curve::coin_in(
                coin_out_u128,
                scale_out,
                scale_in,
                reserve_out_u128,
                reserve_in_u128,
            ) as u64) + 1;
            math::mul_div(coin_in, fee_scale, fee_multiplier) + 1

        } else if (curves::is_uncorrelated<Curve>()) {
            let new_reserves_out = (reserve_out_u128 - coin_out_u128) * (fee_multiplier as u128);

            // coin_out * reserve_in * fee_scale / new reserves out
            let coin_in = math::mul_div_u128(
                coin_out_u128,
                reserve_in_u128 * (fee_scale as u128),
                new_reserves_out
            ) + 1;
            coin_in
        } else {
            abort ERR_UNREACHABLE
        }
    }

    // todo: seems unused, remove
    #[test_only]
    public fun current_price<X, Y, Curve>(x_metadata: Object<Metadata>, y_metadata: Object<Metadata>): u128 {
        let (x_reserve, y_reserve) = get_reserves_size<X, Y, Curve>(x_metadata, y_metadata);
        ((x_reserve / y_reserve) as u128)
    }
}
