//! xfer - BLE READ_X / WRITE_X Chunked Transfer Protocol
//!
//! Reliable chunked transfer over BLE GATT characteristics.
//! Supports sending and receiving large data blocks over MTU-limited
//! BLE connections with loss detection and retransmission.

const chunk = @import("chunk.zig");
const read_x = @import("read_x.zig");
const write_x = @import("write_x.zig");

pub fn ReadX(comptime Transport: type) type {
    return read_x.ReadX(Transport);
}

pub fn WriteX(comptime Transport: type) type {
    return write_x.WriteX(Transport);
}
