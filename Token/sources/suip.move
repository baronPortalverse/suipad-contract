module suip::SUIP {
    use std::option;
    use sui::coin;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    struct SUIP has drop {}

    /// Module initializer is called once on module publish. A treasury
    /// cap is sent to the publisher, who then controls minting and burning
    fun init(witness: SUIP, ctx: &mut TxContext) {
        let (treasury, metadata) = coin::create_currency(witness, 9, b"SUIP", b"SuiPad", b"SuiPad lanchpad test token", option::none(), ctx);
        transfer::public_freeze_object(metadata);

        coin::mint_and_transfer(&mut treasury, 100_000_000__000_000_000, tx_context::sender(ctx), ctx);
        transfer::public_freeze_object(treasury);
    }
}