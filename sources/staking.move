module suipad::staking {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use std::vector;
    use sui::event;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::pay;
    use sui::tx_context::{Self, TxContext};

    const DecimalPrecision: u64 = 10_000;
    // Errors
    const EDecreasingLock: u64 = 1;
    const EStakeLocked: u64 = 2;
    const EInsufficientFunds: u64 = 3;

    // Events
    struct CreateStakePoolEvent has copy, drop {
        staking_pool_id: ID
    }

    struct CreateStakeLockEvent has copy, drop {
        staking_lock_id: ID,
        amount: u64,
        lock_time: u64,
        staking_start_timestamp: u64,
    }

    struct ExtendStakeLockEvent has copy, drop {
        staking_lock_id: ID,
        amount: u64,
        lock_time: u64,
        staking_start_timestamp: u64
    }

    struct WithdrawStakeEvent has copy, drop {
        staking_lock_id: ID,
        amount: u64,
    }

    // State
    struct StakingPool<phantom StakeToken> has key, store {
        id: UID,
        vault: Balance<StakeToken>,
        locks: vector<u64>,
        multipliers: vector<u64>, // *100
        tier_levels: vector<u64>,
        investment_lock_time: u64,
        investment_lock_penalty: u64, // in %
        minimum_amount: u64,
        penalty_receiver: address
    }

    struct StakingLock has key, store {
        id: UID,
        amount: u64,
        staking_start_timestamp: u64,
        lock_time: u64,
        multiplier: u64,
        last_distribution_timestamp: u64,
    }

    // Functions
    // Todo: create staking pool in init function
    entry fun new_staking_pool<StakeToken>(locks: vector<u64>, multipliers: vector<u64>, tier_levels: vector<u64>, minimum_amount: u64, penalty_receiver: address, ctx: &mut TxContext) {
        let staking_pool = StakingPool<StakeToken> {
            id: object::new(ctx),
            vault: balance::zero<StakeToken>(),
            locks: locks,
            multipliers: multipliers,
            tier_levels: tier_levels,
            investment_lock_time: 1296000,
            investment_lock_penalty: 15,
            minimum_amount: minimum_amount,
            penalty_receiver: penalty_receiver
        };

        event::emit(CreateStakePoolEvent{
            staking_pool_id: object::uid_to_inner(&staking_pool.id)
        });

        transfer::share_object(staking_pool)
    }

    entry fun new_stake<StakeToken>(pool: &mut StakingPool<StakeToken>, lock_index: u64, amount: u64, coins: vector<Coin<StakeToken>>, clock: &Clock, ctx: &mut TxContext) {
        assert!(amount >= pool.minimum_amount, EInsufficientFunds);
        
        let lock = StakingLock {
            id: object::new(ctx),
            amount: 0,
            staking_start_timestamp: 0,
            lock_time: 0,
            multiplier: 0,
            last_distribution_timestamp: 0
        };

        let coin = get_coin_from_vec(coins, amount, ctx);
        stake_coins<StakeToken>(pool, &mut lock, coin, lock_index, clock);

        event::emit(CreateStakeLockEvent {
            staking_lock_id: object::uid_to_inner(&lock.id),
            amount: lock.amount,
            lock_time: lock.lock_time,
            staking_start_timestamp: lock.staking_start_timestamp
        });

        transfer::public_transfer(lock, tx_context::sender(ctx))
    }

    entry fun extend_stake<StakeToken>(
        pool: &mut StakingPool<StakeToken>, 
        lock: &mut StakingLock, 
        lock_index: u64, 
        amount: u64, 
        coins: vector<Coin<StakeToken>>, 
        clock: &Clock, 
        ctx: &mut TxContext
    ) {
        event::emit(ExtendStakeLockEvent {
            staking_lock_id: object::uid_to_inner(&lock.id),
            amount: lock.amount,
            lock_time: lock.lock_time,
            staking_start_timestamp: lock.staking_start_timestamp
        });

        let coin = get_coin_from_vec(coins, amount, ctx);
        stake_coins<StakeToken>(pool, lock, coin, lock_index, clock);
    }

    entry fun withdraw<StakeToken>(pool: &mut StakingPool<StakeToken>, lock: StakingLock, clock: &Clock, ctx: &mut TxContext) {
        let lock_end = lock.staking_start_timestamp + lock.lock_time;
        let unlocked_amount = lock.amount;
        assert!(lock_end < clock::timestamp_ms(clock), EStakeLocked);

        let coin_to_withdraw = coin::take(&mut pool.vault, lock.amount, ctx);

        if (lock.last_distribution_timestamp + pool.investment_lock_time > clock::timestamp_ms(clock)){
            // split coin_to_withdraw and send penalty to the penalty receiver
            let total_applicable_penalty = lock.amount / 100 * 15;
            let penalty_per_second = total_applicable_penalty * DecimalPrecision / (pool.investment_lock_time / 100);
            let seconds_left = (lock.last_distribution_timestamp + pool.investment_lock_time - clock::timestamp_ms(clock)) / 100;
            let penalty = (seconds_left * penalty_per_second) / DecimalPrecision;
            
            let penalty_coin = coin::split(&mut coin_to_withdraw, penalty, ctx);
            transfer::public_transfer(penalty_coin, pool.penalty_receiver);
        };

        let StakingLock {
            id: lock_id,
            amount: _,
            staking_start_timestamp: _,
            lock_time: _,
            multiplier: _,
            last_distribution_timestamp: _
        } = lock;

        event::emit(WithdrawStakeEvent{
            staking_lock_id: object::uid_to_inner(&lock_id),
            amount: unlocked_amount
        });

        object::delete(lock_id);
        transfer::public_transfer(coin_to_withdraw, tx_context::sender(ctx))
    }

    public fun update_last_distribution_timestamp(lock: &mut StakingLock, timestamp: u64) {
        lock.last_distribution_timestamp = timestamp;
    }

    fun stake_coins<StakeToken>(pool: &mut StakingPool<StakeToken>, lock: &mut StakingLock, coin: Coin<StakeToken>, lock_index: u64, clock: &Clock) {
        let new_lock_time = *vector::borrow(&pool.locks, lock_index);
        let multiplier = *vector::borrow(&pool.multipliers, lock_index);

        assert!(new_lock_time >= lock.lock_time, EDecreasingLock);

        lock.lock_time = new_lock_time;
        lock.multiplier = multiplier;
        lock.staking_start_timestamp = clock::timestamp_ms(clock);
        lock.amount = lock.amount + coin::value(&coin);

        let stake_balance = coin::into_balance(coin);
        balance::join(&mut pool.vault, stake_balance);
    }

    fun get_coin_from_vec<T>(coins: vector<coin::Coin<T>>, amount: u64, ctx: &mut TxContext): coin::Coin<T>{
        let merged_coins_in = vector::pop_back(&mut coins);
        pay::join_vec(&mut merged_coins_in, coins);
        assert!(coin::value(&merged_coins_in) >= amount, EInsufficientFunds);

        let coin_out = coin::split(&mut merged_coins_in, amount, ctx);

        if (coin::value(&merged_coins_in) > 0) {
            transfer::public_transfer(
                merged_coins_in,
                tx_context::sender(ctx)
            )
        } else {
            coin::destroy_zero(merged_coins_in)
        };

        coin_out
    }

    public fun get_stake_value(lock: &StakingLock): u64 {
        (lock.amount * lock.multiplier) / 100
    }

    public fun get_tier_levels_count<T>(pool: &StakingPool<T>): u64 {
        vector::length(&pool.tier_levels)
    }

    public fun get_tier_level<T>(lock: &StakingLock, pool: &StakingPool<T>): u64 {
        let level = 0;
        let max_level = get_tier_levels_count(pool);
        let stake_value = get_stake_value(lock);

        while (level < max_level && stake_value > *vector::borrow(&pool.tier_levels, level)) {
            level = level + 1;
        };

        level
    }
}