/// Module of a Dutch Auction Sale `Market` type.
///
/// It implements a dutch auction sale configuration, where all NFTs in the sale
/// inventory get sold to the winners of the auction. The number of winners
///
/// NFT creators can decide if they want to create a simple primary market sale
/// or if they want to create a tiered market sale by segregating NFTs by
/// different sale segments (e.g. based on rarity).
///
/// To create a market sale the administrator can simply call `create_market`.
/// Each sale segment can have a whitelisting process, each with their own
/// whitelist tokens.
module nft_protocol::dutch_auction {
    // TODO(https://github.com/Origin-Byte/nft-protocol/issues/80): Market listing is toggled globally

    use std::vector;

    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::object::{Self, ID, UID};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};

    use originmate::crit_bit_u64::{Self as crit_bit, CB as CBTree};

    use nft_protocol::err;
    use nft_protocol::inventory::{Self, Inventory};
    use nft_protocol::listing::{Self, Listing, WhitelistCertificate};

    struct DutchAuctionMarket<phantom FT> has key, store {
        id: UID,
        /// The minimum price at which NFTs can be sold
        reserve_price: u64,
        /// A bid order stores amount of "T"okens the buyer is willing to
        /// purchase
        bids: CBTree<vector<Bid<FT>>>,
    }

    /// A bid for one NFT
    struct Bid<phantom FT> has store {
        /// Amount is equal to the price that the bidder is ready to pay for
        /// one NFT.
        amount: Balance<FT>,
        /// The address of the user who created this bid and who will receive
        /// an NFT in exchange for their tokens.
        owner: address,
    }

    /// Witness used to authenticate witness protected endpoints
    struct Witness has drop {}

    // === Init functions ===

    public fun new<FT>(
        reserve_price: u64,
        ctx: &mut TxContext,
    ): DutchAuctionMarket<FT> {
        DutchAuctionMarket {
            id: object::new(ctx),
            reserve_price,
            bids: crit_bit::empty(),
        }
    }

    /// Creates a `DutchAuctionMarket<FT>` and transfers to transaction sender
    public entry fun init_market<FT>(
        reserve_price: u64,
        ctx: &mut TxContext,
    ) {
        let market = new<FT>(reserve_price, ctx);
        transfer::transfer(market, tx_context::sender(ctx));
    }

    /// Creates a `DutchAuctionMarket<FT>` on `Inventory`
    public entry fun create_market_on_inventory<FT>(
        inventory: &mut Inventory,
        is_whitelisted: bool,
        reserve_price: u64,
        ctx: &mut TxContext,
    ) {
        let market = new<FT>(reserve_price, ctx);
        inventory::add_market(inventory, is_whitelisted, market);
    }

    /// Creates a `DutchAuctionMarket<FT>` on `Listing`
    public entry fun create_market_on_listing<FT>(
        listing: &mut Listing,
        inventory_id: ID,
        is_whitelisted: bool,
        reserve_price: u64,
        ctx: &mut TxContext,
    ) {
        let market = new<FT>(reserve_price, ctx);
        listing::add_market(listing, inventory_id, is_whitelisted, market, ctx);
    }

    // === Entrypoints ===

    /// Creates a bid in a FIFO manner, previous bids are retained
    public entry fun create_bid<FT>(
        wallet: &mut Coin<FT>,
        listing: &mut Listing,
        inventory_id: ID,
        market_id: ID,
        price: u64,
        quantity: u64,
        ctx: &mut TxContext,
    ) {
        let inventory =
            listing::inventory_internal_mut<DutchAuctionMarket<FT>, Witness>(
                Witness {}, listing, inventory_id, market_id
            );

        inventory::assert_is_live(inventory, &market_id);
        inventory::assert_is_not_whitelisted(inventory, &market_id);

        create_bid_(
            inventory::market_mut(inventory, market_id),
            wallet,
            price,
            quantity,
            tx_context::sender(ctx)
        );
    }

    public entry fun create_bid_whitelisted<FT>(
        wallet: &mut Coin<FT>,
        listing: &mut Listing,
        inventory_id: ID,
        market_id: ID,
        whitelist_token: WhitelistCertificate,
        price: u64,
        quantity: u64,
        ctx: &mut TxContext,
    ) {
        let inventory =
            listing::inventory_internal_mut<DutchAuctionMarket<FT>, Witness>(
                Witness {}, listing, inventory_id, market_id
            );

        inventory::assert_is_live(inventory, &market_id);
        inventory::assert_is_whitelisted(inventory, &market_id);

        listing::assert_whitelist_certificate_market(market_id, &whitelist_token);

        create_bid_(
            inventory::market_mut(inventory, market_id),
            wallet,
            price,
            quantity,
            tx_context::sender(ctx)
        );

        listing::burn_whitelist_certificate(whitelist_token);
    }

    /// Cancels a single bid at the given price level in a FIFO manner
    ///
    /// Bids can always be canceled no matter whether the auction is live.
    //
    // TODO(https://github.com/Origin-Byte/nft-protocol/issues/76):
    // Cancel all bids endpoint
    public entry fun cancel_bid<FT>(
        wallet: &mut Coin<FT>,
        listing: &mut Listing,
        inventory_id: ID,
        market_id: ID,
        price: u64,
        ctx: &mut TxContext,
    ) {
        let inventory =
            listing::inventory_internal_mut<DutchAuctionMarket<FT>, Witness>(
                Witness {}, listing, inventory_id, market_id
            );

        cancel_bid_(
            inventory::market_mut(inventory, market_id),
            wallet,
            price,
            tx_context::sender(ctx)
        )
    }

    // === Modifier Functions ===

    /// Cancel the auction and toggle the Slingshot's `live` to `false`.
    /// All bids will be cancelled and refunded.
    ///
    /// Permissioned endpoint to be called by `admin`.
    public entry fun sale_cancel<FT>(
        listing: &mut Listing,
        inventory_id: ID,
        market_id: ID,
        ctx: &mut TxContext,
    ) {
        // TODO: Consider an entrepoint to be called by the Marketplace instead of
        // the listing admin
        listing::assert_listing_admin(listing, ctx);

        let inventory =
            listing::inventory_internal_mut<DutchAuctionMarket<FT>, Witness>(
                Witness {}, listing, inventory_id, market_id
            );

        cancel_auction<FT>(
            inventory::market_mut(inventory, market_id),
            ctx,
        );

        inventory::set_live(inventory, market_id, false);
    }

    /// Conclude the auction and toggle the Slingshot's `live` to `false`.
    /// NFTs will be allocated to the winning biddeers.
    ///
    /// Permissioned endpoint to be called by `admin`.
    public entry fun sale_conclude<C, FT>(
        listing: &mut Listing,
        inventory_id: ID,
        market_id: ID,
        ctx: &mut TxContext,
    ) {
        // TODO: Consider an entrepoint to be called by the Marketplace instead of
        // the listing admin
        listing::assert_listing_admin(listing, ctx);

        let inventory =
            listing::inventory_internal_mut<DutchAuctionMarket<FT>, Witness>(
                Witness {}, listing, inventory_id, market_id
            );

        let nfts_to_sell = inventory::length(inventory);
        let (fill_price, bids_to_fill) = conclude_auction<FT>(
            inventory::market_mut(inventory, market_id),
            // TODO(https://github.com/Origin-Byte/nft-protocol/issues/63):
            // Investigate whether this logic should be paginated
            nfts_to_sell,
        );

        let total_funds = balance::zero<FT>();
        while (!vector::is_empty(&bids_to_fill)) {
            let Bid {amount, owner} = vector::pop_back(&mut bids_to_fill);

            let filled_funds =
                balance::split(&mut amount, (fill_price as u64));

            balance::join<FT>(&mut total_funds, filled_funds);

            let nft = inventory::redeem_nft<C>(inventory);
            transfer::transfer(nft, owner);

            if (balance::value(&amount) == 0) {
                balance::destroy_zero(amount);
            } else {
                // Transfer bidding coins back to bid owner
                transfer::transfer(coin::from_balance(amount, ctx), owner);
            };
        };

        listing::pay<FT>(listing, total_funds, nfts_to_sell);

        vector::destroy_empty(bids_to_fill);

        // Cancel all remaining orders if there are no NFTs left to sell
        if (inventory::is_empty(listing::inventory(listing, inventory_id))) {
            sale_cancel<FT>(listing, inventory_id, market_id, ctx);
        }
    }

    // === Getter Functions ===

    /// Get the auction's reserve price
    public fun reserve_price<FT>(market: &DutchAuctionMarket<FT>): u64 {
        market.reserve_price
    }

    /// Get the auction's bids
    public fun bids<FT>(market: &DutchAuctionMarket<FT>): &CBTree<vector<Bid<FT>>> {
        &market.bids
    }

    public fun bid_owner<FT>(bid: &Bid<FT>): address {
        bid.owner
    }

    public fun bid_amount<FT>(bid: &Bid<FT>): &Balance<FT> {
        &bid.amount
    }

    // === Private Functions ===

    fun create_bid_<FT>(
        auction: &mut DutchAuctionMarket<FT>,
        wallet: &mut Coin<FT>,
        price: u64,
        quantity: u64,
        bidder: address,
    ) {
        assert!(
            price >= auction.reserve_price,
            err::order_price_below_reserve()
        );

        // Create price level if it does not exist
        if (!crit_bit::has_key(&auction.bids, price)) {
            crit_bit::insert(
                &mut auction.bids,
                price,
                vector::empty()
            );
        };

        let price_level =
            crit_bit::borrow_mut(&mut auction.bids, price);

        // Make `quantity` number of bids
        let index = 0;
        while (quantity > index) {
            let amount = balance::split(coin::balance_mut(wallet), price);
            vector::push_back(price_level, Bid { amount, owner: bidder });
            index = index + 1;
        }
    }

    /// Cancels a single order in a FIFO manner
    fun cancel_bid_<FT>(
        auction: &mut DutchAuctionMarket<FT>,
        wallet: &mut Coin<FT>,
        price: u64,
        sender: address,
    ) {
        let bids = &mut auction.bids;

        assert!(
            crit_bit::has_key(bids, price),
            err::order_does_not_exist()
        );

        let price_level = crit_bit::borrow_mut(bids, price);

        let bid_index = 0;
        let bid_count = vector::length(price_level);
        while (bid_count > bid_index) {
            let bid = vector::borrow(price_level, bid_index);
            if (bid.owner == sender) {
                break
            };

            bid_index = bid_index + 1;
        };

        assert!(bid_index < bid_count, err::order_owner_must_be_sender());

        let bid = vector::remove(price_level, bid_index);
        refund_bid(bid, wallet, &sender);

        if (vector::is_empty(price_level)) {
            let price_level = crit_bit::pop(bids, price);
            vector::destroy_empty(price_level);
        }
    }

    // Cancels all bids present on the auction book
    fun cancel_auction<FT>(
        book: &mut DutchAuctionMarket<FT>,
        ctx: &mut TxContext,
    ) {
        let bids = &mut book.bids;

        while (!crit_bit::is_empty(bids)) {
            let min_key = crit_bit::min_key(bids);
            let price_level = crit_bit::pop(bids, min_key);
            while (!vector::is_empty(&price_level)) {
                let bid = vector::pop_back(&mut price_level);

                // Since we do not have access to the original wallet
                // we must create a wallet wherein the bidder can be refunded.
                let wallet = coin::zero(ctx);
                let owner = bid.owner;
                refund_bid(bid, &mut wallet, &owner);

                transfer::transfer(wallet, owner);
            };

            vector::destroy_empty(price_level);
        }
    }

    fun refund_bid<FT>(
        bid: Bid<FT>,
        wallet: &mut Coin<FT>,
        sender: &address,
    ) {
        let Bid { amount, owner } = bid;
        assert!(sender == &owner, err::order_owner_must_be_sender());

        balance::join(coin::balance_mut(wallet), amount);
    }

    /// Returns the fill_price and bids that must be filled
    fun conclude_auction<FT>(
        auction: &mut DutchAuctionMarket<FT>,
        // Use to specify how many NFTs will be transfered to the winning bids
        // during the `conclude_auction`. This functionality is used to avoid
        // hitting computational costs during large auction sales.
        //
        // To conclude the entire auction, the total number of NFTs in the sale
        // should be passed.
        nfts_to_sell: u64,
    ): (u64, vector<Bid<FT>>) {
        let bids = &mut auction.bids;

        let fill_price = 0;
        let bids_to_fill = vector::empty();
        while (nfts_to_sell > 0 && !crit_bit::is_empty(bids)) {
            // Get key of maximum price level representing the price level from
            // which the next winning bid is extracted.
            let max_key = crit_bit::max_key(bids);
            let price_level = crit_bit::borrow_mut(bids, max_key);

            if (vector::is_empty(price_level)) {
                let price_level = crit_bit::pop(bids, max_key);
                vector::destroy_empty(price_level);
                continue
            };

            // There exists a bid we can match to an NFT
            // Match in FIFO order
            let bid = vector::remove(price_level, 0);

            fill_price = max_key;
            nfts_to_sell = nfts_to_sell - 1;
            vector::push_back(&mut bids_to_fill, bid);
        };

        (fill_price, bids_to_fill)
    }
}
