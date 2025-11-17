const std = @import("std");
const posix = std.posix;
const message_types = @import("message_types.zig");
const InputMessage = message_types.InputMessage;
const LockFreeQueue = @import("lockfree_queue.zig").LockFreeQueue;

/// UDP Receiver - Thread 1: Receive UDP packets and parse messages
/// 
/// Design decisions:
/// - Raw POSIX sockets (no Boost.Asio dependency)
/// - 10MB receive buffer to handle burst traffic (cat | netcat)
/// - Multi-line packet parsing (UDP packets can contain multiple CSV lines)
/// - Non-blocking queue push with retry limit
/// - Graceful shutdown via atomic flag
/// 
/// POSIX Socket APIs used:
/// - socket()  : Create UDP socket
/// - bind()    : Bind to port
/// - setsockopt() : Set socket options (buffer size, reuse addr)
/// - recvfrom() : Receive UDP packets
/// - close()   : Close socket
pub const UdpReceiver = struct {
    allocator: std.mem.Allocator,
    
    // Output queue (to processor)
    output_queue: *LockFreeQueue(InputMessage, 16384),
    
    // Network configuration
    port: u16,
    socket_fd: posix.socket_t,
    
    // Thread handle
    thread: ?std.Thread,
    
    // Running flag (atomic)
    running: std.atomic.Value(bool),
    
    // Receive buffer (64KB - max UDP packet size)
    recv_buffer: [65536]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        output_queue: *LockFreeQueue(InputMessage, 16384),
        port: u16,
    ) UdpReceiver {
        return .{
            .allocator = allocator,
            .output_queue = output_queue,
            .port = port,
            .socket_fd = -1,
            .thread = null,
            .running = std.atomic.Value(bool).init(false),
            .recv_buffer = undefined,
        };
    }

    pub fn deinit(self: *UdpReceiver) void {
        self.stop();
    }

    /// Start receiving (spawns thread)
    pub fn start(self: *UdpReceiver) !void {
        if (self.running.swap(true, .seq_cst)) {
            return; // Already running
        }

        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Stop receiving (signals thread to exit)
    pub fn stop(self: *UdpReceiver) void {
        if (!self.running.swap(false, .seq_cst)) {
            return; // Not running
        }

        // Close socket to unblock recvfrom()
        if (self.socket_fd != -1) {
            posix.close(self.socket_fd);
            self.socket_fd = -1;
        }

        // Wait for thread to finish
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    /// Check if thread is running
    pub fn isRunning(self: *const UdpReceiver) bool {
        return self.running.load(.seq_cst);
    }

    /// Thread entry point
    fn run(self: *UdpReceiver) void {
        std.log.info("UDP Receiver thread started on port {d}", .{self.port});

        self.runSocketLoop() catch |err| {
            std.log.err("UDP Receiver error: {}", .{err});
        };

        std.log.info("UDP Receiver thread stopped", .{});
    }

    /// Main socket loop
    fn runSocketLoop(self: *UdpReceiver) !void {
        // Create UDP socket
        // AF_INET = IPv4, SOCK_DGRAM = UDP, 0 = default protocol
        self.socket_fd = try posix.socket(
            posix.AF.INET,
            posix.SOCK.DGRAM,
            0,
        );
        errdefer posix.close(self.socket_fd);

        // Set SO_REUSEADDR to allow rebinding to same port quickly
        // This is important for restart scenarios
        try posix.setsockopt(
            self.socket_fd,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );

        // Set receive buffer size to 10MB (critical for burst handling!)
        // Default is ~200KB which can drop packets during burst traffic
        const buffer_size: c_int = 10 * 1024 * 1024; // 10MB
        try posix.setsockopt(
            self.socket_fd,
            posix.SOL.SOCKET,
            posix.SO.RCVBUF,
            &std.mem.toBytes(buffer_size),
        );

        // Verify buffer size was set
        var actual_size: c_int = 0;
        var opt_len: u32 = @sizeOf(c_int);
        try posix.getsockopt(
            self.socket_fd,
            posix.SOL.SOCKET,
            posix.SO.RCVBUF,
            std.mem.asBytes(&actual_size),
            &opt_len,
        );
        std.log.info("UDP socket receive buffer size: {d} bytes", .{actual_size});

        // Bind socket to port
        // sockaddr_in structure for IPv4 address
        var address = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, self.port), // Network byte order!
            .addr = 0, // INADDR_ANY (0.0.0.0) - listen on all interfaces
            .zero = [_]u8{0} ** 8,
        };

        try posix.bind(
            self.socket_fd,
            @ptrCast(&address),
            @sizeOf(posix.sockaddr.in),
        );

        std.log.info("UDP socket bound to 0.0.0.0:{d}", .{self.port});

        // Main receive loop
        while (self.running.load(.monotonic)) {
            // Receive UDP packet
            // recvfrom() blocks until data arrives or socket is closed
            const bytes_received = posix.recvfrom(
                self.socket_fd,
                &self.recv_buffer,
                0, // flags
                null, // sender address (we don't need it)
                null, // sender address length
            ) catch |err| {
                // Socket closed or error
                if (!self.running.load(.monotonic)) {
                    break; // Graceful shutdown
                }
                std.log.err("recvfrom() error: {}", .{err});
                continue;
            };

            if (bytes_received == 0) {
                continue; // Empty packet
            }

            // Process the received data
            const data = self.recv_buffer[0..bytes_received];
            self.handleReceivedData(data);
        }
    }

    /// Handle received UDP data (may contain multiple lines)
    fn handleReceivedData(self: *UdpReceiver, data: []const u8) void {
        // CRITICAL: UDP packets can contain multiple lines!
        // Example from "cat inputFile.csv | netcat -u 127.0.0.1 1234"
        // A single UDP packet might contain:
        //   "N, 1, IBM, 10, 100, B, 1\nN, 2, AAPL, 20, 200, S, 2\n"
        
        var line_iter = std.mem.splitScalar(u8, data, '\n');
        
        while (line_iter.next()) |line| {
            // Skip empty lines
            if (line.len == 0) continue;
            
            // Remove trailing carriage return (Windows line endings: \r\n)
            const trimmed_line = if (line.len > 0 and line[line.len - 1] == '\r')
                line[0 .. line.len - 1]
            else
                line;
            
            if (trimmed_line.len == 0) continue;
            
            // Parse the message
            const msg = message_types.parseInputMessage(trimmed_line) catch |err| {
                // Log parse errors but continue processing
                if (err != error.CommentLine) {
                    std.log.warn("Failed to parse message: {s} (error: {})", .{ trimmed_line, err });
                }
                continue;
            };
            
            // Push to output queue with retry limit
            var retry_count: usize = 0;
            const MAX_RETRIES = 100;
            
            while (!self.output_queue.push(msg)) {
                retry_count += 1;
                if (retry_count >= MAX_RETRIES) {
                    std.log.warn("Input queue full, dropping message!", .{});
                    break;
                }
                std.Thread.yield() catch {};
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "UdpReceiver: create and destroy" {
    var output_queue = LockFreeQueue(InputMessage, 16384).init();
    
    var receiver = UdpReceiver.init(std.testing.allocator, &output_queue, 1234);
    defer receiver.deinit();
    
    try std.testing.expect(!receiver.isRunning());
}

test "UdpReceiver: parse single line" {
    var output_queue = LockFreeQueue(InputMessage, 16384).init();
    
    var receiver = UdpReceiver.init(std.testing.allocator, &output_queue, 1234);
    defer receiver.deinit();
    
    // Simulate received data
    const data = "N, 1, IBM, 10, 100, B, 1\n";
    receiver.handleReceivedData(data);
    
    // Should have parsed message in queue
    const msg = output_queue.pop();
    try std.testing.expect(msg != null);
    try std.testing.expect(msg.? == .new_order);
    try std.testing.expectEqualStrings("IBM", msg.?.new_order.getSymbol());
}

test "UdpReceiver: parse multiple lines in one packet" {
    var output_queue = LockFreeQueue(InputMessage, 16384).init();
    
    var receiver = UdpReceiver.init(std.testing.allocator, &output_queue, 1234);
    defer receiver.deinit();
    
    // Simulate multi-line UDP packet (critical for cat | netcat)
    const data = "N, 1, IBM, 10, 100, B, 1\nN, 2, AAPL, 20, 200, S, 2\nC, 1, 1\n";
    receiver.handleReceivedData(data);
    
    // Should have 3 messages
    try std.testing.expect(output_queue.pop() != null); // New order 1
    try std.testing.expect(output_queue.pop() != null); // New order 2
    try std.testing.expect(output_queue.pop() != null); // Cancel
    try std.testing.expect(output_queue.pop() == null); // No more
}

test "UdpReceiver: handle Windows line endings" {
    var output_queue = LockFreeQueue(InputMessage, 16384).init();
    
    var receiver = UdpReceiver.init(std.testing.allocator, &output_queue, 1234);
    defer receiver.deinit();
    
    // Windows line ending: \r\n
    const data = "N, 1, IBM, 10, 100, B, 1\r\n";
    receiver.handleReceivedData(data);
    
    const msg = output_queue.pop();
    try std.testing.expect(msg != null);
    try std.testing.expect(msg.? == .new_order);
}

test "UdpReceiver: skip empty lines" {
    var output_queue = LockFreeQueue(InputMessage, 16384).init();
    
    var receiver = UdpReceiver.init(std.testing.allocator, &output_queue, 1234);
    defer receiver.deinit();
    
    // Multiple newlines, empty lines
    const data = "\n\nN, 1, IBM, 10, 100, B, 1\n\n";
    receiver.handleReceivedData(data);
    
    // Should have only 1 message
    try std.testing.expect(output_queue.pop() != null);
    try std.testing.expect(output_queue.pop() == null);
}

test "UdpReceiver: skip comment lines" {
    var output_queue = LockFreeQueue(InputMessage, 16384).init();
    
    var receiver = UdpReceiver.init(std.testing.allocator, &output_queue, 1234);
    defer receiver.deinit();
    
    const data = "# This is a comment\nN, 1, IBM, 10, 100, B, 1\n# Another comment\n";
    receiver.handleReceivedData(data);
    
    // Should have only 1 message (comments skipped)
    try std.testing.expect(output_queue.pop() != null);
    try std.testing.expect(output_queue.pop() == null);
}

test "UdpReceiver: handle parse errors gracefully" {
    var output_queue = LockFreeQueue(InputMessage, 16384).init();
    
    var receiver = UdpReceiver.init(std.testing.allocator, &output_queue, 1234);
    defer receiver.deinit();
    
    // Invalid message + valid message
    const data = "INVALID MESSAGE\nN, 1, IBM, 10, 100, B, 1\n";
    receiver.handleReceivedData(data);
    
    // Should skip invalid and process valid
    const msg = output_queue.pop();
    try std.testing.expect(msg != null);
    try std.testing.expect(msg.? == .new_order);
}

test "UdpReceiver: handle queue full scenario" {
    var output_queue = LockFreeQueue(InputMessage, 16384).init();
    
    var receiver = UdpReceiver.init(std.testing.allocator, &output_queue, 1234);
    defer receiver.deinit();
    
    // Fill the queue completely
    for (0..16383) |i| { // 16384 - 1 (one slot reserved)
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
        try std.testing.expect(output_queue.push(.{ .new_order = new_order }));
    }
    
    // Queue should be full now
    try std.testing.expect(output_queue.size() >= 16380);
    
    // Try to add more messages - should log warning and drop
    const data = "N, 1, IBM, 10, 100, B, 1\n";
    receiver.handleReceivedData(data);
    
    // Message should be dropped (queue full)
    // This test just verifies it doesn't crash
}

// Note: Full socket integration test would require actually binding to a port
// and sending UDP packets, which is complex for unit testing.
// We test the parsing logic thoroughly instead.
