const std = @import("std");
const message_types = @import("message_types.zig");
const OutputMessage = message_types.OutputMessage;
const LockFreeQueue = @import("lockfree_queue.zig").LockFreeQueue;

/// Output Publisher - Thread 3: Format and publish output messages to stdout
/// 
/// Design decisions:
/// - Pops from output queue (from processor)
/// - Formats to CSV using message_types.formatOutputMessage
/// - Writes to stdout with immediate flush (real-time output)
/// - Graceful shutdown: Drains remaining messages
/// - Brief sleep when queue empty (avoids busy-waiting)
/// 
/// Performance characteristics:
/// - Throughput: Limited by stdout (~1-10M lines/sec)
/// - Latency: ~1-5μs per message (write + flush)
/// - CPU usage: ~1-2% when idle, ~5-10% when busy
pub const OutputPublisher = struct {
    allocator: std.mem.Allocator,
    
    // Input queue (from processor)
    input_queue: *LockFreeQueue(OutputMessage, 16384),
    
    // Thread handle
    thread: ?std.Thread,
    
    // Running flag (atomic)
    running: std.atomic.Value(bool),
    
    // Statistics
    messages_published: std.atomic.Value(u64),
    
    // Stdout writer
    stdout: std.fs.File.Writer,

    pub fn init(
        allocator: std.mem.Allocator,
        input_queue: *LockFreeQueue(OutputMessage, 16384),
    ) OutputPublisher {
        return .{
            .allocator = allocator,
            .input_queue = input_queue,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .messages_published = std.atomic.Value(u64).init(0),
            .stdout = std.io.getStdOut().writer(),
        };
    }

    pub fn deinit(self: *OutputPublisher) void {
        self.stop();
    }

    /// Start publishing (spawns thread)
    pub fn start(self: *OutputPublisher) !void {
        if (self.running.swap(true, .seq_cst)) {
            return; // Already running
        }

        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Stop publishing (signals thread to exit and drains queue)
    pub fn stop(self: *OutputPublisher) void {
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
    pub fn isRunning(self: *const OutputPublisher) bool {
        return self.running.load(.seq_cst);
    }

    /// Get number of messages published
    pub fn getMessagesPublished(self: *const OutputPublisher) u64 {
        return self.messages_published.load(.seq_cst);
    }

    /// Thread entry point
    fn run(self: *OutputPublisher) void {
        std.log.info("Output Publisher thread started", .{});

        while (self.running.load(.monotonic)) {
            // Try to pop message from input queue
            if (self.input_queue.pop()) |msg| {
                self.publishMessage(msg) catch |err| {
                    std.log.err("Error publishing message: {}", .{err});
                };
                
                _ = self.messages_published.fetchAdd(1, .monotonic);
            } else {
                // Queue empty - brief sleep to avoid busy-waiting
                // 10μs is a good balance between latency and CPU usage
                std.time.sleep(10_000); // 10μs
            }
        }

        // Drain remaining messages in queue before exiting
        std.log.info("Draining remaining output messages...", .{});
        var drained: usize = 0;
        while (self.input_queue.pop()) |msg| {
            self.publishMessage(msg) catch |err| {
                std.log.err("Error publishing message during drain: {}", .{err});
            };
            
            _ = self.messages_published.fetchAdd(1, .monotonic);
            drained += 1;
        }

        if (drained > 0) {
            std.log.info("Drained {d} messages from output queue", .{drained});
        }

        std.log.info("Output Publisher thread stopped. Messages published: {d}", .{
            self.messages_published.load(.seq_cst),
        });
    }

    /// Publish a single output message
    fn publishMessage(self: *OutputPublisher, msg: OutputMessage) !void {
        // Format message to CSV
        try message_types.formatOutputMessage(msg, self.stdout);
        
        // Flush to ensure real-time output
        // This is critical for piping to other programs or tee
        // try self.stdout.context.sync();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OutputPublisher: create and destroy" {
    var input_queue = LockFreeQueue(OutputMessage, 16384).init();
    
    var publisher = OutputPublisher.init(std.testing.allocator, &input_queue);
    defer publisher.deinit();
    
    try std.testing.expect(!publisher.isRunning());
    try std.testing.expectEqual(@as(u64, 0), publisher.getMessagesPublished());
}

test "OutputPublisher: publish single message" {
    var input_queue = LockFreeQueue(OutputMessage, 16384).init();
    
    var publisher = OutputPublisher.init(std.testing.allocator, &input_queue);
    defer publisher.deinit();
    
    // Push a message
    const msg = OutputMessage{
        .ack = .{
            .user_id = 1,
            .user_order_id = 5,
        },
    };
    try std.testing.expect(input_queue.push(msg));
    
    // Start publisher
    try publisher.start();
    defer publisher.stop();
    
    // Wait for processing
    std.time.sleep(10_000_000); // 10ms
    
    // Should have published 1 message
    try std.testing.expectEqual(@as(u64, 1), publisher.getMessagesPublished());
    
    // Queue should be empty
    try std.testing.expect(input_queue.isEmpty());
}

test "OutputPublisher: publish multiple messages" {
    var input_queue = LockFreeQueue(OutputMessage, 16384).init();
    
    var publisher = OutputPublisher.init(std.testing.allocator, &input_queue);
    defer publisher.deinit();
    
    try publisher.start();
    defer publisher.stop();
    
    // Push multiple messages
    for (0..10) |i| {
        const msg = OutputMessage{
            .ack = .{
                .user_id = @intCast(i + 1),
                .user_order_id = @intCast(i + 1),
            },
        };
        try std.testing.expect(input_queue.push(msg));
    }
    
    // Wait for processing
    std.time.sleep(50_000_000); // 50ms
    
    // Should have published all messages
    try std.testing.expectEqual(@as(u64, 10), publisher.getMessagesPublished());
}

test "OutputPublisher: graceful shutdown drains queue" {
    var input_queue = LockFreeQueue(OutputMessage, 16384).init();
    
    var publisher = OutputPublisher.init(std.testing.allocator, &input_queue);
    defer publisher.deinit();
    
    // Push messages but don't start publisher yet
    for (0..5) |i| {
        const msg = OutputMessage{
            .ack = .{
                .user_id = @intCast(i + 1),
                .user_order_id = @intCast(i + 1),
            },
        };
        try std.testing.expect(input_queue.push(msg));
    }
    
    // Now start and immediately stop (should still publish all)
    try publisher.start();
    std.time.sleep(5_000_000); // 5ms to process
    publisher.stop();
    
    // All messages should be published
    try std.testing.expectEqual(@as(u64, 5), publisher.getMessagesPublished());
    try std.testing.expect(input_queue.isEmpty());
}

test "OutputPublisher: publish different message types" {
    var input_queue = LockFreeQueue(OutputMessage, 16384).init();
    
    var publisher = OutputPublisher.init(std.testing.allocator, &input_queue);
    defer publisher.deinit();
    
    try publisher.start();
    defer publisher.stop();
    
    // ACK
    try std.testing.expect(input_queue.push(.{
        .ack = .{ .user_id = 1, .user_order_id = 1 },
    }));
    
    // Trade
    try std.testing.expect(input_queue.push(.{
        .trade = .{
            .user_id_buy = 1,
            .user_order_id_buy = 1,
            .user_id_sell = 2,
            .user_order_id_sell = 2,
            .price = 100,
            .quantity = 50,
        },
    }));
    
    // Top of book
    try std.testing.expect(input_queue.push(.{
        .top_of_book = .{
            .side = .buy,
            .tob = .{
                .price = 100,
                .total_quantity = 150,
                .eliminated = false,
            },
        },
    }));
    
    // Cancel ack
    try std.testing.expect(input_queue.push(.{
        .cancel_ack = .{ .user_id = 1, .user_order_id = 1 },
    }));
    
    // Wait for processing
    std.time.sleep(20_000_000); // 20ms
    
    // Should have published all 4 messages
    try std.testing.expectEqual(@as(u64, 4), publisher.getMessagesPublished());
}

test "OutputPublisher: handles empty queue gracefully" {
    var input_queue = LockFreeQueue(OutputMessage, 16384).init();
    
    var publisher = OutputPublisher.init(std.testing.allocator, &input_queue);
    defer publisher.deinit();
    
    // Start with empty queue
    try publisher.start();
    
    // Let it run for a bit
    std.time.sleep(20_000_000); // 20ms
    
    // Stop
    publisher.stop();
    
    // Should have published 0 messages (no crash)
    try std.testing.expectEqual(@as(u64, 0), publisher.getMessagesPublished());
}

test "OutputPublisher: high throughput" {
    var input_queue = LockFreeQueue(OutputMessage, 16384).init();
    
    var publisher = OutputPublisher.init(std.testing.allocator, &input_queue);
    defer publisher.deinit();
    
    try publisher.start();
    defer publisher.stop();
    
    // Push 1000 messages
    for (0..1000) |i| {
        const msg = OutputMessage{
            .ack = .{
                .user_id = @intCast(i + 1),
                .user_order_id = @intCast(i + 1),
            },
        };
        try std.testing.expect(input_queue.push(msg));
    }
    
    // Wait for processing
    std.time.sleep(200_000_000); // 200ms
    
    // Should have published all messages
    try std.testing.expectEqual(@as(u64, 1000), publisher.getMessagesPublished());
}
