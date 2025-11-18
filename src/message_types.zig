const std = @import("std");

// ============================================================================
// Core Enumerations
// ============================================================================

/// Side of the order - Buy or Sell
pub const Side = enum {
    buy,
    sell,

    pub fn fromChar(c: u8) !Side {
        return switch (c) {
            'B' => .buy,
            'S' => .sell,
            else => error.InvalidSide,
        };
    }

    pub fn toChar(self: Side) u8 {
        return switch (self) {
            .buy => 'B',
            .sell => 'S',
        };
    }
};

/// Order type - Market or Limit
pub const OrderType = enum {
    market,
    limit,

    pub fn fromPrice(price: u32) OrderType {
        return if (price == 0) .market else .limit;
    }
};

// ============================================================================
// Input Message Structures
// ============================================================================

/// New order message
/// Uses fixed-size symbol buffer (16 bytes) instead of std::string
/// This avoids heap allocation and improves cache locality
pub const NewOrderMsg = struct {
    user_id: u32,
    symbol: [16]u8,
    symbol_len: u8,
    price: u32,
    quantity: u32,
    side: Side,
    user_order_id: u32,

    pub fn getSymbol(self: *const NewOrderMsg) []const u8 {
        return self.symbol[0..self.symbol_len];
    }

    pub fn setSymbol(self: *NewOrderMsg, symbol: []const u8) !void {
        if (symbol.len > 16) return error.SymbolTooLong;
        @memcpy(self.symbol[0..symbol.len], symbol);
        self.symbol_len = @intCast(symbol.len);
    }
};

/// Cancel order message
pub const CancelOrderMsg = struct {
    user_id: u32,
    user_order_id: u32,
};

/// Flush message (no fields needed)
pub const FlushMsg = struct {};

/// Input message - tagged union (replaces C++ std::variant)
/// This is a zero-cost abstraction - no RTTI overhead like std::variant
pub const InputMessage = union(enum) {
    new_order: NewOrderMsg,
    cancel_order: CancelOrderMsg,
    flush: FlushMsg,
};

// ============================================================================
// Output Message Structures
// ============================================================================

/// Acknowledgement message
pub const AckMsg = struct {
    user_id: u32,
    user_order_id: u32,
    symbol: [16]u8,
    symbol_len: u8,

    pub fn getSymbol(self: *const AckMsg) []const u8 {
        return self.symbol[0..self.symbol_len];
    }

    pub fn setSymbol(self: *AckMsg, symbol: []const u8) !void {
        if (symbol.len > 16) return error.SymbolTooLong;
        @memcpy(self.symbol[0..symbol.len], symbol);
        self.symbol_len = @intCast(symbol.len);
    }
};

/// Trade message
pub const TradeMsg = struct {
    user_id_buy: u32,
    user_order_id_buy: u32,
    user_id_sell: u32,
    user_order_id_sell: u32,
    price: u32,
    quantity: u32,
    symbol: [16]u8,
    symbol_len: u8,

    pub fn getSymbol(self: *const TradeMsg) []const u8 {
        return self.symbol[0..self.symbol_len];
    }

    pub fn setSymbol(self: *TradeMsg, symbol: []const u8) !void {
        if (symbol.len > 16) return error.SymbolTooLong;
        @memcpy(self.symbol[0..symbol.len], symbol);
        self.symbol_len = @intCast(symbol.len);
    }
};

/// Top of book data
pub const TopOfBook = struct {
    price: u32,
    total_quantity: u32,
    eliminated: bool = false,
};

/// Top of book message
pub const TopOfBookMsg = struct {
    side: Side,
    tob: TopOfBook,
    symbol: [16]u8,
    symbol_len: u8,

    pub fn getSymbol(self: *const TopOfBookMsg) []const u8 {
        return self.symbol[0..self.symbol_len];
    }

    pub fn setSymbol(self: *TopOfBookMsg, symbol: []const u8) !void {
        if (symbol.len > 16) return error.SymbolTooLong;
        @memcpy(self.symbol[0..symbol.len], symbol);
        self.symbol_len = @intCast(symbol.len);
    }
};

