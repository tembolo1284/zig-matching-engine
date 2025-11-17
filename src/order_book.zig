const std = @import("std");
const Order = @import("order.zig").Order;
const message_types = @import("message_types.zig");
const Side = message_types.Side;
const OrderType = message_types.OrderType;
const OutputMessage = message_types.OutputMessage;
const AckMsg = message_types.AckMsg;
const TradeMsg = message_types.TradeMsg;
const TopOfBookMsg = message_types.TopOfBookMsg;
const TopOfBook = message_types.TopOfBook;
const CancelAckMsg = message_types.CancelAckMsg;

/// Price level containing all orders at a specific price
/// Uses doubly-linked list (TailQueue) for FIFO time priority
const PriceLevel = struct {
    price: u32,
    orders: std.TailQueue(Order),
    total_quantity: u32,

    fn init(price: u32) PriceLevel {
        return .{
            .price = price,
            .orders = .{},
            .total_quantity = 0,
        };
    }

    fn deinit(self: *PriceLevel, allocator: std.mem.Allocator) void {
        // Free all order nodes in the queue
        while (self.orders.pop()) |node| {
            allocator.destroy(node);
        }
    }
};

/// Location of an order in the book (for O(1) cancellation)
const OrderLocation = struct {
    price: u32,
    side: Side,
    node: *std.TailQueue(Order).Node,
};

