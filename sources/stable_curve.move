/// Implements stable curve math.
module samm::stable_curve {
    // !!!FOR AUDITOR!!!
    // Please, review this file really carefully and detailed.
    // Some of the functions just migrated from Solidly (BaseV1-core).
    // Some we implemented outself, like coin_in.
    // Also look at all places in all contracts where the functions called and check places too and arguments.
    use samm::bignum::{Self, BigNum};

    /// We take 10^8 as we expect most of the coins to have 6-8 decimals.
    const ONE_E_8: u128 = 100000000;

    /// Get LP value for stable curve: x^3*y + x*y^3
    /// * `x_coin` - reserves of coin X.
    /// * `x_scale` - 10 pow X coin decimals amount.
    /// * `y_coin` - reserves of coin Y.
    /// * `y_scale` - 10 pow Y coin decimals amount.
    public fun lp_value(x_coin: u128, x_scale: u64, y_coin: u128, y_scale: u64): BigNum {
        let x_u256 = bignum::from_u128(x_coin);
        let y_u256 = bignum::from_u128(y_coin);
        let u2561e8 = bignum::from_u128(ONE_E_8);

        let x_scale_u256 = bignum::from_u64(x_scale);
        let y_scale_u256 = bignum::from_u64(y_scale);

        let _x = bignum::div(
            bignum::mul(x_u256, u2561e8),
            x_scale_u256,
        );

        let _y = bignum::div(
            bignum::mul(y_u256, u2561e8),
            y_scale_u256,
        );

        let _a = bignum::mul(_x, _y);

        // ((_x * _x) / 1e18 + (_y * _y) / 1e18)
        let _b = bignum::add(
            bignum::mul(_x, _x),
            bignum::mul(_y, _y),
        );

        bignum::mul(_a, _b)
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
        let u2561e8 = bignum::from_u128(ONE_E_8);

        let xy = lp_value(reserve_in, scale_in, reserve_out, scale_out);

        let reserve_in_u256 = bignum::div(
            bignum::mul(
                bignum::from_u128(reserve_in),
                u2561e8,
            ),
            bignum::from_u64(scale_in),
        );
        let reserve_out_u256 = bignum::div(
            bignum::mul(
                bignum::from_u128(reserve_out),
                u2561e8,
            ),
            bignum::from_u64(scale_out),
        );
        let amount_in = bignum::div(
            bignum::mul(
                bignum::from_u128(coin_in),
                u2561e8
            ),
            bignum::from_u64(scale_in)
        );
        let total_reserve = bignum::add(amount_in, reserve_in_u256);
        let y = bignum::sub(
            reserve_out_u256,
            get_y(total_reserve, xy, reserve_out_u256),
        );

        let r = bignum::div(
            bignum::mul(
                y,
                bignum::from_u64(scale_out),
            ),
            u2561e8
        );

        bignum::as_u128(r)
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
        let u2561e8 = bignum::from_u128(ONE_E_8);

        let xy = lp_value(reserve_in, scale_in, reserve_out, scale_out);

        let reserve_in_u256 = bignum::div(
            bignum::mul(
                bignum::from_u128(reserve_in),
                u2561e8,
            ),
            bignum::from_u64(scale_in),
        );
        let reserve_out_u256 = bignum::div(
            bignum::mul(
                bignum::from_u128(reserve_out),
                u2561e8,
            ),
            bignum::from_u64(scale_out),
        );
        let amount_out = bignum::div(
            bignum::mul(
                bignum::from_u128(coin_out),
                u2561e8
            ),
            bignum::from_u64(scale_out)
        );

        let total_reserve = bignum::sub(reserve_out_u256, amount_out);
        let x = bignum::sub(
            get_y(total_reserve, xy, reserve_in_u256),
            reserve_in_u256,
        );
        let r = bignum::div(
            bignum::mul(
                x,
                bignum::from_u64(scale_in),
            ),
            u2561e8
        );

        bignum::as_u128(r)
    }