/// Cancel acknowledgement
pub const CancelAckMsg = struct {
    user_id: u32,
    user_order_id: u32,
    symbol: [16]u8,
    symbol_len: u8,

    pub fn getSymbol(self: *const CancelAckMsg) []const u8 {
        return self.symbol[0..self.symbol_len];
    }

    pub fn setSymbol(self: *CancelAckMsg, symbol: []const u8) !void {
        if (symbol.len > 16) return error.SymbolTooLong;
        @memcpy(self.symbol[0..symbol.len], symbol);
        self.symbol_len = @intCast(symbol.len);
    }
};

/// Output message - tagged union
pub const OutputMessage = union(enum) {
    ack: AckMsg,
    trade: TradeMsg,
    top_of_book: TopOfBookMsg,
    cancel_ack: CancelAckMsg,
};

// ============================================================================
// Parsing - Input Messages
// ============================================================================

/// Parse a CSV line into an InputMessage
/// Returns error union (not std::optional) - forces caller to handle errors
pub fn parseInputMessage(line: []const u8) !InputMessage {
    var it = std.mem.tokenizeScalar(u8, line, ',');

    // Get message type (first token)
    const msg_type_raw = it.next() orelse return error.InvalidMessage;
    const msg_type = std.mem.trim(u8, msg_type_raw, " \t\r\n");

    if (msg_type.len == 0) return error.InvalidMessage;

    switch (msg_type[0]) {
        'N' => return try parseNewOrder(&it),
        'C' => return try parseCancelOrder(&it),
        'F' => return try parseFlush(&it),
        '#' => return error.CommentLine, // Skip comments
        else => return error.InvalidMessageType,
    }
}

fn parseNewOrder(it: *std.mem.TokenIterator(u8, .scalar)) !InputMessage {
    // Format: N, user, symbol, price, qty, side, userOrderId
    const user_id = try parseU32(it.next() orelse return error.MissingUserId);
    const symbol_str = std.mem.trim(u8, it.next() orelse return error.MissingSymbol, " \t\r\n");
    const price = try parseU32(it.next() orelse return error.MissingPrice);
    const quantity = try parseU32(it.next() orelse return error.MissingQuantity);
    const side_str = std.mem.trim(u8, it.next() orelse return error.MissingSide, " \t\r\n");
    const user_order_id = try parseU32(it.next() orelse return error.MissingUserOrderId);

    if (quantity == 0) return error.ZeroQuantity;
    if (side_str.len == 0) return error.MissingSide;

    var new_order = NewOrderMsg{
        .user_id = user_id,
        .symbol = undefined,
        .symbol_len = 0,
        .price = price,
        .quantity = quantity,
        .side = try Side.fromChar(side_str[0]),
        .user_order_id = user_order_id,
    };

    try new_order.setSymbol(symbol_str);

    return InputMessage{ .new_order = new_order };
}

fn parseCancelOrder(it: *std.mem.TokenIterator(u8, .scalar)) !InputMessage {
    // Format: C, user, userOrderId
    const user_id = try parseU32(it.next() orelse return error.MissingUserId);
    const user_order_id = try parseU32(it.next() orelse return error.MissingUserOrderId);

    return InputMessage{
        .cancel_order = CancelOrderMsg{
            .user_id = user_id,
            .user_order_id = user_order_id,
        },
    };
}

fn parseFlush(it: *std.mem.TokenIterator(u8, .scalar)) !InputMessage {
    // Format: F (no additional tokens)
    _ = it;
    return InputMessage{ .flush = FlushMsg{} };
}

fn parseU32(s: []const u8) !u32 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return std.fmt.parseInt(u32, trimmed, 10);
}

// ============================================================================
// Formatting - Output Messages
// ============================================================================

