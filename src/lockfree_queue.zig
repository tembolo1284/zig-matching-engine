const std = @import("std");

/// Single-Producer Single-Consumer Lock-Free Queue
/// 
/// Design decisions:
/// - Fixed-size ring buffer (must be power of 2 for efficient modulo)
/// - Cache-line padding prevents false sharing between producer/consumer
/// - Lock-free using atomic operations (no mutexes!)
/// - Based on the proven design from your C++ implementation
/// 
/// Performance characteristics:
/// - Push/Pop: ~50-100ns (no syscalls, no locks)
/// - vs Mutex: ~500-1000ns (syscall overhead)
/// 
/// CRITICAL: Default size increased to 16384 to handle UDP bursts
/// (cat file | netcat scenario)
pub fn LockFreeQueue(comptime T: type, comptime size: usize) type {
    // Compile-time validation that size is power of 2
    comptime {
        if (size == 0 or (size & (size - 1)) != 0) {
            @compileError("Queue size must be a power of 2");
        }
    }

    return struct {
        const Self = @This();
        
        // Cache line size (typically 64 bytes on x86_64)
        const CACHE_LINE_SIZE = 64;
        
        // Ring buffer mask for fast modulo: index & MASK instead of index % size
        const MASK = size - 1;

        // Head index (consumer side) - aligned to cache line
        // alignas ensures this is on its own cache line
        head: std.atomic.Value(usize) align(CACHE_LINE_SIZE),
        
        // Padding to prevent false sharing between head and tail
        // This ensures head and tail are on different cache lines
        _pad1: [CACHE_LINE_SIZE - @sizeOf(std.atomic.Value(usize))]u8,
        
        // Tail index (producer side) - aligned to cache line
        tail: std.atomic.Value(usize) align(CACHE_LINE_SIZE),
        
        // Padding after tail
        _pad2: [CACHE_LINE_SIZE - @sizeOf(std.atomic.Value(usize))]u8,
        
        // Ring buffer storage
        buffer: [size]T,

        /// Initialize queue
        pub fn init() Self {
            return Self{
                .head = std.atomic.Value(usize).init(0),
                ._pad1 = undefined,
                .tail = std.atomic.Value(usize).init(0),
                ._pad2 = undefined,
                .buffer = undefined,
            };
        }

        /// Try to push element (returns false if queue is full)
        /// Producer side - called by single producer thread
        pub fn push(self: *Self, item: T) bool {
            const current_tail = self.tail.load(.monotonic);
            const next_tail = (current_tail + 1) & MASK;
            
            // Check if queue is full
            // Queue is full when next_tail would equal head
            if (next_tail == self.head.load(.acquire)) {
                return false;
            }
            
            // Write item to buffer
            self.buffer[current_tail] = item;
            
            // Update tail (release ensures buffer write is visible before tail update)
            self.tail.store(next_tail, .release);
            return true;
        }

        /// Try to pop element (returns null if queue is empty)
        /// Consumer side - called by single consumer thread
        pub fn pop(self: *Self) ?T {
            const current_head = self.head.load(.monotonic);
            
            // Check if queue is empty
            // Queue is empty when head equals tail
            if (current_head == self.tail.load(.acquire)) {
                return null;
            }
            
            // Read item from buffer
            const item = self.buffer[current_head];
            
            // Update head (release ensures we won't read this slot again)
            self.head.store((current_head + 1) & MASK, .release);
            return item;
        }

        /// Check if queue is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.head.load(.acquire) == self.tail.load(.acquire);
        }

        /// Get approximate size (may be stale due to concurrent access)
        pub fn size(self: *const Self) usize {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);
            return (t -% h) & MASK; // Wrapping subtraction handles wraparound
        }

        /// Get capacity
        pub fn capacity() usize {
            return size;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "LockFreeQueue: basic push and pop" {
    var queue = LockFreeQueue(u32, 8).init();

    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));

    try std.testing.expectEqual(@as(?u32, 1), queue.pop());
    try std.testing.expectEqual(@as(?u32, 2), queue.pop());
    try std.testing.expectEqual(@as(?u32, 3), queue.pop());
    try std.testing.expectEqual(@as(?u32, null), queue.pop());
}

test "LockFreeQueue: push until full" {
    var queue = LockFreeQueue(u32, 4).init();

    // Size 4 means we can store 3 items (one slot reserved for full/empty detection)
    try std.testing.expect(queue.push(1));
    try std.testing.expect(queue.push(2));
    try std.testing.expect(queue.push(3));
    
    // Queue should be full now
    try std.testing.expect(!queue.push(4));
    
    // Pop one item
    try std.testing.expectEqual(@as(?u32, 1), queue.pop());
    
    // Now we can push again
    try std.testing.expect(queue.push(4));
}

