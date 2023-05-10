module suipad::insurance {
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{Self, TxContext};
    use sui::coin;
    use sui::balance;
    use sui::event;
    use sui::transfer;
    use std::vector;
    use sui::pay;
    use suipad::launchpad::{Launchpad};
    use suipad::vault::{Self, InvestCertificate, Vault};

    friend suipad::campaign;

    // Errors
    const ECampaignIDMismatch: u64 = 1;
    const EInsufficientFunds: u64 = 2;


    // Events
    struct InsureCampaignEvent has drop, copy {
        sender: address,
        amount: u64,
        campaign_id: ID
    }

    struct IssueRefundAllowanceEvent has drop, copy {
        campaign_id: ID
    }

    struct ClaimRefundEvent has drop, copy {
        campaign_id: ID,
        amount: u64
    }

    struct Fund<phantom Token> has key, store {
        id: UID,
        vault: balance::Balance<Token>
    }

    struct InsuranceCertificate<phantom Token> has key, store {
        id: UID,
        campaign_id: ID,
        amount: u64
    }

    struct CampaignRefundAllowance has key, store {
        id: UID,
        campaign_id: ID,
        real_avg_price: u64, // * 10_000
    }

    entry fun new<T>(_: &Launchpad, ctx: &mut TxContext){
        let fund = Fund<T>{
            id: object::new(ctx),
            vault: balance::zero<T>()
        };

        transfer::public_share_object(fund)
    }

    public(friend) fun insure_campaign<T>(fund: &mut Fund<T>, campaign_id: ID, coin: coin::Coin<T>, ctx: &mut TxContext){
        let amount = coin::value(&coin);
        let balance_in = coin::into_balance(coin);
        balance::join(&mut fund.vault, balance_in);

        event::emit(InsureCampaignEvent{ sender: tx_context::sender(ctx), amount: amount, campaign_id: campaign_id});
    }

    entry fun issue_refund_allowance( _: &Launchpad, campaign_id: ID, real_avg_price: u64, ctx: &mut TxContext) {
        let refund = CampaignRefundAllowance {
            id: object::new(ctx),
            campaign_id: campaign_id,
            real_avg_price: real_avg_price
        };

        event::emit(IssueRefundAllowanceEvent{campaign_id: campaign_id});

        transfer::public_share_object(refund);
    }

    entry fun add_coins<T>(fund: &mut Fund<T>, amount: u64, coins: vector<coin::Coin<T>>, ctx: &mut TxContext) {
        let coin = get_coin_from_vec(coins, amount, ctx);
        balance::join(&mut fund.vault, coin::into_balance(coin));
    }

    public(friend) fun claim_refund<TF, TI, TR>(
        fund: &mut Fund<TF>, 
        refund_allowance: &CampaignRefundAllowance, 
        cert: &InvestCertificate, 
        vault: &Vault<TI, TR>, 
        ctx: &mut TxContext
    ){
        assert!(refund_allowance.campaign_id == vault::get_certificate_campaign_id(cert), ECampaignIDMismatch);

        let user_reward = vault::get_user_total_reward(vault, cert);
        let token_price = (vault::get_token_price(vault) as u64);
        let invested_amount = user_reward * token_price;
        let refund_amount = invested_amount - (user_reward * refund_allowance.real_avg_price);

        let coin = coin::take(&mut fund.vault, refund_amount, ctx);

        event::emit(ClaimRefundEvent{ campaign_id: refund_allowance.campaign_id, amount: refund_amount});

        transfer::public_transfer(coin, tx_context::sender(ctx))
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