/// Format an OutputMessage to CSV string
/// Uses anytype for writer - works with any std.io.Writer
/// This is more flexible than C++'s std::ostringstream
pub fn formatOutputMessage(msg: OutputMessage, writer: anytype) !void {
    switch (msg) {
        .ack => |ack| {
            try writer.print("A, {d}, {d}, {s}\n", .{ 
                ack.user_id, 
                ack.user_order_id,
                ack.getSymbol(),
             });
        },
        .trade => |trade| {
            try writer.print("T, {d}, {d}, {d}, {d}, {d}, {d}, {s}\n", .{
                trade.user_id_buy,
                trade.user_order_id_buy,
                trade.user_id_sell,
                trade.user_order_id_sell,
                trade.price,
                trade.quantity,
                trade.getSymbol(),
            });
        },
        .top_of_book => |tob_msg| {
            const side_char = tob_msg.side.toChar();
            if (tob_msg.tob.eliminated) {
                try writer.print("B, {c}, -, -, {s}\n", .{side_char, tob_msg.getSymbol()});
            } else {
                try writer.print("B, {c}, {d}, {d}, {s}\n", .{
                    side_char,
                    tob_msg.tob.price,
                    tob_msg.tob.total_quantity,
                    tob_msg.getSymbol(),
                });
            }
        },
        .cancel_ack => |cancel| {
            try writer.print("C, {d}, {d}, {s}\n", .{ 
                cancel.user_id, 
                cancel.user_order_id,
                cancel.getSymbol(),
            });
        },
    }
}

// ============================================================================
// Tests
// ============================================================================

test "Side: fromChar and toChar" {
    try std.testing.expectEqual(Side.buy, try Side.fromChar('B'));
    try std.testing.expectEqual(Side.sell, try Side.fromChar('S'));
    try std.testing.expectError(error.InvalidSide, Side.fromChar('X'));

    try std.testing.expectEqual(@as(u8, 'B'), Side.buy.toChar());
    try std.testing.expectEqual(@as(u8, 'S'), Side.sell.toChar());
}

test "OrderType: fromPrice" {
    try std.testing.expectEqual(OrderType.market, OrderType.fromPrice(0));
    try std.testing.expectEqual(OrderType.limit, OrderType.fromPrice(100));
    try std.testing.expectEqual(OrderType.limit, OrderType.fromPrice(1));
}

test "NewOrderMsg: setSymbol and getSymbol" {
    var msg = NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 100,
        .quantity = 50,
        .side = .buy,
        .user_order_id = 1,
    };

    try msg.setSymbol("IBM");
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());

    try msg.setSymbol("AAPL");
    try std.testing.expectEqualStrings("AAPL", msg.getSymbol());

    // Test symbol too long
    try std.testing.expectError(error.SymbolTooLong, msg.setSymbol("VERYLONGSYMBOLNAME"));
}

test "parse new order: buy" {
    const input = "N, 1, IBM, 10, 100, B, 1";
    const msg = try parseInputMessage(input);

    try std.testing.expect(msg == .new_order);
    try std.testing.expectEqual(@as(u32, 1), msg.new_order.user_id);
    try std.testing.expectEqualStrings("IBM", msg.new_order.getSymbol());
    try std.testing.expectEqual(@as(u32, 10), msg.new_order.price);
    try std.testing.expectEqual(@as(u32, 100), msg.new_order.quantity);
    try std.testing.expectEqual(Side.buy, msg.new_order.side);
    try std.testing.expectEqual(@as(u32, 1), msg.new_order.user_order_id);
}

test "parse new order: sell" {
    const input = "N, 2, AAPL, 150, 200, S, 5";
    const msg = try parseInputMessage(input);

    try std.testing.expect(msg == .new_order);
    try std.testing.expectEqual(@as(u32, 2), msg.new_order.user_id);
    try std.testing.expectEqualStrings("AAPL", msg.new_order.getSymbol());
    try std.testing.expectEqual(@as(u32, 150), msg.new_order.price);
    try std.testing.expectEqual(@as(u32, 200), msg.new_order.quantity);
    try std.testing.expectEqual(Side.sell, msg.new_order.side);
    try std.testing.expectEqual(@as(u32, 5), msg.new_order.user_order_id);
}

