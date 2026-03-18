const std = @import("std");
const embed = @import("../../../mod.zig");
const x509_contract = embed.runtime.crypto.x509;

const Certificate = std.crypto.Certificate;
const Bundle = Certificate.Bundle;

bundle: Bundle,
allocator: std.mem.Allocator,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) anyerror!Self {
    var bundle: Bundle = .{};
    bundle.rescan(allocator) catch |e| return e;
    return .{ .bundle = bundle, .allocator = allocator };
}

pub fn deinit(self: *Self) void {
    self.bundle.deinit(self.allocator);
}

pub fn verifyChain(
    self: *Self,
    chain: []const []const u8,
    hostname: ?[]const u8,
    now_sec: i64,
) x509_contract.VerifyError!void {
    if (chain.len == 0) return error.CertificateChainTooShort;

    const leaf_cert = Certificate{ .buffer = chain[0], .index = 0 };
    const leaf = leaf_cert.parse() catch return error.CertificateParseError;

    if (hostname) |host| {
        leaf.verifyHostName(host) catch return error.CertificateHostMismatch;
    }

    const now: i64 = if (now_sec == 0) ts: {
        const t = std.time.timestamp();
        break :ts if (t <= 0) 0 else t;
    } else now_sec;

    var subject = leaf;
    var i: usize = 1;
    while (i < chain.len) : (i += 1) {
        const issuer_cert = Certificate{ .buffer = chain[i], .index = 0 };
        const issuer = issuer_cert.parse() catch return error.CertificateParseError;
        subject.verify(issuer, now) catch return error.CertificateVerificationFailed;
        subject = issuer;
    }

    self.bundle.verify(subject, now) catch return error.CertificateVerificationFailed;
}
