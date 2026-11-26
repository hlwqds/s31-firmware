/* C 变参 shim：Zig 无法定义 C 变参函数，但驱动恰恰用它们报错。
 *
 * 这里把**整行**格式化后转给 Zig 侧打印（`s31_printf_hook`）。裸机上没有 vsnprintf，格式化器与
 * `radio-coex/link/coex_printf_shim.c` 是同一个做法：够用的有界实现（`%s %c %d %i %u %x %X %p %%`，
 * 支持宽度与零填充、`l` 前缀），长行截到 `S31_WIFI_FMT_MAX`。
 *
 * 此前只把格式串原样转过去、变参不展开，blob 的 "pp rom version: %s" 之类只能看到占位符。
 * blob 的日志默认是关的：要另外调 `esp_wifi_internal_set_log_level`（IDF `esp_wifi_init` 的收尾，
 * `wifi_init.c:125-144`；`initOnly()` 里照做），否则只有设级别之前打的那两行。
 *
 * 覆盖四个：
 *   net80211_printf / pp_printf / mesh_printf（blob 的日志钩子）
 *   _log_write(level, tag, format, ...) —— osi 表里的变参钩子（通过表调用，不走符号）
 */
#include <stdarg.h>
#define S31_WIFI_FMT_MAX 200
extern void s31_printf_hook(const char *msg);

static char *put_str(char *o, char *end, const char *s)
{
    if (!s) s = "(null)";
    while (*s && o < end) *o++ = *s++;
    return o;
}

static int str_len(const char *s)
{
    int n = 0;
    while (s[n] && n < 4096) n++;
    return n;
}

/* 无符号数转成字符串写进 `t`（不补宽度）。返回长度。 */
static int to_str(char *t, int cap, unsigned long v, unsigned base, int upper)
{
    char tmp[24];
    int n = 0, k = 0;
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    if (v == 0) tmp[n++] = '0';
    while (v && n < (int)sizeof tmp) { tmp[n++] = dig[v % base]; v /= base; }
    while (n > 0 && k < cap - 1) t[k++] = tmp[--n];
    if (k < cap) t[k] = 0;
    return k;
}

/* 把长度 `len` 的一项按宽度写出去：默认右对齐、左边补 `pad`；`left` 时左对齐、右边补空格
 * （blob 的统计表用 `%-2s %-3u`，没有这一条整张表只剩格式串）。 */
static char *emit(char *o, char *end, const char *s, int len, int width, char pad, int left)
{
    int padn = width > len ? width - len : 0;
    if (!left) while (padn-- > 0 && o < end) *o++ = pad;
    for (int i = 0; i < len && o < end; i++) *o++ = s[i];
    if (left) while (padn-- > 0 && o < end) *o++ = ' ';
    return o;
}

