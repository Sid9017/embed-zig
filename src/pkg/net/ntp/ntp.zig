//! Cross-Platform NTP Client
//!
//! Simple NTP (Network Time Protocol) client using UDP.
//! Returns server timestamps for user to calculate time offset.
//!
//! Security features (RFC 5905):
//! - Origin Timestamp validation (prevents response spoofing)
//! - Source IP validation (if socket supports recvFromWithAddr)
//! - High-entropy nonce support (use generateNonce with RNG)
//!
//! Example (basic):
//!   const ntp = @import("ntp");
//!
//!   const Client = ntp.Client(Socket);
//!   var client = Client{ .server = .{ 162, 159, 200, 1 } }; // time.cloudflare.com
//!
//!   const t1 = Board.time.nowMs();
//!   const resp = try client.query(@intCast(t1));
//!   const t4 = Board.time.nowMs();
//!
//!   // Calculate offset: ((T2 - T1) + (T3 - T4)) / 2
//!   const offset = @divFloor((resp.receive_time_ms - @as(i64, @intCast(t1))) +
//!                            (resp.transmit_time_ms - @as(i64, @intCast(t4))), 2);
//!   const current_epoch_ms = @as(i64, @intCast(t4)) + offset;
//!
//! Example (with RNG for enhanced security):
//!   const nonce = ntp.generateNonce(Rng);  // Use hardware RNG for unpredictable nonce
//!   const resp = try client.query(nonce);

const std = @import("std");
const runtime = struct {
    pub const socket = @import("../../../runtime/socket.zig");
    pub const std = @import("../../../runtime/std.zig");
};

pub const Ipv4Address = [4]u8;

/// NTP port
pub const NTP_PORT: u16 = 123;

/// Seconds between NTP epoch (1900-01-01) and Unix epoch (1970-01-01)
pub const NTP_UNIX_OFFSET: i64 = 2208988800;

/// Generate a high-entropy nonce for NTP queries (RFC 5905 security)
///
/// Use this instead of monotonic time when hardware RNG is available.
/// This makes the Origin Timestamp unpredictable, preventing off-path spoofing.
///
/// Example:
///   const nonce = ntp.generateNonce(Board.crypto.Rng);
///   const resp = try client.query(nonce);
pub fn generateNonce(comptime Rng: type) i64 {
    var buf: [8]u8 = undefined;
    Rng.fill(&buf);
    // Convert to i64, ensure non-zero (0 is reserved)
    const raw = std.mem.readInt(i64, &buf, .little);
    return if (raw == 0) 1 else raw;
}

pub const NtpError = error{
    SocketError,
    SendFailed,
    RecvFailed,
    Timeout,
    InvalidResponse,
    KissOfDeath,
    /// Origin Timestamp mismatch - possible spoofing attack (RFC 5905)
    OriginMismatch,
    /// Source IP/port mismatch - response from unexpected server (RFC 5905)
    SourceMismatch,
};

/// NTP query response containing server timestamps
pub const Response = struct {
    /// T2: Server receive timestamp (Unix epoch milliseconds)
    receive_time_ms: i64,
    /// T3: Server transmit timestamp (Unix epoch milliseconds)
    transmit_time_ms: i64,
    /// Server stratum (1 = primary, 2-15 = secondary)
    stratum: u8,
    /// Round-trip delay estimate in milliseconds (T4 - T1, set by caller)
    round_trip_ms: u64 = 0,
};

/// Well-known NTP servers
pub const Servers = struct {
    // Global providers
    /// time.cloudflare.com - anycast, global
    pub const cloudflare: Ipv4Address = .{ 162, 159, 200, 1 };
    /// time.google.com
    pub const google: Ipv4Address = .{ 216, 239, 35, 0 };
    /// time2.google.com
    pub const google2: Ipv4Address = .{ 216, 239, 35, 4 };
    /// time3.google.com
    pub const google3: Ipv4Address = .{ 216, 239, 35, 8 };
    /// time4.google.com
    pub const google4: Ipv4Address = .{ 216, 239, 35, 12 };
    /// time.apple.com
    pub const apple: Ipv4Address = .{ 17, 253, 34, 123 };
    /// time.windows.com
    pub const microsoft: Ipv4Address = .{ 20, 101, 57, 9 };
    /// time.nist.gov (US NIST)
    pub const nist: Ipv4Address = .{ 129, 6, 15, 28 };

    // China providers
    /// ntp.aliyun.com
    pub const aliyun: Ipv4Address = .{ 203, 107, 6, 88 };
    /// ntp.tencent.com
    pub const tencent: Ipv4Address = .{ 111, 230, 189, 174 };
    /// ntp.ntsc.ac.cn (中科院国家授时中心)
    pub const ntsc: Ipv4Address = .{ 114, 118, 7, 161 };
};