/// Single-symbol order book with price-time priority matching
/// 
/// Design decisions:
/// - ArrayList for price levels (sorted array) instead of std::map (tree)
///   * Better cache locality: O(log N) binary search on ~100-150 price levels
///   * Simpler memory layout: contiguous array vs tree nodes
///   * Trade-off: O(N) insert vs O(log N), but N is small (typically < 150)
/// 
/// - TailQueue for orders at each price (doubly-linked list)
///   * FIFO time priority: O(1) append to tail
///   * O(1) removal with iterator (for cancellation)
///   * Matches C++ std::list semantics exactly
/// 
/// - AutoHashMap for order lookup
///   * O(1) average case lookup for cancellation
///   * Stores pointer to node for direct removal
pub const OrderBook = struct {
    allocator: std.mem.Allocator,
    symbol: [16]u8,
    symbol_len: u8,

    // Price levels: sorted arrays for cache efficiency
    // Bids: sorted DESCENDING (best = highest price = index 0)
    // Asks: sorted ASCENDING (best = lowest price = index 0)
    bids: std.ArrayList(PriceLevel),
    asks: std.ArrayList(PriceLevel),

    // Fast O(1) lookup for cancellations
    order_map: std.AutoHashMap(u64, OrderLocation),

    // Track top of book for change detection
    prev_best_bid_price: u32,
    prev_best_bid_qty: u32,
    prev_best_ask_price: u32,
    prev_best_ask_qty: u32,

    /// Initialize order book for a symbol
    pub fn init(allocator: std.mem.Allocator, symbol: []const u8) !*OrderBook {
        if (symbol.len > 16) return error.SymbolTooLong;

        const book = try allocator.create(OrderBook);
        book.* = .{
            .allocator = allocator,
            .symbol = undefined,
            .symbol_len = @intCast(symbol.len),
            .bids = std.ArrayList(PriceLevel).init(allocator),
            .asks = std.ArrayList(PriceLevel).init(allocator),
            .order_map = std.AutoHashMap(u64, OrderLocation).init(allocator),
            .prev_best_bid_price = 0,
            .prev_best_bid_qty = 0,
            .prev_best_ask_price = 0,
            .prev_best_ask_qty = 0,
        };

        @memcpy(book.symbol[0..symbol.len], symbol);
        return book;
    }

    /// Clean up all resources
    pub fn deinit(self: *OrderBook) void {
        // Clean up all price levels
        for (self.bids.items) |*level| {
            level.deinit(self.allocator);
        }
        for (self.asks.items) |*level| {
            level.deinit(self.allocator);
        }

        self.bids.deinit();
        self.asks.deinit();
        self.order_map.deinit();
        self.allocator.destroy(self);
    }

    pub fn getSymbol(self: *const OrderBook) []const u8 {
        return self.symbol[0..self.symbol_len];
    }

    /// Add new order and generate output messages
    pub fn addOrder(
        self: *OrderBook,
        order: Order,
        outputs: *std.ArrayList(OutputMessage),
    ) !void {
        var working_order = order;

        // Send acknowledgement FIRST (before matching)
        try outputs.append(.{
            .ack = AckMsg{
                .user_id = order.user_id,
                .user_order_id = order.user_order_id,
            },
        });

        // Try to match against existing orders
        try self.matchOrder(&working_order, outputs);

        // If there's remaining quantity and it's a limit order, add to book
        if (working_order.remaining_qty > 0 and working_order.order_type == .limit) {
            try self.addToBook(working_order);
        }

        // Check for top-of-book changes
        try self.checkTopOfBookChanges(outputs);
    }

    /// Cancel order and generate output messages
    pub fn cancelOrder(
        self: *OrderBook,
        user_id: u32,
        user_order_id: u32,
        outputs: *std.ArrayList(OutputMessage),
    ) !void {
        const key = Order.makeOrderKey(user_id, user_order_id);

        if (self.order_map.get(key)) |loc| {
            // Remove order from the book
            const levels = if (loc.side == .buy) &self.bids else &self.asks;

            // Find the price level
            if (self.findPriceLevelIndex(levels.items, loc.price, loc.side)) |idx| {
                const level = &levels.items[idx];

                // Update total quantity
                level.total_quantity -= loc.node.data.remaining_qty;

                // Remove order from list
                level.orders.remove(loc.node);
                self.allocator.destroy(loc.node);

                // Remove empty price level
                if (level.total_quantity == 0) {
                    level.deinit(self.allocator);
                    _ = levels.orderedRemove(idx);
                }
            }

            // Remove from order map
            _ = self.order_map.remove(key);
        }

        // Send cancel acknowledgement (even if order not found)
        try outputs.append(.{
            .cancel_ack = CancelAckMsg{
                .user_id = user_id,
                .user_order_id = user_order_id,
            },
        });

        // Check for top-of-book changes
        try self.checkTopOfBookChanges(outputs);
    }

    /// Flush/clear the entire order book
    pub fn flush(self: *OrderBook) void {
        // Clean up all price levels
        for (self.bids.items) |*level| {
            level.deinit(self.allocator);
        }
        for (self.asks.items) |*level| {
            level.deinit(self.allocator);
        }

        self.bids.clearRetainingCapacity();
        self.asks.clearRetainingCapacity();
        self.order_map.clearRetainingCapacity();

        self.prev_best_bid_price = 0;
        self.prev_best_bid_qty = 0;
        self.prev_best_ask_price = 0;
        self.prev_best_ask_qty = 0;
    }

    /// Get best bid price (0 if none)
    pub fn getBestBidPrice(self: *const OrderBook) u32 {
        return if (self.bids.items.len > 0) self.bids.items[0].price else 0;
    }

    /// Get best ask price (0 if none)
    pub fn getBestAskPrice(self: *const OrderBook) u32 {
        return if (self.asks.items.len > 0) self.asks.items[0].price else 0;
    }

    /// Get total quantity at best bid
    pub fn getBestBidQuantity(self: *const OrderBook) u32 {
        return if (self.bids.items.len > 0) self.bids.items[0].total_quantity else 0;
    }

    /// Get total quantity at best ask
    pub fn getBestAskQuantity(self: *const OrderBook) u32 {
        return if (self.asks.items.len > 0) self.asks.items[0].total_quantity else 0;
    }

    // ========================================================================
    // Private Helper Methods
    // ========================================================================

    /// Match an incoming order against the book
    fn matchOrder(
        self: *OrderBook,
        order: *Order,
        outputs: *std.ArrayList(OutputMessage),
    ) !void {
        // Get opposite side for matching
        const levels = if (order.side == .buy) &self.asks else &self.bids;

        while (order.remaining_qty > 0 and levels.items.len > 0) {
            const level = &levels.items[0];

            // Check if prices cross (can we match?)
            const can_match = switch (order.order_type) {
                .market => true,
                .limit => if (order.side == .buy)
                    order.price >= level.price
                else
                    order.price <= level.price,
            };

            if (!can_match) break;

            // Match against orders at this price level (FIFO - time priority)
            var it = level.orders.first;
            while (it) |node| {
                const next = node.next; // Save next before potential removal

                if (order.remaining_qty == 0) break;

                const book_order = &node.data;
                const match_qty = @min(order.remaining_qty, book_order.remaining_qty);

                // Generate trade (aggressive order vs passive order)
                const trade = if (order.side == .buy) TradeMsg{
                    .user_id_buy = order.user_id,
                    .user_order_id_buy = order.user_order_id,
                    .user_id_sell = book_order.user_id,
                    .user_order_id_sell = book_order.user_order_id,
                    .price = level.price, // Trade at passive order price
                    .quantity = match_qty,
                } else TradeMsg{
                    .user_id_buy = book_order.user_id,
                    .user_order_id_buy = book_order.user_order_id,
                    .user_id_sell = order.user_id,
                    .user_order_id_sell = order.user_order_id,
                    .price = level.price, // Trade at passive order price
                    .quantity = match_qty,
                };

                try outputs.append(.{ .trade = trade });

                // Update quantities
                _ = order.fill(match_qty);
                _ = book_order.fill(match_qty);
                level.total_quantity -= match_qty;

                // Remove fully filled order
                if (book_order.isFilled()) {
                    _ = self.order_map.remove(book_order.key());
                    level.orders.remove(node);
                    self.allocator.destroy(node);
                }

                it = next;
            }

            // Remove empty price level
            if (level.total_quantity == 0) {
                level.deinit(self.allocator);
                _ = levels.orderedRemove(0);
            }
        }
    }

    /// Add limit order to the book
    fn addToBook(self: *OrderBook, order: Order) !void {
        const levels = if (order.side == .buy) &self.bids else &self.asks;

        // Find or create price level
        if (self.findPriceLevelIndex(levels.items, order.price, order.side)) |idx| {
            // Price level exists, add order to end (time priority)
            const level = &levels.items[idx];
            const node = try self.allocator.create(std.TailQueue(Order).Node);
            node.* = .{ .data = order };
            level.orders.append(node);
            level.total_quantity += order.remaining_qty;

            // Add to order map for cancellation
            try self.order_map.put(order.key(), .{
                .price = order.price,
                .side = order.side,
                .node = node,
            });
        } else {
            // Create new price level
            var new_level = PriceLevel.init(order.price);
            const node = try self.allocator.create(std.TailQueue(Order).Node);
            node.* = .{ .data = order };
            new_level.orders.append(node);
            new_level.total_quantity = order.remaining_qty;

            // Insert at sorted position
            const insert_idx = self.findInsertPosition(levels.items, order.price, order.side);
            try levels.insert(insert_idx, new_level);

            // Add to order map for cancellation
            try self.order_map.put(order.key(), .{
                .price = order.price,
                .side = order.side,
                .node = node,
            });
        }
    }

    /// Check for top-of-book changes and generate messages
    fn checkTopOfBookChanges(self: *OrderBook, outputs: *std.ArrayList(OutputMessage)) !void {
        const current_best_bid_price = self.getBestBidPrice();
        const current_best_bid_qty = self.getBestBidQuantity();
        const current_best_ask_price = self.getBestAskPrice();
        const current_best_ask_qty = self.getBestAskQuantity();

        // Check bid side changes
        if (current_best_bid_price != self.prev_best_bid_price or
            current_best_bid_qty != self.prev_best_bid_qty)
        {
            if (current_best_bid_price == 0) {
                // Bid side eliminated
                try outputs.append(.{
                    .top_of_book = TopOfBookMsg{
                        .side = .buy,
                        .tob = TopOfBook{
                            .price = 0,
                            .total_quantity = 0,
                            .eliminated = true,
                        },
                    },
                });
            } else {
                try outputs.append(.{
                    .top_of_book = TopOfBookMsg{
                        .side = .buy,
                        .tob = TopOfBook{
                            .price = current_best_bid_price,
                            .total_quantity = current_best_bid_qty,
                            .eliminated = false,
                        },
                    },
                });
            }

            self.prev_best_bid_price = current_best_bid_price;
            self.prev_best_bid_qty = current_best_bid_qty;
        }

        // Check ask side changes
        if (current_best_ask_price != self.prev_best_ask_price or
            current_best_ask_qty != self.prev_best_ask_qty)
        {
            if (current_best_ask_price == 0) {
                // Ask side eliminated
                try outputs.append(.{
                    .top_of_book = TopOfBookMsg{
                        .side = .sell,
                        .tob = TopOfBook{
                            .price = 0,
                            .total_quantity = 0,
                            .eliminated = true,
                        },
                    },
                });
            } else {
                try outputs.append(.{
                    .top_of_book = TopOfBookMsg{
                        .side = .sell,
                        .tob = TopOfBook{
                            .price = current_best_ask_price,
                            .total_quantity = current_best_ask_qty,
                            .eliminated = false,
                        },
                    },
                });
            }

            self.prev_best_ask_price = current_best_ask_price;
            self.prev_best_ask_qty = current_best_ask_qty;
        }
    }

    /// Find index of price level (binary search)
    /// Returns null if not found
    fn findPriceLevelIndex(self: *const OrderBook, levels: []const PriceLevel, price: u32, side: Side) ?usize {
        _ = self;
        if (levels.len == 0) return null;

        var left: usize = 0;
        var right: usize = levels.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const mid_price = levels[mid].price;

            if (mid_price == price) {
                return mid;
            }

            // Bids: descending (highest first)
            // Asks: ascending (lowest first)
            if (side == .buy) {
                if (mid_price > price) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            } else {
                if (mid_price < price) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
        }

        return null;
    }

    /// Find insertion position for new price level (binary search)
    /// Returns index where new level should be inserted
    fn findInsertPosition(self: *const OrderBook, levels: []const PriceLevel, price: u32, side: Side) usize {
        _ = self;
        if (levels.len == 0) return 0;

        var left: usize = 0;
        var right: usize = levels.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            const mid_price = levels[mid].price;

            // Bids: descending (highest first)
            // Asks: ascending (lowest first)
            if (side == .buy) {
                if (mid_price > price) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            } else {
                if (mid_price < price) {
                    left = mid + 1;
                } else {
                    right = mid;
                }
            }
        }

        return left;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OrderBook: create and destroy" {
    const book = try OrderBook.init(std.testing.allocator, "IBM");
    defer book.deinit();

    try std.testing.expectEqualStrings("IBM", book.getSymbol());
    try std.testing.expectEqual(@as(u32, 0), book.getBestBidPrice());
    try std.testing.expectEqual(@as(u32, 0), book.getBestAskPrice());
}

