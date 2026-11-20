/*
 * BLE controller 适配面里"由我们提供"的那几个符号。
 *
 * 清单来自离线量算（`nm` 并集 → 减归档自身定义 → 减 ROM → 减同族归档）：
 *   libble_app.a + libbtdm_common.a + libbtbb.a + libphy.a
 *   选择性闭包 113 个对象，减 ROM 后剩 10 个，其中 5 个是链接脚本符号
 *   （见 boards/esp32s31-coreboard/linker/s31.ld 的 btdm 边界），本文件给其余 5 个。
 *
 * 这些函数的返回/参数形态是按归档里的调用点反查出来的，不是猜的：
 *   - `e_btdm_lp_modem_clock_set`：调用点先 `li a0, 0`（一个整型实参），返回值被丢弃；
 *   - `rtc_clk_xtal_freq_get`：无参，返回值参与运算（晶振频率）；
 *   - `phy_printf` / `sprintf`：C 变参，Zig 定义不了，只能放在 C 里；
 *   - `__assert_func`：newlib 的断言钩子，四个参数。
 *
 * 与 wifi-blobs 的 zz_stubs.c 是**不同的符号集**：两套不要同时链进同一个镜像。
 */

typedef unsigned int u32;

/* newlib 断言钩子。controller 断言时把定位信息打到串口再挂住——否则板子上只会
 * 静默死循环，看不到任何线索。用 ROM 的 printf（标准 %s/%d，controller 就是这么调的）。 */
extern int ets_printf(const char *format, ...);

/* BLE 侧的打印走 PHY 的 C 变参函数；裸机上没有 vprintf 实现，丢弃。 */

/* controller 内部用 sprintf 拼日志/版本串；给个最小实现，避免把 libc 拉进来。 */
int sprintf(char *buf, const char *format, ...) {
    (void)format;
    if (buf) buf[0] = 0;
    return 0;
}

/* 晶振频率（**单位 Hz**）：本板 40 MHz 晶振，即 40 000 000。
 * controller 的全部时基（定时器、退避、CCA 窗口）都从这个值推，写错不会崩、
 * 只会变成"超时窗口大到离谱"这类静默错误 ⇒ 直接问 ROM，别自己填常数。 */
extern u32 ets_clk_get_xtal_freq(void);


/* 低功耗 modem 时钟开关：控制器在 lp 初始化时关一次（实参恒为 0）。
 * 我们的时钟树由 board 层统一管理，这里只记录不动作。 */
int e_btdm_lp_modem_clock_set(int enable) {
    (void)enable;
    return 0;
}

/* ---------------------------------------------------------------------------
 * 承重假设验证（2026-11-17）：归档里的 `wr_btdm_*` 都是**弱定义**的断言桩，
 * 我们在这里给**强定义**，链接器应当选我们这份（ELF 规则：强覆盖弱）。
 *
 * 签名取自 IDF 的参考实现 `porting_btdm/controller/btdm_common/src/btdm_log.c:102`：
 *   void wr_btdm_assert(const char *file, int line, int p0, int p1, uint8_t type)
 * 归档里的调用点也能对上（a0=file, a1=行号, a2/a3=参数, a4=type）。
 *
 * 标记串 `bt-blob-strong-assert` 用于验证：镜像里出现它 ⇒ 被选中的是我们的实现。
 * ------------------------------------------------------------------------- */
extern int ets_printf(const char *format, ...);

/* 断言行为分两档，由 `BT_ASSERT_RETURNS` 选择：
 *   - 未定义（**生产默认**）：打印后**挂住**——断言就是要停下来；
 *   - 定义（**探针构建**）：打印后**返回**——挂住只能说明"到了某处"，
 *     返回才能看出后续还能走多远（本轮实验证明这里不是卡点，命中 0 次）。
 * 命中次数记在 `bt_assert_hits`，便于事后统计。 */
unsigned bt_assert_hits = 0;

/* **2026-11-21 改版**：直写 + 恒 halt。旧探针档（打印后返回）在 btdm_sleep.c:684
 * 实证为害：blob 的断言点不检查返回值，直接 `jalr obj[4]（NULL）` ⇒ 取指 fault @0
 * ⇒ double fault ⇒ rst:0x1a ×35 风暴。断言是终止性的（IDF 语义），返回没有意义。
 * 直写走 s31_bt_raw_line（bringup.zig 导出，绕 shim 的 mute/FIFO 丢弃）——
 * 断言文本必须可见（本次靠手挖 .rodata 才拿到 btdm_sleep.c:684）。 */
