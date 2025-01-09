// This is module is for pure TESTING
// for extra info check https://github.com/0xHepha/aptos-test-utils for

module deployer::tu{
    use std::signer;
    use std::vector;
    use std::string_utils;
    use std::timestamp;
    use std::randomness;
    use std::option::{Self, Option};
    use std::string::{Self, String};
     
    use aptos_framework::object::{Self};
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::coin::{Self, MintCapability, destroy_burn_cap, destroy_freeze_cap, destroy_mint_cap};

    use aptos_token::token::{Self as tokenv1,TokenId};

    use aptos_token_objects::aptos_token::{Self,AptosToken, AptosCollection};

    //use std::debug;



    // DEFAULT COLLECTION CONSTS

    const CREATOR_SEED: vector<u8> = b"Creates";
    
    // Used to control a resource account, generailly for module items
    struct Config has key {
        creator_cap: SignerCapability
    }

    // Stores mint capability for APT obtained with aptos_framework
    struct CoinConfig has key{
        mint_cap: MintCapability<AptosCoin>,
    }


    // This funcion needs to be called at the begining of each test to be able to use TU functionalities
    //  - Start time for timestamp functions to be able to work
    //  - Set a random seed for randomness to be able to work
    //  - Initialize structs that enable APT mints to users
    //  - Initialize structs for V1 & V2 collection management
    //  - Creates 10 Coins for tests: <Coin1>,<Coin2>....<Coin10>
    #[lint::allow_unsafe_randomness]
    #[test_only]
    public fun init(aptos_framework: &signer, deployer: &signer){
        // Start time so that functions can use timestamp related calls
        timestamp::set_time_has_started_for_testing(aptos_framework);

        // Initialize for unit tests with randomness
        randomness::initialize_for_testing(aptos_framework);
        randomness::set_seed(x"0000000000000000000000000000000000000000000000000000000000000000");

        
        // Create the resource account used to manage module items instead of deployers account
        let (_resource, resource_cap) = account::create_resource_account(deployer, CREATOR_SEED);
        // Get resource signer to pre-mint 10 Coins
        let creator = &account::create_signer_with_capability(&resource_cap);

        // pre-mint 1M of each of the 10 Coins and store them in resource account
        // They will be used to simulate coin mints 
        internal_mint_coins(deployer,creator);

        // Store SignerCapability
        move_to(deployer,Config{
            creator_cap: resource_cap
        });

        // Initialize APT management for tests
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(aptos_framework);
        
        // Burn cap won't be used
        coin::destroy_burn_cap(burn_cap);

        // Store APT mint cap
        move_to(deployer, CoinConfig{
            mint_cap: mint_cap
        });

        // Initialize sturcts to manage Collections
        move_to(deployer, CollectionsV1 {
            list: vector[],
            tokens: vector[],
            creators: vector[],
        });

        move_to(deployer, CollectionsV2 {
            list: vector[],
            tokens: vector[],
            creators: vector[],
        });

    }


    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    // >>>   GENERAL HELPER FUNCTIONS   >>>
    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    // Gets module resource accoun signer
    fun get_creator(): signer acquires Config{
      let config = borrow_global<Config>(@deployer);
      account::create_signer_with_capability(&config.creator_cap)
    } 

    
    // FUnction used to concat and create string for collection names
    // Result: "V{version} Test Collection {index}"
    fun concat_collection_name(version: u64, index:u64): String{
        let collection_name = string::utf8(b"V");
        string::append(&mut collection_name, string_utils::to_string<u64>(&version));
        string::append(&mut collection_name, string::utf8(b" Test Collection "));
        string::append(&mut collection_name, string_utils::to_string<u64>(&index));
        collection_name
    }


    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    // >>>>>>>>      ITEM MANAGEMENT      >>>>>>>>
    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    // Struct that simulates an object
    // By combining "self: &Item" and "option" allows for multiple "different" structs
    // to call the same function with dot notation for different "items" while avoid the use of structs
    // For the dev using this module he can call what seems to be different structs like:
    // c1:CollectionV1  =>  c1.name();
    // c2:CollectionV2  =>  c2.name();
    // t1:TokenV1       =>  t1.name();
    // t2:TokenV2       =>  t2.name();
    struct Item has store, copy, drop {
        token_v1: Option<TokenV1>,
        collection_v1: Option<CollectionV1>,
        token_v2: Option<TokenV2>,
        collection_v2: Option<CollectionV2>,
    }

