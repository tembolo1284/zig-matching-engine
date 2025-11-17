const std = @import("std");
const message_types = @import("message_types.zig");
const Side = message_types.Side;
const OrderType = message_types.OrderType;

/// Represents a single order in the system
/// 
/// Design decisions:
/// - Fixed-size symbol buffer (16 bytes) for cache locality
/// - Nanosecond timestamp for precise time priority
/// - Tracks remaining_qty separately for partial fills
/// - Compact memory layout (~72 bytes per order)
pub const Order = struct {
    user_id: u32,
    user_order_id: u32,
    symbol: [16]u8,
    symbol_len: u8,
    price: u32,
    quantity: u32,
    remaining_qty: u32,
    side: Side,
    order_type: OrderType,
    timestamp: i128, // Nanosecond precision (std.time.nanoTimestamp)

    /// Initialize order from message
    pub fn init(
        user_id: u32,
        user_order_id: u32,
        symbol: []const u8,
        price: u32,
        quantity: u32,
        side: Side,
    ) !Order {
        if (symbol.len > 16) return error.SymbolTooLong;
        if (quantity == 0) return error.ZeroQuantity;

        var order = Order{
            .user_id = user_id,
            .user_order_id = user_order_id,
            .symbol = undefined,
            .symbol_len = @intCast(symbol.len),
            .price = price,
            .quantity = quantity,
            .remaining_qty = quantity,
            .side = side,
            .order_type = OrderType.fromPrice(price),
            .timestamp = std.time.nanoTimestamp(),
        };

        @memcpy(order.symbol[0..symbol.len], symbol);
        return order;
    }

    /// Get symbol as slice
    pub fn getSymbol(self: *const Order) []const u8 {
        return self.symbol[0..self.symbol_len];
    }

    /// Check if order is fully filled
    pub fn isFilled(self: *const Order) bool {
        return self.remaining_qty == 0;
    }

    /// Fill order by quantity, returns amount actually filled
    pub fn fill(self: *Order, qty: u32) u32 {
        const filled = @min(qty, self.remaining_qty);
        self.remaining_qty -= filled;
        return filled;
    }

    /// Get unique key for order lookup (for cancellation)
    /// Combines user_id and user_order_id into a single u64
    /// Format: [user_id: 32 bits][user_order_id: 32 bits]
    pub fn key(self: *const Order) u64 {
        return makeOrderKey(self.user_id, self.user_order_id);
    }

    /// Static method to create order key without Order instance
    pub fn makeOrderKey(user_id: u32, user_order_id: u32) u64 {
        return (@as(u64, user_id) << 32) | user_order_id;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Order: create limit order" {
    const order = try Order.init(1, 5, "IBM", 100, 50, .buy);

    try std.testing.expectEqual(@as(u32, 1), order.user_id);
    try std.testing.expectEqual(@as(u32, 5), order.user_order_id);
    try std.testing.expectEqualStrings("IBM", order.getSymbol());
    try std.testing.expectEqual(@as(u32, 100), order.price);
    try std.testing.expectEqual(@as(u32, 50), order.quantity);
    try std.testing.expectEqual(@as(u32, 50), order.remaining_qty);
    try std.testing.expectEqual(Side.buy, order.side);
    try std.testing.expectEqual(OrderType.limit, order.order_type);
}

test "Order: create market order" {
    const order = try Order.init(2, 10, "AAPL", 0, 100, .sell);

    try std.testing.expectEqual(@as(u32, 0), order.price);
    try std.testing.expectEqual(OrderType.market, order.order_type);
}

test "Order: symbol too long" {
    const result = Order.init(1, 1, "VERYLONGSYMBOLNAME", 100, 50, .buy);
    try std.testing.expectError(error.SymbolTooLong, result);
}

test "Order: zero quantity" {
    const result = Order.init(1, 1, "IBM", 100, 0, .buy);
    try std.testing.expectError(error.ZeroQuantity, result);
}

test "Order: fill partial" {
    var order = try Order.init(1, 5, "IBM", 100, 50, .buy);

    const filled = order.fill(20);
    try std.testing.expectEqual(@as(u32, 20), filled);
    try std.testing.expectEqual(@as(u32, 30), order.remaining_qty);
    try std.testing.expect(!order.isFilled());
}

test "Order: fill complete" {
    var order = try Order.init(1, 5, "IBM", 100, 50, .buy);

    const filled = order.fill(50);
    try std.testing.expectEqual(@as(u32, 50), filled);
    try std.testing.expectEqual(@as(u32, 0), order.remaining_qty);
    try std.testing.expect(order.isFilled());
}

test "Order: fill more than remaining" {
    var order = try Order.init(1, 5, "IBM", 100, 50, .buy);

    // Try to fill 100, but only 50 available
    const filled = order.fill(100);
    try std.testing.expectEqual(@as(u32, 50), filled);
    try std.testing.expectEqual(@as(u32, 0), order.remaining_qty);
    try std.testing.expect(order.isFilled());
}

test "Order: fill multiple times" {
    var order = try Order.init(1, 5, "IBM", 100, 100, .buy);

    _ = order.fill(30);
    try std.testing.expectEqual(@as(u32, 70), order.remaining_qty);

    _ = order.fill(40);
    try std.testing.expectEqual(@as(u32, 30), order.remaining_qty);

    _ = order.fill(30);
    try std.testing.expectEqual(@as(u32, 0), order.remaining_qty);
    try std.testing.expect(order.isFilled());
}

test "Order: order key generation" {
    const order = try Order.init(1, 5, "IBM", 100, 50, .buy);

    const key1 = order.key();
    const key2 = Order.makeOrderKey(1, 5);

    try std.testing.expectEqual(key1, key2);
    try std.testing.expectEqual(@as(u64, (1 << 32) | 5), key1);
}

test "Order: unique keys for different orders" {
    const order1 = try Order.init(1, 5, "IBM", 100, 50, .buy);
    const order2 = try Order.init(1, 6, "IBM", 100, 50, .buy);
    const order3 = try Order.init(2, 5, "IBM", 100, 50, .buy);

    try std.testing.expect(order1.key() != order2.key());
    try std.testing.expect(order1.key() != order3.key());
    try std.testing.expect(order2.key() != order3.key());
}

test "Order: timestamp is set" {
    const order1 = try Order.init(1, 5, "IBM", 100, 50, .buy);
    
    // Sleep a tiny bit to ensure different timestamp
    std.time.sleep(1000); // 1 microsecond
    
    const order2 = try Order.init(1, 6, "IBM", 100, 50, .buy);

    // order2 should have a later timestamp (time priority)
    try std.testing.expect(order2.timestamp > order1.timestamp);
}

test "Order: sell side" {
    const order = try Order.init(3, 10, "TSLA", 250, 75, .sell);

    try std.testing.expectEqual(Side.sell, order.side);
    try std.testing.expectEqualStrings("TSLA", order.getSymbol());
}

test "Order: memory layout size" {
    // Verify Order struct is reasonably sized
    // Should be around 72-80 bytes
    const size = @sizeOf(Order);
    
    // Just document the size - it should be compact
    std.debug.print("\nOrder struct size: {d} bytes\n", .{size});
    try std.testing.expect(size < 128); // Sanity check
}
