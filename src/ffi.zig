const std = @import("std");
const Ast = std.zig.Ast;

const o = @import("./obj.zig");
const t = @import("./token.zig");
const m = @import("./memory.zig");
const v = @import("./value.zig");
const p = @import("./parser.zig");
const ZigType = @import("./zigtypes.zig").Type;
const Reporter = @import("./reporter.zig");

const Self = @This();

const basic_types = std.ComptimeStringMap(
    o.ObjTypeDef,
    .{
        .{ "u8", .{ .def_type = .Integer } },
        .{ "i8", .{ .def_type = .Integer } },
        .{ "u16", .{ .def_type = .Integer } },
        .{ "i16", .{ .def_type = .Integer } },
        .{ "i32", .{ .def_type = .Integer } },

        .{ "u32", .{ .def_type = .Float } },
        .{ "i64", .{ .def_type = .Float } },
        .{ "f32", .{ .def_type = .Float } },
        .{ "f64", .{ .def_type = .Float } },

        .{ "u64", .{ .def_type = .UserData } },
        .{ "usize", .{ .def_type = .UserData } },

        .{ "bool", .{ .def_type = .Bool } },

        .{ "void", .{ .def_type = .Void } },
    },
);

const zig_basic_types = std.ComptimeStringMap(
    ZigType,
    .{
        .{
            "u8",
            ZigType{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = 8,
                },
            },
        },
        .{
            "i8",
            ZigType{
                .Int = .{
                    .signedness = .signed,
                    .bits = 8,
                },
            },
        },
        .{
            "u16",
            ZigType{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = 16,
                },
            },
        },
        .{
            "i16",
            ZigType{
                .Int = .{
                    .signedness = .signed,
                    .bits = 16,
                },
            },
        },
        .{
            "u32",
            ZigType{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = 32,
                },
            },
        },
        .{
            "i32",
            ZigType{
                .Int = .{
                    .signedness = .signed,
                    .bits = 32,
                },
            },
        },
        .{
            "u64",
            ZigType{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = 64,
                },
            },
        },
        .{
            "i64",
            ZigType{
                .Int = .{
                    .signedness = .signed,
                    .bits = 64,
                },
            },
        },
        .{
            "usize",
            ZigType{
                .Int = .{
                    .signedness = .signed,
                    .bits = @bitSizeOf(usize),
                },
            },
        },

        .{
            "f32",
            ZigType{
                .Float = .{
                    .bits = 32,
                },
            },
        },
        .{
            "f64",
            ZigType{
                .Float = .{
                    .bits = 64,
                },
            },
        },

        .{
            "bool",
            ZigType{ .Bool = {} },
        },
        .{
            "void",
            ZigType{
                .Void = {},
            },
        },
    },
);

pub const Zdef = struct {
    name: []const u8,
    type_def: *o.ObjTypeDef,
    zig_type: ZigType,
};

pub const State = struct {
    source: t.Token,
    ast: Ast,
    parser: ?*p.Parser,
    parsing_type_expr: bool = false,
};

gc: *m.GarbageCollector,
reporter: Reporter,
state: ?State = null,
type_expr_cache: std.StringHashMap(?*Zdef),

