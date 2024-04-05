const std = @import("std");

/// Computes a simple equality check, recording the successive indices of hackstack
/// that match successive characters in needle.
fn firstMatch(
    comptime T: type,
    allocator: std.mem.Allocator,
    hackstack: []const T,
    needle: []const T,
) ![]const usize {

    // allocate maximum
    var matches = try std.ArrayList(usize).initCapacity(allocator, needle.len);
    defer matches.deinit();

    var index: usize = 0;
    for (0.., hackstack) |i, t| {
        if (index >= needle.len) break;
        const p = needle[index];

        if (t == p) {
            matches.appendAssumeCapacity(i);
            index += 1;
        }
    }

    matches.shrinkAndFree(matches.items.len);
    return try matches.toOwnedSlice();
}

// Matrix Filling: for two sequences a1a2a3..., b1b2b3... we have a reward
// function
//
//     s(a_i, b_j) = { +SCORE  if a_i == b_j     # match
//                   { -SCORE  if a_i != b_j     # mitmatch
//
//     s(-, b_j) = -PENALTY if a_i == -          # insertion
//     s(a_i, -) = -PENALTY if b_j == -          # deletion
//
// Here `-` is a placeholder to represent an "unknown" or gap in the sequence.
//
//                  { M[i-1,j-1] + s(a_i, b_i)   # up and left
//     M[i,j] = max { M[i,j-1] + s(a_i, -)       # left
//                  { M[i-1,j] + s(-, b_i)       # up
//                  { 0                          # no direction
//
// This matrix is the score of best alignment between i characters of x and j
// characters of y.
//
// For fuzzy finding want to include a gap penalty for successive gaps, i.e. so
// a run of `n` gaps incurrs less of a penalty than starting `n` individual 1
// character gaps
//
//     gaps(n) < penalty * n
//
// Gap information is contained in two new matrices tracking row and column
// gaps respectively:
//
//     X[i,j] = max { M[i,j-l] - gaps(l)     l in 1:j
//                  { Y[i,j-l] - gaps(l)     l in 1:j
//
//     Y[i,j] = max { M[i-l,j] - gaps(l)     l in 1:j
//                  { X[i-l,j] - gaps(l)     l in 1:j
//
// Cost of building these matrices is O(n^3). Instead, assume an _affine gap
// penalty_, where we differentiate the penalty for `gap_start` and
// `gap_ext` for starting a new gap or extending the existing gap.
// Requires the same three matrices but no longer search over all gap lengths,
// only need to know if we're starting a new gap
//
//                  { gap_start + gap_ext + M[i,j-1]
//     X[i,j] = max { gap_ext + X[i,j-1]
//                  { gap_start + gap_ext + Y[i,j-1]
//
// We no longer require the Y matrix, and the algorithm is now O(mn).

/// Column major matrix type.
fn MatrixT(comptime T: type) type {
    return struct {
        pub const ElementType = T;
        const Self = @This();

        allocator: std.mem.Allocator,
        matrix: []ElementType,
        rows: usize,
        cols: usize,

        pub fn init(allocator: std.mem.Allocator, rows: usize, cols: usize) !Self {
            const mem = try allocator.alloc(ElementType, cols * rows);
            return .{
                .allocator = allocator,
                .matrix = mem,
                .rows = rows,
                .cols = cols,
            };
        }

        pub fn deinit(m: *Self) void {
            m.allocator.free(m.matrix);
            m.* = undefined;
        }

        /// Get the `row` and `col` element of the matrix.
        pub fn get(m: Self, row: usize, col: usize) ElementType {
            return m.getPtr(row, col).*;
        }

        /// Set the `row` and `col` element of the matrix.
        pub fn set(m: Self, row: usize, col: usize, t: ElementType) void {
            m.getPtr(row, col).* = t;
        }

        /// Get a pointer to `row` and `col` element of the matrix.
        pub fn getPtr(m: Self, row: usize, col: usize) *ElementType {
            return &m.matrix[m.getIndex(row, col)];
        }

        /// Get the index into the array
        pub fn getIndex(m: Self, row: usize, col: usize) usize {
            std.debug.assert(row < m.rows);
            std.debug.assert(col < m.cols);
            return row * m.cols + col;
        }

        /// Get a slice into a `row` of the matrix.
        pub fn getRow(m: Self, row: usize) []ElementType {
            std.debug.assert(row < m.rows);
            const i = row * m.cols;
            return m.matrix[i .. i + m.cols];
        }
    };
}