    // Function used to create Specific type of Item while avoiding the need create all the option::none() calls
    inline fun token_v1_item(token: TokenV1): Item {
        Item {
            token_v1: option::some<TokenV1>(token),
            collection_v1: option::none(),
            token_v2: option::none(),
            collection_v2: option::none(),
        }
    }

    inline fun collection_v1_item(collection: CollectionV1): Item {
        Item {
            token_v1: option::none(),
            collection_v1: option::some<CollectionV1>(collection),
            token_v2: option::none(),
            collection_v2: option::none(),
        }
    }

    
    inline fun token_v2_item(token: TokenV2): Item {
        Item {
            token_v1: option::none(),
            collection_v1: option::none(),
            token_v2: option::some<TokenV2>(token),
            collection_v2: option::none(),
        }
    }

    inline fun collection_v2_item(collection: CollectionV2): Item {
        Item {
            token_v1: option::none(),
            collection_v1: option::none(),
            token_v2: option::none(),
            collection_v2: option::some<CollectionV2>(collection),
        }
    }

    inline fun empty_item(): Item {
        Item {
            token_v1: option::none(),
            collection_v1: option::none(),
            token_v2: option::none(),
            collection_v2: option::none(),
        }
    }

    // Functions used to avoid the need to interact with option module each time we have a item
    inline fun token_v1(item: &Item): &TokenV1{
        option::borrow<TokenV1>(&item.token_v1)
    }
    inline fun collection_v1(item: &Item): &CollectionV1{
        option::borrow<CollectionV1>(&item.collection_v1)
    }

    inline fun token_v2(item: &Item): &TokenV2{
        option::borrow<TokenV2>(&item.token_v2)

    }

    inline fun collection_v2(item: &Item): &CollectionV2{
        option::borrow<CollectionV2>(&item.collection_v2)
    }


    // Functions used to check what type of item we are using
    inline fun is_token_v1(item: &Item): bool {
        option::is_some<TokenV1>(&item.token_v1)
    }

    inline fun is_collection_v1(item: &Item): bool {
        option::is_some<CollectionV1>(&item.collection_v1)
    }

    inline fun is_token_v2(item: &Item): bool {
        option::is_some<TokenV2>(&item.token_v2)
    }

    inline fun is_collection_v2(item: &Item): bool {
        option::is_some<CollectionV2>(&item.collection_v2)
    }


    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    // >>>>>>>>      COLLECTIONS V1      >>>>>>>>
    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    // Theese consts are used by Collection V2 aswell, be carefull when doing changes
    const COLLECTION_DESCRIPTION : vector<u8> = b"Collection created by test_only module for test purpouses";
    const COLLECTION_URI: vector<u8> = b"https://arweave.net/yV7tLNngiZm7jCxfxOxzUxYOXWD9HNu64pV-UTXOqWw";
    const COLLECTION_SUPPLY: u64 = 1000;
    const COLLECTION_ROYALTY_NUM: u64 = 100;
    const COLLECTION_ROYALTY_DEN: u64 = 1000;

    const TOKEN_DESCRIPTION: vector<u8> = b"Token used for tests";
    const TOKEN_URI: vector<u8> = b"https://arweave.net/JgXp079FBp6SWv5v0A3tBIGrEPiGt8quCSwgxSJRbcA";



