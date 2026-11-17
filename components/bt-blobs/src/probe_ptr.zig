//! 只读地暴露归档的 `Xpuq` 锚点全局（见 probe.zig 的说明）。
pub extern var r_sym_bt_d3D3sk5KewclELfrD5xa: u32;
pub fn get() u32 {
    return r_sym_bt_d3D3sk5KewclELfrD5xa;
}

/// `r_sym_bt_fqmZkUKgd5GE6m7i2YFG`：唯一的写者，`P = wr_btdm_osal_malloc(...)`。
/// 归档里它被一个 `if (*(*s0 + 8) != 0)` 守卫着；那个字段在裸机配置下是 0，
/// 于是它被**跳过**，`P` 停在 NULL，`Xpuq` 就从地址 0 开始零填充。
extern fn r_sym_bt_fqmZkUKgd5GE6m7i2YFG() c_int;

/// 补调一次（幂等性由调用方保证：只在 `P == 0` 时调）。
pub fn populate() c_int {
    return r_sym_bt_fqmZkUKgd5GE6m7i2YFG();
}
