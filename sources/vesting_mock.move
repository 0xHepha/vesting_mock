module deployer::vesting_mock {
    use std::event;
    use std::error;
    use std::signer;
    use std::math64;
    // use std::vector;
    use std::timestamp;
    use std::table::{Self, Table};
    use std::option::{Self,Option};

    use aptos_framework::coin;
    use aptos_framework::object::{Self,Object};
    use aptos_framework::primary_fungible_store::{Self as pfs};
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};

    // =========== ERRORS ===========
    
    // PERMISION errors //
    // Caller is not admin
    const ENOT_ADMIN: u64 = 1;

    // Caller is not porposed as admin
    const ENOT_PROPOSED_ADMIN: u64 = 2;

    // Caller is not the beneficiary of Vesting Stream
    const ENOT_STREAM_BENEFICIARY: u64 = 3;

    // INTERANL errors //

    // Stream is already vesting
    const ESTREAM_ALREADY_VESTING: u64 = 1;

    // New start time can't avoid vesting process
    const ENEW_START_TIME_TOO_LATE: u64 = 2;

    // The stream opeartes with a different FA
    const EDIFFERENT_FA: u64 = 3;


    // =========== STRUCTS ===========
    struct ModuleControl has key {
        admin: address,
        // Used to avoid dead addresses when changing admin
        proposed_admin: Option<address>,
    }

    struct Stream has key,copy,store,drop{
        beneficiary: address,
        amount: u64,
        start_time: u64,
        cliff_duration: u64,
        vesting_duration: u64,
        metadata_address: address,
    }

    struct StreamControl has key{
        delete_ref: object::DeleteRef,
        extend_ref: object::ExtendRef,
    }

    struct ActiveStreams has key{
        // Maps user address to its active streams objects adress
        active: Table<address,vector<address>>
    }

    
    // =========== EVENTS ===========
    #[event]
    struct AdminChangeEvent has drop, store{
        // Stores address that had admin removed
        previous: address,
        // Address that has admin 
        new: address,
    }

    #[event]
    struct AdminProposedEvent has drop, store{
        // Adress that proposed the admin
        by: address,
        // Adress that can accept admin 
        apointed: address,
    }

    #[event]
    struct StreamCreatedEvent has drop, store{
        beneficiary: address,
        metadata_address: address,
        // address of the Object that stores data & assets
        object_address: address,
    }

    #[event]
    struct ModifyStreamDataEvent has drop,store {
        object_address: address,
    }


    #[event]
    struct VestedTokensClaimEvent has drop, store {
        object_address: address,
        amount: u64,
    }

    #[event]
    struct DeleteEmptyStreamEvent has drop,store {
        object_address: address,
    }



    
    // =========== INIT ===========
    fun init_module(deployer: &signer) {

        // Initialize module control struct
        move_to(deployer, ModuleControl{
            // Deployer is admin by default
            admin: signer::address_of(deployer),

            // Will be filled only when admin is being changed
            proposed_admin: option::none(),

        });

        // Initialize struct ot keep track of Streams
        move_to(deployer, ActiveStreams{
            active: table::new(),
        });
    }

    

    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    // >>>>>>>>      Streams Management      >>>>>>>>
    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>


    entry fun create_stream_with_coins<CoinType>(
        caller: &signer,
        beneficiary: address,
        start_time: u64,
        cliff_duration: u64,
        vesting_duration: u64,
        amount: u64,
    ) acquires ModuleControl, ActiveStreams{
        // Get user coins       
        let coins = coin::withdraw<CoinType>(caller, amount);

        // Convert Coins to FA
        let fa = coin::coin_to_fungible_asset<CoinType>(coins);

        internal_create_stream(
            caller,
            beneficiary,
            start_time,
            cliff_duration,
            vesting_duration,
            fa,
        );
    }

    entry fun create_stream_with_fa(
        caller: &signer,
        beneficiary: address,
        start_time: u64,
        cliff_duration: u64,
        vesting_duration: u64,
        metadata: Object<Metadata>, 
        amount: u64,
    ) acquires ModuleControl,ActiveStreams {
        let fa = pfs::withdraw(caller, metadata, amount);

        internal_create_stream(
            caller,
            beneficiary,
            start_time,
            cliff_duration,
            vesting_duration,
            fa,
        );
        
    }

    
    fun internal_create_stream(
        caller: &signer,
        beneficiary: address,
        start_time: u64,
        cliff_duration: u64,
        vesting_duration: u64,
        fa: FungibleAsset,
    ) acquires ModuleControl, ActiveStreams{
        admin_only(caller);

        // Create an object to store the assets & data
        let constructor_ref = object::create_object(@0x0);

        // Generate a signer to control the object & get the address of it
        let stream_object_signer = &object::generate_signer(&constructor_ref);
        let stream_object_address = signer::address_of(stream_object_signer);

        // Get FA metadata
        let metadata = fungible_asset::metadata_from_asset(&fa);

        // Create the Primary Store of the object address
        pfs::ensure_primary_store_exists(stream_object_address, metadata);

        // store amount since FA doesn't have copy & store
        let amount = fungible_asset::amount(&fa);

        // Deposit fa 
        pfs::deposit(stream_object_address, fa);


        // Store data at the object
        move_to(stream_object_signer, Stream {
            beneficiary: beneficiary,
            amount: amount,
            start_time: start_time,
            cliff_duration: cliff_duration,
            vesting_duration: vesting_duration,
            metadata_address: object::object_address<Metadata>(&metadata),
        });

        move_to(stream_object_signer, StreamControl{
            delete_ref: object::generate_delete_ref(&constructor_ref),
            extend_ref: object::generate_extend_ref(&constructor_ref),
        });

        let streams = &mut ActiveStreams[@deployer].active;


        // if the user doesn't have any stream, initialize empty array
        if(!streams.contains(beneficiary)){
            streams.add(beneficiary, vector[]);
        };

        // Add object address to user streams
        let user_streams = streams.borrow_mut(beneficiary);
        user_streams.push_back(stream_object_address);
    

        event::emit(StreamCreatedEvent{
            beneficiary: beneficiary,
            metadata_address: object::object_address<Metadata>(&metadata),
            // Object that stores data & assets
            object_address: stream_object_address,
            
        });

    }

    entry fun add_fa_balance_to_stream(
        caller: &signer,
        object_address: address,
        metadata: Object<Metadata>,
        amount: u64,
    ) acquires Stream {

        let fa = pfs::withdraw(caller, metadata, amount);

        internal_add_balance_to_stream(object_address, fa);
    }

    entry fun add_coin_balance_to_stream<CoinType>(
        caller: &signer,
        object_address: address,
        amount: u64,
    ) acquires Stream{

        let coins = coin::withdraw<CoinType>(caller, amount);

        // Convert Coins to FA
        let fa = coin::coin_to_fungible_asset<CoinType>(coins);

        internal_add_balance_to_stream(object_address, fa);
    }

    fun internal_add_balance_to_stream(
        object_address: address,
        fa: FungibleAsset,
    ) acquires Stream {
        let stream = &mut Stream[object_address];

        // Get FA metadata
        let metadata = fungible_asset::metadata_from_asset(&fa);
        let fa_metada_address = object::object_address<Metadata>(&metadata);

        // Make sure the same FA is being added to avoid lost funds inside Streams
        assert!(stream.metadata_address == fa_metada_address, error::internal(EDIFFERENT_FA));

        // store the amount since deposit calls remove the chance to get it afterwards
        let amount_to_add = fungible_asset::amount(&fa);

        pfs::deposit(object_address, fa); 

        stream.amount += amount_to_add;

        event::emit(ModifyStreamDataEvent{
            object_address: object_address,
        })
    }
    
    entry fun remove_balance_from_stream(caller: &signer, object_address: address, amount: u64) acquires Stream, ModuleControl, StreamControl {
        admin_only(caller);

        assert_pre_vesting_phase(object_address);

        let stream = &mut Stream[object_address];
        let stream_control = &StreamControl[object_address];
    
        let metadata = object::address_to_object<Metadata>(stream.metadata_address);
        
        let object_signer = &object::generate_signer_for_extending(&stream_control.extend_ref);

        let fa = pfs::withdraw(object_signer, metadata, amount);
        pfs::deposit(signer::address_of(caller), fa); 
    
        // no need to check for underflow, it will error when trying to withdraw FA
        // and each stream has its own funds so no risk of draining
        stream.amount -= amount;


        event::emit(ModifyStreamDataEvent{
            object_address: object_address,
        })
    }

    entry fun delete_stream(caller: &signer, object_address: address) acquires Stream, StreamControl, ActiveStreams, ModuleControl {
        admin_only(caller);
        
        // Get actual time and the time that stream starts vesting
        let stream = &Stream[object_address];
        let now = timestamp::now_seconds();
        let time_limit = stream.start_time + stream.cliff_duration;

        assert!(now < time_limit, error::internal(ESTREAM_ALREADY_VESTING));


        // return the funds of the deleted stream
        let fa = internal_delete_stream(object_address);
        pfs::deposit(signer::address_of(caller), fa); 
    }
    

    fun internal_delete_stream(object_address: address): FungibleAsset acquires Stream, StreamControl, ActiveStreams {
        let Stream {
            beneficiary: beneficiary,
            amount: _amount,
            start_time: _start_time,
            cliff_duration: _cliff_duration,
            vesting_duration: _vesting_duration,
            metadata_address: metadata_address,
        } = move_from<Stream>(object_address);

        // Get control refs to delte object
        let StreamControl {
            delete_ref: delete_ref,
            extend_ref: extend_ref,
        } = move_from<StreamControl>(object_address);

        let metadata = object::address_to_object<Metadata>(metadata_address);

        // get object data
        let object_signer = &object::generate_signer_for_extending(&extend_ref);
        let object_address = signer::address_of(object_signer);
        let object_balance = pfs::balance(object_address, metadata);

        // Get funds before the object is deleted
        let fa = pfs::withdraw(object_signer, metadata, object_balance);
    
        let streams = &mut ActiveStreams[@deployer].active;
        let user_streams = streams.borrow_mut(beneficiary);

        // remove object address from user active streams
        user_streams.remove_value(&object_address);

        // delete the object
        object::delete(delete_ref);

        
        event::emit(DeleteEmptyStreamEvent{
            object_address: object_address,
        });

        fa        
    }

    entry fun change_stream_beneficiary(caller: &signer, object_address: address, new_beneficiary: address) acquires Stream, ModuleControl {
        admin_only(caller);

        assert_pre_vesting_phase(object_address);

        Stream[object_address].beneficiary = new_beneficiary;

        event::emit(ModifyStreamDataEvent{
            object_address: object_address
        });
    }

    entry fun change_stream_start_time(caller: &signer, object_address: address, new_start_time: u64) acquires Stream, ModuleControl {
        admin_only(caller);

        let stream = &Stream[object_address];
        let now = timestamp::now_seconds();
        let cliff_end_time = stream.start_time + stream.cliff_duration;

        // Checks that vesting didn't start yet
        assert!(now < cliff_end_time, error::internal(ESTREAM_ALREADY_VESTING));

        let new_end_time = new_start_time + stream.cliff_duration;

        // make sure that the new time doesn't skip the vesting process
        assert!(new_end_time > now, error::internal(ENEW_START_TIME_TOO_LATE));


        Stream[object_address].start_time = new_start_time;

        event::emit(ModifyStreamDataEvent{
            object_address: object_address
        });

    }

    entry fun change_stream_cliff_duration(caller: &signer, object_address: address, new_cliff_duration: u64) acquires Stream, ModuleControl {
        admin_only(caller);

        assert_pre_vesting_phase(object_address);

        Stream[object_address].cliff_duration = new_cliff_duration;


        event::emit(ModifyStreamDataEvent{
            object_address: object_address
        });
    }

    entry fun change_vesting_duration(caller: &signer, object_address: address, new_vesting_duration: u64) acquires Stream, ModuleControl {
        admin_only(caller);

        assert_pre_vesting_phase(object_address);

        Stream[object_address].vesting_duration = new_vesting_duration;


        event::emit(ModifyStreamDataEvent{
            object_address: object_address
        });
    }

    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    // >>>>>>>>      User Calls      >>>>>>>>
    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>


    entry fun claim_stream(caller: &signer, object_address: address) acquires Stream, StreamControl, ActiveStreams {
        let caller_address = signer::address_of(caller);
        
        let stream = &Stream[object_address];
        
        let metadata = object::address_to_object<Metadata>(stream.metadata_address);

        let stream_control = &StreamControl[object_address];

        // Make sure the caller is the beneficiary of the Stream
        assert!(stream.beneficiary == caller_address,error::permission_denied(ENOT_STREAM_BENEFICIARY));
   
        // get object data
        let object_signer = &object::generate_signer_for_extending(&stream_control.extend_ref);
        let object_balance = pfs::balance(object_address, metadata);
        
        // Calculate the amount that the user is able to claim
        let amount_to_claim = calculate_vested_tokens(  
            stream.amount,
            object_balance,
            stream.start_time,
            stream.cliff_duration,
            stream.vesting_duration,
        );
        
        let fa = pfs::withdraw(object_signer, metadata, amount_to_claim);
        pfs::deposit(stream.beneficiary, fa); 
        

        // log claim data
        event::emit(VestedTokensClaimEvent{
            object_address: object_address,
            amount: amount_to_claim,
        }); 

        // release Stream reference
        // Will thorw warning but its necesary
        let stream:bool;

        // Delete stream object to get gas back if its empty
        if(pfs::balance(object_address, metadata) == 0){
            let fa = internal_delete_stream(object_address);

            // Wont' deposit anything but FA struct can't be dropped even if is 0
            // and using destory makes code larger
            pfs::deposit(caller_address, fa); 
        };

    }

    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    // >>>>>>>>      Module Control      >>>>>>>>
    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    entry fun propose_admin(caller: &signer, new_admin: address) acquires ModuleControl {
        admin_only(caller);

        let control = &mut ModuleControl[@deployer];

        // Proposed admin should be always empty, but in any case, just overwrite it
        control.proposed_admin.swap_or_fill(new_admin);

        event::emit(AdminProposedEvent{
            by: signer::address_of(caller),
            apointed: new_admin,
        });
    }

    entry fun remove_poposed_admin(caller: &signer) acquires ModuleControl{
        admin_only(caller);

        ModuleControl[@deployer].proposed_admin = option::none<address>();


        event::emit(AdminProposedEvent{
            by: signer::address_of(caller),
            apointed: @0x0,
        });
    }

    entry fun accept_admin(caller: &signer) acquires ModuleControl {
        // Get mutable reference from start to avoid the need to clean normal reference and get the mutable one later on 
        let control = &mut ModuleControl[@deployer];

        // make sure only the proposed address can accept admin role
        assert!(
            signer::address_of(caller) == *control.proposed_admin.borrow(),
            error::permission_denied(ENOT_PROPOSED_ADMIN)
        );

        // Store old admin address for event data
        let previous_address = control.admin;

        // Change to new admin
        control.admin = signer::address_of(caller);

        // extract() will clear the value AND it will ABORT if value is empty (it must never be empty if this line is reached)
        // thus adding extra security in case someone manages to bypass the previous assert 
        control.proposed_admin.extract();

        event::emit(AdminChangeEvent{
            previous: previous_address,
            new: signer::address_of(caller),
        });
    }


    //>>>>>>>>>>>>>>>>>>>>>>>>>>
    //>>>   View Functions   >>>
    //>>>>>>>>>>>>>>>>>>>>>>>>>>

    #[view]
    public fun stream_data(stream_object_address: address):Stream acquires Stream{
        Stream[stream_object_address]
    }

    #[view]
    public fun user_active_streams(user_address: address): vector<address> acquires ActiveStreams{
        let streams = &mut ActiveStreams[@deployer].active;

        *streams.borrow(user_address)
    }

    #[view]
    public fun user_active_streams_data(user_address: address): (vector<address>,vector<Stream>) acquires Stream,ActiveStreams{
        let res = vector<Stream>[];
        let user_streams = user_active_streams(user_address);
        let amount = user_streams.length();

        for(i in 0..amount){            
            res.push_back(stream_data(*user_streams.borrow(i)));
        };

        (user_streams, res)
    }


    //>>>>>>>>>>>>>>>>>>>
    //>>>   Helpers   >>>
    //>>>>>>>>>>>>>>>>>>>
    
    // Function used to restrict access for administrator only
    // Will ERROR if the caller is not admint
    fun admin_only(caller: &signer) acquires ModuleControl {
        let control = &ModuleControl[@deployer];

        assert!(signer::address_of(caller) == control.admin, error::permission_denied(ENOT_ADMIN));
    }

 
    /*  Following the provided descriptions:
            - Start Time: The time when the vesting period starts.
            - Cliff: The duration of the cliff, before tokens can be claimed.
            - Duration: The total duration of the vesting period.

        it is doesn't make sense, it would mean that
            - cliff_start_time = start_time - cliff_duration
            - vesting_end = start_time + duration

        So for this function it will be assumed that:
            - final_end_time = start_time + cliff_duration + vesting_duration
    */
    fun calculate_vested_tokens(  
        total_amount: u64,
        remaining_amount: u64,
        start_time: u64,
        cliff_duration: u64,
        vesting_duration: u64,
    ): u64 {
        let claimed_amount = total_amount - remaining_amount;

        let now = timestamp::now_seconds();
        let end_time = start_time + cliff_duration + vesting_duration;

        // check if cliff didn't end
        if(now < start_time + cliff_duration){
            return 0
        };
        
        // Check if vesting reached 100%
        if(now >= end_time){
            return remaining_amount
        };

        // Elapsed time since cliff completed
        // First IF condition asures that there won't be an underflow
        let elapsed_time = now - (start_time + cliff_duration);

        // calculate the total amount vested
        // use mul_div to prevent intermediate overlow of x * y / z
        let vested_amount = math64::mul_div(total_amount, elapsed_time, vesting_duration);

        // remove claimed from vested
        vested_amount - claimed_amount

    }

    // Function that aborts if the specified stream is already in vesting phase
    // Mostly used to control stream modifications
    fun assert_pre_vesting_phase(object_address: address) acquires Stream{
        let stream = &Stream[object_address];
        let now = timestamp::now_seconds();
        let cliff_end_time = stream.start_time + stream.cliff_duration;

        assert!(now < cliff_end_time, error::internal(ESTREAM_ALREADY_VESTING));
    }



    //>>>>>>>>>>>>>>>>>>>
    //>>>   TESTING   >>>
    //>>>>>>>>>>>>>>>>>>>

    #[test_only]
    use deployer::tu::{Self, Coin1,Coin2, Coin3};

    #[test(deployer = @deployer)]
    fun test___init_module(deployer: &signer) acquires ModuleControl{
        init_module(deployer);

        let deployer_address = signer::address_of(deployer);

        let control = &ModuleControl[@deployer];

        // Make sure that ModuleControl is initilized with deployer as Admin
        assert!(control.admin == deployer_address);
        assert!(control.proposed_admin == option::none<address>());

        assert!(exists<ActiveStreams>(@deployer));
    }

    #[test(deployer = @deployer)]
    fun test___admin_only(deployer: &signer) acquires ModuleControl {
        init_module(deployer);

        // If caler is not admit it will error
        admin_only(deployer);
    }

    #[test(deployer = @deployer, user1 = @user1), expected_failure]
    fun test___admin_only__error_not_admin(deployer: &signer, user1 : &signer) acquires ModuleControl {
        init_module(deployer);

        admin_only(user1);
    }

    #[test(deployer = @deployer, user1 = @user1)]
    fun test___propose_admin(deployer: &signer, user1 : &signer) acquires ModuleControl {
        init_module(deployer);

        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);

        propose_admin(deployer, user1_address);

        let control = &ModuleControl[@deployer];
        
        // Check that admin is the same but the proposed address changed
        assert!(control.admin == deployer_address);
        assert!(control.proposed_admin.contains(&user1_address));


        // Check that emitted event data is correct
        let emited_events = event::emitted_events<AdminProposedEvent>();
        let emited_event = emited_events.borrow(0);

        assert!(emited_event.by == deployer_address);
        assert!(emited_event.apointed == user1_address);
    }

    #[test(deployer = @deployer, user1 = @user1)]
    fun test___remove_porposed_admin(deployer: &signer, user1 : &signer) acquires ModuleControl {
        init_module(deployer);

        // Fill the proposed_address data
        propose_admin(deployer, signer::address_of(user1));

        // Remov admind
        remove_poposed_admin(deployer);

        // Make sure that the event was emmited
        let emited_events = event::emitted_events<AdminProposedEvent>();

        // propose_admint() emitted the first event(0), so pick the second to check the update
        let emited_event = emited_events.borrow(1);

        // Check proposed address was emptied
        assert!(emited_event.by == signer::address_of(deployer));
        assert!(emited_event.apointed == @0x0);

    }

    #[test(deployer = @deployer, user1 = @user1)]
    fun test___accept_admin(deployer: &signer, user1 : &signer) acquires ModuleControl {
        init_module(deployer);
        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);

        // Previous admin proposes user1 as new admin
        propose_admin(deployer, user1_address);

        // User1 accepts admin role
        accept_admin(user1);

        let control = &ModuleControl[@deployer];

        // Check ModuleControl struct is updated correctly
        assert!(control.admin == user1_address);
        assert!(control.proposed_admin == option::none<address>());


        // Make sure the emited event data is correct
        let emited_events = event::emitted_events<AdminChangeEvent>();
        let emited_event = emited_events.borrow(0);

        assert!(emited_event.previous == deployer_address);
        assert!(emited_event.new == user1_address);
    }
 
    #[test(deployer = @deployer, user1 = @user1, user2 = @user2), expected_failure]
    fun test___accept_admin___only_porposed_can_accept(deployer: &signer, user1 :&signer, user2: &signer) acquires ModuleControl {
        init_module(deployer);

        propose_admin(deployer, signer::address_of(user1));

        // Since user2 is not proposed as new admin, it should fail if it tries to accept it 
        accept_admin(user2);
    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___create_stream_with_coins(aptos_framework: &signer, deployer: &signer, user1: &signer) acquires Stream,ModuleControl,ActiveStreams {
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;


        ////////////////
        // TEST START //
        ////////////////
        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);

        // Check if the balance of the admin decreses
        assert!(coin::balance<Coin1>(deployer_address) == deployer_initial_balance - amount_to_vest);

        // Get created stream
        let (user_stream_objects, user_streams) = user_active_streams_data(user1_address);
        let stream = user_streams.borrow(0);
        let stream_address = *user_stream_objects.borrow(0);
        
        // Check if there is no duplicates
        assert!(user_streams.length() == 1);

        // Make sure Stream data is working corectlly
        assert!(stream.beneficiary == user1_address);
        assert!(stream.amount == amount_to_vest);
        assert!(stream.start_time == start_time);
        assert!(stream.cliff_duration == cliff_duration);
        assert!(stream.vesting_duration == vesting_duration);

        // Check that Stream Object has vesting funds
        assert!(coin::balance<Coin1>(stream_address) == amount_to_vest);

        // Get emmited event 
        let emited_events = event::emitted_events<StreamCreatedEvent>();
        let emited_event = emited_events.borrow(0);

        // Check if event data is correct
        assert!(emited_event.beneficiary == user1_address);
        assert!(emited_event.metadata_address == stream.metadata_address);
        assert!(emited_event.object_address == stream_address);
    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___create_stream_with_fa(aptos_framework: &signer, deployer: &signer, user1: &signer) acquires Stream,ModuleControl,ActiveStreams {
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        // Convert user Coin1 to FA to avoid writing extra FA creation code       
        let coins = coin::withdraw<Coin1>(deployer, deployer_initial_balance);
        let fa = coin::coin_to_fungible_asset<Coin1>(coins);
        let metadata = fungible_asset::metadata_from_asset(&fa);
        pfs::deposit(deployer_address, fa);

        
        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;


        ////////////////
        // TEST START //
        ////////////////
        create_stream_with_fa(deployer,user1_address,start_time,
            cliff_duration,vesting_duration,metadata,amount_to_vest);

        // Check if the balance of the admin decreses
        assert!(pfs::balance(deployer_address, metadata) == deployer_initial_balance - amount_to_vest);

        // Get created stream
        let (user_stream_objects, user_streams) = user_active_streams_data(user1_address);
        let stream = user_streams.borrow(0);
        let stream_address = *user_stream_objects.borrow(0);
        
        // Check if there is no duplicates
        assert!(user_streams.length() == 1);

        // Make sure Stream data is working corectlly
        assert!(stream.beneficiary == user1_address);
        assert!(stream.amount == amount_to_vest);
        assert!(stream.start_time == start_time);
        assert!(stream.cliff_duration == cliff_duration);
        assert!(stream.vesting_duration == vesting_duration);


        // Check that Stream Object has vesting funds
        assert!(pfs::balance(stream_address, metadata) == amount_to_vest);


        // Get emmited event 
        let emited_events = event::emitted_events<StreamCreatedEvent>();
        let emited_event = emited_events.borrow(0);

        // Check if event data is correct
        assert!(emited_event.beneficiary == user1_address);
        assert!(emited_event.metadata_address == stream.metadata_address);
        assert!(emited_event.object_address == stream_address);
    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___delete_stream(aptos_framework: &signer, deployer: &signer, user1: &signer) acquires StreamControl, Stream, ModuleControl,ActiveStreams {
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;

        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);

        ////////////////
        // TEST START //
        ////////////////
        delete_stream(deployer, stream_address);

        // Make sure the stream was removed from user active streams list
        let active_streams = user_active_streams(user1_address);
        assert!(active_streams.length() == 0);

        // Check if balance is returned to admin
        assert!(coin::balance<Coin1>(deployer_address) == deployer_initial_balance);

        // Get emmited event 
        let emited_events = event::emitted_events<DeleteEmptyStreamEvent>();
        let emited_event = emited_events.borrow(0);

        assert!(emited_event.object_address == stream_address);

    }

    
    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1), expected_failure]
    fun test___delete_stream___already_vesting_error(aptos_framework: &signer, deployer: &signer, user1: &signer) acquires StreamControl, Stream, ModuleControl,ActiveStreams {
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;

        // Prepare a vesting stream to produce the error
        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);

        // Change time to match vesting phase
        timestamp::update_global_time_for_test_secs(14);

        ////////////////
        // TEST START //
        ////////////////
        delete_stream(deployer, stream_address);

    }


    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___add_coin_balance_to_stream(aptos_framework: &signer, deployer: &signer, user1: &signer) acquires Stream, ModuleControl,ActiveStreams {
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;

        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);

        let amount_to_add = 30;


        ////////////////
        // TEST START //
        ////////////////
        add_coin_balance_to_stream<Coin1>(deployer, stream_address,amount_to_add);
        
        let stream_balance = coin::balance<Coin1>(stream_address);

        // Check that balances were moved 
        assert!(coin::balance<Coin1>(deployer_address) == deployer_initial_balance - amount_to_vest - amount_to_add);
        assert!(stream_balance == amount_to_vest + amount_to_add);

        // Check that object data was updated
        let stream = stream_data(stream_address);
        assert!(stream.amount == stream_balance);

        // Get emmited event 
        let emited_events = event::emitted_events<ModifyStreamDataEvent>();
        let emited_event = emited_events.borrow(0);

        // Check if event data is correct
        assert!(emited_event.object_address == stream_address);


    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1), expected_failure]
    fun test___add_coin_balance_to_stream___wrong_coin(aptos_framework: &signer, deployer: &signer, user1: &signer) acquires Stream, ModuleControl,ActiveStreams {
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;
        let amount_to_add = 30;


        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);
        tu::get_coins<Coin2>(deployer, amount_to_add);


        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;

        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);


        
        ////////////////
        // TEST START //
        ////////////////
        // Should error when trying to send a different coin to the Stream Object
        add_coin_balance_to_stream<Coin2>(deployer, stream_address,amount_to_add);
        
    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___add_fa_balance_to_stream(aptos_framework: &signer, deployer: &signer, user1: &signer) acquires Stream, ModuleControl,ActiveStreams {
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        // Convert user Coin1 to FA to avoid writing extra FA creation code       
        let coins = coin::withdraw<Coin1>(deployer, deployer_initial_balance);
        let fa = coin::coin_to_fungible_asset<Coin1>(coins);
        let metadata = fungible_asset::metadata_from_asset(&fa);
        pfs::deposit(deployer_address, fa);
        

        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;


        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);

        let amount_to_add = 30;


        ////////////////
        // TEST START //
        ////////////////
        add_fa_balance_to_stream(deployer, stream_address, metadata, amount_to_add);
        
        let stream_balance = coin::balance<Coin1>(stream_address);

        // Check that balances were moved 
        assert!(coin::balance<Coin1>(deployer_address) == deployer_initial_balance - amount_to_vest - amount_to_add);
        assert!(stream_balance == amount_to_vest + amount_to_add);

        // Check that object data was updated
        let stream = stream_data(stream_address);
        assert!(stream.amount == stream_balance);

        // Get emmited event 
        let emited_events = event::emitted_events<ModifyStreamDataEvent>();
        let emited_event = emited_events.borrow(0);

        // Check if event data is correct
        assert!(emited_event.object_address == stream_address);

    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___remove_balance_from_stream(aptos_framework: &signer, deployer: &signer, user1: &signer) acquires Stream,StreamControl, ModuleControl,ActiveStreams {
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;


        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);

        let amount_to_remove = 10;
    

        ////////////////
        // TEST START //
        ////////////////
        remove_balance_from_stream(deployer, stream_address,amount_to_remove);

        let stream = stream_data(stream_address);
        let metadata = object::address_to_object<Metadata>(stream.metadata_address);

        
        let stream_balance = pfs::balance(stream_address, metadata);

        // Check that balances were moved 
        assert!(stream_balance == amount_to_vest - amount_to_remove);

        // Check that object data was updated
        assert!(stream.amount == stream_balance);

        // In the case of the admin, it has FA back, so need to check for FA balance
        assert!(pfs::balance(deployer_address, metadata) == amount_to_remove);

        // Get emmited event 
        let emited_events = event::emitted_events<ModifyStreamDataEvent>();
        let emited_event = emited_events.borrow(0);

        // Check if event data is correct
        assert!(emited_event.object_address == stream_address);
    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___assert_pre_vesting_phase(aptos_framework: &signer,deployer: &signer, user1 :&signer) acquires ModuleControl, ActiveStreams,Stream{
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;


        // Start test
        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);

        // Get stream
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);


        ////////////////
        // TEST START //
        ////////////////
        // Won't error since test time is by defualt set to 0
        assert_pre_vesting_phase(stream_address);

    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1), expected_failure]
    fun test___assert_pre_vesting_phase___vesting_started_error(aptos_framework: &signer,deployer: &signer, user1 :&signer) acquires ModuleControl, ActiveStreams,Stream{
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;


        // Start test
        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);

        // Get stream
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);

        // Advance time so it errors
        timestamp::update_global_time_for_test_secs(start_time + cliff_duration + 1);

        ////////////////
        // TEST START //
        ////////////////
        // This should error since the vesting phase is ongoing
        assert_pre_vesting_phase(stream_address);

    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1, user2 = @user2)]
    fun test___change_stream_beneficiary(aptos_framework: &signer,deployer: &signer, user1 :&signer, user2: &signer) acquires ModuleControl, ActiveStreams,Stream{
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let user1_address = signer::address_of(user1);
        let user2_address = signer::address_of(user2);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;


        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);

        // Get stream
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);


        ////////////////
        // TEST START //
        ////////////////
        change_stream_beneficiary(deployer, stream_address, user2_address);

        let stream = stream_data(stream_address);
        assert!(stream.beneficiary == user2_address);

        // Get emmited event 
        let emited_events = event::emitted_events<ModifyStreamDataEvent>();
        let emited_event = emited_events.borrow(0);

        // Check if event data is correct
        assert!(emited_event.object_address == stream_address);
    } 

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___change_stream_start_time(aptos_framework: &signer,deployer: &signer, user1 :&signer) acquires ModuleControl, ActiveStreams,Stream{
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 5;
        let vesting_duration = 10;
        let amount_to_vest = 20;

        let new_start_time = 12;

        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);

        // Get stream
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);

        ////////////////
        // TEST START //
        ////////////////
        change_stream_start_time(deployer, stream_address, new_start_time);

        let stream = stream_data(stream_address);
        assert!(stream.start_time == new_start_time);

        // Get emmited event 
        let emited_events = event::emitted_events<ModifyStreamDataEvent>();
        let emited_event = emited_events.borrow(0);

        // Check if event data is correct
        assert!(emited_event.object_address == stream_address);
    } 

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1), expected_failure]
    fun test___change_stream_start_time___already_vesting(aptos_framework: &signer,deployer: &signer, user1 :&signer) acquires ModuleControl, ActiveStreams,Stream{
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 5;
        let vesting_duration = 10;
        let amount_to_vest = 20;

        let new_start_time = 12;

        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);

        // Get stream
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);

        // Advance time to vesting phase to trigger error    
        timestamp::update_global_time_for_test_secs(16);


        ////////////////
        // TEST START //
        ////////////////
        change_stream_start_time(deployer, stream_address, new_start_time);

    } 

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1), expected_failure]
    fun test___change_stream_start_time___error_skiping_vesting(aptos_framework: &signer,deployer: &signer, user1 :&signer) acquires ModuleControl, ActiveStreams,Stream{
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 5;
        let vesting_duration = 10;
        let amount_to_vest = 20;


        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);

        // Get stream
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);

        // Create a situation where the new start time would skip vesting
        timestamp::update_global_time_for_test_secs(9);
        let new_start_time = 2;

        ////////////////
        // TEST START //
        ////////////////
        change_stream_start_time(deployer, stream_address, new_start_time);

    } 

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___change_stream_cliff_duration(aptos_framework: &signer,deployer: &signer, user1 :&signer) acquires ModuleControl, ActiveStreams,Stream{
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;

        let new_cliff_duration = 3;

        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);

        // Get stream
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);


        ////////////////
        // TEST START //
        ////////////////
        change_stream_cliff_duration(deployer, stream_address, new_cliff_duration);

        let stream = stream_data(stream_address);
        assert!(stream.cliff_duration == new_cliff_duration);

        // Get emmited event 
        let emited_events = event::emitted_events<ModifyStreamDataEvent>();
        let emited_event = emited_events.borrow(0);

        // Check if event data is correct
        assert!(emited_event.object_address == stream_address);
    } 
    
    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___change_vesting_duration(aptos_framework: &signer,deployer: &signer, user1 :&signer) acquires ModuleControl, ActiveStreams,Stream{
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        
        let start_time = 10;
        let cliff_duration = 2;
        let vesting_duration = 10;
        let amount_to_vest = 20;

        let new_vesting_duration = 20;

        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);

        // Get stream
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);


        ////////////////
        // TEST START //
        ////////////////
        change_vesting_duration(deployer, stream_address, new_vesting_duration);

        let stream = stream_data(stream_address);
        assert!(stream.vesting_duration == new_vesting_duration);

        // Get emmited event 
        let emited_events = event::emitted_events<ModifyStreamDataEvent>();
        let emited_event = emited_events.borrow(0);

        // Check if event data is correct
        assert!(emited_event.object_address == stream_address);
    } 


    #[test(aptos_framework = @0x1, deployer = @deployer)]
    fun test___calculate_vested_tokens___pre_cliff_phase(aptos_framework: &signer,deployer: &signer,){
        // Initialize timestamp since calcualte_vested_tokens() has a dependency on it
        tu::init(aptos_framework, deployer);
        

        let total_amount:u64 = 100;
        let remaining_amount:u64 = 100;
        let start_time:u64 = 10;
        let cliff_duration:u64 = 5;
        let vesting_duration:u64 = 20;
        
        // If not even cliff started, it should return 0 since time is 0
        let expected_amount = 0;

        let result = calculate_vested_tokens(total_amount, remaining_amount, start_time, cliff_duration, vesting_duration);

        assert!(result == expected_amount);
    }

    #[test(aptos_framework = @0x1, deployer = @deployer)]
    fun test___calculate_vested_tokens___still_cliff_phase(aptos_framework: &signer,deployer: &signer,){
        // Initialize timestamp since calcualte_vested_tokens() has a dependency on it
        tu::init(aptos_framework, deployer);
        
        let total_amount:u64 = 100;
        let remaining_amount:u64 = 100;
        let start_time:u64 = 10;
        let cliff_duration:u64 = 5;
        let vesting_duration:u64 = 20;
        
        // During cliff it should still return 0
        timestamp::update_global_time_for_test_secs(13);
        let expected_amount = 0;

        let result = calculate_vested_tokens(total_amount, remaining_amount, start_time, cliff_duration, vesting_duration);

        assert!(result == expected_amount);
    }

    
    #[test(aptos_framework = @0x1, deployer = @deployer)]
    fun test___calculate_vested_tokens___cliff_end_second_0(aptos_framework: &signer,deployer: &signer,){
        // Initialize timestamp since calcualte_vested_tokens() has a dependency on it
        tu::init(aptos_framework, deployer);
        

        let total_amount:u64 = 100;
        let remaining_amount:u64 = 100;
        let start_time:u64 = 10;
        let cliff_duration:u64 = 5;
        let vesting_duration:u64 = 20;
         
        // Cliff ended, but 0 seonds passed since, so there are 0 vested tokens
        timestamp::update_global_time_for_test_secs(15);
        let expected_amount = 0;

        let result = calculate_vested_tokens(total_amount, remaining_amount, start_time, cliff_duration, vesting_duration);

        assert!(result == expected_amount);
    }

    #[test(aptos_framework = @0x1, deployer = @deployer)]
    fun test___calculate_vested_tokens___fully_vested_precise(aptos_framework: &signer,deployer: &signer,){
        // Initialize timestamp since calcualte_vested_tokens() has a dependency on it
        tu::init(aptos_framework, deployer);
        

        let total_amount:u64 = 100;
        let remaining_amount:u64 = 100;
        let start_time:u64 = 10;
        let cliff_duration:u64 = 5;
        let vesting_duration:u64 = 20;
         
        // exact full vesting time = 10 + 5 + 20
        timestamp::update_global_time_for_test_secs(35);
        let expected_amount = total_amount;

        let result = calculate_vested_tokens(total_amount, remaining_amount, start_time, cliff_duration, vesting_duration);

        assert!(result == expected_amount);
    }

    #[test(aptos_framework = @0x1, deployer = @deployer)]
    fun test___calculate_vested_tokens___fully_vested_post(aptos_framework: &signer,deployer: &signer,){
        // Initialize timestamp since calcualte_vested_tokens() has a dependency on it
        tu::init(aptos_framework, deployer);
        

        let total_amount:u64 = 100;
        let remaining_amount:u64 = 100;
        let start_time:u64 = 10;
        let cliff_duration:u64 = 5;
        let vesting_duration:u64 = 20;
         
        // Lots of time passed since fully vestd
        timestamp::update_global_time_for_test_secs(1005);
        let expected_amount = total_amount;

        let result = calculate_vested_tokens(total_amount, remaining_amount, start_time, cliff_duration, vesting_duration);

        assert!(result == expected_amount);
    }

    #[test(aptos_framework = @0x1, deployer = @deployer)]
    fun test___calculate_vested_tokens___20_percent_vested(aptos_framework: &signer,deployer: &signer,){
        // Initialize timestamp since calcualte_vested_tokens() has a dependency on it
        tu::init(aptos_framework, deployer);
        
        let total_amount:u64 = 100;
        let remaining_amount:u64 = 100;
        let start_time:u64 = 10;
        let cliff_duration:u64 = 5;
        let vesting_duration:u64 = 20;
         
        // Vesting starts at time 15
        // at 19 (4 seconds later) it should have 20% vested
        timestamp::update_global_time_for_test_secs(19);
        let expected_amount = 20;

        let result = calculate_vested_tokens(total_amount, remaining_amount, start_time, cliff_duration, vesting_duration);

        assert!(result == expected_amount);
    }

    #[test(aptos_framework = @0x1, deployer = @deployer)]
    fun test___calculate_vested_tokens___second_claim_while_still_vesting(aptos_framework: &signer,deployer: &signer,){
        // Initialize timestamp since calcualte_vested_tokens() has a dependency on it
        tu::init(aptos_framework, deployer);
        
        let total_amount:u64 = 100;
        // Simulate a claim at 20% vested, thus 80 tokens remaining
        let remaining_amount:u64 = 80;
        let start_time:u64 = 10;
        let cliff_duration:u64 = 5;
        let vesting_duration:u64 = 20;
         
        // Vesting starts at time 15
        // at 23 (8 seconds later) it should have 40% vested
        // since 20% was claimend, it should retunr another 20%
        timestamp::update_global_time_for_test_secs(23);
        let expected_amount = 20;

        let result = calculate_vested_tokens(total_amount, remaining_amount, start_time, cliff_duration, vesting_duration);

        assert!(result == expected_amount);
    }

    #[test(aptos_framework = @0x1, deployer = @deployer)]
    fun test___calculate_vested_tokens___claim_remaining_after_first_claim(aptos_framework: &signer,deployer: &signer,){
        // Initialize timestamp since calcualte_vested_tokens() has a dependency on it
        tu::init(aptos_framework, deployer);
        
        let total_amount:u64 = 100;
        // User already calimed 20 at time(19) so there are 80 remaining
        let remaining_amount:u64 = 80;
        let start_time:u64 = 10;
        let cliff_duration:u64 = 5;
        let vesting_duration:u64 = 20;
         
        // Claim the remaining 80% when fully vested
        timestamp::update_global_time_for_test_secs(1000);
        let expected_amount = 80;

        let result = calculate_vested_tokens(total_amount, remaining_amount, start_time, cliff_duration, vesting_duration);

        assert!(result == expected_amount);
    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___claim_stream___20_percent_claim(aptos_framework: &signer, deployer: &signer, user1: &signer) acquires Stream,StreamControl,ModuleControl,ActiveStreams {
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        // Convert user Coin1 to FA to avoid writing extra FA creation code       
        let coins = coin::withdraw<Coin1>(deployer, deployer_initial_balance);
        let fa = coin::coin_to_fungible_asset<Coin1>(coins);
        pfs::deposit(deployer_address, fa);


        let start_time = 10;
        let cliff_duration = 5;
        let vesting_duration = 20;
        let amount_to_vest = 100;


        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);
        let stream = stream_data(stream_address);

        let metadata = object::address_to_object<Metadata>(stream.metadata_address);

        let user_pre_balance = pfs::balance(user1_address, metadata);
        let expected_to_claim = 20;

        // Cliff end time = 15 
        // 4 seconds = 20 %
        timestamp::update_global_time_for_test_secs(19);


        ////////////////
        // TEST START //
        ////////////////
        claim_stream(user1, stream_address);

        let user_post_balance = pfs::balance(user1_address, metadata);

        // Check if balance was extracted from Stream object and added to user
        assert!(pfs::balance(stream_address,metadata) == amount_to_vest - expected_to_claim);
        assert!(user_post_balance == user_pre_balance + expected_to_claim);


        // Get emmited event 
        let emited_events = event::emitted_events<VestedTokensClaimEvent>();
        let emited_event = emited_events.borrow(0);

        // Check if event data is correct
        assert!(emited_event.object_address == stream_address);
        assert!(emited_event.amount == expected_to_claim);

    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1)]
    fun test___claim_stream___full_claim(aptos_framework: &signer, deployer: &signer, user1: &signer) acquires Stream,StreamControl,ModuleControl,ActiveStreams {
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        // Convert deployer Coin1 to FA to avoid writing extra FA creation code       
        let coins = coin::withdraw<Coin1>(deployer, deployer_initial_balance);
        let fa = coin::coin_to_fungible_asset<Coin1>(coins);
        pfs::deposit(deployer_address, fa);


        let start_time = 10;
        let cliff_duration = 5;
        let vesting_duration = 20;
        let amount_to_vest = 100;


        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);
        let stream = stream_data(stream_address);

        let metadata = object::address_to_object<Metadata>(stream.metadata_address);

        let user_pre_balance = pfs::balance(user1_address, metadata);
        let expected_to_claim = amount_to_vest;

        // Vesting fully ended
        timestamp::update_global_time_for_test_secs(1000);


        ////////////////
        // TEST START //
        ////////////////
        claim_stream(user1, stream_address);

        let user_post_balance = pfs::balance(user1_address, metadata);

        // Check if balance was extracted from Stream object and added to user
        assert!(pfs::balance(stream_address,metadata) == 0);
        assert!(user_post_balance == user_pre_balance + expected_to_claim);


        // Get emmited event 
        let emited_events = event::emitted_events<VestedTokensClaimEvent>();
        let emited_event = emited_events.borrow(0);

        // Check if event data is correct
        assert!(emited_event.object_address == stream_address);
        assert!(emited_event.amount == expected_to_claim);


        // Get emmited event 
        let emited_events = event::emitted_events<DeleteEmptyStreamEvent>();
        let emited_event = emited_events.borrow(0);

        // Checking if the active streams were updated were made when cehcking admin delete_stream() function
        // since they use the same internal function, we only check the Delete Event to make sure it was triggered 
        assert!(emited_event.object_address == stream_address);
    }
    
    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1, user2 = @user2), expected_failure]
    fun test___claim_stream___not_beneficiary(aptos_framework: &signer, deployer: &signer, user1: &signer, user2: &signer) acquires Stream,StreamControl,ModuleControl,ActiveStreams {
        //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);

        let deployer_initial_balance = 100;

        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);

        // Convert user Coin1 to FA to avoid writing extra FA creation code       
        let coins = coin::withdraw<Coin1>(deployer, deployer_initial_balance);
        let fa = coin::coin_to_fungible_asset<Coin1>(coins);
        pfs::deposit(deployer_address, fa);


        let start_time = 10;
        let cliff_duration = 5;
        let vesting_duration = 20;
        let amount_to_vest = 100;


        create_stream_with_coins<Coin1>(deployer, user1_address, start_time, cliff_duration, vesting_duration, amount_to_vest);
        let active_streams = user_active_streams(user1_address);
        let stream_address = *active_streams.borrow(0);

        ////////////////
        // TEST START //
        ////////////////
        // should error since user2 is not the beneficiary of the stream
        claim_stream(user2, stream_address);

    }

    #[test(aptos_framework = @0x1, deployer = @deployer, user1 = @user1, user2 = @user2)]
    fun test___staged_simulation(aptos_framework: &signer, deployer: &signer, user1: &signer, user2: &signer) acquires Stream,StreamControl,ModuleControl,ActiveStreams {
                //////////////////////
        // TEST PREPARATION //
        //////////////////////
        init_module(deployer);
        tu::init(aptos_framework, deployer);
        let deployer_address = signer::address_of(deployer);
        let user1_address = signer::address_of(user1);
        let user2_address = signer::address_of(user2);

        let deployer_initial_balance = 1000;
        tu::get_apt(deployer,10);
        tu::get_coins<Coin1>(deployer, deployer_initial_balance);
        tu::get_coins<Coin2>(deployer, deployer_initial_balance);
        tu::get_coins<Coin3>(deployer, deployer_initial_balance);

        // Prepare metada of each coin to be used latter, while at it, convert those coins to FA 
        let coins1 = coin::withdraw<Coin1>(deployer, deployer_initial_balance);
        let coins2 = coin::withdraw<Coin2>(deployer, deployer_initial_balance);
        let coins3 = coin::withdraw<Coin3>(deployer, deployer_initial_balance);

        let fa1 = coin::coin_to_fungible_asset<Coin1>(coins1);
        let fa2 = coin::coin_to_fungible_asset<Coin2>(coins2);
        let fa3 = coin::coin_to_fungible_asset<Coin3>(coins3);

        let metadata1 = fungible_asset::metadata_from_asset(&fa1);
        let metadata2 = fungible_asset::metadata_from_asset(&fa2);
        let metadata3 = fungible_asset::metadata_from_asset(&fa3);
        
        pfs::deposit(deployer_address, fa1);
        pfs::deposit(deployer_address, fa2);
        pfs::deposit(deployer_address, fa3);


        // Create 2 streams of Coin1 for each user
        // caller, user_address, start_time, cliff_duration, vesting_duration, metadata, amount
        create_stream_with_fa(deployer, user1_address, 5, 5, 10, metadata1, 100);
        create_stream_with_fa(deployer, user2_address, 5, 5, 10, metadata1, 90);

        // Admin misses and creates one extra to user1
        create_stream_with_fa(deployer, user1_address, 5, 5, 10, metadata1, 100);

        // Creates Coin2 stream to user1 that starts after its first stream
        create_stream_with_fa(deployer, user1_address, 20, 5, 10, metadata2, 100);
        
        // Creates Coin3 stream to user2 that starts when first stream ends
        create_stream_with_fa(deployer, user2_address, 20, 5, 10, metadata2, 100);

        // Creates Coin2 stream to user2 that starts at the same time as the second one
        create_stream_with_fa(deployer, user2_address, 20, 5, 10, metadata3, 100);


        // Admin made a mistake and saw that there are 10 coin missing from User2 Stream, so it adds them
        let user2_streams = user_active_streams(user2_address);
        let stream_address = *user2_streams.borrow(0);
        add_fa_balance_to_stream(deployer, stream_address, metadata1, 10);

        // Admin notices that it created an extra Coin1 stream to user 1 by mistake, so it deletes it
        let user1_streams = user_active_streams(user1_address);
        let stream_address = *user1_streams.borrow(1);
        delete_stream(deployer, stream_address);

        // Check that user1 has 2 streams and user2 has 3
        let user1_streams = user_active_streams(user1_address);

        assert!(user1_streams.length() == 2);
        assert!(user2_streams.length() == 3);

        // Check that deployer balances are correct after creating streams
        assert!(pfs::balance(deployer_address, metadata1) == 800);
        assert!(pfs::balance(deployer_address, metadata2) == 800);
        assert!(pfs::balance(deployer_address, metadata3) == 900);


        // Time passes, user1 claims at 20% of coin1 vestings
        timestamp::update_global_time_for_test_secs(12);
        claim_stream(user1, *user1_streams.borrow(0));

        // Time passes, cliff phase is going on second wave streams
        timestamp::update_global_time_for_test_secs(21);

        // User2 claims 100% coin1 stream
        claim_stream(user2, *user2_streams.borrow(0));

        // Check if claims were sucessfull
        assert!(pfs::balance(user1_address,metadata1) == 20);
        assert!(pfs::balance(user2_address,metadata1) == 100);

        // Admin notices that coin3 stream was wrong,should start 5 seconds later, have 0 cliff and last 5 seconds of vesting
        change_stream_start_time(deployer, *user2_streams.borrow(2), 25);
        change_stream_cliff_duration(deployer, *user2_streams.borrow(2), 0);
        change_vesting_duration(deployer, *user2_streams.borrow(2), 5);

        // Admin overalocated to stream of coin3 retrives 60 coin3
        remove_balance_from_stream(deployer, *user2_streams.borrow(2), 60);
        //and creates a new stream to user2 with them
        create_stream_with_fa(deployer, user1_address, 25, 0, 5, metadata3, 60);

        // Check that admin didn't use new funds, but those extracted 60
        assert!(pfs::balance(deployer_address, metadata3) == 900);

        // Check that each user1 has 3 streams
        let user1_streams = user_active_streams(user1_address);
        assert!(user1_streams.length() == 3);

        // Check that user2 has 2 streams, since it claimed stream1 fully, it was deleted
        let user2_streams = user_active_streams(user2_address);
        assert!(user2_streams.length() == 2);

        // Time passes, Coin2 streams are at 80% vesting
        timestamp::update_global_time_for_test_secs(33);

        // User1 claims coin1 stream and 80% of coin2
        claim_stream(user1, *user1_streams.borrow(0));
        claim_stream(user1, *user1_streams.borrow(1));

        assert!(pfs::balance(user1_address,metadata1) == 100);
        assert!(pfs::balance(user1_address,metadata2) == 80);

        // User1 should have 2 streams aswell since the first one was fully claimed
        let user1_streams = user_active_streams(user1_address);
        assert!(user1_streams.length() == 2);

        // Time passed, all streams were fully vested
        timestamp::update_global_time_for_test_secs(100);
        
        // Both users claim all remaining streams
        claim_stream(user1, *user1_streams.borrow(0));
        claim_stream(user1, *user1_streams.borrow(1));
        claim_stream(user2, *user2_streams.borrow(0));
        claim_stream(user2, *user2_streams.borrow(1));

        // Both users should have 100 Coin1, 100 Coin2
        // User1 should have 60 Coin3 and user2 40 Coin3
        assert!(pfs::balance(user1_address,metadata1) == 100);
        assert!(pfs::balance(user1_address,metadata2) == 100);
        assert!(pfs::balance(user1_address,metadata3) == 60);

        assert!(pfs::balance(user2_address,metadata1) == 100);
        assert!(pfs::balance(user2_address,metadata2) == 100);
        assert!(pfs::balance(user2_address,metadata3) == 40);


        // Check that their active streams lists are empty
        let user1_streams = user_active_streams(user1_address);
        assert!(user1_streams.length() == 0);

        let user2_streams = user_active_streams(user2_address);
        assert!(user2_streams.length() == 0);
            
        // Check if events were sucessfully emited
        let creation_events = event::emitted_events<StreamCreatedEvent>();
        let modification_events = event::emitted_events<ModifyStreamDataEvent>();
        let claimed_tokens_events = event::emitted_events<VestedTokensClaimEvent>();
        let deleted_events = event::emitted_events<DeleteEmptyStreamEvent>();
        
        assert!(creation_events.length() == 7);
        // 1 add balance, 3 data mod, 1 remove balance
        assert!(modification_events.length() == 5); 
        assert!(claimed_tokens_events.length() == 8);
        // Should be same as creation if they have been claimed
        assert!(deleted_events.length() == 7);

    }


}