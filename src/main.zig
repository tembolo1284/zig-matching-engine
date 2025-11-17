const std = @import("std");
const posix = std.posix;

// Import all our components
const message_types = @import("message_types.zig");
const InputMessage = message_types.InputMessage;
const OutputMessage = message_types.OutputMessage;
const LockFreeQueue = @import("lockfree_queue.zig").LockFreeQueue;
const UdpReceiver = @import("udp_receiver.zig").UdpReceiver;
const Processor = @import("processor.zig").Processor;
const OutputPublisher = @import("output_publisher.zig").OutputPublisher;

/// Global shutdown flag (set by signal handler)
var shutdown_requested = std.atomic.Value(bool).init(false);

/// Signal handler for graceful shutdown
fn signalHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    shutdown_requested.store(true, .seq_cst);
}

pub fn main() !void {
    // Use GeneralPurposeAllocator for good debugging and leak detection
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    }
    const allocator = gpa.allocator();

    // Parse command line arguments (optional: port number)
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // Skip program name

    var port: u16 = 1234; // Default port
    if (args.next()) |arg| {
        port = std.fmt.parseInt(u16, arg, 10) catch {
            std.log.err("Invalid port number, using default: 1234", .{});
            1234
        };
    }

    // Print banner
    std.log.info("==============================================================", .{});
    std.log.info("Kraken Matching Engine (Zig Implementation)", .{});
    std.log.info("==============================================================", .{});
    std.log.info("UDP Port: {d}", .{port});
    std.log.info("==============================================================", .{});

    // Create lock-free queues
    // CRITICAL: 16384 capacity handles UDP burst traffic (cat file | netcat)
    var input_queue = LockFreeQueue(InputMessage, 16384).init();
    var output_queue = LockFreeQueue(OutputMessage, 16384).init();

    std.log.info("Queue Configuration:", .{});
    std.log.info("  Input queue capacity:  {d} messages", .{input_queue.capacity()});
    std.log.info("  Output queue capacity: {d} messages", .{output_queue.capacity()});
    std.log.info("==============================================================", .{});

    // Create thread components
    var receiver = UdpReceiver.init(allocator, &input_queue, port);
    defer receiver.deinit();

    var processor = Processor.init(allocator, &input_queue, &output_queue);
    defer processor.deinit();

    var publisher = OutputPublisher.init(allocator, &output_queue);
    defer publisher.deinit();

    // Set up signal handlers for graceful shutdown
    // SIGINT = Ctrl+C, SIGTERM = kill command
    const sigaction = posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = posix.empty_sigset,
        .flags = 0,
    };

    try posix.sigaction(posix.SIG.INT, &sigaction, null);
    try posix.sigaction(posix.SIG.TERM, &sigaction, null);

    // Start all threads in order
    std.log.info("Starting threads...", .{});
    
    try receiver.start();
    std.log.info("  ✓ UDP Receiver started", .{});
    
    try processor.start();
    std.log.info("  ✓ Processor started", .{});
    
    try publisher.start();
    std.log.info("  ✓ Output Publisher started", .{});

    std.log.info("==============================================================", .{});
    std.log.info("All threads started. System is running.", .{});
    std.log.info("Press Ctrl+C to shutdown gracefully.", .{});
    std.log.info("==============================================================", .{});

    // Main thread waits for shutdown signal
    while (!shutdown_requested.load(.seq_cst)) {
        std.time.sleep(50_000_000); // 50ms

        // Optional: Monitor queue depths (useful for debugging)
        // Uncomment to see real-time queue usage:
        // if (input_queue.size() > 1000 or output_queue.size() > 1000) {
        //     std.log.warn("Queue depths - Input: {d}, Output: {d}", .{
        //         input_queue.size(),
        //         output_queue.size(),
        //     });
        // }
    }

    // Graceful shutdown sequence
    std.log.info("==============================================================", .{});
    std.log.info("Shutdown signal received. Initiating graceful shutdown...", .{});
    std.log.info("==============================================================", .{});

    // Stop receiver first (no more input)
    std.log.info("Stopping UDP receiver...", .{});
    receiver.stop();
    std.log.info("  ✓ UDP Receiver stopped", .{});

    // Give processor time to drain input queue
    std.log.info("Draining input queue (size: {d})...", .{input_queue.size()});
    std.time.sleep(200_000_000); // 200ms
    std.log.info("  ✓ Input queue drained (remaining: {d})", .{input_queue.size()});

    // Stop processor (no more processing)
    std.log.info("Stopping processor...", .{});
    processor.stop();
    std.log.info("  ✓ Processor stopped", .{});

    // Give publisher time to drain output queue
    std.log.info("Draining output queue (size: {d})...", .{output_queue.size()});
    std.time.sleep(200_000_000); // 200ms
    std.log.info("  ✓ Output queue drained (remaining: {d})", .{output_queue.size()});

    // Stop publisher (no more output)
    std.log.info("Stopping output publisher...", .{});
    publisher.stop();
    std.log.info("  ✓ Output Publisher stopped", .{});

    // Print statistics
    std.log.info("==============================================================", .{});
    std.log.info("Shutdown complete. Final statistics:", .{});
    std.log.info("  Messages processed:  {d}", .{processor.getMessagesProcessed()});
    std.log.info("  Messages published:  {d}", .{publisher.getMessagesPublished()});
    std.log.info("==============================================================", .{});
    std.log.info("Goodbye!", .{});
}

// Run all tests when building with `zig test`
test {
    std.testing.refAllDecls(@This());
    _ = @import("message_types.zig");
    _ = @import("order.zig");
    _ = @import("lockfree_queue.zig");
    _ = @import("order_book.zig");
    _ = @import("matching_engine.zig");
    _ = @import("processor.zig");
    _ = @import("udp_receiver.zig");
    _ = @import("output_publisher.zig");
}
