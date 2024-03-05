/// The current module contains pre-deplopyed scripts v3 for LiquidSwap.
/// New version doesn't require to register coins before swap and
/// allows to transfer coins after swap to another account.
module ls_periphery::scripts_v3 {
    use std::option::{Self, Option};
    use std::signer;

    use aptos_framework::coin;
    use aptos_framework::aptos_account;

    use ls_periphery::router_v3;
    use liquidswap_lp::lp_coin::LP;

    /// Register a new liquidity pool for `X`/`Y` pair.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun register_pool<X, Y, Curve>(account: &signer) {
        router_v3::register_pool<X, Y, Curve>(account);
    }

    /// Register a new liquidity pool `X`/`Y` and immediately add liquidity.
    /// * `coin_x_val` - amount of coin `X` to add as liquidity.
    /// * `coin_x_val_min` - minimum amount of coin `X` to add as liquidity (slippage).
    /// * `coin_y_val` - minimum amount of coin `Y` to add as liquidity.
    /// * `coin_y_val_min` - minimum amount of coin `Y` to add as liquidity (slippage).
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun register_pool_and_add_liquidity<X, Y, Curve>(
        account: &signer,
        coin_x_val: u64,
        coin_x_val_min: u64,
        coin_y_val: u64,
        coin_y_val_min: u64,
    ) {
        router_v3::register_pool<X, Y, Curve>(account);
        add_liquidity<X, Y, Curve>(
            account,
            coin_x_val,
            coin_x_val_min,
            coin_y_val,
            coin_y_val_min,
        );
    }

    /// Add new liquidity into pool `X`/`Y` and get liquidity coin `LP`.
    /// * `coin_x_val` - amount of coin `X` to add as liquidity.
    /// * `coin_x_val_min` - minimum amount of coin `X` to add as liquidity (slippage).
    /// * `coin_y_val` - minimum amount of coin `Y` to add as liquidity.
    /// * `coin_y_val_min` - minimum amount of coin `Y` to add as liquidity (slippage).
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public entry fun add_liquidity<X, Y, Curve>(
        account: &signer,
        coin_x_val: u64,
        coin_x_val_min: u64,
        coin_y_val: u64,
        coin_y_val_min: u64,
    ) {
        let coin_x = coin::withdraw<X>(account, coin_x_val);
        let coin_y = coin::withdraw<Y>(account, coin_y_val);

        let (coin_x_remainder, coin_y_remainder, lp_coins) =
            router_v3::add_liquidity<X, Y, Curve>(
                coin_x,
                coin_x_val_min,
                coin_y,
                coin_y_val_min,
            );

        let account_addr = signer::address_of(account);

        coin::deposit(account_addr, coin_x_remainder);
        coin::deposit(account_addr, coin_y_remainder);
        aptos_account::deposit_coins(account_addr, lp_coins);
    }

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
    ) {
        let lp_coins = coin::withdraw<LP<X, Y, Curve>>(account, lp_val);

        let (coin_x, coin_y) = router_v3::remove_liquidity<X, Y, Curve>(
            lp_coins,
            min_x_out_val,
            min_y_out_val,
        );

        let account_addr = signer::address_of(account);
        aptos_account::deposit_coins(account_addr, coin_x);
        aptos_account::deposit_coins(account_addr, coin_y);
    }

    /// Swap exact coin `X` for at least minimum coin `Y`.
    /// * `coin_val` - amount of coins `X` to swap.
    /// * `coin_out_min_val` - minimum expected amount of coins `Y` to get.
    /// * `recipient` - optional recipient, can be another account address.
    public entry fun swap<X, Y, Curve>(
        account: &signer,
        coin_val: u64,
        coin_out_min_val: u64,
        recipient: Option<address>,
    ) {
        let coin_x = coin::withdraw<X>(account, coin_val);

        let coin_y = router_v3::swap_exact_coin_for_coin<X, Y, Curve>(
            coin_x,
            coin_out_min_val,
        );

        if (option::is_some(&recipient)) {
            let recipient_addr = option::destroy_some(recipient);
            aptos_account::deposit_coins(recipient_addr, coin_y);
        } else {
            let account_addr = signer::address_of(account);
            aptos_account::deposit_coins(account_addr, coin_y);
        }
    }

    /// Swap maximum coin `X` for exact coin `Y`.
    /// * `coin_val_max` - how much of coins `X` can be used to get `Y` coin.
    /// * `coin_out` - how much of coins `Y` should be returned.
    /// * `recipient` - optional recipient, can be another account address.
    public entry fun swap_into<X, Y, Curve>(
        account: &signer,
        coin_val_max: u64,
        coin_out: u64,
        recipient: Option<address>,
    ) {
        let coin_x = coin::withdraw<X>(account, coin_val_max);

        let (coin_x, coin_y) = router_v3::swap_coin_for_exact_coin<X, Y, Curve>(
            coin_x,
            coin_out,
        );

        let account_addr = signer::address_of(account);
        coin::deposit(account_addr, coin_x);

        if (option::is_some(&recipient)) {
            let recipient_addr = option::destroy_some(recipient);
            aptos_account::deposit_coins(recipient_addr, coin_y);
        } else {
            aptos_account::deposit_coins(account_addr, coin_y);
        }
    }

    /// Swap `coin_in` of X for a `coin_out` of Y.
    /// Does not check optimality of the swap, and fails if the `X` to `Y` price ratio cannot be satisfied.
    /// * `coin_in` - how much of coins `X` to swap.
    /// * `coin_out` - how much of coins `Y` should be returned.
    /// * `recipient` - optional recipient, can be another account address.
    public entry fun swap_unchecked<X, Y, Curve>(
        account: &signer,
        coin_in: u64,
        coin_out: u64,
        recipient: Option<address>,
    ) {
        let coin_x = coin::withdraw<X>(account, coin_in);

        let coin_y = router_v3::swap_coin_for_coin_unchecked<X, Y, Curve>(coin_x, coin_out);

        if (option::is_some(&recipient)) {
            let recipient_addr = option::destroy_some(recipient);
            aptos_account::deposit_coins(recipient_addr, coin_y);
        } else {
            let account_addr = signer::address_of(account);
            aptos_account::deposit_coins(account_addr, coin_y);
        }
    }
}
