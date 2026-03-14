const std = @import("std");
const common = @import("common.zig");

pub const Alert = common.Alert;
pub const AlertLevel = common.AlertLevel;
pub const AlertDescription = common.AlertDescription;

pub const AlertError = error{
    CloseNotify,
    UnexpectedMessage,
    BadRecordMac,
    RecordOverflow,
    HandshakeFailure,
    BadCertificate,
    UnsupportedCertificate,
    CertificateRevoked,
    CertificateExpired,
    CertificateUnknown,
    IllegalParameter,
    UnknownCa,
    AccessDenied,
    DecodeError,
    DecryptError,
    ProtocolVersion,
    InsufficientSecurity,
    InternalError,
    InappropriateFallback,
    UserCanceled,
    MissingExtension,
    UnsupportedExtension,
    UnrecognizedName,
    BadCertificateStatusResponse,
    UnknownPskIdentity,
    CertificateRequired,
    NoApplicationProtocol,
    UnknownAlert,
};

pub fn alertToError(description: AlertDescription) AlertError {
    return switch (description) {
        .close_notify => error.CloseNotify,
        .unexpected_message => error.UnexpectedMessage,
        .bad_record_mac => error.BadRecordMac,
        .record_overflow => error.RecordOverflow,
        .handshake_failure => error.HandshakeFailure,
        .bad_certificate => error.BadCertificate,
        .unsupported_certificate => error.UnsupportedCertificate,
        .certificate_revoked => error.CertificateRevoked,
        .certificate_expired => error.CertificateExpired,
        .certificate_unknown => error.CertificateUnknown,
        .illegal_parameter => error.IllegalParameter,
        .unknown_ca => error.UnknownCa,
        .access_denied => error.AccessDenied,
        .decode_error => error.DecodeError,
        .decrypt_error => error.DecryptError,
        .protocol_version => error.ProtocolVersion,
        .insufficient_security => error.InsufficientSecurity,
        .internal_error => error.InternalError,
        .inappropriate_fallback => error.InappropriateFallback,
        .user_canceled => error.UserCanceled,
        .missing_extension => error.MissingExtension,
        .unsupported_extension => error.UnsupportedExtension,
        .unrecognized_name => error.UnrecognizedName,
        .bad_certificate_status_response => error.BadCertificateStatusResponse,
        .unknown_psk_identity => error.UnknownPskIdentity,
        .certificate_required => error.CertificateRequired,
        .no_application_protocol => error.NoApplicationProtocol,
        else => error.UnknownAlert,
    };
}

pub fn errorToAlert(err: AlertError) AlertDescription {
    return switch (err) {
        error.CloseNotify => .close_notify,
        error.UnexpectedMessage => .unexpected_message,
        error.BadRecordMac => .bad_record_mac,
        error.RecordOverflow => .record_overflow,
        error.HandshakeFailure => .handshake_failure,
        error.BadCertificate => .bad_certificate,
        error.UnsupportedCertificate => .unsupported_certificate,
        error.CertificateRevoked => .certificate_revoked,
        error.CertificateExpired => .certificate_expired,
        error.CertificateUnknown => .certificate_unknown,
        error.IllegalParameter => .illegal_parameter,
        error.UnknownCa => .unknown_ca,
        error.AccessDenied => .access_denied,
        error.DecodeError => .decode_error,
        error.DecryptError => .decrypt_error,
        error.ProtocolVersion => .protocol_version,
        error.InsufficientSecurity => .insufficient_security,
        error.InternalError => .internal_error,
        error.InappropriateFallback => .inappropriate_fallback,
        error.UserCanceled => .user_canceled,
        error.MissingExtension => .missing_extension,
        error.UnsupportedExtension => .unsupported_extension,
        error.UnrecognizedName => .unrecognized_name,
        error.BadCertificateStatusResponse => .bad_certificate_status_response,
        error.UnknownPskIdentity => .unknown_psk_identity,
        error.CertificateRequired => .certificate_required,
        error.NoApplicationProtocol => .no_application_protocol,
        error.UnknownAlert => .internal_error,
    };
}

pub fn parseAlert(data: []const u8) !Alert {
    if (data.len < 2) return error.DecodeError;
    return Alert{
        .level = @enumFromInt(data[0]),
        .description = @enumFromInt(data[1]),
    };
}

pub fn serializeAlert(a: Alert, buf: []u8) !void {
    if (buf.len < 2) return error.BufferTooSmall;
    buf[0] = @intFromEnum(a.level);
    buf[1] = @intFromEnum(a.description);
}