    struct TokenV1 has store, copy, drop {
        // Position of this token inside the vector that correspons to his collection
        // To Access: CollectionsV1.tokens[collection_index][index]
        index: u64,
        // Name of the collection the token is part of
        collection_name: String,
        // Index of the collection inside CollectionsV1
        collection_index: u64,
        // Creator of the collection
        creator: address,
        // Token Name
        name: String,
        // Property Version
        version: u64,
    }

    struct CollectionV1 has store, copy, drop {
        // Index inside CollectionsV1.list
        index: u64,
        // Collection Creator
        creator: address,
        // Name of the collection
        name: String,
        // Amount of minted tokens
        supply: u64,
    }

    struct CollectionsV1 has key {
        // Stores the Item<CollectionV1> items
        list: vector<Item>,
        // Stores multidimensional array of TokenV1. tokens[collection_index][token_index]
        tokens: vector<vector<Item>>,
        // Stores the signer capability of each collection creator
        creators: vector<SignerCapability>,
    }


    public fun create_collection_v1(): Item acquires Config, CollectionsV1{

        let creator = get_creator();

        // get collections struct
        let collections = &mut CollectionsV1[@deployer]; 

        // Create new index, will be the amount of items
        let index = collections.list.length();

        // Create collection name
        let collection_name = concat_collection_name(1,index);

        // Create a new resource account to simulate collections on different addresses
        let seed = std::bcs::to_bytes<String>(&collection_name);
        let (_resource, resource_cap) = account::create_resource_account(&creator, seed);
        let collection_creator = account::create_signer_with_capability(&resource_cap);

        // Add creator capability just in case
        collections.creators.push_back(resource_cap);

        tokenv1::create_collection(
            &collection_creator,
            collection_name,
            string::utf8(COLLECTION_DESCRIPTION),
            string::utf8(COLLECTION_URI),
            COLLECTION_SUPPLY,
            vector[true,true,true]
        );

        // Create new item struct
        let new_collection = collection_v1_item(CollectionV1{
                index: index,
                creator: signer::address_of(&collection_creator),
                name: collection_name,
                supply: 0,
            });

        // Add new collection to array
        collections.list.push_back(new_collection);

        // Add empty tokens array
        collections.tokens.push_back(vector[]);

        new_collection     
    }

    fun mint_v1(self: Item, minter: &signer,amount: u64) acquires CollectionsV1{
        
        // Get references to collections struct
        let collections = &mut CollectionsV1[@deployer];
        
        // Obtain the CollectionV1 struct from the Item 
        let collection = option::borrow_mut<CollectionV1>(&mut collections.list[self.index()].collection_v1);

        // Refrence the array that stores tokens of the collection
        let collection_tokens = collections.tokens.borrow_mut(collection.index);

        // Get the colleciton creator
        let creator = &account::create_signer_with_capability(&collections.creators[self.index()]); 
        let creator_address = signer::address_of(creator);

        // Use index to avoid writing in each itearation to collection supply
        let temp_index = collection.supply;

        // Initialize minters TokenStore in case he doens't have one
        tokenv1::initialize_token_store(minter);
        
    
        for(i in 0..amount){
            // Generate token name by using collection name
            let token_name = collection.name;
            string::append(&mut token_name, string::utf8(b" T"));
            string::append(&mut token_name, string_utils::to_string<u64>(&temp_index));

            // CREATE TOKEN
            let token_data_id = tokenv1::create_tokendata(
                creator,
                collection.name,
                token_name,
                string::utf8(TOKEN_DESCRIPTION),
                0,
                string::utf8(TOKEN_URI),
                creator_address,
                COLLECTION_ROYALTY_DEN,
                COLLECTION_ROYALTY_NUM,
                tokenv1::create_token_mutability_config(&vector[true,true,true,true,true]),
                vector::empty<String>(),
                vector::empty<vector<u8>>(),
                vector::empty<String>(),
            );


            // MINT TOKEN
            tokenv1::mint_token(
                creator,
                token_data_id,
                1
            );   

            // Mutate each token so it converts to NFT
            let final_token_id = tokenv1::mutate_one_token(
                creator,
                creator_address,
                tokenv1::create_token_id(token_data_id,0),
                vector::empty<String>(),
                vector::empty<vector<u8>>(),
                vector::empty<String>(),
            );

            // Since we have the signers of both, we just direct transfer it
            tokenv1::direct_transfer(creator,minter,final_token_id,1);
            
            // Get property version to store at TokenV1 struct
            let (_1,_2,_3, token_version) = tokenv1::get_token_id_fields(&final_token_id);

            let new_item = token_v1_item(TokenV1 {
                    index: temp_index,
                    collection_name: collection.name,
                    collection_index: collection.index,
                    creator: creator_address,
                    name: token_name,
                    version: token_version, 
                });
    
         
            // Add new token to vector of tokens from the collection        
            collection_tokens.push_back(new_item);

            // Update the the token index
            temp_index += 1;
        };

        // Add minted amount to collection suplly
        collection.supply += amount;
    }

    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    // >>>>>>>>      COLLECTIONS V2      >>>>>>>>
    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    struct TokenV2 has store, copy, drop {
        // Position of this token inside the vector that correspons to his collection
        // To Access: CollectionsV2.tokens[collection_index][index]
        index: u64,
        // Address of the Token Object
        address: address,
        // Address of the Colleciton object
        collection_address: address,
        // Index of the collection inside CollectionsV2
        collection_index: u64,
    }

