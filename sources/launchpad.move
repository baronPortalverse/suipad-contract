module suipad::launchpad {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use std::string::{String};
    use suipad::campaign::{Self, Campaign};
    use suipad::whitelist::{Self, Whitelist};
    use sui::event;
    use std::vector;

    const ENotCaimpaignAdmin: u64 = 1;

    //Events
    struct CampaignCreated has copy, drop {
        id: ID
    }

    struct CampaignClosed has copy, drop {
        campaign_id: ID
    }

    // Admin object
    struct Launchpad has key, store {
        id: UID
    }

    fun init(ctx: &mut TxContext){
        // Create launchpad object for admin
        let launchpad = Launchpad{
            id: object::new(ctx)
        };

        transfer::transfer(launchpad, tx_context::sender(ctx))
    }

    public entry fun create_campaign<TI, TR>(
        _: &mut Launchpad, 
        campaignID: String,
        target_amount: u64,
        tokens_to_sell: u64,
        receiver: address,
        ctx: &mut TxContext
    ) {
        // Create campaign and corresponding whitelist
        let campaign = campaign::new<TI, TR>(
            campaignID,
            target_amount,
            tokens_to_sell,
            receiver,
            ctx
        );
        let whitelist = whitelist::new(campaign::get_id(&campaign), ctx);

        event::emit(CampaignCreated{id: campaign::get_id(&campaign)});

        // Make objects shared to be accessed for everyone
        transfer::share_object(campaign);
        transfer::share_object(whitelist);
    }

    public entry fun add_to_whitelist(_: &Launchpad, whitelist: &mut Whitelist, investors: vector<address>) {
        let i = 0;
        let len = vector::length(&investors);
        while (i < len) {
            whitelist::add_investor(whitelist, *vector::borrow(&investors, i));
            i = i + 1;
        }
    }

    public entry fun close_campaign<TI, TR>(_: &Launchpad, campaign: &mut Campaign<TI, TR>){
        campaign::close(campaign);
        event::emit(CampaignClosed{campaign_id: campaign::get_id(campaign)});
    }
}