pub fn init(gc: *m.GarbageCollector) Self {
    return .{
        .gc = gc,
        .reporter = .{
            .allocator = gc.allocator,
            .error_prefix = "FFI",
        },
        .type_expr_cache = std.StringHashMap(?*Zdef).init(gc.allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.type_expr_cache.deinit();
}

pub fn parseTypeExpr(self: *Self, ztype: []const u8) !?*Zdef {
    if (self.type_expr_cache.get(ztype)) |zdef| {
        return zdef;
    }

    var full = std.ArrayList(u8).init(self.gc.allocator);
    defer full.deinit();

    full.writer().print("const zig_type: {s};", .{ztype}) catch @panic("Out of memory");

    var zdef = try self.parse(
        null,
        t.Token.identifier(full.items),
        true,
    );

    self.type_expr_cache.put(ztype, zdef) catch @panic("Out of memory");

    return zdef;
}

pub fn parse(self: *Self, parser: ?*p.Parser, source: t.Token, parsing_type_expr: bool) !?*Zdef {
    // TODO: maybe an Arena allocator for those kinds of things that can live for the whole process lifetime
    const duped = self.gc.allocator.dupeZ(u8, source.literal_string.?) catch @panic("Out of memory");
    // defer self.gc.allocator.free(duped);

    self.state = .{
        .parsing_type_expr = parsing_type_expr,
        .source = source,
        .parser = parser,
        .ast = Ast.parse(
            self.gc.allocator,
            duped,
            .zig,
        ) catch @panic("Could not parse zdef"),
    };
    defer self.state = null;

    for (self.state.?.ast.errors) |err| {
        if (!err.is_note) {
            self.reportZigError(err);
        }
    }

    if (self.state.?.ast.errors.len > 0) {
        return null;
    }

    const root_decls = self.state.?.ast.rootDecls();

    if (root_decls.len > 1) {
        self.reporter.report(
            .zdef,
            self.state.?.source,
            "Only one declaration is allowed in zdef",
        );
    } else if (root_decls.len == 0) {
        self.reporter.report(
            .zdef,
            self.state.?.source,
            "At least one declaration is required in zdef",
        );

        return null;
    }

    return self.getZdef(root_decls[0]);
}

fn getZdef(self: *Self, decl_index: Ast.Node.Index) !?*Zdef {
    const decl = self.state.?.ast.nodes.get(decl_index);

    return switch (decl.tag) {
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => try self.fnProto(decl.tag, decl_index),

        .identifier => try self.identifier(decl_index),

        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        => try self.ptrType(decl.tag, decl_index),

        .simple_var_decl => var_decl: {
            // Allow simple type if we're parsing type expr, or struct type
            if (self.state.?.parsing_type_expr) {
                break :var_decl try self.getZdef(self.state.?.ast.simpleVarDecl(decl_index).ast.type_node);
            }

            switch (self.state.?.ast.nodes.get(self.state.?.ast.simpleVarDecl(decl_index).ast.init_node).tag) {
                .container_decl,
                .container_decl_trailing,
                .container_decl_two,
                .container_decl_two_trailing,
                .container_decl_arg,
                .container_decl_arg_trailing,
                => break :var_decl try self.containerDecl(
                    self.state.?.ast.tokenSlice(self.state.?.ast.nodes.get(self.state.?.ast.simpleVarDecl(decl_index).ast.type_node).data.rhs),
                    self.state.?.ast.simpleVarDecl(decl_index).ast.init_node,
                ),
                else => {},
            }

            self.reporter.reportErrorFmt(
                .zdef,
                self.state.?.source,
                "Unsupported zig node `{}`: only C ABI compatible function signatures, structs and enums are supported",
                .{decl.tag},
            );
            break :var_decl null;
        },

        // TODO: do we support container_field and container_field_align?
        .container_field_init => try self.containerField(decl_index),

        else => fail: {
            self.reporter.reportErrorFmt(
                .zdef,
                self.state.?.source,
                "Unsupported zig node `{}`: only C ABI compatible function signatures, structs and enums are supported",
                .{decl.tag},
            );
            break :fail null;
        },
    };
}

fn containerDecl(self: *Self, name: []const u8, decl_index: Ast.Node.Index) anyerror!*Zdef {
    const container_node = self.state.?.ast.nodes.get(decl_index);

    var buf: [2]Ast.Node.Index = undefined;
    const container = switch (container_node.tag) {
        .container_decl => self.state.?.ast.containerDecl(decl_index),
        .container_decl_trailing => self.state.?.ast.containerDecl(decl_index),
        .container_decl_two => self.state.?.ast.containerDeclTwo(&buf, decl_index),
        .container_decl_two_trailing => self.state.?.ast.containerDeclTwo(&buf, decl_index),
        .container_decl_arg => self.state.?.ast.containerDeclArg(decl_index),
        .container_decl_arg_trailing => self.state.?.ast.containerDecl(decl_index),
        else => unreachable,
    };

    if (container.layout_token == null or self.state.?.ast.tokens.get(container.layout_token.?).tag != .keyword_extern) {
        self.reporter.reportErrorAt(
            .zdef,
            self.state.?.source,
            "Only `extern` structs are supported",
        );
    }

    if (self.state.?.ast.tokens.get(container_node.main_token).tag != .keyword_struct) {
        self.reporter.reportErrorAt(
            .zdef,
            self.state.?.source,
            "Unsupported type",
        );
    }

    var fields = std.ArrayList(ZigType.StructField).init(self.gc.allocator);
    var get_set_fields = std.StringArrayHashMap(o.ObjForeignStruct.StructDef.StructField).init(self.gc.allocator);
    var buzz_fields = std.StringArrayHashMap(*o.ObjTypeDef).init(self.gc.allocator);
    var decls = std.ArrayList(ZigType.Declaration).init(self.gc.allocator);
    var offset: usize = 0;
    var next_field: ?*Zdef = null;
    for (container.ast.members, 0..) |member, idx| {
        const member_zdef = next_field orelse try self.getZdef(member);

        next_field = if (idx < container.ast.members.len - 1)
            try self.getZdef(container.ast.members[idx + 1])
        else
            null;

        try fields.append(
            ZigType.StructField{
                .name = member_zdef.?.name,
                .type = &member_zdef.?.zig_type,
                .default_value = null,
                .is_comptime = false,
                .alignment = member_zdef.?.zig_type.alignment(),
            },
        );

        try decls.append(
            ZigType.Declaration{
                .name = member_zdef.?.name,
            },
        );

        try buzz_fields.put(
            member_zdef.?.name,
            member_zdef.?.type_def,
        );

        try get_set_fields.put(
            member_zdef.?.name,
            .{
                .offset = offset,
                .getter = undefined,
                .setter = undefined,
            },
        );

        offset += member_zdef.?.zig_type.size();

        // Round up the end of the previous field to a multiple of the next field's alignment
        if (next_field) |next| {
            const next_field_align = next.zig_type.alignment();
            const current_field_size = member_zdef.?.zig_type.size();

            const div = @as(f64, @floatFromInt(current_field_size)) / @as(f64, @floatFromInt(next_field_align));
            const fpart = std.math.modf(div).fpart;
            const padding = @as(usize, @intFromFloat(fpart * @as(f64, @floatFromInt(next_field_align))));

            offset += padding;
        }
    }

    const zig_type = ZigType{
        .Struct = .{
            .layout = .Extern,
            .fields = fields.items,
            .decls = decls.items,
            .is_tuple = false,
        },
    };

    const foreign_def = o.ObjForeignStruct.StructDef{
        .location = self.state.?.source,
        .name = try self.gc.copyString(name),
        // FIXME
        .qualified_name = try self.gc.copyString(name),
        .zig_type = zig_type,
        .buzz_type = buzz_fields,
        .fields = get_set_fields,
    };

    const type_def = o.ObjTypeDef{
        .def_type = .ForeignStruct,
        .resolved_type = .{ .ForeignStruct = foreign_def },
    };

    var zdef = try self.gc.allocator.create(Zdef);
    zdef.* = .{
        .type_def = try self.gc.type_registry.getTypeDef(type_def),
        .zig_type = zig_type,
        .name = name,
    };

    return zdef;
}

fn containerField(self: *Self, decl_index: Ast.Node.Index) anyerror!*Zdef {
    const container_field = self.state.?.ast.containerFieldInit(decl_index);

    var zdef = (try self.getZdef(container_field.ast.type_expr)).?;
    zdef.name = self.state.?.ast.tokenSlice(self.state.?.ast.nodes.get(decl_index).main_token);

    return zdef;
}

fn identifier(self: *Self, decl_index: Ast.Node.Index) anyerror!*Zdef {
    const id = self.state.?.ast.tokenSlice(self.state.?.ast.nodes.get(decl_index).main_token);

    var type_def = if (basic_types.get(id)) |basic_type|
        basic_type
    else
        null;
    var zig_type = if (zig_basic_types.get(id)) |zig_basic_type|
        zig_basic_type
    else
        null;

    if ((type_def == null or zig_type == null) and self.state.?.parser != null) {
        const global_idx = try self.state.?.parser.?.resolveGlobal(null, t.Token.identifier(id));
        const global = if (global_idx) |idx|
            self.state.?.parser.?.globals.items[idx]
        else
            null;

        if (global != null and global.?.type_def.def_type == .ForeignStruct) {
            type_def = global.?.type_def.*;
            zig_type = global.?.type_def.resolved_type.?.ForeignStruct.zig_type;
        }
    }

    if (type_def == null or zig_type == null) {
        // TODO: search for struct names
        self.reporter.reportErrorFmt(
            .zdef,
            self.state.?.source,
            "Unknown or unsupported type `{s}`",
            .{id},
        );
    }

    var zdef = try self.gc.allocator.create(Zdef);
    zdef.* = .{
        .type_def = try self.gc.type_registry.getTypeDef(type_def orelse .{ .def_type = .Void }),
        .zig_type = zig_type orelse ZigType{ .Void = {} },
        .name = id,
    };

    return zdef;
}

fn ptrType(self: *Self, tag: Ast.Node.Tag, decl_index: Ast.Node.Index) anyerror!*Zdef {
    const ptr_type = switch (tag) {
        .ptr_type_aligned => self.state.?.ast.ptrTypeAligned(decl_index),
        .ptr_type_sentinel => self.state.?.ast.ptrTypeSentinel(decl_index),
        .ptr_type => self.state.?.ast.ptrType(decl_index),
        else => unreachable,
    };

    var zdef = try self.gc.allocator.create(Zdef);

    const child_type = (try self.getZdef(ptr_type.ast.child_type)).?;
    const sentinel_node = self.state.?.ast.nodes.get(ptr_type.ast.sentinel);

    // Is it a null terminated string?
    // zig fmt: off
    zdef.* = if (ptr_type.const_token != null
        and child_type.zig_type == .Int
        and child_type.zig_type.Int.bits == 8
        and sentinel_node.tag == .number_literal
        and std.mem.eql(u8, self.state.?.ast.tokenSlice(sentinel_node.main_token), "0"))
        // zig fmt: on
        .{
            .type_def = try self.gc.type_registry.getTypeDef(.{ .def_type = .String }),
            .zig_type = ZigType{
                .Pointer = .{
                    .size = .C,
                    .is_const = ptr_type.const_token != null,
                    .is_volatile = undefined,
                    .alignment = undefined,
                    .address_space = undefined,
                    .child = &child_type.zig_type,
                    .is_allowzero = undefined,
                    .sentinel = undefined,
                },
            },
            .name = "string",
        }
    else
        .{
            .type_def = try self.gc.type_registry.getTypeDef(.{ .def_type = .UserData }),
            .zig_type = ZigType{
                .Pointer = .{
                    .size = .C,
                    .is_const = ptr_type.const_token != null,
                    .is_volatile = undefined,
                    .alignment = undefined,
                    .address_space = undefined,
                    .child = &child_type.zig_type,
                    .is_allowzero = undefined,
                    .sentinel = undefined,
                },
            },
            .name = "string",
        };

    return zdef;
}

fn fnProto(self: *Self, tag: Ast.Node.Tag, decl_index: Ast.Node.Index) anyerror!*Zdef {
    var buffer = [1]Ast.Node.Index{undefined};
    const fn_proto = switch (tag) {
        .fn_proto_simple => self.state.?.ast.fnProtoSimple(&buffer, decl_index),
        .fn_proto_one => self.state.?.ast.fnProtoOne(&buffer, decl_index),
        .fn_proto => self.state.?.ast.fnProto(decl_index),
        .fn_proto_multi => self.state.?.ast.fnProtoMulti(decl_index),
        else => unreachable,
    };
    const return_type_zdef = try self.getZdef(fn_proto.ast.return_type);

    const name = if (fn_proto.name_token) |token| self.state.?.ast.tokenSlice(token) else null;

    if (name == null) {
        self.reporter.report(
            .zdef,
            self.state.?.source,
            "Functions must be named",
        );
    }

    var function_def = o.ObjFunction.FunctionDef{
        .id = o.ObjFunction.FunctionDef.nextId(),
        .name = try self.gc.copyString(name orelse "unknown"),
        .script_name = try self.gc.copyString(self.state.?.source.script_name),
        .return_type = if (return_type_zdef) |return_type|
            return_type.type_def
        else
            try self.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
        .yield_type = try self.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
        .parameters = std.AutoArrayHashMap(*o.ObjString, *o.ObjTypeDef).init(self.gc.allocator),
        .defaults = std.AutoArrayHashMap(*o.ObjString, v.Value).init(self.gc.allocator),
        .function_type = .Extern,
        .generic_types = std.AutoArrayHashMap(*o.ObjString, *o.ObjTypeDef).init(self.gc.allocator),
    };

    var parameters_zig_types = std.ArrayList(ZigType.Fn.Param).init(self.gc.allocator);
    var zig_fn_type = ZigType.Fn{
        .calling_convention = .C,
        // How could it be something else?
        .alignment = 4,
        .is_generic = false,
        .is_var_args = false,
        .return_type = if (return_type_zdef) |return_type|
            &return_type.zig_type
        else
            null,
        .params = undefined,
    };

    var it = fn_proto.iterate(&self.state.?.ast);
    while (it.next()) |param| {
        const param_name = if (param.name_token) |param_name_token|
            self.state.?.ast.tokenSlice(param_name_token)
        else
            null;

        if (param_name == null) {
            self.reporter.report(
                .zdef,
                self.state.?.source,
                "Please provide name to functions arguments",
            );
        }

        const param_zdef = try self.getZdef(param.type_expr);

        try function_def.parameters.put(
            try self.gc.copyString(param_name orelse "$"),
            param_zdef.?.type_def,
        );

        try parameters_zig_types.append(
            .{
                .is_generic = false,
                .is_noalias = false,
                .type = &param_zdef.?.zig_type,
            },
        );
    }

    parameters_zig_types.shrinkAndFree(parameters_zig_types.items.len);
    zig_fn_type.params = parameters_zig_types.items;

    var type_def = o.ObjTypeDef{
        .def_type = .Function,
        .resolved_type = .{ .Function = function_def },
    };

    var zdef = try self.gc.allocator.create(Zdef);
    zdef.* = .{
        .zig_type = ZigType{ .Fn = zig_fn_type },
        .type_def = try self.gc.type_registry.getTypeDef(type_def),
        .name = name orelse "unknown",
    };

    return zdef;
}

fn reportZigError(self: *Self, err: Ast.Error) void {
    var message = std.ArrayList(u8).init(self.gc.allocator);
    defer message.deinit();

    message.writer().print("zdef could not be parsed: {}", .{err.tag}) catch unreachable;

    self.reporter.report(
        .zdef,
        self.state.?.source,
        message.items,
    );
}