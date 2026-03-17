//! TraceIo decorator: wraps any Io and logs all read/write bytes via a user log function.
//! Zero-intrusion debugging. See plan.md §5.2.1 (R29).

const io = @import("io.zig");

/// Direction of the traced data.
pub const TraceDirection = enum { tx, rx };

/// User-provided log: (direction, slice) -> void.
pub const TraceFn = *const fn (TraceDirection, []const u8) void;

/// Returns a new Io that delegates to `inner` and calls `log_fn` for every read/write.
/// poll() is not logged. Implement in Step 2 or when TraceIo is needed.
pub fn wrap(inner: io.Io, log_fn: TraceFn) io.Io {
    _ = log_fn;
    return inner;
}
