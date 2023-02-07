/// Implements stable curve math.
module liquidswap_v05::stable_curve {
    /// We take 10^8 as we expect most of the coins to have 6-8 decimals.
    const ONE_E_8: u256 = 100000000;

    /// Get LP value for stable curve: x^3*y + x*y^3
    /// * `x_coin` - reserves of coin X.
    /// * `x_scale` - 10 pow X coin decimals amount.
    /// * `y_coin` - reserves of coin Y.
    /// * `y_scale` - 10 pow Y coin decimals amount.
    public fun lp_value(x_coin: u128, x_scale: u64, y_coin: u128, y_scale: u64): u256 {
        let x_u256 = (x_coin as u256);
        let y_u256 = (y_coin as u256);

        let x_scale_u256 = (x_scale as u256);
        let y_scale_u256 = (y_scale as u256);

        let _x =  (x_u256 * ONE_E_8) / x_scale_u256;
        let _y = (y_u256 * ONE_E_8) / y_scale_u256;

        let _a = _x * _y;

        let _b = (_x * _x) + (_y * _y);
        _a * _b
    }

    /// Get coin amount out by passing amount in, returns amount out (we don't take fees into account here).
    /// It probably would eat a lot of gas and better to do it offchain (on your frontend or whatever),
    /// yet if no other way and need blockchain computation we left it here.
    /// * `coin_in` - amount of coin to swap.
    /// * `scale_in` - 10 pow by coin decimals you want to swap.
    /// * `scale_out` - 10 pow by coin decimals you want to get.
    /// * `reserve_in` - reserves of coin to swap coin_in.
    /// * `reserve_out` - reserves of coin to get in exchange.
    public fun coin_out(coin_in: u128, scale_in: u64, scale_out: u64, reserve_in: u128, reserve_out: u128): u128 {
        let xy = lp_value(reserve_in, scale_in, reserve_out, scale_out);

        let scale_in_u256 = (scale_in as u256);
        let scale_out_u256 = (scale_out as u256);

        let reserve_in_u256 = ((reserve_in as u256) * ONE_E_8) / scale_in_u256;
        let reserve_out_u256 = ((reserve_out as u256) * ONE_E_8) / scale_out_u256;

        let amount_in = ((coin_in as u256) * ONE_E_8) / scale_in_u256;
        let total_reserve = amount_in + reserve_in_u256;
        let y = reserve_out_u256 - get_y(total_reserve, xy, reserve_out_u256);
        let r = (y * scale_out_u256) / ONE_E_8;

        (r as u128)
    }

    /// Get coin amount in by passing amount out, returns amount in (we don't take fees into account here).
    /// It probably would eat a lot of gas and better to do it offchain (on your frontend or whatever),
    /// yet if no other way and need blockchain computation we left it here.
    /// * `coin_out` - amount of coin you want to get.
    /// * `scale_in` - 10 pow by coin decimals you want to swap.
    /// * `scale_out` - 10 pow by coin decimals you want to get.
    /// * `reserve_in` - reserves of coin to swap.
    /// * `reserve_out` - reserves of coin to get in exchange.
    public fun coin_in(coin_out: u128, scale_out: u64, scale_in: u64, reserve_out: u128, reserve_in: u128): u128 {
        let xy = lp_value(reserve_in, scale_in, reserve_out, scale_out);

        let scale_in_u256 = (scale_in as u256);
        let scale_out_u256 = (scale_out as u256);

        let reserve_in_u256 = ((reserve_in as u256) * ONE_E_8) / scale_in_u256;
        let reserve_out_u256 = ((reserve_out as u256) * ONE_E_8) / scale_out_u256;

        let amount_out = ((coin_out as u256) * ONE_E_8) / scale_out_u256;

        let total_reserve = reserve_out_u256 - amount_out;
        let x = get_y(total_reserve, xy, reserve_in_u256) - reserve_in_u256;
        let r = (x * scale_in_u256) / ONE_E_8;

        (r as u128)
    }

