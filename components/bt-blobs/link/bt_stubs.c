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


/* **轮 89c 真身实现**（oracle asm 解密，原为 no-op = 60+ 轮 synth 墙）：
 * task pump 每次 eventq_get 返回后调 e_btdm_lp_modem_clock_set(1)——
 * oracle 实体 = modem_clock_module_enable(6)（BT modem 时钟模块）→
 * device_control → DEVICE_EN/ICG 写。原注释"实参恒为 0"是旧误读
 * （泵在队列非空时才传 0，且 disable 路径被 oracle 的 s_bt_active==1 门住）。 */
extern int modem_clock_module_enable(int module);
extern int modem_clock_module_disable(int module);
static unsigned char s_btdm_lp_modem_clk_en = 0;

int e_btdm_lp_modem_clock_set(int enable) {
    if (enable) {
        if (!s_btdm_lp_modem_clk_en) {
            modem_clock_module_enable(6);
            s_btdm_lp_modem_clk_en = 1;
        }
    }
    /* enable==0：oracle 需 s_bt_active==0 才真关；enable 相后恒 active ⇒ no-op */
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
    *(volatile unsigned int *)0x2E000388 = (unsigned int)line; /* LP: 跨复位可读（探针 BBP 行） */
    /* **轮 124e**：限流——synth 等锁路径每轮断言打印一次，16 次轮询 × 反复重进
     * = UART 饱和（1.1MB 刷屏），把探针的 R99/ana 对拍行全挤掉。前 4 次打印保
     * 现场，之后静默（hits/LP 槽照记）。 */
    if (bt_assert_hits > 4) return;
    /* **轮 120e**：buf 128→256（ble_hw.c 全路径 86 字符把 p0/type 挤掉——占位符
     * 之谜），并打全 p0/p1/type/RA（一次 boot 拿到断言点全现场）。 */
    char buf[256];
    int n = 0;
    const char *src = "bt-blob-strong-assert ";
    while (*src && n < (int)sizeof buf - 1) buf[n++] = *src++;
    src = file ? file : "?";
    while (*src && n < (int)sizeof buf - 1) buf[n++] = *src++;
    {
        buf[n++] = ':';
        if (line < 0) { buf[n++] = '-'; line = -line; }
        char tmp[12]; int t = 0;
        do { tmp[t++] = (char)('0' + line % 10); line /= 10; } while (line && t < 12);
        while (t && n < (int)sizeof buf - 1) buf[n++] = tmp[--t];
        unsigned ra = (unsigned)__builtin_return_address(0);
        const char *sfx2 = " p0=0x";
        while (*sfx2 && n < (int)sizeof buf - 1) buf[n++] = *sfx2++;
        unsigned vals[4] = { (unsigned)p0, (unsigned)p1, (unsigned)type, ra };
        const char *sep[4] = { " p1=0x", " type=0x", " ra=0x", "" };
        for (int vi = 0; vi < 4; vi++) {
            /* 每值 8 位 hex（freestanding 无 snprintf；type 值小，前导零可容忍） */
            for (int sh = 28; sh >= 0 && n < (int)sizeof buf - 1; sh -= 4) {
                unsigned d = (vals[vi] >> sh) & 0xF;
                buf[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
            }
            const char *sx = sep[vi];
            while (*sx && n < (int)sizeof buf - 1) buf[n++] = *sx++;
        }
    }
    buf[n] = 0;
    s31_bt_raw_line(buf);
    /* **轮 16（2026-11-22）：探针构建恢复「打印后返回」**。11-21 的恒 halt 是对
     * btdm_sleep.c:684（NULL 回调 jalr）的过激反应——该风险已被 step20 的
     * 「sleep 槽非空才注册」规避。而 0x200A 的 synth-ready 轮询超时（cap 65536
     * → wr_btdm_assert）在官方同样发生（trace 实证官方 98BC=0 恒定 + 45s
     * trace 跑完不挂）⇒ 官方语义 = 打印后返回、error 3 被容忍、广播继续。
     * 恒 halt 让 0x200A 处理器把整系统冻死在其轮询里（轮 11-12 marker 实锤）。
     * **作用域**：BT_ASSERT_RETURNS=1（build-probe.sh 探针档）→ 返回；
     * 生产默认（未定义）保持恒 halt——未知断言点的返回语义未经验证。
     * 命中计数 bt_assert_hits 与 LP 0x2E000388=line 保留可观测。 */
#ifdef BT_ASSERT_RETURNS
    return; /* 探针档：返回让 0x200A 超时按官方语义被容忍 */
#else
    for (;;) {
    }
#endif
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
#define BT_LOG_SILENT 1 /* **轮 94-final**：0x200A 后 blob 门控 UART0 ⇒ 任何 blob 打印
                         * 都卡死 ROM 排空环（0x2f8036cc）。编译期全静默（README 27452
                         * 的 mute 实验已证静默让 ADV 序列完整跑通）。 */
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
    extern void s31_bt_raw_put(unsigned, unsigned, unsigned);
    s31_bt_raw_put(p0, p1, p2); /* 裸三元组环：冻结 marker 据此拷载荷（轮 9） */
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
