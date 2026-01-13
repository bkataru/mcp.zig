const std = @import("std");

/// Arena-based memory management for request/response cycles
pub const RequestArena = struct {
    arena: std.heap.ArenaAllocator,
    parent_allocator: std.mem.Allocator,

    pub fn init(parent_allocator: std.mem.Allocator) RequestArena {
        return RequestArena{
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
            .parent_allocator = parent_allocator,
        };
    }

    pub fn deinit(self: *RequestArena) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *RequestArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Reset arena for next request - frees all allocated memory
    pub fn reset(self: *RequestArena) void {
        _ = self.arena.reset(.retain_capacity);
    }
};

/// Pool of arena allocators for handling concurrent requests
pub const ArenaPool = struct {
    arenas: std.ArrayListUnmanaged(RequestArena),
    available: std.ArrayListUnmanaged(usize),
    mutex: std.Thread.Mutex,
    parent_allocator: std.mem.Allocator,

    pub fn init(parent_allocator: std.mem.Allocator, initial_size: usize) !ArenaPool {
        var arenas = std.ArrayListUnmanaged(RequestArena){};
        var available = std.ArrayListUnmanaged(usize){};

        // Pre-allocate initial arenas
        for (0..initial_size) |i| {
            try arenas.append(parent_allocator, RequestArena.init(parent_allocator));
            try available.append(parent_allocator, i);
        }

        return ArenaPool{
            .arenas = arenas,
            .available = available,
            .mutex = .{},
            .parent_allocator = parent_allocator,
        };
    }

    pub fn deinit(self: *ArenaPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.arenas.items) |*arena| {
            arena.deinit();
        }
        self.arenas.deinit(self.parent_allocator);
        self.available.deinit(self.parent_allocator);
    }

    /// Acquire an arena from the pool
    pub fn acquire(self: *ArenaPool) !*RequestArena {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.available.items.len > 0) {
            const index = self.available.orderedRemove(self.available.items.len - 1);
            return &self.arenas.items[index];
        }

        // No available arenas, create a new one
        const index = self.arenas.items.len;
        try self.arenas.append(self.parent_allocator, RequestArena.init(self.parent_allocator));
        return &self.arenas.items[index];
    }

    /// Release an arena back to the pool
    pub fn release(self: *ArenaPool, arena: *RequestArena) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Reset the arena to free all allocated memory
        arena.reset();

        // Find the index of this arena
        for (self.arenas.items, 0..) |*pool_arena, i| {
            if (pool_arena == arena) {
                try self.available.append(self.parent_allocator, i);
                return;
            }
        }

        // This should never happen
        std.log.err("Attempted to release unknown arena", .{});
    }
};

/// Scoped arena that automatically releases on scope exit
pub const ScopedArena = struct {
    arena: *RequestArena,
    pool: *ArenaPool,

    pub fn init(pool: *ArenaPool) !ScopedArena {
        const arena = try pool.acquire();
        return ScopedArena{
            .arena = arena,
            .pool = pool,
        };
    }

    pub fn deinit(self: *ScopedArena) void {
        self.pool.release(self.arena) catch |err| {
            std.log.err("Failed to release arena: {any}", .{err});
        };
    }

    pub fn allocator(self: *ScopedArena) std.mem.Allocator {
        return self.arena.allocator();
    }
};

/// Memory statistics for monitoring
pub const MemoryStats = struct {
    total_allocations: u64 = 0,
    total_deallocations: u64 = 0,
    peak_memory_usage: usize = 0,
    current_memory_usage: usize = 0,
    arena_pool_size: usize = 0,
    available_arenas: usize = 0,

    pub fn update(self: *MemoryStats, pool: *ArenaPool) void {
        pool.mutex.lock();
        defer pool.mutex.unlock();

        self.arena_pool_size = pool.arenas.items.len;
        self.available_arenas = pool.available.items.len;

        // Calculate current memory usage from active arenas
        var current_usage: usize = 0;
        for (pool.arenas.items) |*arena| {
            // This is an approximation since ArenaAllocator doesn't expose exact usage
            current_usage += arena.arena.queryCapacity();
        }

        self.current_memory_usage = current_usage;
        if (current_usage > self.peak_memory_usage) {
            self.peak_memory_usage = current_usage;
        }
    }

    pub fn print(self: *const MemoryStats) void {
        std.log.info("Memory Statistics:", .{});
        std.log.info("  Arena Pool Size: {d}", .{self.arena_pool_size});
        std.log.info("  Available Arenas: {d}", .{self.available_arenas});
        std.log.info("  Current Memory Usage: {d} bytes", .{self.current_memory_usage});
        std.log.info("  Peak Memory Usage: {d} bytes", .{self.peak_memory_usage});
        std.log.info("  Total Allocations: {d}", .{self.total_allocations});
        std.log.info("  Total Deallocations: {d}", .{self.total_deallocations});
    }
};

