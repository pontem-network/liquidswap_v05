/// The `FAHelper` module contains helper funcs to work with `AptosFramework::FungibleAsset` module.
module liquidswap_v05::fa_helper {
    use std::option;
    use std::string::{Self, String};

    use aptos_framework::coin;
    use aptos_std::comparator::{Self, Result};
    use aptos_std::string_utils;
    use aptos_std::type_info;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object;
    use aptos_framework::object::Object;

    use liquidswap_v05::curves::is_stable;
    use liquidswap_v05::math;

    // Errors codes.

    /// When both FA have same names and can't be ordered.
    const ERR_CANNOT_BE_THE_SAME_FA: u64 = 3000;

    /// When provided CoinType is not a coin.
    const ERR_IS_NOT_COIN: u64 = 3001;

    // Constants.
    /// Length of symbol prefix to be used in LP coin symbol.
    const SYMBOL_PREFIX_LENGTH: u64 = 4;

    /// Check if provided generic `CoinType` is a coin.
    public fun assert_is_coin<CoinType>() {
        assert!(coin::is_coin_initialized<CoinType>(), ERR_IS_NOT_COIN);
    }

    // todo: refactore this file

    // todo: add tests!
    // todo: update description
    /// Compare two coins, `X` and `Y`, using names.
    /// Caller should call this function to determine the order of X, Y.
    public fun compare_fa(x_metadata: Object<Metadata>, y_metadata: Object<Metadata>): Result {
        // std::debug::print(&aptos_std::string_utils::format1(&b"x_metadata = {}", x_metadata));
        // std::debug::print(&aptos_std::string_utils::format1(&b"y_metadata = {}", y_metadata));
        // 1. compare symbol
        let x_symb = fungible_asset::symbol(x_metadata);
        let y_symb = fungible_asset::symbol(y_metadata);
        let symb_cmp = comparator::compare(&x_symb, &y_symb);
        if (!comparator::is_equal(&symb_cmp)) return symb_cmp;

        // 2. metadata address
        let x_metadata_addr = object::object_address(&x_metadata);
        let y_metadata_addr = object::object_address(&y_metadata);
        let metadata_cmp = comparator::compare(&x_metadata_addr, &y_metadata_addr);

        metadata_cmp
    }

    /// Compare two coins, `X` and `Y`, using names.
    /// Caller should call this function to determine the order of X, Y.
    public fun compare<X, Y>(): Result {
        let x_info = type_info::type_of<X>();
        let y_info = type_info::type_of<Y>();

        // 1. compare struct_name
        let x_struct_name = type_info::struct_name(&x_info);
        let y_struct_name = type_info::struct_name(&y_info);
        let struct_cmp = comparator::compare(&x_struct_name, &y_struct_name);
        if (!comparator::is_equal(&struct_cmp)) return struct_cmp;

        // 2. if struct names are equal, compare module name
        let x_module_name = type_info::module_name(&x_info);
        let y_module_name = type_info::module_name(&y_info);
        let module_cmp = comparator::compare(&x_module_name, &y_module_name);
        if (!comparator::is_equal(&module_cmp)) return module_cmp;

        // 3. if modules are equal, compare addresses
        let x_address = type_info::account_address(&x_info);
        let y_address = type_info::account_address(&y_info);
        let address_cmp = comparator::compare(&x_address, &y_address);

        address_cmp
    }

    // todo: test
    // todo: same metadata\symbol test
    // todo: change description
    /// Check that coins generics `X`, `Y` are sorted in correct ordering.
    /// X != Y && X.symbol < Y.symbol
    public fun is_fa_sorted(x_metadata: Object<Metadata>, y_metadata: Object<Metadata>): bool {
        let order = compare_fa(x_metadata, y_metadata);
        assert!(!comparator::is_equal(&order), ERR_CANNOT_BE_THE_SAME_FA);
        comparator::is_smaller_than(&order)
    }

    /// Check that coins generics `X`, `Y` are sorted in correct ordering.
    /// X != Y && X.symbol < Y.symbol
    public fun is_sorted<X, Y>(): bool {
        let order = compare<X, Y>();
        assert!(!comparator::is_equal(&order), ERR_CANNOT_BE_THE_SAME_FA);
        comparator::is_smaller_than(&order)
    }

    /// Get supply for `CoinType`.
    /// Would throw error if supply for `CoinType` doesn't exist.
    public fun supply<CoinType>(): u128 {
        option::extract(&mut coin::supply<CoinType>())
    }

