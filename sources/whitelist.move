module suipad::whitelist {
    use sui::object::{Self, ID, UID};
    use sui::tx_context::{TxContext};
    use std::vector;

    struct Ticket has key, store {
        id: UID,
        campaign_id: ID
    }

    struct Whitelist has key, store {
        id: UID,
        campaign_id: ID,
        allowed_addresses: vector<address>
    }

    public fun new(campaignID: ID, ctx: &mut TxContext): Whitelist {
        Whitelist {
            id: object::new(ctx),
            campaign_id: campaignID,
            allowed_addresses: vector::empty<address>()
        }
    }

    public fun take_ticket(campaign_id: ID, ctx: &mut TxContext): Ticket {
        let ticket = Ticket {
            id: object::new(ctx),
            campaign_id: campaign_id
        };

        ticket
    }

    public fun burn_ticket(ticket: Ticket) {
        let Ticket {
            id: id,
            campaign_id: _
        } = ticket;

        object::delete(id)
    }

    public fun add_investor(whitelist: &mut Whitelist, investor: address) {
        vector::push_back(&mut whitelist.allowed_addresses, investor)
    }

    // Getters
    public fun contains(whitelist: &Whitelist, investor: address): bool {
        vector::contains(&whitelist.allowed_addresses, &investor)
    }

    public fun get_ticket_id(ticket: &Ticket): ID {
        object::uid_to_inner(&ticket.id)
    }

    public fun get_ticket_address(ticket: &Ticket): address {
        object::uid_to_address(&ticket.id)
    }

    public fun get_campaign_id(whitelist: &Whitelist): ID {
        whitelist.campaign_id
    }
}