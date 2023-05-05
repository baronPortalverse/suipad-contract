module suipad::staking {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use std::vector;
    use sui::event;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::pay;
    use suip::SUIP::{SUIP};
    use suipad::launchpad::{Launchpad};
    use sui::tx_context::{Self, TxContext};

    friend suipad::campaign;

    const DecimalPrecision: u128 = 10_000_000;
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
    struct StakingPool has key, store {
        id: UID,
        vault: Balance<SUIP>,
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
    fun init(ctx: &mut TxContext) {
        let staking_pool = StakingPool {
            id: object::new(ctx),
            vault: balance::zero<SUIP>(),
            locks: vector::empty<u64>(),
            multipliers: vector::empty<u64>(),
            tier_levels: vector::empty<u64>(),
            investment_lock_time: 1296000,
            investment_lock_penalty: 15,
            minimum_amount: 2_499_999_999_999,
            penalty_receiver: tx_context::sender(ctx)
        };

        vector::push_back(&mut staking_pool.locks, 0);
        vector::push_back(&mut staking_pool.locks, 7_776_000_000);
        vector::push_back(&mut staking_pool.locks, 15_552_000_000);
        vector::push_back(&mut staking_pool.locks, 31_104_000_000);

        vector::push_back(&mut staking_pool.multipliers, 100);
        vector::push_back(&mut staking_pool.multipliers, 130);
        vector::push_back(&mut staking_pool.multipliers, 150);
        vector::push_back(&mut staking_pool.multipliers, 200);

        vector::push_back(&mut staking_pool.tier_levels, 4_999_999_999_999);
        vector::push_back(&mut staking_pool.tier_levels, 9_999_999_999_999);
        vector::push_back(&mut staking_pool.tier_levels, 29_999_999_999_999);
        vector::push_back(&mut staking_pool.tier_levels, 49_999_999_999_999);
        vector::push_back(&mut staking_pool.tier_levels, 99_999_999_999_999);
        vector::push_back(&mut staking_pool.tier_levels, 18_446_744_073_709_551_615);

        event::emit(CreateStakePoolEvent{
            staking_pool_id: object::uid_to_inner(&staking_pool.id)
        });

        transfer::share_object(staking_pool)
    }

    entry fun set_penalty_receiver(_: &Launchpad, pool: &mut StakingPool, receiver: address) {
        pool.penalty_receiver = receiver;
    }

    entry fun new_stake(pool: &mut StakingPool, lock_index: u64, amount: u64, coins: vector<Coin<SUIP>>, clock: &Clock, ctx: &mut TxContext) {
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
        stake_coins(pool, &mut lock, coin, lock_index, clock);

        event::emit(CreateStakeLockEvent {
            staking_lock_id: object::uid_to_inner(&lock.id),
            amount: lock.amount,
            lock_time: lock.lock_time,
            staking_start_timestamp: lock.staking_start_timestamp
        });

        transfer::public_transfer(lock, tx_context::sender(ctx))
    }

    entry fun extend_stake(
        pool: &mut StakingPool, 
        lock: &mut StakingLock, 
        lock_index: u64, 
        amount: u64, 
        coins: vector<Coin<SUIP>>, 
        clock: &Clock, 
        ctx: &mut TxContext
    ) {
        let coin = get_coin_from_vec(coins, amount, ctx);
        stake_coins(pool, lock, coin, lock_index, clock);
        
        event::emit(ExtendStakeLockEvent {
            staking_lock_id: object::uid_to_inner(&lock.id),
            amount: lock.amount,
            lock_time: lock.lock_time,
            staking_start_timestamp: lock.staking_start_timestamp
        });
    }

    entry fun withdraw(pool: &mut StakingPool, lock: StakingLock, clock: &Clock, ctx: &mut TxContext) {
        let lock_end = lock.staking_start_timestamp + lock.lock_time;
        let unlocked_amount = lock.amount;
        assert!(lock_end < clock::timestamp_ms(clock), EStakeLocked);

        let coin_to_withdraw = coin::take(&mut pool.vault, lock.amount, ctx);

        if (lock.last_distribution_timestamp + pool.investment_lock_time > clock::timestamp_ms(clock)){
            // split coin_to_withdraw and send penalty to the penalty receiver
            let total_applicable_penalty = lock.amount / 100 * pool.investment_lock_penalty;
            let penalty_per_second = (total_applicable_penalty as u128) * DecimalPrecision / ((pool.investment_lock_time / 1000) as u128);
            let seconds_left = (lock.last_distribution_timestamp + pool.investment_lock_time - clock::timestamp_ms(clock)) / 1000;
            let penalty = {
                let this = ((seconds_left as u128) * penalty_per_second) / DecimalPrecision;
                (this as u64)
            };
            
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

    public(friend) fun update_last_distribution_timestamp(lock: &mut StakingLock, timestamp: u64) {
        lock.last_distribution_timestamp = timestamp;
    }

    fun stake_coins(pool: &mut StakingPool, lock: &mut StakingLock, coin: Coin<SUIP>, lock_index: u64, clock: &Clock) {
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

    fun get_coin_from_vec(coins: vector<coin::Coin<SUIP>>, amount: u64, ctx: &mut TxContext): coin::Coin<SUIP>{
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

    public fun get_tier_levels_count(pool: &StakingPool): u64 {
        vector::length(&pool.tier_levels)
    }

    public fun get_tier_level(lock: &StakingLock, pool: &StakingPool): u64 {
        let level = 0;
        let max_level = get_tier_levels_count(pool);
        let stake_value = get_stake_value(lock);

        while (level < max_level && stake_value > *vector::borrow(&pool.tier_levels, level)) {
            level = level + 1;
        };

        level
    }
}