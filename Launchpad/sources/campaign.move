module suipad::campaign {
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use std::string::{String};
    use sui::coin;
    use sui::event;
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use std::vector;
    use sui::pay;
    use suipad::launchpad;
    use suipad::insurance::{Self};
    use suipad::staking::{Self, StakingLock};
    use suipad::vault::{Self, Vault, InvestCertificate};
    use suipad::whitelist::{Self, Whitelist};
    use sui::dynamic_object_field as ofield;
    use sui::table::{Self, Table};

    const DecimalPrecision: u128 = 10_000_000;

    // Errors
    const EWrongCert: u64 = 1;
    const ENotInWhitelist: u64 = 2;
    const ENotInWhitelistPhase: u64 = 3;
    const ENotInSalePhase: u64 = 4;
    const ENotInDistributionPhase: u64 = 5;
    const EAlreadyRequested: u64 = 6;
    const EInsufficientFunds: u64 = 7;
    const EAllocationExceed: u64 = 8;
    const EInvalidAllocationsLength: u64 = 9;
    const EAlreadyFunded: u64 = 10;
    const ECampaignHasNoRewards: u64 = 11;
    const EWrongTokenPrice: u64 = 12;
    const EInvalidAmount: u64 = 13;
    const ENotInsured: u64 = 14;
    const EInvalidVesting: u64 = 15;


    // Events
    struct CampaignCreatedEvent has copy, drop {
        campaign_id: ID
    }

    struct CampaignClosedEvent has copy, drop {
        campaign_id: ID
    }

    struct CampaignFundedEvent has copy, drop {
        campaign_id: ID
    }

    struct InvestedInCampaignEvent has copy, drop {
        campaign_id: ID,
        investor: address,
        amount: u64,
    }

    struct RewardsClaimedEvent has copy, drop {
        campaign_id: ID,
        investor: address,
        amount: u64,
        refunded: u64
    }

    struct InvestmentClaimedEvent has copy, drop {
        campaign_id: ID,
        amount: u64,
    }

    struct ApplyForWhitelistEvent has copy, drop {
        campaign_id: ID,
        project_id: String
    }


    // Structs
    struct Campaign<phantom TI, phantom TR> has key, store {
        id: UID,
        project_id: String,
        whitelist_start: u64,
        sale_start: u64,
        distribution_start: u64,
        investors_count: u64,
        vault: Vault<TI, TR>,
        allocations: vector<u64>,
        funded: bool,
        requests: Table<address, bool>
    }

    public entry fun create_campaign<TI, TR>(
        _: &mut launchpad::Launchpad, 
        projectID: String,
        scheduled_times: vector<u64>,
        scheduled_rewards: vector<u64>,
        whitelist_start: u64,
        sale_start: u64,
        distribution_start: u64,
        target_amount: u64,
        tokens_to_sell: u64,
        receiver: address,
        ctx: &mut TxContext
    ) {
        assert!(vector::length(&scheduled_times) == vector::length(&scheduled_rewards), EInvalidVesting);

        let campaign_id = object::new(ctx);
        let vault = vault::create<TI, TR>(
            object::uid_to_inner(&campaign_id),
            scheduled_times,
            scheduled_rewards,
            target_amount,
            distribution_start,
            tokens_to_sell,
            receiver,
            ctx
        );

        assert!(vault::get_token_price(&vault) > 0, EWrongTokenPrice);

        let campaign = Campaign {
            id: campaign_id,
            project_id: projectID,
            whitelist_start: whitelist_start,
            sale_start: sale_start,
            distribution_start,
            investors_count: 0,
            vault: vault,
            allocations: vector::empty<u64>(),
            funded: false,
            requests: table::new<address, bool>(ctx)
        };

        let whitelist = whitelist::new(ctx);

        event::emit(CampaignCreatedEvent{campaign_id: get_id(&campaign)});

        // Make objects shared to be accessed for everyone
        ofield::add(&mut campaign.id, b"whitelist", whitelist);
        transfer::public_share_object(campaign);
    }

    public entry fun fund<TI, TR>(campaign: &mut Campaign<TI, TR>, coins: vector<coin::Coin<TR>>, ctx: &mut TxContext){
        assert!(!campaign.funded, EAlreadyFunded);

        let amount = vault::get_tokens_total_rewards_amount(&campaign.vault);
        let coin = get_coin_from_vec(coins, amount, ctx);

        campaign.funded = true;

        vault::fund<TI, TR>(&mut campaign.vault, coin);

        event::emit(CampaignFundedEvent{campaign_id: get_id(campaign)});
    }

    public entry fun apply_for_whitelist<TI, TR>(campaign: &mut Campaign<TI, TR>, _: &StakingLock, clock: &Clock, ctx: &mut TxContext) {
        assert!(is_whitelist_phase(campaign, clock), ENotInWhitelistPhase);
        assert!(campaign.funded, ECampaignHasNoRewards);
        assert!(!table::contains(&campaign.requests, tx_context::sender(ctx)), EAlreadyRequested);

        let campaign_id = get_id(campaign);
        table::add(&mut campaign.requests, tx_context::sender(ctx), true);

        event::emit(ApplyForWhitelistEvent {campaign_id, project_id: campaign.project_id});
    }

    public entry fun add_bulk_to_whitelist<TI, TR>(
        _: &launchpad::Launchpad, 
        campaign: &mut Campaign<TI, TR>, 
        investors: vector<address>
    ){
        let whitelist = ofield::borrow_mut<vector<u8>, Whitelist>(
            &mut campaign.id,
            b"whitelist",
        );

        whitelist::add_to_whitelist(whitelist, investors)
    }

    public entry fun add_to_whitelist<TI, TR>(_: &launchpad::Launchpad, campaign: &mut Campaign<TI, TR>, investor: address){
        let whitelist = ofield::borrow_mut<vector<u8>, Whitelist>(
            &mut campaign.id,
            b"whitelist",
        );

        whitelist::add_investor(whitelist, investor)
    }

    public entry fun set_allocations<TI, TR>(
        _: &launchpad::Launchpad, 
        campaign: &mut Campaign<TI, TR>, 
        staking_pool: &staking::StakingPool, 
        allocations: vector<u64>) 
    {
        assert!(vector::length(&allocations) == staking::get_tier_levels_count(staking_pool), EInvalidAllocationsLength);

        campaign.allocations = allocations
    }

    public entry fun invest<TI, TR>(
        campaign: &mut Campaign<TI, TR>,
        staking_pool: &staking::StakingPool,
        staking_lock: &mut StakingLock,
        amount: u64,
        coins: vector<coin::Coin<TI>>,
        insure: bool,
        insurance_fund: &mut insurance::Fund<TI>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let token_price = vault::get_token_price(&campaign.vault);
        amount = {
            let this = (((amount as u128) * DecimalPrecision / token_price) * token_price) / DecimalPrecision;
            (this as u64)
        };

        let max_allocation = *vector::borrow<u64>(&campaign.allocations, staking::get_tier_level(staking_lock, staking_pool));

        assert!(amount > 0, EInvalidAmount);
        assert!(is_sale_phase(campaign, clock), ENotInSalePhase);
        assert!(amount <= max_allocation, EAllocationExceed);

        let whitelist = ofield::borrow_mut<vector<u8>, Whitelist>(
            &mut campaign.id,
            b"whitelist",
        );
        assert!(whitelist::can_invest(whitelist, tx_context::sender(ctx)), ENotInWhitelist);
        whitelist::investor_invested(whitelist, tx_context::sender(ctx));
        
        let amount_to_take = if (insure) {
            amount + (amount / 100 * 15)
        } else {
            amount
        };

        let coin = get_coin_from_vec(coins, amount_to_take, ctx);
        if (insure) {
            let insure_coin = coin::split(&mut coin, amount / 100 * 15, ctx);
            insurance::insure_campaign(insurance_fund, get_id(campaign), insure_coin, ctx);
        };

        // Create proof of investment and transfer ownership to sender
        vault::mint_investment_certificate<TI, TR>(
            &mut campaign.vault, 
            object::uid_to_inner(&campaign.id), 
            coin, 
            insure,
            ctx
        );

        campaign.investors_count = campaign.investors_count + 1;


        staking::update_last_distribution_timestamp(staking_lock, campaign.distribution_start);

        event::emit(InvestedInCampaignEvent {
            campaign_id: get_id(campaign),
            investor: tx_context::sender(ctx),
            amount: amount
        });
    }

    public entry fun claim_rewards<TI, TR>(campaign: &mut Campaign<TI, TR>, cert: &mut InvestCertificate, clock: &Clock, ctx: &mut TxContext) {
        assert!(is_distribution_phase(campaign, clock), ENotInDistributionPhase);
        assert!(get_id(campaign) == vault::get_certificate_campaign_id(cert), EWrongCert);

        vault::claim(cert, &mut campaign.vault, clock, ctx);
    }

    public entry fun claim_investment<TI, TR>(campaign: &mut Campaign<TI, TR>, clock: &Clock, ctx: &mut TxContext) {
        assert!(is_distribution_phase(campaign, clock), ENotInDistributionPhase);

        vault::claim_investment(&mut campaign.vault, ctx);
    }

    public entry fun claim_insurance<TI, TR>(
        fund: &mut insurance::Fund<TI>, 
        refund_allowance: &insurance::CampaignRefundAllowance, 
        cert: &mut InvestCertificate, 
        campaign: &Campaign<TI, TR>, 
        ctx: &mut TxContext
    ) {
        assert!(get_id(campaign) == vault::get_certificate_campaign_id(cert), EWrongCert);
        assert!(vault::is_insured(cert), ENotInsured);

        insurance::claim_refund(fund, refund_allowance, cert, &campaign.vault, ctx);
        vault::insurance_claimed(cert);
    }

    // Getters
    fun get_id<TI, TR>(campaign: &Campaign<TI, TR>): ID {
        object::uid_to_inner(&campaign.id)
    }

    fun is_whitelist_phase<TI, TR>(campaign: &Campaign<TI, TR>, clock: &Clock): bool {
        let one_day = 24 * 60 * 60 * 1000;
        campaign.whitelist_start < clock::timestamp_ms(clock) && campaign.sale_start - one_day > clock::timestamp_ms(clock)
    }

    fun is_sale_phase<TI, TR>(campaign: &Campaign<TI, TR>, clock: &Clock): bool {
        campaign.sale_start < clock::timestamp_ms(clock) && campaign.distribution_start > clock::timestamp_ms(clock)
    }

    fun is_distribution_phase<TI, TR>(campaign: &Campaign<TI, TR>, clock: &Clock): bool {
        campaign.distribution_start < clock::timestamp_ms(clock)
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
}