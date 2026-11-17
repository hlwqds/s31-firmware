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
int ets_printf(const char *format, ...)
{
    (void)format;
    return 0; /* 丢弃：不让 ROM 的 UART 轮询有机会把系统卡死 */
}
#endif