/// Thread-safe memory statistics tracker
pub const MemoryTracker = struct {
    stats: MemoryStats,
    mutex: std.Thread.Mutex,

    pub fn init() MemoryTracker {
        return MemoryTracker{
            .stats = MemoryStats{},
            .mutex = .{},
        };
    }

    pub fn recordAllocation(self: *MemoryTracker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stats.total_allocations += 1;
    }

    pub fn recordDeallocation(self: *MemoryTracker) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stats.total_deallocations += 1;
    }

    pub fn updateStats(self: *MemoryTracker, pool: *ArenaPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stats.update(pool);
    }

    pub fn getStats(self: *MemoryTracker) MemoryStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    pub fn printStats(self: *MemoryTracker) void {
        const stats = self.getStats();
        stats.print();
    }
};

// ==================== Tests ====================

test "RequestArena basic operations" {
    const allocator = std.testing.allocator;
    var arena = RequestArena.init(allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    const slice = try alloc.alloc(u8, 10);
    defer alloc.free(slice);

    try std.testing.expectEqual(@as(usize, 10), slice.len);
}

test "RequestArena reset" {
    const allocator = std.testing.allocator;
    var arena = RequestArena.init(allocator);
    defer arena.deinit();

    const alloc = arena.allocator();
    const slice1 = try alloc.alloc(u8, 100);
    const slice2 = try alloc.alloc(u8, 50);
    _ = slice1;
    _ = slice2;

    arena.reset();

    const slice3 = try alloc.alloc(u8, 200);
    defer alloc.free(slice3);

    try std.testing.expectEqual(@as(usize, 200), slice3.len);
}

test "ScopedArena acquire and release" {
    const allocator = std.testing.allocator;
    var pool = try ArenaPool.init(allocator, 2);
    defer pool.deinit();

    {
        var scoped = try ScopedArena.init(&pool);
        defer scoped.deinit();

        const alloc = scoped.allocator();
        const slice = try alloc.alloc(u8, 50);
        defer alloc.free(slice);

        try std.testing.expectEqual(@as(usize, 50), slice.len);
    }

    try std.testing.expectEqual(@as(usize, 2), pool.arenas.items.len);
    try std.testing.expectEqual(@as(usize, 2), pool.available.items.len);
}

test "MemoryTracker" {
    var tracker = MemoryTracker.init();

    try std.testing.expectEqual(@as(u64, 0), tracker.stats.total_allocations);

    tracker.recordAllocation();
    try std.testing.expectEqual(@as(u64, 1), tracker.stats.total_allocations);

    tracker.recordDeallocation();
    try std.testing.expectEqual(@as(u64, 1), tracker.stats.total_deallocations);
}

test "ArenaPool init" {
    const allocator = std.testing.allocator;
    var pool = try ArenaPool.init(allocator, 4);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 4), pool.arenas.items.len);
    try std.testing.expectEqual(@as(usize, 4), pool.available.items.len);
}

test "ArenaPool acquire and release" {
    const allocator = std.testing.allocator;
    var pool = try ArenaPool.init(allocator, 2);
    defer pool.deinit();

    const arena1 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 1), pool.available.items.len);

    const arena2 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 0), pool.available.items.len);

    try pool.release(arena1);
    try std.testing.expectEqual(@as(usize, 1), pool.available.items.len);

    try pool.release(arena2);
    try std.testing.expectEqual(@as(usize, 2), pool.available.items.len);
}