/// Preset server lists for different network environments
pub const ServerLists = struct {
    /// Global - works in most regions (recommended default)
    pub const global = [_]Ipv4Address{
        Servers.cloudflare,
        Servers.google,
        Servers.aliyun,
    };

    /// China optimized - Chinese servers first
    pub const china = [_]Ipv4Address{
        Servers.aliyun,
        Servers.tencent,
        Servers.ntsc,
        Servers.cloudflare,
    };

    /// Overseas optimized - global providers
    pub const overseas = [_]Ipv4Address{
        Servers.cloudflare,
        Servers.google,
        Servers.google2,
        Servers.google3,
        Servers.google4,
        Servers.apple,
    };
};

/// NTP Client - generic over socket type
///
/// Type parameters:
///   - `Socket`: must satisfy `runtime.socket.from` contract
pub fn Client(comptime Socket: type) type {
    comptime _ = runtime.socket.is(Socket);

    return struct {
        const Self = @This();

        /// NTP server address
        server: Ipv4Address = Servers.cloudflare,

        /// Timeout in milliseconds
        timeout_ms: u32 = 5000,

        /// Query NTP server and return timestamps
        ///
        /// User should record local time before calling (T1) and after receiving (T4)
        /// to calculate precise time offset.
        ///
        /// Security features (RFC 5905):
        /// - Origin Timestamp validation (always enabled)
        /// - Source IP/port validation (always enabled via recvFrom)
        ///
        /// Args:
        ///   t1_local_ms: Local monotonic time when starting query (for origin timestamp)
        ///
        /// Returns:
        ///   Response containing server receive (T2) and transmit (T3) timestamps
        pub fn query(self: *const Self, t1_local_ms: i64) NtpError!Response {
            var sock = Socket.udp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);

            const origin_time = if (t1_local_ms != 0) t1_local_ms else 1;
            const expected_origin = unixMsToNtp(origin_time);

            var request: [48]u8 = undefined;
            buildRequest(&request, origin_time);

            _ = sock.sendTo(self.server, NTP_PORT, &request) catch return error.SendFailed;

            var response: [48]u8 = undefined;
            const result = sock.recvFrom(&response) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.RecvFailed,
                };
            };
            if (result.len < 48) return error.InvalidResponse;

            if (!std.mem.eql(u8, &result.src_addr, &self.server) or result.src_port != NTP_PORT) {
                return error.SourceMismatch;
            }

            return parseResponse(&response, expected_origin);
        }

        /// Simple time query - returns current Unix epoch milliseconds
        ///
        /// This is a convenience method that uses T3 (transmit time) directly.
        /// For higher precision, use query() and calculate offset manually.
        pub fn getTime(self: *const Self, local_time_ms: i64) NtpError!i64 {
            const resp = try self.query(local_time_ms);
            return resp.transmit_time_ms;
        }

        /// Query multiple servers simultaneously, return first response
        ///
        /// Sends NTP requests to all servers at once and returns the first
        /// valid response. This is useful for devices that need to work in
        /// different network environments (e.g., China vs overseas).
        ///
        /// The fastest responding server wins - no location detection needed.
        ///
        /// Security features (RFC 5905):
        /// - Origin Timestamp validation (always enabled)
        /// - Source IP/port validation (always enabled via recvFrom)
        pub fn queryRace(self: *const Self, t1_local_ms: i64, servers: []const Ipv4Address) NtpError!Response {
            if (servers.len == 0) return error.InvalidResponse;

            var sock = Socket.udp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);

            const origin_time = if (t1_local_ms != 0) t1_local_ms else 1;
            const expected_origin = unixMsToNtp(origin_time);

            var request: [48]u8 = undefined;
            buildRequest(&request, origin_time);

            var sent_count: usize = 0;
            for (servers) |server| {
                if (sock.sendTo(server, NTP_PORT, &request)) |_| {
                    sent_count += 1;
                } else |_| {}
            }

            if (sent_count == 0) return error.SendFailed;

            const max_retries: u32 = 10;
            const max_unknown: u32 = 50;
            var response: [48]u8 = undefined;
            var retry_count: u32 = 0;
            var unknown_count: u32 = 0;

            while (retry_count < max_retries and unknown_count < max_unknown) {
                const result = sock.recvFrom(&response) catch |err| {
                    return switch (err) {
                        error.Timeout => error.Timeout,
                        else => error.RecvFailed,
                    };
                };

                var from_expected_server = false;
                for (servers) |server| {
                    if (std.mem.eql(u8, &result.src_addr, &server) and result.src_port == NTP_PORT) {
                        from_expected_server = true;
                        break;
                    }
                }

                if (!from_expected_server) {
                    unknown_count += 1;
                    continue;
                }

                if (result.len < 48) {
                    retry_count += 1;
                    continue;
                }

                if (parseResponse(&response, expected_origin)) |resp| {
                    return resp;
                } else |_| {
                    retry_count += 1;
                    continue;
                }
            }

            return error.InvalidResponse;
        }

        /// Simple race query - returns time using global server list
        pub fn getTimeRace(self: *const Self, local_time_ms: i64) NtpError!i64 {
            const resp = try self.queryRace(local_time_ms, &ServerLists.global);
            return resp.transmit_time_ms;
        }
    };
}

