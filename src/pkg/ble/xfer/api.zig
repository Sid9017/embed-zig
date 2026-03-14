//! xfer - BLE READ_X / WRITE_X Chunked Transfer Protocol
//!
//! Reliable chunked transfer over BLE GATT characteristics.
//! Supports sending and receiving large data blocks over MTU-limited
//! BLE connections with loss detection and retransmission.

pub const chunk = @import("chunk.zig");
pub const read_x = @import("read_x.zig");
pub const write_x = @import("write_x.zig");

pub fn ReadX(comptime Transport: type) type {
    return read_x.ReadX(Transport);
}

pub fn WriteX(comptime Transport: type) type {
    return write_x.WriteX(Transport);
}

pub const Header = chunk.Header;
pub const Bitmask = chunk.Bitmask;
pub const start_magic = chunk.start_magic;
pub const ack_signal = chunk.ack_signal;
pub const dataChunkSize = chunk.dataChunkSize;
pub const chunksNeeded = chunk.chunksNeeded;
