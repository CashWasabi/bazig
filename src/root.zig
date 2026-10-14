//! Game audio for Zig.
//! `audio` plays sound through miniaudio.
//! `synth` makes sound effects in code.
const std = @import("std");

pub const audio = @import("audio.zig");
pub const synth = @import("synth.zig");

test {
    std.testing.refAllDecls(@This());
}