/// Build NTP request packet (48 bytes)
pub fn buildRequest(buf: *[48]u8, origin_time_ms: i64) void {
    @memset(buf, 0);

    // LI (0) | VN (4) | Mode (3 = client)
    // LI = 0 (no warning), VN = 4 (NTPv4), Mode = 3 (client)
    buf[0] = 0b00_100_011; // 0x23

    // Stratum: 0 (unspecified)
    buf[1] = 0;

    // Poll interval: 6 (2^6 = 64 seconds)
    buf[2] = 6;

    // Precision: -20 (about 1 microsecond)
    buf[3] = 0xEC; // -20 as signed byte

    // Root delay, root dispersion, reference ID: leave as 0

    // Reference timestamp: leave as 0

    // Origin timestamp: leave as 0 (RFC 5905)
    // Receive timestamp: leave as 0 (RFC 5905)

    // Transmit timestamp (T1): client's departure time (RFC 5905)
    // Server will copy this to Origin Timestamp in response for validation
    if (origin_time_ms != 0) {
        const ntp_ts = unixMsToNtp(origin_time_ms);
        writeTimestamp(buf[40..48], ntp_ts);
    }
}

/// Parse NTP response packet
/// Validates that the response's Origin Timestamp matches what we sent in Transmit Timestamp
/// (RFC 5905 security - server echoes back our Transmit Timestamp in Origin field)
pub fn parseResponse(buf: *const [48]u8, expected_origin: NtpTimestamp) NtpError!Response {
    // Check LI (Leap Indicator) - if 3, server is not synchronized
    const li = (buf[0] >> 6) & 0x03;
    if (li == 3) return error.InvalidResponse;

    // Check mode - should be 4 (server) or 5 (broadcast)
    const mode = buf[0] & 0x07;
    if (mode != 4 and mode != 5) return error.InvalidResponse;

    // IMPORTANT: Validate Origin Timestamp BEFORE checking stratum/KoD (RFC 5905 security)
    // This prevents off-path attackers from sending spoofed KoD packets
    // Server must echo back our Transmit Timestamp in the Origin field
    const origin = readTimestamp(buf[24..32]);
    // Compare against truncated value since wire format is u32
    // This handles generateNonce() returning large i64 values correctly
    const expected_secs_truncated: i64 = @as(i64, @as(u32, @truncate(@as(u64, @bitCast(expected_origin.seconds)))));
    if (origin.seconds != expected_secs_truncated or origin.fraction != expected_origin.fraction) {
        return error.OriginMismatch;
    }

    // Check stratum (after origin validation to prevent spoofed KoD attacks)
    const stratum = buf[1];
    if (stratum == 0) {
        // Kiss-o'-Death packet - server is telling us to go away
        return error.KissOfDeath;
    }

    // Parse receive timestamp (T2) - bytes 32-39
    const t2_ntp = readTimestamp(buf[32..40]);
    const t2_unix_ms = ntpToUnixMs(t2_ntp);

    // Parse transmit timestamp (T3) - bytes 40-47
    const t3_ntp = readTimestamp(buf[40..48]);
    const t3_unix_ms = ntpToUnixMs(t3_ntp);

    return .{
        .receive_time_ms = t2_unix_ms,
        .transmit_time_ms = t3_unix_ms,
        .stratum = stratum,
    };
}

