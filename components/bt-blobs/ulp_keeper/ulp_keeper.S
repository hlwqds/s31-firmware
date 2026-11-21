/* ULP 守护者:RTC 慢时钟域,HP 域全死仍运行。
 * 每 ~1s 重使能 RTC WDT(CONFIG0/CONFIG1)对抗 blob 的 WPROTECT 解除;
 * 不写 FEED ⇒ 计数不清零 ⇒ 冻结后必然超时复位(rst:0x10)⇒ LP 黑匣子可读。
 * 载入地址 0x2E001000(LP RAM,避开 0x2E000200-0x570 的盒结构)。RV32I。
 * 显式寄存器:x28=RTC WDT base, x29=key, x30=CONFIG0, x31=CONFIG1, x27=delay 上限。
 * (避开 x3/gp——gp 松弛会把 store 基址换成错误的全局指针) */
    .section .text
    .globl _start
_start:
    lui x28, 0x20801        # x28 = 0x20801000
    lui x29, 0x50d84
    addi x29, x29, -1375    # x29 = 0x50d83aa1
    lui x30, 0xa0011
    addi x30, x30, -2048    # x30 = 0xa0010800
    lui x31, 0x2f03
    addi x31, x31, -192     # x31 = 0x2f02f40
    li x27, 2000000         # 延迟迭代数
loop:
    sw x29, 24(x28)         # +0x18 WPROTECT 解锁
    sw x29, 32(x28)         # +0x20 SWD WPROTECT 解锁
    sw x30, 0(x28)          # +0x00 CONFIG0 = armed
    sw x31, 4(x28)          # +0x04 CONFIG1 = hold
    sw x0, 24(x28)          # +0x18 上锁
    sw x0, 32(x28)          # +0x20 上锁
    li x26, 0
delay:
    addi x26, x26, 1
    bne x26, x27, delay
    j loop
