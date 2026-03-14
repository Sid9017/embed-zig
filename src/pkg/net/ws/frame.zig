//! WebSocket Frame Codec — RFC 6455 Section 5
//!
//! Handles encoding and decoding of WebSocket frames including masking.
//! Zero-allocation: frame headers are parsed from caller-provided buffers.

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const FrameHeader = struct {
    fin: bool,
    opcode: Opcode,
    masked: bool,
    payload_len: u64,
    mask_key: [4]u8,
    header_size: usize,
};

pub const Frame = struct {
    header: FrameHeader,
    payload: []const u8,
};

pub const Error = error{
    TruncatedHeader,
    TruncatedPayload,
    InvalidControlFrameLength,
    ReservedOpcode,
};

pub const MIN_HEADER_SIZE = 2;

pub fn decodeHeader(buf: []const u8) Error!FrameHeader {
    if (buf.len < MIN_HEADER_SIZE)
        return error.TruncatedHeader;

    const b0 = buf[0];
    const b1 = buf[1];

    const fin = (b0 & 0x80) != 0;
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b0 & 0x0F)));
    const masked = (b1 & 0x80) != 0;
    var payload_len: u64 = b1 & 0x7F;
    var pos: usize = 2;

    if (payload_len == 126) {
        if (buf.len < pos + 2) return error.TruncatedHeader;
        payload_len = readU16Big(buf[pos..][0..2]);
        pos += 2;
    } else if (payload_len == 127) {
        if (buf.len < pos + 8) return error.TruncatedHeader;
        payload_len = readU64Big(buf[pos..][0..8]);
        pos += 8;
    }

    const op_int = @intFromEnum(opcode);
    if (op_int >= 0x8 and payload_len > 125)
        return error.InvalidControlFrameLength;

    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (buf.len < pos + 4) return error.TruncatedHeader;
        @memcpy(&mask_key, buf[pos..][0..4]);
        pos += 4;
    }

    return .{
        .fin = fin,
        .opcode = opcode,
        .masked = masked,
        .payload_len = payload_len,
        .mask_key = mask_key,
        .header_size = pos,
    };
}

pub fn decode(buf: []const u8) Error!Frame {
    const header = try decodeHeader(buf);
    if (header.payload_len > buf.len) return error.TruncatedPayload;
    const payload_len: usize = @intCast(header.payload_len);
    const total = header.header_size + payload_len;
    if (buf.len < total) return error.TruncatedPayload;

    return .{
        .header = header,
        .payload = buf[header.header_size..total],
    };
}

pub fn encodeHeader(
    out: []u8,
    opcode: Opcode,
    payload_len: u64,
    fin: bool,
    mask_key: ?[4]u8,
) usize {
    var pos: usize = 0;

    var b0: u8 = @intFromEnum(opcode);
    if (fin) b0 |= 0x80;
    out[pos] = b0;
    pos += 1;

    var b1: u8 = 0;
    if (mask_key != null) b1 |= 0x80;

    if (payload_len < 126) {
        b1 |= @intCast(payload_len);
        out[pos] = b1;
        pos += 1;
    } else if (payload_len <= 0xFFFF) {
        b1 |= 126;
        out[pos] = b1;
        pos += 1;
        writeU16Big(out[pos..][0..2], @intCast(payload_len));
        pos += 2;
    } else {
        b1 |= 127;
        out[pos] = b1;
        pos += 1;
        writeU64Big(out[pos..][0..8], payload_len);
        pos += 8;
    }

    if (mask_key) |key| {
        @memcpy(out[pos..][0..4], &key);
        pos += 4;
    }

    return pos;
}

/// Maximum encoded header size: 1(flags) + 1(len) + 8(ext len) + 4(mask) = 14
pub const MAX_HEADER_SIZE = 14;

pub fn applyMask(data: []u8, mask_key: [4]u8) void {
    for (data, 0..) |*b, i| {
        b.* ^= mask_key[i % 4];
    }
}

pub fn applyMaskOffset(data: []u8, mask_key: [4]u8, offset: usize) void {
    for (data, 0..) |*b, i| {
        b.* ^= mask_key[(i + offset) % 4];
    }
}

pub fn readU16Big(b: *const [2]u8) u16 {
    return @as(u16, b[0]) << 8 | @as(u16, b[1]);
}

pub fn readU64Big(b: *const [8]u8) u64 {
    var result: u64 = 0;
    inline for (0..8) |i| {
        result |= @as(u64, b[i]) << @intCast((7 - i) * 8);
    }
    return result;
}

pub fn writeU16Big(b: *[2]u8, v: u16) void {
    b[0] = @intCast(v >> 8);
    b[1] = @intCast(v & 0xFF);
}

pub fn writeU64Big(b: *[8]u8, v: u64) void {
    inline for (0..8) |i| {
        b[i] = @intCast((v >> @intCast((7 - i) * 8)) & 0xFF);
    }
}