test "OrderBook: add single buy limit order" {
    const book = try OrderBook.init(std.testing.allocator, "IBM");
    defer book.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    const order = try Order.init(1, 1, "IBM", 100, 50, .buy);
    try book.addOrder(order, &outputs);

    // Should have: ACK + TOB update
    try std.testing.expectEqual(@as(usize, 2), outputs.items.len);
    try std.testing.expect(outputs.items[0] == .ack);
    try std.testing.expect(outputs.items[1] == .top_of_book);

    try std.testing.expectEqual(@as(u32, 100), book.getBestBidPrice());
    try std.testing.expectEqual(@as(u32, 50), book.getBestBidQuantity());
}

test "OrderBook: add single sell limit order" {
    const book = try OrderBook.init(std.testing.allocator, "IBM");
    defer book.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    const order = try Order.init(1, 1, "IBM", 100, 50, .sell);
    try book.addOrder(order, &outputs);

    try std.testing.expectEqual(@as(u32, 100), book.getBestAskPrice());
    try std.testing.expectEqual(@as(u32, 50), book.getBestAskQuantity());
}

test "OrderBook: match buy against sell - full fill" {
    const book = try OrderBook.init(std.testing.allocator, "IBM");
    defer book.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add sell order at 100
    const sell_order = try Order.init(1, 1, "IBM", 100, 50, .sell);
    try book.addOrder(sell_order, &outputs);
    outputs.clearRetainingCapacity();

    // Add buy order at 100 - should match
    const buy_order = try Order.init(2, 2, "IBM", 100, 50, .buy);
    try book.addOrder(buy_order, &outputs);

    // Should have: ACK + TRADE + TOB eliminated (both sides)
    var has_trade = false;
    for (outputs.items) |msg| {
        if (msg == .trade) has_trade = true;
    }
    try std.testing.expect(has_trade);

    // Both sides should be eliminated
    try std.testing.expectEqual(@as(u32, 0), book.getBestBidPrice());
    try std.testing.expectEqual(@as(u32, 0), book.getBestAskPrice());
}