    struct CollectionV2 has store, copy, drop {
        // Index inside CollectionsV2.list
        index: u64,
        // Address of the Collection Object
        address: address,
        // Amount of minted tokens
        supply: u64,
        // Creator of the collection
        creator: address,
    }

    struct CollectionsV2 has key {
        // Stores the Item<CollectionV2> items
        list: vector<Item>,
        // Stores multidimensional array of TokenV2. tokens[collection_index][token_index]
        tokens: vector<vector<Item>>,
        // Stores the signer capability of each collection creator
        creators: vector<SignerCapability>,
    }


    
    public fun create_collection_v2():Item acquires Config, CollectionsV2{
        let creator = get_creator();

        // get collections struct
        let collections = &mut CollectionsV2[@deployer]; 

        // Create new index
        let index = collections.list.length();

        // Create collection name
        let collection_name = concat_collection_name(2,index);

        let seed = std::bcs::to_bytes<String>(&collection_name);
        let (_resource, resource_cap) = account::create_resource_account(&creator, seed);
        let collection_creator = &account::create_signer_with_capability(&resource_cap);

        // Add creator capability just in case
        collections.creators.push_back(resource_cap);


        // Create the collection to be minted
        let collection_object = aptos_token::create_collection_object(
            collection_creator,
            string::utf8(COLLECTION_DESCRIPTION),
            COLLECTION_SUPPLY,
            collection_name,
            string::utf8(COLLECTION_URI),
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            true,
            COLLECTION_ROYALTY_NUM,
            COLLECTION_ROYALTY_DEN
        );

        let new_collection = collection_v2_item(CollectionV2 {
            index: index,
            address: object::object_address<AptosCollection>(&collection_object),
            supply: 0,
            creator: signer::address_of(collection_creator),
        });

        // Store the resource cap in the object
        collections.list.push_back(new_collection);

        // Add empty tokens array
        collections.tokens.push_back(vector[]);

        new_collection

    }


    
    fun mint_v2(self: Item, minter: &signer, amount: u64) acquires CollectionsV2{
        // Get referecnce to CollectionsV2 struct
        let collections = &mut CollectionsV2[@deployer]; 
        // Extract collection from Item
        let collection =  option::borrow_mut<CollectionV2>(&mut collections.list[self.index()].collection_v2);
        // Reference to array that stores tokens of the collection
        let collection_tokens = collections.tokens.borrow_mut(collection.index);
        
        // Use a temporal index to avoid updating supply on each iteration
        let temp_index = collection.supply;
        
        // Create collection name
        let collection_name = concat_collection_name(2,collection.index);
       
        // Get the collection creator
        let collection_creator = &account::create_signer_with_capability(&collections.creators[self.index()]); 

        for(i in 0..amount){
            // Prepare the token name by adding the id to the collection name
            let token_name = collection_name;
            string::append(&mut token_name, string::utf8(b" T"));
            string::append(&mut token_name, string_utils::to_string<u64>(&temp_index));

            // Min the token
            let minted_token = aptos_token::mint_token_object(
                collection_creator,
                collection_name,
                string::utf8(TOKEN_DESCRIPTION),
                token_name,
                string::utf8(TOKEN_URI),
                vector::empty<String>(),
                vector::empty<String>(),
                vector::empty<vector<u8>>()
            );

            // Get token address
            let token_addr = object::object_address<AptosToken>(&minted_token);

            // Transfer the token to the minter
            object::transfer(collection_creator, minted_token, signer::address_of(minter));

            // Create Item struct
            let new_item = token_v2_item(TokenV2{
                index: temp_index,
                address: token_addr,
                collection_address: collection.address,
                collection_index: collection.index,
            });

            // Add token address to collection tokens list
            collection_tokens.push_back(new_item);

            // Update the the token index
            temp_index +=  1;
        };

        // add amount of minted to collection suplly
        collection.supply += amount;
    }

    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    // >>>>>>>>      COINS      >>>>>>>>
    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    // Test Coins structs
    struct Coin1 {}
    struct Coin2 {}
    struct Coin3 {}
    struct Coin4 {}
    struct Coin5 {}
    struct Coin6 {}
    struct Coin7 {}
    struct Coin8 {}
    struct Coin9 {}
    struct Coin10 {}
   
