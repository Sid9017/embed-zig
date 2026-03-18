const std = @import("std");
const testing = std.testing;
const ogg = @import("src.zig");
const SyncState = ogg.SyncState;
const StreamState = ogg.StreamState;
const Page = ogg.Page;
const Packet = ogg.Packet;
const PageOutResult = ogg.PageOutResult;
const PacketOutResult = ogg.PacketOutResult;
const Sync = ogg.Sync;
const Stream = ogg.Stream;
const pageVersion = ogg.pageVersion;
const pageContinued = ogg.pageContinued;
const pageBos = ogg.pageBos;
const pageEos = ogg.pageEos;
const pageGranulePos = ogg.pageGranulePos;
const pageSerialNo = ogg.pageSerialNo;
const pagePageNo = ogg.pagePageNo;
const pagePackets = ogg.pagePackets;

// ── tests ─────────────────────────────────────────────────────────────────

test "sync state lifecycle" {
    var sync = Sync.init();
    defer sync.deinit();

    sync.reset();
}

test "stream state lifecycle" {
    var stream = Stream.init(12345);
    defer stream.deinit();

    stream.reset();
    stream.resetSerial(67890);
}

test "sync buffer allocation" {
    var sync = Sync.init();
    defer sync.deinit();

    const buf = sync.buffer(4096);
    try std.testing.expect(buf != null);
    try std.testing.expect(buf.?.len == 4096);
}

test "sync pageOut returns need_more_data on empty state" {
    var sync = Sync.init();
    defer sync.deinit();

    var page: Page = undefined;
    const result = sync.pageOut(&page);
    try std.testing.expectEqual(PageOutResult.need_more_data, result);
}

test "stream packetOut returns need_more_data on empty stream" {
    var stream = Stream.init(1);
    defer stream.deinit();

    var packet: Packet = undefined;
    const result = stream.packetOut(&packet);
    try std.testing.expectEqual(PacketOutResult.need_more_data, result);
}
