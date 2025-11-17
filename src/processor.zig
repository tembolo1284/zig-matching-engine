const std = @import("std");
const MatchingEngine = @import("matching_engine.zig").MatchingEngine;
const message_types = @import("message_types.zig");
const InputMessage = message_types.InputMessage;
const OutputMessage = message_types.OutputMessage;
const LockFreeQueue = @import("lockfree_queue.zig").LockFreeQueue;

/// Processor - Thread 2: Process input messages through matching engine
/// 
/// Design decisions:
/// - Batch processing: Process up to 32 messages per iteration (reduces loop overhead)
/// - Adaptive sleep: 1μs when active, 100μs when idle (balances latency vs CPU)
/// - Non-blocking output push with retry limit (prevents deadlock)
/// - Graceful shutdown: Drains remaining messages from input queue
/// 
/// Performance characteristics:
/// - Throughput: ~1-5M orders/sec (depends on order book depth)
/// - Latency: ~1-10μs per order (when queue not empty)
/// - CPU usage: ~1-2% when idle, ~100% of one core when busy
pub const Processor = struct {
    allocator: std.mem.Allocator,
    
    // Input queue (from UDP receiver)
    input_queue: *LockFreeQueue(InputMessage, 16384),
    
    // Output queue (to output publisher)
    output_queue: *LockFreeQueue(OutputMessage, 16384),
    
    // Matching engine
    engine: MatchingEngine,
    
    // Thread handle
    thread: ?std.Thread,
    
    // Running flag (atomic)
    running: std.atomic.Value(bool),
    
    // Statistics
    messages_processed: std.atomic.Value(u64),

    pub fn init(
        allocator: std.mem.Allocator,
        input_queue: *LockFreeQueue(InputMessage, 16384),
        output_queue: *LockFreeQueue(OutputMessage, 16384),
    ) Processor {
        return .{
            .allocator = allocator,
            .input_queue = input_queue,
            .output_queue = output_queue,
            .engine = MatchingEngine.init(allocator),
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .messages_processed = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Processor) void {
        self.stop();
        self.engine.deinit();
    }

    /// Start processing (spawns thread)
    pub fn start(self: *Processor) !void {
        if (self.running.swap(true, .seq_cst)) {
            return; // Already running
        }

        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Stop processing (signals thread to exit)
    pub fn stop(self: *Processor) void {
        if (!self.running.swap(false, .seq_cst)) {
            return; // Not running
        }

        // Wait for thread to finish
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// Check if thread is running
    pub fn isRunning(self: *const Processor) bool {
        return self.running.load(.seq_cst);
    }

    /// Get number of messages processed
    pub fn getMessagesProcessed(self: *const Processor) u64 {
        return self.messages_processed.load(.seq_cst);
    }

    /// Thread entry point
    fn run(self: *Processor) void {
        std.log.info("Processor thread started", .{});

        // CRITICAL: Batch processing for better throughput
        const BATCH_SIZE = 32;
        var empty_iterations: usize = 0;

        // Temporary output buffer for matching engine
        var outputs = std.ArrayList(OutputMessage).init(self.allocator);
        defer outputs.deinit();

        while (self.running.load(.monotonic)) {
            var processed_this_iteration: usize = 0;

            // Try to process up to BATCH_SIZE messages without sleeping
            for (0..BATCH_SIZE) |_| {
                if (self.input_queue.pop()) |msg| {
                    self.processMessage(msg, &outputs) catch |err| {
                        std.log.err("Error processing message: {}", .{err});
                    };
                    
                    _ = self.messages_processed.fetchAdd(1, .monotonic);
                    processed_this_iteration += 1;
                    empty_iterations = 0; // Reset counter
                } else {
                    break; // Queue empty, exit batch
                }
            }

            // If queue was empty, sleep briefly
            if (processed_this_iteration == 0) {
                empty_iterations += 1;

                // CRITICAL: Adaptive sleep - sleep longer if consistently empty
                if (empty_iterations > 100) {
                    // Been empty for a while, sleep longer
                    std.time.sleep(100_000); // 100μs
                } else {
                    // Just became empty, use very short sleep
                    std.time.sleep(1_000); // 1μs
                }
            }
        }

        // Drain remaining messages in queue before exiting
        std.log.info("Draining remaining input messages...", .{});
        var drained: usize = 0;
        while (self.input_queue.pop()) |msg| {
            self.processMessage(msg, &outputs) catch |err| {
                std.log.err("Error processing message during drain: {}", .{err});
            };
            
            _ = self.messages_processed.fetchAdd(1, .monotonic);
            drained += 1;
        }

        if (drained > 0) {
            std.log.info("Drained {d} messages from input queue", .{drained});
        }

        std.log.info("Processor thread stopped. Messages processed: {d}", .{
            self.messages_processed.load(.seq_cst),
        });
    }

    /// Process a single input message
    fn processMessage(
        self: *Processor,
        msg: InputMessage,
        outputs: *std.ArrayList(OutputMessage),
    ) !void {
        // Clear output buffer from previous message
        outputs.clearRetainingCapacity();

        // Process through matching engine
        try self.engine.processMessage(msg, outputs);

        // Push all output messages to output queue
        for (outputs.items) |output| {
            // CRITICAL: Non-blocking push with limited retries
            var retry_count: usize = 0;
            const MAX_RETRIES = 1000;

            while (!self.output_queue.push(output)) {
                retry_count += 1;
                if (retry_count >= MAX_RETRIES) {
                    std.log.warn("Output queue full, dropping message!", .{});
                    break;
                }
                // Very brief wait
                std.Thread.yield() catch {};
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Processor: create and destroy" {
    var input_queue = LockFreeQueue(InputMessage, 16384).init();
    var output_queue = LockFreeQueue(OutputMessage, 16384).init();

    var processor = Processor.init(std.testing.allocator, &input_queue, &output_queue);
    defer processor.deinit();

    try std.testing.expect(!processor.isRunning());
    try std.testing.expectEqual(@as(u64, 0), processor.getMessagesProcessed());
}

test "Processor: process single message" {
    var input_queue = LockFreeQueue(InputMessage, 16384).init();
    var output_queue = LockFreeQueue(OutputMessage, 16384).init();

    var processor = Processor.init(std.testing.allocator, &input_queue, &output_queue);
    defer processor.deinit();

    // Create new order message
    var new_order = message_types.NewOrderMsg{
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

    // Start processor
    try processor.start();
    defer processor.stop();

    // Push message to input queue
    try std.testing.expect(input_queue.push(msg));

    // Wait a bit for processing
    std.time.sleep(10_000_000); // 10ms

    // Should have output messages
    try std.testing.expect(output_queue.pop() != null);

    // Should have processed at least 1 message
    try std.testing.expect(processor.getMessagesProcessed() >= 1);
}

test "Processor: process multiple messages" {
    var input_queue = LockFreeQueue(InputMessage, 16384).init();
    var output_queue = LockFreeQueue(OutputMessage, 16384).init();

    var processor = Processor.init(std.testing.allocator, &input_queue, &output_queue);
    defer processor.deinit();

    try processor.start();
    defer processor.stop();

    // Push multiple messages
    for (0..10) |i| {
        var new_order = message_types.NewOrderMsg{
            .user_id = @intCast(i + 1),
            .symbol = undefined,
            .symbol_len = 0,
            .price = 100,
            .quantity = 50,
            .side = .buy,
            .user_order_id = @intCast(i + 1),
        };
        try new_order.setSymbol("IBM");

        const msg = InputMessage{ .new_order = new_order };
        try std.testing.expect(input_queue.push(msg));
    }

    // Wait for processing
    std.time.sleep(50_000_000); // 50ms

    // Should have processed all messages
    try std.testing.expectEqual(@as(u64, 10), processor.getMessagesProcessed());

    // Should have output messages (ACK + TOB for each)
    var output_count: usize = 0;
    while (output_queue.pop()) |_| {
        output_count += 1;
    }
    try std.testing.expect(output_count >= 10); // At least 10 (probably 20: ACK + TOB)
}

test "Processor: graceful shutdown drains queue" {
    var input_queue = LockFreeQueue(InputMessage, 16384).init();
    var output_queue = LockFreeQueue(OutputMessage, 16384).init();

    var processor = Processor.init(std.testing.allocator, &input_queue, &output_queue);
    defer processor.deinit();

    // Push messages but don't start processor yet
    for (0..5) |i| {
        var new_order = message_types.NewOrderMsg{
            .user_id = @intCast(i + 1),
            .symbol = undefined,
            .symbol_len = 0,
            .price = 100,
            .quantity = 50,
            .side = .buy,
            .user_order_id = @intCast(i + 1),
        };
        try new_order.setSymbol("IBM");

        const msg = InputMessage{ .new_order = new_order };
        try std.testing.expect(input_queue.push(msg));
    }

    // Now start and immediately stop (should still process all)
    try processor.start();
    std.time.sleep(5_000_000); // 5ms to process
    processor.stop();

    // All messages should be processed
    try std.testing.expectEqual(@as(u64, 5), processor.getMessagesProcessed());
    try std.testing.expect(input_queue.isEmpty());
}

test "Processor: handles flush message" {
    var input_queue = LockFreeQueue(InputMessage, 16384).init();
    var output_queue = LockFreeQueue(OutputMessage, 16384).init();

    var processor = Processor.init(std.testing.allocator, &input_queue, &output_queue);
    defer processor.deinit();

    try processor.start();
    defer processor.stop();

    // Add an order
    var new_order = message_types.NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 100,
        .quantity = 50,
        .side = .buy,
        .user_order_id = 1,
    };
    try new_order.setSymbol("IBM");
    try std.testing.expect(input_queue.push(.{ .new_order = new_order }));

    // Flush
    try std.testing.expect(input_queue.push(.{ .flush = .{} }));

    // Wait for processing
    std.time.sleep(10_000_000); // 10ms

    // Should have processed 2 messages
    try std.testing.expectEqual(@as(u64, 2), processor.getMessagesProcessed());
}

test "Processor: handles cancel message" {
    var input_queue = LockFreeQueue(InputMessage, 16384).init();
    var output_queue = LockFreeQueue(OutputMessage, 16384).init();

    var processor = Processor.init(std.testing.allocator, &input_queue, &output_queue);
    defer processor.deinit();

    try processor.start();
    defer processor.stop();

    // Add an order
    var new_order = message_types.NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 100,
        .quantity = 50,
        .side = .buy,
        .user_order_id = 1,
    };
    try new_order.setSymbol("IBM");
    try std.testing.expect(input_queue.push(.{ .new_order = new_order }));

    // Cancel it
    try std.testing.expect(input_queue.push(.{
        .cancel_order = .{
            .user_id = 1,
            .user_order_id = 1,
        },
    }));

    // Wait for processing
    std.time.sleep(10_000_000); // 10ms

    // Should have processed 2 messages
    try std.testing.expectEqual(@as(u64, 2), processor.getMessagesProcessed());

    // Should have cancel ack in output
    var has_cancel_ack = false;
    while (output_queue.pop()) |msg| {
        if (msg == .cancel_ack) {
            has_cancel_ack = true;
        }
    }
    try std.testing.expect(has_cancel_ack);
}

test "Processor: multi-symbol processing" {
    var input_queue = LockFreeQueue(InputMessage, 16384).init();
    var output_queue = LockFreeQueue(OutputMessage, 16384).init();

    var processor = Processor.init(std.testing.allocator, &input_queue, &output_queue);
    defer processor.deinit();

    try processor.start();
    defer processor.stop();

    // Add orders to different symbols
    var ibm_order = message_types.NewOrderMsg{
        .user_id = 1,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 100,
        .quantity = 50,
        .side = .buy,
        .user_order_id = 1,
    };
    try ibm_order.setSymbol("IBM");
    try std.testing.expect(input_queue.push(.{ .new_order = ibm_order }));

    var aapl_order = message_types.NewOrderMsg{
        .user_id = 2,
        .symbol = undefined,
        .symbol_len = 0,
        .price = 150,
        .quantity = 100,
        .side = .sell,
        .user_order_id = 2,
    };
    try aapl_order.setSymbol("AAPL");
    try std.testing.expect(input_queue.push(.{ .new_order = aapl_order }));

    // Wait for processing
    std.time.sleep(10_000_000); // 10ms

    // Should have processed 2 messages
    try std.testing.expectEqual(@as(u64, 2), processor.getMessagesProcessed());
}
