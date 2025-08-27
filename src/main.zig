const std = @import("std");
const c = @cImport({
    @cInclude("miniaudio.h");
    @cInclude("ffms.h");
});

var video_file = "sample/video.mov";

var audio_src: ?*c.FFMS_AudioSource = null;
var audio_props: [*c]const c.FFMS_AudioProperties = null;
var current_sample_pos: i64 = 0;
var audio_buffer: ?[]u8 = null;
var allocator: std.mem.Allocator = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();

    const version = c.FFMS_GetVersion();

    const major = version >> 24;
    const minor = version >> 16 & 0xFF;
    const micro = version >> 8 & 0xFF;
    const bump = version & 0xFF;

    std.debug.print("FFMS version: {}.{}.{}.{}\n", .{ major, minor, micro, bump });

    c.FFMS_Init(0, 0);

    var errmsg: [1024]u8 = undefined;
    var errinfo: c.FFMS_ErrorInfo = .{ .Buffer = &errmsg, .BufferSize = 1024, .ErrorType = c.FFMS_ERROR_SUCCESS, .SubType = c.FFMS_ERROR_SUCCESS };

    const indexer = c.FFMS_CreateIndexer(video_file, &errinfo);
    if (indexer == null) {
        std.debug.print("Failed to create indexer: {s}\n", .{errinfo.Buffer});
        return error.FFMS_Error;
    }

    std.debug.print("Successfully initialized\n", .{});

    // Enable audio tracks to make them indexable
    c.FFMS_TrackTypeIndexSettings(indexer, c.FFMS_TYPE_AUDIO, 1, 0);

    const index = c.FFMS_DoIndexing2(indexer, c.FFMS_IEH_ABORT, &errinfo);
    if (index == null) {
        std.debug.print("Failed to index: {s}\n", .{errinfo.Buffer});
        c.FFMS_CancelIndexing(indexer);
        return error.FFMS_Error;
    }
    defer c.FFMS_DestroyIndex(index);

    std.debug.print("Indexing completed successfully\n", .{});

    const audio_track_no = c.FFMS_GetFirstTrackOfType(index, c.FFMS_TYPE_AUDIO, &errinfo);

    if (audio_track_no < 0) {
        std.debug.print("No audio track found: {s}\n", .{errinfo.Buffer});
        return error.NoAudioTrack;
    }

    std.debug.print("Audio track number: {}\n", .{audio_track_no});

    audio_src = c.FFMS_CreateAudioSource(video_file, audio_track_no, index, c.FFMS_DELAY_FIRST_VIDEO_TRACK, &errinfo);
    if (audio_src == null) {
        std.debug.print("Failed to create audio source: {s}\n", .{errinfo.Buffer});
        return error.FFMS_Error;
    }
    defer c.FFMS_DestroyAudioSource(audio_src);

    std.debug.print("Created audio source successfully\n", .{});

    audio_props = c.FFMS_GetAudioProperties(audio_src);
    if (audio_props == null) {
        std.debug.print("Failed to get audio properties: {s}\n", .{errinfo.Buffer});
        return error.FFMS_Error;
    }

    std.debug.print("Audio Properties:\n", .{});
    std.debug.print("  Sample Format: {}\n", .{audio_props.*.SampleFormat});
    std.debug.print("  Sample Rate: {}\n", .{audio_props.*.SampleRate});
    std.debug.print("  Bits Per Sample: {}\n", .{audio_props.*.BitsPerSample});
    std.debug.print("  Channels: {}\n", .{audio_props.*.Channels});
    std.debug.print("  Channel Layout: {}\n", .{audio_props.*.ChannelLayout});
    std.debug.print("  Num Samples: {}\n", .{audio_props.*.NumSamples});
    std.debug.print("  Duration: {:.2}s\n", .{audio_props.*.LastTime - audio_props.*.FirstTime});

    // Calculate buffer size for audio samples
    const buffer_frames = 4096;
    const bytes_per_sample = @as(usize, @intCast(@divExact(audio_props.*.BitsPerSample, 8)));
    const channels = @as(usize, @intCast(audio_props.*.Channels));
    const buffer_size = buffer_frames * bytes_per_sample * channels;

    audio_buffer = try allocator.alloc(u8, buffer_size);
    defer if (audio_buffer) |buf| allocator.free(buf);

    // Configure miniaudio device
    var device = std.mem.zeroes(c.ma_device);
    var deviceConfig = c.ma_device_config_init(c.ma_device_type_playback);

    // Match the audio format from FFMS2
    switch (audio_props.*.SampleFormat) {
        c.FFMS_FMT_U8 => deviceConfig.playback.format = c.ma_format_u8,
        c.FFMS_FMT_S16 => deviceConfig.playback.format = c.ma_format_s16,
        c.FFMS_FMT_S32 => deviceConfig.playback.format = c.ma_format_s32,
        c.FFMS_FMT_FLT => deviceConfig.playback.format = c.ma_format_f32,
        c.FFMS_FMT_DBL => {
            std.log.err("Miniaudio doesn't support DBL (f64) sample format", .{});
            // TODO: use libswresample
            return error.UnsupportedFormat;
        },
        else => {
            std.debug.print("Unsupported sample format: {}\n", .{audio_props.*.SampleFormat});
            return error.UnsupportedFormat;
        },
    }

    deviceConfig.playback.channels = @as(c_uint, @intCast(audio_props.*.Channels));
    deviceConfig.sampleRate = @as(c_uint, @intCast(audio_props.*.SampleRate));
    deviceConfig.dataCallback = audio_callback;
    deviceConfig.pUserData = null;

    const result = c.ma_device_init(null, &deviceConfig, &device);
    if (result != c.MA_SUCCESS) {
        std.debug.print("Device init failed: {}\n", .{result});
        return error.DeviceInitFailed;
    }
    defer c.ma_device_uninit(&device);

    // Start playback
    const start_result = c.ma_device_start(&device);
    if (start_result != c.MA_SUCCESS) {
        std.debug.print("Device start failed: {}\n", .{start_result});
        return error.DeviceStartFailed;
    }

    std.debug.print("Playing audio... Press Enter to stop.\n", .{});

    // Wait for user input to stop playback
    var buf: [100]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&buf);
    const reader = &stdin_reader.interface;
    _ = try reader.take(1);

    _ = c.ma_device_stop(&device);
    std.debug.print("Playback stopped.\n", .{});
}

