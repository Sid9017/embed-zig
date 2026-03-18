//! chunk — BLE X-Protocol chunk encoding and bitmask utilities
//!
//! Provides chunk header encode/decode, control message handling,
//! and bitmask operations for the READ_X / WRITE_X protocols.
//!
//! ## Chunk Header Format (3 bytes)
//!
//! ```
//! Byte 0:    [total_hi 8bit]
//! Byte 1:    [total_lo 4bit][seq_hi 4bit]
//! Byte 2:    [seq_lo 8bit]
//!
//! total = 12 bit → max 4095 chunks
//! seq   = 12 bit → 1-based (1 to total)
//! ```
//!
//! ## Control Messages
//!
//! | Message     | Format              | Meaning                    |
//! |-------------|---------------------|----------------------------|
//! | Start Magic | `0xFFFF0001` (4B)   | READ_X: begin transfer     |
//! | ACK         | `0xFFFF` (2B)       | All chunks received        |
//! | Loss List   | `[seq_be16]...`     | Missing seqs, request retry|

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

/// Maximum number of chunks supported (12-bit field).
pub const max_chunks: u16 = 4095;

/// Chunk header size in bytes.
pub const header_size: usize = 3;

/// ATT protocol overhead (for GATT write/notify).
pub const att_overhead: usize = 3;

/// Total overhead per chunk: header + ATT.
pub const chunk_overhead: usize = header_size + att_overhead;

/// Maximum BLE ATT_MTU (BLE 5.2).
pub const max_mtu: usize = 517;

/// Maximum bitmask size in bytes (ceil(4095 / 8)).
pub const max_mask_bytes: usize = (max_chunks + 7) / 8;

/// Start magic for READ_X protocol (0xFFFF0001, big-endian).
pub const start_magic = [4]u8{ 0xFF, 0xFF, 0x00, 0x01 };

/// ACK signal (0xFFFF, big-endian).
pub const ack_signal = [2]u8{ 0xFF, 0xFF };

// ============================================================================
// Chunk Header
// ============================================================================

/// Decoded chunk header.
pub const Header = struct {
    /// Total number of chunks (1..4095).
    total: u16,
    /// Sequence number, 1-based (1..total).
    seq: u16,

    /// Encode header into 3 bytes.
    pub fn encode(self: Header) [header_size]u8 {
        return .{
            @intCast((self.total >> 4) & 0xFF),
            @intCast(((self.total & 0xF) << 4) | ((self.seq >> 8) & 0xF)),
            @intCast(self.seq & 0xFF),
        };
    }

    /// Decode header from 3 bytes.
    pub fn decode(bytes: *const [header_size]u8) Header {
        return .{
            .total = @as(u16, bytes[0]) << 4 | @as(u16, bytes[1]) >> 4,
            .seq = @as(u16, bytes[1] & 0xF) << 8 | @as(u16, bytes[2]),
        };
    }

    /// Validate header fields.
    pub fn validate(self: Header) error{InvalidHeader}!void {
        if (self.total == 0 or self.total > max_chunks) return error.InvalidHeader;
        if (self.seq == 0 or self.seq > self.total) return error.InvalidHeader;
    }
};

// ============================================================================
// Control Messages
// ============================================================================

/// Check if data is the READ_X start magic (0xFFFF0001).
pub fn isStartMagic(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], &start_magic);
}

/// Check if data is an ACK signal (0xFFFF).
pub fn isAck(data: []const u8) bool {
    return data.len >= 2 and data[0] == 0xFF and data[1] == 0xFF;
}

/// Encode a loss list into a buffer. Each seq is big-endian u16.
/// Returns the written slice.
pub fn encodeLossList(seqs: []const u16, buf: []u8) []u8 {
    var offset: usize = 0;
    for (seqs) |seq| {
        if (offset + 2 > buf.len) break;
        buf[offset] = @intCast((seq >> 8) & 0xFF);
        buf[offset + 1] = @intCast(seq & 0xFF);
        offset += 2;
    }
    return buf[0..offset];
}

/// Decode a loss list from received data. Returns number of seqs decoded.
pub fn decodeLossList(data: []const u8, out: []u16) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset + 2 <= data.len and count < out.len) {
        out[count] = @as(u16, data[offset]) << 8 | @as(u16, data[offset + 1]);
        count += 1;
        offset += 2;
    }
    return count;
}

// ============================================================================
// Bitmask Operations
// ============================================================================

/// Operations on a chunk tracking bitmask.
///
/// Bit layout: bit index = seq - 1.
/// Bit 0 of byte 0 = seq 1, bit 7 of byte 0 = seq 8, etc.
pub const Bitmask = struct {
    /// Required buffer size for `total` chunks.
    pub fn requiredBytes(total: u16) usize {
        return (@as(usize, total) + 7) / 8;
    }

    /// Clear all bits (no chunks tracked).
    pub fn initClear(buf: []u8, total: u16) void {
        @memset(buf[0..requiredBytes(total)], 0);
    }

    /// Set all valid bits (all chunks pending).
    /// Unused high bits in last byte are cleared.
    pub fn initAllSet(buf: []u8, total: u16) void {
        const len = requiredBytes(total);
        @memset(buf[0..len], 0xFF);
        const remainder: u3 = @intCast(total % 8);
        if (remainder != 0) {
            buf[len - 1] = (@as(u8, 1) << remainder) - 1;
        }
    }

    /// Set bit for a chunk seq (1-based).
    pub fn set(buf: []u8, seq: u16) void {
        const idx = seq - 1;
        buf[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
    }

    /// Clear bit for a chunk seq (1-based).
    pub fn clear(buf: []u8, seq: u16) void {
        const idx = seq - 1;
        buf[idx / 8] &= ~(@as(u8, 1) << @intCast(idx % 8));
    }

    /// Check if bit is set for a chunk seq (1-based).
    pub fn isSet(buf: []const u8, seq: u16) bool {
        const idx = seq - 1;
        return (buf[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
    }

    /// Check if all valid bits are set (transfer complete).
    pub fn isComplete(buf: []const u8, total: u16) bool {
        const full_bytes: usize = @as(usize, total) / 8;
        for (buf[0..full_bytes]) |b| {
            if (b != 0xFF) return false;
        }
        const remainder: u3 = @intCast(total % 8);
        if (remainder != 0) {
            const expected: u8 = (@as(u8, 1) << remainder) - 1;
            if ((buf[full_bytes] & expected) != expected) return false;
        }
        return true;
    }

    /// Collect missing seq numbers (bits NOT set). Returns count written to `out`.
    pub fn collectMissing(buf: []const u8, total: u16, out: []u16) usize {
        var count: usize = 0;
        var seq: u16 = 1;
        while (seq <= total and count < out.len) : (seq += 1) {
            if (!isSet(buf, seq)) {
                out[count] = seq;
                count += 1;
            }
        }
        return count;
    }
};

// ============================================================================
// Helpers
// ============================================================================

/// Max data payload per chunk: MTU - 3 (ATT) - 3 (header).
pub fn dataChunkSize(mtu: u16) usize {
    if (mtu <= chunk_overhead) return 1;
    return @as(usize, mtu) - chunk_overhead;
}

/// Number of chunks needed for `data_len` bytes at given MTU.
pub fn chunksNeeded(data_len: usize, mtu: u16) usize {
    const dcs = dataChunkSize(mtu);
    if (data_len == 0) return 0;
    return (data_len + dcs - 1) / dcs;
}
