/* radio-coex 的 C 侧 shim：`coexist_printf` 与 `puts`。
 *
 * 链接 `libcoexist.a` 的全部 11 个成员时，链接器只报这两个未定义符号
 * （2026-11-24 实测，命令见 `docs/verification/coex-verification.md`）。
 *
 * IDF 在 `esp_coex/src/lib_printf.c` 里用 vsnprintf 把库的日志格式化进 80 字节，
 * 去掉行尾的换行与空格，再交给 `ESP_LOGI("coexist", ...)`。裸机上没有 vsnprintf，
 * 也没有 ESP_LOG，于是与 `bt-blobs/link/bt_printf_shim.c` 同一做法：自己写一个
 * 够用的有界格式化器（`%s %c %d %i %u %x %X %p %%`，支持宽度与零填充），
 * 把整行转给 Zig 侧的 `s31_coex_log_hook`。
 *
 * `s31_coex_log_hook` 由接线层提供，同一个镜像里只能有一份：
 *   - 只有 BLE（`-Dbt-blob-*` 加 `-Dcoex`）：`components/osal/src/osal.zig`；
 *   - 带 Wi-Fi blob（`-Dwifi-blob-*` 加 `-Dcoex`）：`components/wifi-blobs`。
 *
 * 库里实际出现的格式串（`strings` 对 `coexist_*.o`）：
 *   "coex firmware version: %s"、"[%u] Incorrect coexistence BLE status: %d"、
 *   "Invalid coexist adapter function md5, internal: %s, idf: %s"、
 *   "coexist adapter function version error! Version %x is expected, but it is %x"。
 *
 * **两个符号都是弱定义**，因为各有另一个提供者：
 *
 *   - `coexist_printf`：BLE 探针镜像里 `components/bt-blobs/src/wifi_glue.zig` 有同名的强导出
 *     （Zig 读不到变参，只把格式串转给日志）。那里强定义胜出；其余 coex 镜像用本文件，真格式化。
 *     只有 `coexist_api.o`、`coexist_core.o` 等引用它。
 *   - `puts`：只有 `coexist_api.o` 引用；Wi-Fi 侧的 `wifi-blobs/src/link_stubs.zig` 已有强定义，
 *     两个 blob 同链时它胜出，只链 BLE 时用这份。
 *
 * `s31_coex_log_hook` 由接线层提供，同一个镜像里只能有一份：只有 BLE 时在
 * `components/osal/src/osal.zig`，带 Wi-Fi blob 时在 `components/wifi-blobs`。
 * 不用 `printf`/`puts` 的头文件声明，免得与工具链自带的 libc 声明打架。
 */

#include <stdarg.h>

#define S31_COEX_FMT_MAX 160

extern void s31_coex_log_hook(const char *msg);

static char *put_str(char *o, char *end, const char *s)
{
    if (!s) s = "(null)";
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

/* 返回写进 buf 的字节数（不含结尾的 0）。`scan` 上限防止坏格式串把循环拖死。 */
static int s31_coex_fmt(char *buf, int cap, const char *format, va_list ap)
{
    char *o = buf, *end = buf + cap - 1;
    unsigned scan = 0;
    if (!format) return 0;
    for (const char *p = format; *p && o < end && scan++ < 256; p++) {
        if (*p != '%') { *o++ = *p; continue; }
        p++;
        char pad = ' ';
        if (*p == '0') { pad = '0'; p++; }
        int width = 0, nd = 0;
        while (*p >= '0' && *p <= '9' && nd++ < 9) { width = width * 10 + (*p - '0'); p++; }
        if (*p == 'l') p++; /* %ld/%lu/%lx：ilp32 上与 int 同宽 */
        switch (*p) {
        case 's': o = put_str(o, end, va_arg(ap, const char *)); break;
        case 'c': { char c = (char)va_arg(ap, int); if (o < end) *o++ = c; break; }
        case 'd': case 'i': {
            int v = va_arg(ap, int);
            if (v < 0) {
                if (o < end) *o++ = '-';
                o = put_uint(o, end, (unsigned long)(-(long)v), 10, 0, width - 1, pad);
            } else {
                o = put_uint(o, end, (unsigned long)v, 10, 0, width, pad);
            }
            break;
        }
        case 'u': o = put_uint(o, end, va_arg(ap, unsigned), 10, 0, width, pad); break;
        case 'x': o = put_uint(o, end, va_arg(ap, unsigned), 16, 0, width, pad); break;
        case 'X': o = put_uint(o, end, va_arg(ap, unsigned), 16, 1, width, pad); break;
        case 'p': (void)va_arg(ap, void *); o = put_str(o, end, "(ptr)"); break;
        case '%': if (o < end) *o++ = '%'; break;
        case 0: p--; break; /* 格式串以 '%' 结尾 */
        default: if (o < end) *o++ = '%'; if (o < end) *o++ = *p; break;
        }
    }
    *o = 0;
    return (int)(o - buf);
}

/* 弱定义：见文件头。 */
__attribute__((weak)) int coexist_printf(const char *format, ...)
{
    if (!format) return 0;
    char buf[S31_COEX_FMT_MAX];
    va_list ap;
    va_start(ap, format);
    int len = s31_coex_fmt(buf, (int)sizeof buf, format, ap);
    va_end(ap);
    /* 同 IDF 的 lib_printf：去掉行尾的 '\n'、'\r'、空格；空行不打。 */
    int i = len - 1;
    for (; i >= 0; i--) {
        if (buf[i] != '\n' && buf[i] != '\r' && buf[i] != ' ') break;
        buf[i] = 0;
    }
    if (i >= 0) s31_coex_log_hook(buf);
    return len;
}

__attribute__((weak)) int puts(const char *s)
{
    if (s) s31_coex_log_hook(s);
    return 0;
}