test "parse new order: market order (price=0)" {
    const input = "N, 1, IBM, 0, 100, B, 1";
    const msg = try parseInputMessage(input);

    try std.testing.expect(msg == .new_order);
    try std.testing.expectEqual(@as(u32, 0), msg.new_order.price);
}

test "parse cancel order" {
    const input = "C, 1, 5";
    const msg = try parseInputMessage(input);

    try std.testing.expect(msg == .cancel_order);
    try std.testing.expectEqual(@as(u32, 1), msg.cancel_order.user_id);
    try std.testing.expectEqual(@as(u32, 5), msg.cancel_order.user_order_id);
}

test "parse flush" {
    const input = "F";
    const msg = try parseInputMessage(input);

    try std.testing.expect(msg == .flush);
}

test "parse: whitespace handling" {
    const input = "  N,  1,  IBM,  10,  100,  B,  1  ";
    const msg = try parseInputMessage(input);

    try std.testing.expect(msg == .new_order);
    try std.testing.expectEqualStrings("IBM", msg.new_order.getSymbol());
}

test "parse: comment line" {
    const input = "# This is a comment";
    try std.testing.expectError(error.CommentLine, parseInputMessage(input));
}

test "parse: empty line" {
    try std.testing.expectError(error.InvalidMessage, parseInputMessage(""));
    try std.testing.expectError(error.InvalidMessage, parseInputMessage("   "));
}

test "parse: invalid message type" {
    try std.testing.expectError(error.InvalidMessageType, parseInputMessage("X, 1, 2"));
}

test "parse: missing fields" {
    try std.testing.expectError(error.MissingSymbol, parseInputMessage("N, 1"));
    try std.testing.expectError(error.MissingUserOrderId, parseInputMessage("C, 1"));
}

test "parse: invalid side" {
    try std.testing.expectError(error.InvalidSide, parseInputMessage("N, 1, IBM, 10, 100, X, 1"));
}

test "parse: zero quantity" {
    try std.testing.expectError(error.ZeroQuantity, parseInputMessage("N, 1, IBM, 10, 0, B, 1"));
}

test "format ack message" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const msg = OutputMessage{ .ack = AckMsg{ .user_id = 1, .user_order_id = 5 } };
    try formatOutputMessage(msg, buf.writer());

    try std.testing.expectEqualStrings("A, 1, 5\n", buf.items);
}

test "format trade message" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const msg = OutputMessage{
        .trade = TradeMsg{
            .user_id_buy = 1,
            .user_order_id_buy = 3,
            .user_id_sell = 2,
            .user_order_id_sell = 102,
            .price = 11,
            .quantity = 100,
        },
    };
    try formatOutputMessage(msg, buf.writer());

    try std.testing.expectEqualStrings("T, 1, 3, 2, 102, 11, 100\n", buf.items);
}

test "format top of book message" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const msg = OutputMessage{
        .top_of_book = TopOfBookMsg{
            .side = .buy,
            .tob = TopOfBook{
                .price = 100,
                .total_quantity = 500,
                .eliminated = false,
            },
        },
    };
    try formatOutputMessage(msg, buf.writer());

    try std.testing.expectEqualStrings("B, B, 100, 500\n", buf.items);
}

test "format top of book eliminated" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const msg = OutputMessage{
        .top_of_book = TopOfBookMsg{
            .side = .sell,
            .tob = TopOfBook{
                .price = 0,
                .total_quantity = 0,
                .eliminated = true,
            },
        },
    };
    try formatOutputMessage(msg, buf.writer());

    try std.testing.expectEqualStrings("B, S, -, -\n", buf.items);
}

test "format cancel ack message" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    const msg = OutputMessage{ .cancel_ack = CancelAckMsg{ .user_id = 2, .user_order_id = 10 } };
    try formatOutputMessage(msg, buf.writer());

    try std.testing.expectEqualStrings("C, 2, 10\n", buf.items);
}
