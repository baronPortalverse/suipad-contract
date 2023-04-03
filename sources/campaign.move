module suipad::campaign {
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use std::string::{String};
    use sui::coin;
    use sui::balance;
    use sui::event;
    use sui::transfer;
    use suipad::launchpad;
    use suipad::whitelist::{Self, Whitelist};

    // Errors
    const EWrongCert: u64 = 1;
    const EOnlyReceiver: u64 = 2;
    const ENotInWhitelist: u64 = 3;
    const ECampaignNotClosed: u64 = 4;
    const ENotEnoughFunds: u64 = 5;
    const EInvestmentAlreadyClaimed: u64 = 6;


    // Events
    struct CampaignCreated has copy, drop {
        campaign_id: ID
    }

    struct CampaignClosed has copy, drop {
        campaign_id: ID
    }

    struct CampaignFunded has copy, drop {
        campaign_id: ID
    }

    struct InvestedInCampaign has copy, drop {
        campaign_id: ID,
        investor: address,
        amount: u64,
    }

    struct RewardsClaimed has copy, drop {
        campaign_id: ID,
        investor: address,
        amount: u64,
        refunded: u64
    }

    struct InvestmentClaimed has copy, drop {
        campaign_id: ID,
        amount: u64,
    }

    struct TicketSold has copy, drop {
        id: ID,
        campaign_id: ID,
        buyer: address
    }


    // Structs
    struct Campaign<phantom TI, phantom TR> has key, store {
        id: UID,
        project_id: String,
        target_amount: u64,
        invested_amount: u64,
        tokens_to_sell: u64,
        receiver: address,
        closed: bool,
        funded: bool,
        investors_count: u64,
        investment_vault: balance::Balance<TI>,
        rewards_vault: balance::Balance<TR>,
        investment_claimed: bool
    }

    struct InvestCertificate has key, store {
        id: UID,
        campaign: ID,
        deposit: u64
    }

    public fun new<TI, TR>(
            projectID: String,
            target_amount: u64,
            tokens_to_sell: u64,
            receiver: address,
            ctx: &mut TxContext
        ) : Campaign<TI, TR>
    {
        let campaign = Campaign {
            id: object::new(ctx),
            project_id: projectID,
            target_amount: target_amount,
            invested_amount: 0,
            tokens_to_sell: tokens_to_sell,
            receiver: receiver,
            closed: false,
            funded: false,
            investors_count: 0,
            investment_vault: balance::zero<TI>(),
            rewards_vault: balance::zero<TR>(),
            investment_claimed: false
        };

        return campaign
    }

    public entry fun create_campaign<TI, TR>(
        _: &mut launchpad::Launchpad, 
        campaignID: String,
        target_amount: u64,
        tokens_to_sell: u64,
        receiver: address,
        ctx: &mut TxContext
    ) {
        // Create campaign and corresponding whitelist
        let campaign = new<TI, TR>(
            campaignID,
            target_amount,
            tokens_to_sell,
            receiver,
            ctx
        );
        let whitelist = whitelist::new(get_id(&campaign), ctx);

        event::emit(CampaignCreated{campaign_id: get_id(&campaign)});

        // Make objects shared to be accessed for everyone
        transfer::public_share_object(campaign);
        transfer::public_share_object(whitelist);
    }

    public entry fun close_campaign<TI, TR>(_: &launchpad::Launchpad, campaign: &mut Campaign<TI, TR>){
        close(campaign);
        event::emit(CampaignClosed{campaign_id: get_id(campaign)});
    }

    public entry fun fund<TI, TR>(campaign: &mut Campaign<TI, TR>, coin: &mut coin::Coin<TR>, ctx: &mut TxContext){
        assert!(coin::value(coin) >= campaign.tokens_to_sell, ENotEnoughFunds);

        let fund_coins = coin::split(coin, campaign.tokens_to_sell, ctx);

        let fund_balance = coin::into_balance(fund_coins);
        balance::join(&mut campaign.rewards_vault, fund_balance);
        campaign.funded = true;

        event::emit(CampaignFunded{campaign_id: get_id(campaign)});
    }

    public entry fun apply_for_whitelist<TI, TR>(campaign: &Campaign<TI, TR>, ctx: &mut TxContext) {
        // Create ticket for campaign and transfer to user
        let campaign_id = get_id(campaign);
        let ticket = whitelist::take_ticket(campaign_id, ctx);

        event::emit(TicketSold {id: whitelist::get_ticket_id(&ticket), campaign_id, buyer: tx_context::sender(ctx)});
        whitelist::transfer_ticket_to(ticket, tx_context::sender(ctx));
    }

    public entry fun invest<TI, TR>(
        campaign: &mut Campaign<TI, TR>, 
        whitelist: &Whitelist, 
        coin: &mut coin::Coin<TI>, 
        amount: u64,
        ctx: &mut TxContext
    ) {
        // Verify if sender is present in the whitelist
        assert!(whitelist::contains(whitelist, tx_context::sender(ctx)), ENotInWhitelist);

        let coins_to_invest = coin::split(coin, amount, ctx);

        // Create proof of investment and transfer ownership to sender
        let invest_balance = coin::into_balance(coins_to_invest);
        balance::join(&mut campaign.investment_vault, invest_balance);

        let invest_cert = InvestCertificate{
            id: object::new(ctx),
            campaign: get_id(campaign),
            deposit: amount
        };

        campaign.invested_amount = campaign.invested_amount + amount;
        campaign.investors_count = campaign.investors_count + 1;

        transfer::public_transfer(invest_cert, tx_context::sender(ctx));

        event::emit(InvestedInCampaign{
            campaign_id: get_id(campaign),
            investor: tx_context::sender(ctx),
            amount: amount
        });
    }

    public entry fun claim_rewards<TI, TR>(campaign: &mut Campaign<TI, TR>, cert: InvestCertificate, ctx: &mut TxContext) {
        assert!(is_closed(campaign), ECampaignNotClosed);
        assert!(get_id(campaign) == cert.campaign, EWrongCert);

        let amount_to_claim = 0;
        let amount_to_refund = 0;

        if (campaign.invested_amount <= campaign.target_amount) {
            amount_to_claim = (cert.deposit / get_token_price(campaign)) / 1000;
            let tokens_to_claim = coin::take(&mut campaign.rewards_vault, amount_to_claim, ctx);

            transfer::public_transfer(tokens_to_claim, tx_context::sender(ctx));
        } else if (campaign.invested_amount > campaign.target_amount) {
            amount_to_claim = (cert.deposit / campaign.invested_amount) * campaign.tokens_to_sell;
            amount_to_refund = cert.deposit - ((amount_to_claim * get_token_price(campaign)) / 1000);

            let tokens_to_claim = coin::take(&mut campaign.rewards_vault, amount_to_claim, ctx);
            let tokens_to_refund = coin::take(&mut campaign.investment_vault, amount_to_refund, ctx);

            // Transfer coins to investor 
            transfer::public_transfer(tokens_to_claim, tx_context::sender(ctx));
            transfer::public_transfer(tokens_to_refund, tx_context::sender(ctx));
        };

        let InvestCertificate {
            id: cert_id,
            campaign:_,
            deposit: _
        } = cert;

        object::delete(cert_id);

        event::emit(RewardsClaimed{
            campaign_id: get_id(campaign),
            investor: tx_context::sender(ctx),
            amount: amount_to_claim,
            refunded: amount_to_refund
        });
    }

    public entry fun claim_investment<TI, TR>(campaign: &mut Campaign<TI, TR>, ctx: &mut TxContext) {
        assert!(is_closed(campaign), ECampaignNotClosed);
        assert!(get_receiver(campaign) == tx_context::sender(ctx), EOnlyReceiver);
        assert!(!campaign.investment_claimed, EInvestmentAlreadyClaimed);

        let amount = campaign.target_amount;
        if (campaign.invested_amount < campaign.target_amount) {
            amount = campaign.invested_amount
        };
        
        let tokens = coin::take(&mut campaign.investment_vault, amount, ctx);
        campaign.investment_claimed = true;

        event::emit(InvestmentClaimed{
            campaign_id: get_id(campaign),
            amount: coin::value(&tokens)
        });

        transfer::public_transfer(tokens, tx_context::sender(ctx))
    }

    public fun close<TI, TR>(campaign: &mut Campaign<TI, TR>) {
        campaign.closed = true;
    }

    // Getters
    public fun get_id<TI, TR>(campaign: &Campaign<TI, TR>): ID {
        object::uid_to_inner(&campaign.id)
    }

    public fun is_closed<TI, TR>(campaign: &Campaign<TI, TR>): bool {
        campaign.closed
    }

    public fun get_token_price<TI, TR>(campaign: &Campaign<TI, TR>): u64 {
        campaign.target_amount * 1000 / campaign.tokens_to_sell 
    }

    public fun get_receiver<TI, TR>(campaign: &Campaign<TI, TR>): address {
        campaign.receiver
    }
}