pub fn audio_callback(
    device: [*c]c.ma_device,
    output: ?*anyopaque,
    input: ?*const anyopaque,
    frame_count: c_uint,
) callconv(.c) void {
    _ = input;
    _ = device;

    if (audio_src == null or audio_props == null or output == null) {
        return;
    }

    // If reached end of the audio
    if (current_sample_pos >= audio_props.*.NumSamples) {
        // Reset to beginning for looping, or could stop playback
        current_sample_pos = 0;
        return;
    }

    // Calculate how many samples to read
    const samples_to_read = @min(frame_count, @as(c_uint, @intCast(audio_props.*.NumSamples - current_sample_pos)));

    if (samples_to_read == 0) {
        return;
    }

    var errmsg: [1024]u8 = undefined;
    var errinfo: c.FFMS_ErrorInfo = .{ .Buffer = &errmsg, .BufferSize = 1024, .ErrorType = c.FFMS_ERROR_SUCCESS, .SubType = c.FFMS_ERROR_SUCCESS };

    const result = c.FFMS_GetAudio(audio_src, output, current_sample_pos, samples_to_read, &errinfo);

    if (result != 0) {
        std.debug.print("FFMS_GetAudio failed: {s}\n", .{errinfo.Buffer});
        return;
    }

    current_sample_pos += samples_to_read;

    // If we didn't fill the entire output buffer, zero out the rest
    if (samples_to_read < frame_count) {
        const bytes_per_sample = @as(usize, @intCast(@divExact(audio_props.*.BitsPerSample, 8)));
        const channels = @as(usize, @intCast(audio_props.*.Channels));
        const bytes_written = @as(usize, @intCast(samples_to_read)) * bytes_per_sample * channels;
        const total_bytes = @as(usize, @intCast(frame_count)) * bytes_per_sample * channels;
        const remaining_bytes = total_bytes - bytes_written;

        if (remaining_bytes > 0) {
            const output_ptr = @as([*]u8, @ptrCast(output.?));
            @memset(output_ptr[bytes_written .. bytes_written + remaining_bytes], 0);
        }
    }
}