    /// Trying to find suitable `y` value.
    /// * `x0` - total reserve x (include `coin_in`) with transformed decimals.
    /// * `xy` - lp value (see `lp_value` func).
    /// * `y` - reserves out with transformed decimals.
    fun get_y(x0: BigNum, xy: BigNum, y: BigNum): BigNum {
        let i = 0;

        let one_u256 = bignum::from_u128(1);

        while (i < 255) {
            let k = f(x0, y);

            let _dy = bignum::zero();
            let cmp = bignum::compare(&k, &xy);
            if (cmp == 1) {
                _dy = bignum::add(
                    bignum::div(
                        bignum::sub(xy, k),
                        d(x0, y),
                    ),
                    one_u256    // Round up
                );
                y = bignum::add(y, _dy);
            } else {
                _dy = bignum::div(
                    bignum::sub(k, xy),
                    d(x0, y),
                );
                y = bignum::sub(y, _dy);
            };
            cmp = bignum::compare(&_dy, &one_u256);
            if (cmp == 0 || cmp == 1) {
                return y
            };

            i = i + 1;
        };

        y
    }

    /// Implements x0*y^3 + x0^3*y = x0*(y*y/1e18*y/1e18)/1e18+(x0*x0/1e18*x0/1e18)*y/1e18
    fun f(x0_u256: BigNum, y_u256: BigNum): BigNum {
        // x0*(y*y/1e18*y/1e18)/1e18
        let yy = bignum::mul(y_u256, y_u256);
        let yyy = bignum::mul(yy, y_u256);

        let a = bignum::mul(x0_u256, yyy);

        //(x0*x0/1e18*x0/1e18)*y/1e18
        let xx = bignum::mul(x0_u256, x0_u256);
        let xxx = bignum::mul(xx, x0_u256);
        let b = bignum::mul(xxx, y_u256);

        // a + b
        bignum::add(a, b)
    }

    /// Implements 3 * x0 * y^2 + x0^3 = 3 * x0 * (y * y / 1e8) / 1e8 + (x0 * x0 / 1e8 * x0) / 1e8
    fun d(x0_u256: BigNum, y_u256: BigNum): BigNum {
        let three_u256 = bignum::from_u128(3);

        // 3 * x0 * (y * y / 1e8) / 1e8
        let x3 = bignum::mul(three_u256, x0_u256);
        let yy = bignum::mul(y_u256, y_u256);
        let xyy3 = bignum::mul(x3, yy);
        let xx = bignum::mul(x0_u256, x0_u256);

        // x0 * x0 / 1e8 * x0 / 1e8
        let xxx = bignum::mul(xx, x0_u256);

        bignum::add(xyy3, xxx)
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
        let x0 = bignum::from_u128(10000518365287);
        let y = bignum::from_u128(2520572000001255);

        let r = bignum::as_u128(bignum::div(f(x0, y), bignum::from_u128(1000000000000000000000000)));
        assert!(r == 160149899619106589403934712464197979, 0);

        let r = bignum::as_u128(f(bignum::zero(), bignum::zero()));
        assert!(r == 0, 1);
    }

    #[test]
    fun test_d() {
        let x0 = bignum::from_u128(10000518365287);
        let y = bignum::from_u128(2520572000001255);

        let z = d(x0, y);
        let r = bignum::as_u128(bignum::div(z, bignum::from_u128(100000000)));

        assert!(r == 1906093763356467088703995764640866982, 0);

        let x0 = bignum::from_u128(5000000000);
        let y = bignum::from_u128(10000000000000000);

        let z = d(x0, y);
        let r = bignum::as_u128(bignum::div(z, bignum::from_u128(100000000)));

        assert!(r == 15000000000001250000000000000000000, 1);

        let x0 = bignum::from_u128(1);
        let y = bignum::from_u128(2);

        let z = d(x0, y);
        let r = bignum::as_u128(z);
        assert!(r == 13, 2);
    }

    #[test]
    fun test_lp_value_compute() {
        // 0.3 ^ 3 * 0.5 + 0.5 ^ 3 * 0.3 = 0.051 (12 decimals)
        let lp_value = lp_value(300000, 1000000, 500000, 1000000);

        assert!(
            bignum::as_u128(lp_value) == 5100000000000000000000000000000,
            0
        );

        lp_value = lp_value(
            500000899318256,
            1000000,
            25000567572582123,
            1000000000000
        );

        lp_value = bignum::div(lp_value, bignum::from_u128(1000000000000000000000000));
        assert!(bignum::as_u128(lp_value) == 312508781701599715772756132553838833260, 1);
    }
}