    /// Trying to find suitable `y` value.
    /// * `x0` - total reserve x (include `coin_in`) with transformed decimals.
    /// * `xy` - lp value (see `lp_value` func).
    /// * `y` - reserves out with transformed decimals.
    fun get_y(x0: u256, xy: u256, y: u256): u256 {
        let i = 0;

        while (i < 255) {
            let k = f(x0, y);

            let _dy = 0;
            if (k < xy) {
                _dy = ((xy - k) / d(x0, y)) + 1;
                y = y + _dy;
            } else {
                _dy = ((k - xy) / d(x0, y));
                y = y - _dy;
            };

            if (_dy <= 1) {
                return y
            };

            i = i + 1;
        };

        y
    }

    /// Implements x0*y^3 + x0^3*y = x0*(y*y/1e18*y/1e18)/1e18+(x0*x0/1e18*x0/1e18)*y/1e18
    fun f(x0_u256: u256, y_u256: u256): u256 {
        let a = x0_u256 * y_u256 * y_u256 * y_u256;
        let b = y_u256 * x0_u256 * x0_u256 * x0_u256;

        // a + b
        a + b
    }

    /// Implements 3 * x0 * y^2 + x0^3 = 3 * x0 * (y * y / 1e8) / 1e8 + (x0 * x0 / 1e8 * x0) / 1e8
    fun d(x0_u256: u256, y_u256: u256): u256 {
        let three_u256 = 3;

        // 3 * x0 * (y * y / 1e8) / 1e8
        let xyy3 = three_u256 * x0_u256 * y_u256 * y_u256;
        let xxx = x0_u256 * x0_u256 * x0_u256;

        // x0 * x0 / 1e8 * x0 / 1e8
        xyy3 + xxx
    }

    #[test]
    fun test_coin_out() {
        let out = coin_out(
            2513058000,
            1000000,
            100000000,
            25582858050757,
            2558285805075712
        );
        assert!(out == 251305799999, 0);
    }

    #[test]
    fun test_coin_out_vise_vera() {
        let out = coin_out(
            251305800000,
            100000000,
            1000000,
            2558285805075701,
            25582858050757
        );
        assert!(out == 2513057999, 0);
    }

    #[test]
    fun test_get_coin_in() {
        let in = coin_in(
            251305800000,
            100000000,
            1000000,
            2558285805075701,
            25582858050757
        );
        assert!(in == 2513058000, 0);
    }

    #[test]
    fun test_get_coin_in_vise_versa() {
        let in = coin_in(
            2513058000,
            1000000,
            100000000,
            25582858050757,
            2558285805075701
        );
        assert!(in == 251305800001, 0);
    }

    #[test]
    fun test_f() {
        let x0 = 10000518365287;
        let y = 2520572000001255;

        let r = f(x0, y) / 1000000000000000000000000;
        assert!(r == 160149899619106589403934712464197979, 0);

        let r = f(0, 0);
        assert!(r == 0, 1);
    }

    #[test]
    fun test_d() {
        let x0 = 10000518365287;
        let y = 2520572000001255;

        let z = d(x0, y);
        let r = z / 100000000;
        assert!(r == 1906093763356467088703995764640866982, 0);

        let x0 = 5000000000;
        let y = 10000000000000000;

        let z = d(x0, y);
        let r = z / 100000000;

        assert!(r == 15000000000001250000000000000000000, 1);

        let x0 = 1;
        let y = 2;

        let z = d(x0, y);
        let r = z;
        assert!(r == 13, 2);
    }

    #[test]
    fun test_lp_value_compute() {
        // 0.3 ^ 3 * 0.5 + 0.5 ^ 3 * 0.3 = 0.051 (12 decimals)
        let lp_value = lp_value(300000, 1000000, 500000, 1000000);

        assert!(
            lp_value == 5100000000000000000000000000000,
            0
        );

        lp_value = lp_value(
            500000899318256,
            1000000,
            25000567572582123,
            1000000000000
        );

        lp_value = lp_value / 1000000000000000000000000;
        assert!(lp_value == 312508781701599715772756132553838833260, 1);
    }
}
