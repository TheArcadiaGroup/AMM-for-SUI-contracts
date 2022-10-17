
module samm::pool {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin:: {Self, Coin};
    use sui::balance::{Self, Balance, Supply};
    use samm::bignum;
    use samm::uq64x64;
    use samm::math;
    use sui::event;
    use std::vector;
    use std::type_name;
    use samm::stable_curve;

    const FEE_DIVISOR: u64 = 10000;
    const SWAP_FEE: u64 = 25;
    const STABLE_FEE: u64 = 20;
    const MINIMAL_LIQUIDITY: u64 = 1000;
    const PERCENT_FEE_TO_DAO: u64 = 3000;   // 20% of swap fee to DAO

    /// ERROR CODE
    /// When coins used to create pair have wrong ordering.
    const ERR_WRONG_PAIR_ORDERING: u64 = 100;

    /// When pair already exists on account.
    const ERR_POOL_EXISTS_FOR_PAIR: u64 = 101;

    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_INITIAL_LIQUIDITY: u64 = 102;

    /// When not enough liquidity minted.
    const ERR_NOT_ENOUGH_LIQUIDITY: u64 = 103;

    /// When both X and Y provided for swap are equal zero.
    const ERR_EMPTY_COIN_IN: u64 = 104;

    /// When incorrect INs/OUTs arguments passed during swap and math doesn't work.
    const ERR_INCORRECT_SWAP: u64 = 105;

    /// Incorrect lp coin burn values
    const ERR_INCORRECT_BURN_VALUES: u64 = 106;

    /// When pool doesn't exists for pair.
    const ERR_POOL_DOES_NOT_EXIST: u64 = 107;

    /// When invalid curve passed as argument.
    const ERR_INVALID_CURVE: u64 = 108;

    /// When `initialize()` transaction is signed with any account other than @liquidswap.
    const ERR_NOT_ENOUGH_PERMISSIONS_TO_INITIALIZE: u64 = 109;

    /// When both X and Y provided for flashloan are equal zero.
    const ERR_EMPTY_COIN_LOAN: u64 = 110;

    /// When pool is locked.
    const ERR_POOL_IS_LOCKED: u64 = 111;

    const ERR_INSUFFICIENT_PERMISSION: u64 = 112;

    const ERR_INSUFFICIENT_0_AMOUNT: u64 = 113;
    const ERR_INSUFFICIENT_1_AMOUNT: u64 = 114;
    const ERR_WRONG_AMOUNT: u64 = 115;
    const ERR_WRONG_RESERVE: u64 = 116;
    const ERR_OVERLIMIT_0: u64 = 117;
    const ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM: u64 = 118;
    const ERR_EMERGENCY: u64 = 119;
    const ERR_PAIR_CANT_BE_SAME_TYPE: u64 = 120;
    const ERR_UNREACHABLE: u64 = 121;

    struct ConstantCurve {}
    struct StableCurve {}

    struct LP<phantom CT0, phantom CT1, phantom Curve> has drop {}

    struct Pool<phantom CT0, phantom CT1, phantom Curve> has key {
        id: UID,
        reserve_0: Balance<CT0>,
        reserve_1: Balance<CT1>,
        last_block_timestamp: u64,
        last_price_cumulative_0: u128,
        last_price_cumulative_1: u128,
        lps: Supply<LP<CT0, CT1, Curve>>,
        locked: bool,
        scale_0: u64,
        scale_1: u64
    }

    struct FlashLoan<phantom CT0, phantom CT1, phantom Curve> has key {
        id: UID,
        coin0_loan: u64,
        coin1_loan: u64
    }

    struct PoolConfig has key {
        id: UID,
        admin: address,
        dao_address: address,
        emercency: bool
    }

    struct PoolIdsList has key {
        id: UID,
        pool_ids: vector<address>
    }

    struct PoolCreatedEvent<phantom CT0, phantom CT1, phantom Curve> has copy, drop {
        creator: address,
    }

    struct PoolIdCreated has copy, drop {
        pool_id: address
    }

    struct LiquidityAddedEvent<phantom CT0, phantom CT1, phantom Curve> has copy, drop {
        added_0_val: u64,
        added_1_val: u64,
        lp_tokens_received: u64
    }

    struct LiquidityRemovedEvent<phantom CT0, phantom CT1, phantom Curve> has copy, drop {
        returned_0_val: u64,
        returned_1_val: u64,
        lp_tokens_burned: u64
    }

