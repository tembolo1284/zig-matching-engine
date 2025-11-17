const std = @import("std");
const OrderBook = @import("order_book.zig").OrderBook;
const message_types = @import("message_types.zig");
const InputMessage = message_types.InputMessage;
const OutputMessage = message_types.OutputMessage;
const NewOrderMsg = message_types.NewOrderMsg;
const CancelOrderMsg = message_types.CancelOrderMsg;
const Order = @import("order.zig").Order;

/// Multi-symbol order book orchestrator
/// 
/// Design decisions:
/// - One OrderBook per symbol (complete isolation)
/// - StringHashMap for O(1) symbol routing
/// - Tracks order → symbol mapping for cancellation
///   (cancel messages don't specify symbol, so we need to track it)
/// - Order books created on-demand when first order arrives
pub const MatchingEngine = struct {
    allocator: std.mem.Allocator,

    // Symbol → OrderBook mapping
    order_books: std.StringHashMap(*OrderBook),

    // Order key → Symbol mapping (for cancel operations)
    // Cancel messages only have user_id + user_order_id, not symbol
    order_to_symbol: std.AutoHashMap(u64, []const u8),

    pub fn init(allocator: std.mem.Allocator) MatchingEngine {
        return .{
            .allocator = allocator,
            .order_books = std.StringHashMap(*OrderBook).init(allocator),
            .order_to_symbol = std.AutoHashMap(u64, []const u8).init(allocator),
        };
    }

    pub fn deinit(self: *MatchingEngine) void {
        // Clean up all order books
        var it = self.order_books.valueIterator();
        while (it.next()) |book_ptr| {
            book_ptr.*.deinit();
        }

        // Clean up symbol strings stored in order_to_symbol
        var symbol_it = self.order_to_symbol.valueIterator();
        while (symbol_it.next()) |symbol_ptr| {
            self.allocator.free(symbol_ptr.*);
        }

        self.order_books.deinit();
        self.order_to_symbol.deinit();
    }

    /// Process input message and return output messages
    pub fn processMessage(
        self: *MatchingEngine,
        msg: InputMessage,
        outputs: *std.ArrayList(OutputMessage),
    ) !void {
        switch (msg) {
            .new_order => |order_msg| try self.processNewOrder(order_msg, outputs),
            .cancel_order => |cancel_msg| try self.processCancelOrder(cancel_msg, outputs),
            .flush => try self.processFlush(),
        }
    }

    /// Process new order message
    fn processNewOrder(
        self: *MatchingEngine,
        msg: NewOrderMsg,
        outputs: *std.ArrayList(OutputMessage),
    ) !void {
        // Get or create order book for this symbol
        const book = try self.getOrCreateOrderBook(msg.getSymbol());

        // Create order from message
        const order = try Order.init(
            msg.user_id,
            msg.user_order_id,
            msg.getSymbol(),
            msg.price,
            msg.quantity,
            msg.side,
        );

        // Track order location for future cancellation
        // We need to store a copy of the symbol string since msg may be temporary
        const key = Order.makeOrderKey(msg.user_id, msg.user_order_id);
        
        // Check if we already have this order tracked (shouldn't happen, but be safe)
        if (!self.order_to_symbol.contains(key)) {
            const symbol_copy = try self.allocator.dupe(u8, msg.getSymbol());
            try self.order_to_symbol.put(key, symbol_copy);
        }

        // Process the order through the order book
        try book.addOrder(order, outputs);
    }

    /// Process cancel order message
    fn processCancelOrder(
        self: *MatchingEngine,
        msg: CancelOrderMsg,
        outputs: *std.ArrayList(OutputMessage),
    ) !void {
        const key = Order.makeOrderKey(msg.user_id, msg.user_order_id);

        // Find which symbol this order belongs to
        if (self.order_to_symbol.get(key)) |symbol| {
            // Get the order book
            if (self.order_books.get(symbol)) |book| {
                // Cancel the order
                try book.cancelOrder(msg.user_id, msg.user_order_id, outputs);

                // Remove from tracking map
                const symbol_to_free = self.order_to_symbol.get(key).?;
                _ = self.order_to_symbol.remove(key);
                self.allocator.free(symbol_to_free);
            } else {
                // Order book doesn't exist - still send cancel ack
                try outputs.append(.{
                    .cancel_ack = .{
                        .user_id = msg.user_id,
                        .user_order_id = msg.user_order_id,
                    },
                });

                // Clean up tracking
                const symbol_to_free = self.order_to_symbol.get(key).?;
                _ = self.order_to_symbol.remove(key);
                self.allocator.free(symbol_to_free);
            }
        } else {
            // Order not found - still send cancel ack
            try outputs.append(.{
                .cancel_ack = .{
                    .user_id = msg.user_id,
                    .user_order_id = msg.user_order_id,
                },
            });
        }
    }

    /// Process flush - clear all order books
    fn processFlush(self: *MatchingEngine) !void {
        // Clean up all order books
        var it = self.order_books.valueIterator();
        while (it.next()) |book_ptr| {
            book_ptr.*.deinit();
        }

        // Clean up symbol strings
        var symbol_it = self.order_to_symbol.valueIterator();
        while (symbol_it.next()) |symbol_ptr| {
            self.allocator.free(symbol_ptr.*);
        }

        // Clear maps
        self.order_books.clearRetainingCapacity();
        self.order_to_symbol.clearRetainingCapacity();
    }

    /// Get or create order book for symbol
    fn getOrCreateOrderBook(self: *MatchingEngine, symbol: []const u8) !*OrderBook {
        if (self.order_books.get(symbol)) |book| {
            return book;
        }

        // Create new order book
        const book = try OrderBook.init(self.allocator, symbol);

        // Store with symbol key (need to duplicate symbol for HashMap storage)
        const symbol_copy = try self.allocator.dupe(u8, symbol);
        try self.order_books.put(symbol_copy, book);

        return book;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "MatchingEngine: create and destroy" {
    var engine = MatchingEngine.init(std.testing.allocator);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 0), engine.order_books.count());
}