    /// Generate LP coin name and symbol for pair `X`/`Y` and curve `Curve`.
    /// Changes for v0.5:
    ///
    /// ```
    ///
    /// (curve_name, curve_symbol) = when(curve) {
    ///     is Uncorrelated -> ("U", "-U")
    ///     is Stable -> ("S", "-S")
    /// }
    /// name = "LiquidLP-" + symbol<X>() + "-" + symbol<Y>() + curve_name;
    /// symbol = symbol<X>()[0:4] + "-" + symbol<Y>()[0:4] + curve_symbol;
    /// ```
    /// For example, for `LP<BTC, USDT, Uncorrelated>`,
    /// the result will be `(b"LiquidLP-BTC-USDT+", b"BTC-USDT+")`
    public fun generate_lp_name_and_symbol<X, Y, Curve>(): (String, String) {
        let lp_name = string::utf8(b"");
        string::append_utf8(&mut lp_name, b"LS05 LP-");
        string::append(&mut lp_name, coin::symbol<X>());
        string::append_utf8(&mut lp_name, b"-");
        string::append(&mut lp_name, coin::symbol<Y>());

        let lp_symbol = string::utf8(b"");
        string::append(&mut lp_symbol, coin_symbol_prefix<X>());
        string::append_utf8(&mut lp_symbol, b"-");
        string::append(&mut lp_symbol, coin_symbol_prefix<Y>());

        let (curve_name, curve_symbol) = if (is_stable<Curve>()) (b"-S", b"S") else (b"-U", b"U");
        string::append_utf8(&mut lp_name, curve_name);
        string::append_utf8(&mut lp_symbol, curve_symbol);

        (lp_name, lp_symbol)
    }

    // todo: update description
    // todo: refactor this file after LP coin => FA transition
    /// Generate LP coin name and symbol for pair `X`/`Y` and curve `Curve`.
    /// Changes for v0.5:
    ///
    /// ```
    ///
    /// (curve_name, curve_symbol) = when(curve) {
    ///     is Uncorrelated -> ("U", "-U")
    ///     is Stable -> ("S", "-S")
    /// }
    /// name = "LiquidLP-" + symbol<X>() + "-" + symbol<Y>() + curve_name;
    /// symbol = symbol<X>()[0:4] + "-" + symbol<Y>()[0:4] + curve_symbol;
    /// ```
    /// For example, for `LP<BTC, USDT, Uncorrelated>`,
    /// the result will be `(b"LiquidLP-BTC-USDT+", b"BTC-USDT+")`
    public fun fa_generate_lp_name_and_symbol<Curve>(x_metadata: Object<Metadata>, y_metadata: Object<Metadata>): (String, String) {
        // todo: ATTENTION, add FA metadata addr to LP name generation to prevent collisions?
        let lp_name = string::utf8(b"");
        string::append_utf8(&mut lp_name, b"LS05 LP-");
        string::append(&mut lp_name, fungible_asset::symbol(x_metadata));
        string::append_utf8(&mut lp_name, b"-");
        string::append(&mut lp_name, fungible_asset::symbol(y_metadata));

        let lp_symbol = string::utf8(b"");
        string::append(&mut lp_symbol, fa_symbol_prefix(x_metadata));
        string::append_utf8(&mut lp_symbol, b"-");
        string::append(&mut lp_symbol, fa_symbol_prefix(y_metadata));

        let (curve_name, curve_symbol) = if (is_stable<Curve>()) (b"-S", b"S") else (b"-U", b"U");
        string::append_utf8(&mut lp_name, curve_name);
        string::append_utf8(&mut lp_symbol, curve_symbol);

        (lp_name, lp_symbol)
    }

    // todo: do we need it at all?
    fun fa_symbol_prefix(fa_metadata: Object<Metadata>): String {
        let symbol = fungible_asset::symbol(fa_metadata);
        let prefix_length = math::min_u64(string::length(&symbol), SYMBOL_PREFIX_LENGTH);
        string::sub_string(&symbol, 0, prefix_length)
    }

    // todo: add desription
    // todo: add tests
    public fun create_pool_obj_name<Curve>(metadata_x: Object<Metadata>, metadata_y: Object<Metadata>): String {
        let pool_obj_name = string::utf8(b"");
        string::append(&mut pool_obj_name, fungible_asset::symbol(metadata_x));
        string::append(&mut pool_obj_name, string_utils::to_string(&object::object_address(&metadata_x)));
        string::append_utf8(&mut pool_obj_name, b"-");
        string::append(&mut pool_obj_name, fungible_asset::symbol(metadata_y));
        string::append(&mut pool_obj_name, string_utils::to_string(&object::object_address(&metadata_y)));
        string::append_utf8(&mut pool_obj_name, b"-");
        string::append_utf8(&mut pool_obj_name, type_info::struct_name(&type_info::type_of<Curve>()));

        pool_obj_name
    }

    fun coin_symbol_prefix<CoinType>(): String {
        let symbol = coin::symbol<CoinType>();
        let prefix_length = math::min_u64(string::length(&symbol), SYMBOL_PREFIX_LENGTH);
        string::sub_string(&symbol, 0, prefix_length)
    }
}
