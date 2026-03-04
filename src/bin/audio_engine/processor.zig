const engine_mod = @import("engine");
const speexdsp = @import("speexdsp");

pub const SpeexAecNs = struct {
    aec: speexdsp.EchoCanceller,
    pp: speexdsp.Preprocessor,
    frame_size: u32,

    pub fn create(frame_size: u32, sample_rate: u32) !SpeexAecNs {
        // 200ms tail — speex recommends 100-500ms; keep modest to avoid
        // blowing the capture thread's stack (speex allocates O(filter_length)
        // temporaries internally).
        const filter_length: c_int = @intCast(sample_rate / 5);
        var aec = speexdsp.EchoCanceller.init(@intCast(frame_size), filter_length) orelse
            return error.AecInitFailed;
        aec.setSamplingRate(@intCast(sample_rate));

        var pp = speexdsp.Preprocessor.init(@intCast(frame_size), @intCast(sample_rate)) orelse {
            aec.deinit();
            return error.PreprocessorInitFailed;
        };
        pp.setDenoise(true);
        pp.setNoiseSuppress(-25);
        pp.setEchoState(&aec);

        return .{ .aec = aec, .pp = pp, .frame_size = frame_size };
    }

    pub fn destroy(self: *SpeexAecNs) void {
        self.pp.clearEchoState();
        self.pp.deinit();
        self.aec.deinit();
    }

    pub fn processor(self: *SpeexAecNs) engine_mod.Processor {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    const vtable = engine_mod.Processor.VTable{
        .process = &processFrame,
        .reset = &resetState,
        .deinit = &destroyVtable,
    };

    fn processFrame(ctx: *anyopaque, mic: []const i16, ref: ?[]const i16, out: []i16) void {
        const self: *SpeexAecNs = @ptrCast(@alignCast(ctx));
        if (ref) |r| {
            self.aec.cancel(mic, r, out);
        } else {
            @memcpy(out[0..mic.len], mic);
        }
        _ = self.pp.run(out.ptr);
    }

    fn resetState(ctx: *anyopaque) void {
        const self: *SpeexAecNs = @ptrCast(@alignCast(ctx));
        self.aec.reset();
    }

    fn destroyVtable(ctx: *anyopaque) void {
        const self: *SpeexAecNs = @ptrCast(@alignCast(ctx));
        self.destroy();
    }
};
