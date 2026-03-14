const std = @import("std");
const mem = std.mem;
const request_mod = @import("request.zig");
const response_mod = @import("response.zig");
const Request = request_mod.Request;
const Response = response_mod.Response;
const Method = request_mod.Method;

pub const Handler = *const fn (*Request, *Response) void;

pub const MatchType = enum {
    exact,
    prefix,
};

pub const Route = struct {
    method: ?Method,
    path: []const u8,
    handler: Handler,
    match_type: MatchType = .exact,
};

pub fn get(path: []const u8, handler: Handler) Route {
    return .{ .method = .GET, .path = path, .handler = handler };
}

pub fn post(path: []const u8, handler: Handler) Route {
    return .{ .method = .POST, .path = path, .handler = handler };
}

pub fn put(path: []const u8, handler: Handler) Route {
    return .{ .method = .PUT, .path = path, .handler = handler };
}

pub fn delete(path: []const u8, handler: Handler) Route {
    return .{ .method = .DELETE, .path = path, .handler = handler };
}

pub fn prefix(path: []const u8, handler: Handler) Route {
    return .{ .method = null, .path = path, .handler = handler, .match_type = .prefix };
}

pub const MatchResult = enum {
    found,
    not_found,
    method_not_allowed,
};

pub const RouteMatch = struct {
    result: MatchResult,
    handler: ?Handler = null,
};

pub fn match(routes: []const Route, method: Method, path: []const u8) RouteMatch {
    var path_matched = false;

    for (routes) |route| {
        const path_matches = switch (route.match_type) {
            .exact => mem.eql(u8, route.path, path),
            .prefix => mem.startsWith(u8, path, route.path),
        };

        if (path_matches) {
            if (route.method == null or route.method.? == method) {
                return .{ .result = .found, .handler = route.handler };
            }
            path_matched = true;
        }
    }

    if (path_matched) {
        return .{ .result = .method_not_allowed };
    }
    return .{ .result = .not_found };
}

const testing = std.testing;

pub fn dummyHandler(_: *Request, _: *Response) void {}
pub fn dummyHandler2(_: *Request, _: *Response) void {}
