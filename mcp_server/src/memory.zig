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
    arenas: std.ArrayList(RequestArena),
    available: std.ArrayList(usize),
    mutex: std.Thread.Mutex,
    parent_allocator: std.mem.Allocator,

    pub fn init(parent_allocator: std.mem.Allocator, initial_size: usize) !ArenaPool {
        var pool = ArenaPool{
            .arenas = std.ArrayList(RequestArena).init(parent_allocator),
            .available = std.ArrayList(usize).init(parent_allocator),
            .mutex = .{},
            .parent_allocator = parent_allocator,
        };

        // Pre-allocate initial arenas
        for (0..initial_size) |i| {
            try pool.arenas.append(RequestArena.init(parent_allocator));
            try pool.available.append(i);
        }

        return pool;
    }

    pub fn deinit(self: *ArenaPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.arenas.items) |*arena| {
            arena.deinit();
        }
        self.arenas.deinit();
        self.available.deinit();
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
        try self.arenas.append(RequestArena.init(self.parent_allocator));
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
                try self.available.append(i);
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
