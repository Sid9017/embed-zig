//! Base64 Encoder/Decoder — RFC 4648
//!
//! Minimal freestanding implementation for WebSocket handshake.
//! Only standard alphabet (no URL-safe variant).

pub const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn encodedLen(input_len: usize) usize {
    return ((input_len + 2) / 3) * 4;
}

pub fn encode(out: []u8, input: []const u8) []const u8 {
    const len = encodedLen(input.len);
    var pos: usize = 0;
    var i: usize = 0;

    while (i + 3 <= input.len) : (i += 3) {
        const b0 = input[i];
        const b1 = input[i + 1];
        const b2 = input[i + 2];

        out[pos] = alphabet[b0 >> 2];
        out[pos + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[pos + 2] = alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)];
        out[pos + 3] = alphabet[b2 & 0x3F];
        pos += 4;
    }

    const remaining = input.len - i;
    if (remaining == 1) {
        out[pos] = alphabet[input[i] >> 2];
        out[pos + 1] = alphabet[(input[i] & 0x03) << 4];
        out[pos + 2] = '=';
        out[pos + 3] = '=';
    } else if (remaining == 2) {
        out[pos] = alphabet[input[i] >> 2];
        out[pos + 1] = alphabet[((input[i] & 0x03) << 4) | (input[i + 1] >> 4)];
        out[pos + 2] = alphabet[(input[i + 1] & 0x0F) << 2];
        out[pos + 3] = '=';
    }

    return out[0..len];
}

pub fn decodedLen(input_len: usize) usize {
    return (input_len / 4) * 3;
}

pub const DecodeError = error{
    InvalidCharacter,
    InvalidPadding,
};

pub fn decode(out: []u8, input: []const u8) DecodeError![]const u8 {
    if (input.len % 4 != 0) return error.InvalidPadding;

    var pos: usize = 0;
    var i: usize = 0;

    while (i < input.len) : (i += 4) {
        const a = try decodeChar(input[i]);
        const b = try decodeChar(input[i + 1]);

        out[pos] = (a << 2) | (b >> 4);
        pos += 1;

        if (input[i + 2] != '=') {
            const c = try decodeChar(input[i + 2]);
            out[pos] = (b << 4) | (c >> 2);
            pos += 1;

            if (input[i + 3] != '=') {
                const d = try decodeChar(input[i + 3]);
                out[pos] = (c << 6) | d;
                pos += 1;
            }
        }
    }

    return out[0..pos];
}

pub fn decodeChar(c: u8) DecodeError!u8 {
    if (c >= 'A' and c <= 'Z') return @intCast(c - 'A');
    if (c >= 'a' and c <= 'z') return @intCast(c - 'a' + 26);
    if (c >= '0' and c <= '9') return @intCast(c - '0' + 52);
    if (c == '+') return 62;
    if (c == '/') return 63;
    return error.InvalidCharacter;
}
