module suipad::whitelist {
    use sui::object::{Self, UID};
    use sui::tx_context::{TxContext};
    use std::vector;
    use sui::table::{Self, Table};

    friend suipad::campaign;

    struct WhitelistItem has store {
        invested: bool
    }

    struct Whitelist has key, store {
        id: UID,
        allowed_addresses: Table<address, WhitelistItem>
    }

    public fun new(ctx: &mut TxContext): Whitelist {
        Whitelist {
            id: object::new(ctx),
            allowed_addresses: table::new<address, WhitelistItem>(ctx)
        }
    }

    public(friend) fun add_to_whitelist(whitelist: &mut Whitelist, investors: vector<address>) {
        let i = 0;
        let len = vector::length(&investors);
        while (i < len) {
            add_investor(whitelist, *vector::borrow(&investors, i));
            i = i + 1;
        }
    }

    public(friend) fun add_investor(whitelist: &mut Whitelist, investor: address) {
        if (!table::contains(&whitelist.allowed_addresses, investor)) {
            table::add(
                &mut whitelist.allowed_addresses, 
                investor, 
                WhitelistItem {
                    invested: false
                }
            )
        }
    }

    public(friend) fun investor_invested(whitelist: &mut Whitelist, investor: address) {
        let item = table::borrow_mut(&mut whitelist.allowed_addresses, investor);
        item.invested = true;
    }

    // Getters
    public fun can_invest(whitelist: &Whitelist, investor: address): bool {
        if (contains(whitelist, investor)) {
            let item = table::borrow(&whitelist.allowed_addresses, investor);
            return !item.invested
        };

        false
    }

    public fun contains(whitelist: &Whitelist, investor: address): bool {
        table::contains(&whitelist.allowed_addresses, investor)
    }
}