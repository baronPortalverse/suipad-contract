module suipad::launchpad {
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    const ENotCaimpaignAdmin: u64 = 1;

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
}