    struct SwapEvent<phantom CT0, phantom CT1, phantom Curve> has copy, drop {
        coin0_in: u64,
        coin0_out: u64,
        coin1_in: u64,
        coin1_out: u64,
    }

    struct FlashloanEvent<phantom CT0, phantom CT1, phantom Curve> has copy, drop {
        coin0_in: u64,
        coin0_out: u64,
        coin1_in: u64,
        coin1_out: u64
    }

    struct OracleUpdatedEvent<phantom CT0, phantom CT1, phantom Curve> has copy, drop {
        last_price_cumulative_0: u128,
        last_price_cumulative_1: u128,
    }

    fun assert_admin(config: &PoolConfig, ctx: &TxContext) {
        let sender = tx_context::sender(ctx);
        assert!(sender == config.admin, ERR_INSUFFICIENT_PERMISSION);
    }

    fun assert_no_emergency(config: &PoolConfig) {
        assert!(!config.emercency, ERR_EMERGENCY);
    }

    /// Aborts if pool is locked.
    fun assert_pool_unlocked<CT0, CT1, Curve>(pool: &Pool<CT0, CT1, Curve>) {
        assert!(pool.locked == false, ERR_POOL_IS_LOCKED);
    }

    /// Check if pool is locked.
    public fun is_pool_locked<CT0, CT1, Curve>(pool: &Pool<CT0, CT1, Curve>): bool {
        pool.locked
    }

    public entry fun change_admin(config: &mut PoolConfig, new_admin: address, ctx: &mut TxContext) {
        assert_admin(config, ctx);
        config.admin = new_admin
    }

    public entry fun change_dao_address(config: &mut PoolConfig, new_dao: address, ctx: &mut TxContext) {
        assert_admin(config, ctx);
        config.dao_address = new_dao
    }

    public entry fun set_emergency(config: &mut PoolConfig, emercency: bool, ctx: &mut TxContext) {
        assert_admin(config, ctx);
        config.emercency = emercency
    }

    fun get_current_time_seconds(): u64 {
        1
    }

    fun init(ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        transfer::share_object(PoolConfig {
            id: object::new(ctx),
            admin: sender,
            dao_address: sender,
            emercency: false
        });

        transfer::share_object(PoolIdsList {
            id: object::new(ctx),
            pool_ids: vector::empty()
        })
    }

    fun compute_lp(current_lp: u64, reserve_0: u64, reserve_1: u64, provide_0: u64, provide_1: u64): u64 {
        if (current_lp == 0) {
            let initial_liq = math::sqrt(math::mul_to_u128(provide_0, provide_1));
            assert!(initial_liq > MINIMAL_LIQUIDITY, ERR_NOT_ENOUGH_INITIAL_LIQUIDITY);
            initial_liq - MINIMAL_LIQUIDITY
        } else {
            let x_liq = math::mul_div_u128((provide_0 as u128), (current_lp as u128), (reserve_0 as u128));
            let y_liq = math::mul_div_u128((provide_1 as u128), (current_lp as u128), (reserve_1 as u128));
            if (x_liq < y_liq) {
                x_liq
            } else {
                y_liq
            }
        }
    }

    // pool creators should provide decimals for stable pools as 
    // there is no decimals in coin
    public fun create_pool<CT0, CT1, Curve>(
                        config: &PoolConfig,
                        pool_ids_list: &mut PoolIdsList,
                        coin0: Coin<CT0>,
                        coin1: Coin<CT1>,
                        decimals_0: u64,   
                        decimals_1: u64,
                        ctx: &mut TxContext): Coin<LP<CT0, CT1, Curve>> {
        assert_no_emergency(config);
        assert_valid_curve<Curve>();
        // this should check if duplicate pool with the same pair
        assert_sorted<CT0, CT1>();
        let lp_supply = balance::create_supply<LP<CT0, CT1, Curve>>(LP<CT0, CT1, Curve> {});

        let provide_0_val = coin::value<CT0>(&coin0);
        let provide_1_val = coin::value<CT1>(&coin1);

        let lp_amount = compute_lp(0, 0, 0, provide_0_val, provide_1_val);

        assert!(lp_amount > 0, ERR_NOT_ENOUGH_LIQUIDITY);

        let lp_coin = coin::from_balance(balance::increase_supply<LP<CT0, CT1, Curve>>(&mut lp_supply, lp_amount), ctx);

        let scale_0 = 0;
        let scale_1 = 0;

        if (is_stable<Curve>()) {
            scale_0 = decimals_0;
            scale_1 = decimals_1;
        };


        let pool = Pool<CT0, CT1, Curve> {
            id: object::new(ctx),
            reserve_0: coin::into_balance<CT0>(coin0),
            reserve_1: coin::into_balance<CT1>(coin1),
            last_block_timestamp: get_current_time_seconds(),
            last_price_cumulative_0: 0,
            last_price_cumulative_1: 0,
            lps: lp_supply,
            locked: false,
            scale_0, 
            scale_1
        };

        let pool_id = object::id_address(&pool);

        transfer::share_object(pool);

        vector::push_back(&mut pool_ids_list.pool_ids, pool_id);

        event::emit(
            PoolCreatedEvent<CT0, CT1, Curve> {
                creator: tx_context::sender(ctx)
            }
        );

        event::emit(
            PoolIdCreated {
                pool_id: pool_id
            }
        );

        lp_coin
    }