   // Creates 10 Test Coins and pre-mints stores them at module resource account
    fun internal_mint_coins(deployer: &signer, creator: &signer){
        internal_mint_coin<Coin1>(deployer,creator,1);  
        internal_mint_coin<Coin2>(deployer,creator,2);  
        internal_mint_coin<Coin3>(deployer,creator,3);  
        internal_mint_coin<Coin4>(deployer,creator,4);  
        internal_mint_coin<Coin5>(deployer,creator,5);  
        internal_mint_coin<Coin6>(deployer,creator,6);  
        internal_mint_coin<Coin7>(deployer,creator,7);  
        internal_mint_coin<Coin8>(deployer,creator,8);  
        internal_mint_coin<Coin9>(deployer,creator,9);  
        internal_mint_coin<Coin10>(deployer,creator,10);  
    } 

    // Function used to create and pre-mint each Test Coin
    fun internal_mint_coin<CoinType>(deployer: &signer, creator: &signer,index: u64){ 

        // Generate Coin name "Test Coin{index}"
        let name = string::utf8(b"Test Coin ");
        string::append(&mut name, string_utils::to_string<u64>(&index));

        // Generate Coin symbol "TESTCO{index}"
        let symbol = string::utf8(b"TESTCO");
        string::append(&mut symbol, string_utils::to_string<u64>(&index));

        // Create the coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<CoinType>(
            deployer,
            name,
            symbol,
            6,
            true
        );

        // Register the new coin resource account
        coin::register<CoinType>(creator);

        // Mint 1M coins
        let coins_minted = coin::mint(1000000000000, &mint_cap);

        // Store the coins at resource account
        coin::deposit(signer::address_of(creator), coins_minted);