test "MatchingEngine: process single order" {
    var engine = MatchingEngine.init(std.testing.allocator);
    defer engine.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    var new_order = NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 100,
        .quantity = 50,
        .side = .buy,
        .user_order_id = 1,
    };
    try new_order.setSymbol("IBM");

    const msg = InputMessage{ .new_order = new_order };
    try engine.processMessage(msg, &outputs);

    // Should have ACK + TOB
    try std.testing.expect(outputs.items.len >= 2);
    try std.testing.expect(outputs.items[0] == .ack);

    // Order book should be created
    try std.testing.expectEqual(@as(usize, 1), engine.order_books.count());
}

test "MatchingEngine: multiple symbols" {
    var engine = MatchingEngine.init(std.testing.allocator);
    defer engine.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add IBM order
    var ibm_order = NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 100,
        .quantity = 50,
        .side = .buy,
        .user_order_id = 1,
    };
    try ibm_order.setSymbol("IBM");
    try engine.processMessage(.{ .new_order = ibm_order }, &outputs);

    // Add AAPL order
    var aapl_order = NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 150,
        .quantity = 100,
        .side = .sell,
        .user_order_id = 2,
    };
    try aapl_order.setSymbol("AAPL");
    try engine.processMessage(.{ .new_order = aapl_order }, &outputs);

    // Should have 2 order books
    try std.testing.expectEqual(@as(usize, 2), engine.order_books.count());

    // Verify both exist
    try std.testing.expect(engine.order_books.contains("IBM"));
    try std.testing.expect(engine.order_books.contains("AAPL"));
}

test "MatchingEngine: cancel order" {
    var engine = MatchingEngine.init(std.testing.allocator);
    defer engine.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add order
    var new_order = NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 100,
        .quantity = 50,
        .side = .buy,
        .user_order_id = 1,
    };
    try new_order.setSymbol("IBM");
    try engine.processMessage(.{ .new_order = new_order }, &outputs);
    outputs.clearRetainingCapacity();

    // Cancel it
    const cancel_msg = InputMessage{
        .cancel_order = .{
            .user_id = 1,
            .user_order_id = 1,
        },
    };
    try engine.processMessage(cancel_msg, &outputs);

    // Should have cancel ack
    try std.testing.expect(outputs.items[0] == .cancel_ack);
    try std.testing.expectEqual(@as(u32, 1), outputs.items[0].cancel_ack.user_id);
    try std.testing.expectEqual(@as(u32, 1), outputs.items[0].cancel_ack.user_order_id);
}

