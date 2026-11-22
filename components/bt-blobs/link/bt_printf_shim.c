/* 接管 ROM 的 `ets_printf`。
 *
 * 动机（板侧 PC 采样实测）：归档打印日志时走进 ROM 的 `0x2f83efd2` 轮询循环，
 * 那里在等 UART0 的 TX 状态位，而该位在本板上会停在 128（FIFO 满、永不排空）
 * ⇒ **打印本身把系统卡死**，看起来像"蓝牙栈挂死"（无 fault、无 panic）。
 *
 * 我们的 Zig logger 直接写 UART0、工作正常；坏的是 ROM 这段轮询。
 * 所以这里给 `ets_printf` 一个强定义直接丢弃，归档的日志不再有机会卡住系统。
 * 需要看归档日志时，把 `S31_BT_ROM_PRINTF_PASS=1` 打开即可回到原行为。
 */
#include <stdarg.h>

#ifndef S31_BT_ROM_PRINTF_PASS
#define S31_BT_ROM_PRINTF_PASS 0
#endif

#if S31_BT_ROM_PRINTF_PASS
extern int rom_ets_printf(const char *format, ...);
int ets_printf(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int r = rom_ets_printf(format, ap);
    va_end(ap);
    return r;
}
#else
/* 转发**格式串本身**给 Zig 侧（变参不展开）。
 * 归档在错误路径上会打印它自己的失败原因（disassembly：`.LC0` 格式串 + 参数），
 * 直接丢弃等于把最直接的诊断信息扔掉；Zig 侧用有界写输出，不会自旋。 */
extern void s31_bt_log_hook(const char *msg);
/* ROM 里没有 vsnprintf（链接实测 undefined）⇒ 自己写一个**够用就行**的格式化器：
 * 支持 %s %c %d %i %u %x %X %p %% 与宽度/零填充（跳过精度），其余按字面输出。
 * 归档的日志就是这些形状（`.LC0` 格式串 + 参数）。 */
#define S31_BT_FMT_MAX 160
/* 归档日志的上限行数。**默认 400**：降到 20 的实验证明它**不是**洪水的主因，
 * 反而把归档的诊断信息全丢了 ⇒ 恢复默认，并允许构建时 `-DS31_BT_FMT_LINES=N` 覆盖。 */
#ifndef S31_BT_FMT_LINES
#define S31_BT_FMT_LINES 400
#endif
static unsigned s31_bt_fmt_lines;

static char *put_str(char *o, char *end, const char *s)
{
    while (*s && o < end) *o++ = *s++;
    return o;
}

static char *put_uint(char *o, char *end, unsigned long v, unsigned base, int upper, int width, char pad)
{
    char tmp[24];
    int n = 0;
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (v == 0) tmp[n++] = '0';
    while (v && n < (int)sizeof tmp) { tmp[n++] = dig[v % base]; v /= base; }
    for (int i = n; i < width && o < end; i++) *o++ = pad;
    while (n > 0 && o < end) *o++ = tmp[--n];
    return o;
}

/* **静音开关**：由 Zig 侧置位（mute 期台词仍进行环）。 */
/* mute/环/丢包计数全部住在 Zig 侧（.bss 安全区）——此前的 C 全局落在 blob
 * 运行时数据区（0x2f011054+，紧邻 sleep_en 槽/g_phyFuns），被 blob 活数据踩掉。 */
extern int s31_bt_log_mute_get(void);
extern void s31_bt_log_dropped_inc(void);
extern void s31_bt_ring_put(const char *line);

/* **RAM 行环（2026-11-22，轮 8）**：blob 台词在 UART mute 期被丢——但 HCI 分发器
 * 对每条命令的内部判词正在其中（轮 7 定位：6/7 命令中止于响应 TX 前）。
 * 格式化后、mute 判定前抄进行环（16×48B .bss，零 irom 成本）；冻结时刻
 * probe 的 flash 标记块把整环抄进 0x18E000 扇区，宿主机 read-flash 离线判读。 */
#define S31_BT_RING_LINES 16
#define S31_BT_RING_LINE  48

int ets_printf(const char *format, ...)
{
    const int muted = s31_bt_log_mute_get();
    if (!format || s31_bt_fmt_lines >= S31_BT_FMT_LINES) return 0;
    char buf[S31_BT_FMT_MAX];
    char *o = buf, *end = buf + sizeof buf - 1;
    __builtin_va_list ap;
    __builtin_va_start(ap, format);
    unsigned scan = 0;
for (const char *p = format; *p && o < end && scan++ < 256; p++) {
        if (*p != '%') { *o++ = *p; continue; }
        p++;
        char pad = ' ';
        if (*p == '0') { pad = '0'; p++; }
        int width = 0;
        int nd = 0;
while (*p >= '0' && *p <= '9' && nd++ < 9) { width = width * 10 + (*p - '0'); p++; }
        if (*p == 'l') p++;                      /* %ld/%lu：忽略长度修饰 */
        switch (*p) {
            case 's': o = put_str(o, end, __builtin_va_arg(ap, const char *)); break;
            case 'c': { char c = (char)__builtin_va_arg(ap, int); if (o < end) *o++ = c; break; }
            case 'd': case 'i': {
                int v = __builtin_va_arg(ap, int);
                if (v < 0) { if (o < end) *o++ = '-'; o = put_uint(o, end, (unsigned long)(-(long)v), 10, 0, width - 1, pad); }
                else o = put_uint(o, end, (unsigned long)v, 10, 0, width, pad);
                break;
            }
            case 'u': o = put_uint(o, end, __builtin_va_arg(ap, unsigned), 10, 0, width, pad); break;
            case 'x': o = put_uint(o, end, __builtin_va_arg(ap, unsigned), 16, 0, width, pad); break;
            case 'X': o = put_uint(o, end, __builtin_va_arg(ap, unsigned), 16, 1, width, pad); break;
            case 'p': { (void)__builtin_va_arg(ap, void *); o = put_str(o, end, "(ptr)"); break; }
            case '%': if (o < end) *o++ = '%'; break;
            case 0: p--; break;
            default: if (o < end) *o++ = '%'; if (o < end) *o++ = *p; break;
        }
    }
    __builtin_va_end(ap);
    *o = 0;
    s31_bt_fmt_lines++;
    s31_bt_ring_put(buf); /* mute 期也进环（flash 标记判据源） */
    if (muted) { s31_bt_log_dropped_inc(); return 0; }
    s31_bt_log_hook(buf);
    return (int)(o - buf);
}
#endif

/* **同一桩的另两个名字**。
 * ROM 集合里 `printf` / `esp_rom_printf` 与 `ets_printf` 同址（`0x2f800024`），
 * 而 `PROVIDE` 只提供**弱**符号 ⇒ 没有强定义的名字仍解析到 ROM 实现，
 * 其循环是 `while (txfifo_cnt > 127) {}` —— README 记录的
 * `mepc=0x2f83efda × 29` 正是它。此前只强定义了 `ets_printf`，覆盖不全。
 * 这里把三个名字都接到同一实现（`ets_printf` 已按上面分支处理）。 */
int printf(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int r = ets_printf(format, ap);
    va_end(ap);
    return r;
}

int esp_rom_printf(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int r = ets_printf(format, ap);
    va_end(ap);
    return r;
}