test "OrderBook: match buy against sell - partial fill" {
    const book = try OrderBook.init(std.testing.allocator, "IBM");
    defer book.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add sell order at 100 (50 qty)
    const sell_order = try Order.init(1, 1, "IBM", 100, 50, .sell);
    try book.addOrder(sell_order, &outputs);
    outputs.clearRetainingCapacity();

    // Add buy order at 100 (30 qty) - partial match
    const buy_order = try Order.init(2, 2, "IBM", 100, 30, .buy);
    try book.addOrder(buy_order, &outputs);

    // Should have trade for 30
    var trade_qty: u32 = 0;
    for (outputs.items) |msg| {
        if (msg == .trade) {
            trade_qty = msg.trade.quantity;
        }
    }
    try std.testing.expectEqual(@as(u32, 30), trade_qty);

    // Sell side should have 20 remaining
    try std.testing.expectEqual(@as(u32, 100), book.getBestAskPrice());
    try std.testing.expectEqual(@as(u32, 20), book.getBestAskQuantity());
}

test "OrderBook: market order matches any price" {
    const book = try OrderBook.init(std.testing.allocator, "IBM");
    defer book.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add sell order at 100
    const sell_order = try Order.init(1, 1, "IBM", 100, 50, .sell);
    try book.addOrder(sell_order, &outputs);
    outputs.clearRetainingCapacity();

    // Market buy order (price=0) - should match
    const market_order = try Order.init(2, 2, "IBM", 0, 50, .buy);
    try book.addOrder(market_order, &outputs);

    // Should have trade
    var has_trade = false;
    for (outputs.items) |msg| {
        if (msg == .trade) {
            has_trade = true;
            // Trade should happen at passive order price (100)
            try std.testing.expectEqual(@as(u32, 100), msg.trade.price);
        }
    }
    try std.testing.expect(has_trade);
}

