/// The `FAHelper` module contains helper funcs to work with `AptosFramework::FungibleAsset` module.
module liquidswap_v05::fa_helper {
    use std::option;
    use std::string::{Self, String};

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

    // Constants.

    /// Length of symbol prefix to be used in LP coin symbol.
    const SYMBOL_PREFIX_LENGTH: u64 = 4;

    /// Compare two FA's, `X` and `Y`, by symbol and metadata address.
    /// Caller should call this function to determine the order of X, Y.
    public fun compare_fa(x_metadata: Object<Metadata>, y_metadata: Object<Metadata>): Result {
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

    /// Check that FA's `X` and`Y` are sorted in correct ordering.
    /// X != Y && X.symbol < Y.symbol is symbs are equal, then X.metadata_addr < Y.symbol.metadata_addr.
    public fun is_fa_sorted(x_metadata: Object<Metadata>, y_metadata: Object<Metadata>): bool {
        let order = compare_fa(x_metadata, y_metadata);
        assert!(!comparator::is_equal(&order), ERR_CANNOT_BE_THE_SAME_FA);
        comparator::is_smaller_than(&order)
    }

    /// Get supply of FungibleAsset.
    /// Would throw error if supply for FungibleAsset doesn't exist.
    public fun fa_supply(fa_metadata: Object<Metadata>): u128 {
        option::extract(&mut fungible_asset::supply(fa_metadata))
    }

    /// Generate LP FA name and symbol for pair `X`/`Y` and curve `Curve`.
    /// Changes for v0.5:
    ///
    /// ```
    ///
    /// (curve_name, curve_symbol) = when(curve) {
    ///     is Uncorrelated -> ("U", "-U")
    ///     is Stable -> ("S", "-S")
    /// }
    /// name = "LiquidLP-" + symbol(x_metadata) + "-" + symbol(y_metadata) + curve_name;
    /// symbol = symbol(x_metadata)[0:4] + "-" + symbol(y_metadata)[0:4] + curve_symbol;
    /// ```
    /// For example, for BTC USDT Uncorrelated pair pool,
    /// the result will be `(b"LS05 LP-BTC-USDT-U", b"BTC-USDTU")`
    public fun fa_generate_lp_name_and_symbol<Curve>(
        x_metadata: Object<Metadata>,
        y_metadata: Object<Metadata>,
    ): (String, String) {
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

    fun fa_symbol_prefix(fa_metadata: Object<Metadata>): String {
        let symbol = fungible_asset::symbol(fa_metadata);
        let prefix_length = math::min_u64(string::length(&symbol), SYMBOL_PREFIX_LENGTH);
        string::sub_string(&symbol, 0, prefix_length)
    }

    #[view]
    /// Generate LiquidityPool object name for pair `X`/`Y` and curve `Curve`.
    /// name = symbol(x_metadata) + address(x_metadata) + "-" + symbol(y_metadata) + address(y_metadata) + "-" + 'Curve';
    ///
    /// For example, for BTC USDT Uncorrelated pair pool,
    /// the result will be `(b"BTC@0xde...f5-USDT@0x7a...b9-Uncorrelated")`
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
}