/// NTP timestamp (internal representation using i64 to avoid Y2036 overflow)
/// Wire format uses 32-bit unsigned, but we store as i64 for extended range
pub const NtpTimestamp = struct {
    seconds: i64,
    fraction: u32,
};

/// Read NTP timestamp from buffer (big-endian)
/// Wire format is u32, but we extend to i64 to handle Y2036+ timestamps
pub fn readTimestamp(buf: *const [8]u8) NtpTimestamp {
    return .{
        .seconds = @as(i64, std.mem.readInt(u32, buf[0..4], .big)),
        .fraction = std.mem.readInt(u32, buf[4..8], .big),
    };
}

/// Write NTP timestamp to buffer (big-endian)
/// Truncates to u32 for wire format (handles nonce values safely)
pub fn writeTimestamp(buf: *[8]u8, ts: NtpTimestamp) void {
    // Use @truncate to safely handle large values from generateNonce()
    // This preserves the lower 32 bits which is all that matters for NTP wire format
    std.mem.writeInt(u32, buf[0..4], @truncate(@as(u64, @bitCast(ts.seconds))), .big);
    std.mem.writeInt(u32, buf[4..8], ts.fraction, .big);
}

/// Convert NTP timestamp to Unix milliseconds
pub fn ntpToUnixMs(ntp: NtpTimestamp) i64 {
    // NTP seconds since 1900 -> Unix seconds since 1970
    const unix_secs: i64 = ntp.seconds - NTP_UNIX_OFFSET;
    // Fraction to milliseconds: fraction * 1000 / 2^32
    const ms: i64 = (@as(i64, ntp.fraction) * 1000) >> 32;
    return unix_secs * 1000 + ms;
}

/// Convert Unix milliseconds to NTP timestamp
pub fn unixMsToNtp(unix_ms: i64) NtpTimestamp {
    const unix_secs = @divFloor(unix_ms, 1000);
    const ms = @mod(unix_ms, 1000);

    // Unix seconds -> NTP seconds (stored as i64)
    const ntp_secs: i64 = unix_secs + NTP_UNIX_OFFSET;
    // Milliseconds to fraction: ms * 2^32 / 1000
    const fraction: u32 = @intCast((@as(u64, @intCast(ms)) << 32) / 1000);

    return .{
        .seconds = ntp_secs,
        .fraction = fraction,
    };
}

/// Format Unix epoch milliseconds as ISO 8601 string
/// Uses std.time.epoch for robust date/time calculation
pub fn formatTime(epoch_ms: i64, buf: []u8) []const u8 {
    const secs = @divFloor(epoch_ms, 1000);

    // Guard against negative timestamps (pre-1970) which std.time.epoch doesn't handle
    if (secs < 0) return "????-??-??T??:??:??Z";

    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day_seconds = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();

    // Get month and day from year_day
    const month_day = year_day.calculateMonthDay();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch "????-??-??T??:??:??Z";
}

// ============================================================================
// Tests
// ============================================================================

// ============================================================================
// Real Network Tests (using runtime.std.Socket)
// ============================================================================

pub fn nowMs() i64 {
    return @intCast(@divFloor(std.time.nanoTimestamp(), 1_000_000));
}
