const std = @import("std");
const print = std.debug.print;
const _chunk = @import("./chunk.zig");
const _value = @import("./value.zig");
const _obj = @import("./obj.zig");
const _vm = @import("./vm.zig");

const VM = _vm.VM;
const Chunk = _chunk.Chunk;
const OpCode = _chunk.OpCode;
const ObjFunction = _obj.ObjFunction;

pub fn disassembleChunk(chunk: *Chunk, name: []const u8) !void {
    print("=== {s} ===\n", .{ name });

    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = try disassembleInstruction(chunk, offset);
    }
}

inline fn simpleInstruction(code: OpCode, offset: usize) usize {
    print("{}\t", .{ code });

    return offset + 1;
}

fn byteInstruction(code: OpCode, chunk: *Chunk, offset: usize) usize {
    var slot: u8 = chunk.code.items[offset + 1];
    print("{}\t{}", .{ code, slot });
    return offset + 2;
}

fn constantInstruction(code: OpCode, chunk: *Chunk, offset: usize) !usize {
    const constant: u8 = chunk.code.items[offset + 1];
    var value_str: []const u8 = try _value.valueToString(std.heap.c_allocator, chunk.constants.items[constant]);
    defer std.heap.c_allocator.free(value_str);

    print("{}\t{} {s}", .{ code, constant, value_str });

    return offset + 2;
}

pub fn dumpStack(vm: *VM) !void {
    print(" [ ", .{});

    var i: usize = 0;
    while (i < vm.stack_top) {
        var value_str: []const u8 = try _value.valueToString(std.heap.c_allocator, vm.stack[i]);
        defer std.heap.c_allocator.free(value_str);

        print("{s} | ", .{ value_str });

        i += 1;
    }

    print(" ]\n", .{});
}

pub fn disassembleInstruction(chunk: *Chunk, offset: usize) !usize {
    print("\n{:0>3} ", .{ offset });

    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset -1]) {
        print("|   ", .{});
    } else {
        print("{:0>3} ", .{ chunk.lines.items[offset] });
    }

    const instruction: OpCode = @intToEnum(OpCode, chunk.code.items[offset]);
    return switch (instruction) {
        .OP_NULL,
        .OP_TRUE,
        .OP_FALSE,
        .OP_POP,
        .OP_EQUAL,
        .OP_GREATER,
        .OP_LESS,
        .OP_ADD,
        .OP_SUBTRACT,
        .OP_MULTIPLY,
        .OP_DIVIDE,
        .OP_NOT,
        .OP_NEGATE,
        .OP_MOD,
        .OP_SHL,
        .OP_SHR,
        .OP_UNWRAP => simpleInstruction(instruction, offset),

        .OP_GET_LOCAL,
        .OP_SET_LOCAL,
        .OP_GET_UPVALUE,
        .OP_SET_UPVALUE => byteInstruction(instruction, chunk, offset),
        
        .OP_CONSTANT => try constantInstruction(instruction, chunk, offset),

        .OP_GET_PROPERTY => simpleInstruction(instruction, offset),
        .OP_SET_PROPERTY => simpleInstruction(instruction, offset),
        .OP_GET_SUBSCRIPT => simpleInstruction(instruction, offset),
        .OP_SET_SUBSCRIPT => simpleInstruction(instruction, offset),
        .OP_GET_SUPER => simpleInstruction(instruction, offset),
        
        .OP_JUMP => simpleInstruction(instruction, offset),
        .OP_JUMP_IF_FALSE => simpleInstruction(instruction, offset),
        .OP_LOOP => simpleInstruction(instruction, offset),

        .OP_CALL => simpleInstruction(instruction, offset),
        .OP_INVOKE => simpleInstruction(instruction, offset),
        .OP_SUPER_INVOKE => simpleInstruction(instruction, offset),

        .OP_CLOSURE => closure: {
            var off_offset: usize = offset;
            off_offset += 1;
            var constant: u8 = chunk.code.items[off_offset];
            off_offset += 1;

            var value_str: []const u8 = try _value.valueToString(std.heap.c_allocator, chunk.constants.items[constant]);
            defer std.heap.c_allocator.free(value_str);

            print("{}\t{} {s}", .{ instruction, constant, value_str });

            var function: *ObjFunction = ObjFunction.cast(chunk.constants.items[constant].Obj).?;
            var i: u8 = 0;
            while (i < function.upvalue_count) : (i += 1) {
                var is_local: bool = chunk.code.items[off_offset] == 1;
                off_offset += 1;
                var index: u8 = chunk.code.items[off_offset];
                off_offset += 1;
                print("\n{:0>3} |                         \t{s} {}\n", .{ off_offset - 2, if (is_local) "local  " else "upvalue", index });
            }

            break :closure off_offset;
        },

        .OP_CLOSE_UPVALUE => simpleInstruction(instruction, offset),

        .OP_RETURN => simpleInstruction(instruction, offset),

        .OP_CLASS => simpleInstruction(instruction, offset),
        .OP_OBJECT => simpleInstruction(instruction, offset),
        .OP_INHERIT => simpleInstruction(instruction, offset),
        .OP_METHOD => simpleInstruction(instruction, offset),
        .OP_PROPERTY => simpleInstruction(instruction, offset),

        // TODO: remove
        .OP_PRINT => simpleInstruction(instruction, offset),
    };
}