extern void s31_bt_raw_line(const char *s);

void wr_btdm_assert(const char *file, int line, int p0, int p1, unsigned char type) {
    bt_assert_hits++;
    char buf[128];
    int n = 0;
    const char *src = "bt-blob-strong-assert ";
    while (*src && n < (int)sizeof buf - 1) buf[n++] = *src++;
    src = file ? file : "?";
    while (*src && n < (int)sizeof buf - 1) buf[n++] = *src++;
    {
        /* 手写十进制（freestanding 无 snprintf）；:line p0=.. type=.. 全保留 */
        buf[n++] = ':';
        if (line < 0) { buf[n++] = '-'; line = -line; }
        char tmp[12]; int t = 0;
        do { tmp[t++] = (char)('0' + line % 10); line /= 10; } while (line && t < 12);
        while (t && n < (int)sizeof buf - 1) buf[n++] = tmp[--t];
        const char *sfx = " p0=? type=?";
        while (*sfx && n < (int)sizeof buf - 1) buf[n++] = *sfx++;
    }
    buf[n] = 0;
    s31_bt_raw_line(buf);
    for (;;) {
    }
}

/* ---------------------------------------------------------------------------
 * 8 个 `wr_btdm_log_*`（2026-11-17）
 *
 * controller 在 init 阶段就会写日志 ⇒ 这 8 个弱桩是**第一个会被调到的**，
 * 不覆盖就会在"第一行日志"上断言挂住。签名取自 IDF 参考实现
 * `porting_btdm/controller/btdm_common/src/btdm_log.c:29-95`。
 *
 * 注意：`log_internal_x*` / `log_internal_hex` 的参数是**整数**，不是格式串
 * （IDF 内部按 p0 去查一张日志表）。我们没有那张表，所以只打印数值——
 * 目的就是"第一行日志能出来"这个可观测判据，不是还原原文。
 * ------------------------------------------------------------------------- */
static unsigned char s_log_flags;

void wr_btdm_log_set_flags(unsigned char p0) { s_log_flags = p0; }
void wr_btdm_log_reset_flags(unsigned char p0) { (void)p0; s_log_flags = 0; }

/* **对照实验**：`BT_LOG_SILENT=1` 时这些桩不写串口。
 * 动机：板侧显示 UART0_STATUS.TXFIFO_CNT 恒 128（FIFO 满且不排空），
 * 且 OSAL 调用序列只打出一行就再无输出 ⇒ 先排除"controller 的日志把 UART 灌死"。 */
#ifndef BT_LOG_SILENT
#define BT_LOG_SILENT 0
#endif

void wr_btdm_log_internal_x0(unsigned int p0) {
#if !BT_LOG_SILENT
    ets_printf("bt-log x0 %u\n", p0);
#else
    (void)p0;
#endif
}
void wr_btdm_log_internal_x1(unsigned int p0, unsigned int p1) {
#if !BT_LOG_SILENT
    ets_printf("bt-log x1 %u %u\n", p0, p1);
#else
    (void)p0; (void)p1;
#endif
}
void wr_btdm_log_internal_x2(unsigned int p0, unsigned int p1, unsigned int p2) {
#if !BT_LOG_SILENT
    ets_printf("bt-log x2 %u %u %u\n", p0, p1, p2);
#else
    (void)p0; (void)p1; (void)p2;
#endif
}
void wr_btdm_log_internal_x3(unsigned int p0, unsigned int p1, unsigned int p2, unsigned int p3) {
#if !BT_LOG_SILENT
    ets_printf("bt-log x3 %u %u %u %u\n", p0, p1, p2, p3);
#else
    (void)p0; (void)p1; (void)p2; (void)p3;
#endif
}
void wr_btdm_log_internal_hex(unsigned int p0, unsigned int p1, unsigned int p2) {
#if !BT_LOG_SILENT
    ets_printf("bt-log hex %u %x %x\n", p0, p1, p2);
#else
    (void)p0; (void)p1; (void)p2;
#endif
}
void wr_btdm_log_raw_export(unsigned short p0, unsigned int p1, unsigned int p2) {
#if !BT_LOG_SILENT
    ets_printf("bt-log raw %u %u %u\n", (unsigned)p0, p1, p2);
#else
    (void)p0; (void)p1; (void)p2;
#endif
}