test "OrderBook: price-time priority" {
    const book = try OrderBook.init(std.testing.allocator, "IBM");
    defer book.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add three sell orders at same price (time priority matters)
    const sell1 = try Order.init(1, 1, "IBM", 100, 10, .sell);
    try book.addOrder(sell1, &outputs);
    std.time.sleep(1000); // Ensure different timestamps

    const sell2 = try Order.init(1, 2, "IBM", 100, 20, .sell);
    try book.addOrder(sell2, &outputs);
    std.time.sleep(1000);

    const sell3 = try Order.init(1, 3, "IBM", 100, 30, .sell);
    try book.addOrder(sell3, &outputs);
    outputs.clearRetainingCapacity();

    // Market buy for 25 - should match sell1 (10) + part of sell2 (15)
    const buy_order = try Order.init(2, 10, "IBM", 0, 25, .buy);
    try book.addOrder(buy_order, &outputs);

    // Should have 2 trades
    var trade_count: usize = 0;
    for (outputs.items) |msg| {
        if (msg == .trade) {
            trade_count += 1;
            if (trade_count == 1) {
                // First trade: user_order_id = 1 (sell1)
                try std.testing.expectEqual(@as(u32, 1), msg.trade.user_order_id_sell);
                try std.testing.expectEqual(@as(u32, 10), msg.trade.quantity);
            } else if (trade_count == 2) {
                // Second trade: user_order_id = 2 (sell2)
                try std.testing.expectEqual(@as(u32, 2), msg.trade.user_order_id_sell);
                try std.testing.expectEqual(@as(u32, 15), msg.trade.quantity);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), trade_count);

    // Remaining: 5 from sell2, 30 from sell3
    try std.testing.expectEqual(@as(u32, 35), book.getBestAskQuantity());
}

test "OrderBook: cancel order" {
    const book = try OrderBook.init(std.testing.allocator, "IBM");
    defer book.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add order
    const order = try Order.init(1, 1, "IBM", 100, 50, .buy);
    try book.addOrder(order, &outputs);
    outputs.clearRetainingCapacity();

    // Cancel it
    try book.cancelOrder(1, 1, &outputs);

    // Should have cancel ack + TOB eliminated
    try std.testing.expect(outputs.items[0] == .cancel_ack);
    try std.testing.expectEqual(@as(u32, 0), book.getBestBidPrice());
}

test "OrderBook: cancel non-existent order" {
    const book = try OrderBook.init(std.testing.allocator, "IBM");
    defer book.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Cancel order that doesn't exist
    try book.cancelOrder(999, 999, &outputs);

    // Should still send cancel ack
    try std.testing.expect(outputs.items[0] == .cancel_ack);
}

test "OrderBook: flush" {
    const book = try OrderBook.init(std.testing.allocator, "IBM");
    defer book.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add multiple orders
    const buy1 = try Order.init(1, 1, "IBM", 100, 50, .buy);
    try book.addOrder(buy1, &outputs);

    const sell1 = try Order.init(2, 2, "IBM", 110, 50, .sell);
    try book.addOrder(sell1, &outputs);

    try std.testing.expect(book.getBestBidPrice() != 0);
    try std.testing.expect(book.getBestAskPrice() != 0);

    // Flush
    book.flush();

    // Everything should be cleared
    try std.testing.expectEqual(@as(u32, 0), book.getBestBidPrice());
    try std.testing.expectEqual(@as(u32, 0), book.getBestAskPrice());
}

test "OrderBook: multiple price levels" {
    const book = try OrderBook.init(std.testing.allocator, "IBM");
    defer book.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add orders at different prices
    const buy1 = try Order.init(1, 1, "IBM", 100, 10, .buy);
    try book.addOrder(buy1, &outputs);

    const buy2 = try Order.init(1, 2, "IBM", 99, 20, .buy);
    try book.addOrder(buy2, &outputs);

    const buy3 = try Order.init(1, 3, "IBM", 101, 30, .buy);
    try book.addOrder(buy3, &outputs);

    // Best bid should be 101 (highest)
    try std.testing.expectEqual(@as(u32, 101), book.getBestBidPrice());
    try std.testing.expectEqual(@as(u32, 30), book.getBestBidQuantity());

    // Should have 3 price levels
    try std.testing.expectEqual(@as(usize, 3), book.bids.items.len);

    // Verify sorted order: 101, 100, 99 (descending)
    try std.testing.expectEqual(@as(u32, 101), book.bids.items[0].price);
    try std.testing.expectEqual(@as(u32, 100), book.bids.items[1].price);
    try std.testing.expectEqual(@as(u32, 99), book.bids.items[2].price);
}
