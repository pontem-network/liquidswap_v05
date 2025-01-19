/// The current module contains pre-deplopyed scripts for LiquidSwap.
module liquidswap_v05::scripts {
    use std::signer;

    use aptos_framework::coin;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store;

    use liquidswap_v05::router;
    use liquidswap_lp::lp_coin::LP;

    // todo: upd description
    /// Register a new liquidity pool for `X`/`Y` pair.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun register_pool<X, Y, Curve>(
        account: &signer,
        metadata_x: Object<Metadata>,
        metadata_y: Object<Metadata>,
    ) {
        router::register_pool<X, Y, Curve>(account, metadata_x, metadata_y);
    }

    // todo: upd description
    /// Register a new liquidity pool `X`/`Y` and immediately add liquidity.
    /// * `coin_x_val` - amount of coin `X` to add as liquidity.
    /// * `coin_x_val_min` - minimum amount of coin `X` to add as liquidity (slippage).
    /// * `coin_y_val` - minimum amount of coin `Y` to add as liquidity.
    /// * `coin_y_val_min` - minimum amount of coin `Y` to add as liquidity (slippage).
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun register_pool_and_add_liquidity<X, Y, Curve>(
        account: &signer,
        fa_x_val: u64,
        fa_x_val_min: u64,
        fa_y_val: u64,
        fa_y_val_min: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        router::register_pool<X, Y, Curve>(account, x_metadata, y_metadata);
        add_liquidity<X, Y, Curve>(
            account,
            fa_x_val,
            fa_x_val_min,
            fa_y_val,
            fa_y_val_min,
            x_metadata,
            y_metadata,
        );
    }

    // todo: upd description
    /// Add new liquidity into pool `X`/`Y` and get liquidity coin `LP`.
    /// * `coin_x_val` - amount of coin `X` to add as liquidity.
    /// * `coin_x_val_min` - minimum amount of coin `X` to add as liquidity (slippage).
    /// * `coin_y_val` - minimum amount of coin `Y` to add as liquidity.
    /// * `coin_y_val_min` - minimum amount of coin `Y` to add as liquidity (slippage).
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun add_liquidity<X, Y, Curve>(
        account: &signer,
        fa_x_val: u64,
        fa_x_val_min: u64,
        fa_y_val: u64,
        fa_y_val_min: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        let fa_x = primary_fungible_store::withdraw(account, x_metadata, fa_x_val);
        let fa_y = primary_fungible_store::withdraw(account, y_metadata, fa_y_val);

        let (fa_x_remainder, fa_y_remainder, lp_coins) =
            router::add_liquidity<X, Y, Curve>(
                fa_x,
                fa_x_val_min,
                fa_y,
                fa_y_val_min,
            );

        let account_addr = signer::address_of(account);

        if (!coin::is_account_registered<LP<X, Y, Curve>>(account_addr)) {
            coin::register<LP<X, Y, Curve>>(account);
        };

        primary_fungible_store::deposit(account_addr, fa_x_remainder);
        primary_fungible_store::deposit(account_addr, fa_y_remainder);
        coin::deposit(account_addr, lp_coins);
    }

    // todo: upd description
    /// Remove (burn) liquidity coins `LP` from account, get `X` and`Y` coins back.
    /// * `lp_val` - amount of `LP` coins to burn.
    /// * `min_x_out_val` - minimum amount of X coins to get.
    /// * `min_y_out_val` - minimum amount of Y coins to get.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun remove_liquidity<X, Y, Curve>(
        account: &signer,
        lp_val: u64,
        min_x_out_val: u64,
        min_y_out_val: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        let lp_coins = coin::withdraw<LP<X, Y, Curve>>(account, lp_val);

        let (fa_x, fa_y) =
            router::remove_liquidity<X, Y, Curve>(
                lp_coins,
                min_x_out_val,
                min_y_out_val,
                x_metadata,
                y_metadata,
            );

        let account_addr = signer::address_of(account);
        primary_fungible_store::deposit(account_addr, fa_x);
        primary_fungible_store::deposit(account_addr, fa_y);
    }

    // todo: upd description
    /// Swap exact coin `X` for at least minimum coin `Y`.
    /// * `coin_val` - amount of coins `X` to swap.
    /// * `coin_out_min_val` - minimum expected amount of coins `Y` to get.
    public entry fun swap<X, Y, Curve>(
        account: &signer,
        fa_val: u64,
        fa_out_min_val: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        let fa_x = primary_fungible_store::withdraw(account, x_metadata, fa_val);

        let fa_y =
            router::swap_exact_coin_for_coin<X, Y, Curve>(
                fa_x,
                fa_out_min_val,
                x_metadata,
                y_metadata,
            );

        let account_addr = signer::address_of(account);
        primary_fungible_store::deposit(account_addr, fa_y);
    }

    // todo: upd description
    /// Swap maximum coin `X` for exact coin `Y`.
    /// * `coin_val_max` - how much of coins `X` can be used to get `Y` coin.
    /// * `coin_out` - how much of coins `Y` should be returned.
    public entry fun swap_into<X, Y, Curve>(
        account: &signer,
        fa_val_max: u64,
        fa_out: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        let fa_x = primary_fungible_store::withdraw(account, x_metadata, fa_val_max);

        let (fa_x, fa_y) =
            router::swap_coin_for_exact_coin<X, Y, Curve>(
                fa_x,
                fa_out,
                x_metadata,
                y_metadata
            );

        let account_addr = signer::address_of(account);
        primary_fungible_store::deposit(account_addr, fa_x);
        primary_fungible_store::deposit(account_addr, fa_y);
    }

    // todo: upd description
    /// Swap `coin_in` of X for a `coin_out` of Y.
    /// Does not check optimality of the swap, and fails if the `X` to `Y` price ratio cannot be satisfied.
    /// * `coin_in` - how much of coins `X` to swap.
    /// * `coin_out` - how much of coins `Y` should be returned.
    public entry fun swap_unchecked<X, Y, Curve>(
        account: &signer,
        fa_in: u64,
        fa_out: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        let fa_x = primary_fungible_store::withdraw(account, x_metadata, fa_in);

        let fa_y =
            router::swap_coin_for_coin_unchecked<X, Y, Curve>(
                fa_x,
                fa_out,
                x_metadata,
                y_metadata,
            );

        let account_addr = signer::address_of(account);
        primary_fungible_store::deposit(account_addr, fa_y);
    }
}