    public entry fun create_pool_script<CT0, CT1, Curve>(config: &PoolConfig, pool_ids_list: &mut PoolIdsList, coin0: Coin<CT0>, coin1: Coin<CT1>, decimals_0: u64, decimals_1: u64, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        transfer::transfer(create_pool<CT0, CT1, Curve>(config, pool_ids_list, coin0, coin1, decimals_0, decimals_1, ctx), sender);
    }

    public fun add_liquidity<CT0, CT1, Curve>(
                            config: &PoolConfig,
                            pool: &mut Pool<CT0, CT1, Curve>, 
                            coin0: Coin<CT0>,
                            min_coin0_val: u64,
                            coin1: Coin<CT1>,
                            min_coin1_val: u64,
                            ctx: &mut TxContext): (Coin<CT0>, Coin<CT1>, Coin<LP<CT0, CT1, Curve>>) {
        assert_no_emergency(config);        
        assert_sorted<CT0, CT1>();
        assert_pool_unlocked<CT0, CT1, Curve>(pool);
        let provide_0_val = coin::value<CT0>(&coin0);
        let provide_1_val = coin::value<CT1>(&coin1);

        assert!(provide_0_val >= min_coin0_val, ERR_INSUFFICIENT_0_AMOUNT);
        assert!(provide_1_val >= min_coin1_val, ERR_INSUFFICIENT_1_AMOUNT);

        let (reserve_0_val, reserve_1_val) = get_reserves<CT0, CT1, Curve>(pool);

        let (optimal_0, optimal_1) =
            compute_optimal_coin_values(
                reserve_0_val,
                reserve_1_val,
                provide_0_val,
                provide_1_val,
                min_coin0_val,
                min_coin1_val
            );
        
        let balance_0 = coin::into_balance(coin0);
        let balance_1 = coin::into_balance(coin1);

        let coin_0_opt = coin::take(&mut balance_0, optimal_0, ctx);
        let coin_1_opt = coin::take(&mut balance_1, optimal_1, ctx);

        let lp_amount = compute_lp(balance::supply_value<LP<CT0, CT1, Curve>>(&pool.lps), reserve_0_val, reserve_1_val, optimal_0, optimal_1);
        assert!(lp_amount > 0, ERR_NOT_ENOUGH_LIQUIDITY);

        balance::join<CT0>(&mut pool.reserve_0, coin::into_balance(coin_0_opt));
        balance::join<CT1>(&mut pool.reserve_1, coin::into_balance(coin_1_opt));

        let lp_coin = coin::from_balance(balance::increase_supply<LP<CT0, CT1, Curve>>(&mut pool.lps, lp_amount), ctx);

        event::emit(
            LiquidityAddedEvent<CT0, CT1, Curve> {
                added_0_val: provide_0_val,
                added_1_val: provide_1_val,
                lp_tokens_received: lp_amount
            }
        );

        (coin::from_balance(balance_0, ctx), coin::from_balance(balance_1, ctx), lp_coin)
    }

    public entry fun add_liquidity_script<CT0, CT1, Curve>(
                                        config: &PoolConfig,
                                        pool: &mut Pool<CT0, CT1, Curve>, 
                                        coin0: Coin<CT0>, 
                                        coin0_desired_val: u64,
                                        min_coin0_val: u64, 
                                        coin1: Coin<CT1>, 
                                        coin1_desired_val: u64,
                                        min_coin1_val: u64, 
                                        ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        
        let balance_0_input = coin::into_balance(coin0);
        let balance_1_input = coin::into_balance(coin1);

        let coin_0_desired = coin::take(&mut balance_0_input, coin0_desired_val, ctx);
        let coin_1_desired = coin::take(&mut balance_1_input, coin1_desired_val, ctx);

        transfer::transfer(coin::from_balance(balance_0_input, ctx), sender);
        transfer::transfer(coin::from_balance(balance_1_input, ctx), sender);

        let (coin0, coin1, coin_lp) = add_liquidity<CT0, CT1, Curve>(config, pool, coin_0_desired, min_coin0_val, coin_1_desired, min_coin1_val, ctx);
        transfer::transfer(coin0, sender);
        transfer::transfer(coin1, sender);
        transfer::transfer(coin_lp, sender);
    }

