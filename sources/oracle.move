module suipad::oracle {
    use sui::object::{Self, ID, UID};
    use sui::transfer;
    use sui::tx_context::TxContext;
    use sui::event;
    use suipad::launchpad;

    const EInvalidTime: u64 = 1;


    // Events
    struct TimeOracleUpdated has copy, drop {
        oracle_id: ID,
        value: u64,
    }


    struct TimeOracle has key {
        id: UID,
        value: u64,
    }

    fun init(ctx: &mut TxContext) {
        let timeOracle = TimeOracle {
            id: object::new(ctx),
            value: 0,
        };

        transfer::share_object(timeOracle)
    }

    public entry fun update_time(_: &launchpad::Launchpad, oracle: &mut TimeOracle, value: u64) {
        assert!(oracle.value < value, EInvalidTime);
        oracle.value = value;

        event::emit(TimeOracleUpdated { 
            oracle_id: object::uid_to_inner(&oracle.id),
            value: oracle.value,
        });
    }

    public fun get_time(oracle: &TimeOracle): u64 {
        oracle.value
    }

}