/* 返回写进 buf 的字节数（不含结尾的 0）。`scan` 上限防止坏格式串把循环拖死。 */
static int s31_wifi_fmt(char *buf, int cap, const char *format, va_list ap)
{
    char *o = buf, *end = buf + cap - 1;
    unsigned scan = 0;
    if (!format || cap <= 0) return 0;
    for (const char *p = format; *p && o < end && scan++ < 512; p++) {
        if (*p != '%') { *o++ = *p; continue; }
        p++;
        char pad = ' ';
        int left = 0;
        for (;;) { /* 标志：`-` 左对齐、`0` 补零 */
            if (*p == '-') { left = 1; p++; }
            else if (*p == '0') { pad = '0'; p++; }
            else break;
        }
        int width = 0, nd = 0;
        while (*p >= '0' && *p <= '9' && nd++ < 9) { width = width * 10 + (*p - '0'); p++; }
        if (*p == 'l') p++; /* %ld/%lu/%lx：ilp32 上与 int 同宽 */
        char tok[32];
        int n;
        switch (*p) {
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            o = emit(o, end, s, str_len(s), width, pad, left);
            break;
        }
        case 'c': {
            tok[0] = (char)va_arg(ap, int);
            o = emit(o, end, tok, 1, width, pad, left);
            break;
        }
        case 'd': case 'i': {
            long v = (long)va_arg(ap, int);
            if (v < 0) {
                tok[0] = '-';
                n = 1 + to_str(tok + 1, (int)sizeof tok - 1, (unsigned long)(-v), 10, 0);
                /* 补零要补在负号之后（"%05d" 的 -42 是 -0042）。 */
                if (!left && pad == '0' && o < end) {
                    *o++ = '-';
                    o = emit(o, end, tok + 1, n - 1, width - 1, pad, 0);
                    break;
                }
            } else {
                n = to_str(tok, (int)sizeof tok, (unsigned long)v, 10, 0);
            }
            o = emit(o, end, tok, n, width, pad, left);
            break;
        }
        case 'u': n = to_str(tok, (int)sizeof tok, va_arg(ap, unsigned), 10, 0); o = emit(o, end, tok, n, width, pad, left); break;
        case 'x': n = to_str(tok, (int)sizeof tok, va_arg(ap, unsigned), 16, 0); o = emit(o, end, tok, n, width, pad, left); break;
        case 'X': n = to_str(tok, (int)sizeof tok, va_arg(ap, unsigned), 16, 1); o = emit(o, end, tok, n, width, pad, left); break;
        case 'p': {
            /* 指针按 0x 打出来：日志里大量用它辨认 blob 的对象地址。 */
            if (o < end) *o++ = '0';
            if (o < end) *o++ = 'x';
            n = to_str(tok, (int)sizeof tok, (unsigned long)va_arg(ap, void *), 16, 0);
            o = emit(o, end, tok, n, 0, ' ', 0);
            break;
        }
        case '%': if (o < end) *o++ = '%'; break;
        case 0: p--; break; /* 格式串以 '%' 结尾 */
        default: if (o < end) *o++ = '%'; if (o < end) *o++ = *p; break;
        }
    }
    *o = 0;
    return (int)(o - buf);
}

static int wifi_vprint(const char *format, va_list ap)
{
    char buf[S31_WIFI_FMT_MAX];
    int len = s31_wifi_fmt(buf, (int)sizeof buf, format, ap);
    s31_printf_hook(buf);
    return len;
}

int net80211_printf(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int len = wifi_vprint(format, ap);
    va_end(ap);
    return len;
}

int pp_printf(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int len = wifi_vprint(format, ap);
    va_end(ap);
    return len;
}

int mesh_printf(const char *format, ...)
{
    va_list ap;
    va_start(ap, format);
    int len = wifi_vprint(format, ap);
    va_end(ap);
    return len;
}

/* `_log_write` 是经 osi 表调用的（字段类型是函数指针），所以导出一个符号供 Zig 取地址。
 * 行形状与 IDF 的日志一致：`<tag>: <正文>`（级别由 Zig 侧按需加）。 */
void s31_log_write(unsigned int level, const char *tag, const char *format, ...)
{
    (void)level;
    if (!format || !*format) return;
    char buf[S31_WIFI_FMT_MAX];
    char *o = buf, *end = buf + sizeof buf - 1;
    if (tag) o = put_str(o, end, tag);
    if (o + 2 <= end) {
        *o++ = ':';
        *o++ = ' ';
    }
    *o = 0;
    int n = (int)(o - buf);
    va_list ap;
    va_start(ap, format);
    s31_wifi_fmt(buf + n, (int)sizeof buf - n, format, ap);
    va_end(ap);
    s31_printf_hook(buf);
}

/* `_log_writev` 同理，但正文带的是现成的 `va_list`：blob 先用 `_log_write` 打 "W (ms) tag: " 这一截
 * 表头，正文走这里。`va_list` 在 riscv32 上就是指针，所以这里不是变参函数，Zig 侧可以直接取地址。 */
void s31_log_writev(unsigned int level, const char *tag, const char *format, va_list ap)
{
    (void)level;
    (void)tag;
    if (!format || !*format) return;
    char buf[S31_WIFI_FMT_MAX];
    s31_wifi_fmt(buf, (int)sizeof buf, format, ap);
    s31_printf_hook(buf);
}
