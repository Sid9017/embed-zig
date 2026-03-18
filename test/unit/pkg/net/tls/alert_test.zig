const std = @import("std");
const testing = std.testing;
const embed = @import("embed");
const alert = embed.pkg.net.tls.alert;
const tls_common = embed.pkg.net.tls.common;

test "alert conversion roundtrip" {
    const descriptions = [_]tls_common.AlertDescription{
        .close_notify,
        .handshake_failure,
        .bad_certificate,
        .internal_error,
    };

    for (descriptions) |desc| {
        const alert_err = alert.alertToError(desc);
        const back = alert.errorToAlert(alert_err);
        try std.testing.expectEqual(desc, back);
    }
}

test "parse and serialize alert" {
    const a = tls_common.Alert{
        .level = .fatal,
        .description = .handshake_failure,
    };

    var buf: [2]u8 = undefined;
    try alert.serializeAlert(a, &buf);

    const parsed = try alert.parseAlert(&buf);
    try std.testing.expectEqual(a.level, parsed.level);
    try std.testing.expectEqual(a.description, parsed.description);
}

test "alert conversion roundtrip all known descriptions" {
    const all_descriptions = [_]tls_common.AlertDescription{
        .close_notify,
        .unexpected_message,
        .bad_record_mac,
        .record_overflow,
        .handshake_failure,
        .bad_certificate,
        .unsupported_certificate,
        .certificate_revoked,
        .certificate_expired,
        .certificate_unknown,
        .illegal_parameter,
        .unknown_ca,
        .access_denied,
        .decode_error,
        .decrypt_error,
        .protocol_version,
        .insufficient_security,
        .internal_error,
        .inappropriate_fallback,
        .user_canceled,
        .missing_extension,
        .unsupported_extension,
        .unrecognized_name,
        .bad_certificate_status_response,
        .unknown_psk_identity,
        .certificate_required,
        .no_application_protocol,
    };

    for (all_descriptions) |desc| {
        const err = alert.alertToError(desc);
        const back = alert.errorToAlert(err);
        try std.testing.expectEqual(desc, back);
    }
}

test "unknown alert description maps to UnknownAlert" {
    const unknown: tls_common.AlertDescription = @enumFromInt(255);
    const err = alert.alertToError(unknown);
    try std.testing.expectEqual(error.UnknownAlert, err);
}

test "UnknownAlert maps to internal_error" {
    const desc = alert.errorToAlert(error.UnknownAlert);
    try std.testing.expectEqual(tls_common.AlertDescription.internal_error, desc);
}

test "parseAlert too small buffer" {
    const buf: [1]u8 = .{0};
    try std.testing.expectError(error.DecodeError, alert.parseAlert(&buf));
}

test "parseAlert empty buffer" {
    try std.testing.expectError(error.DecodeError, alert.parseAlert(""));
}

test "serializeAlert too small buffer" {
    const a = tls_common.Alert{ .level = .fatal, .description = .internal_error };
    var buf: [1]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, alert.serializeAlert(a, &buf));
}

test "parse and serialize all alert levels" {
    const levels = [_]tls_common.AlertLevel{ .warning, .fatal };
    for (levels) |level| {
        const a = tls_common.Alert{ .level = level, .description = .close_notify };
        var buf: [2]u8 = undefined;
        try alert.serializeAlert(a, &buf);
        const parsed = try alert.parseAlert(&buf);
        try std.testing.expectEqual(level, parsed.level);
    }
}