        // Destroy all the capabilities since they wont be used again
        destroy_burn_cap(burn_cap);
        destroy_freeze_cap(freeze_cap);
        destroy_mint_cap(mint_cap);
    }

    // All the supplies of the coins are already minted and stored at the modules resouce account
    public fun get_coins<CoinType>(to: &signer, amount: u64) acquires Config{
        // Get address of the receiver
        let to_address = signer::address_of(to);

        // If the receiver doesn't have the coin registered, do it
        if(!coin::is_account_registered<CoinType>(to_address)){
            coin::register<CoinType>(to);
        };

        // Get reource account signer
        let creator = &get_creator();

        // Transfer coins from resource account to receiver
        let coins = coin::withdraw<CoinType>(creator,amount);
        coin::deposit<CoinType>(to_address, coins);
    }

    // Can be used to initialize accounts for tests aswell at the begining of test functions
    #[test_only]
    public fun get_apt(user: &signer, amount: u64) acquires CoinConfig{
        // Get APT mint capability
        let CoinConfig {mint_cap} = borrow_global<CoinConfig>(@deployer);

        // Get addr of the user that will get the coins
        let user_addr = signer::address_of(user);

        // Since they don't exist, intialize address
        account::create_account_for_test(user_addr);

        // Register APT for address
        coin::register<aptos_coin::AptosCoin>(user);

        // Get amount of coins
        let coins = coin::mint(amount, mint_cap);

        // Deposti coins at address
        coin::deposit(user_addr, coins);
    }

 
    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    // >>>>>>>>      GENERAL CALLS      >>>>>>>>
    // >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

    // Functions that take ITEM as input
    // Some of the functions like name() can be called for all Item<Type>
    // While others are avaible only to a specific, 
    // mint() for example can't be called by a token, only by collections
    
    public fun mint(self: &Item, minter: &signer, amount: u64) acquires CollectionsV1, CollectionsV2{
        if(is_collection_v1(self)){return mint_v1(*self, minter, amount)};
        if(is_collection_v2(self)){return mint_v2(*self, minter, amount)};

        // If it reaches here, the item type is wrong
        assert!(false);
    }

    public fun type(self: &Item): u64 {
        if(is_token_v1(self)) {return 1};
        if(is_collection_v1(self)) {return 1};
        if(is_token_v2(self)) {return 2};
        if(is_collection_v2(self)) {return 2};

        // It shouldn't reach, but if it does, raise an error
        assert!(false);

        //return is needed for compiler even if it never reaches
        0
    }

    public fun index(self: &Item): u64 {
        if(is_token_v1(self)) {return token_v1(self).index};
        if(is_collection_v1(self)) {return collection_v1(self).index};
        if(is_token_v2(self)) { return token_v2(self).index};
        if(is_collection_v2(self)) {return collection_v2(self).index};

        assert!(false);
        0
    }

    public fun creator(self: &Item): address {
        if(is_token_v1(self)) {return token_v1(self).creator};
        if(is_collection_v1(self)) {return collection_v1(self).creator};
        if(is_collection_v2(self)) {return collection_v2(self).creator};

        assert!(false);
        @0x0
    }
 
    public fun name(self: &Item): String {
        if(is_token_v1(self)) {return token_v1(self).name};
        if(is_collection_v1(self)) {return collection_v1(self).name};

        assert!(false);
        string::utf8(b"NULL")
    }


    public fun supply(self: &Item): u64 {
        if(is_collection_v1(self)) {return collection_v1(self).supply};
        if(is_collection_v2(self)) {return collection_v2(self).supply};
    
        assert!(false);
        0
    }

    // We use addr() instead of address() due to the fact that is a reserved word
    public fun addr(self: &Item): address {
        if(is_token_v2(self)) {return token_v2(self).address};
        if(is_collection_v2(self)) {return collection_v2(self).address};

        assert!(false);
        @0x0
    }

    public fun collection_address(self: &Item): address {
        if(is_token_v2(self)) {return token_v2(self).collection_address};

       assert!(false);
       @0x0
    }
    
    public fun collection_name(self: &Item): String {
        if(is_token_v1(self)) {return token_v1(self).collection_name};

        assert!(false);
        string::utf8(b"NULL")
    }

    public fun collection_index(self: &Item): u64 {
        if(is_token_v1(self)) {return token_v1(self).collection_index};
        if(is_token_v2(self)) {return token_v2(self).collection_index};

        assert!(false);
        0
    }

    public fun version(self: &Item): u64 {
        if(is_token_v1(self)) {return token_v1(self).version};

        assert!(false);
        0
    }

    public fun is_owner(self: &Item, user: address): bool {
        if(is_token_v1(self)){return tokenv1::balance_of(user, self.id()) == 1};
        if(is_token_v2(self)){
            let token = object::address_to_object<AptosToken>(token_v2(self).address);
            return object::is_owner(token, user)
        };

        assert!(false);
        false
    }

    // In normal cases "to" parameter should be an adress, but this way the code is cleaner
    // and since this will be used for tests only, you already have the signer anyway
    public fun transfer(self: &Item, from: &signer, to: &signer){
        if(is_token_v1(self)){
            tokenv1::direct_transfer(from,to,self.id(),1);
        };
        if(is_token_v2(self)){
            object::transfer(from, self.object(), signer::address_of(to))
        };

        assert!(false);
    }


    public fun tokens(self: &Item): vector<Item> acquires CollectionsV1,CollectionsV2{
        if(is_collection_v1(self)){ return CollectionsV1[@deployer].tokens[self.index()]};
        if(is_collection_v2(self)){ return CollectionsV2[@deployer].tokens[self.index()]};

        assert!(false);
        vector[]
    }

    public fun token_at(self: &Item, index: u64): Item acquires CollectionsV1,CollectionsV2{ 
        if(is_collection_v1(self)){
            let collections = &CollectionsV1[@deployer];
            let tokens = collections.tokens[self.index()];
            return tokens[index]
        };
        if(is_collection_v2(self)){
            let collections = &CollectionsV2[@deployer];
            let tokens = collections.tokens[self.index()];
            return tokens[index]
        };

        assert!(false);
        empty_item()
      
    }
    public fun get_collection_at(index:u64, type: u64): Item acquires CollectionsV1, CollectionsV2{
        if(type == 1){return CollectionsV1[@deployer].list[index]};
        if(type == 2){return CollectionsV2[@deployer].list[index]};

        assert!(false);
        empty_item()

    }
    
    // Returns a TokenId struct for v1 tokens
    public fun id(self: &Item): TokenId{        
        tokenv1::create_token_id_raw(self.creator(), self.collection_name(), self.name(), self.version())
    }

    // Returns the token object for v2 tokens
    public fun object(self: &Item): object::Object<aptos_token::AptosToken> {
        object::address_to_object<AptosToken>(token_v2(self).address)
    }


    public fun tokens_of(user: address):vector<Item> acquires CollectionsV1,CollectionsV2 {
        let res = vector<Item>[];

        // first process v1 collections
        let collections_1 = CollectionsV1[@deployer].tokens;
        let collections_amount_1 = collections_1.length();
        for(i in 0..collections_amount_1){
            // Get vector of tokens of the collection
            let tokens = collections_1[i];

            // Get amount of tokens in collection 
            let tokens_amount = tokens.length();

            for(j in 0..tokens_amount){
                // get token
                let token = tokens[j];
                // If user is the owner, append it to return array
                if(token.is_owner(user)){
                    res.push_back(token);
                };
            };
        };

        // process v2 collections aswell
        let collections_2 = CollectionsV2[@deployer].tokens;
        let collections_amount_2 = collections_2.length();
        for(i in 0..collections_amount_2){
            // Get vector of tokens of the collection
            let tokens = collections_2[i];

            // Get amount of tokens in collection 
            let tokens_amount = tokens.length();

            for(j in 0..tokens_amount){
                // get token
                let token = tokens[j];
                // If user is the owner, append it to return array
                if(token.is_owner(user)){
                    res.push_back(token);
                };
            };
        };

        res
    }

    
    public fun tokens_amount(user: address):u64 acquires CollectionsV1,CollectionsV2 {
        let tokens = tokens_of(user);
        tokens.length()
    }
    
}