/* C 变参 shim：Zig 无法定义 C 变参函数，但驱动恰恰用它们报错。
 *
 * 这里只把**格式串**转给 Zig 侧打印（变参不展开）——够用来看到驱动说"哪个参数非法"，
 * 不需要在裸机上实现 vsnprintf。真要格式化时再换实现。
 *
 * 覆盖四个：
 *   net80211_printf / pp_printf / mesh_printf（blob 的日志钩子）
 *   _log_write(level, tag, format, ...) —— osi 表里的变参钩子（通过表调用，不走符号）
 */
extern void s31_printf_hook(const char *msg);

int net80211_printf(const char *format, ...) {
    s31_printf_hook(format);
    return 0;
}

int pp_printf(const char *format, ...) {
    s31_printf_hook(format);
    return 0;
}

int mesh_printf(const char *format, ...) {
    s31_printf_hook(format);
    return 0;
}

/* `_log_write` 是经 osi 表调用的（字段类型是函数指针），所以导出一个符号供 Zig 取地址。 */
void s31_log_write(unsigned int level, const char *tag, const char *format, ...) {
    (void)level;
    (void)tag;
    s31_printf_hook(format);
}
