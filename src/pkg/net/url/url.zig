//! URL Parser — Zero-allocation URL parsing for freestanding environments.
//!
//! Parses URLs following RFC 3986 structure:
//!
//!   [scheme:][//[userinfo@]host[:port]][/path][?query][#fragment]
//!
//! All string fields are slices into the original input — zero heap allocation.
//! Port is parsed into a `u16` for convenience.
//!
//! Example:
//!
//!   const url = @import("url");
//!
//!   const u = try url.parse("mqtts://user:pass@example.com:8883/topic?qos=1#ref");
//!   u.scheme     // "mqtts"
//!   u.username   // "user"
//!   u.password   // "pass"
//!   u.host       // "example.com"
//!   u.port       // 8883
//!   u.path       // "/topic"
//!   u.raw_query  // "qos=1"
//!   u.fragment   // "ref"

/// Errors that can occur during URL parsing.
pub const ParseError = error{
    /// Port number is not a valid integer or exceeds 0–65535.
    InvalidPort,
    /// Host component is malformed (e.g., unclosed IPv6 bracket).
    InvalidHost,
};

/// A parsed URL. All slice fields point into the original input string.
pub const Url = struct {
    /// The original, unparsed URL string.
    raw: []const u8,

    /// URI scheme (e.g., "http", "mqtts", "ftp"). Lowercase by convention.
    scheme: ?[]const u8 = null,

    /// Username from the userinfo component.
    username: ?[]const u8 = null,

    /// Password from the userinfo component.
    password: ?[]const u8 = null,

    /// Host (domain or IP). IPv6 addresses include the brackets (e.g., "[::1]").
    host: ?[]const u8 = null,

    /// Port number, parsed as u16.
    port: ?u16 = null,

    /// Path component (includes the leading '/').
    /// Empty string if no path is present.
    path: []const u8 = "",

    /// Raw query string (after '?' and before '#'), without the leading '?'.
    raw_query: ?[]const u8 = null,

    /// Fragment (after '#'), without the leading '#'.
    fragment: ?[]const u8 = null,

    /// Returns the port, or the given default if no port was specified.
    ///
    /// Example:
    ///   const u = try url.parse("http://example.com/path");
    ///   u.portOrDefault(80) // 80
    pub fn portOrDefault(self: Url, default: u16) u16 {
        return self.port orelse default;
    }

    /// Returns the hostname without IPv6 brackets.
    ///
    /// For regular hosts, returns the host as-is.
    /// For IPv6 hosts like "[::1]", returns "::1".
    pub fn hostname(self: Url) ?[]const u8 {
        const h = self.host orelse return null;
        if (h.len >= 2 and h[0] == '[' and h[h.len - 1] == ']') {
            return h[1 .. h.len - 1];
        }
        return h;
    }

    /// Returns an iterator over query parameters (key=value pairs separated by '&').
    pub fn queryIterator(self: Url) QueryIterator {
        return .{ .raw = self.raw_query orelse "" };
    }
};

/// Iterator over query string parameters.
///
/// Splits on '&' and yields key/value pairs split on the first '='.
/// Empty segments between '&' delimiters are skipped.
///
/// Example:
///   const u = try url.parse("http://h/p?a=1&b=2&flag");
///   var it = u.queryIterator();
///   it.next() // .{ .key = "a", .value = "1" }
///   it.next() // .{ .key = "b", .value = "2" }
///   it.next() // .{ .key = "flag", .value = null }
///   it.next() // null
pub const QueryIterator = struct {
    raw: []const u8,
    pos: usize = 0,

    pub const Entry = struct {
        key: []const u8,
        value: ?[]const u8 = null,
    };

    /// Returns the next query parameter, or null when exhausted.
    pub fn next(self: *QueryIterator) ?Entry {
        while (self.pos < self.raw.len) {
            const rest = self.raw[self.pos..];

            // Find end of this parameter ('&' or end of string)
            const param_end = indexOf(rest, '&') orelse rest.len;
            const param = rest[0..param_end];

            // Advance past this segment (and the '&')
            self.pos += param_end;
            if (self.pos < self.raw.len) self.pos += 1; // skip '&'

            // Skip empty segments (e.g., "a=1&&b=2")
            if (param.len == 0) continue;

            // Split on first '='
            if (indexOf(param, '=')) |eq| {
                return .{
                    .key = param[0..eq],
                    .value = param[eq + 1 ..],
                };
            }
            return .{ .key = param };
        }
        return null;
    }

    /// Reset the iterator to the beginning.
    pub fn reset(self: *QueryIterator) void {
        self.pos = 0;
    }
};

