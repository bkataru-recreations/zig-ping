const std = @import("std");
const net = std.net;
const os = std.os;
const time = std.time;
const print = std.debug.print;
const Thread = std.Thread;
const Atomic = std.atomic.Atomic;
const Mutex = Thread.Mutex;

const HostResult = struct {
    ip: []const u8,
    is_alive: bool,
    open_ports: std.ArrayList(u16),
    mutex: Mutex,

    fn init(allocator: std.mem.Allocator, ip: []const u8) !*HostResult {
        const result = try allocator.create(HostResult);
        result.* = .{
            .ip = try allocator.dupe(u8, ip),
            .is_alive = false,
            .open_ports = std.ArrayList(u16).init(allocator),
            .mutex = .{},
        };
        return result;
    }

    fn deinit(self: *HostResult, allocator: std.mem.Allocator) void {
        allocator.free(self.ip);
        self.open_ports.deinit();
        allocator.destroy(self);
    }
};

const WorkQueue = struct {
    mutex: Mutex = .{},
    hosts: std.ArrayList(*HostResult),
    current_index: usize = 0,

    fn init(allocator: std.mem.Allocator) WorkQueue {
        return .{
            .hosts = std.ArrayList(*HostResult).init(allocator),
        };
    }

    fn deinit(self: *WorkQueue) void {
        self.hosts.deinit();
    }

    fn addHost(self: *WorkQueue, host: *HostResult) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.hosts.append(host);
    }

    fn getNextHost(self: *WorkQueue) ?*HostResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.current_index >= self.hosts.items.len) return null;
        const host = self.hosts.items[self.current_index];
        self.current_index += 1;
        return host;
    }
};

const Config = struct {
    start_ip: [4]u8,
    end_ip: [4]u8,
    timeout_ms: u32 = 1000,
    start_port: u16 = 1,
    end_port: u16 = 1024,
    thread_count: u8 = 4,
};

fn ipToString(ip: [4]u8) ![16]u8 {
    var buf: [16]u8 = undefined;
    _ = try std.fmt.bufPrint(&buf, "{}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });
    return buf;
}

fn incrementIP(ip: *[4]u8) void {
    var i: i32 = 3;
    while (i >= 0) : (i -= 1) {
        ip[i] +%= 1;
        if (ip[i] != 0) break;
    }
}

fn ipInRange(ip: [4]u8, start: [4]u8, end: [4]u8) bool {
    const ip_val = @as(u32, ip[0]) << 24 | @as(u32, ip[1]) << 16 | @as(u32, ip[2]) << 8 | @as(u32, ip[3]);
    const start_val = @as(u32, start[0]) << 24 | @as(u32, start[1]) << 16 | @as(u32, start[2]) << 8 | @as(u32, start[3]);
    const end_val = @as(u32, end[0]) << 24 | @as(u32, end[1]) << 16 | @as(u32, end[2]) << 8 | @as(u32, end[3]);
    return ip_val >= start_val and ip_val <= end_val;
}

fn pingHost(host: *HostResult) !void {
    const sock = try net.tcpConnectToHost(std.heap.page_allocator, host.ip, 7);
    defer sock.close();

    // If we get here, host is alive
    host.mutex.lock();
    defer host.mutex.unlock();
    host.is_alive = true;
}

fn scanPort(host: *HostResult, port: u16) !void {
    const sock = net.tcpConnectToHost(std.heap.page_allocator, host.ip, port) catch |err| {
        if (err == error.ConnectionRefused) return;
        return err;
    };
    defer sock.close();

    // If we get here, port is open
    host.mutex.lock();
    defer host.mutex.unlock();
    try host.open_ports.append(port);
}

fn worker(queue: *WorkQueue, config: *const Config) void {
    while (true) {
        const host = queue.getNextHost() orelse break;

        // Try to ping the host
        pingHost(host) catch continue;

        // If host is alive, scan ports
        if (host.is_alive) {
            var port = config.start_port;
            while (port <= config.end_port) : (port += 1) {
                scanPort(host, port) catch continue;
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config{
        .start_ip = .{ 192, 168, 1, 1 },
        .end_ip = .{ 192, 168, 1, 254 },
        .timeout_ms = 1000,
        .start_port = 1,
        .end_port = 1024,
        .thread_count = 4,
    };

    var queue = WorkQueue.init(allocator);
    defer queue.deinit();

    // Create host results for IP range
    var current_ip = config.start_ip;
    while (ipInRange(current_ip, config.start_ip, config.end_ip)) {
        const ip_str = try ipToString(current_ip);
        const host = try HostResult.init(allocator, &ip_str);
        try queue.addHost(host);
        incrementIP(&current_ip);
    }

    print("Starting scan of {d} hosts...\n", .{queue.hosts.items.len});
    print("Port range: {d}-{d}\n", .{ config.start_port, config.end_port });

    // Spawn worker threads
    var threads = try allocator.alloc(Thread, config.thread_count);
    defer allocator.free(threads);

    for (0..config.thread_count) |i| {
        threads[i] = try Thread.spawn(.{}, worker, .{ &queue, &config });
    }

    // Wait for all threads to complete
    for (threads) |thread| {
        thread.join();
    }

    // Print results
    print("\nScan Results:\n", .{});
    print("-----------------\n", .{});

    for (queue.hosts.items) |host| {
        if (host.is_alive) {
            print("Host {s} is up!\n", .{host.ip});
            if (host.open_ports.items.len > 0) {
                print("Open ports: ", .{});
                for (host.open_ports.items) |port| {
                    print("{d} ", .{port});
                }
                print("\n", .{});
            }
        }
        host.deinit(allocator);
    }
}
