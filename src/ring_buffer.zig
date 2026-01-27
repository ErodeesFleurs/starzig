const std = @import("std");
const mem = std.mem;

pub const RingBuffer = struct {
    data: []u8,
    read_pos: usize = 0,
    write_pos: usize = 0,
    full: bool = false,

    pub fn init(gpa: mem.Allocator, capacity: usize) !RingBuffer {
        const data = try gpa.alloc(u8, capacity);
        return RingBuffer{
            .data = data,
        };
    }

    pub fn deinit(self: *RingBuffer, gpa: mem.Allocator) void {
        gpa.free(self.data);
    }

    pub fn readableLen(self: RingBuffer) usize {
        if (self.full) return self.data.len;
        if (self.write_pos >= self.read_pos) {
            return self.write_pos - self.read_pos;
        }
        return self.data.len - self.read_pos + self.write_pos;
    }

    pub fn writableLen(self: RingBuffer) usize {
        if (self.full) return 0;
        if (self.write_pos >= self.read_pos) {
            return self.data.len - self.write_pos + self.read_pos;
        }
        return self.read_pos - self.write_pos;
    }

    pub fn writeSlice(self: *RingBuffer) []u8 {
        if (self.full) return self.data[0..0];
        if (self.write_pos >= self.read_pos) {
            return self.data[self.write_pos..];
        }
        return self.data[self.write_pos..self.read_pos];
    }

    pub fn advanceWrite(self: *RingBuffer, n: usize) void {
        if (n == 0) return;
        self.write_pos = (self.write_pos + n) % self.data.len;
        if (self.write_pos == self.read_pos) self.full = true;
    }

    pub fn advanceRead(self: *RingBuffer, n: usize) void {
        if (n == 0) return;
        self.read_pos = (self.read_pos + n) % self.data.len;
        self.full = false;
    }

    /// 确保从 read_pos 开始有 n 字节的连续内存
    /// 使用内部 memmove 避免外部分配，提高性能
    pub fn linearize(self: *RingBuffer, n: usize) ![]u8 {
        const available = self.readableLen();
        if (n > available) return error.NoData;

        // 如果已经是连续的
        if (self.read_pos + n <= self.data.len) {
            return self.data[self.read_pos .. self.read_pos + n];
        }

        // 需要重整：跨越了边界
        // 简单方案：将所有数据移回头部
        const temp_max = 65536; // 64KB 栈分配上限
        if (available <= temp_max) {
            var stack_buf: [temp_max]u8 = undefined;
            const p1 = self.data[self.read_pos..];
            const p2 = self.data[0..self.write_pos];
            @memcpy(stack_buf[0..p1.len], p1);
            @memcpy(stack_buf[p1.len..available], p2);
            @memcpy(self.data[0..available], stack_buf[0..available]);
        } else {
            // 如果极大，分配一次
            const temp = try std.heap.page_allocator.alloc(u8, available);
            defer std.heap.page_allocator.free(temp);
            const p1 = self.data[self.read_pos..];
            const p2 = self.data[0..self.write_pos];
            @memcpy(temp[0..p1.len], p1);
            @memcpy(temp[p1.len..available], p2);
            @memcpy(self.data[0..available], temp);
        }

        self.read_pos = 0;
        self.write_pos = available;
        // full 状态由 readableLen 确定，如果 available == data.len 则 full
        self.full = (available == self.data.len);

        return self.data[0..n];
    }
};
