module suipad::token {
    use std::option;
    use sui::coin;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// The type identifier of coin. The coin will have a type
    /// tag of kind: `Coin<package_object::mycoin::MYCOIN>`
    /// Make sure that the name of the type matches the module's name.
    struct TOKEN has drop {}

    /// Module initializer is called once on module publish. A treasury
    /// cap is sent to the publisher, who then controls minting and burning
    fun init(witness: TOKEN, ctx: &mut TxContext) {
        let (treasury, metadata) = coin::create_currency(witness, 6, b"SUIP", b"SUIP", b"Suipad lanchpad test token", option::none(), ctx);
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury, tx_context::sender(ctx))
    }

    public entry fun mint(
        treasury_cap: &mut coin::TreasuryCap<TOKEN>, 
        amount: u64, 
        recipient: address, 
        ctx: &mut TxContext
    ) {
        coin::mint_and_transfer(treasury_cap, amount, recipient, ctx)
    }

    /// Manager can burn coins
    public entry fun burn(treasury_cap: &mut coin::TreasuryCap<TOKEN>, coin: coin::Coin<TOKEN>) {
        coin::burn(treasury_cap, coin);
    }
}