test "MatchingEngine: cancel non-existent order" {
    var engine = MatchingEngine.init(std.testing.allocator);
    defer engine.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Cancel order that doesn't exist
    const cancel_msg = InputMessage{
        .cancel_order = .{
            .user_id = 999,
            .user_order_id = 999,
        },
    };
    try engine.processMessage(cancel_msg, &outputs);

    // Should still send cancel ack
    try std.testing.expect(outputs.items[0] == .cancel_ack);
}

test "MatchingEngine: flush all books" {
    var engine = MatchingEngine.init(std.testing.allocator);
    defer engine.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add orders to multiple symbols
    var ibm_order = NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 100,
        .quantity = 50,
        .side = .buy,
        .user_order_id = 1,
    };
    try ibm_order.setSymbol("IBM");
    try engine.processMessage(.{ .new_order = ibm_order }, &outputs);

    var aapl_order = NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 150,
        .quantity = 100,
        .side = .sell,
        .user_order_id = 2,
    };
    try aapl_order.setSymbol("AAPL");
    try engine.processMessage(.{ .new_order = aapl_order }, &outputs);

    try std.testing.expectEqual(@as(usize, 2), engine.order_books.count());

    // Flush
    try engine.processMessage(.{ .flush = .{} }, &outputs);

    // All books should be cleared
    try std.testing.expectEqual(@as(usize, 0), engine.order_books.count());
    try std.testing.expectEqual(@as(usize, 0), engine.order_to_symbol.count());
}

test "MatchingEngine: cross-symbol isolation" {
    var engine = MatchingEngine.init(std.testing.allocator);
    defer engine.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add IBM buy at 100
    var ibm_buy = NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 100,
        .quantity = 50,
        .side = .buy,
        .user_order_id = 1,
    };
    try ibm_buy.setSymbol("IBM");
    try engine.processMessage(.{ .new_order = ibm_buy }, &outputs);
    outputs.clearRetainingCapacity();

    // Add AAPL sell at 100 - should NOT match with IBM
    var aapl_sell = NewOrderMsg{
        .user_id = 2,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 100,
        .quantity = 50,
        .side = .sell,
        .user_order_id = 2,
    };
    try aapl_sell.setSymbol("AAPL");
    try engine.processMessage(.{ .new_order = aapl_sell }, &outputs);

    // Should have no trades (different symbols)
    var has_trade = false;
    for (outputs.items) |msg| {
        if (msg == .trade) has_trade = true;
    }
    try std.testing.expect(!has_trade);

    // Both order books should have orders
    const ibm_book = engine.order_books.get("IBM").?;
    const aapl_book = engine.order_books.get("AAPL").?;

    try std.testing.expect(ibm_book.getBestBidPrice() != 0);
    try std.testing.expect(aapl_book.getBestAskPrice() != 0);
}

test "MatchingEngine: order tracking for cancellation" {
    var engine = MatchingEngine.init(std.testing.allocator);
    defer engine.deinit();

    var outputs = std.ArrayList(OutputMessage).init(std.testing.allocator);
    defer outputs.deinit();

    // Add multiple orders to different symbols
    var ibm1 = NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 100,
        .quantity = 50,
        .side = .buy,
        .user_order_id = 1,
    };
    try ibm1.setSymbol("IBM");
    try engine.processMessage(.{ .new_order = ibm1 }, &outputs);

    var aapl1 = NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 150,
        .quantity = 100,
        .side = .sell,
        .user_order_id = 2,
    };
    try aapl1.setSymbol("AAPL");
    try engine.processMessage(.{ .new_order = aapl1 }, &outputs);

    // Should track 2 orders
    try std.testing.expectEqual(@as(usize, 2), engine.order_to_symbol.count());

    outputs.clearRetainingCapacity();

    // Cancel IBM order - should only affect IBM book
    try engine.processMessage(.{ .cancel_order = .{ .user_id = 1, .user_order_id = 1 } }, &outputs);

    // Should have cancel ack
    try std.testing.expect(outputs.items[0] == .cancel_ack);

    // IBM book should be empty, AAPL should still have order
    const ibm_book = engine.order_books.get("IBM").?;
    const aapl_book = engine.order_books.get("AAPL").?;

    try std.testing.expectEqual(@as(u32, 0), ibm_book.getBestBidPrice());
    try std.testing.expect(aapl_book.getBestAskPrice() != 0);

    // Should only track 1 order now
    try std.testing.expectEqual(@as(usize, 1), engine.order_to_symbol.count());
}