    public fun remove_liquidity<CT0, CT1, Curve>(
                                        config: &PoolConfig,
                                        pool: &mut Pool<CT0, CT1, Curve>, 
                                        lp_coin: Coin<LP<CT0, CT1, Curve>>, 
                                        min_coin0_out: u64,
                                        min_coin1_out: u64,
                                        ctx: &mut TxContext): (Coin<CT0>, Coin<CT1>) {
        assert_no_emergency(config);
        assert_sorted<CT0, CT1>();
        assert_pool_unlocked<CT0, CT1, Curve>(pool);
        let burned_lp_coin_val = coin::value(&lp_coin);
        
        let lp_coin_total = balance::supply_value<LP<CT0, CT1, Curve>>(&pool.lps);
        let (reserve_0_val, reserve_1_val) = get_reserves<CT0, CT1, Curve>(pool);

        let coin0_to_return_val = math::mul_div_u128((burned_lp_coin_val as u128), (reserve_0_val as u128), (lp_coin_total as u128));
        let coin1_to_return_val = math::mul_div_u128((burned_lp_coin_val as u128), (reserve_1_val as u128), (lp_coin_total as u128));
        assert!(coin0_to_return_val > 0 && coin1_to_return_val > 0, ERR_INCORRECT_BURN_VALUES);

        assert!(
            coin0_to_return_val >= min_coin0_out,
            ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
        );
        assert!(
            coin1_to_return_val >= min_coin1_out,
            ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
        );

        //withdraw coins from reserve
        let coin0_to_return = coin::take<CT0>(&mut pool.reserve_0, coin0_to_return_val, ctx);
        let coin1_to_return = coin::take<CT1>(&mut pool.reserve_1, coin1_to_return_val, ctx);

        update_cumulative_prices<CT0, CT1, Curve>(pool, reserve_0_val, reserve_1_val);
        balance::decrease_supply<LP<CT0, CT1, Curve>>(&mut pool.lps, coin::into_balance(lp_coin));

        event::emit(
            LiquidityRemovedEvent<CT0, CT1, Curve> {
                returned_0_val: coin0_to_return_val,
                returned_1_val: coin1_to_return_val,
                lp_tokens_burned: burned_lp_coin_val
            }
        );

        (coin0_to_return, coin1_to_return)
    }   

    public entry fun remove_liquidity_script<CT0, CT1, Curve>(
                                            config: &PoolConfig,
                                            pool: &mut Pool<CT0, CT1, Curve>, 
                                            lp_coin: Coin<LP<CT0, CT1, Curve>>, 
                                            lp_amount: u64,
                                            min_coin0_out: u64,
                                            min_coin1_out: u64,
                                            ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);