const Algorithm = struct {
    const UT = i32;
    const Matrix = MatrixT(UT);

    const Options = struct {
        score_match: UT = 16,
        score_gap_start: UT = -3,
        score_gap_extension: UT = -1,
        // negative_infinity: UT = std.math.minInt(i16),
        negative_infinity: UT = 0,
    };

    m: Matrix,
    x: Matrix,
    skip: MatrixT(bool),
    hackstack: []const u8,
    needle: []const u8,
    allocator: std.mem.Allocator,
    opts: Options,

    pub fn init(
        allocator: std.mem.Allocator,
        hackstack: []const u8,
        needle: []const u8,
        opts: Options,
    ) !Algorithm {
        const rows = needle.len + 1;
        const cols = hackstack.len + 1;

        var m = try Matrix.init(allocator, rows, cols);
        errdefer m.deinit();
        var x = try Matrix.init(allocator, rows, cols);
        errdefer x.deinit();
        var skip = try MatrixT(bool).init(allocator, rows, cols);
        errdefer skip.deinit();

        return .{
            .m = m,
            .x = x,
            .skip = skip,
            .hackstack = hackstack,
            .needle = needle,
            .allocator = allocator,
            .opts = opts,
        };
    }

    pub fn score(self: *Algorithm) !UT {
        const first_match_indices = try firstMatch(
            u8,
            self.allocator,
            self.hackstack,
            self.needle,
        );
        defer self.allocator.free(first_match_indices);
        self.reset(first_match_indices);
        try self.populateMatrices(first_match_indices);

        const col_max = self.findMaximalElement(first_match_indices);

        // self.traceback(col_max, first_match_indices);

        const last_row_index = self.needle.len;
        return self.m.get(last_row_index, col_max);
    }

    pub fn deinit(self: *Algorithm) void {
        self.m.deinit();
        self.x.deinit();
        self.skip.deinit();
        self.* = undefined;
    }

    fn findMaximalElement(
        self: *const Algorithm,
        first_match_indices: []const usize,
    ) usize {
        // the first visted element of the last row
        const start =
            first_match_indices[first_match_indices.len - 1];
        const last_row_index = self.needle.len;
        const last_row = self.m.getRow(last_row_index);

        // iterate over the visited element of the last row
        return std.mem.indexOfMax(UT, last_row[start..]) + start;
    }

    fn traceback(
        self: *Algorithm,
        col_max: usize,
        first_match_indices: []const usize,
    ) void {
        var row = self.m.rows - 1;
        var col = col_max;

        // the first visited element in the first row
        const beginning = first_match_indices[0];

        var follow_m: bool = true;
        while (row > 0 and col > beginning) {
            const skipped = self.skip.get(row, col);
            // const el = self.m.get(row, col);

            if (follow_m) {
                row -= 1;
            }
            col -= 1;

            follow_m = !skipped;
        }
    }

    fn reset(self: *Algorithm, first_match_indices: []const usize) void {
        // set the first row and column to zero
        @memset(self.m.getRow(0), self.opts.negative_infinity);
        @memset(self.x.getRow(0), self.opts.negative_infinity);

        for (1..self.m.rows) |i| {
            const j = first_match_indices[i - 1];
            self.m.set(i, j, self.opts.negative_infinity);
            self.x.set(i, j, self.opts.negative_infinity);
        }
    }

    fn scoreFunc(self: *const Algorithm, n: u8, h: u8) ?UT {
        if (n != h) return null;
        return self.opts.score_match;
    }

    fn populateMatrices(self: *Algorithm, first_match_indices: []const usize) !void {
        for (0.., self.needle) |i, n| {

            // how many characters of the haystack do we skip
            const skip = first_match_indices[i];
            for (skip.., self.hackstack[skip..]) |j, h| {
                const prev_match_score = self.m.get(i, j);
                const prev_skip_score = self.x.get(i, j);

                std.debug.print(
                    "{d},{d}: prev {d} skip {d}\n",
                    .{ i, j, prev_match_score, prev_skip_score },
                );

                // start by updating the M matrix
                if (self.scoreFunc(n, h)) |current_score| {
                    if (prev_match_score >= prev_skip_score) {
                        const total_score = current_score + prev_match_score;
                        self.m.set(i + 1, j + 1, total_score);
                    } else {
                        const total_score = current_score + prev_skip_score;
                        self.m.set(i + 1, j + 1, total_score);
                    }
                } else {
                    self.m.set(i + 1, j + 1, self.opts.negative_infinity);
                }

                // then update the X matrix
                const x_start_score =
                    self.opts.score_gap_start +
                    self.opts.score_gap_extension +
                    prev_match_score;
                const x_extend_score =
                    self.opts.score_gap_extension +
                    prev_match_score;

                if (x_start_score >= x_extend_score) {
                    self.x.set(i + 1, j + 1, x_start_score);
                } else {
                    self.x.set(i + 1, j + 1, x_extend_score);
                }
            }
        }
    }
};

fn doTest(hackstack: []const u8, needle: []const u8) !void {
    var alg = try Algorithm.init(
        std.testing.allocator,
        hackstack,
        needle,
        .{},
    );
    defer alg.deinit();

    const s = try alg.score();
    std.debug.print("SCORE : {d}\n", .{s});
}

test "algorithm test" {
    try doTest(
        "hello world",
        "wrld",
    );
    try doTest(
        "hello world",
        "world",
    );
    try doTest(
        "hello world",
        "hello world",
    );
}