test "LockFreeQueue: isEmpty" {
    var queue = LockFreeQueue(u32, 8).init();

    try std.testing.expect(queue.isEmpty());
    
    try std.testing.expect(queue.push(1));
    try std.testing.expect(!queue.isEmpty());
    
    _ = queue.pop();
    try std.testing.expect(queue.isEmpty());
}

test "LockFreeQueue: size tracking" {
    var queue = LockFreeQueue(u32, 8).init();

    try std.testing.expectEqual(@as(usize, 0), queue.size());
    
    try std.testing.expect(queue.push(1));
    try std.testing.expectEqual(@as(usize, 1), queue.size());
    
    try std.testing.expect(queue.push(2));
    try std.testing.expectEqual(@as(usize, 2), queue.size());
    
    _ = queue.pop();
    try std.testing.expectEqual(@as(usize, 1), queue.size());
    
    _ = queue.pop();
    try std.testing.expectEqual(@as(usize, 0), queue.size());
}

test "LockFreeQueue: wraparound" {
    var queue = LockFreeQueue(u32, 4).init();

    // Fill and drain multiple times to test wraparound
    for (0..10) |i| {
        const val: u32 = @intCast(i);
        try std.testing.expect(queue.push(val));
        try std.testing.expectEqual(@as(?u32, val), queue.pop());
    }
}

test "LockFreeQueue: capacity" {
    const Q1 = LockFreeQueue(u32, 8);
    const Q2 = LockFreeQueue(u32, 16384);
    
    try std.testing.expectEqual(@as(usize, 8), Q1.capacity());
    try std.testing.expectEqual(@as(usize, 16384), Q2.capacity());
}

test "LockFreeQueue: with complex type" {
    const Message = struct {
        id: u32,
        value: u64,
    };
    
    var queue = LockFreeQueue(Message, 8).init();
    
    try std.testing.expect(queue.push(.{ .id = 1, .value = 100 }));
    try std.testing.expect(queue.push(.{ .id = 2, .value = 200 }));
    
    const msg1 = queue.pop().?;
    try std.testing.expectEqual(@as(u32, 1), msg1.id);
    try std.testing.expectEqual(@as(u64, 100), msg1.value);
    
    const msg2 = queue.pop().?;
    try std.testing.expectEqual(@as(u32, 2), msg2.id);
    try std.testing.expectEqual(@as(u64, 200), msg2.value);
}

test "LockFreeQueue: stress test - many operations" {
    var queue = LockFreeQueue(u32, 1024).init();
    
    // Push many items
    for (0..500) |i| {
        const val: u32 = @intCast(i);
        try std.testing.expect(queue.push(val));
    }
    
    // Pop them all in order
    for (0..500) |i| {
        const expected: u32 = @intCast(i);
        try std.testing.expectEqual(@as(?u32, expected), queue.pop());
    }
    
    // Queue should be empty
    try std.testing.expect(queue.isEmpty());
}

test "LockFreeQueue: alternating push/pop" {
    var queue = LockFreeQueue(u32, 8).init();
    
    for (0..100) |i| {
        const val: u32 = @intCast(i);
        try std.testing.expect(queue.push(val));
        try std.testing.expectEqual(@as(?u32, val), queue.pop());
    }
    
    try std.testing.expect(queue.isEmpty());
}

test "LockFreeQueue: compile-time size validation" {
    // These should compile fine (powers of 2)
    _ = LockFreeQueue(u32, 2);
    _ = LockFreeQueue(u32, 4);
    _ = LockFreeQueue(u32, 8);
    _ = LockFreeQueue(u32, 16384);
    
    // These would fail at compile-time (not powers of 2):
    // _ = LockFreeQueue(u32, 0);    // @compileError
    // _ = LockFreeQueue(u32, 3);    // @compileError
    // _ = LockFreeQueue(u32, 100);  // @compileError
}

test "LockFreeQueue: memory layout verification" {
    const Q = LockFreeQueue(u32, 16);
    
    // Print layout for documentation
    std.debug.print("\nQueue memory layout:\n", .{});
    std.debug.print("  Size of queue: {d} bytes\n", .{@sizeOf(Q)});
    std.debug.print("  Alignment: {d} bytes\n", .{@alignOf(Q)});
    std.debug.print("  Head offset: {d}\n", .{@offsetOf(Q, "head")});
    std.debug.print("  Tail offset: {d}\n", .{@offsetOf(Q, "tail")});
    std.debug.print("  Buffer offset: {d}\n", .{@offsetOf(Q, "buffer")});
    
    // Verify cache-line alignment
    try std.testing.expect(@offsetOf(Q, "head") % 64 == 0);
    try std.testing.expect(@offsetOf(Q, "tail") % 64 == 0);
}
