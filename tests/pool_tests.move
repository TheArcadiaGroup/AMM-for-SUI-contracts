#[test_only]
module samm::pool_tests {
    use sui::coin::{mint_for_testing as mint, destroy_for_testing as burn};
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use samm::pool::{Self, Pool, PoolConfig, PoolIdsList, ConstantCurve};

    /// Gonna be our test token.
    struct USDT {}
    struct BITCOIN {}

    const USDT_AMT: u64 = 1000000000;
    const BTC_AMT: u64 = 1000000;

    fun scenario(): Scenario { test::begin(@0x1) }
    fun people(): (address, address) { (@0xBEEF, @0x1337) }

    // Tests section
    #[test] fun test_init_pool() { 
        let scenario = scenario();
        test_init_pool_(&mut scenario); 
        end_test(scenario);    
    }

    #[test] 
    #[expected_failure(abort_code = 119)]
    fun test_create_pool_emergency_fail() { 
        let scenario = scenario();
        test_create_pool_emergency_fail_(&mut scenario); 
        end_test(scenario);    
    }

    #[test] 
    #[expected_failure(abort_code = 102)]
    fun test_add_liquidity_less_than_minimal() { 
        let scenario = scenario();
        test_add_liquidity_less_than_minimal_(&mut scenario); 
        end_test(scenario);            
    }
    
    #[test] 
    fun test_add_liquidity_minimal() { 
        let scenario = scenario();
        test_add_liquidity_minimal_(&mut scenario); 
        end_test(scenario);
    }

    fun end_test(scenario: Scenario) {
        test::end(scenario);
    }

    #[test] 
    #[expected_failure(abort_code = 119)]
    fun test_add_liquidity_emergency_stop_fail() { 
        let test_val = scenario();
        let test = &mut test_val;
        let (owner, _) = people();
        next_tx(test, owner); {
            pool::init_for_testing(ctx(test));
        };

        next_tx(test, owner); {
            let config = test::take_shared<PoolConfig>(test);
            let pool_ids_list = test::take_shared<PoolIdsList>(test);
            
            pool::create_pool_script<USDT, BITCOIN, ConstantCurve>(
                &mut config, 
                &mut pool_ids_list, 
                mint<USDT>(1001, ctx(test)),
                mint<BITCOIN>(1001, ctx(test)),
                0,
                0,
                ctx(test)
            );
            pool::set_emergency(&mut config, true, ctx(test));
            test::return_shared(pool_ids_list);
            test::return_shared(config);
        };

        next_tx(test, owner); {
            let config = test::take_shared<PoolConfig>(test);

            let pool = test::take_shared<Pool<USDT, BITCOIN, ConstantCurve>>(test);
            let pool_mut = &mut pool;

            pool::add_liquidity_script<USDT, BITCOIN, ConstantCurve>(
                &mut config, 
                pool_mut,
                mint<USDT>(1001, ctx(test)),
                1001,
                0,
                mint<BITCOIN>(1001, ctx(test)),
                1001,
                0,
                ctx(test)
            );

            test::return_shared(pool);
            test::return_shared(config);
        };
        end_test(test_val)
    }

    /// Init a Pool with a 1_000_000 BEEP and 1_000_000_000 SUI;
    /// Set the ratio BEEP : SUI = 1 : 1000.
    /// Set LSP token amount to 1000;
    fun test_init_pool_(test: &mut Scenario) {
        let (owner, _) = people();
        next_tx(test, owner); {
            pool::init_for_testing(ctx(test));
        };

        next_tx(test, owner); {
            let config = test::take_shared<PoolConfig>(test);
            let pool_ids_list = test::take_shared<PoolIdsList>(test);

            let lsp = pool::create_pool<USDT, BITCOIN, ConstantCurve>(
                &mut config, 
                &mut pool_ids_list, 
                mint<USDT>(USDT_AMT, ctx(test)),
                mint<BITCOIN>(BTC_AMT, ctx(test)),
                0,
                0,
                ctx(test)
            );
            test::return_shared(pool_ids_list);
            test::return_shared(config);
            assert!(burn(lsp) == 31622776 - 1000, 0);
        };

        next_tx(test, owner); {
            let pool = test::take_shared<Pool<USDT, BITCOIN, ConstantCurve>>(test);
            let (amt_poo, amt_bar, lsp_supply) = pool::get_amounts(&mut pool);

            assert!(lsp_supply == 31622776 - 1000, 0);
            assert!(amt_poo == USDT_AMT, 0);
            assert!(amt_bar == BTC_AMT, 0);

            test::return_shared(pool)
        };
    }

    fun test_create_pool_emergency_fail_(test: &mut Scenario) {
        let (owner, _) = people();
        next_tx(test, owner); {
            pool::init_for_testing(ctx(test));
        };

        next_tx(test, owner); {
            let config = test::take_shared<PoolConfig>(test);
            let pool_ids_list = test::take_shared<PoolIdsList>(test);

            let config_mut = &mut config;
            pool::set_emergency(config_mut, true, ctx(test));

            pool::create_pool_script<USDT, BITCOIN, ConstantCurve>(
                config_mut, 
                &mut pool_ids_list, 
                mint<USDT>(USDT_AMT, ctx(test)),
                mint<BITCOIN>(BTC_AMT, ctx(test)),
                0,
                0,
                ctx(test)
            );
            test::return_shared(pool_ids_list);
            test::return_shared(config);
        };
    }

    fun test_add_liquidity_less_than_minimal_(test: &mut Scenario) {
        let (owner, _) = people();
        next_tx(test, owner); {
            pool::init_for_testing(ctx(test));
        };

        next_tx(test, owner); {
            let config = test::take_shared<PoolConfig>(test);
            let pool_ids_list = test::take_shared<PoolIdsList>(test);

            pool::create_pool_script<USDT, BITCOIN, ConstantCurve>(
                &mut config, 
                &mut pool_ids_list, 
                mint<USDT>(1, ctx(test)),
                mint<BITCOIN>(1, ctx(test)),
                0,
                0,
                ctx(test)
            );
            test::return_shared(pool_ids_list);
            test::return_shared(config);
        };
    }

    fun test_add_liquidity_minimal_(test: &mut Scenario) {
        let (owner, _) = people();
        next_tx(test, owner); {
            pool::init_for_testing(ctx(test));
        };

        next_tx(test, owner); {
            let config = test::take_shared<PoolConfig>(test);
            let pool_ids_list = test::take_shared<PoolIdsList>(test);

            pool::create_pool_script<USDT, BITCOIN, ConstantCurve>(
                &mut config, 
                &mut pool_ids_list, 
                mint<USDT>(1001, ctx(test)),
                mint<BITCOIN>(1001, ctx(test)),
                0,
                0,
                ctx(test)
            );
            test::return_shared(pool_ids_list);
            test::return_shared(config);
        };

        next_tx(test, owner); {
            let expected_liquidity = 1;

            let pool = test::take_shared<Pool<USDT, BITCOIN, ConstantCurve>>(test);
            let pool_mut = &mut pool;
            let (_, _, lp_supply) = pool::get_amounts(pool_mut);
            assert!(lp_supply == expected_liquidity, 1);

            test::return_shared(pool);
        };
    }

    fun test_add_liquidity_emergency_stop_fail_(test: &mut Scenario) {
        let (owner, _) = people();
        next_tx(test, owner); {
            pool::init_for_testing(ctx(test));
        };

        next_tx(test, owner); {
            let config = test::take_shared<PoolConfig>(test);
            let pool_ids_list = test::take_shared<PoolIdsList>(test);
            
            pool::create_pool_script<USDT, BITCOIN, ConstantCurve>(
                &mut config, 
                &mut pool_ids_list, 
                mint<USDT>(1001, ctx(test)),
                mint<BITCOIN>(1001, ctx(test)),
                0,
                0,
                ctx(test)
            );
            pool::set_emergency(&mut config, true, ctx(test));

            test::return_shared(pool_ids_list);
            test::return_shared(config);
        };

        next_tx(test, owner); {
            let config = test::take_shared<PoolConfig>(test);

            let pool = test::take_shared<Pool<USDT, BITCOIN, ConstantCurve>>(test);

            pool::add_liquidity_script<USDT, BITCOIN, ConstantCurve>(
                &mut config, 
                &mut pool,
                mint<USDT>(1001, ctx(test)),
                1001,
                0,
                mint<BITCOIN>(1001, ctx(test)),
                1001,
                0,
                ctx(test)
            );

            test::return_shared(pool);
            test::return_shared(config);
        };
    }
}