/// Parse a URL string into its components.
///
/// Supports the general URI syntax (RFC 3986):
///   [scheme:][//[userinfo@]host[:port]][/path][?query][#fragment]
///
/// All string fields are slices into the input — zero heap allocation.
pub fn parse(raw: []const u8) ParseError!Url {
    var result = Url{ .raw = raw };
    var rest = raw;

    // 1. Extract fragment (after '#')
    if (indexOf(rest, '#')) |i| {
        result.fragment = rest[i + 1 ..];
        rest = rest[0..i];
    }

    // 2. Extract query (after '?')
    if (indexOf(rest, '?')) |i| {
        result.raw_query = rest[i + 1 ..];
        rest = rest[0..i];
    }

    // 3. Extract scheme
    if (getSchemeEnd(rest)) |scheme_end| {
        result.scheme = rest[0..scheme_end];
        rest = rest[scheme_end + 1 ..]; // skip ':'
    }

    // 4. Parse authority if present (starts with "//")
    if (rest.len >= 2 and rest[0] == '/' and rest[1] == '/') {
        rest = rest[2..]; // skip "//"

        // Authority ends at the first '/'
        const auth_end = indexOf(rest, '/') orelse rest.len;
        const authority = rest[0..auth_end];
        result.path = rest[auth_end..];

        try parseAuthority(&result, authority);
    } else {
        // No authority — rest is path (or opaque data for non-hierarchical URIs)
        result.path = rest;
    }

    return result;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Find the end of the scheme component.
/// Returns the index of ':' if a valid scheme precedes it, null otherwise.
///
/// RFC 3986 §3.1: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
pub fn getSchemeEnd(s: []const u8) ?usize {
    if (s.len == 0) return null;

    // First character must be alphabetic
    if (!isAlpha(s[0])) return null;

    for (s, 0..) |c, i| {
        if (c == ':') return i;
        if (i == 0) continue; // already checked s[0]
        if (!isAlpha(c) and !isDigit(c) and c != '+' and c != '-' and c != '.') {
            return null;
        }
    }
    return null; // no ':' found
}

/// Parse the authority component: [userinfo@]host[:port]
pub fn parseAuthority(result: *Url, authority: []const u8) ParseError!void {
    if (authority.len == 0) return;

    var host_part = authority;

    // Extract userinfo (before last '@')
    // Using last '@' handles edge cases like "user@name:pass@host"
    if (lastIndexOf(authority, '@')) |at| {
        const userinfo = authority[0..at];
        host_part = authority[at + 1 ..];

        // Split userinfo on first ':'
        if (indexOf(userinfo, ':')) |colon| {
            result.username = userinfo[0..colon];
            result.password = userinfo[colon + 1 ..];
        } else {
            result.username = userinfo;
        }
    }

    if (host_part.len == 0) return;

    // IPv6: [host]:port
    if (host_part[0] == '[') {
        const bracket = indexOf(host_part, ']') orelse return error.InvalidHost;
        result.host = host_part[0 .. bracket + 1]; // include brackets

        const after = host_part[bracket + 1 ..];
        if (after.len == 0) return;
        if (after[0] != ':') return error.InvalidHost;
        // RFC 3986: port = *DIGIT — empty port after ':' is valid
        const port_str = after[1..];
        if (port_str.len > 0) {
            result.port = parsePort(port_str) orelse return error.InvalidPort;
        }
    } else {
        // Regular host — split on last ':' for port
        if (lastIndexOf(host_part, ':')) |colon| {
            // Only treat as port if there's something after ':'
            const port_str = host_part[colon + 1 ..];
            if (port_str.len > 0) {
                result.port = parsePort(port_str) orelse return error.InvalidPort;
                result.host = host_part[0..colon];
            } else {
                // Trailing colon, no port (e.g., "host:")
                result.host = host_part[0..colon];
            }
        } else {
            result.host = host_part;
        }
    }
}

/// Parse a decimal port string as u16. Returns null on invalid input.
pub fn parsePort(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    var acc: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        acc = acc * 10 + (c - '0');
        if (acc > 65535) return null;
    }
    return @intCast(acc);
}

pub fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn indexOf(s: []const u8, needle: u8) ?usize {
    for (s, 0..) |c, i| {
        if (c == needle) return i;
    }
    return null;
}

pub fn lastIndexOf(s: []const u8, needle: u8) ?usize {
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if (s[i] == needle) return i;
    }
    return null;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = @import("std").testing;
