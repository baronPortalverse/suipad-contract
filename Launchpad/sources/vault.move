module suipad::vault {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use std::vector;
    use sui::event;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::tx_context::{Self, TxContext};

    friend suipad::campaign;

    const DecimalPrecision: u128 = 10_000_000;
    // Errors
    const ECampaignIdMismatch : u64 = 1;
    const EOnlyInvestmentReceiver : u64 = 2;
    const EInvestmentAlreadyClaimed : u64 = 3;
    const ENotEnoughFunds: u64 = 4;
    const ESmallRewardsBalance: u64 = 5;
    const EDistributionNotStarted: u64 = 6;
    const EAllocationExceeded: u64 = 7;

    // Events
    struct WithdrawInvestmentEvent has copy, drop {
        campaign_id: ID,
        amount: u64,
    }

    struct ClaimRewardsEvent has copy, drop {
        campaign_id: ID,
        round: u64,
        amount: u64
    }

    struct RefundInvestmentEvent has copy, drop {
        campaign_id: ID,
        amount: u64
    }

    struct WithdrawUnsoldTokensEvent has copy, drop {
        campaign_id: ID,
        amount: u64
    }

    // Structs
    struct Vault<phantom InvestmentToken, phantom RewardToken> has store, key {
        id: UID,
        campaign_id: ID,
        scheduled_times: vector<u64>,
        scheduled_rewards: vector<u64>,
        target_amount: u64,
        invested_amount: u64,
        total_rewards: u64,
        reward_balance: Balance<RewardToken>,
        investment_balance: Balance<InvestmentToken>,
        start_timestamp: u64,
        investment_receiver: address,
        investment_claimed: bool
    }

    struct InvestCertificate has key, store {
        id: UID,
        campaign_id: ID,
        deposit: u64,
        vesting_applicable_round: u64,
        insured: bool
    }

    // Functions 
    public(friend) fun create<TI, TR> (
        campaign_id: ID,
        scheduled_time: vector<u64>,
        scheduled_reward: vector<u64>,
        target_amount: u64,
        start_timestamp: u64,
        total_rewards: u64,
        investment_receiver: address,
        ctx: &mut TxContext
    ): Vault<TI, TR> {
        Vault<TI, TR> {
            id: object::new(ctx),
            campaign_id: campaign_id,
            scheduled_times: scheduled_time,
            scheduled_rewards: scheduled_reward,
            target_amount: target_amount,
            invested_amount: 0,
            reward_balance: balance::zero<TR>(),
            investment_balance: balance::zero<TI>(),
            start_timestamp: start_timestamp,
            total_rewards: total_rewards,
            investment_receiver: investment_receiver,
            investment_claimed: false
        }
    }

    public(friend) fun fund<TI, TR> (vault: &mut Vault<TI, TR>, coin: Coin<TR>) {
        assert!(coin::value(&coin) >= vault.total_rewards, ENotEnoughFunds);

        vault.total_rewards = coin::value(&coin);
        balance::join(&mut vault.reward_balance, coin::into_balance(coin));
    }

    public(friend) fun claim<TI, TR>(cert: &mut InvestCertificate, vault: &mut Vault<TI, TR>, clock: &Clock, ctx: &mut TxContext) {
        assert!(cert.campaign_id == vault.campaign_id, ECampaignIdMismatch);

        let last_applicable_round = get_last_applicable_round(vault, clock);
        let total_applicable_reward_share = 0;

        assert!(last_applicable_round > 0, EDistributionNotStarted);

        while (cert.vesting_applicable_round < last_applicable_round) {
            total_applicable_reward_share = total_applicable_reward_share + *vector::borrow(&vault.scheduled_rewards, cert.vesting_applicable_round);
            cert.vesting_applicable_round = cert.vesting_applicable_round + 1;
        };

        let user_reward = get_user_total_reward(vault, cert) * total_applicable_reward_share / 100;

        if (user_reward != 0){
            assert!(user_reward <= balance::value(&vault.reward_balance), ESmallRewardsBalance);

            let tokens_to_claim = coin::take(&mut vault.reward_balance, user_reward, ctx);
            transfer::public_transfer(tokens_to_claim, tx_context::sender(ctx));

            event::emit(ClaimRewardsEvent{ campaign_id: vault.campaign_id, round: cert.vesting_applicable_round, amount: user_reward });
        }
    }

    public fun get_user_total_reward<TI, TR>(vault: &Vault<TI, TR>, cert: &InvestCertificate): u64 {
        ((cert.deposit as u128) * DecimalPrecision / get_token_price(vault) as u64)
    }

    public(friend) fun insurance_claimed(cert: &mut InvestCertificate) {
        cert.insured = false;
    }

    public fun is_insured(cert: &InvestCertificate): bool {
        cert.insured
    }

    public(friend) fun mint_investment_certificate<TI, TR>(vault: &mut Vault<TI, TR>, campaign_id: ID, coin: coin::Coin<TI>, insured: bool, ctx: &mut TxContext) {
        assert!(vault.invested_amount + coin::value(&coin) <= vault.target_amount, EAllocationExceeded);
        
        let deposit = coin::value(&coin);

        let invest_balance = coin::into_balance(coin);
        balance::join(&mut vault.investment_balance, invest_balance);
        vault.invested_amount = vault.invested_amount + deposit;

        let invest_cert = InvestCertificate {
            id: object::new(ctx),
            campaign_id: campaign_id,
            deposit: deposit,
            vesting_applicable_round: 0,
            insured: insured
        };

        transfer::public_transfer(invest_cert, tx_context::sender(ctx));
    }

    public(friend) fun claim_investment<TI, TR>(vault: &mut Vault<TI, TR>, ctx: &mut TxContext) {
        assert!(vault.investment_receiver == tx_context::sender(ctx), EOnlyInvestmentReceiver);
        assert!(!vault.investment_claimed, EInvestmentAlreadyClaimed);

        let amount = vault.target_amount;
        if (vault.invested_amount < vault.target_amount) {
            amount = vault.invested_amount
        };
        
        let tokens = coin::take(&mut vault.investment_balance, amount, ctx);
        vault.investment_claimed = true;

        if (vault.invested_amount < vault.target_amount){
            // Withdraw unsold tokens
            let reward_tokens_amount = {
                let this = (vault.target_amount - vault.invested_amount as u128) * DecimalPrecision / get_token_price(vault);
                (this as u64)
            };
            
            let tokens_to_withdraw = coin::take(&mut vault.reward_balance, reward_tokens_amount, ctx);
            transfer::public_transfer(tokens_to_withdraw, tx_context::sender(ctx));

            event::emit(WithdrawUnsoldTokensEvent { campaign_id: vault.campaign_id, amount: reward_tokens_amount})
        };

        event::emit(WithdrawInvestmentEvent{
            campaign_id: vault.campaign_id,
            amount: amount
        });

        transfer::public_transfer(tokens, tx_context::sender(ctx))
    }

    public fun get_token_price<TI, TR>(vault: &Vault<TI, TR>): u128 {
        (vault.target_amount as u128) * DecimalPrecision / (vault.total_rewards as u128)
    }

    public fun get_tokens_total_rewards_amount<TI, TR>(vault: &Vault<TI, TR>): u64 {
        vault.total_rewards
    }

    fun get_last_applicable_round<TI, TR>(vault: &Vault<TI, TR>, clock: &Clock): u64 {
        let i = 0;
        let max_round = vector::length(&vault.scheduled_times);

        while (i < max_round && vault.start_timestamp + *vector::borrow(&vault.scheduled_times, i) < clock::timestamp_ms(clock)) {
            i = i +1;
        };
        i
    }

    public fun get_certificate_campaign_id(cert: &InvestCertificate): ID {
        cert.campaign_id
    }

}