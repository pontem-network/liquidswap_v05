/// The current module contains pre-deplopyed scripts for LiquidSwap.
module liquidswap_v05::scripts {
    use std::signer;

    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store;

    use liquidswap_v05::router;
    use liquidswap_v05::liquidity_pool;

    /// Register a new liquidity pool for `X`/`Y` pair.
    /// * `account` - pool creator signer.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun register_pool<Curve>(
        account: &signer,
        metadata_x: Object<Metadata>,
        metadata_y: Object<Metadata>,
    ) {
        router::register_pool<Curve>(account, metadata_x, metadata_y);
    }

    /// Register a new liquidity pool `X`/`Y` and immediately add liquidity.
    /// * `account` - pool creator signer.
    /// * `fa_x_val` - amount of FA `X` to add as liquidity.
    /// * `fa_x_val_min` - minimum amount of FA `X` to add as liquidity (slippage).
    /// * `fa_y_val` - minimum amount of FA `Y` to add as liquidity.
    /// * `fa_y_val_min` - minimum amount of FA `Y` to add as liquidity (slippage).
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun register_pool_and_add_liquidity<Curve>(
        account: &signer,
        fa_x_val: u64,
        fa_x_val_min: u64,
        fa_y_val: u64,
        fa_y_val_min: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        router::register_pool<Curve>(account, x_metadata, y_metadata);
        add_liquidity<Curve>(
            account,
            fa_x_val,
            fa_x_val_min,
            fa_y_val,
            fa_y_val_min,
            x_metadata,
            y_metadata,
        );
    }

    /// Add new liquidity into pool `X`/`Y` and get liquidity FA `LP`.
    /// * `account` - liquidity adding signer.
    /// * `fa_x_val` - amount of fa `X` to add as liquidity.
    /// * `fa_x_val_min` - minimum amount of fa `X` to add as liquidity (slippage).
    /// * `fa_y_val` - minimum amount of fa `Y` to add as liquidity.
    /// * `fa_y_val_min` - minimum amount of coin `Y` to add as liquidity (slippage).
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun add_liquidity<Curve>(
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

        let (fa_x_remainder, fa_y_remainder, lp_fa) =
            router::add_liquidity<Curve>(
                fa_x,
                fa_x_val_min,
                fa_y,
                fa_y_val_min,
            );

        let account_addr = signer::address_of(account);
        primary_fungible_store::deposit(account_addr, fa_x_remainder);
        primary_fungible_store::deposit(account_addr, fa_y_remainder);
        primary_fungible_store::deposit(account_addr, lp_fa);
    }

    /// Remove (burn) liquidity FA `LP` from account, get `X` and`Y` FA's back.
    /// * `account` - liquidity burning signer.
    /// * `lp_val` - amount of `LP` FA to burn.
    /// * `min_x_out_val` - minimum amount of X FA to get.
    /// * `min_y_out_val` - minimum amount of Y FA to get.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun remove_liquidity<Curve>(
        account: &signer,
        lp_val: u64,
        min_x_out_val: u64,
        min_y_out_val: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        let lp_metadata = liquidity_pool::get_pool_lp_metadata<Curve>(x_metadata, y_metadata);
        let lp_fa = primary_fungible_store::withdraw(account, lp_metadata, lp_val);

        let (fa_x, fa_y) =
            router::remove_liquidity<Curve>(
                lp_fa,
                min_x_out_val,
                min_y_out_val,
                x_metadata,
                y_metadata,
            );

        let account_addr = signer::address_of(account);
        primary_fungible_store::deposit(account_addr, fa_x);
        primary_fungible_store::deposit(account_addr, fa_y);
    }

    /// Swap exact FA `X` for at least minimum FA `Y`.
    /// * `account` - swap preforming signer.
    /// * `fa_val` - amount of FA `X` to swap.
    /// * `fa_out_min_val` - minimum expected amount of FA `Y` to get.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public entry fun swap<Curve>(
        account: &signer,
        fa_val: u64,
        fa_out_min_val: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        let fa_x = primary_fungible_store::withdraw(account, x_metadata, fa_val);

        let fa_y =
            router::swap_exact_coin_for_coin<Curve>(
                fa_x,
                fa_out_min_val,
                y_metadata,
            );

        let account_addr = signer::address_of(account);
        primary_fungible_store::deposit(account_addr, fa_y);
    }

    /// Swap maximum FA `X` for exact FA `Y`.
    /// * `account` - swap preforming signer.
    /// * `fa_val_max` - how much of FA `X` can be used to get `Y` FA.
    /// * `fa_out` - how much of FA `Y` should be returned.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public entry fun swap_into<Curve>(
        account: &signer,
        fa_val_max: u64,
        fa_out: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        let fa_x = primary_fungible_store::withdraw(account, x_metadata, fa_val_max);

        let (fa_x, fa_y) =
            router::swap_coin_for_exact_coin<Curve>(
                fa_x,
                fa_out,
                y_metadata,
            );

        let account_addr = signer::address_of(account);
        primary_fungible_store::deposit(account_addr, fa_x);
        primary_fungible_store::deposit(account_addr, fa_y);
    }

    /// Swap `fa_in` of X for a `fa_out` of Y.
    /// Does not check optimality of the swap, and fails if the `X` to `Y` price ratio cannot be satisfied.
    /// * `account` - swap preforming signer.
    /// * `fa_in` - how much of FA `X` to swap.
    /// * `fa_out` - how much of FA `Y` should be returned.
    /// * `x_metadata` - metadata object of FungibleAsset X.
    /// * `y_metadata` - metadata object of FungibleAsset Y.
    public entry fun swap_unchecked<Curve>(
        account: &signer,
        fa_in: u64,
        fa_out: u64,
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ) {
        let fa_x = primary_fungible_store::withdraw(account, x_metadata, fa_in);

        let fa_y =
            router::swap_coin_for_coin_unchecked<Curve>(
                fa_x,
                fa_out,
                y_metadata,
            );

        let account_addr = signer::address_of(account);
        primary_fungible_store::deposit(account_addr, fa_y);
    }
}
