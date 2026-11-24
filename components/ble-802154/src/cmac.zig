//! ble-802154：AES-CMAC 与数据签名（ATT_SIGNED_WRITE_CMD 的 Authentication Signature）。
//!
//! 规范出处（Bluetooth Core Specification v5.4）：
//!   * AES-CMAC —— [Vol 3] Part H §2.2.5 指向 RFC 4493；向量在 [Vol 3] Part H 附录 D.1
//!     （与 RFC 4493 的四个例子相同），全零密钥的向量在 [Vol 3] Part G 附录 B；
//!   * 签名算法 —— [Vol 3] Part H §2.4.5：MAC 截成 64 位（Tlen），被签的消息
//!     M = m ‖ SignCounter，SignCounter 最低有效字节在前；验签方应记住最近一次验签
//!     通过的 SignCounter，只接受更大的值（防重放）；
//!   * 例子 —— [Vol 3] Part F §3.4.5.4：m = D2 12 00 13 37，SignCounter = 0x00000001，
//!     CSRK = 611B64EB FBCD1FD3 72EC9196 DF425E50，签名 = 01 00 00 00 F1 87 1E 93 3C 90 0F F2。
//!
//! 字节序：`cmac` 的密钥、消息、输出都是 RFC 4493 的字节串顺序（十六进制写法里最左边的
//! 字节最先进入分组密码），也就是 [Vol 3] Part H 各附录里「最高有效字节在左」的写法。
//!
//! 签名有两处 Bluetooth 特有的字节序，[Vol 3] Part H §2.4.5 的文字没有写，只能从
//! [Vol 3] Part F §3.4.5.4 的例子反推，本文件以例子为准：
//!
//!   1. 待签消息进 CMAC 之前整段字节反转。直接对 M = D2 12 00 13 37 01 00 00 00 做
//!      RFC 4493 的 CMAC 得不到例子里的 MAC；对反转后的 00 00 00 01 37 13 00 12 D2 做，
//!      才得到例子里的 F20F903C 931E87F1 59B64F01 2574B4D0。
//!   2. 取出的 64 位是 CMAC 结果里最高有效的 64 位（F2 0F 90 3C 93 1E 87 F1），写进 PDU
//!      时按最低有效字节在前（F1 87 1E 93 3C 90 0F F2）。
//!
//! 本机 IDF v6.1 的 NimBLE 做法相同：`ble_att_svr_rx_signed_write` 与
//! `ble_att_clt_tx_signed_write_cmd` 都先 `swap_in_place(message, len)` 再算 CMAC，
//! 再取反转后 CMAC 的后 8 字节。
//!
//! 反转不需要另开缓冲：CMAC 是按 16 字节分组的，把消息从尾向头每 16 字节取一段、
//! 段内反转后喂给 `update`，效果与整段反转后一次喂入相同。
//!
//! 分组密码与 CMAC 本体用 Zig 标准库（`std.crypto.auth.cmac.CmacAes128`，RFC 4493），
//! 本文件只实现 Bluetooth 加在上面的部分。

const std = @import("std");

const Cmac = std.crypto.auth.cmac.CmacAes128;

/// 签名的长度：SignCounter 4 字节 + 64 位 MAC（表 3.33 的 Authentication Signature）。
pub const sig_len = 12;
/// MAC 保留的字节数（[Vol 3] Part H §2.4.5：Tlen = 64 位）。
pub const mac_len = 8;

/// AES-CMAC（RFC 4493）。密钥、消息、输出都是 RFC 的字节串顺序。
pub fn cmac(key: [16]u8, msg: []const u8) [16]u8 {
    var out: [16]u8 = undefined;
    Cmac.create(&out, msg, &key);
    return out;
}

/// 把 `msg` 整段字节反转后喂给 `ctx`：从尾向头每 16 字节一段，段内反转。
fn feedReversed(ctx: *Cmac, msg: []const u8) void {
    var end = msg.len;
    while (end >= 16) : (end -= 16) {
        var block: [16]u8 = undefined;
        for (0..16) |i| block[i] = msg[end - 1 - i];
        ctx.update(&block);
    }
    if (end > 0) {
        var head: [15]u8 = undefined;
        for (0..end) |i| head[i] = msg[end - 1 - i];
        ctx.update(head[0..end]);
    }
}

/// 生成签名：SignCounter（最低有效字节在前）‖ 64 位 MAC。
///
/// `m` 是被签的变量长消息；对 ATT_SIGNED_WRITE_CMD 就是操作码加参数，即去掉末尾
/// 12 字节签名后的整个 PDU（[Vol 3] Part F §3.3.1）。`counter` 是本方 CSRK 的
/// SignCounter，每签一次加一（[Vol 3] Part H §2.4.5）。
pub fn sign(csrk: [16]u8, counter: u32, m: []const u8) [sig_len]u8 {
    var ctr: [4]u8 = undefined;
    std.mem.writeInt(u32, &ctr, counter, .little);

    var ctx = Cmac.init(&csrk);
    // M = m ‖ SignCounter；反转后 SignCounter 在最前。
    ctx.update(&.{ ctr[3], ctr[2], ctr[1], ctr[0] });
    feedReversed(&ctx, m);
    const t = ctx.finalResult();

    var sig: [sig_len]u8 = undefined;
    @memcpy(sig[0..4], &ctr);
    for (0..mac_len) |i| sig[4 + i] = t[7 - i];
    return sig;
}

/// 验签：用收到的 SignCounter 重算并比较 MAC（常数时间）。不含 SignCounter 的新鲜度
/// 检查，那一步由调用方拿自己存的计数器做（[Vol 3] Part H §2.4.5）。
pub fn verify(csrk: [16]u8, m: []const u8, sig: [sig_len]u8) bool {
    const counter = std.mem.readInt(u32, sig[0..4], .little);
    const want = sign(csrk, counter, m);
    return std.crypto.timing_safe.eql([sig_len]u8, want, sig);
}

/// 签名里的 SignCounter。
pub fn counterOf(sig: [sig_len]u8) u32 {
    return std.mem.readInt(u32, sig[0..4], .little);
}
