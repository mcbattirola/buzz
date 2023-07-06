const std = @import("std");
const _obj = @import("../obj.zig");
const ObjPattern = _obj.ObjPattern;
const ObjString = _obj.ObjString;
const ObjList = _obj.ObjList;
const ObjTypeDef = _obj.ObjTypeDef;
const NativeCtx = _obj.NativeCtx;
const VM = @import("../vm.zig").VM;
const _value = @import("../value.zig");
const Value = _value.Value;

pub const pcre = @import("../pcre.zig").pcre;

fn rawMatch(self: *ObjPattern, vm: *VM, subject: *ObjString, offset: *usize) !?*ObjList {
    if (subject.string.len == 0) {
        return null;
    }

    var results: ?*ObjList = null;

    var output_vector: [3000]c_int = undefined;

    const rc = pcre.pcre_exec(
        self.pattern, // the compiled pattern
        null, // no extra data - we didn't study the pattern
        @as([*c]const u8, @ptrCast(subject.string)), // the subject string
        @as(c_int, @intCast(subject.string.len)), // the length of the subject
        @as(c_int, @intCast(offset.*)), // start offset
        0, // default options
        @as([*c]c_int, @ptrCast(&output_vector)), // output vector for substring information
        output_vector.len, // number of elements in the output vector
    );

    switch (rc) {
        pcre.PCRE_ERROR_UNSET...pcre.PCRE_ERROR_NOMATCH => return null,
        // TODO: handle ouptut_vector too small
        0 => @panic("Could not match pattern"),
        else => {
            offset.* = @as(usize, @intCast(output_vector[1]));

            results = try vm.gc.allocateObject(
                ObjList,
                ObjList.init(
                    vm.gc.allocator,
                    try vm.gc.type_registry.getTypeDef(
                        ObjTypeDef{
                            .def_type = .String,
                        },
                    ),
                ),
            );

            // Prevent gc collection
            vm.push(results.?.toValue());

            var i: usize = 0;
            while (i < rc) : (i += 1) {
                try results.?.items.append(
                    (try vm.gc.copyString(
                        subject.string[@as(usize, @intCast(output_vector[2 * i]))..@as(usize, @intCast(output_vector[2 * i + 1]))],
                    )).toValue(),
                );
            }

            _ = vm.pop();
        },
    }

    return results;
}

fn rawMatchAll(self: *ObjPattern, vm: *VM, subject: *ObjString) !?*ObjList {
    if (subject.string.len == 0) {
        return null;
    }

    var results: ?*ObjList = null;
    var offset: usize = 0;
    while (true) {
        if (try rawMatch(self, vm, subject, &offset)) |matches| {
            var was_null = results == null;
            results = results orelse try vm.gc.allocateObject(
                ObjList,
                ObjList.init(vm.gc.allocator, matches.type_def),
            );

            if (was_null) {
                vm.push(results.?.toValue());
            }

            try results.?.items.append(matches.toValue());
        } else {
            if (results != null) {
                _ = vm.pop();
            }

            return results;
        }
    }

    if (results != null) {
        _ = vm.pop();
    }

    return results;
}

fn rawReplace(self: *ObjPattern, vm: *VM, subject: *ObjString, replacement: *ObjString, offset: *usize) !*ObjString {
    if (subject.string.len == 0) {
        return subject;
    }

    var result = std.ArrayList(u8).init(vm.gc.allocator);
    defer result.deinit();

    var output_vector: [3000]c_int = undefined;

    const rc = pcre.pcre_exec(
        self.pattern, // the compiled pattern
        null, // no extra data - we didn't study the pattern
        @as([*c]const u8, @ptrCast(subject.string)), // the subject string
        @as(c_int, @intCast(subject.string.len)), // the length of the subject
        @as(c_int, @intCast(offset.*)), // start offset
        0, // default options
        @as([*c]c_int, @ptrCast(&output_vector)), // output vector for substring information
        output_vector.len, // number of elements in the output vector
    );

    switch (rc) {
        pcre.PCRE_ERROR_UNSET...pcre.PCRE_ERROR_NOMATCH => return subject,
        // TODO: handle ouptut_vector too small
        0 => @panic("Could not match pattern"),
        else => {
            offset.* = @as(usize, @intCast(output_vector[1]));

            try result.appendSlice(subject.string[0..@as(usize, @intCast(output_vector[0]))]);
            try result.appendSlice(replacement.string);
            try result.appendSlice(subject.string[offset.*..]);
        },
    }

    return try vm.gc.copyString(result.items);
}

fn rawReplaceAll(self: *ObjPattern, vm: *VM, subject: *ObjString, replacement: *ObjString) !*ObjString {
    if (subject.string.len == 0) {
        return subject;
    }

    var offset: usize = 0;
    var current = subject;
    while (true) {
        const replaced = try rawReplace(self, vm, current, replacement, &offset);

        if (replaced == current) {
            break;
        } else {
            current = replaced;
        }
    }

    return current;
}

pub fn match(ctx: *NativeCtx) c_int {
    const self = ObjPattern.cast(ctx.vm.peek(1).obj()).?;
    const subject = ObjString.cast(ctx.vm.peek(0).obj()).?;

    var offset: usize = 0;
    if (rawMatch(
        self,
        ctx.vm,
        subject,
        &offset,
    ) catch @panic("Could not match pattern")) |results| {
        ctx.vm.push(results.toValue());
    } else {
        ctx.vm.push(Value.Null);
    }

    return 1;
}

pub fn replace(ctx: *NativeCtx) c_int {
    const self = ObjPattern.cast(ctx.vm.peek(2).obj()).?;
    const subject = ObjString.cast(ctx.vm.peek(1).obj()).?;
    const replacement = ObjString.cast(ctx.vm.peek(0).obj()).?;

    var offset: usize = 0;
    const result = rawReplace(self, ctx.vm, subject, replacement, &offset) catch @panic("Could not replace pattern");

    ctx.vm.push(result.toValue());

    return 1;
}

pub fn matchAll(ctx: *NativeCtx) c_int {
    const self = ObjPattern.cast(ctx.vm.peek(1).obj()).?;
    const subject = ObjString.cast(ctx.vm.peek(0).obj()).?;

    if (rawMatchAll(
        self,
        ctx.vm,
        subject,
    ) catch @panic("Could not match pattern")) |results| {
        ctx.vm.push(results.toValue());
    } else {
        ctx.vm.push(Value.Null);
    }

    return 1;
}

pub fn replaceAll(ctx: *NativeCtx) c_int {
    const self = ObjPattern.cast(ctx.vm.peek(2).obj()).?;
    const subject = ObjString.cast(ctx.vm.peek(1).obj()).?;
    const replacement = ObjString.cast(ctx.vm.peek(0).obj()).?;

    const result = rawReplaceAll(
        self,
        ctx.vm,
        subject,
        replacement,
    ) catch @panic("Could not match pattern");

    ctx.vm.push(result.toValue());

    return 1;
}