        let lp_balance = coin::into_balance(lp_coin);
        let lp_coin_input = coin::take(&mut lp_balance, lp_amount, ctx);
        transfer::transfer(coin::from_balance(lp_balance, ctx), sender);
        let (coin0, coin1) = remove_liquidity<CT0, CT1, Curve>(config, pool, lp_coin_input, min_coin0_out, min_coin1_out, ctx);
        let sender = tx_context::sender(ctx);
        transfer::transfer(coin0, sender);
        transfer::transfer(coin1, sender);       
    }

    public fun swap_to_1<CT0, CT1, Curve>(config: &PoolConfig, pool: &mut Pool<CT0, CT1, Curve>, coin0_in: Coin<CT0>, coin1_out_val: u64, ctx: &mut TxContext): Coin<CT1> {
        assert_no_emergency(config);        
        assert_sorted<CT0, CT1>();
        assert_pool_unlocked<CT0, CT1, Curve>(pool);
        let coin0_in_val = coin::value(&coin0_in);

        assert!(coin0_in_val > 0, ERR_EMPTY_COIN_IN);
        let (reserve_0_val, reserve_1_val) = get_reserves<CT0, CT1, Curve>(pool);

        // deposit coin0 into pool
        balance::join<CT0>(&mut pool.reserve_0, coin::into_balance<CT0>(coin0_in));

        let out_1_val_swapped = balance::split<CT1>(&mut pool.reserve_1, coin1_out_val);

        let (x_res_new_after_fee, y_res_new_after_fee) =
            compute_reserves_after_fees<Curve>(
                balance::value(&pool.reserve_0),
                balance::value(&pool.reserve_1),
                coin0_in_val,
                0,
            );
        assert_lp_value_increase<Curve>(
            pool.scale_0,
            pool.scale_1,
            (reserve_0_val as u128),
            (reserve_1_val as u128),
            x_res_new_after_fee,
            y_res_new_after_fee,
        );
        distribute_fee_to_dao(config, pool, coin0_in_val, 0, ctx);
        update_cumulative_prices<CT0, CT1, Curve>(pool, coin0_in_val, 0);

        event::emit(
            SwapEvent<CT0, CT1, Curve> {
                coin0_in: coin0_in_val,
                coin0_out: 0,
                coin1_in: 0,
                coin1_out: coin1_out_val
            }
        );

        coin::from_balance<CT1>(out_1_val_swapped, ctx)
    }

    public entry fun swap_to_1_script<CT0, CT1, Curve>(config: &PoolConfig, pool: &mut Pool<CT0, CT1, Curve>, coin0_in: Coin<CT0>, coin0_desired_val: u64, coin1_out_val: u64, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        
        let coin0_balance = coin::into_balance(coin0_in);
        let coin0_input = coin::take(&mut coin0_balance, coin0_desired_val, ctx);

        transfer::transfer(coin::from_balance(coin0_balance, ctx), sender);
        let coin1_out = swap_to_1<CT0, CT1, Curve>(config, pool, coin0_input, coin1_out_val, ctx);
        transfer::transfer(coin1_out, sender);
    }

    public fun swap_to_0<CT0, CT1, Curve>(config: &PoolConfig, pool: &mut Pool<CT0, CT1, Curve>, coin1_in: Coin<CT1>, coin0_out_val: u64, ctx: &mut TxContext): Coin<CT0> {
        assert_no_emergency(config);
        assert_sorted<CT0, CT1>();
        assert_pool_unlocked<CT0, CT1, Curve>(pool);
        let coin1_in_val = coin::value(&coin1_in);

        assert!(coin1_in_val > 0, ERR_EMPTY_COIN_IN);
        let (reserve_0_val, reserve_1_val) = get_reserves<CT0, CT1, Curve>(pool);

        // deposit coin0 into pool
        balance::join<CT1>(&mut pool.reserve_1, coin::into_balance<CT1>(coin1_in));

        let out_0_val_swapped = balance::split<CT0>(&mut pool.reserve_0, coin0_out_val);

        let (x_res_new_after_fee, y_res_new_after_fee) =
            compute_reserves_after_fees<Curve>(
                balance::value(&pool.reserve_0),
                balance::value(&pool.reserve_1),
                0,
                coin1_in_val
            );
        assert_lp_value_increase<Curve>(
            pool.scale_0,
            pool.scale_1,
            (reserve_0_val as u128),
            (reserve_1_val as u128),
            x_res_new_after_fee,
            y_res_new_after_fee,
        );
        distribute_fee_to_dao(config, pool, 0, coin1_in_val, ctx);

        update_cumulative_prices<CT0, CT1, Curve>(pool, 0, coin1_in_val);

        event::emit(
            SwapEvent<CT0, CT1, Curve> {
                coin0_in: 0,
                coin0_out: coin0_out_val,
                coin1_in: coin1_in_val,
                coin1_out: 0
            }
        );

        coin::from_balance<CT0>(out_0_val_swapped, ctx)
    }

    public entry fun swap_to_0_script<CT0, CT1, Curve>(config: &PoolConfig, pool: &mut Pool<CT0, CT1, Curve>, coin1_in: Coin<CT1>, coin1_desired_val: u64, coin0_out_val: u64, ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        
        let coin1_balance = coin::into_balance(coin1_in);
        let coin1_input = coin::take(&mut coin1_balance, coin1_desired_val, ctx);

        transfer::transfer(coin::from_balance(coin1_balance, ctx), sender);
        let coin0_out = swap_to_0<CT0, CT1, Curve>(config, pool, coin1_input, coin0_out_val, ctx);
        transfer::transfer(coin0_out, sender);
    }

    public fun create_flashloan<CT0, CT1, Curve>(config: &PoolConfig, pool: &mut Pool<CT0, CT1, Curve>, coin0_amount: u64, coin1_amount: u64, ctx: &mut TxContext):(Coin<CT0>, Coin<CT1>, FlashLoan<CT0, CT1, Curve>) {
        assert_no_emergency(config);
        assert_sorted<CT0, CT1>();

        assert_pool_unlocked<CT0, CT1, Curve>(pool);

        assert!(coin0_amount > 0 || coin1_amount > 0, ERR_EMPTY_COIN_LOAN);

        let (reserve_0_val, reserve_1_val) = get_reserves<CT0, CT1, Curve>(pool);

        // borrow expected amount from reserves.
        let coin0 = coin::take(&mut pool.reserve_0, coin0_amount, ctx);
        let coin1 = coin::take(&mut pool.reserve_1, coin1_amount, ctx);


        // The pool will be locked after the loan until payment.
        pool.locked = true;

        update_cumulative_prices(pool, reserve_0_val, reserve_1_val);

        // Return loaned amount.
        (coin0, coin1, FlashLoan<CT0, CT1, Curve> {id: object::new(ctx), coin0_loan: coin0_amount, coin1_loan: coin1_amount })
    }

    /// Pay flash loan coins.
    public fun pay_flashloan<CT0, CT1, Curve>(
        config: &PoolConfig,
        coin0_in: Coin<CT0>,
        coin1_in: Coin<CT1>,
        loan: FlashLoan<CT0, CT1, Curve>,
        pool: &mut Pool<CT0, CT1, Curve>,
        ctx: &mut TxContext
    ) {
        assert_no_emergency(config);
        assert_sorted<CT0, CT1>();

        let FlashLoan {id, coin0_loan, coin1_loan } = loan;

        let coin0_in_val = coin::value(&coin0_in);
        let coin1_in_val = coin::value(&coin1_in);

        assert!(coin0_in_val > 0 || coin1_in_val > 0, ERR_EMPTY_COIN_IN);

        let (reserve_0_val, reserve_1_val) = get_reserves<CT0, CT1, Curve>(pool);

        // Reserve sizes before loan out
        reserve_0_val = reserve_0_val + coin0_loan;
        reserve_1_val = reserve_1_val + coin1_loan;

        // Deposit new coins to liquidity pool.
        coin::put(&mut pool.reserve_0, coin0_in);
        coin::put(&mut pool.reserve_1, coin1_in);

        // Confirm that lp_value for the pool hasn't been reduced.
        let (x_res_new_after_fee, y_res_new_after_fee) =
            compute_reserves_after_fees<Curve>(
                balance::value(&pool.reserve_0),
                balance::value(&pool.reserve_1),
                coin0_in_val,
                coin1_in_val,
            );

        assert_lp_value_increase<Curve>(
            pool.scale_0,
            pool.scale_1,
            (reserve_0_val as u128),
            (reserve_1_val as u128),
            x_res_new_after_fee,
            y_res_new_after_fee,
        );

        // third of all fees goes into DAO
        distribute_fee_to_dao(config, pool, coin0_in_val, coin1_in_val, ctx);

        // The pool will be unlocked after payment.
        pool.locked = false;
        
        object::delete(id);

        event::emit(
            FlashloanEvent<CT0, CT1, Curve> {
                coin0_in: coin0_in_val,
                coin0_out: coin0_loan,
                coin1_in: coin1_in_val,
                coin1_out: coin1_loan
            }
        );
    }

    fun update_cumulative_prices<CT0, CT1, Curve>(pool: &mut Pool<CT0, CT1, Curve>, reserve_0_val: u64, reserve_1_val: u64) {
        let last_block_timestamp = pool.last_block_timestamp;

        let block_timestamp = get_current_time_seconds();

        let time_elapsed = ((block_timestamp - last_block_timestamp) as u128);

        if (time_elapsed > 0 && reserve_0_val != 0 && reserve_1_val != 0) {
            let last_price_0_cumulative = uq64x64::to_u128(uq64x64::fraction(reserve_1_val, reserve_0_val)) * time_elapsed;
            let last_price_1_cumulative = uq64x64::to_u128(uq64x64::fraction(reserve_0_val, reserve_1_val)) * time_elapsed;

            pool.last_price_cumulative_0 = math::overflow_add(pool.last_price_cumulative_0, last_price_0_cumulative);
            pool.last_price_cumulative_1 = math::overflow_add(pool.last_price_cumulative_1, last_price_1_cumulative);

            event::emit(
                OracleUpdatedEvent<CT0, CT1, Curve> {
                    last_price_cumulative_0: pool.last_price_cumulative_0,
                    last_price_cumulative_1: pool.last_price_cumulative_1
                }
            );
        };

        pool.last_block_timestamp = block_timestamp;
    }

    // * `pool` - pool to extract coins.
    // * `x_in_val` - how much X coins was deposited to pool.
    // * `y_in_val` - how much Y coins was deposited to pool.
    fun distribute_fee_to_dao<CT0, CT1, Curve>(
        config: &PoolConfig,
        pool: &mut Pool<CT0, CT1, Curve>,
        coin0_in_val: u64,
        coin1_in_val: u64,
        ctx: &mut TxContext
    ) {
        let dao_0_fee_val = math::mul_div(coin0_in_val, SWAP_FEE, FEE_DIVISOR);
        dao_0_fee_val = dao_0_fee_val * PERCENT_FEE_TO_DAO / FEE_DIVISOR;
        let dao_1_fee_val = math::mul_div(coin1_in_val, SWAP_FEE, FEE_DIVISOR);
        dao_1_fee_val = dao_1_fee_val * PERCENT_FEE_TO_DAO / FEE_DIVISOR;

        if (dao_0_fee_val > 0) {
            let dao_0_in = coin::take(&mut pool.reserve_0, dao_0_fee_val, ctx);
            transfer::transfer(dao_0_in, config.dao_address);
        };
        if (dao_1_fee_val > 0) {
            let dao_1_in = coin::take(&mut pool.reserve_1, dao_1_fee_val, ctx);
            transfer::transfer(dao_1_in, config.dao_address);
        }
    }

    /// Compute and verify LP value after and before swap, in nutshell, _k function.
    /// Aborts if swap can't be done.
    fun assert_lp_value_increase<Curve>(
        x_scale: u64,
        y_scale: u64,
        x_res: u128,
        y_res: u128,
        x_res_with_fees: u128,
        y_res_with_fees: u128,
    ) {
        if (is_stable<Curve>()) {
            let lp_value_before_swap = stable_curve::lp_value(x_res, x_scale, y_res, y_scale);
            let lp_value_after_swap_and_fee = stable_curve::lp_value(x_res_with_fees, x_scale, y_res_with_fees, y_scale);

            let cmp = bignum::compare(&lp_value_after_swap_and_fee, &lp_value_before_swap);
            assert!(cmp == 2, ERR_INCORRECT_SWAP);
        } else if (is_constant<Curve>()) {
            let lp_value_before_swap = x_res * y_res;
            let lp_value_before_swap_u256 = bignum::mul(
                bignum::from_u128(lp_value_before_swap),
                bignum::from_u64(FEE_DIVISOR * FEE_DIVISOR)
            );
            let lp_value_after_swap_and_fee = bignum::mul(
                bignum::from_u128(x_res_with_fees),
                bignum::from_u128(y_res_with_fees),
            );

            let cmp = bignum::compare(&lp_value_after_swap_and_fee, &lp_value_before_swap_u256);
            assert!(cmp == 2, ERR_INCORRECT_SWAP);
        } else {
            abort ERR_UNREACHABLE
        }
    }

    /// Get reserves after fees.
    fun compute_reserves_after_fees<Curve> (
        x_reserve: u64,
        y_reserve: u64,
        x_in_val: u64,
        y_in_val: u64
    ): (u128, u128) {        
        let x_res_new_after_fee = if (is_constant<Curve>()) {
            math::mul_to_u128(x_reserve, FEE_DIVISOR) - math::mul_to_u128(x_in_val, SWAP_FEE)
        } else if (is_stable<Curve>()) {
            ((x_reserve - math::mul_div(x_in_val, STABLE_FEE, FEE_DIVISOR)) as u128)
        } else {
            abort ERR_UNREACHABLE
        };

        let y_res_new_after_fee = if (is_constant<Curve>()) {
            math::mul_to_u128(y_reserve, FEE_DIVISOR) - math::mul_to_u128(y_in_val, SWAP_FEE)
        } else if (is_stable<Curve>()) {
            ((y_reserve - math::mul_div(y_in_val, STABLE_FEE, FEE_DIVISOR)) as u128)
        } else {
            abort ERR_UNREACHABLE
        };
        
        (x_res_new_after_fee, y_res_new_after_fee)
    }

    public fun get_reserves<CT0, CT1, Curve>(pool: &Pool<CT0, CT1, Curve>): (u64, u64) {
        (balance::value<CT0>(&pool.reserve_0), balance::value<CT1>(&pool.reserve_1))
    }

    /// Get current cumulative prices.
    /// Cumulative prices can be overflowed, so take it into account before work with the following function.
    /// It's important to use same logic in your math/algo (as Move doesn't allow overflow).
    /// Returns (X price, Y price, block_timestamp).
    public fun get_cumulative_prices<CT0, CT1, Curve>(pool: &Pool<CT0, CT1, Curve>): (u128, u128, u64) {
        assert_sorted<CT0, CT1>();

        assert_pool_unlocked<CT0, CT1, Curve>(pool);

        let last_price_0_cumulative = *&pool.last_price_cumulative_0;
        let last_price_1_cumulative = *&pool.last_price_cumulative_1;
        let last_block_timestamp = pool.last_block_timestamp;

        (last_price_0_cumulative, last_price_1_cumulative, last_block_timestamp)
    }

    /// Calculate amounts needed for adding new liquidity 
    /// Returns both coins amounts.
    public fun compute_optimal_coin_values(
        reserve_0: u64,
        reserve_1: u64,
        coin0_desired: u64,
        coin1_desired: u64,
        coin0_min: u64,
        coin1_min: u64
    ): (u64, u64) {
        if (reserve_0 == 0 && reserve_1 == 0) {
            return (coin0_desired, coin1_desired)
        } else {
            let coin1_returned = convert_with_current_price(coin0_desired, reserve_0, reserve_1);
            if (coin1_returned <= coin1_desired) {
                assert!(coin1_returned >= coin1_min, ERR_INSUFFICIENT_1_AMOUNT);
                return (coin0_desired, coin1_returned)
            } else {
                let coin0_returned = convert_with_current_price(coin1_desired, reserve_1, reserve_0);
                assert!(coin0_returned <= coin0_desired, ERR_OVERLIMIT_0);
                assert!(coin0_returned >= coin0_min, ERR_INSUFFICIENT_0_AMOUNT);
                return (coin0_returned, coin1_desired)
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
        let res = math::mul_div(coin_in, reserve_out, reserve_in);
        (res as u64)
    }

    /// Get most used values in a handy way:
    /// - amount of SUI
    /// - amount of token
    /// - total supply of LSP
    public fun get_amounts<CT0, CT1, Curve>(pool: &Pool<CT0, CT1, Curve>): (u64, u64, u64) {
        (
            balance::value(&pool.reserve_0),
            balance::value(&pool.reserve_1),
            balance::supply_value<LP<CT0, CT1, Curve>>(&pool.lps)
        )
    }

    fun assert_sorted<CT0, CT1>() {
        let ct0_name = type_name::into_string(type_name::get<CT0>());
        let ct1_name = type_name::into_string(type_name::get<CT1>());

        assert!(ct0_name != ct1_name, ERR_PAIR_CANT_BE_SAME_TYPE);

        let ct0_bytes = std::ascii::as_bytes(&ct0_name);
        let ct1_bytes = std::ascii::as_bytes(&ct1_name);

        assert!(vector::length<u8>(ct0_bytes) <= vector::length<u8>(ct1_bytes), ERR_WRONG_PAIR_ORDERING);

        if (vector::length<u8>(ct0_bytes) == vector::length<u8>(ct1_bytes)) {
            let count = vector::length<u8>(ct0_bytes); 
            let i = 0;
            while (i < count) {
                assert!(*vector::borrow<u8>(ct0_bytes, i) <= *vector::borrow<u8>(ct1_bytes, i), ERR_WRONG_PAIR_ORDERING);
            }
        };
    }

    fun assert_valid_curve<Curve>() {
        let curve_name = type_name::into_string(type_name::get<Curve>());

        assert!(curve_name == type_name::into_string(type_name::get<ConstantCurve>()) || curve_name == type_name::into_string(type_name::get<StableCurve>()), ERR_INVALID_CURVE);
    }

    fun is_stable<Curve>(): bool {
        type_name::into_string(type_name::get<Curve>()) == type_name::into_string(type_name::get<StableCurve>())
    }

    fun is_constant<Curve>(): bool {
        type_name::into_string(type_name::get<Curve>()) == type_name::into_string(type_name::get<ConstantCurve>())
    }

    /// Get fees (numerator, denominator).
    public fun get_fees_config(): (u64, u64) {
        (SWAP_FEE, FEE_DIVISOR)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}