//! wifi-mlme：Wireless network management（IEEE Std 802.11-2016：11.24.7 的 BSS transition
//! management、11.2.3.18 的 WNM sleep mode，以及 9.4.2.79 / 9.4.2.82 / 9.4.2.37 / 9.6.14 的元素与
//! 帧格式）。
//!
//! 全部是「字节 ↔ 结构」和「输入 → 判决 / 状态」的纯逻辑：不碰射频、不分配堆内存。
//!
//!   1. BSS Transition Management（下称 BTM）Query / Request / Response 三种帧的解析与构造，
//!      Request Mode 各位与候选表的约束；
//!   2. STA 侧：收到 BTM Request 后按候选表与本端 BSS 表（`scan.zig`，只读）决定 BTM Status
//!      Code 与 Target BSSID；
//!   3. AP 侧：由扫描表生成带 Preference 的候选表、Disassociation Timer 的逐 Beacon 递减、
//!      组地址 Request 的条件；
//!   4. WNM Sleep Mode：元素与两种帧的解析 / 构造，STA 侧的进出与 DTIM 期醒来规则，AP 侧的
//!      接受 / 拒绝、停发单播、TIM 位与密钥处理；
//!   5. TFS（Traffic Filtering Service，11.24.12）：TFS Request / Response / Notify / Notify
//!      Response 四种帧与元素（含 TCLAS / TCLAS Processing 子元素）的解析与构造，Table 9-145
//!      全部七种分类器的解析与匹配，STA 侧的请求 / 响应配对，AP 侧的保存、替换、按帧匹配与
//!      Delete After Match / Notify 记账（WNM Sleep 帧里的 TFS 元素仍以切片返回，可另交给本
//!      文的 TFS 函数解析）；
//!   6. WNM Sleep Mode Response 的 Key Data（9.6.14.20）：GTK / IGTK 子元素（KDE）的构造与
//!      解析，以及「Key Data 非空走 Key Data、为空走组密钥握手」的判定。加解密经 KeyDataCodec
//!      注入——真实密钥封装（12.7.2 的 AES Key Wrap / PMF 帧保护）没有在本组件验证，要由
//!      拥有 KEK / PMF 上下文的调用方提供。
//!   7. BSS Max Idle Period（第 15 节）：元素编解码与 STA 侧保活判决（判决函数、时间注入）；
//!   8. TIM Broadcast（第 16 节）：请求 / 响应帧与元素编解码、STA 侧接受 / 拒绝的判决；
//!   9. FMS（第 17 节）：请求 / 响应帧、FMS 子元素 / Status 子元素 / TCLAS Status 子元素、
//!      STA 侧流账本（Accept / Terminate / 不得再请求改速率）；
//!   10. DMS（第 18 节）：请求 / 响应帧、Descriptor / Status 字段编解码与 GCR Request
//!       子元素（只认到 nibble），STA 侧流账本；
//!   11. Collocated Interference（第 19 节）：请求 / 报告帧编解码、按 STA 自身共址射频
//!       状态生成报告的模型（端点封顶）、上报时机判决、占空比公式；
//!   12. Channel Usage（第 20 节）：元素与请求 / 响应帧编解码；
//!   13. WNM Notification（第 21 节）：请求 / 响应帧编解码与 STA 侧应答规则；
//!   14. Event / Diagnostic 容器（第 22 节）：元素编解码（子元素内容不解释）与帧容器；
//!   15. QoS Traffic Capability（第 23 节）：元素 / Update 帧编解码与变化判决；
//!   16. Extended Capabilities 里的 WNM 位（第 24 节）：Table 9-135 位号与判定。
//!
//! 对应原文（页码为印刷页码）：
//!
//!   * 11.24.7.1–11.24.7.4（p.1799–1802）：BTM 能力、Query、Request、Response；
//!   * 9.6.14.1 / Table 9-354（p.1225）：WNM Action 字段；9.6.14.8–9.6.14.10（p.1230–1232）、
//!     Figure 9-700–9-705、Table 9-357（p.1233）；
//!   * 9.4.2.37（p.916–921）：Neighbor Report 元素；Figure 9-299 / 9-300、Table 9-152（p.920–921）；
//!   * 11.2.3.18.1–.3（p.1623–1624）：WNM sleep mode 的能力、STA 侧、AP 侧规程；
//!   * 9.4.2.82 / Figure 9-424 / Table 9-203 / Table 9-204（p.1005–1006）：WNM Sleep Mode 元素；
//!   * 9.4.2.79 / Figure 9-416（p.1001）：BSS Max Idle Period 元素；
//!   * 9.6.14.19–9.6.14.20 / Figure 9-715–9-716（p.1237–1238）：WNM Sleep Mode Request / Response；
//!   * 11.2.3.1（p.1600）：PS 模式且不在 WNM sleep mode 的 STA 按 ListenInterval / ReceiveDTIMs
//!     听 Beacon；
//!   * 11.24.12.1–.3（p.1806–1809）：TFS 能力、non-AP STA 侧与 AP 侧规程（协议的 AND / OR
//!     结构、EAPOL-Key 隐式规则集、Delete After Match 与 Notify）；
//!   * 9.4.2.80 / Figure 9-418 / Table 9-200 / Table 9-201（p.1002–1004）：TFS Request 元素；
//!   * 9.4.2.81 / Figure 9-421 / 9-422 / Table 9-202（p.1004–1005）：TFS Response 元素；
//!   * Table 9-198（p.999）：TFS Response Status（0–14，15–255 保留）；
//!   * 9.4.2.31 / Figure 9-269–9-279 / Table 9-144 / 9-145 / 9-147 / 9-148（p.906–912）：TCLAS
//!     元素与七种 Frame Classifier；
//!   * 9.4.2.33 / Figure 9-290 / Table 9-149（p.914–915）：TCLAS Processing 元素；
//!   * 9.6.14.15–9.6.14.18 / Figure 9-711–9-714（p.1236–1237）：TFS Request / Response / Notify /
//!     Notify Response 帧格式；
//!   * Table 9-135（p.891–…）：Extended Capabilities 的 TFS 位 = 16；
//!   * 9.6.14.20 / Figure 9-716 / 9-717 / 9-718 / Table 9-358（p.1238–1240）：Key Data 与 GTK /
//!     IGTK 子元素；Figure 9-319（p.935）：GTK 子元素的 Key Info；
//! * MIB 属性 dot11BssMaxIdlePeriod：Max Idle Period 以 1000 TU 为单位（「number of 1000
//!   TUs that pass before an AP disassociates an inactive non-AP STA」）。
//!
//! 第五批（第 15–24 节）的原文锚点（行号是 `/tmp/spec/802.11-2016.txt` 的原文行）：
//!
//!   * 11.24.13 BSS max idle period management（p.1809，行 94196）；9.4.2.79 / Figure 9-416 /
//!     9-417（p.1001–1002，行 54378–54408）；
//!   * 11.2.3.17 TIM broadcast（p.1621–1622，行 84774 起）；9.6.14.21 / 9.6.14.22（p.1240，
//!     Figure 9-719 / 9-720，行 65626 / 65634）；9.4.2.83 / 9.4.2.84 / Table 9-205
//!     （p.1006–1007，行 54573–54660）；
//!   * 11.24.8 FMS multicast rate processing（p.1803，行 93912）；9.6.14.11 / 9.6.14.12
//!     （p.1234，Figure 9-706 / 9-707）；9.4.2.76 / 9.4.2.77 / Figure 9-410–9-414 /
//!     Table 9-196 / 9-197 / 9-198（p.996–1000，行 54179–54330）；
//!   * 11.24.16.2 DMS procedures（p.1811 起，行 94300）；9.6.14.26 / 9.6.14.27（p.1243）；
//!     9.4.2.88 / 9.4.2.89 / Figure 9-431–9-435 / Table 9-207–9-212（p.1011–1016，行
//!     54800–55030）；
//!   * 11.24.9 Collocated interference reporting（p.1804，行 93949）；9.6.14.13 / 9.6.14.14
//!     （p.1234–1236，Figure 9-708 / 9-709 / 9-710）；9.4.2.85 / Figure 9-427 / 9-428
//!     （p.1008–1009，行 54662–54739）；
//!   * 11.24.15 Channel usage procedures（p.1810，行 94243）；9.6.14.24 / 9.6.14.25
//!     （p.1242–1243）；9.4.2.86 / Figure 9-429 / Table 9-206（p.1009–1010，行 54740–54799）；
//!   * 11.24.17 WNM notification（p.1824，行 94974）；9.6.14.29 / 9.6.14.30（p.1244–1245）；
//!     Table 9-360 / 9-361 / 9-362（行 65795–65852）；
//!   * 11.24.2 Event request and report（p.1776 起，行 92544）；11.24.3 Diagnostic request
//!     and report（p.1779，行 92723）；9.6.14.2–9.6.14.5（p.1226–1228，行 65018–65098）；
//!     9.4.2.67–9.4.2.70 / Figure 9-351 / 9-365 / 9-370 / 9-393 / Table 9-171 / 9-175 /
//!     9-178（p.961–984，行 52795–53746）；
//!   * 11.24.10 QoS Traffic capability procedure（p.1805，行 94014）；9.6.14.23（p.1241）；
//!     9.4.2.78 / Table 9-199（p.1000–1001）；Table 9-359（p.1241）；
//!   * Table 9-354（WNM Action，p.1225–1226，行 64990–65036）；Table 9-77（Element IDs，
//!     p.784–787：Event 78 / Diagnostic 80 / FMS Descriptor 86 / FMS Request 87 / FMS
//!     Response 88 / QoS Traffic Capability 89 / BSS Max Idle Period 90 / TIM Broadcast
//!     Request 94 / TIM Broadcast Response 95 / Collocated Interference Report 96 /
//!     Channel Usage 97 / DMS Request 99 / DMS Response 100 / Destination URI 141 / TSPEC 13）；
//!   * Table 9-135（Extended Capabilities，p.891–894）：Event 7、Diagnostics 8、FMS 11、
//!     Collocated Interference Reporting 13、WNM Sleep Mode 17、TIM Broadcast 18、QoS
//!     Traffic Capability 20、Channel Usage 24、DMS 26、WNM Notification 46。
//!
//! 「2016 无明文、依据盘上 hostap」的规则（与上面分开列）：
//!
//!   * 候选表条目没有 Preference 子元素时不算 excluded：2016 只说「Preference 为 0 即
//!     excluded」；hostap `common/wnm_sta.c:337` 是 `preference_present && preference == 0` 才
//!     排除，排序时缺 Preference 的排后面（`wnm_sta.c:743–751`）。本实现同它。
//!   * Accept 时 Target BSSID 总是 6 字节；不知道目标时写 6 个 0（`wnm_sta.c:610–617` 引
//!     P802.11-REVmc 的澄清）。
//!
//! 取舍与偏离：
//!
//!   * 候选表里有候选、但本端 BSS 表里一个都没见过时回 2（Insufficient Beacon or Probe
//!     Response frames received from all candidates）——Table 9-357 的字面含义，且 11.24.7.4
//!     规定 AP 收到 2 后应留出扫描时间再发。hostap 同一情形回 7（`wnm_sta.c:710–713`）。
//!   * BTM Status 3（Insufficient available capacity）需要 BSS Available Admission Capacity /
//!     BSS Load，本端 BSS 表不存，所以判决模型不会产出 3，只把它当作合法码。
//!   * TFS：WNM Sleep Mode 帧里的 TFS 元素仍以切片返回（可交给第 10–13 节解析）；AP 侧模型
//!     保留「有排队帧就置 TIM 位」这一条，TFS 匹配与 TIM 位的接线由调用方完成（`TfsAp`
//!     的匹配结果 + `SleepAp.queueTfsMatch`）。
//!   * TFS：分类器类型 1（TCP/UDP IP）不要求 Classifier Mask 的 Version 位为 1——原文该句
//!     （「A TCLAS element is valid when …」）只出现在 Type 4 的布局之后；Type 2 的
//!     Classifier Mask「reserved」按「必须为 0、TCI 无条件比较」处理。类型 3 的 Filter
//!     Offset 按分类器参数的 big-endian 约定读（原文只对类型 1 / 4 / 5 明说 big-endian）。
//!   * TFS：AP 侧采用「全部 Accept 才提交」——部分拒绝时保留旧规则（11.24.12.2「previously
//!     established filter parameters … remain in effect」的字面含义），Response 仍逐元素回状态。
//!     每个请求元素里的全部子元素共用同一个状态（原文没有给出把状态拆到单个子元素的规则）。
//!   * TFS：TFS Response / TFS Status 子元素里的 Vendor Specific 只校验 ID（Table 9-202），
//!     不保留内容；TFS Notify Response 与 TFS Notify 共用 WNM Action 15、按方向区分
//!     （Table 9-354 只有「15 TFS Notify」，9.6.14.18 的图与 9.6.14.17 相同）。
//!   * Key Data：子元素顺序按 9.4.3「非降序」校验（Key Data 不是元素，但 NOTE 1 的多 GTK /
//!     IGTK 与 9.4.3 的排序规则一致）；Key ID（IGTK 的 2 八位组）按 9.2.2 的数值字段
//!     LSB 在前读取。
//! * Key Data：加密经 KeyDataCodec 注入。PMF 场景整帧在帧级受保护、Key Data 本身是明文
//!   KDE（9.6.14.20 的 NOTE 2）；AKM 决定的密钥封装（12.7.2，如组密钥握手的 AES Key
//!   Wrap）没有在本组件验证，要由调用方提供 protect / unprotect；组件测试只用测试替身。
//!
//! 第五批（第 15–24 节）的取舍与偏离：
//!
//!   * BSS Max Idle：Idle Options 的 B1–B7 保留位按忽略处理（9.4.2.79 没有「应拒收」句）；
//!     保活判决的「余量」是调用方注入的参数，原文没有规定 STA 侧提前量。
//!   * TIM Broadcast：Table 9-205 的 5–255 保留 Status 按拒收（同批内 TFS/FMS 状态表的
//!     先例）；status = 2（Denied）时 Length 必须 = 1、0/1/3/4 时必须 = 10（9.4.2.84 的
//!     「When the Status field is 0, 1, 3 or 4, the … fields are included」）。
//!   * FMS：FMS 子元素里「≥2 个 TCLAS 必须带 TCLAS Processing」不成立——9.4.2.76 原文对
//!     Processing 只说「optionally present」（与 TFS/DMS 不同），所以不强制；FMS Status
//!     子元素里 Current Count 保留位不检查（原文只说 reserved，没有拒收句）。
//!   * DMS：GCR Request / GCR Response 子元素只认到子元素头与前 2 个 nibble（Table 9-208 /
//!     9-212 的 ID 校验 + Table 9-209 / 9-210 的保留值校验）；Concealment Address 与
//!     Schedule Element 是 GCR（11.24.16.3）内容、属本组件非目标，留给调用方。
//!   * DMS Response 的 Accept/Denied 语义校验（Accept → 非 0 DMSID、Deny → 0；带 GCR
//!     Response 时首个 TCLAS 必须是类型 0 且必须带 TSPEC）是 11.24.16.2 对 DMS provider
//!     的 shall，本组件把它做成 STA 侧严格解析；Terminate 的 DMS Length 必须 = 3、
//!     Last Sequence Control 必须是 65535 / 65534 / 低 4 位为 0。
//!   * Collocated Interference：平均占空比公式 = ⌊(2^32−2)×T_B/T_I + 0.5⌋（9.4.2.85，
//!     印刷页 1009，PDF 原件核对）；上报时机判决里的「显著变化」标准原文说属于实现内部，
//!     这里由调用方以 `changed` 布尔注入。
//!   * Channel Usage：请求帧里元素顺序按图 9-722 的排列校验（Usage 元素全部在前、
//!     Supported Operating Classes 在后）；响应帧的可选元素（Power Constraint / EDCA /
//!     Transmit Power Envelope）只按 9.4.2.1 的结构走一遍、内容不解释。
//!   * Event Report 帧允许 0 条元素：11.24.2「If there are no available logged events …
//!     the STA shall send the Event Report frame without any Event Report element」与
//!     9.6.14.3 的「one or more」冲突，按规程条款放宽（Diagnostic Report 仍要求 ≥1 条）。
//!   * Event / Diagnostic 元素里的事件类型、诊断类型、Report Status 的保留值按拒收
//!     （Table 9-171 / 9-175 / 9-178 的保留段 + 批内状态表先例）；Event Request 元素里
//!     各事件类型的子元素、Diagnostic 子元素内容不解释。
//!   * WNM Notification：Table 9-360 的保留类型与 Table 9-361 的保留子元素 ID 按拒收；
//!     Type = 221（Vendor Specific）的子元素内容不解释、应答规则由厂商决定。
//!   * QoS Traffic Capability：元素按 9.4.2.78 的「Length = 1 + n（n = Flags 的 B0–B1
//!     非零位数）」接受，AC STA Count List（QoS AP 发送时携带）原样返回；Update 帧
//!     （Table 9-359）恒 1 字节 Flags。Flags 的保留位（B2–B3、B7）不检查、变化比较只看
//!     定义位。
//!   * 评审返修（2026-11-25 独立评审 /tmp/r5c/review-wifi.md）：
//!     CI Report 元素体按 Figure 9-427（行 54696 Octets「4 4 4 4 2」）改为 21 八位组、
//!     Interference Center Frequency 4 八位组（u32，2.4 GHz 本信道 482 400 个 5 kHz）；
//!     电平 +127（unknown）放行、不再被 +126 封顶吞掉（行 54672–54675 的两个可区分编码）；
//!     CI Request 的 auto=0 + timeout≠0 接收按 9.2.4.1 忽略保留子字段（行 36052）、构造仍拒；
//!     DMS Add 的「Otherwise → zero TCLAS Processing」双向执行（行 54844–54846）；
//!     FMS 元素总长 ≤ 255 / DMS Length ≤ 253 的上限在构造与解析两侧执行（行 54217/54324/
//!     54810/54926）；Diagnostic 类型 0/1/2 不带子元素（9.4.2.69 行 53279–53280）；
//!     WNM Notification Type 0 必带子元素 0/1/2（9.6.14.29 行 65817–65819；Type 221 的
//!     子元素 ID 由厂商定义、不套 Table 9-361）；Destination URI 元素体（ESS Detection
//!     Interval + URI）解析进 `destination_uri` 交给调用方、必须排最后、Report 帧无此
//!     槽位（9.4.2.90 行 55030、Figure 9-695/9-697）；TIM Broadcast Request 按
//!     Figure 9-719 定长 6 八位组拒尾随字节；Update 帧 Flags 按 Table 9-359（B0–B3 保留）
//!     用独立视图 `QosTrafficUpdateFlags`、变化比较掩码 0x70（仅 B4–B6）。
//!   * 评审第二轮返修（review-wifi-r2.md 残留 N2–N5）：CI 向量注释与手排字节的单位/字节
//!     更正（center = 2412 MHz × 200 = 482 400 = 0x00075C60，LE 60 5c 07 00）；
//!     CiReportElement 结构注释 19→21、Center Frequency(2)→(4)；DMS Add「Otherwise →
//!     zero TCLAS Processing」双向负例补回（构造 + 解析）；URI ≤ 253 八位组解析/构造
//!     双向强制（9.4.2.90 行 55028–55029）；Destination URI 解析/构造形式差异写入字段
//!     注释。N1（DMS Length 上限比原文严一行）经主代理裁定保持不改行为、注释如实写明。
//!   * 返修记录（2026-11-25 验收回：验收人在差分/主机套件之外抽查出的模块与用例问题）：
//!     `buildEventRequestElement` 的 Length/索引算错（体 3 + n、总长 2 + 体）；
//!     `buildDiagnosticRequestElement`/`buildDiagnosticReportElement` 的 total 差 2
//!     （6 + n / 5 + n）；`parseQosTrafficCapabilityElement` 原来硬性要求体 1 字节、与
//!     9.4.2.78 的「1 + n」冲突（见上）；`parseTimBroadcastResponse` 的元素体应从
//!     [ID][Length] 之后取；DMS 帧层按 9.6.14.26/27 改为「one or more elements」的元素
//!     计数；DiagType 按 Table 9-178 单独定义（类型 4 有定义）。
//!   * FMS 的 FMS Descriptor 元素（ID 86，Beacon 里的计数器通告）没有做——它属于 AP 侧
//!     Beacon 调度，本组件不碰真实 Beacon；WNM Notification 的 AP Descriptor / Firmware
//!     Version 子元素内容（Figure 9-374 / 9-380）没有做——只校验子元素 ID。
//!   * 非目标（任务书）：FTM / Timing Measurement 的时序、Location track、Proxy ARP、
//!     GCR（除 GCR Request 子元素的 nibble）、AC Station Count、需要真实 Beacon 调度的部分。
//!   * hostap 交叉核对：IDF 裁剪版 `ieee802_11_defs.h` 只有 WNM Action 值（`WNM_*` 枚举，
//!     765–792 行，与 Table 9-354 一致）；本批各元素的 Element ID 常量盘上 hostap 没有
//!     （`WLAN_EID_*` 无 BSS Max Idle / TIM Broadcast / FMS / DMS 等），全部出自 Table 9-77。
//!   * 比特编号沿用 9.2.2（p.636）：字段第 N 位落在第 N/8 字节的第 N mod 8 位。

const std = @import("std");

const frame = @import("frame.zig");
const ie = @import("ie.zig");
const robust = @import("robust.zig");
const rrm = @import("rrm.zig");
const scan = @import("scan.zig");

pub const Error = rrm.Error || error{
    /// 保留字段不是 0（Disassociation Imminent = 0 时的 Disassociation Timer 等）。
    ReservedField,
    /// Request Mode 的 BSS Termination Included = 1 却没有 BSS Termination Duration 字段。
    MissingTermination,
    /// 该有的子元素 / TCLAS 一个都没有（TFS 元素的「one or more」）。
    Empty,
    /// Key Info 的保留位不是 0（Figure 9-319 的 B2–B15）。
    ReservedBitsSet,
};

pub const BuildError = rrm.BuildError || error{
    ReservedField,
    MissingTermination,
    /// ESS Disassociation Imminent = 1 却没有 Session Information URL 字段。
    MissingUrl,
    /// 构造 Query / Response 时给出的候选表元素串被截断。
    Truncated,
    /// 构造 Query / Response 时给出的候选表里有非 Neighbor Report 元素。
    UnexpectedElement,
    /// 该有的子元素 / TCLAS 一个都没有。
    Empty,
    /// 多于一个 TCLAS 却没有 TCLAS Processing（11.24.12.1）。
    MissingElement,
};

fn le16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .little);
}

fn w16(out: []u8, v: u16) void {
    std.mem.writeInt(u16, out[0..2], v, .little);
}

fn le32(b: *const [4]u8) u32 {
    return std.mem.readInt(u32, b, .little);
}

fn w32(out: []u8, v: u32) void {
    std.mem.writeInt(u32, out[0..4], v, .little);
}

// ---------------------------------------------------------------------------
// 0) 常量
// ---------------------------------------------------------------------------

/// WNM 的 Category（Table 9-47，p.736：Robust = Yes）。
pub const category: u8 = @backingInt(robust.Category.wnm);

/// Table 9-354（p.1225）：本组件用到的 WNM Action 字段。
pub const Action = enum(u8) {
    btm_query = 6,
    btm_request = 7,
    btm_response = 8,
    tfs_request = 13,
    tfs_response = 14,
    /// TFS Notify 与 TFS Notify Response 共用 15、按方向区分（Table 9-354；9.6.14.17 / 9.6.14.18）。
    tfs_notify = 15,
    sleep_request = 16,
    sleep_response = 17,
    // —— 以下为第五批（wnm.zig 第 15–23 节）——
    event_request = 0,
    event_report = 1,
    diagnostic_request = 2,
    diagnostic_report = 3,
    fms_request = 9,
    fms_response = 10,
    collocated_interference_request = 11,
    collocated_interference_report = 12,
    tim_broadcast_request = 18,
    tim_broadcast_response = 19,
    qos_traffic_capability_update = 20,
    channel_usage_request = 21,
    channel_usage_response = 22,
    dms_request = 23,
    dms_response = 24,
    notification_request = 26,
    notification_response = 27,
    _,
};

/// Table 9-357（p.1233）：BTM status code；9–255 保留。
pub const BtmStatus = struct {
    pub const accept: u8 = 0;
    pub const reject_unspecified: u8 = 1;
    /// Reject—Insufficient Beacon or Probe Response frames received from all candidates。
    pub const reject_insufficient_frames: u8 = 2;
    /// Reject—Insufficient available capacity from all candidates。
    pub const reject_insufficient_capacity: u8 = 3;
    /// Reject—BSS termination undesired。
    pub const reject_termination_undesired: u8 = 4;
    /// Reject—BSS termination delay requested。
    pub const reject_termination_delay: u8 = 5;
    /// Reject—STA BSS Transition Candidate List provided。
    pub const reject_candidate_list_provided: u8 = 6;
    /// Reject—No suitable BSS transition candidates。
    pub const reject_no_suitable_candidates: u8 = 7;
    /// Reject—Leaving ESS。
    pub const reject_leaving_ess: u8 = 8;

    /// Table 9-357 的名字；保留值返回 null。
    pub fn name(code: u8) ?[]const u8 {
        return switch (code) {
            0 => "Accept",
            1 => "Reject-Unspecified reject reason",
            2 => "Reject-Insufficient Beacon or Probe Response frames received from all candidates",
            3 => "Reject-Insufficient available capacity from all candidates",
            4 => "Reject-BSS termination undesired",
            5 => "Reject-BSS termination delay requested",
            6 => "Reject-STA BSS Transition Candidate List provided",
            7 => "Reject-No suitable BSS transition candidates",
            8 => "Reject-Leaving ESS",
            else => null,
        };
    }
};

/// 11.24.7.2（p.1800）：只为提供偏好而发 Query 时，BSS Transition Query Reason 取 19。
pub const query_reason_preferred_candidate_list: u8 = 19;

fn checkHeader(body: []const u8, action: Action) Error!void {
    if (body.len < 2) return error.Truncated;
    if (body[0] != category) return error.BadCategory;
    if (body[1] != @backingInt(action)) return error.BadAction;
}

// ---------------------------------------------------------------------------
// 1) Request Mode 与 BTM Request（9.6.14.9；Figure 9-701 / 9-702 / 9-703 / 9-704）
// ---------------------------------------------------------------------------

/// Figure 9-702（p.1231）：B0 Preferred Candidate List Included、B1 Abridged、B2
/// Disassociation Imminent、B3 BSS Termination Included、B4 ESS Disassociation Imminent、
/// B5–B7 保留。
pub const RequestMode = packed struct(u8) {
    preferred_candidate_list_included: bool = false,
    abridged: bool = false,
    disassociation_imminent: bool = false,
    bss_termination_included: bool = false,
    ess_disassociation_imminent: bool = false,
    reserved: u3 = 0,

    pub fn word(self: RequestMode) u8 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u8) RequestMode {
        return .{
            .preferred_candidate_list_included = w & 0x01 != 0,
            .abridged = w & 0x02 != 0,
            .disassociation_imminent = w & 0x04 != 0,
            .bss_termination_included = w & 0x08 != 0,
            .ess_disassociation_imminent = w & 0x10 != 0,
        };
    }
};

/// 一帧 BTM Request / Query / Response 里最多放几个候选。
pub const max_candidates = 8;

/// Figure 9-701（p.1230）：Category、WNM Action、Dialog Token(1)、Request mode(1)、
/// Disassociation Timer(2)、Validity Interval(1)、BSS Termination Duration(12，可选)、Session
/// Information URL(可选)、BSS Transition Candidate List Entries(可选)。
pub const BtmRequest = struct {
    dialog_token: u8 = 0,
    mode: RequestMode = .{},
    disassociation_timer: u16 = 0,
    validity_interval: u8 = 0,
    termination: ?rrm.TerminationDuration = null,
    url: ?[]const u8 = null,
    candidates: [max_candidates]rrm.NeighborReport = undefined,
    candidate_count: u8 = 0,

    pub fn candidateSlice(self: *const BtmRequest) []const rrm.NeighborReport {
        return self.candidates[0..self.candidate_count];
    }

    pub fn findCandidate(self: *const BtmRequest, bssid: frame.Mac) ?*const rrm.NeighborReport {
        for (self.candidates[0..self.candidate_count]) |*c| {
            if (std.mem.eql(u8, &c.bssid, &bssid)) return c;
        }
        return null;
    }
};

pub fn parseBtmRequest(body: []const u8) Error!BtmRequest {
    if (body.len < 7) return error.Truncated;
    try checkHeader(body, .btm_request);
    var r = BtmRequest{
        .dialog_token = body[2],
        .mode = RequestMode.fromWord(body[3]),
        .disassociation_timer = le16(body[4..6]),
        .validity_interval = body[6],
    };
    // 「The Dialog Token field is the nonzero value …」（9.6.14.9）。
    if (r.dialog_token == 0) return error.ZeroDialogToken;
    // 「The Validity Interval field is the number of beacon transmission times (TBTTs) until the
    // BSS transition candidate list is no longer valid. A value of 0 is reserved.」
    if (r.validity_interval == 0) return error.ReservedValue;
    // 「If the Disassociation Imminent field is 0, the Disassociation Timer field is reserved.」
    if (!r.mode.disassociation_imminent and r.disassociation_timer != 0) return error.ReservedField;
    var pos: usize = 7;
    if (r.mode.bss_termination_included) {
        // 「present only when the BSS Termination Included field is 1」：子元素 ID 4、Length 10。
        if (body.len - pos < 12) return error.MissingTermination;
        if (body[pos] != rrm.NeighborReportSubelement.bss_termination_duration or body[pos + 1] != 10) return error.BadLength;
        r.termination = .{
            .tsf = std.mem.readInt(u64, body[pos + 2 ..][0..8], .little),
            .duration_minutes = le16(body[pos + 10 ..][0..2]),
        };
        pos += 12;
    }
    if (r.mode.ess_disassociation_imminent) {
        // Figure 9-704：URL Length(1) + URL；「This field is present when the ESS Disassociation
        // Imminent field is 1」。
        if (pos >= body.len) return error.Truncated;
        const n: usize = body[pos];
        pos += 1;
        if (body.len - pos < n) return error.Truncated;
        r.url = body[pos .. pos + n];
        pos += n;
    }
    // 候选表「contains zero or more Neighbor Report elements」。
    var w = ie.Walker.init(body[pos..]);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != @backingInt(ie.ElementId.neighbor_report)) return error.UnexpectedElement;
        if (r.candidate_count == max_candidates) return error.TooMany;
        r.candidates[r.candidate_count] = try rrm.parseNeighborReport(el.body);
        r.candidate_count += 1;
    }
    return r;
}

pub fn buildBtmRequest(out: []u8, r: BtmRequest) BuildError!usize {
    if (r.dialog_token == 0) return error.ZeroDialogToken;
    if (r.validity_interval == 0) return error.ReservedValue;
    if (!r.mode.disassociation_imminent and r.disassociation_timer != 0) return error.ReservedField;
    if (r.mode.bss_termination_included and r.termination == null) return error.MissingTermination;
    const url_len = if (r.url) |u| u.len else 0;
    if (r.mode.ess_disassociation_imminent and r.url == null) return error.MissingUrl;
    const fixed: usize = 7 +
        (if (r.mode.bss_termination_included) @as(usize, 12) else 0) +
        (if (r.mode.ess_disassociation_imminent) @as(usize, 1 + url_len) else 0);
    if (fixed > 255 or out.len < fixed) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.btm_request);
    out[2] = r.dialog_token;
    out[3] = r.mode.word();
    w16(out[4..6], r.disassociation_timer);
    out[6] = r.validity_interval;
    var pos: usize = 7;
    if (r.termination) |t| {
        out[pos] = rrm.NeighborReportSubelement.bss_termination_duration;
        out[pos + 1] = 10;
        std.mem.writeInt(u64, out[pos + 2 ..][0..8], t.tsf, .little);
        w16(out[pos + 10 ..], t.duration_minutes);
        pos += 12;
    }
    if (r.url) |u| {
        out[pos] = @intCast(u.len);
        @memcpy(out[pos + 1 ..][0..u.len], u);
        pos += 1 + u.len;
    }
    for (r.candidateSlice()) |c| pos += try rrm.buildNeighborReport(out[pos..], c);
    return pos;
}

// ---------------------------------------------------------------------------
// 2) 候选表的 Preference 约束（11.24.7.2 / 11.24.7.4；Table 9-152）
// ---------------------------------------------------------------------------

/// Query 与 Response 里的候选表：「The Preference field value … shall be between 1 and 255.
/// The value of 0 is reserved」——所以每条都要带 Preference 子元素，且不是 0。
fn checkPreferenceList(comptime E: type, elements: []const u8) E!void {
    var w = ie.Walker.init(elements);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != @backingInt(ie.ElementId.neighbor_report)) return error.UnexpectedElement;
        const c = rrm.parseNeighborReport(el.body) catch |e| return switch (e) {
            error.Truncated => error.Truncated,
            else => error.BadLength,
        };
        if ((c.preference orelse 0) == 0) return error.ReservedValue;
    }
}

// ---------------------------------------------------------------------------
// 3) BTM Query（9.6.14.8；Figure 9-700）
// ---------------------------------------------------------------------------

/// Figure 9-700（p.1230）：Category、WNM Action、Dialog Token(1)、BSS Transition Query
/// Reason(1)、BSS Transition Candidate List Entries(可选)。
pub const BtmQuery = struct {
    dialog_token: u8,
    /// Table 9-176（p.969）：Transition and Transition Query reasons。
    reason: u8,
    /// Neighbor Report 元素串，每条都带 1–255 的 Preference。
    candidates: []const u8,
};

pub fn parseBtmQuery(body: []const u8) Error!BtmQuery {
    if (body.len < 4) return error.Truncated;
    try checkHeader(body, .btm_query);
    if (body[2] == 0) return error.ZeroDialogToken;
    try checkPreferenceList(Error, body[4..]);
    return .{ .dialog_token = body[2], .reason = body[3], .candidates = body[4..] };
}

pub const BtmQueryParams = struct {
    dialog_token: u8,
    reason: u8,
    /// 已拼好的 Neighbor Report 元素串；只提供偏好时也用 19。
    candidate_elements: []const u8 = &.{},
};

pub fn buildBtmQuery(out: []u8, p: BtmQueryParams) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    try checkPreferenceList(BuildError, p.candidate_elements);
    const total = 4 + p.candidate_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.btm_query);
    out[2] = p.dialog_token;
    out[3] = p.reason;
    @memcpy(out[4..][0..p.candidate_elements.len], p.candidate_elements);
    return total;
}

// ---------------------------------------------------------------------------
// 4) BTM Response（9.6.14.10；Figure 9-705；Table 9-357）
// ---------------------------------------------------------------------------

/// Figure 9-705（p.1232）：Category、WNM Action、Dialog Token(1)、BTM Status Code(1)、BSS
/// Termination Delay(1)、Target BSSID(6，状态码为 0 时才有)、候选表(可选)。
pub const BtmResponse = struct {
    dialog_token: u8,
    status: u8,
    /// 状态码为 5（Reject—BSS termination delay requested）时是请求延迟的分钟数，否则保留。
    termination_delay: u8,
    /// 状态码为 0 时才有（6 字节；不知道目标时是 6 个 0）。
    target_bssid: ?frame.Mac = null,
    candidates: [max_candidates]rrm.NeighborReport = undefined,
    candidate_count: u8 = 0,

    pub fn candidateSlice(self: *const BtmResponse) []const rrm.NeighborReport {
        return self.candidates[0..self.candidate_count];
    }
};

pub fn parseBtmResponse(body: []const u8) Error!BtmResponse {
    if (body.len < 5) return error.Truncated;
    try checkHeader(body, .btm_response);
    var r = BtmResponse{ .dialog_token = body[2], .status = body[3], .termination_delay = body[4] };
    // 「9–255 Reserved」（Table 9-357）。
    if (r.status > BtmStatus.reject_leaving_ess) return error.ReservedValue;
    // 「This field is reserved if the Status code field value is not set to 5.」
    if (r.status != BtmStatus.reject_termination_delay and r.termination_delay != 0) return error.ReservedField;
    var pos: usize = 5;
    if (r.status == BtmStatus.accept) {
        // 「This field is present if the Status code subfield contains 0, and not present otherwise.」
        if (body.len - pos < 6) return error.Truncated;
        r.target_bssid = body[pos..][0..6].*;
        pos += 6;
    }
    var w = ie.Walker.init(body[pos..]);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != @backingInt(ie.ElementId.neighbor_report)) return error.UnexpectedElement;
        if (r.candidate_count == max_candidates) return error.TooMany;
        r.candidates[r.candidate_count] = try rrm.parseNeighborReport(el.body);
        r.candidate_count += 1;
    }
    // 「If the BTM Status Code field is a value of 6 …, the non-AP STA shall include a nonempty
    // BSS Transition Candidate List Entries field」（11.24.7.4）。
    if (r.status == BtmStatus.reject_candidate_list_provided and r.candidate_count == 0) return error.BadValue;
    for (r.candidateSlice()) |c| {
        if ((c.preference orelse 0) == 0) return error.ReservedValue;
    }
    return r;
}

pub const BtmResponseParams = struct {
    dialog_token: u8,
    status: u8,
    termination_delay: u8 = 0,
    /// 状态码为 0 时写进 Target BSSID；null 时写 6 个 0。状态码非 0 时必须为 null。
    target_bssid: ?frame.Mac = null,
    /// 已拼好的 Neighbor Report 元素串；状态码为 6 时不能为空。
    candidate_elements: []const u8 = &.{},
};

pub fn buildBtmResponse(out: []u8, p: BtmResponseParams) BuildError!usize {
    if (p.status > BtmStatus.reject_leaving_ess) return error.ReservedValue;
    if (p.status != BtmStatus.reject_termination_delay and p.termination_delay != 0) return error.ReservedField;
    if (p.status != BtmStatus.accept and p.target_bssid != null) return error.ReservedField;
    if (p.status == BtmStatus.reject_candidate_list_provided and p.candidate_elements.len == 0) return error.BadValue;
    try checkPreferenceList(BuildError, p.candidate_elements);
    const total = 5 + (if (p.status == BtmStatus.accept) @as(usize, 6) else 0) + p.candidate_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.btm_response);
    out[2] = p.dialog_token;
    out[3] = p.status;
    out[4] = p.termination_delay;
    var pos: usize = 5;
    if (p.status == BtmStatus.accept) {
        out[pos..][0..6].* = p.target_bssid orelse @splat(0);
        pos += 6;
    }
    @memcpy(out[pos..][0..p.candidate_elements.len], p.candidate_elements);
    return total;
}

// ---------------------------------------------------------------------------
// 5) STA 侧：怎么回 BTM Request（11.24.7.3 / 11.24.7.4）
// ---------------------------------------------------------------------------

pub const StaConfig = struct {
    /// SME 打算离开 ESS → Reject—Leaving ESS（11.24.7.4）。
    leaving_ess: bool = false,
    /// BSS Termination Included = 1 时的对策：0 接受终止；非 0 是请求延迟的分钟数
    /// （Reject—BSS termination delay，BSS Termination Delay 填这个值）。
    termination_delay_minutes: u8 = 0,
    /// 策略（非标准）：BSSID Information 的 Security 位为 0 的候选不选。9.4.2.37：Security
    /// 位为 0 表示「不支持同样的安全配置，或者信息未知」。
    require_security_match: bool = false,
    /// SME 自己排好的候选表（Neighbor Report 元素串，Preference 1–255）；非空时回 6。
    own_candidate_elements: ?[]const u8 = null,
};

pub const StaContext = struct {
    /// 当前关联的 BSSID：它不是迁移目标。
    current_bssid: frame.Mac = @splat(0),
    received_tu: u64 = 0,
    now_tu: u64 = 0,
    beacon_interval_tu: u16 = 100,
};

pub const Decision = struct {
    status: u8,
    target_bssid: ?frame.Mac = null,
    termination_delay: u8 = 0,
};

/// 候选表还在有效期内：Validity Interval 个 TBTT 之内才可以用（11.24.7.3：「The STA shall
/// not use the corresponding BSS Transition Candidate List Entries field information after the
/// indicated validity interval」）。
pub fn candidatesValid(req: *const BtmRequest, ctx: StaContext) bool {
    const valid_tu: u64 = @as(u64, req.validity_interval) * ctx.beacon_interval_tu;
    return ctx.now_tu <= ctx.received_tu + valid_tu;
}

const Rank = struct {
    /// 候选表的 Preference；没排优先级的（不在表里、或表里没带 Preference）是 0。
    pref: u8,
    rssi: i8,
    bssid: frame.Mac,
};

/// Table 9-152：255 最偏好；偏好相同按 RSSI 强者，再按 BSSID 字典序，保证结果确定。
fn better(a: Rank, b: Rank) bool {
    if (a.pref != b.pref) return a.pref > b.pref;
    if (a.rssi != b.rssi) return a.rssi > b.rssi;
    return std.mem.order(u8, &a.bssid, &b.bssid) == .lt;
}

const ScanResult = struct {
    best: ?Rank,
    /// 还需要扫描（有没见过的候选，或候选范围是开放的）→ 2；否则 → 7。
    needs_scan: bool,
};

fn scanCandidates(req: *const BtmRequest, cfg: StaConfig, table: *const scan.BssTable, ctx: StaContext) ScanResult {
    // 过了有效期就不能再用候选表：当作没有候选表、也没有 Abridged。
    const usable = candidatesValid(req, ctx);
    var res = ScanResult{ .best = null, .needs_scan = !usable or !req.mode.abridged };
    var unseen: usize = 0;
    if (usable) {
        for (req.candidateSlice()) |*c| {
            // 没有 Preference 子元素的候选不算 excluded（hostap common/wnm_sta.c:337）。
            if (c.preference == null or c.preference.? != 0) unseen += 1;
        }
    }
    for (table.entries[0..table.len]) |*b| {
        // 当前关联的 BSS 不是迁移目标。
        if (std.mem.eql(u8, &b.bssid, &ctx.current_bssid)) continue;
        var pref: u8 = 0;
        if (usable) {
            if (req.findCandidate(b.bssid)) |c| {
                // 「A Preference field value of 0 indicates that the BSS listed is an excluded
                // BSS.」（11.24.7.3）：带了 Preference 子元素且值为 0 才排除；没有该子元素的
                // 不算 excluded（hostap common/wnm_sta.c:337），排序时排在所有带 Preference 的之后。
                if (c.preference) |p| {
                    if (p == 0) continue;
                    pref = p;
                }
                // 见过了这个候选：下面即使因为不合适而跳过，也不再算「需要扫描」。
                unseen -= 1;
                if (cfg.require_security_match and !c.bssid_info.security) continue;
            } else if (req.mode.abridged) {
                // 「shall treat any BSSID in the current ESS that does not appear in the BSS
                // Transition Candidate List as if it were present … with a Preference value of 0」
                continue;
            }
        }
        // BTM 的规定不适用于 IBSS（11.24.7.1）。
        if (b.capability.ibss) continue;
        const rank = Rank{ .pref = pref, .rssi = b.rssi, .bssid = b.bssid };
        if (res.best == null or better(rank, res.best.?)) res.best = rank;
    }
    // 候选范围封闭（Abridged = 1 且候选表可用）时：非 excluded 的候选都见过却没选中 → 再扫也没
    // 用；还有没见过的候选 → 需要扫描。
    if (usable and req.mode.abridged) res.needs_scan = unseen != 0;
    return res;
}

/// 收到 BTM Request 后的 Response 内容。
///
///   * BSS Termination Included = 1：0（接受终止）或 5（请求延迟）；
///   * 打算离开 ESS：8；SME 给了自己的候选表：6（Response 必须带非空候选表）；
///   * 扫描表里有非 excluded 的候选：0，Target BSSID 取偏好最高的；
///   * 候选范围封闭（Abridged）且候选全都见过或全被排除：7；
///   * 其余：2（候选还在，但本端没收到它们的 Beacon / Probe Response，需要扫描）。
pub fn decideBtm(req: *const BtmRequest, cfg: StaConfig, table: *const scan.BssTable, ctx: StaContext) Decision {
    if (req.mode.bss_termination_included) {
        if (cfg.termination_delay_minutes != 0) {
            return .{ .status = BtmStatus.reject_termination_delay, .termination_delay = cfg.termination_delay_minutes };
        }
        const best = scanCandidates(req, cfg, table, ctx).best;
        return .{ .status = BtmStatus.accept, .target_bssid = if (best) |b| b.bssid else null };
    }
    if (cfg.leaving_ess) return .{ .status = BtmStatus.reject_leaving_ess };
    if (cfg.own_candidate_elements) |own| {
        if (own.len != 0) return .{ .status = BtmStatus.reject_candidate_list_provided };
    }
    const res = scanCandidates(req, cfg, table, ctx);
    if (res.best) |b| return .{ .status = BtmStatus.accept, .target_bssid = b.bssid };
    if (!res.needs_scan) return .{ .status = BtmStatus.reject_no_suitable_candidates };
    return .{ .status = BtmStatus.reject_insufficient_frames };
}

/// `scan.BssTable.find` 要可变指针；这里只读。
fn findBss(table: *const scan.BssTable, bssid: frame.Mac) ?*const scan.Bss {
    for (table.entries[0..table.len]) |*b| {
        if (std.mem.eql(u8, &b.bssid, &bssid)) return b;
    }
    return null;
}

// ---------------------------------------------------------------------------
// 6) AP 侧：发 BTM Request（11.24.7.3）
// ---------------------------------------------------------------------------

pub const max_btm_stas = 8;

pub const BtmApSta = struct {
    address: frame.Mac = @splat(0),
    /// 关联 STA 的 Extended Capabilities 里 BSS Transition 位（B19，11.24.7.1）。
    supports_btm: bool = false,
    /// 最近一帧 Request 的 Disassociation Imminent = 1。
    disassoc_imminent: bool = false,
    /// 到 AP 发 Disassociation 帧之前还有几个 TBTT。
    disassoc_timer: u16 = 0,
};

/// 进程内的 AP 模型：Disassociation Timer 的记账与组地址 Request 的条件。
pub const BtmAp = struct {
    stas: [max_btm_stas]BtmApSta = @splat(.{}),
    len: u8 = 0,

    pub fn init() BtmAp {
        return .{};
    }

    pub fn count(self: *const BtmAp) usize {
        return self.len;
    }

    pub fn associate(self: *BtmAp, address: frame.Mac, supports_btm: bool) ?*BtmApSta {
        if (self.len == max_btm_stas) return null;
        self.stas[self.len] = .{ .address = address, .supports_btm = supports_btm };
        self.len += 1;
        return &self.stas[self.len - 1];
    }

    pub fn find(self: *BtmAp, address: frame.Mac) ?*BtmApSta {
        for (self.stas[0..self.len]) |*s| {
            if (std.mem.eql(u8, &s.address, &address)) return s;
        }
        return null;
    }

    pub fn dissociate(self: *BtmAp, address: frame.Mac) void {
        for (self.stas[0..self.len], 0..) |*s, i| {
            if (std.mem.eql(u8, &s.address, &address)) {
                self.len -= 1;
                self.stas[i] = self.stas[self.len];
                return;
            }
        }
    }

    /// 「The AP may transmit a group addressed BSS Transition Management Request frame to
    /// associated non-AP STAs if all associated non-AP STAs support the BSS transition
    /// management; otherwise the AP shall not transmit a group addressed BSS Transition
    /// Management Request frame」（11.24.7.3）。
    pub fn groupRequestAllowed(self: *const BtmAp) bool {
        if (self.len == 0) return false;
        for (self.stas[0..self.len]) |s| {
            if (!s.supports_btm) return false;
        }
        return true;
    }

    /// 发出一帧 Disassociation Imminent = 1 的 Request 之后记账：计时器是「0 or the number
    /// of TBTTs that will occur prior to the AP disassociating the non-AP STA」（11.24.7.3）。
    pub fn noteImminentRequest(self: *BtmAp, address: frame.Mac, tbtts: u16) ?*BtmApSta {
        const s = self.find(address) orelse return null;
        s.disassoc_imminent = true;
        s.disassoc_timer = tbtts;
        return s;
    }

    /// 「The AP shall decrement the timer by one after transmitting each Beacon frame until the
    /// timer has value of 0」（11.24.7.3）。后续 Request 带计时器的当前值。
    pub fn onBeaconSent(self: *BtmAp) void {
        for (self.stas[0..self.len]) |*s| {
            if (s.disassoc_timer != 0) s.disassoc_timer -= 1;
        }
    }

    /// 下一帧 Request 里该填的 Disassociation Timer。
    pub fn disassocTimer(self: *BtmAp, address: frame.Mac) u16 {
        const s = self.find(address) orelse return 0;
        return s.disassoc_timer;
    }

    /// 「the AP shall not transmit a Disassociation frame to the non-AP STA unless the timer for
    /// the non-AP STA has value of 0」（11.24.7.3）。
    pub fn mayDisassociate(self: *BtmAp, address: frame.Mac) bool {
        const s = self.find(address) orelse return false;
        return s.disassoc_imminent and s.disassoc_timer == 0;
    }
};

/// 「When the BSS Transition Management Request frame is transmitted as a group addressed frame,
/// a receiving non-AP STA shall not respond with a BSS Transition Management Response frame.」
/// 单播的 Request：「shall respond … with a BSS Transition Management Response frame」（11.24.7.3）。
pub fn responseExpected(group_addressed: bool) bool {
    return !group_addressed;
}

/// AP 给一个候选 BSS 的排位信息。
pub const ApCandidate = struct {
    bssid: frame.Mac,
    /// Table 9-152（p.921）：0 = Excluded BSS，1–255 排序。
    preference: u8 = 0,
    /// BSSID Information 的 Security 位（9.4.2.37）。
    security: bool = false,
    operating_class: u8 = 255,
    /// dot11PHYType；255 表示未知。
    phy_type: u8 = 255,
    /// 只在能保证 TSF Offset 累计误差 ≤ 1.5 TU 时给出（11.11.10.3）。
    tsf: ?rrm.TsfInfo = null,
    termination: ?rrm.TerminationDuration = null,
};

pub const ApRequestParams = struct {
    dialog_token: u8,
    disassoc_imminent: bool = false,
    disassoc_timer: u16 = 0,
    validity_interval: u8,
    candidates: []const ApCandidate,
    /// 发请求的 AP 的国家串；邻居国家不同才带 Condensed Country String 子元素（9.4.2.37）。
    serving_country: [3]u8 = @splat(0),
};

/// 由 AP 的扫描表排 BTM Request：每个在扫描表里见过的候选一个 Neighbor Report 元素（信道号
/// 取自扫描表，Capabilities 位取自 Capability Information，其余取自 `ApCandidate`）。一个
/// 都排不进时 Preferred Candidate List Included = 0（9.6.14.9）。
pub fn buildApRequest(out: []u8, table: *const scan.BssTable, p: ApRequestParams) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    if (p.validity_interval == 0) return error.ReservedValue;
    if (!p.disassoc_imminent and p.disassoc_timer != 0) return error.ReservedField;
    if (out.len < 7) return error.NoRoom;
    var pos: usize = 7;
    var listed: usize = 0;
    for (p.candidates) |c| {
        const b = findBss(table, c.bssid) orelse continue;
        var n = rrm.NeighborReport{
            .bssid = b.bssid,
            .bssid_info = .{
                .ap_reachability = .unknown,
                .security = c.security,
                .capabilities = rrm.BssidCapabilities.fromCapability(b.capability),
            },
            .operating_class = c.operating_class,
            .channel = b.channel,
            .phy_type = c.phy_type,
            .tsf = c.tsf,
            .preference = c.preference,
            .termination = c.termination,
        };
        // 「present only if the country of the neighbor AP … differs from the country of the AP
        // that sent this neighbor report」（9.4.2.37）。
        if (b.country_present and !std.mem.eql(u8, b.country[0..2], p.serving_country[0..2])) n.condensed_country = b.country[0..2].*;
        pos += try rrm.buildNeighborReport(out[pos..], n);
        listed += 1;
    }
    out[0] = category;
    out[1] = @backingInt(Action.btm_request);
    out[2] = p.dialog_token;
    out[3] = (RequestMode{
        .preferred_candidate_list_included = listed != 0,
        .disassociation_imminent = p.disassoc_imminent,
    }).word();
    w16(out[4..6], p.disassoc_timer);
    out[6] = p.validity_interval;
    return pos;
}

// ---------------------------------------------------------------------------
// 7) WNM Sleep Mode 元素与帧（9.4.2.82；9.6.14.19 / 9.6.14.20）
// ---------------------------------------------------------------------------

/// Table 9-203（p.1006）：Enter 0、Exit 1，其余保留。
pub const SleepActionType = enum(u8) {
    enter = 0,
    exit = 1,
    _,
};

/// Table 9-204（p.1006）：WNM Sleep Mode Response Status；6–255 保留。
pub const SleepStatus = struct {
    /// Enter/Exit WNM sleep mode Accept。
    pub const accept: u8 = 0;
    /// Exit WNM sleep mode Accept, GTK/IGTK update required。
    pub const accept_exit_update_keys: u8 = 1;
    /// Denied. The AP is unable to perform the requested action。
    pub const denied: u8 = 2;
    /// Denied temporarily. The request can be submitted again at a later time。
    pub const denied_temporarily: u8 = 3;
    /// Denied. Due to the pending key expiration。
    pub const denied_key_expiration: u8 = 4;
    /// Denied. Due to other WNM services in use by the requesting STA。
    pub const denied_other_wnm: u8 = 5;

    pub fn name(code: u8) ?[]const u8 {
        return switch (code) {
            0 => "Enter/Exit WNM sleep mode Accept",
            1 => "Exit WNM sleep mode Accept, GTK/IGTK update required",
            2 => "Denied. The AP is unable to perform the requested action",
            3 => "Denied temporarily",
            4 => "Denied. Due to the pending key expiration",
            5 => "Denied. Due to other WNM services in use by the requesting STA",
            else => null,
        };
    }
};

/// Figure 9-424（p.1005）：Action Type(1)、WNM Sleep Mode Response Status(1)、WNM Sleep
/// Interval(2)，Length = 4。
pub const sleep_element_len = 4;

pub const SleepElement = struct {
    action_type: SleepActionType,
    /// 「valid only in the WNM Sleep Mode element in a WNM Sleep Mode Response frame and is
    /// reserved otherwise」（9.4.2.82）。
    response_status: u8 = 0,
    /// 每 DTIM 间隔数醒来一次；0 = 不按固定间隔醒。Action Type = Exit 时保留。
    interval: u16 = 0,
};

pub fn parseSleepElement(body: []const u8) Error!SleepElement {
    if (body.len != sleep_element_len) return error.BadLength;
    if (body[0] > @backingInt(SleepActionType.exit)) return error.ReservedValue;
    if (body[1] > SleepStatus.denied_other_wnm) return error.ReservedValue;
    return .{ .action_type = @fromBackingInt(@intCast(body[0])), .response_status = body[1], .interval = le16(body[2..4]) };
}

pub fn buildSleepElement(out: []u8, e: SleepElement) BuildError!usize {
    if (@backingInt(e.action_type) > @backingInt(SleepActionType.exit)) return error.ReservedValue;
    if (e.response_status > SleepStatus.denied_other_wnm) return error.ReservedValue;
    if (out.len < 6) return error.NoRoom;
    out[0] = @backingInt(ie.ElementId.wnm_sleep_mode);
    out[1] = sleep_element_len;
    out[2] = @backingInt(e.action_type);
    out[3] = e.response_status;
    w16(out[4..6], e.interval);
    return 6;
}

/// Figure 9-715（p.1238）：Category、WNM Action、Dialog Token(1)、WNM Sleep Mode Element(6)、
/// TFS Request Elements。
pub const SleepRequest = struct {
    dialog_token: u8,
    element: SleepElement,
    tfs_request: []const u8,
};

pub fn parseSleepRequest(body: []const u8) Error!SleepRequest {
    if (body.len < 9) return error.Truncated;
    try checkHeader(body, .sleep_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    if (body[3] != @backingInt(ie.ElementId.wnm_sleep_mode) or body[4] != sleep_element_len) return error.MissingElement;
    const e = try parseSleepElement(body[5..9]);
    if (e.response_status != 0) return error.ReservedField;
    // 「The WNM Sleep Interval field is reserved if the Action Type field is 1」（9.4.2.82）。
    if (e.action_type == .exit and e.interval != 0) return error.ReservedField;
    return .{ .dialog_token = body[2], .element = e, .tfs_request = body[9..] };
}

pub const SleepRequestParams = struct {
    dialog_token: u8,
    action_type: SleepActionType,
    interval: u16 = 0,
    tfs_request_elements: []const u8 = &.{},
};

pub fn buildSleepRequest(out: []u8, p: SleepRequestParams) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    if (p.action_type == .exit and p.interval != 0) return error.ReservedField;
    const total = 9 + p.tfs_request_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.sleep_request);
    out[2] = p.dialog_token;
    _ = try buildSleepElement(out[3..], .{ .action_type = p.action_type, .interval = p.interval });
    @memcpy(out[9..][0..p.tfs_request_elements.len], p.tfs_request_elements);
    return total;
}

/// Figure 9-716（p.1238）：Category、WNM Action、Dialog Token(1)、Key Data Length(2)、Key
/// Data、WNM Sleep Mode Element(6)、TFS Response Elements。没有管理帧保护时 Key Data Length = 0。
pub const SleepResponse = struct {
    dialog_token: u8,
    key_data: []const u8,
    element: SleepElement,
    tfs_response: []const u8,
};

pub fn parseSleepResponse(body: []const u8) Error!SleepResponse {
    if (body.len < 5) return error.Truncated;
    try checkHeader(body, .sleep_response);
    const n: usize = le16(body[3..5]);
    if (body.len - 5 < n) return error.Truncated;
    var pos: usize = 5 + n;
    if (body.len - pos < 6) return error.MissingElement;
    if (body[pos] != @backingInt(ie.ElementId.wnm_sleep_mode) or body[pos + 1] != sleep_element_len) return error.MissingElement;
    // 只取元素自己的 4 个八位组：后面是 TFS Response Elements（图 9-716），不是元素的一部分。
    const e = try parseSleepElement(body[pos + 2 ..][0..sleep_element_len]);
    if (e.action_type == .exit and e.interval != 0) return error.ReservedField;
    pos += 6;
    return .{ .dialog_token = body[2], .key_data = body[5 .. 5 + n], .element = e, .tfs_response = body[pos..] };
}

pub const SleepResponseParams = struct {
    dialog_token: u8,
    element: SleepElement,
    key_data: []const u8 = &.{},
    tfs_response_elements: []const u8 = &.{},
};

pub fn buildSleepResponse(out: []u8, p: SleepResponseParams) BuildError!usize {
    if (p.element.action_type == .exit and p.element.interval != 0) return error.ReservedField;
    const total = 3 + 2 + p.key_data.len + 6 + p.tfs_response_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.sleep_response);
    out[2] = p.dialog_token;
    w16(out[3..5], @intCast(p.key_data.len));
    @memcpy(out[5..][0..p.key_data.len], p.key_data);
    _ = try buildSleepElement(out[5 + p.key_data.len ..], p.element);
    @memcpy(out[11 + p.key_data.len ..][0..p.tfs_response_elements.len], p.tfs_response_elements);
    return total;
}

// ---------------------------------------------------------------------------
// 8) STA 侧：WNM sleep mode 的进出与 DTIM 期的行为（11.2.3.18.2）
// ---------------------------------------------------------------------------

pub const SleepState = enum { awake, entering, sleeping, exiting };

pub const StateError = error{ Busy, NotSleeping, IntervalTooLong, BadToken };

/// 「The WNM Sleep Interval field shall be less than the BSS max idle period」（11.2.3.18.2）。
/// Max Idle Period 以 1000 TU 为单位（dot11BssMaxIdlePeriod），一个 DTIM 间隔是 dtim_period ×
/// beacon_interval 个 TU。返回满足 interval × dtim_period × beacon_interval < max_idle × 1000
/// 的最大 interval；`max_idle_period` 为 0（没有上限可算）或 DTIM 周期为 0 时返回 0。
pub fn maxSleepInterval(max_idle_period: u16, dtim_period: u8, beacon_interval_tu: u16) u32 {
    if (max_idle_period == 0 or dtim_period == 0 or beacon_interval_tu == 0) return 0;
    const limit_tu: u64 = @as(u64, max_idle_period) * 1000 - 1;
    const per_dtim_tu: u64 = @as(u64, dtim_period) * beacon_interval_tu;
    return @intCast(limit_tu / per_dtim_tu);
}

pub const DtimEvent = union(enum) {
    /// 这个 DTIM 不必醒：WNM sleep mode 下不必每个 DTIM 都醒（11.2.3.18.2）。
    doze,
    /// 醒：`tim_bit` = TIM 里本 STA 的位置了，`group_pending` = AP 缓存了组播。
    wake: struct { tim_bit: bool, group_pending: bool },
};

pub const SleepSta = struct {
    state: SleepState = .awake,
    interval_dtim: u16 = 0,
    pending_token: u8 = 0,
    /// AP 的 Response 指示成功进入：GTKSA（用了 MFP 时连 IGTKSA）要删除（11.2.3.18.2）。
    keys_invalidated: bool = false,
    /// AP 说需要 GTK/IGTK 更新（status 1；新密钥在 Key Data 里）。
    key_update_required: bool = false,
    last_status: u8 = 0,

    pub fn sleeping(self: *const SleepSta) bool {
        return self.state == .sleeping;
    }

    /// 「The non-AP STA does not participate in GTK/IGTK updates」（11.2.3.18.2）。
    pub fn gtkUpdateApplies(self: *const SleepSta) bool {
        return self.state != .sleeping;
    }

    /// 发进入请求。`max_idle_period` 是 AP 在（Re)Association Response 里给的 BSS Max Idle
    /// Period；null 表示 AP 没给，不做比较。
    pub fn requestEnter(self: *SleepSta, token: u8, interval_dtim: u16, max_idle_period: ?u16, dtim_period: u8, beacon_interval_tu: u16) StateError!SleepElement {
        if (self.state != .awake) return error.Busy;
        if (token == 0) return error.BadToken;
        if (max_idle_period) |m| {
            const sleep_tu: u64 = @as(u64, interval_dtim) * dtim_period * beacon_interval_tu;
            if (sleep_tu >= @as(u64, m) * 1000) return error.IntervalTooLong;
        }
        self.state = .entering;
        self.interval_dtim = interval_dtim;
        self.pending_token = token;
        self.keys_invalidated = false;
        self.key_update_required = false;
        return .{ .action_type = .enter, .interval = interval_dtim };
    }

    /// 发退出请求：Action Type = Exit，Interval 保留（11.2.3.18.2）。
    pub fn requestExit(self: *SleepSta, token: u8) StateError!SleepElement {
        if (self.state != .sleeping) return error.NotSleeping;
        if (token == 0) return error.BadToken;
        self.state = .exiting;
        self.pending_token = token;
        return .{ .action_type = .exit };
    }

    /// 请求没有得到 Response（超时）：回到请求之前的状态。
    pub fn onRequestTimeout(self: *SleepSta) void {
        self.state = if (self.state == .entering) .awake else .sleeping;
    }

    /// 收到 AP 的 Response；返回 false 表示忽略（Dialog Token 对不上、Action Type 没回显、
    /// 状态码与请求对不上）。
    ///
    /// 主动发的 Response（Dialog Token = 0）：status 1 让 STA 退出 WNM sleep mode，其余忽略
    /// （11.2.3.18.2）。应答进入请求：status 0 进 sleeping 并删 GTKSA / IGTKSA，2–5 回 awake。
    /// 应答退出请求：status 0 / 1 回 awake（1 表示要更新密钥），2–5 留在 sleeping。
    pub fn onResponse(self: *SleepSta, resp: SleepResponse) bool {
        const status = resp.element.response_status;
        if (resp.dialog_token == 0) {
            const accepted = self.sleeping() and status == SleepStatus.accept_exit_update_keys;
            if (accepted) {
                self.state = .awake;
                self.key_update_required = true;
                self.last_status = status;
            }
            return accepted;
        }
        const want_enter = self.state == .entering;
        if (!want_enter and self.state != .exiting) return false;
        if (resp.dialog_token != self.pending_token) return false;
        const want: SleepActionType = if (want_enter) .enter else .exit;
        if (resp.element.action_type != want) return false;
        self.last_status = status;
        if (want_enter) {
            // status 1（Exit … Accept）只对退出有意义。
            if (status == SleepStatus.accept_exit_update_keys) return false;
            self.state = if (status == SleepStatus.accept) .sleeping else .awake;
            self.keys_invalidated = status == SleepStatus.accept;
            return true;
        }
        const ok = status <= SleepStatus.accept_exit_update_keys;
        self.state = if (ok) .awake else .sleeping;
        self.key_update_required = status == SleepStatus.accept_exit_update_keys;
        return true;
    }

    /// 「The STA wakes up at intervals not longer than the value indicated by the WNM Sleep
    /// Interval field to check whether the corresponding TIM bit is set or group addressed
    /// traffic is pending」（11.2.3.18.2）。Interval = 0：「does not wake up at any specific
    /// interval」（9.4.2.82）。
    pub fn mustWakeAt(self: *const SleepSta, dtim_index: u64) bool {
        if (self.state != .sleeping or self.interval_dtim == 0) return false;
        return dtim_index % self.interval_dtim == 0;
    }

    /// DTIM Beacon 到了：不在醒来点就继续 doze；在醒来点就醒，并读出 TIM 里的两位。
    pub fn onDtim(self: *const SleepSta, tim: ?ie.Tim, dtim_index: u64, aid: u16) DtimEvent {
        if (!self.mustWakeAt(dtim_index)) return .doze;
        const t = tim orelse return .{ .wake = .{ .tim_bit = false, .group_pending = false } };
        return .{ .wake = .{ .tim_bit = t.bitSet(aid), .group_pending = t.multicast_buffered } };
    }
};

// ---------------------------------------------------------------------------
// 9) AP 侧：WNM sleep mode 服务（11.2.3.18.3）
// ---------------------------------------------------------------------------

/// Exit 之后怎么把当前 GTK（有 MFP 时连 IGTK）交给 STA（11.2.3.18.3）。
pub const KeyHandling = enum {
    /// 没有 RSN，或没有配好有效 PTK：不需要。
    none,
    /// RSN + 管理帧保护 + 有效 PTK：当前（更新中则是 pending 的）GTK / IGTK 放进 Response 的 Key Data。
    key_data,
    /// RSN、无管理帧保护、有效 PTK：Response 之后紧接着做组密钥握手（12.7.7）。
    group_key_handshake,
};

pub fn keyHandling(rsn: bool, mfp: bool, ptk: bool) KeyHandling {
    if (!rsn or !ptk) return .none;
    return if (mfp) .key_data else .group_key_handshake;
}

pub const max_sleep_stas = 8;

pub const SleepApSta = struct {
    aid: u16 = 0,
    sleeping: bool = false,
    interval_dtim: u16 = 0,
    rsn: bool = false,
    mfp: bool = false,
    ptk: bool = false,
    /// 有排队的 TFS Notify / 匹配帧：AP 置这个 STA 的 TIM 位。
    tim_bit: bool = false,
    /// 这个 STA 还在用别的 WNM 服务：进入请求回 5。
    other_wnm_in_use: bool = false,
};

/// 进程内的 AP 模型：接受 / 拒绝、停发单播、TIM 位、密钥处理。
pub const SleepAp = struct {
    stas: [max_sleep_stas]SleepApSta = @splat(.{}),
    len: u8 = 0,
    /// AP 正在做 GTK/IGTK 更新：进入请求回 4；此间的 Exit 要带 pending 的密钥。
    key_update_in_progress: bool = false,

    pub fn init() SleepAp {
        return .{};
    }

    pub fn associate(self: *SleepAp, aid: u16, rsn: bool, mfp: bool, ptk: bool) ?*SleepApSta {
        if (aid == 0 or self.len == max_sleep_stas) return null;
        self.stas[self.len] = .{ .aid = aid, .rsn = rsn, .mfp = mfp, .ptk = ptk };
        self.len += 1;
        return &self.stas[self.len - 1];
    }

    pub fn find(self: *SleepAp, aid: u16) ?*SleepApSta {
        for (self.stas[0..self.len]) |*s| {
            if (s.aid == aid) return s;
        }
        return null;
    }

    pub fn dissociate(self: *SleepAp, aid: u16) void {
        for (self.stas[0..self.len], 0..) |*s, i| {
            if (s.aid == aid) {
                self.len -= 1;
                self.stas[i] = self.stas[self.len];
                return;
            }
        }
    }

    /// 处理一帧 Request：改状态，把 Response 写进 `out`（Dialog Token 与 Action Type 回显；
    /// 进入时 Action Type「shall be set to Enter WNM sleep mode」）。
    pub fn onRequest(self: *SleepAp, sta: *SleepApSta, req: SleepRequest, out: []u8) BuildError!usize {
        var element = req.element;
        var status: u8 = SleepStatus.accept;
        switch (element.action_type) {
            .enter => {
                if (self.key_update_in_progress) {
                    status = SleepStatus.denied_key_expiration;
                } else if (sta.other_wnm_in_use) {
                    status = SleepStatus.denied_other_wnm;
                } else {
                    sta.sleeping = true;
                    sta.interval_dtim = element.interval;
                }
            },
            // 「the AP shall disable WNM sleep mode service for the requesting STA」
            .exit => {
                sta.sleeping = false;
                element.interval = 0;
            },
            else => return error.ReservedValue,
        }
        element.response_status = status;
        return buildSleepResponse(out, .{ .dialog_token = req.dialog_token, .element = element });
    }

    /// 「When WNM sleep mode is enabled for an associated STA, the AP shall stop sending all
    /// individually addressed MPDUs to the non-AP STA」（11.2.3.18.3）。
    pub fn unicastAllowed(sta: *const SleepApSta) bool {
        return !sta.sleeping;
    }

    /// 「An AP shall not perform GTK/IGTK updates for the STAs in WNM sleep mode」。
    pub fn gtkUpdateApplies(sta: *const SleepApSta) bool {
        return !sta.sleeping;
    }

    /// 「The AP shall set the TIM bit corresponding to the AID of the associated STA for which
    /// the AP has queued either a TFS Notify frame or matching frame」。
    pub fn queueTfsMatch(self: *SleepAp, aid: u16) bool {
        const s = self.find(aid) orelse return false;
        s.tim_bit = true;
        return true;
    }

    pub fn timBit(self: *SleepAp, aid: u16) bool {
        const s = self.find(aid) orelse return false;
        return s.tim_bit;
    }

    /// 「When all traffic filter sets established for a STA are deleted upon frame matches, the
    /// AP shall also disable the WNM sleep mode service and transmit to the STA an unsolicited
    /// WNM Sleep Mode Response frame with the WNM Sleep Mode Response status value … set to 1」
    /// （11.2.3.18.3）。主动发的帧 Dialog Token 为 0（9.6.14.20）。
    pub fn onFiltersDeleted(sta: *SleepApSta, out: []u8) BuildError!usize {
        sta.sleeping = false;
        return buildSleepResponse(out, .{
            .dialog_token = 0,
            .element = .{ .action_type = .exit, .response_status = SleepStatus.accept_exit_update_keys },
        });
    }
};

// ---------------------------------------------------------------------------
// 10) TFS：TCLAS 元素与分类器（9.4.2.31 / 9.4.2.33；Figure 9-269–9-290；
//     Table 9-144 / 9-145 / 9-146 / 9-147 / 9-148 / 9-149）
// ---------------------------------------------------------------------------

/// Table 9-77（p.784–786）：TCLAS = 14、TCLAS Processing = 44、TFS Request = 91、TFS
/// Response = 92。ie.ElementId 没有这四个 ID（ie.zig 不归本切片改），用本地常量。
pub const tclas_element_id: u8 = 14;
pub const tclas_processing_element_id: u8 = 44;
pub const tfs_request_element_id: u8 = 91;
pub const tfs_response_element_id: u8 = 92;

/// Table 9-145（p.908）：Frame classifier type；7–255 保留。
pub const ClassifierType = enum(u8) {
    ethernet = 0,
    tcp_udp_ip = 1,
    vlan = 2,
    filter_offset = 3,
    ip_and_higher = 4,
    dot1d_q = 5,
    mac_header = 6,
    _,
};

/// Table 9-149（p.915）：Processing subfield；3–255 保留。
pub const TclasProcessing = enum(u8) {
    /// PDU / MSDU 要匹配全部关联的 TCLAS。
    match_all = 0,
    /// 至少匹配一个关联的 TCLAS。
    match_any = 1,
    /// 不属于任何其他 TS 的帧（没有关联的 TCLAS）——TFS 子元素要求 1..n 个 TCLAS，用不到。
    match_rest = 2,
    _,
};

/// Figure 9-269（p.906）：Element ID(1) Length(1) User Priority(1) Frame Classifier(3–255)。
pub const Tclas = struct {
    /// Table 9-144（p.907）：0–7 是 MSDU 的 UP、8–11 是 MPDU 的 AC、255 不参与比较；12–254 保留。
    user_priority: u8,
    classifier: Classifier,
};

/// Figure 9-270–9-279（p.908–912）：七种分类器。字段全集都存（各布局固定）；Classifier Mask
/// 只决定匹配时比较哪些字段。类型 3 的 Value / Mask 与类型 6 的规格串是变长字节串，指向
/// 输入缓冲。分类器参数按原文 big-endian 传输（类型 1 / 4 / 5 明说；类型 0 的 Type 按
/// Ethernet 字节序；类型 2 的 TCI 按 802.1Q）。
pub const Classifier = struct {
    kind: ClassifierType,
    /// 类型 ≤ 5：1 个八位组位图，位 i → 图里第 i 个参数；类型 2 必须为 0；类型 6 改存
    /// `mac_mask` 的 3 个八位组（9 个 2 位控制子字段）。
    mask: u8 = 0,
    // 类型 0（Figure 9-271：SA(6) DA(6) Type(2)）。
    eth_sa: [6]u8 = @splat(0),
    eth_da: [6]u8 = @splat(0),
    eth_type: u16 = 0,
    // 类型 1 / 4（Figure 9-272 / 9-273 / 9-276 / 9-277；地址按版本是 4 或 16 字节）。
    ip_version: u8 = 4,
    ip_src: [16]u8 = @splat(0),
    ip_dst: [16]u8 = @splat(0),
    ip_addr_len: u8 = 4,
    sport: u16 = 0,
    dport: u16 = 0,
    /// DSCP 只比较 6 个 LSB（2 个 MSB 忽略）；IPv6 的 Flow Label 只比较 20 个 LSB。
    dscp: u8 = 0,
    /// IPv4：Protocol；IPv6 且类型 4：Next Header。
    protocol: u8 = 0,
    flow: [3]u8 = @splat(0),
    // 类型 2（Figure 9-274：802.1Q VLAN TCI）。
    vlan_tci: u16 = 0,
    // 类型 3（Figure 9-275：Filter Offset(2) Filter Value(n) Filter Mask(n)）。
    filter_offset: u16 = 0,
    filter_value: []const u8 = &.{},
    filter_mask: []const u8 = &.{},
    // 类型 5（Figure 9-278：PCP/UP(1，4 个 LSB) DEI(1，LSB) VID(2，12 个 LSB)）。
    dot1_pcp: u8 = 0,
    dot1_dei: u8 = 0,
    dot1_vid: u16 = 0,
    // 类型 6（Figure 9-279：3 个八位组掩码 + 各 Match Specification / Filter Mask）。
    mac_mask: [3]u8 = @splat(0),
    mac_specs: []const u8 = &.{},
};

fn be16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .big);
}

fn wbe16(out: []u8, v: u16) void {
    std.mem.writeInt(u16, out[0..2], v, .big);
}

/// IPv4 地址放进 16 字节槽的前 4 字节；比较时只看前 `ip_addr_len` 字节。
fn pad16(src: []const u8) [16]u8 {
    var out: [16]u8 = @splat(0);
    @memcpy(out[0..src.len], src);
    return out;
}

/// 解析 TCLAS 元素体（Element ID / Length 之后）：User Priority(1) + Frame Classifier。
pub fn parseTclasElement(body: []const u8) Error!Tclas {
    if (body.len < 2) return error.Truncated;
    // Table 9-144：12–254 保留；255 = UP 与 AC 都不比较。
    if (body[0] >= 12 and body[0] != 255) return error.ReservedValue;
    return .{ .user_priority = body[0], .classifier = try parseClassifier(body[1..]) };
}

fn parseClassifier(f: []const u8) Error!Classifier {
    if (f.len < 2) return error.Truncated;
    const t = f[0];
    if (t > 6) return error.ReservedValue; // Table 9-145：7–255 保留
    return switch (t) {
        0 => parseEthernet(f),
        1 => parseIp(f, .tcp_udp_ip),
        2 => parseVlan(f),
        3 => parseFilterOffset(f),
        4 => parseIp(f, .ip_and_higher),
        5 => parseDot1(f),
        else => parseMacHeader(f),
    };
}

/// Figure 9-271（p.909）：Type(1) Mask(1) SA(6) DA(6) Type(2) = 16 个八位组；位图 3–7 不指向
/// 任何参数（保留，须为 0）。
fn parseEthernet(f: []const u8) Error!Classifier {
    if (f.len != 16) return error.BadLength;
    if (f[1] & 0xF8 != 0) return error.ReservedField;
    return .{ .kind = .ethernet, .mask = f[1], .eth_sa = f[2..8].*, .eth_da = f[8..14].*, .eth_type = be16(f[14..16]) };
}

/// Figure 9-272 / 9-273（p.910）与 Figure 9-276 / 9-277（p.912）。IPv4：Ver(1) Src(4) Dst(4)
/// SPort(2) DPort(2) DSCP(1) Protocol(1) Reserved(1)，分类器 18 字节；IPv6 类型 1 没有
/// DSCP / Next Header（分类器 42 字节），类型 4 两者都有（44 字节）；末尾都是 Flow Label(3)。
fn parseIp(f: []const u8, kind: ClassifierType) Error!Classifier {
    const mask = f[1];
    if (f.len < 3) return error.Truncated;
    switch (f[2]) {
        4 => {
            if (f.len != 18) return error.BadLength;
            if (mask & 0x80 != 0) return error.ReservedField; // 位 7 → 保留八位组
            if (kind == .ip_and_higher and mask & 0x01 == 0) return error.ReservedField;
            return .{
                .kind = kind,
                .mask = mask,
                .ip_version = 4,
                .ip_addr_len = 4,
                .ip_src = pad16(f[3..7]),
                .ip_dst = pad16(f[7..11]),
                .sport = be16(f[11..13]),
                .dport = be16(f[13..15]),
                .dscp = f[15],
                .protocol = f[16],
            };
        },
        6 => {
            if (kind == .tcp_udp_ip) {
                if (f.len != 42) return error.BadLength;
                if (mask & 0xC0 != 0) return error.ReservedField; // 位 6–7 → 无对应参数
                return .{
                    .kind = kind,
                    .mask = mask,
                    .ip_version = 6,
                    .ip_addr_len = 16,
                    .ip_src = f[3..19].*,
                    .ip_dst = f[19..35].*,
                    .sport = be16(f[35..37]),
                    .dport = be16(f[37..39]),
                    .flow = f[39..42].*,
                };
            }
            if (f.len != 44) return error.BadLength;
            // 「A TCLAS element is valid when the Classifier Mask Version bit is 1.」
            if (mask & 0x01 == 0) return error.ReservedField;
            return .{
                .kind = kind,
                .mask = mask,
                .ip_version = 6,
                .ip_addr_len = 16,
                .ip_src = f[3..19].*,
                .ip_dst = f[19..35].*,
                .sport = be16(f[35..37]),
                .dport = be16(f[37..39]),
                .dscp = f[39],
                .protocol = f[40],
                .flow = f[41..44].*,
            };
        },
        else => return error.BadValue, // Version 取 RFC 791 / RFC 2460 的值
    }
}

/// Figure 9-274（p.910）：Type(1) Mask(1) TCI(2) = 4；「The Classifier Mask subfield is
/// reserved.」→ 必须为 0，TCI 无条件比较。
fn parseVlan(f: []const u8) Error!Classifier {
    if (f.len != 4) return error.BadLength;
    if (f[1] != 0) return error.ReservedField;
    return .{ .kind = .vlan, .vlan_tci = be16(f[2..4]) };
}

/// Figure 9-275（p.910）：Type(1) Mask(1，保留) Offset(2) Value(n) Mask(n)；n =（元素 Length
/// − 5）/ 2 ≥ 1，Value 与 Mask 等长；Mask 里的位是 1 才比较对应位。
fn parseFilterOffset(f: []const u8) Error!Classifier {
    if (f.len < 6 or (f.len - 4) % 2 != 0) return error.BadLength;
    if (f[1] != 0) return error.ReservedField;
    const n = (f.len - 4) / 2;
    return .{
        .kind = .filter_offset,
        .filter_offset = be16(f[2..4]),
        .filter_value = f[4..][0..n],
        .filter_mask = f[4 + n ..][0..n],
    };
}

/// Figure 9-278（p.912）：Type(1) Mask(1) PCP/UP(1) DEI(1) VID(2) = 6；位图 3–7 不指向任何
/// 参数；各参数的保留位（PCP 高 4 位、DEI 高 7 位、VID 高 4 位）必须为 0。
fn parseDot1(f: []const u8) Error!Classifier {
    if (f.len != 6) return error.BadLength;
    if (f[1] & 0xF8 != 0) return error.ReservedField;
    if (f[2] & 0xF0 != 0 or f[3] & 0xFE != 0 or be16(f[4..6]) & 0xF000 != 0) return error.ReservedValue;
    return .{
        .kind = .dot1d_q,
        .mask = f[1],
        .dot1_pcp = f[2] & 0x0F,
        .dot1_dei = f[3] & 0x01,
        .dot1_vid = be16(f[4..6]) & 0x0FFF,
    };
}

/// Table 9-147（p.909）：控制子字段 0–8 依次是 FC、Duration/ID、A1、A2、A3、SC、A4、QoS
/// Control、HT Control；Table 9-146（p.908）：0 不比较、1 比较（规格 = 字段长度）、2 保留、
/// 3 比较并带 Filter Mask（规格 = 2 × 字段长度）。
pub const mac_field_count = 9;
pub const mac_field_len = [mac_field_count]usize{ 2, 2, 6, 6, 6, 2, 6, 2, 4 };

/// 每个控制子字段的规格长度（0 = 不比较）；控制值 2 是保留值。
fn macSpecLens(mask: []const u8, lens: *[mac_field_count]usize) error{ReservedValue}!usize {
    var total: usize = 0;
    for (0..mac_field_count) |i| {
        const byte = mask[i / 4];
        const shift: u3 = @intCast(2 * (i % 4));
        const ctrl: u2 = @truncate((byte >> shift) & 0x03);
        if (ctrl == 2) return error.ReservedValue;
        lens[i] = if (ctrl == 0) 0 else if (ctrl == 1) mac_field_len[i] else 2 * mac_field_len[i];
        total += lens[i];
    }
    return total;
}

fn parseMacHeader(f: []const u8) Error!Classifier {
    if (f.len < 5) return error.Truncated; // Type(1) Mask(3) + 至少一段规格
    var lens: [mac_field_count]usize = undefined;
    const total = try macSpecLens(f[1..4], &lens);
    if (f.len != 4 + total) return error.BadLength;
    return .{ .kind = .mac_header, .mac_mask = f[1..4].*, .mac_specs = f[4..] };
}

pub fn buildTclasElement(out: []u8, t: Tclas) BuildError!usize {
    if (t.user_priority >= 12 and t.user_priority != 255) return error.ReservedValue;
    var body: [255]u8 = undefined;
    const n = try buildClassifier(&body, &t.classifier);
    const total = 2 + 1 + n;
    if (out.len < total) return error.NoRoom;
    out[0] = tclas_element_id;
    out[1] = @intCast(1 + n);
    out[2] = t.user_priority;
    @memcpy(out[3..][0..n], body[0..n]);
    return total;
}

fn buildClassifier(out: []u8, c: *const Classifier) BuildError!usize {
    switch (c.kind) {
        .ethernet => {
            if (out.len < 16) return error.NoRoom;
            out[0] = 0;
            out[1] = c.mask & 0x07;
            @memcpy(out[2..8], &c.eth_sa);
            @memcpy(out[8..14], &c.eth_da);
            wbe16(out[14..16], c.eth_type);
            return 16;
        },
        .tcp_udp_ip, .ip_and_higher => {
            if (c.ip_version == 4) {
                if (out.len < 18) return error.NoRoom;
                out[0] = @backingInt(c.kind);
                out[1] = c.mask & 0x7F;
                if (c.kind == .ip_and_higher) out[1] |= 0x01; // Version 位必须为 1
                out[2] = 4;
                @memcpy(out[3..7], c.ip_src[0..4]);
                @memcpy(out[7..11], c.ip_dst[0..4]);
                wbe16(out[11..13], c.sport);
                wbe16(out[13..15], c.dport);
                out[15] = c.dscp;
                out[16] = c.protocol;
                out[17] = 0; // 保留八位组
                return 18;
            }
            const n: usize = if (c.kind == .tcp_udp_ip) 42 else 44;
            if (out.len < n) return error.NoRoom;
            out[0] = @backingInt(c.kind);
            out[1] = if (c.kind == .tcp_udp_ip) c.mask & 0x3F else c.mask | 0x01;
            out[2] = 6;
            @memcpy(out[3..19], &c.ip_src);
            @memcpy(out[19..35], &c.ip_dst);
            wbe16(out[35..37], c.sport);
            wbe16(out[37..39], c.dport);
            var pos: usize = 39;
            if (c.kind == .ip_and_higher) {
                out[pos] = c.dscp;
                out[pos + 1] = c.protocol;
                pos += 2;
            }
            @memcpy(out[pos..][0..3], &c.flow);
            return n;
        },
        .vlan => {
            if (out.len < 4) return error.NoRoom;
            out[0] = 2;
            out[1] = 0;
            wbe16(out[2..4], c.vlan_tci);
            return 4;
        },
        .filter_offset => {
            const n = c.filter_value.len;
            if (n == 0 or c.filter_mask.len != n) return error.BadLength;
            const total = 4 + 2 * n;
            if (out.len < total) return error.NoRoom;
            out[0] = 3;
            out[1] = 0;
            wbe16(out[2..4], c.filter_offset);
            @memcpy(out[4..][0..n], c.filter_value);
            @memcpy(out[4 + n ..][0..n], c.filter_mask);
            return total;
        },
        .dot1d_q => {
            if (out.len < 6) return error.NoRoom;
            out[0] = 5;
            out[1] = c.mask & 0x07;
            out[2] = c.dot1_pcp & 0x0F;
            out[3] = c.dot1_dei & 0x01;
            wbe16(out[4..6], c.dot1_vid & 0x0FFF);
            return 6;
        },
        .mac_header => {
            var lens: [mac_field_count]usize = undefined;
            const total = try macSpecLens(&c.mac_mask, &lens);
            if (c.mac_specs.len != total) return error.BadLength;
            if (out.len < 4 + total) return error.NoRoom;
            out[0] = 6;
            @memcpy(out[1..4], &c.mac_mask);
            @memcpy(out[4..][0..total], c.mac_specs);
            return 4 + total;
        },
        _ => return error.ReservedValue,
    }
}

/// Figure 9-290（p.915）：Element ID(1) Length(1)=1 Processing(1)。
pub fn parseTclasProcessing(body: []const u8) Error!TclasProcessing {
    if (body.len != 1) return error.BadLength;
    if (body[0] > 2) return error.ReservedValue; // Table 9-149：3–255 保留
    return @fromBackingInt(body[0]);
}

pub fn buildTclasProcessingElement(out: []u8, p: TclasProcessing) BuildError!usize {
    if (@backingInt(p) > 2) return error.ReservedValue;
    if (out.len < 3) return error.NoRoom;
    out[0] = tclas_processing_element_id;
    out[1] = 1;
    out[2] = @backingInt(p);
    return 3;
}

// ---------------------------------------------------------------------------
// 11) TFS：TFS Request / Response 元素（9.4.2.80 / 9.4.2.81；Figure 9-418–9-423；
//     Table 9-198 / 9-200 / 9-201 / 9-202）
// ---------------------------------------------------------------------------

/// Figure 9-419（p.1003）：一条 TFS 子元素 = 一个 TFS Request 子元素（ID 1），装 1..n 个
/// TCLAS 元素 + 可选 TCLAS Processing（多于一个 TCLAS 时必须存在）。
pub const max_tclas_per_sub = 4;

pub const TfsSubelement = struct {
    tclas: [max_tclas_per_sub]Tclas,
    tclas_count: u8,
    processing: ?TclasProcessing = null,

    pub fn tclasSlice(self: *const TfsSubelement) []const Tclas {
        return self.tclas[0..self.tclas_count];
    }
};

/// 解析 TFS 子元素体（Subelement ID / Length 之后）：TCLAS 元素 + 可选 TCLAS Processing。
pub fn parseTfsSubelement(body: []const u8) Error!TfsSubelement {
    var r = TfsSubelement{ .tclas = undefined, .tclas_count = 0 };
    var w = ie.Walker.init(body);
    while (w.next() catch return error.Truncated) |el| {
        switch (el.id) {
            tclas_element_id => {
                if (r.tclas_count == max_tclas_per_sub) return error.TooMany;
                r.tclas[r.tclas_count] = try parseTclasElement(el.body);
                r.tclas_count += 1;
            },
            tclas_processing_element_id => {
                if (r.processing != null) return error.BadValue; // 至多一个
                r.processing = try parseTclasProcessing(el.body);
            },
            else => return error.UnexpectedElement,
        }
    }
    // 「The TCLAS Elements field contains one or more TCLAS elements」（Figure 9-419）。
    if (r.tclas_count == 0) return error.Empty;
    // 「The TCLAS Processing element shall be present if more than one TCLAS element is
    // included in the TFS subelement」（11.24.12.1）。
    if (r.tclas_count > 1 and r.processing == null) return error.MissingElement;
    // match_rest 要求「no associated TCLAS elements」，与 TFS 子元素的 1..n 矛盾。
    if (r.processing != null and r.processing.? == .match_rest) return error.BadValue;
    return r;
}

/// 构造 TFS 子元素：`tclas_elements` 是已编码的 TCLAS 元素串（含 Element ID / Length）。
pub fn buildTfsSubelement(out: []u8, tclas_elements: []const []const u8, processing: ?TclasProcessing) BuildError!usize {
    if (tclas_elements.len == 0) return error.Empty;
    if (tclas_elements.len > 1 and processing == null) return error.MissingElement;
    if (processing) |p| {
        if (@backingInt(p) > 2) return error.ReservedValue;
        if (p == .match_rest) return error.BadValue;
    }
    var body_len: usize = 2;
    for (tclas_elements) |e| {
        if (e.len < 2 or e[0] != tclas_element_id) return error.UnexpectedElement;
        body_len += e.len;
    }
    if (processing != null) body_len += 3;
    if (body_len - 2 > 255 or out.len < body_len) return error.NoRoom;
    out[0] = 1; // Table 9-201：TFS 子元素
    out[1] = @intCast(body_len - 2);
    var pos: usize = 2;
    for (tclas_elements) |e| {
        @memcpy(out[pos..][0..e.len], e);
        pos += e.len;
    }
    if (processing) |p| _ = try buildTclasProcessingElement(out[pos..], p);
    return body_len;
}

/// Figure 9-418（p.1002）：Element ID(1) Length(1) TFS ID(1) TFS Action Code(1) 子元素串。
/// Table 9-200（p.1002）：位 0 Delete After Match（任一规则集置 1 → 匹配后删全部规则集）、
/// 位 1 Notify（首个匹配帧或收到 Notify Response 后的首个匹配帧发一帧 TFS Notify）、位 2–7 保留。
pub const TfsActionCode = packed struct(u8) {
    delete_after_match: bool = false,
    notify: bool = false,
    reserved: u6 = 0,

    pub fn word(self: TfsActionCode) u8 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u8) TfsActionCode {
        return .{ .delete_after_match = w & 0x01 != 0, .notify = w & 0x02 != 0 };
    }
};

pub const TfsRequestElement = struct {
    tfs_id: u8,
    action: TfsActionCode,
    /// Figure 9-418 的 TFS Request Subelements 原串（含子元素头）；指向输入缓冲。
    subelements: []const u8,
};

/// 数子元素个数（Table 9-201：ID 1 与 221 之外保留）。
pub fn countTfsSubelements(bytes: []const u8) Error!usize {
    var n: usize = 0;
    var w = rrm.SubWalker.init(bytes);
    while (try w.next()) |s| {
        if (s.id != 1 and s.id != 221) return error.ReservedValue;
        n += 1;
    }
    return n;
}

/// 解析 TFS Request 元素体（Element ID / Length 之后）；至少一个子元素。
pub fn parseTfsRequestElement(body: []const u8) Error!TfsRequestElement {
    if (body.len < 2) return error.Truncated;
    // 「The TFS Request Subelements field contains one or more TFS Request subelements」。
    if (try countTfsSubelements(body[2..]) == 0) return error.Empty;
    var w = rrm.SubWalker.init(body[2..]);
    while (try w.next()) |s| {
        switch (s.id) {
            1 => _ = try parseTfsSubelement(s.body),
            221 => {}, // Figure 9-420：内容不解释
            else => return error.ReservedValue,
        }
    }
    return .{ .tfs_id = body[0], .action = TfsActionCode.fromWord(body[1]), .subelements = body[2..] };
}

pub const TfsRequestElementParams = struct {
    tfs_id: u8,
    action: TfsActionCode = .{},
    /// 已编码的子元素串（Figure 9-419 / 9-420 布局，含子元素头）。
    subelements: []const []const u8,
};

pub fn buildTfsRequestElement(out: []u8, p: TfsRequestElementParams) BuildError!usize {
    if (p.subelements.len == 0) return error.Empty;
    var body_len: usize = 2;
    for (p.subelements) |s| {
        if (s.len < 2) return error.BadLength;
        if (s[0] != 1 and s[0] != 221) return error.ReservedValue; // Table 9-201
        body_len += s.len;
    }
    if (body_len > 255 or out.len < body_len + 2) return error.NoRoom;
    out[0] = tfs_request_element_id;
    out[1] = @intCast(body_len);
    out[2] = p.tfs_id;
    out[3] = p.action.word();
    var pos: usize = 4;
    for (p.subelements) |s| {
        @memcpy(out[pos..][0..s.len], s);
        pos += s.len;
    }
    return body_len + 2;
}

/// Table 9-198（p.999）：TFS Response Status；15–255 保留。
pub const TfsResponseStatus = struct {
    pub const accept: u8 = 0;
    pub const deny_format: u8 = 1;
    pub const deny_resources: u8 = 2;
    pub const deny_ambiguous_streams: u8 = 3;
    pub const deny_policy: u8 = 4;
    pub const deny_unspecified: u8 = 5;
    pub const alternate_existing_interval: u8 = 6;
    pub const alternate_policy_limits: u8 = 7;
    pub const alternate_changed_interval: u8 = 8;
    pub const multicast_rate_not_allowed: u8 = 9;
    pub const terminate_policy: u8 = 10;
    pub const terminate_resources: u8 = 11;
    pub const terminate_higher_priority: u8 = 12;
    pub const alternate_changed_max_interval: u8 = 13;
    pub const alternate_classifier_unavailable: u8 = 14;

    pub fn name(code: u8) ?[]const u8 {
        return switch (code) {
            0 => "Accept",
            1 => "Deny, due to request format error or ambiguous classifier",
            2 => "Deny, due to lack of resources on the AP",
            3 => "Deny, due to requested classifier(s) matching 2 or more existing streams on different intervals",
            4 => "Deny, by policy",
            5 => "Deny, reason unspecified",
            6 => "Alternate proposed, due to existing stream with different delivery interval",
            7 => "Alternate proposed, due to policy limits on the AP",
            8 => "Alternate proposed, because the AP changed the delivery interval",
            9 => "Multicast rate changes not allowed",
            10 => "Terminate, due to an AP policy change",
            11 => "Terminate, due to lack of resources of the AP",
            12 => "Terminate, due to other FMS stream with higher priority",
            13 => "Alternate proposed, because the AP changed the maximum delivery interval",
            14 => "Alternate proposed, because the AP is unable to provide requested TCLAS-based classifiers",
            else => null,
        };
    }
};

/// Figure 9-422（p.1005）：TFS Status 子元素 = [1, Length, Status, 备选 TFS Request 子元素串]。
pub const TfsStatusSubelementParams = struct {
    status: u8,
    /// 备选参数（「one or more TFS Request subelements」），已编码；没有备选时为空。
    alternative: []const u8 = &.{},
};

pub fn buildTfsStatusSubelement(out: []u8, p: TfsStatusSubelementParams) BuildError!usize {
    if (p.status > TfsResponseStatus.alternate_classifier_unavailable) return error.ReservedValue;
    const total = 3 + p.alternative.len;
    if (total - 2 > 255 or out.len < total) return error.NoRoom;
    out[0] = 1; // Table 9-202：TFS Status 子元素
    out[1] = @intCast(total - 2);
    out[2] = p.status;
    @memcpy(out[3..][0..p.alternative.len], p.alternative);
    return total;
}

/// Figure 9-421（p.1004）：Element ID(1) Length(1) TFS ID(1) 子元素串。
pub const TfsResponseElement = struct {
    tfs_id: u8,
    /// Figure 9-421 的 TFS Response Subelements 原串；指向输入缓冲。
    subelements: []const u8,
};

/// 解析 TFS Status 子元素体：Status(1) + 可选备选参数（按 Table 9-201 校验）。
pub fn parseTfsStatusSubelement(body: []const u8) Error!u8 {
    if (body.len < 1) return error.Truncated;
    if (body[0] > TfsResponseStatus.alternate_classifier_unavailable) return error.ReservedValue;
    if (body.len > 1) {
        var w = rrm.SubWalker.init(body[1..]);
        while (try w.next()) |t| {
            if (t.id != 1 and t.id != 221) return error.ReservedValue;
            if (t.id == 1) _ = try parseTfsSubelement(t.body);
        }
    }
    return body[0];
}

/// 解析 TFS Response 元素体（Element ID / Length 之后）；至少一个子元素。
pub fn parseTfsResponseElement(body: []const u8) Error!TfsResponseElement {
    if (body.len < 1) return error.Truncated;
    // 「The TFS Response Subelements field contains one or more TFS Response subelements」。
    if (try countTfsSubelements(body[1..]) == 0) return error.Empty;
    var w = rrm.SubWalker.init(body[1..]);
    while (try w.next()) |s| {
        switch (s.id) {
            1 => _ = try parseTfsStatusSubelement(s.body),
            221 => {},
            else => return error.ReservedValue, // Table 9-202：其余 ID 保留
        }
    }
    return .{ .tfs_id = body[0], .subelements = body[1..] };
}

pub const TfsResponseElementParams = struct {
    tfs_id: u8,
    /// 已编码的子元素串（Figure 9-422 / 9-423 布局，含子元素头）。
    subelements: []const []const u8,
};

pub fn buildTfsResponseElement(out: []u8, p: TfsResponseElementParams) BuildError!usize {
    if (p.subelements.len == 0) return error.Empty;
    var body_len: usize = 1;
    for (p.subelements) |s| {
        if (s.len < 2) return error.BadLength;
        if (s[0] != 1 and s[0] != 221) return error.ReservedValue;
        body_len += s.len;
    }
    if (body_len > 255 or out.len < body_len + 2) return error.NoRoom;
    out[0] = tfs_response_element_id;
    out[1] = @intCast(body_len);
    out[2] = p.tfs_id;
    var pos: usize = 3;
    for (p.subelements) |s| {
        @memcpy(out[pos..][0..s.len], s);
        pos += s.len;
    }
    return body_len + 2;
}

// ---------------------------------------------------------------------------
// 12) TFS：动作帧（9.6.14.15–9.6.14.18；Figure 9-711–9-714）与匹配模型
// ---------------------------------------------------------------------------

/// Extended Capabilities 元素体里的 TFS 位 = 16（Table 9-135，p.893：dot11TFSActivated）；
/// 位 16 → 第 16/8 = 2 字节的位 0。
pub fn tfsSupported(ext_capabilities_body: []const u8) bool {
    return ext_capabilities_body.len > 2 and (ext_capabilities_body[2] & 0x01) != 0;
}

pub const TfsRequestFrame = struct {
    /// 「nonzero」（9.4.1.12）；请求 / 响应事务的标识。
    dialog_token: u8,
    /// TFS Request 元素串（指向输入缓冲）；0 个元素 = 撤销全部过滤（11.24.12.2）。
    elements: []const u8,
};

/// Figure 9-711（p.1236）：Category、WNM Action(=13)、Dialog Token、元素串。
pub fn parseTfsRequestFrame(body: []const u8) Error!TfsRequestFrame {
    if (body.len < 3) return error.Truncated;
    try checkHeader(body, .tfs_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    var w = ie.Walker.init(body[3..]);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != tfs_request_element_id) return error.UnexpectedElement;
        _ = try parseTfsRequestElement(el.body);
    }
    return .{ .dialog_token = body[2], .elements = body[3..] };
}

pub const TfsFrameParams = struct {
    dialog_token: u8,
    /// 已编码的元素串。
    elements: []const u8 = &.{},
};

pub fn buildTfsRequestFrame(out: []u8, p: TfsFrameParams) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    var w = ie.Walker.init(p.elements);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != tfs_request_element_id) return error.UnexpectedElement;
        // 元素体坏 → BadValue（Error 集里解析专用理由不外泄）。
        if (parseTfsRequestElement(el.body)) |_| {} else |_| return error.BadValue;
    }
    const total = 3 + p.elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.tfs_request);
    out[2] = p.dialog_token;
    @memcpy(out[3..][0..p.elements.len], p.elements);
    return total;
}

pub const TfsResponseFrame = struct {
    /// 回显对应 Request 的 Dialog Token。
    dialog_token: u8,
    elements: []const u8,
};

/// Figure 9-712（p.1236）：Category、WNM Action(=14)、Dialog Token、元素串。元素数为 0 只在
/// 对应 Request 也为 0 个元素（撤销全部）时成立（9.6.14.16 的数量对应规则）。
pub fn parseTfsResponseFrame(body: []const u8) Error!TfsResponseFrame {
    if (body.len < 3) return error.Truncated;
    try checkHeader(body, .tfs_response);
    if (body[2] == 0) return error.ZeroDialogToken;
    var w = ie.Walker.init(body[3..]);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != tfs_response_element_id) return error.UnexpectedElement;
        _ = try parseTfsResponseElement(el.body);
    }
    return .{ .dialog_token = body[2], .elements = body[3..] };
}

pub fn buildTfsResponseFrame(out: []u8, p: TfsFrameParams) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    var w = ie.Walker.init(p.elements);
    while (w.next() catch return error.Truncated) |el| {
        if (el.id != tfs_response_element_id) return error.UnexpectedElement;
        if (parseTfsResponseElement(el.body)) |_| {} else |_| return error.BadValue;
    }
    const total = 3 + p.elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.tfs_response);
    out[2] = p.dialog_token;
    @memcpy(out[3..][0..p.elements.len], p.elements);
    return total;
}

/// Figure 9-713 / 9-714（p.1237）：Category、WNM Action(=15)、Number of TFS IDs(1)、TFS ID
/// List；两个方向的帧格式相同（TFS Notify 由 AP 发，TFS Notify Response 由 STA 发）。
pub const TfsNotify = struct {
    /// 1 字节的 TFS ID 列表；长度必须与 Number of TFS IDs 一致。
    ids: []const u8,
};

pub fn parseTfsNotify(body: []const u8) Error!TfsNotify {
    try checkHeader(body, .tfs_notify);
    if (body.len < 3) return error.Truncated;
    if (body[2] != body.len - 3) return error.BadLength;
    return .{ .ids = body[3..] };
}

pub fn buildTfsNotify(out: []u8, ids: []const u8) BuildError!usize {
    if (ids.len > 255 or out.len < ids.len + 3) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.tfs_notify);
    out[2] = @intCast(ids.len);
    @memcpy(out[3..][0..ids.len], ids);
    return ids.len + 3;
}

/// 9.4.2.80 / 9.4.2.81：Response 的元素数、每个元素里的子元素数都要与 Request 一致、顺序一致。
/// 配对成功把每元素的首个 Status 写进 `out_statuses`（元素里的全部子元素共用同一状态），返回
/// 元素个数；对不上返回 error.BadValue。
pub fn pairTfsResponse(req_elements: []const u8, resp_elements: []const u8, out_statuses: []u8) Error!usize {
    var n: usize = 0;
    var rw = ie.Walker.init(req_elements);
    var pw = ie.Walker.init(resp_elements);
    while (true) {
        const r = rw.next() catch return error.Truncated;
        const p = pw.next() catch return error.Truncated;
        if (r == null and p == null) break;
        if (r == null or p == null) return error.BadValue;
        if (r.?.id != tfs_request_element_id or p.?.id != tfs_response_element_id) return error.UnexpectedElement;
        const req = try parseTfsRequestElement(r.?.body);
        const resp = try parseTfsResponseElement(p.?.body);
        if (req.tfs_id != resp.tfs_id) return error.BadValue;
        const req_subs = try countTfsSubelements(req.subelements);
        const resp_subs = try countTfsSubelements(resp.subelements);
        if (req_subs != resp_subs) return error.BadValue;
        if (n == out_statuses.len) return error.TooMany;
        var first: ?u8 = null;
        var sw = rrm.SubWalker.init(resp.subelements);
        while (try sw.next()) |s| {
            if (s.id != 1) continue;
            const status = try parseTfsStatusSubelement(s.body);
            if (first == null or status != first.?) first = status;
        }
        out_statuses[n] = first orelse return error.Empty;
        n += 1;
    }
    return n;
}

/// 被分类的帧（调用方从收到的 MSDU / MMPDU 填）。某个域没填时，需要它的分类器一律不匹配。
pub const MatchInput = struct {
    /// MSDU 的 User Priority；无 QoS 时 null。
    up: ?u8 = null,
    /// MPDU 的 AC（Table 9-144：0 = AC_VO、1 = AC_VI、2 = AC_BE、3 = AC_BK）。
    ac: ?u8 = null,
    /// 11.24.12.3 的隐式规则集：单独寻址的 EAPOL-Key 帧总是交付。
    eapol_key: bool = false,
    eth: ?EthHeader = null,
    ipv4: ?Ip4Header = null,
    ipv6: ?Ip6Header = null,
    vlan_tci: ?u16 = null,
    dot1: ?Dot1Header = null,
    /// 类型 3 比较的 MSDU / MMPDU 内容。
    content: []const u8 = &.{},
    /// 类型 6 比较的 MAC 头原始字节（FC 起）。
    mac_header: []const u8 = &.{},
    /// 头里有第 4 个地址（A4 在 SC 之后）。
    mac_four_addr: bool = false,
    /// 头里有 QoS Control。
    mac_qos: bool = false,
    /// 头里有 HT Control。
    mac_ht: bool = false,
};

pub const EthHeader = struct {
    sa: [6]u8,
    da: [6]u8,
    ethertype: u16,
};

pub const Ip4Header = struct {
    src: [4]u8,
    dst: [4]u8,
    sport: u16,
    dport: u16,
    dscp: u8,
    protocol: u8,
};

pub const Ip6Header = struct {
    src: [16]u8,
    dst: [16]u8,
    sport: u16,
    dport: u16,
    dscp: u8,
    next_header: u8,
    flow: [3]u8,
};

pub const Dot1Header = struct {
    pcp: u8,
    dei: bool,
    vid: u16,
    /// false = 802.1D 帧（DEI / VID 被忽略）；true = 802.1Q 帧。
    is_1q: bool,
};

/// Table 9-144：UP 0–7 比 MSDU UP、8–11 比 AC、255 不比较。
fn upMatches(field: u8, in: *const MatchInput) bool {
    if (field == 255) return true;
    if (field <= 7) return in.up != null and in.up.? == field;
    return in.ac != null and in.ac.? == field - 8;
}

fn maskBit(mask: u8, i: u3) bool {
    return (mask >> i) & 0x01 != 0;
}

/// 一个分类器对一帧的判定：位图置 1 的参数都要相等；DSCP 比较低 6 位、Flow Label 比较低
/// 20 位（其余位「ignored for frame classification」）。
pub fn classifierMatches(c: *const Classifier, in: *const MatchInput) bool {
    switch (c.kind) {
        .ethernet => {
            const e = in.eth orelse return false;
            if (maskBit(c.mask, 0) and !std.mem.eql(u8, &c.eth_sa, &e.sa)) return false;
            if (maskBit(c.mask, 1) and !std.mem.eql(u8, &c.eth_da, &e.da)) return false;
            if (maskBit(c.mask, 2) and c.eth_type != e.ethertype) return false;
            return true;
        },
        .tcp_udp_ip, .ip_and_higher => {
            const n: usize = c.ip_addr_len;
            if (c.ip_version == 4) {
                const f = in.ipv4 orelse return false;
                // 位 0 是 Version：走到这里帧已是 IPv4，恒等。
                if (maskBit(c.mask, 1) and !std.mem.eql(u8, c.ip_src[0..n], &f.src)) return false;
                if (maskBit(c.mask, 2) and !std.mem.eql(u8, c.ip_dst[0..n], &f.dst)) return false;
                if (maskBit(c.mask, 3) and c.sport != f.sport) return false;
                if (maskBit(c.mask, 4) and c.dport != f.dport) return false;
                if (maskBit(c.mask, 5) and c.dscp & 0x3F != f.dscp & 0x3F) return false;
                if (maskBit(c.mask, 6) and c.protocol != f.protocol) return false;
                return true;
            }
            const f = in.ipv6 orelse return false;
            // 位 0 是 Version：走到这里帧已是 IPv6，恒等。
            if (maskBit(c.mask, 1) and !std.mem.eql(u8, &c.ip_src, &f.src)) return false;
            if (maskBit(c.mask, 2) and !std.mem.eql(u8, &c.ip_dst, &f.dst)) return false;
            if (maskBit(c.mask, 3) and c.sport != f.sport) return false;
            if (maskBit(c.mask, 4) and c.dport != f.dport) return false;
            if (c.kind == .ip_and_higher) {
                if (maskBit(c.mask, 5) and c.dscp & 0x3F != f.dscp & 0x3F) return false;
                if (maskBit(c.mask, 6) and c.protocol != f.next_header) return false;
            }
            if (maskBit(c.mask, 7) or (c.kind == .tcp_udp_ip and maskBit(c.mask, 5))) {
                const want = c.flow;
                if (want[0] & 0x0F != f.flow[0] & 0x0F) return false;
                if (!std.mem.eql(u8, want[1..3], f.flow[1..3])) return false;
            }
            return true;
        },
        .vlan => {
            const t = in.vlan_tci orelse return false;
            return c.vlan_tci == t;
        },
        .filter_offset => {
            const off: usize = c.filter_offset;
            const n = c.filter_value.len;
            if (in.content.len < off + n) return false;
            for (0..n) |i| {
                const m = c.filter_mask[i];
                if (in.content[off + i] & m != c.filter_value[i] & m) return false;
            }
            return true;
        },
        .dot1d_q => {
            const h = in.dot1 orelse return false;
            if (maskBit(c.mask, 0) and c.dot1_pcp != h.pcp) return false;
            if (h.is_1q) {
                if (maskBit(c.mask, 1) and @intFromBool(h.dei) != c.dot1_dei) return false;
                if (maskBit(c.mask, 2) and c.dot1_vid != h.vid) return false;
            }
            // 802.1D 帧：DEI / VID 被忽略（9.4.2.31）。
            return true;
        },
        .mac_header => return macHeaderMatches(c, in),
        _ => return false,
    }
}

/// 类型 6：逐控制子字段比较 MAC 头字段。Table 9-147 的字段位置：FC@0、Duration@2、A1@4、
/// A2@10、A3@16、SC@22、A4@24（仅 4 地址）、QoS 在其后、HT 再其后。
fn macHeaderMatches(c: *const Classifier, in: *const MatchInput) bool {
    const hdr = in.mac_header;
    const a4_off: usize = 24;
    const qos_off: usize = if (in.mac_four_addr) 30 else 24;
    const ht_off: usize = qos_off + 2;
    var spec: usize = 0;
    var i: usize = 0;
    while (i < mac_field_count) : (i += 1) {
        const shift: u3 = @intCast(2 * (i % 4));
        const ctrl: u2 = @truncate((c.mac_mask[i / 4] >> shift) & 0x03);
        const flen = mac_field_len[i];
        if (ctrl == 0) continue;
        const available = switch (i) {
            6 => in.mac_four_addr,
            7 => in.mac_qos,
            8 => in.mac_ht,
            else => hdr.len >= fieldOffset(i, a4_off, qos_off, ht_off) + flen,
        };
        if (!available) return false;
        const off = fieldOffset(i, a4_off, qos_off, ht_off);
        const field = hdr[off..][0..flen];
        const w = c.mac_specs[spec..][0..flen];
        if (ctrl == 1) {
            if (!std.mem.eql(u8, w, field)) return false;
        } else {
            const fm = c.mac_specs[spec + flen ..][0..flen];
            for (0..flen) |k| {
                if (w[k] & fm[k] != field[k] & fm[k]) return false;
            }
        }
        spec += if (ctrl == 1) flen else 2 * flen;
    }
    return true;
}

fn fieldOffset(i: usize, a4: usize, qos: usize, ht: usize) usize {
    return switch (i) {
        0 => 0,
        1 => 2,
        2 => 4,
        3 => 10,
        4 => 16,
        5 => 22,
        6 => a4,
        7 => qos,
        else => ht,
    };
}

/// 一个 TCLAS 元素的判定：UP（Table 9-144）与分类器都要满足。
pub fn tclasMatches(t: *const Tclas, in: *const MatchInput) bool {
    return upMatches(t.user_priority, in) and classifierMatches(&t.classifier, in);
}

/// 一个 TFS 子元素（一条过滤规则）的判定：多个 TCLAS 按 TCLAS Processing 的 ALL / ANY。
pub fn tfsSubelementMatches(s: *const TfsSubelement, in: *const MatchInput) bool {
    if (s.tclas_count == 1) return tclasMatches(&s.tclas[0], in);
    const any = s.processing orelse .match_any;
    if (any == .match_all) {
        for (s.tclasSlice()) |*t| {
            if (!tclasMatches(t, in)) return false;
        }
        return true;
    }
    for (s.tclasSlice()) |*t| {
        if (tclasMatches(t, in)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 13) TFS：STA 侧（11.24.12.2）与 AP 侧（11.24.12.3）模型
// ---------------------------------------------------------------------------

pub const max_tfs_ap_stas = 8;
/// 每 STA 存下的规则集（TFS Request 元素）上限。
pub const max_filter_sets = 4;
/// 一帧请求里评估的元素数上限。
pub const max_tfs_elements_per_frame = 16;

/// AP 存下的一条过滤规则集 = 一个 TFS Request 元素（Table 9-200 的动作位 + 元素体串，指向
/// 调用方的请求帧缓冲）。
pub const FilterSet = struct {
    tfs_id: u8 = 0,
    delete_after_match: bool = false,
    notify: bool = false,
    /// Notify 位置 1 时武装；发出一帧 TFS Notify 后解除；收到带该 ID 的 Notify Response 再武装
    /// （Table 9-200 位 1、11.24.12.3）。
    notify_armed: bool = false,
    /// TFS Request 元素体（Element ID / Length 之后）。
    element: []const u8 = &.{},
};

pub const TfsApSta = struct {
    address: frame.Mac = @splat(0),
    /// 最近收到的 Extended Capabilities 里 TFS 位（Table 9-135 位 16）。
    supports_tfs: bool = false,
    agreement: bool = false,
    sets: [max_filter_sets]FilterSet = @splat(.{}),
    set_count: u8 = 0,

    pub const RequestOutcome = struct {
        /// 每个请求元素的 Status（顺序同请求；一个元素的全部子元素共用）。
        statuses: [max_tfs_elements_per_frame]u8 = @splat(0),
        count: u8 = 0,
        /// 全部 Accept：协议已建立 / 更新。
        established: bool = false,
        /// 写进 out 的 TFS Response 帧体长度。
        response_len: usize = 0,
    };

    /// 处理一帧 TFS Request（11.24.12.3）：`elements` 是帧体里 Dialog Token 之后的元素串
    /// （AP 路径有意宽松——帧必须逐元素回应而不是整体丢弃）。先评估全部元素（不改状态），
    /// 全部 Accept 才替换旧协议（「disregard any previous MLME-TFS.indication primitive」）；
    /// 空请求撤销全部。同时在 out 排出 TFS Response 帧体：每个请求元素一个元素、每个请求
    /// 子元素一个 Status 子元素（数量与顺序按 9.6.14.16 / 9.4.2.80）。元素体格式错 / 分类器
    /// 含糊 → Status 1；规则集槽满 → Status 2；元素头被截断 → 这一条按格式错回 1 后停止。
    /// STA 侧的严格解析在 `parseTfsRequestFrame`。
    pub fn onRequest(sta: *TfsApSta, dialog_token: u8, elements: []const u8, out: []u8) BuildError!RequestOutcome {
        var res = RequestOutcome{};
        const Eval = struct { tfs_id: u8, subs: usize, body: []const u8, action: TfsActionCode };
        var evals: [max_tfs_elements_per_frame]Eval = undefined;
        var installs: usize = 0;
        var rest = elements;
        while (rest.len != 0) {
            if (res.count == max_tfs_elements_per_frame) return error.TooMany;
            if (rest.len < 2 or rest.len - 2 < rest[1]) {
                // 元素头不完整 / 长度越界：这一条（TFS ID 取得到的就回显）按格式错回 1。
                evals[res.count] = .{ .tfs_id = rest[0], .subs = 0, .body = &.{}, .action = .{} };
                res.statuses[res.count] = TfsResponseStatus.deny_format;
                res.count += 1;
                break;
            }
            const el_id = rest[0];
            const el_len: usize = rest[1];
            const el_body = rest[2..][0..el_len];
            rest = rest[2 + el_len ..];
            if (parseTfsRequestElement(el_body)) |parsed| {
                if (el_id != tfs_request_element_id) {
                    // 9.6.14.15：TFS Request Elements 只有 TFS Request 元素；别的元素按格式错。
                    evals[res.count] = .{ .tfs_id = parsed.tfs_id, .subs = 0, .body = el_body, .action = .{} };
                    res.statuses[res.count] = TfsResponseStatus.deny_format;
                } else {
                    evals[res.count] = .{
                        .tfs_id = parsed.tfs_id,
                        .subs = countTfsSubelements(parsed.subelements) catch 0,
                        .body = el_body,
                        .action = parsed.action,
                    };
                    // 一个元素占一个规则集槽（旧集合在提交时被替换）；现有 + 新请求超槽 →
                    // 2（Table 9-198：lack of resources）。
                    res.statuses[res.count] = if (sta.set_count + installs >= max_filter_sets)
                        TfsResponseStatus.deny_resources
                    else
                        TfsResponseStatus.accept;
                    if (res.statuses[res.count] == TfsResponseStatus.accept) installs += 1;
                }
            } else |_| {
                // 解析不了的元素按一个子元素回状态；TFS ID 取不出来的写 0。
                evals[res.count] = .{
                    .tfs_id = if (el_body.len >= 1) el_body[0] else 0,
                    .subs = 0,
                    .body = el_body,
                    .action = .{},
                };
                res.statuses[res.count] = TfsResponseStatus.deny_format;
            }
            res.count += 1;
        }
        res.response_len = try buildTfsResponseFor(out, dialog_token, res.statuses[0..res.count], evals[0..res.count]);
        // 全部 Accept 才提交（11.24.12.2 / 11.24.12.3）。
        var all_accept = true;
        for (res.statuses[0..res.count]) |s| {
            if (s != TfsResponseStatus.accept) all_accept = false;
        }
        res.established = all_accept;
        if (all_accept) {
            sta.set_count = 0;
            for (evals[0..res.count]) |e| {
                sta.sets[sta.set_count] = .{
                    .tfs_id = e.tfs_id,
                    .delete_after_match = e.action.delete_after_match,
                    .notify = e.action.notify,
                    .notify_armed = e.action.notify,
                    .element = e.body,
                };
                sta.set_count += 1;
            }
            sta.agreement = res.count != 0;
        }
        return res;
    }

    /// 一帧是否交付给这个 STA（11.24.12.3）；组地址帧照常交付（11.24.12.1），但匹配仍用于
    /// Notify。隐式 EAPOL-Key 规则集：单独寻址的 EAPOL-Key 帧总是交付（动作位 0、无状态）。
    pub fn matchFrame(sta: *TfsApSta, in: *const MatchInput, group_addressed: bool) TfsMatchOutcome {
        var res = TfsMatchOutcome{};
        if (!sta.agreement) return res;
        if (in.eapol_key) {
            res.delivered = true;
            return res;
        }
        var matched_any = false;
        var delete_all = false;
        for (sta.sets[0..sta.set_count]) |*set| {
            if (!filterSetMatches(set, in)) continue;
            matched_any = true;
            if (set.notify and set.notify_armed and res.notify_count < max_filter_sets) {
                set.notify_armed = false;
                res.notify_ids[res.notify_count] = set.tfs_id;
                res.notify_count += 1;
                res.notify_generated = true;
            }
            if (set.delete_after_match) delete_all = true;
        }
        res.delivered = matched_any or group_addressed;
        if (delete_all) {
            // 「all traffic filter sets established at the AP for the non-AP STA are deleted when
            // a frame matches any of the traffic filter sets established for the non-AP STA」
            // （Table 9-200 位 0）。
            sta.set_count = 0;
            sta.agreement = false;
            res.filters_deleted = true;
        }
        return res;
    }

    /// 收到 TFS Notify Response（WNM Action 15，STA → AP）：给列出的 TFS ID 恢复 Notify 生成
    /// （11.24.12.3）。返回恢复的个数。
    pub fn onNotifyResponse(sta: *TfsApSta, ids: []const u8) usize {
        var n: usize = 0;
        for (ids) |id| {
            for (sta.sets[0..sta.set_count]) |*set| {
                if (set.tfs_id == id and set.notify and !set.notify_armed) {
                    set.notify_armed = true;
                    n += 1;
                }
            }
        }
        return n;
    }
};

pub const TfsMatchOutcome = struct {
    /// 是否交付：没有协议、匹配（含隐式 EAPOL-Key 规则）或组地址帧 → true；被过滤 → false。
    delivered: bool = true,
    /// 本次匹配生成了一帧 TFS Notify（每个武装的规则集只发一次）。
    notify_generated: bool = false,
    notify_ids: [max_filter_sets]u8 = @splat(0),
    notify_count: u8 = 0,
    /// Delete After Match 命中：全部规则集已删，协议结束（11.2.3.18.3 的主动退出由调用方接）。
    filters_deleted: bool = false,
};

fn filterSetMatches(set: *const FilterSet, in: *const MatchInput) bool {
    // 一个过滤规则集内的多条规则是 AND（11.24.12.1）；set.element 是元素体（TFS ID、
    // Action Code 之后是子元素串）。
    var w = rrm.SubWalker.init(set.element[2..]);
    while (w.next() catch return false) |s| {
        if (s.id != 1) continue; // Vendor Specific 不参与匹配
        const sub = parseTfsSubelement(s.body) catch return false;
        if (!tfsSubelementMatches(&sub, in)) return false;
    }
    return true;
}

/// 排出 TFS Response 帧体：每个请求元素一个 Response 元素，其下每个请求子元素一个 Status
/// 子元素（[1, 1, status]；元素里的全部子元素共用同一状态）。
fn buildTfsResponseFor(out: []u8, token: u8, statuses: []const u8, evals: anytype) BuildError!usize {
    if (out.len < 3) return error.NoRoom;
    var pos: usize = 3;
    for (evals, 0..) |e, i| {
        var n_subs = e.subs;
        if (n_subs == 0) n_subs = 1; // 解析失败的元素按一个子元素回状态
        const body_len = 1 + 3 * n_subs; // TFS ID(1) + 每子元素 3 字节
        if (body_len > 255) return error.TooLong;
        if (out.len - pos < body_len + 2) return error.NoRoom;
        out[pos] = tfs_response_element_id;
        out[pos + 1] = @intCast(body_len);
        out[pos + 2] = e.tfs_id;
        var j: usize = 0;
        while (j < n_subs) : (j += 1) {
            out[pos + 3 + 3 * j] = 1; // Table 9-202：TFS Status 子元素
            out[pos + 4 + 3 * j] = 1;
            out[pos + 5 + 3 * j] = statuses[i];
        }
        pos += body_len + 2;
    }
    out[0] = category;
    out[1] = @backingInt(Action.tfs_response);
    out[2] = token;
    return pos;
}

/// non-AP STA 侧的请求 / 响应记账（11.24.12.2）。
pub const TfsSta = struct {
    /// 最近一次全 Accept 的请求元素串（指向调用方缓冲）；协议生效的标志。
    agreement: bool = false,
    established_elements: []const u8 = &.{},
    pending_token: u8 = 0,
    pending_elements: []const u8 = &.{},

    /// 发出 TFS Request（9.6.14.15）：记下待配对的 token 与元素串。
    pub fn sendRequest(self: *TfsSta, token: u8, elements: []const u8) Error!void {
        if (token == 0) return error.ZeroDialogToken;
        self.pending_token = token;
        self.pending_elements = elements;
    }

    /// 处理 TFS Response：配对成功（token、元素数、顺序、TFS ID、子元素数）且全部 Accept →
    /// 协议生效；否则保持原协议（11.24.12.2）。返回是否（重新）建立。
    pub fn onResponse(self: *TfsSta, token: u8, elements: []const u8) Error!bool {
        if (token != self.pending_token) return false;
        var statuses: [max_tfs_elements_per_frame]u8 = undefined;
        const n = try pairTfsResponse(self.pending_elements, elements, &statuses);
        var all = true;
        for (statuses[0..n]) |s| {
            if (s != TfsResponseStatus.accept) all = false;
        }
        if (all) {
            self.agreement = true;
            self.established_elements = self.pending_elements;
        }
        return all;
    }

    /// TFS Notify 到了：把仍在本端协议里的 TFS ID 写进 out_ids（用于 Notify Response），返回个数。
    pub fn onNotify(self: *TfsSta, ids: []const u8, out_ids: []u8) usize {
        var n: usize = 0;
        for (ids) |id| {
            var keep = false;
            var w = ie.Walker.init(self.established_elements);
            while (w.next() catch break) |el| {
                if (el.id != tfs_request_element_id or el.body.len < 1) continue;
                if (el.body[0] == id) keep = true;
            }
            if (keep and n < out_ids.len) {
                out_ids[n] = id;
                n += 1;
            }
        }
        return n;
    }
};

// ---------------------------------------------------------------------------
// 14) WNM Sleep Mode Response 的 Key Data（9.6.14.20；Figure 9-717 / 9-718；
//     Table 9-358；Figure 9-319）
// ---------------------------------------------------------------------------

/// Table 9-358（p.1239）：0 = GTK、1 = IGTK、2–255 保留。
pub const gtk_subelement_id: u8 = 0;
pub const igtk_subelement_id: u8 = 1;

/// Figure 9-717（p.1239）：Subelement ID(1)=0 Length(1) Key Info(2) Key Length(1) RSC(8)
/// Key(5–32)；Length = 11 + Key Length。
pub const GtkKeyData = struct {
    /// Figure 9-319（p.935）：Key Info 的 B0–B1；B2–B15 保留（必须为 0）。
    key_id: u8,
    /// RSC 原样 8 字节（TSC / PN 的最低位八位组在最前；不足 8 字节由发送方补 0）。
    rsc: [8]u8,
    key: []const u8,
};

/// Figure 9-718（p.1239）：Subelement ID(1)=1 Length(1)=24 Key ID(2) PN(6) Key(16)。
pub const IgTkKeyData = struct {
    /// BIP key identifier；9.2.2 数值字段按 LSB 在前读。
    key_id: u16,
    pn: [6]u8,
    key: [16]u8,
};

pub const max_keydata_entries = 4;

pub const KeyDataEntry = union(enum) {
    gtk: GtkKeyData,
    igtk: IgTkKeyData,
};

/// 解析 Key Data 字段：零或多个 GTK / IGTK 子元素（NOTE 1：组重键进行中可有多条）；
/// 顺序按 9.4.3 非降序；保留 ID 拒绝。返回写入 `out` 的条数。
pub fn parseKeyData(data: []const u8, out: []KeyDataEntry) Error!usize {
    var n: usize = 0;
    var prev_id: u8 = 0;
    var first = true;
    var w = rrm.SubWalker.init(data);
    while (try w.next()) |s| {
        if (!first and s.id < prev_id) return error.BadValue;
        prev_id = s.id;
        first = false;
        const entry: KeyDataEntry = switch (s.id) {
            gtk_subelement_id => blk: {
                // body = Key Info(2) + Key Length(1) + RSC(8) + Key(key_len)，固定部分 11。
                if (s.body.len < 11) return error.BadLength;
                const key_len: usize = s.body[2];
                if (s.body.len != 11 + key_len) return error.BadLength;
                if (key_len < 5 or key_len > 32) return error.BadValue; // Figure 9-717：5–32
                const info = le16(s.body[0..2]);
                if (info & 0xFFFC != 0) return error.ReservedBitsSet; // Figure 9-319：B2–B15 保留
                break :blk .{ .gtk = .{ .key_id = @intCast(info & 0x03), .rsc = s.body[3..11].*, .key = s.body[11..] } };
            },
            igtk_subelement_id => blk: {
                if (s.body.len != 24) return error.BadLength;
                break :blk .{ .igtk = .{ .key_id = le16(s.body[0..2]), .pn = s.body[2..8].*, .key = s.body[8..24].* } };
            },
            else => return error.ReservedValue, // Table 9-358：2–255 保留
        };
        if (n == out.len) return error.TooMany;
        out[n] = entry;
        n += 1;
    }
    return n;
}

/// 构造 Key Data 字段（明文 KDE 串）。
pub fn buildKeyData(out: []u8, entries: []const KeyDataEntry) BuildError!usize {
    var pos: usize = 0;
    var prev_id: u8 = 0;
    for (entries, 0..) |e, i| {
        const id: u8 = if (e == .gtk) gtk_subelement_id else igtk_subelement_id;
        if (i != 0 and id < prev_id) return error.BadValue;
        prev_id = id;
        switch (e) {
            .gtk => |g| {
                if (g.key.len < 5 or g.key.len > 32) return error.BadLength;
                if (g.key_id > 3) return error.ReservedValue; // Figure 9-319：2 位
                const total: usize = 13 + g.key.len; // ID(1) + Length(1) + 11 + Key
                if (out.len - pos < total) return error.NoRoom;
                out[pos] = gtk_subelement_id;
                out[pos + 1] = @intCast(total - 2);
                w16(out[pos + 2 ..], g.key_id);
                out[pos + 4] = @intCast(g.key.len);
                @memcpy(out[pos + 5 ..][0..8], &g.rsc);
                @memcpy(out[pos + 13 ..][0..g.key.len], g.key);
                pos += total;
            },
            .igtk => |g| {
                if (out.len - pos < 26) return error.NoRoom;
                out[pos] = igtk_subelement_id;
                out[pos + 1] = 24;
                w16(out[pos + 2 ..], g.key_id);
                @memcpy(out[pos + 4 ..][0..6], &g.pn);
                @memcpy(out[pos + 10 ..][0..16], &g.key);
                pos += 26;
            },
        }
    }
    return pos;
}

/// 12.7.2 / 9.6.14.20 的 NOTE 2：Key Data 的机密性 / 完整性由管理帧保护（PMF）在帧级提供；
/// AKM 决定的密钥封装（例如组密钥握手的 AES Key Wrap）不在本组件里实现——经本接口由调用方
/// 注入。真实密钥封装的接线没有在本组件验证：protect / unprotect 必须由拥有 KEK / PMF 上下文
/// 的一方提供；组件测试只用测试替身。
pub const KeyDataCodec = struct {
    ctx: ?*anyopaque = null,
    /// 明文 Key Data → 受保护串；允许就地（out == plaintext），返回写入 out 的长度。
    protect: ?*const fn (ctx: ?*anyopaque, plaintext: []const u8, out: []u8) BuildError!usize = null,
    /// 受保护串 → 明文 Key Data；允许就地，返回明文长度。
    unprotect: ?*const fn (ctx: ?*anyopaque, protected: []const u8, out: []u8) Error!usize = null,
};

/// 排出带 GTK / IGTK 的 WNM Sleep Mode Response（Figure 9-716）：先在 `scratch` 里排明文
/// KDE，再经 codec（可选）保护后放进 Key Data；没有 protect 时 Key Data 保持明文（PMF 在
/// 帧级保护整帧）。Response 的其余字段沿用 `p`。
pub fn buildSleepResponseWithKeys(out: []u8, scratch: []u8, p: SleepResponseParams, entries: []const KeyDataEntry, codec: KeyDataCodec) BuildError!usize {
    const n = try buildKeyData(scratch, entries);
    const m = if (codec.protect) |f| try f(codec.ctx, scratch[0..n], scratch) else n;
    var params = p;
    params.key_data = scratch[0..m];
    return buildSleepResponse(out, params);
}

/// 解开 Response 的 Key Data：没有 unprotect 时按明文子元素解释。
pub fn openKeyData(resp: *const SleepResponse, scratch: []u8, codec: KeyDataCodec) Error![]const u8 {
    if (resp.key_data.len == 0) return &.{};
    if (codec.unprotect) |f| {
        const n = try f(codec.ctx, resp.key_data, scratch);
        return scratch[0..n];
    }
    return resp.key_data;
}

/// 9.6.14.20 / 11.2.3.18.3：Exit 接受（status 0 / 1）后，Key Data 非空（用了管理帧保护）→
/// 从 Key Data 装当前 GTK / IGTK；为空 → 紧接着做组密钥握手（12.7.7）。拒绝（2–5）→ 两者都不做。
pub const KeyDelivery = enum { none, key_data, group_key_handshake };

pub fn staKeyDelivery(response_status: u8, key_data_len: usize) KeyDelivery {
    if (response_status > SleepStatus.accept_exit_update_keys) return .none;
    return if (key_data_len != 0) .key_data else .group_key_handshake;
}

// ---------------------------------------------------------------------------
// 15) BSS Max Idle Period（9.4.2.79 / 11.24.13；Figure 9-416 / 9-417）
// ---------------------------------------------------------------------------

/// Figure 9-416（p.1001）：Max Idle Period(2) + Idle Options(1)，元素体定长 3 八位组。
pub const bss_max_idle_element_len = 3;

/// BSS Max Idle Period 元素体（不含 Element ID / Length）。Idle Options 的 B1–B7 保留位：
/// 9.4.2.79 对它们没有「应拒收」的句子，只定义了 B0 的含义，所以接收端忽略保留位。
pub const BssMaxIdleElement = struct {
    /// 11.24.13 / MIB dot11BssMaxIdlePeriod：以 1000 TU 为单位的空闲超时；0 = 不做空闲解除。
    max_idle_period: u16,
    idle_options: u8,

    /// Figure 9-417（p.1002）：B0 Protected Keep-Alive Required = 1 → 只有受保护帧算活动。
    pub fn protectedKeepAliveRequired(self: BssMaxIdleElement) bool {
        return self.idle_options & 0x01 != 0;
    }
};

pub fn parseBssMaxIdleElement(body: []const u8) Error!BssMaxIdleElement {
    if (body.len < bss_max_idle_element_len) return error.Truncated;
    if (body.len != bss_max_idle_element_len) return error.BadLength;
    return .{ .max_idle_period = le16(body[0..2]), .idle_options = body[2] };
}

pub fn buildBssMaxIdleElement(out: []u8, e: BssMaxIdleElement) BuildError!usize {
    const total = 2 + bss_max_idle_element_len;
    if (out.len < total) return error.NoRoom;
    out[0] = @backingInt(ie.ElementId.bss_max_idle_period);
    out[1] = bss_max_idle_element_len;
    w16(out[2..4], e.max_idle_period);
    out[4] = e.idle_options;
    return total;
}

/// 11.24.13（p.1809）：保活帧的受保护要求由 Idle Options 决定——要求受保护时只有受保护
/// 帧能证明活动；否则受保护或不受保护帧都行。
pub const KeepaliveClass = enum {
    /// 仅受保护帧算活动（Protected Keep-Alive Required = 1）。
    protected_only,
    /// 受保护或不受保护帧都算活动。
    either,
};

pub fn keepaliveClass(e: BssMaxIdleElement) KeepaliveClass {
    return if (e.protectedKeepAliveRequired()) .protected_only else .either;
}

/// STA 侧保活判决（11.24.13）：AP 在「≥ Max Idle Period 没收到该 STA 发起的 Data /
/// PS-Poll / Management 帧」时可解除关联，所以 STA 必须在那之前发出保活帧。
/// `elapsed_tu` = 距上次「本 STA 发起、AP 已收到」一帧的时长，`margin_tu` 是调用方给定的
/// 发送 + 对端处理余量（原文没有规定余量大小）；时间全部注入。周期以 TU 计——元素里的
/// 1000 TU 单位由调用方换算。字段最大 65535，换算后是 65 535 000 TU，所以周期参数是 u32
///（主代理验收时由 u16 改正：u16 只装得下字段值 65 以内，而真实取值是几百）。
pub const KeepaliveVerdict = enum {
    /// 还不用发。
    none_needed,
    /// 再不发就来不及：elapsed + margin 已达到 Max Idle Period。
    send_keepalive,
    /// elapsed 已 ≥ Max Idle Period：AP 侧已可解除关联。
    already_overdue,
};

pub fn keepaliveVerdict(max_idle_period_tu: u32, elapsed_tu: u32, margin_tu: u32) KeepaliveVerdict {
    if (max_idle_period_tu == 0) return .none_needed; // dot11BssMaxIdlePeriod = 0：无空闲解除
    if (elapsed_tu >= max_idle_period_tu) return .already_overdue;
    // elapsed < period，减法安全；elapsed + margin ≥ period ⟺ margin ≥ period − elapsed。
    if (margin_tu >= max_idle_period_tu - elapsed_tu) return .send_keepalive;
    return .none_needed;
}

// ---------------------------------------------------------------------------
// 16) TIM Broadcast（9.4.2.83 / 9.4.2.84；9.6.14.21 / 9.6.14.22；11.2.3.17）
// ---------------------------------------------------------------------------

/// Table 9-77（p.787）：TIM Broadcast Request 元素 ID 94、Response 元素 ID 95。
pub const tim_broadcast_request_element_id: u8 = 94;
pub const tim_broadcast_response_element_id: u8 = 95;

/// Table 9-205（p.1007）：Status 字段；5–255 保留。
pub const TimStatus = struct {
    pub const accept: u8 = 0;
    pub const accept_valid_timestamp: u8 = 1;
    pub const denied: u8 = 2;
    pub const overridden: u8 = 3;
    pub const overridden_valid_timestamp: u8 = 4;
};

/// Figure 9-719（p.1240）：Category、WNM Action(18)、Dialog Token（非 0）、TIM Broadcast
/// Request 元素（Figure 9-425：ID 94、Length 1、TIM Broadcast Interval(1)；0 = 终止本 STA
/// 的 TIM broadcast，9.4.2.83）。
pub const TimBroadcastRequest = struct {
    dialog_token: u8,
    interval: u8,
};

pub fn parseTimBroadcastRequest(body: []const u8) Error!TimBroadcastRequest {
    if (body.len < 6) return error.Truncated;
    if (body.len != 6) return error.BadLength; // Figure 9-719（行 65638）：定长 6 八位组
    try checkHeader(body, .tim_broadcast_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    if (body[3] != tim_broadcast_request_element_id or body[4] != 1) return error.MissingElement;
    return .{ .dialog_token = body[2], .interval = body[5] };
}

pub fn buildTimBroadcastRequest(out: []u8, dialog_token: u8, interval: u8) BuildError!usize {
    if (dialog_token == 0) return error.ZeroDialogToken;
    if (out.len < 6) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.tim_broadcast_request);
    out[2] = dialog_token;
    out[3] = tim_broadcast_request_element_id;
    out[4] = 1;
    out[5] = interval;
    return 6;
}

/// Figure 9-426（p.1007）：Status(1)；status 0/1/3/4 时带 TIM Broadcast Interval(1)、
/// Offset(4，有符号微秒，±4 µs 容差、相对 TBTT)、High Rate(2)、Low Rate(2)（0.5 Mb/s
/// 单位，0 = 不发该 TIM 帧）；Length = 1 或 10。
pub const TimBroadcastResponseElement = struct {
    status: u8,
    interval: u8 = 0,
    offset_us: i32 = 0,
    high_rate: u16 = 0,
    low_rate: u16 = 0,
};

pub fn parseTimBroadcastResponseElement(body: []const u8) Error!TimBroadcastResponseElement {
    if (body.len < 1) return error.Truncated;
    const status = body[0];
    if (status > TimStatus.overridden_valid_timestamp) return error.ReservedValue; // Table 9-205
    const scheduled = status != TimStatus.denied;
    if (body.len != (if (scheduled) @as(usize, 10) else 1)) return error.BadLength;
    if (!scheduled) return .{ .status = status };
    return .{
        .status = status,
        .interval = body[1],
        .offset_us = @bitCast(le32(body[2..6])),
        .high_rate = le16(body[6..8]),
        .low_rate = le16(body[8..10]),
    };
}

pub fn buildTimBroadcastResponseElement(out: []u8, e: TimBroadcastResponseElement) BuildError!usize {
    if (e.status > TimStatus.overridden_valid_timestamp) return error.ReservedValue;
    const scheduled = e.status != TimStatus.denied;
    const total = if (scheduled) @as(usize, 12) else 3; // 头 2 + 体 1
    if (out.len < total) return error.NoRoom;
    out[0] = tim_broadcast_response_element_id;
    out[1] = @intCast(total - 2);
    out[2] = e.status;
    if (scheduled) {
        out[3] = e.interval;
        w32(out[4..8], @bitCast(e.offset_us));
        w16(out[8..10], e.high_rate);
        w16(out[10..12], e.low_rate);
    }
    return total;
}

/// Figure 9-720（p.1240）：Category、WNM Action(19)、Dialog Token（非应答发送时为 0）、
/// TIM Broadcast Response 元素（3 或 12 八位组）。
pub const TimBroadcastResponse = struct {
    dialog_token: u8,
    element: TimBroadcastResponseElement,
};

pub fn parseTimBroadcastResponse(body: []const u8) Error!TimBroadcastResponse {
    if (body.len < 6) return error.Truncated; // 头 3 + 元素头 2 + 至少 Status 1
    try checkHeader(body, .tim_broadcast_response);
    if (body[3] != tim_broadcast_response_element_id) return error.MissingElement;
    const elen: usize = body[4];
    if (body.len - 5 < elen) return error.Truncated;
    if (body.len != 5 + elen) return error.BadLength; // 恰好一个元素
    const e = try parseTimBroadcastResponseElement(body[5..][0..elen]);
    return .{ .dialog_token = body[2], .element = e };
}

pub fn buildTimBroadcastResponse(out: []u8, r: TimBroadcastResponse) BuildError!usize {
    if (r.element.status > TimStatus.overridden_valid_timestamp) return error.ReservedValue;
    const total = 3 + (if (r.element.status != TimStatus.denied) @as(usize, 12) else 3);
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.tim_broadcast_response);
    out[2] = r.dialog_token;
    _ = try buildTimBroadcastResponseElement(out[3..], r.element);
    return total;
}

/// STA 侧的接受 / 拒绝判决（11.2.3.17，p.1621–1622）：Accept（0/1）= AP 接受了请求的
/// interval（原文 NOTE：STA 可以忽略响应里的 interval 字段、用自己请求的值）；Overridden
/// （3/4）= AP 用自己的 interval（当前活跃的最小值）；Denied（2）= 不提供 TIM broadcast。
pub const TimBroadcastDecision = struct {
    /// TIM broadcast 服务是否在用。
    active: bool,
    /// 使用的 TIM Broadcast Interval（Beacon 周期数）。
    interval: u8,
    /// TIM 帧里带合法 TSF 时间戳（status 1 / 4）。
    valid_timestamp: bool,
};

pub fn decideTimBroadcast(requested_interval: u8, resp: TimBroadcastResponseElement) TimBroadcastDecision {
    return switch (resp.status) {
        TimStatus.accept, TimStatus.accept_valid_timestamp => .{
            .active = true,
            .interval = requested_interval,
            .valid_timestamp = resp.status == TimStatus.accept_valid_timestamp,
        },
        TimStatus.overridden, TimStatus.overridden_valid_timestamp => .{
            .active = true,
            .interval = resp.interval,
            .valid_timestamp = resp.status == TimStatus.overridden_valid_timestamp,
        },
        else => .{ .active = false, .interval = 0, .valid_timestamp = false },
    };
}

/// 11.2.3.17（p.1622）：N_TBI × dot11BeaconPeriod TU 一个 TTTT（target TIM transmission
/// time）、time 0 是 TTTT、TIM 帧排在 TTTT + offset（µs，可为负）。返回 `now_us` 之后（含）
/// 的下一个 TIM 发送时刻（µs，TSF 时基）。`tim_interval` = 0 或 `decideTimBroadcast` 判为
/// 不活跃时返回 0（没有服务）。TU = 1024 µs（9.1.3.3）。
pub fn nextTimTransmission(beacon_interval_tu: u16, tim_interval: u8, offset_us: i32, now_us: u64) u64 {
    if (tim_interval == 0) return 0;
    const period_us: i64 = @as(i64, tim_interval) * beacon_interval_tu * 1024;
    if (period_us <= 0) return 0;
    const off: i64 = offset_us;
    const now: i64 = @intCast(now_us);
    // TTTT_k + off >= now → k = ceil((now − off) / period)（整除时含当前时刻）。
    var k: i64 = @divTrunc(now - off, period_us);
    if (@rem(now - off, period_us) > 0) k += 1;
    if (k < 0) k = 0;
    return @intCast(period_us * k + off);
}

// ---------------------------------------------------------------------------
// 17) FMS（9.4.2.76 / 9.4.2.77；9.6.14.11 / 9.6.14.12；11.2.3.16 / 11.24.8）
// ---------------------------------------------------------------------------

/// Table 9-77：FMS Request 元素 ID 87、FMS Response 元素 ID 88。
pub const fms_request_element_id: u8 = 87;
pub const fms_response_element_id: u8 = 88;
/// Table 9-196：FMS Request 子元素 ID；Table 9-197：FMS Status 子元素 ID 1、TCLAS Status
/// 子元素 ID 2；221 = Vendor Specific。
pub const fms_subelement_id: u8 = 1;
pub const fms_status_subelement_id: u8 = 1;
pub const tclas_status_subelement_id: u8 = 2;
/// 9.4.2.75（p.996）：「A maximum of eight FMS counters are permitted」。
pub const max_fms_counters = 8;

/// Figure 9-409（p.996）：B0–B2 FMS Counter ID、B3–B7 Current Count（Current Count 在
/// FMS Status 子元素里保留；原文没有「应拒收」，接收端不检查它）。
pub const FmsCounter = packed struct(u8) {
    counter_id: u3,
    current_count: u5 = 0,

    pub fn word(self: FmsCounter) u8 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u8) FmsCounter {
        return .{ .counter_id = @as(u3, @truncate(w)), .current_count = @as(u5, @truncate(w >> 3)) };
    }
};

/// Figure 9-411（p.997）：Subelement ID(1)=1、Length、Delivery Interval(1，DTIM 数；0 =
/// 不再使用该流)、Max Delivery Interval(1，0 = 接受 AP 的任意上限)、Rate Identification(4)、
/// FMSID(1，新请求保留)、TCLAS 元素（≥1）、TCLAS Processing 元素（0 或 3 八位组）。
/// FMS 的 TCLAS Processing 只是「可选」（9.4.2.76 原文没有 TFS/DMS 的「≥2 个必须带」），
/// 所以这里不强制。
pub const FmsSubelementParams = struct {
    delivery_interval: u8,
    max_delivery_interval: u8,
    rate_identification: u32,
    fmsid: u8,
    /// 已编码的 TCLAS 元素串（含 Element ID / Length 头）。
    tclas_elements: []const []const u8,
    tclas_processing: ?TclasProcessing = null,
};

pub fn buildFmsSubelement(out: []u8, p: FmsSubelementParams) BuildError!usize {
    if (p.tclas_elements.len == 0) return error.Empty;
    var payload: usize = 7; // interval + max + rate(4) + fmsid
    for (p.tclas_elements) |e| payload += e.len;
    if (p.tclas_processing != null) payload += 3;
    if (payload > 255 or out.len < 2 + payload) return error.NoRoom;
    out[0] = fms_subelement_id;
    out[1] = @intCast(payload);
    out[2] = p.delivery_interval;
    out[3] = p.max_delivery_interval;
    w32(out[4..8], p.rate_identification);
    out[8] = p.fmsid;
    var pos: usize = 9;
    for (p.tclas_elements) |e| {
        @memcpy(out[pos..][0..e.len], e);
        pos += e.len;
    }
    if (p.tclas_processing) |proc| {
        out[pos] = tclas_processing_element_id;
        out[pos + 1] = 1;
        out[pos + 2] = @backingInt(proc);
        pos += 3;
    }
    return 2 + payload;
}

/// Figure 9-411 的子元素体（Subelement ID / Length 之后）。
pub const FmsSubelement = struct {
    delivery_interval: u8,
    max_delivery_interval: u8,
    rate_identification: u32,
    fmsid: u8,
    tclas_count: usize,
    tclas_processing: ?TclasProcessing,
};

pub fn parseFmsSubelement(body: []const u8) Error!FmsSubelement {
    if (body.len < 7) return error.Truncated;
    var v = FmsSubelement{
        .delivery_interval = body[0],
        .max_delivery_interval = body[1],
        .rate_identification = le32(body[2..6]),
        .fmsid = body[6],
        .tclas_count = 0,
        .tclas_processing = null,
    };
    var w = ie.Walker.init(body[7..]);
    while (w.next() catch return error.Truncated) |el| {
        switch (el.id) {
            tclas_element_id => {
                if (v.tclas_processing != null) return error.BadValue; // TCLAS 不能排在 Processing 之后
                _ = try parseTclasElement(el.body);
                v.tclas_count += 1;
            },
            tclas_processing_element_id => {
                if (v.tclas_processing != null) return error.BadValue; // 至多一个
                v.tclas_processing = try parseTclasProcessing(el.body);
            },
            else => return error.UnexpectedElement,
        }
    }
    if (v.tclas_count == 0) return error.Empty; // 「one or more TCLAS Elements」
    return v;
}

/// Table 9-196 / 9-197 的子元素串计数与校验。请求只认 FMS 子元素（ID 1）与 Vendor（221，
/// Table 9-196 的 ID 2 保留）；响应另认 FMS Status（1）与 TCLAS Status（2）。保留 ID 拒收。
fn countFmsSubelementsGeneric(bytes: []const u8, comptime response: bool) Error!usize {
    var n: usize = 0;
    var w = rrm.SubWalker.init(bytes);
    while (try w.next()) |s| {
        switch (s.id) {
            fms_subelement_id => {
                if (response) {
                    _ = try parseFmsStatusSubelement(s.body);
                } else {
                    _ = try parseFmsSubelement(s.body);
                }
            },
            tclas_status_subelement_id => {
                if (!response) return error.ReservedValue; // Table 9-196：2 保留
                _ = try parseFmsTclasStatusSubelement(s.body);
            },
            221 => {},
            else => return error.ReservedValue,
        }
        n += 1;
    }
    return n;
}

/// Figure 9-410（p.996）：FMS Token(1) + ≥1 个 FMS Request 子元素。
pub const FmsRequestElement = struct {
    fms_token: u8,
    subelements: []const u8,
};

pub fn parseFmsRequestElement(body: []const u8) Error!FmsRequestElement {
    if (body.len < 1) return error.Truncated;
    if (body.len > 253) return error.TooLong; // 元素总长 ≤ 255（9.4.2.76，行 54217）
    if (try countFmsSubelementsGeneric(body[1..], false) == 0) return error.Empty;
    return .{ .fms_token = body[0], .subelements = body[1..] };
}

pub fn buildFmsRequestElement(out: []u8, fms_token: u8, subelements: []const []const u8) BuildError!usize {
    if (subelements.len == 0) return error.Empty;
    var payload: usize = 1;
    for (subelements) |s| payload += s.len;
    if (payload > 253) return error.TooLong; // 元素总长 = 2 + payload ≤ 255（行 54217）
    if (out.len < 2 + payload) return error.NoRoom;
    out[0] = fms_request_element_id;
    out[1] = @intCast(payload);
    out[2] = fms_token;
    var pos: usize = 3;
    for (subelements) |s| {
        @memcpy(out[pos..][0..s.len], s);
        pos += s.len;
    }
    return 2 + payload;
}

/// Figure 9-414（p.1000）：TCLAS Status 子元素 = Subelement ID(1)=2、Length、FMSID(1)、
/// TCLAS 元素（≥1）、TCLAS Processing 元素（0 或 3 八位组）。
pub const FmsTclasStatusSubelement = struct {
    fmsid: u8,
    tclas_count: usize,
    tclas_processing: ?TclasProcessing,
};

pub fn parseFmsTclasStatusSubelement(body: []const u8) Error!FmsTclasStatusSubelement {
    if (body.len < 1) return error.Truncated;
    var v = FmsTclasStatusSubelement{ .fmsid = body[0], .tclas_count = 0, .tclas_processing = null };
    var w = ie.Walker.init(body[1..]);
    while (w.next() catch return error.Truncated) |el| {
        switch (el.id) {
            tclas_element_id => {
                if (v.tclas_processing != null) return error.BadValue; // TCLAS 不能排在 Processing 之后
                _ = try parseTclasElement(el.body);
                v.tclas_count += 1;
            },
            tclas_processing_element_id => {
                if (v.tclas_processing != null) return error.BadValue;
                v.tclas_processing = try parseTclasProcessing(el.body);
            },
            else => return error.UnexpectedElement,
        }
    }
    if (v.tclas_count == 0) return error.Empty;
    return v;
}

/// Figure 9-413（p.998）：Subelement ID(1)=1、Length、Element Status(1)（Table 9-198，与
/// TFS Response Status 共用第 11 节的 `TfsResponseStatus`）、Delivery Interval(1)、
/// Max Delivery Interval(1)、FMSID(1)、FMS Counter(1)、Rate Identification(4)、
/// Multicast MAC(6) → 体 15 八位组。
pub const FmsStatusSubelement = struct {
    status: u8,
    delivery_interval: u8,
    max_delivery_interval: u8,
    fmsid: u8,
    counter: FmsCounter,
    rate_identification: u32,
    multicast: [6]u8,
};

pub fn parseFmsStatusSubelement(body: []const u8) Error!FmsStatusSubelement {
    if (body.len < 15) return error.Truncated;
    if (body.len != 15) return error.BadLength;
    if (body[0] > TfsResponseStatus.alternate_classifier_unavailable) return error.ReservedValue;
    return .{
        .status = body[0],
        .delivery_interval = body[1],
        .max_delivery_interval = body[2],
        .fmsid = body[3],
        .counter = FmsCounter.fromWord(body[4]),
        .rate_identification = le32(body[5..9]),
        .multicast = body[9..15].*,
    };
}

/// Figure 9-412（p.998）：FMS Token(1) + ≥1 个 FMS Response 子元素。
pub const FmsResponseElement = struct {
    fms_token: u8,
    subelements: []const u8,
};

pub fn parseFmsResponseElement(body: []const u8) Error!FmsResponseElement {
    if (body.len < 1) return error.Truncated;
    if (body.len > 253) return error.TooLong; // 元素总长 ≤ 255（9.4.2.77，行 54324）
    if (try countFmsSubelementsGeneric(body[1..], true) == 0) return error.Empty;
    return .{ .fms_token = body[0], .subelements = body[1..] };
}

pub fn buildFmsResponseElement(out: []u8, fms_token: u8, subelements: []const []const u8) BuildError!usize {
    if (subelements.len == 0) return error.Empty;
    var payload: usize = 1;
    for (subelements) |s| payload += s.len;
    if (payload > 253) return error.TooLong; // 元素总长 = 2 + payload ≤ 255（行 54324）
    if (out.len < 2 + payload) return error.NoRoom;
    out[0] = fms_response_element_id;
    out[1] = @intCast(payload);
    out[2] = fms_token;
    var pos: usize = 3;
    for (subelements) |s| {
        @memcpy(out[pos..][0..s.len], s);
        pos += s.len;
    }
    return 2 + payload;
}

/// Figure 9-706 / 9-707（p.1234）：Cat、WNM Action(9/10)、Dialog Token、恰好一个 FMS
/// Request / Response 元素。请求的 Dialog Token 非 0 且唯一；应答自主发送时为 0。
pub const FmsRequestFrame = struct {
    dialog_token: u8,
    element: FmsRequestElement,
};

pub fn parseFmsRequestFrame(body: []const u8) Error!FmsRequestFrame {
    if (body.len < 6) return error.Truncated; // 头 3 + 元素头 2 + FMS Token 1
    try checkHeader(body, .fms_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    if (body[3] != fms_request_element_id) return error.MissingElement;
    const elen: usize = body[4];
    if (body.len - 5 < elen or elen < 1) return error.BadLength;
    if (body.len != 5 + elen) return error.BadLength; // 恰好一个元素
    const el = try parseFmsRequestElement(body[5..][0..elen]);
    return .{ .dialog_token = body[2], .element = el };
}

pub fn buildFmsRequestFrame(out: []u8, dialog_token: u8, element: []const u8) BuildError!usize {
    if (dialog_token == 0) return error.ZeroDialogToken;
    if (element.len < 3 or element[0] != fms_request_element_id) return error.BadValue;
    const total = 3 + element.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.fms_request);
    out[2] = dialog_token;
    @memcpy(out[3..total], element);
    return total;
}

pub const FmsResponseFrame = struct {
    dialog_token: u8,
    element: FmsResponseElement,
};

pub fn parseFmsResponseFrame(body: []const u8) Error!FmsResponseFrame {
    if (body.len < 6) return error.Truncated;
    try checkHeader(body, .fms_response);
    if (body[3] != fms_response_element_id) return error.MissingElement;
    const elen: usize = body[4];
    if (body.len - 5 < elen or elen < 1) return error.BadLength;
    if (body.len != 5 + elen) return error.BadLength;
    const el = try parseFmsResponseElement(body[5..][0..elen]);
    return .{ .dialog_token = body[2], .element = el };
}

pub fn buildFmsResponseFrame(out: []u8, dialog_token: u8, element: []const u8) BuildError!usize {
    if (element.len < 3 or element[0] != fms_response_element_id) return error.BadValue;
    const total = 3 + element.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.fms_response);
    out[2] = dialog_token;
    @memcpy(out[3..total], element);
    return total;
}

/// STA 侧的 FMS 流账本（11.2.3.16 / 11.24.8；有界表、无堆）。每条流一个 FMSID。
pub const max_fms_streams = 4;

pub const FmsStream = struct {
    fmsid: u8 = 0,
    counter: FmsCounter = .{ .counter_id = 0 },
    delivery_interval: u8 = 1,
    multicast: [6]u8 = @splat(0),
    /// Accept 后为真。
    active: bool = false,
    /// 收到 Terminate（10/11/12）后为真：流退出 FMS、按 DTIM 间隔交付，STA 每个 DTIM
    /// 都要醒来（11.2.3.16 末尾 / 11.24.8）。
    terminated_to_dtim: bool = false,
};

pub const FmsSta = struct {
    streams: [max_fms_streams]FmsStream = @splat(.{}),
    /// Element Status = 9（Multicast rate changes not allowed）后置位：关联期间不得再发
    /// 改 multicast rate 的 FMS Request（11.24.8）。
    rate_change_blocked: bool = false,

    pub fn stream(self: *const FmsSta, fmsid: u8) ?*const FmsStream {
        for (&self.streams) |*s| {
            if (s.active and s.fmsid == fmsid) return s;
        }
        return null;
    }

    /// 11.24.8：还能不能发「改 multicast rate」的 FMS Request。
    pub fn mayRequestRateChange(self: *const FmsSta) bool {
        return !self.rate_change_blocked;
    }

    /// 把一条 FMS Status 子元素记进账本：Accept → 建流；Terminate（10/11/12）→ 流退出并
    /// 置 terminated_to_dtim；9 → rate_change_blocked；Deny / Alternate → 流不变（备选
    /// 间隔在子元素里，是否按它重新请求由调用方决定）。
    pub fn applyStatus(self: *FmsSta, st: *const FmsStatusSubelement) Error!void {
        switch (st.status) {
            TfsResponseStatus.accept => {
                for (&self.streams) |*s| {
                    if (s.active and s.fmsid == st.fmsid) {
                        s.counter = st.counter;
                        s.delivery_interval = st.delivery_interval;
                        s.multicast = st.multicast;
                        return;
                    }
                }
                for (&self.streams) |*s| {
                    if (!s.active and !s.terminated_to_dtim) {
                        s.* = .{
                            .fmsid = st.fmsid,
                            .counter = st.counter,
                            .delivery_interval = st.delivery_interval,
                            .multicast = st.multicast,
                            .active = true,
                        };
                        return;
                    }
                }
                return error.TooMany;
            },
            TfsResponseStatus.terminate_policy,
            TfsResponseStatus.terminate_resources,
            TfsResponseStatus.terminate_higher_priority,
            => {
                for (&self.streams) |*s| {
                    if (s.active and s.fmsid == st.fmsid) {
                        s.active = false;
                        s.terminated_to_dtim = true;
                        return;
                    }
                }
                return error.BadValue; // 终止一条不存在的流
            },
            TfsResponseStatus.multicast_rate_not_allowed => self.rate_change_blocked = true,
            else => {},
        }
    }
};

// ---------------------------------------------------------------------------
// 18) DMS（9.4.2.88 / 9.4.2.89；9.6.14.26 / 9.6.14.27；11.24.16.2）
// ---------------------------------------------------------------------------

/// Table 9-77：DMS Request 元素 ID 99、DMS Response 元素 ID 100；TSPEC 元素 ID 13；
/// Destination URI 元素 ID 141。
pub const dms_request_element_id: u8 = 99;
pub const dms_response_element_id: u8 = 100;
pub const tspec_element_id: u8 = 13;
pub const destination_uri_element_id: u8 = 141;
/// Table 9-208 / 9-212：GCR Request / GCR Response 子元素 ID 都是 1；221 = Vendor Specific。
pub const gcr_request_subelement_id: u8 = 1;
pub const gcr_response_subelement_id: u8 = 1;

/// Table 9-207（p.1012）：0 Add、1 Remove、2 Change；3–255 保留。
pub const DmsRequestType = enum(u8) { add = 0, remove = 1, change = 2 };

/// Table 9-211（p.1014）：0 Accept、1 Denied、2 Terminate、3 GCR Advertise；4–255 保留。
pub const DmsResponseType = enum(u8) { accept = 0, denied = 1, terminate = 2, gcr_advertise = 3 };

/// Figure 9-433（p.1013）：Subelement ID(8)、Length(8)、GATS Retransmission Policy
/// (B16–B19)、GCR Delivery Method(B20–B23) → 体 1 八位组：低 4 位 retrans、高 4 位
/// delivery。Table 9-209：retrans 0–3、4–15 保留；Table 9-210：delivery 0–2、3–15 保留。
pub const GcrRequest = struct {
    gats_retransmission_policy: u4,
    gcr_delivery_method: u4,

    pub fn word(self: GcrRequest) u8 {
        return @as(u8, self.gats_retransmission_policy) | (@as(u8, self.gcr_delivery_method) << 4);
    }
};

pub fn parseGcrRequest(body: []const u8) Error!GcrRequest {
    if (body.len != 1) return error.BadLength;
    const retrans: u4 = @truncate(body[0]);
    const delivery: u4 = @truncate(body[0] >> 4);
    if (retrans > 3) return error.ReservedValue; // Table 9-209
    if (delivery > 2) return error.ReservedValue; // Table 9-210
    return .{ .gats_retransmission_policy = retrans, .gcr_delivery_method = delivery };
}

/// Figure 9-432（p.1011）：DMSID(1)、DMS Length(1)、Request Type(1)、TCLAS 元素（仅 Add，
/// ≥1）、TCLAS Processing（0 或 3）、TSPEC 元素（0 或 57）、Optional Subelements（GCR
/// Request，0 或 1 个）。DMS Length = 1 + 其后全部字节数（9.4.2.88）；Remove 时 = 1 且
/// 其后没有字段（11.24.16.2）。
pub const DmsDescriptor = struct {
    dmsid: u8,
    request_type: DmsRequestType,
    /// 已编码的 TCLAS 元素串（含 Element ID / Length 头）。
    tclas_elements: []const []const u8 = &.{},
    tclas_processing: ?TclasProcessing = null,
    /// 已编码的 TSPEC 元素（含头）。
    tspec: []const u8 = &.{},
    gcr_request: ?GcrRequest = null,
};

pub fn buildDmsDescriptor(out: []u8, d: DmsDescriptor) BuildError!usize {
    switch (d.request_type) {
        .add => {
            if (d.dmsid != 0) return error.BadValue; // 「DMSID field is set to 0 when Add」
            if (d.tclas_elements.len == 0) return error.Empty;
            // 「…two or more TCLAS elements present, the TCLAS Processing Element field
            // contains one … Otherwise, … zero TCLAS Processing elements」（行 54844–54846）：
            // 双向都查——1 个 TCLAS 带了 Processing 也拒。
            if (d.tclas_elements.len >= 2 and d.tclas_processing == null) return error.MissingElement;
            if (d.tclas_processing != null and d.tclas_elements.len < 2) return error.BadValue;
        },
        .change => {
            if (d.dmsid == 0) return error.BadValue;
            // 「When the Request Type field contains any value other than 'Add', the TCLAS
            // Elements field contains zero TCLAS elements」。
            if (d.tclas_elements.len != 0 or d.tclas_processing != null) return error.BadValue;
        },
        .remove => {
            if (d.dmsid == 0) return error.BadValue;
            // 「The TLCAS Elements, TCLAS Processing Element TSPEC Element and Optional
            // Subelements fields shall not be included if the Request Type is 'Remove'」。
            if (d.tclas_elements.len != 0 or d.tclas_processing != null or d.tspec.len != 0 or d.gcr_request != null)
                return error.BadValue;
        },
    }
    var payload: usize = 1; // Request Type
    for (d.tclas_elements) |e| payload += e.len;
    if (d.tclas_processing != null) payload += 3;
    payload += d.tspec.len;
    if (d.gcr_request != null) payload += 3; // 子元素头 2 + 体 1
    // DMS Length = 1 + n，payload 就是 DMS Length（上面的初值 1 是 Request Type）；原文上限 253
    //（9.4.2.88，行 54809–54810）。评审第二轮的 N1 成立：原先写成 252，比原文严一个八位组，与解析侧（dmslen ≤ 253）不一致，主代理更正。
    if (payload > 253) return error.TooLong;
    if (out.len < 2 + payload) return error.NoRoom;
    out[0] = d.dmsid;
    out[1] = @intCast(payload);
    out[2] = @backingInt(d.request_type);
    var pos: usize = 3;
    for (d.tclas_elements) |e| {
        @memcpy(out[pos..][0..e.len], e);
        pos += e.len;
    }
    if (d.tclas_processing) |proc| {
        out[pos] = tclas_processing_element_id;
        out[pos + 1] = 1;
        out[pos + 2] = @backingInt(proc);
        pos += 3;
    }
    @memcpy(out[pos..][0..d.tspec.len], d.tspec);
    pos += d.tspec.len;
    if (d.gcr_request) |g| {
        out[pos] = gcr_request_subelement_id;
        out[pos + 1] = 1;
        out[pos + 2] = g.word();
        pos += 3;
    }
    return 2 + payload;
}

/// parseDmsDescriptor 的返回视图（切片指向输入）。
pub const DmsDescriptorView = struct {
    dmsid: u8,
    request_type: DmsRequestType,
    tclas_count: usize,
    tclas_processing: ?TclasProcessing,
    tspec: []const u8,
    gcr_request: ?GcrRequest,
};

/// 解析一个 DMS Descriptor：`raw` = [DMSID][DMS Length][Request Type]…（含其后全部字节）。
pub fn parseDmsDescriptor(raw: []const u8) Error!DmsDescriptorView {
    if (raw.len < 3) return error.Truncated;
    const dmslen: usize = raw[1];
    if (dmslen < 1) return error.BadValue;
    if (dmslen > 253) return error.TooLong; // 「maximum value of the DMS Length field is 253」（行 54810）
    if (raw.len - 2 < dmslen) return error.Truncated;
    if (raw[2] > 2) return error.ReservedValue; // Table 9-207：3–255 保留
    const rt: DmsRequestType = @fromBackingInt(raw[2]);
    const body = raw[3 .. 2 + dmslen];
    var v = DmsDescriptorView{
        .dmsid = raw[0],
        .request_type = rt,
        .tclas_count = 0,
        .tclas_processing = null,
        .tspec = &.{},
        .gcr_request = null,
    };
    // Remove 的结构校验先走（11.24.16.2：DMS Length = 1 且其后没有字段）；否则 payload 里
    // 的保留子元素 ID 会先触发 ReservedValue。
    if (rt == .remove and (dmslen != 1 or v.dmsid == 0)) return error.BadValue;
    var pos: usize = 0;
    while (pos + 2 <= body.len and body[pos] == tclas_element_id) {
        const len: usize = body[pos + 1];
        if (body.len - pos - 2 < len) return error.Truncated;
        _ = try parseTclasElement(body[pos + 2 ..][0..len]);
        v.tclas_count += 1;
        pos += 2 + len;
    }
    if (pos + 3 <= body.len and body[pos] == tclas_processing_element_id) {
        if (body[pos + 1] != 1) return error.BadLength;
        v.tclas_processing = try parseTclasProcessing(body[pos + 2 ..][0..1]);
        pos += 3;
    }
    if (pos + 2 <= body.len and body[pos] == tspec_element_id) {
        const len: usize = body[pos + 1];
        if (body.len - pos - 2 < len) return error.Truncated;
        v.tspec = body[pos .. pos + 2 + len];
        pos += 2 + len;
    }
    var w = rrm.SubWalker.init(body[pos..]);
    while (try w.next()) |s| {
        switch (s.id) {
            gcr_request_subelement_id => {
                if (v.gcr_request != null) return error.BadValue; // zero or one
                v.gcr_request = try parseGcrRequest(s.body);
            },
            221 => {},
            else => return error.ReservedValue, // Table 9-208
        }
    }
    switch (rt) {
        .add => {
            if (v.dmsid != 0) return error.BadValue;
            if (v.tclas_count == 0) return error.Empty;
            if (v.tclas_count >= 2 and v.tclas_processing == null) return error.MissingElement;
            if (v.tclas_processing != null and v.tclas_count < 2) return error.BadValue;
        },
        .change => {
            if (v.dmsid == 0) return error.BadValue;
            if (v.tclas_count != 0 or v.tclas_processing != null) return error.BadValue;
        },
        .remove => {
            if (dmslen != 1) return error.BadValue; // 「DMS Length field is set to 1」
            if (v.dmsid == 0) return error.BadValue;
        },
    }
    return v;
}

/// Figure 9-431（p.1011）：Element ID 99、Length、DMS Descriptor List（≥1 个 Descriptor）。
pub const DmsRequestElement = struct {
    descriptors: []const u8,
    count: usize,
};

pub fn countDmsDescriptors(bytes: []const u8) Error!usize {
    var n: usize = 0;
    var rest = bytes;
    while (rest.len != 0) {
        if (rest.len < 3) return error.Truncated;
        const dmslen: usize = rest[1];
        if (dmslen < 1) return error.BadValue;
        if (rest.len - 2 < dmslen) return error.Truncated;
        _ = try parseDmsDescriptor(rest[0 .. 2 + dmslen]);
        n += 1;
        rest = rest[2 + dmslen ..];
    }
    return n;
}

pub fn parseDmsRequestElement(body: []const u8) Error!DmsRequestElement {
    const n = try countDmsDescriptors(body);
    if (n == 0) return error.Empty; // 「one or more DMS Descriptors」
    return .{ .descriptors = body, .count = n };
}

pub fn buildDmsRequestElement(out: []u8, descriptors: []const []const u8) BuildError!usize {
    if (descriptors.len == 0) return error.Empty;
    var payload: usize = 0;
    for (descriptors) |d| payload += d.len;
    if (payload > 255 or out.len < 2 + payload) return error.NoRoom;
    out[0] = dms_request_element_id;
    out[1] = @intCast(payload);
    var pos: usize = 2;
    for (descriptors) |d| {
        @memcpy(out[pos..][0..d.len], d);
        pos += d.len;
    }
    return 2 + payload;
}

/// Figure 9-435（p.1014）：DMSID(1)、DMS Length(1)、Response Type(1)、Last Sequence
/// Control(2)、TCLAS 元素、TCLAS Processing（0 或 3）、TSPEC（0 或 57）、Optional
/// Subelements。DMS Length = 3 + n；Terminate 时 = 3。
pub const DmsStatusView = struct {
    dmsid: u8,
    response_type: DmsResponseType,
    /// 65535 = 不支持；Terminate 且支持时 B0–B3 = 0、B4–B15 = 序号；65534 = 终止前最后
    /// 一帧不是组地址帧。
    last_sequence_control: u16,
    tclas_count: usize,
    first_tclas_type: u8,
    tclas_processing: ?TclasProcessing,
    tspec: []const u8,
    gcr_response: bool,
};

/// 解析一个 DMS Status 字段：`raw` = [DMSID][DMS Length][Response Type][LSC 2]…。
pub fn parseDmsStatusField(raw: []const u8) Error!DmsStatusView {
    if (raw.len < 5) return error.Truncated;
    const dmslen: usize = raw[1];
    if (dmslen < 3) return error.BadLength; // 「3 + n」
    if (dmslen > 253) return error.TooLong; // 「maximum value … is 253」（行 54926）
    if (raw.len - 2 < dmslen) return error.Truncated;
    if (raw[2] > 3) return error.ReservedValue; // Table 9-211：4–255 保留
    const rt: DmsResponseType = @fromBackingInt(raw[2]);
    const body = raw[5 .. 2 + dmslen];
    var v = DmsStatusView{
        .dmsid = raw[0],
        .response_type = rt,
        .last_sequence_control = le16(raw[3..5]),
        .tclas_count = 0,
        .first_tclas_type = 0,
        .tclas_processing = null,
        .tspec = &.{},
        .gcr_response = false,
    };
    var pos: usize = 0;
    while (pos + 2 <= body.len and body[pos] == tclas_element_id) {
        const len: usize = body[pos + 1];
        if (body.len - pos - 2 < len) return error.Truncated;
        const t = try parseTclasElement(body[pos + 2 ..][0..len]);
        if (v.tclas_count == 0) v.first_tclas_type = @backingInt(t.classifier.kind);
        v.tclas_count += 1;
        pos += 2 + len;
    }
    if (pos + 3 <= body.len and body[pos] == tclas_processing_element_id) {
        if (body[pos + 1] != 1) return error.BadLength;
        v.tclas_processing = try parseTclasProcessing(body[pos + 2 ..][0..1]);
        pos += 3;
    }
    if (pos + 2 <= body.len and body[pos] == tspec_element_id) {
        const len: usize = body[pos + 1];
        if (body.len - pos - 2 < len) return error.Truncated;
        v.tspec = body[pos .. pos + 2 + len];
        pos += 2 + len;
    }
    var w = rrm.SubWalker.init(body[pos..]);
    while (try w.next()) |s| {
        switch (s.id) {
            gcr_response_subelement_id => {
                if (v.gcr_response) return error.BadValue; // zero or one
                // GCR 是本组件的非目标（11.24.16.3）：只认到这个子元素并校验前面 2 个
                // 半八位组，Concealment Address / Schedule Element 留给调用方。
                if (s.body.len < 1) return error.Truncated;
                const retrans: u4 = @truncate(s.body[0]);
                const delivery: u4 = @truncate(s.body[0] >> 4);
                if (retrans > 3 or delivery > 2) return error.ReservedValue;
                v.gcr_response = true;
            },
            221 => {},
            else => return error.ReservedValue, // Table 9-212
        }
    }
    switch (rt) {
        .accept, .denied => {
            // Accept/Denied 必须带 ≥1 个 TCLAS（带 GCR Response 时第一个还要是类型 0）。
            if (v.tclas_count == 0) return error.Empty;
            if (v.gcr_response) {
                if (v.first_tclas_type != 0) return error.BadValue;
                if (v.tspec.len == 0) return error.MissingElement;
            }
            // 「Terminate or when there is only one TCLAS element → 0 个 TCLAS Processing」。
            if (v.tclas_count == 1 and v.tclas_processing != null) return error.BadValue;
            // 11.24.16.2：Accept → 非 0 DMSID；Deny → DMSID = 0。
            if (rt == .accept and v.dmsid == 0) return error.BadValue;
            if (rt == .denied and v.dmsid != 0) return error.BadValue;
        },
        .terminate => {
            if (dmslen != 3) return error.BadLength; // 「Terminate 时 = 3」→ 后面没有字段
            // supported 时 B0–B3 = 0；65535 = 不支持；65534 = 上一帧不是组地址帧。
            if (v.last_sequence_control != 65535 and v.last_sequence_control != 65534 and
                (v.last_sequence_control & 0x000F) != 0) return error.BadValue;
        },
        .gcr_advertise => {
            if (v.gcr_response) {
                if (v.tclas_count == 0) return error.Empty;
                if (v.first_tclas_type != 0) return error.BadValue;
                if (v.tspec.len == 0) return error.MissingElement;
            }
        },
    }
    return v;
}

/// Figure 9-434（p.1014）：Element ID 100、Length、DMS Status List（≥1 个 Status 字段）。
pub const DmsResponseElement = struct {
    statuses: []const u8,
    count: usize,
};

pub fn countDmsStatusFields(bytes: []const u8) Error!usize {
    var n: usize = 0;
    var rest = bytes;
    while (rest.len != 0) {
        if (rest.len < 5) return error.Truncated;
        const dmslen: usize = rest[1];
        if (dmslen < 3) return error.BadLength;
        if (rest.len - 2 < dmslen) return error.Truncated;
        _ = try parseDmsStatusField(rest[0 .. 2 + dmslen]);
        n += 1;
        rest = rest[2 + dmslen ..];
    }
    return n;
}

pub fn parseDmsResponseElement(body: []const u8) Error!DmsResponseElement {
    const n = try countDmsStatusFields(body);
    if (n == 0) return error.Empty;
    return .{ .statuses = body, .count = n };
}

pub fn buildDmsResponseElement(out: []u8, statuses: []const []const u8) BuildError!usize {
    if (statuses.len == 0) return error.Empty;
    var payload: usize = 0;
    for (statuses) |s| payload += s.len;
    if (payload > 255 or out.len < 2 + payload) return error.NoRoom;
    out[0] = dms_response_element_id;
    out[1] = @intCast(payload);
    var pos: usize = 2;
    for (statuses) |s| {
        @memcpy(out[pos..][0..s.len], s);
        pos += s.len;
    }
    return 2 + payload;
}

/// Figure 9-724 / 9-725（p.1243）：Cat、WNM Action(23/24)、Dialog Token、一个或多个 DMS
/// Request / Response 元素（9.6.14.26「contains one or more DMS Request elements」、
/// 9.6.14.27「contains one or more DMS Response elements」——与 FMS 的「one element」不同）。
/// 请求的 Dialog Token 非 0；应答自主发送（终止 / GCR 广告）时为 0。
pub const DmsRequestFrame = struct {
    dialog_token: u8,
    /// 元素串（指向输入缓冲）。
    elements: []const u8,
    count: usize,
};

fn walkDmsElements(body: []const u8, comptime request: bool) Error!usize {
    var pos: usize = 0;
    var n: usize = 0;
    while (pos < body.len) {
        if (body.len - pos < 2) return error.Truncated;
        const want_id = if (request) dms_request_element_id else dms_response_element_id;
        if (body[pos] != want_id) return error.MissingElement;
        const len: usize = body[pos + 1];
        if (body.len - pos - 2 < len) return error.Truncated;
        const el = body[pos + 2 ..][0..len];
        if (request) {
            _ = try parseDmsRequestElement(el);
        } else {
            _ = try parseDmsResponseElement(el);
        }
        n += 1;
        pos += 2 + len;
    }
    if (n == 0) return error.Empty;
    return n;
}

pub fn parseDmsRequestFrame(body: []const u8) Error!DmsRequestFrame {
    if (body.len == 3) return error.Empty; // 一个元素都没有
    if (body.len < 5) return error.Truncated; // 头 3 + 元素头 2
    try checkHeader(body, .dms_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    const n = try walkDmsElements(body[3..], true);
    return .{ .dialog_token = body[2], .elements = body[3..], .count = n };
}

pub fn buildDmsRequestFrame(out: []u8, dialog_token: u8, elements: []const u8) BuildError!usize {
    if (dialog_token == 0) return error.ZeroDialogToken;
    if (elements.len == 0) return error.Empty;
    const total = 3 + elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.dms_request);
    out[2] = dialog_token;
    @memcpy(out[3..total], elements);
    return total;
}

pub const DmsResponseFrame = struct {
    dialog_token: u8,
    elements: []const u8,
    count: usize,
};

pub fn parseDmsResponseFrame(body: []const u8) Error!DmsResponseFrame {
    if (body.len == 3) return error.Empty; // 一个元素都没有
    if (body.len < 5) return error.Truncated;
    try checkHeader(body, .dms_response);
    const n = try walkDmsElements(body[3..], false);
    return .{ .dialog_token = body[2], .elements = body[3..], .count = n };
}

pub fn buildDmsResponseFrame(out: []u8, dialog_token: u8, elements: []const u8) BuildError!usize {
    if (elements.len == 0) return error.Empty;
    const total = 3 + elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.dms_response);
    out[2] = dialog_token;
    @memcpy(out[3..total], elements);
    return total;
}

/// STA 侧的 DMS 流账本（11.24.16.2；有界表、无堆）。Accept → 记 DMSID（非 0）；Terminate
/// → 清除；Denied → 不记。
pub const max_dms_streams = 4;

pub const DmsSta = struct {
    /// 0 = 空槽；AP 保证 DMSID 非 0（Accept 时）。
    dmsids: [max_dms_streams]u8 = @splat(0),

    pub fn active(self: *const DmsSta, dmsid: u8) bool {
        if (dmsid == 0) return false;
        for (self.dmsids) |d| {
            if (d == dmsid) return true;
        }
        return false;
    }

    pub fn applyResponse(self: *DmsSta, st: *const DmsStatusView) Error!void {
        switch (st.response_type) {
            .accept => {
                if (st.dmsid == 0) return error.BadValue;
                if (self.active(st.dmsid)) return;
                for (&self.dmsids) |*d| {
                    if (d.* == 0) {
                        d.* = st.dmsid;
                        return;
                    }
                }
                return error.TooMany;
            },
            .terminate => {
                for (&self.dmsids) |*d| {
                    if (d.* == st.dmsid) d.* = 0;
                }
            },
            .denied, .gcr_advertise => {},
        }
    }
};

// ---------------------------------------------------------------------------
// 19) Collocated Interference（9.4.2.85；9.6.14.13 / 9.6.14.14；11.24.9）
// ---------------------------------------------------------------------------

/// Table 9-77：Collocated Interference Report 元素 ID 96。
pub const collocated_interference_report_element_id: u8 = 96;

/// Figure 9-709（p.1235）：Request Info(1) = B0–B1 Automatic Report Enabled +
/// B2–B7 Report Timeout（200 TU 单位）。auto：0 = 取消之前的请求（此时 Report Timeout
/// 保留）；1 = 变化时报；2 = 周期报；3 = 周期报或变化时报。
pub const RequestInfo = packed struct(u8) {
    automatic_report: u2 = 0,
    report_timeout: u6 = 0,

    pub fn word(self: RequestInfo) u8 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u8) RequestInfo {
        return .{ .automatic_report = @as(u2, @truncate(w)), .report_timeout = @as(u6, @truncate(w >> 2)) };
    }
};

/// Figure 9-708（p.1235）：Cat、WNM Action(11)、Dialog Token（非 0）、Request Info(1)。
pub const CiRequestFrame = struct {
    dialog_token: u8,
    info: RequestInfo,
};

pub fn parseCollocatedInterferenceRequestFrame(body: []const u8) Error!CiRequestFrame {
    if (body.len < 4) return error.Truncated;
    try checkHeader(body, .collocated_interference_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    const info = RequestInfo.fromWord(body[3]);
    // auto = 0 时 Report Timeout 是保留子字段（9.6.14.13，行 65427）；9.2.4.1（行 36052）：
    // 保留子字段接收时忽略——不拒帧（构造侧仍拒，发送方置 0）。
    return .{ .dialog_token = body[2], .info = info };
}

pub fn buildCollocatedInterferenceRequestFrame(out: []u8, dialog_token: u8, info: RequestInfo) BuildError!usize {
    if (dialog_token == 0) return error.ZeroDialogToken;
    if (info.automatic_report == 0 and info.report_timeout != 0) return error.ReservedField;
    if (out.len < 4) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.collocated_interference_request);
    out[2] = dialog_token;
    out[3] = info.word();
    return 4;
}

/// Figure 9-427（p.1008）的元素体（Element ID / Length 之后，定长 21 八位组）：Report
/// Period(1，200 TU 单位)、Interference Level(1，补码 i8，dBm)、Interference Level
/// Accuracy / Interference Index(1)、Interference Interval(4，µs)、Interference Burst
/// Length(4，µs)、Interference Start Time / Duty Cycle(4)、Interference Center
/// Frequency(4，5 kHz 单位)、Interference Bandwidth(2，5 kHz 单位)。
/// Figure 9-428：B0–B3 Expected Accuracy（0–14 dB，15 = 未知）、B4–B7 Interference Index
/// （0 = 无共址干扰）。
pub const CiReportElement = struct {
    report_period: u8,
    level_dbm: i8,
    expected_accuracy: u4,
    index: u4,
    interval_us: u32,
    burst_us: u32,
    /// 周期干扰：TSF B0–B31；可变 / 无干扰：平均占空比或 0。
    start_or_duty: u32,
    /// 5 kHz 单位；2.4 GHz 本信道 = 482 400，u16 装不下（Figure 9-427 的 Octets 4）。
    center_freq_khz5: u32,
    bandwidth_khz5: u16,
};

/// Figure 9-427（p.1008，行 54696）：元素体 21 八位组 = Period(1) + Level(1) + Acc/Idx(1) +
/// Interval(4) + Burst(4) + Start/Duty(4) + Center Frequency(4) + Bandwidth(2)。
pub fn parseCiReportElement(body: []const u8) Error!CiReportElement {
    if (body.len < 21) return error.Truncated;
    if (body.len != 21) return error.BadLength;
    return .{
        .report_period = body[0],
        .level_dbm = @bitCast(body[1]),
        .expected_accuracy = @as(u4, @truncate(body[2])),
        .index = @as(u4, @truncate(body[2] >> 4)),
        .interval_us = le32(body[3..7]),
        .burst_us = le32(body[7..11]),
        .start_or_duty = le32(body[11..15]),
        .center_freq_khz5 = le32(body[15..19]),
        .bandwidth_khz5 = le16(body[19..21]),
    };
}

/// 9.4.2.85 的取值端点。
pub const CiLimits = struct {
    pub const level_unknown: i8 = 127;
    pub const level_cap_high: i8 = 126;
    pub const level_none: i8 = -128;
    pub const level_cap_low: i8 = -127;
    pub const interval_variable: u32 = 0xFFFF_FFFF;
    pub const interval_cap: u32 = 0xFFFF_FFFE;
    pub const bandwidth_unknown: u16 = 65535;
    pub const bandwidth_cap: u16 = 65534;
};

/// STA 自身的共址射频状态（与仓里共存 glue 同一个场景的输入模型）：是否监测到共址干扰
/// 及其测量值。周期 / 带宽 / 频率的「未知」用单独的布尔位表达。
pub const CoexInterferenceState = struct {
    present: bool,
    /// 测得的最大共址干扰功率（dBm；模块负责按端点封顶）。
    level_dbm: i8 = 0,
    /// 0–14 dB；15 = 未知。
    expected_accuracy: u4 = 15,
    /// 每类干扰源唯一；0 = 无。
    index: u4 = 0,
    interval_us: u32 = 0,
    interval_variable: bool = false,
    burst_us: u32 = 0,
    burst_variable: bool = false,
    /// 周期干扰的起始 TSF（B0–B31）；可变间隔 / 突发时当占空比用。
    start_or_duty: u32 = 0,
    /// 5 kHz 单位；0 = 未知（此时报本信道）。
    center_freq_khz5: u32 = 0,
    /// 本信道中心频率（5 kHz 单位；center_freq 未知时用它）。
    operating_channel_khz5: u32 = 0,
    /// –3 dB 带宽（5 kHz 单位）；unknown = true 时报 65535。
    bandwidth_khz5: u16 = 0,
    bandwidth_unknown: bool = false,
};

/// 把 STA 自身的共址射频状态编码成一条 Collocated Interference Report 元素；9.4.2.85 的
/// 全部端点封顶规则都在这里。`report_period`：周期上报的周期（200 TU 单位；0 = 非周期、
/// 只在变化时报，11.24.9）。
pub fn buildCiReportElement(out: []u8, state: *const CoexInterferenceState, report_period: u8) BuildError!usize {
    const total = 2 + 21; // Figure 9-427：元素体 21 八位组
    if (out.len < total) return error.NoRoom;
    out[0] = collocated_interference_report_element_id;
    out[1] = 21;
    out[2] = report_period;
    if (!state.present) {
        // 无共址干扰：电平 −128、index 0、其余字段全 0（9.4.2.85 各字段的「If no
        // collocated interference is present」句）。
        out[3] = @bitCast(CiLimits.level_none);
        out[4] = 0x0F; // accuracy = 15（未知）、index = 0
        w32(out[5..9], 0);
        w32(out[9..13], 0);
        w32(out[13..17], 0);
        w32(out[17..21], 0);
        w16(out[21..23], 0);
        return total;
    }
    // 电平（行 54672–54675）：「unknown → +127」与「≥126 dBm → +126」是两个可区分的编码，
    // 所以 +127（未知哨兵）放行、不被 +126 封顶吞掉；< −127 封到 −127。
    const level: i8 = if (state.level_dbm == CiLimits.level_unknown) CiLimits.level_unknown else if (state.level_dbm > CiLimits.level_cap_high) CiLimits.level_cap_high else if (state.level_dbm < CiLimits.level_cap_low) CiLimits.level_cap_low else state.level_dbm;
    out[3] = @bitCast(level);
    out[4] = @as(u8, state.expected_accuracy) | (@as(u8, state.index) << 4);
    const interval: u32 = if (state.interval_variable) CiLimits.interval_variable else if (state.interval_us >= CiLimits.interval_cap) CiLimits.interval_cap else state.interval_us;
    w32(out[5..9], interval);
    const burst: u32 = if (state.burst_variable) CiLimits.interval_variable else if (state.burst_us >= CiLimits.interval_cap) CiLimits.interval_cap else state.burst_us;
    w32(out[9..13], burst);
    w32(out[13..17], state.start_or_duty);
    const center: u32 = if (state.center_freq_khz5 != 0) state.center_freq_khz5 else state.operating_channel_khz5;
    w32(out[17..21], center);
    const bw: u16 = if (state.bandwidth_unknown) CiLimits.bandwidth_unknown else if (state.bandwidth_khz5 >= CiLimits.bandwidth_cap) CiLimits.bandwidth_cap else state.bandwidth_khz5;
    w16(out[21..23], bw);
    return total;
}

/// 9.4.2.85 的平均占空比（印刷页 1009 原式，PDF 原件核对）：Average duty cycle =
/// ⌊(2^32 − 2) × T_B / T_I + 0.5⌋（T_B = 平均干扰突发长度、T_I = 平均干扰间隔）。
/// TI = 0 不可用，返回 0。
pub fn ciDutyCycle(burst_us: u32, interval_us: u32) u64 {
    if (interval_us == 0) return 0;
    const scale: u64 = 0xFFFF_FFFE;
    return (scale * burst_us + interval_us / 2) / interval_us;
}

/// Figure 9-710（p.1236）：Cat、WNM Action(12)、Dialog Token（回显非 0）、≥1 条 Report
/// 元素（ID 96）。
pub const CiReportFrame = struct {
    dialog_token: u8,
    elements: []const u8,
    count: usize,
};

pub fn parseCollocatedInterferenceReportFrame(body: []const u8) Error!CiReportFrame {
    if (body.len < 6) return error.Truncated;
    try checkHeader(body, .collocated_interference_report);
    if (body[2] == 0) return error.ZeroDialogToken;
    var pos: usize = 3;
    var n: usize = 0;
    while (pos < body.len) {
        if (body.len - pos < 2) return error.Truncated;
        if (body[pos] != collocated_interference_report_element_id) return error.MissingElement;
        const len: usize = body[pos + 1];
        if (body.len - pos - 2 < len) return error.Truncated;
        _ = try parseCiReportElement(body[pos + 2 ..][0..len]);
        n += 1;
        pos += 2 + len;
    }
    if (n == 0) return error.Empty; // 「one or more Collocated Interference Report elements」
    return .{ .dialog_token = body[2], .elements = body[3..], .count = n };
}

pub fn buildCollocatedInterferenceReportFrame(out: []u8, dialog_token: u8, elements: []const []const u8) BuildError!usize {
    if (dialog_token == 0) return error.ZeroDialogToken;
    if (elements.len == 0) return error.Empty;
    var total: usize = 3;
    for (elements) |e| total += e.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.collocated_interference_report);
    out[2] = dialog_token;
    var pos: usize = 3;
    for (elements) |e| {
        @memcpy(out[pos..][0..e.len], e);
        pos += e.len;
    }
    return total;
}

/// 11.24.9（p.1804）：上报时机判决。auto = 1 → 变化时（且距上次 ≥ timeout×200 TU）；
/// 2 → 周期（report_period×200 TU，同样要满足 timeout）；3 → 两者；0 → 取消（不再报）。
/// `report_period` 是上报方在自己元素里声明的周期（0 = 非周期）；`elapsed_tu` 距上次上报。
pub const CiReportTrigger = enum { none, change, periodic };

pub fn ciReportTrigger(automatic_report: u2, changed: bool, elapsed_tu: u32, report_period: u8, report_timeout: u6) CiReportTrigger {
    if (elapsed_tu < @as(u32, report_timeout) * 200) return .none;
    const periodic_due = report_period != 0 and elapsed_tu >= @as(u32, report_period) * 200;
    return switch (automatic_report) {
        0 => .none,
        1 => if (changed) .change else .none,
        2 => if (periodic_due) .periodic else .none,
        3 => if (changed) .change else if (periodic_due) .periodic else .none,
    };
}

// ---------------------------------------------------------------------------
// 20) Channel Usage（9.4.2.86；9.6.14.24 / 9.6.14.25；11.24.15）
// ---------------------------------------------------------------------------

/// Table 9-77：Channel Usage 元素 ID 97。
pub const channel_usage_element_id: u8 = 97;

/// Table 9-206（p.1010）：0 = 非基础设施 802.11 网络；1 = 离信道 TDLS 直连链路；2–255 保留。
pub const UsageMode = enum(u8) { noninfrastructure = 0, off_channel_tdls = 1 };

/// Figure 9-429（p.1010）：Usage Mode(1) + Channel Entry（Operating Class / Channel 号对，
/// 9.4.1.22；零或多对）。
pub const ChannelUsageElement = struct {
    usage_mode: UsageMode,
    channel_entry: []const u8,
};

pub fn parseChannelUsageElement(body: []const u8) Error!ChannelUsageElement {
    if (body.len < 1) return error.Truncated;
    if (body[0] > 1) return error.ReservedValue; // Table 9-206：2–255 保留
    const mode: UsageMode = @fromBackingInt(body[0]);
    const entry = body[1..];
    if (entry.len % 2 != 0) return error.BadLength; // 必须成对
    return .{ .usage_mode = mode, .channel_entry = entry };
}

pub fn buildChannelUsageElement(out: []u8, e: ChannelUsageElement) BuildError!usize {
    if (e.channel_entry.len % 2 != 0) return error.BadLength;
    if (e.channel_entry.len > 255) return error.TooLong;
    const total = 2 + 1 + e.channel_entry.len;
    if (out.len < total) return error.NoRoom;
    out[0] = channel_usage_element_id;
    out[1] = @intCast(1 + e.channel_entry.len);
    out[2] = @backingInt(e.usage_mode);
    @memcpy(out[3..total], e.channel_entry);
    return total;
}

/// Figure 9-722（p.1242）：Cat、WNM Action(21)、Dialog Token（非 0）、≥1 条 Channel Usage
/// 元素（在前）、Supported Operating Classes 元素（9.4.2.54，在后）。
pub const ChannelUsageRequestFrame = struct {
    dialog_token: u8,
    usage_elements: []const u8,
    operating_classes: []const u8,
};

pub fn parseChannelUsageRequestFrame(body: []const u8) Error!ChannelUsageRequestFrame {
    if (body.len == 3) return error.Empty; // 没有 CU 元素也没有 SOC
    if (body.len < 4) return error.Truncated;
    try checkHeader(body, .channel_usage_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    var pos: usize = 3;
    var n_usage: usize = 0;
    var soc_start: ?usize = null;
    while (pos < body.len) {
        if (body.len - pos < 2) return error.Truncated;
        const id = body[pos];
        const len: usize = body[pos + 1];
        if (body.len - pos - 2 < len) return error.Truncated;
        switch (id) {
            channel_usage_element_id => {
                if (soc_start != null) return error.BadValue; // 元素顺序：Usage 全部在前
                _ = try parseChannelUsageElement(body[pos + 2 ..][0..len]);
                n_usage += 1;
            },
            @backingInt(ie.ElementId.supported_operating_classes) => {
                if (soc_start == null) soc_start = pos;
            },
            else => return error.BadValue,
        }
        pos += 2 + len;
    }
    if (n_usage == 0) return error.Empty;
    const soc = soc_start orelse return error.MissingElement;
    return .{ .dialog_token = body[2], .usage_elements = body[3..soc], .operating_classes = body[soc..] };
}

pub const ChannelUsageRequestParams = struct {
    dialog_token: u8,
    /// 完整元素（含 Element ID / Length 头）。
    usage_elements: []const []const u8,
    /// 完整的 Supported Operating Classes 元素。
    operating_classes: []const u8,
};

pub fn buildChannelUsageRequestFrame(out: []u8, p: ChannelUsageRequestParams) BuildError!usize {
    if (p.dialog_token == 0) return error.ZeroDialogToken;
    if (p.usage_elements.len == 0) return error.Empty;
    if (p.operating_classes.len < 2 or p.operating_classes[0] != @backingInt(ie.ElementId.supported_operating_classes))
        return error.BadValue;
    var total: usize = 3;
    for (p.usage_elements) |e| total += e.len;
    total += p.operating_classes.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.channel_usage_request);
    out[2] = p.dialog_token;
    var pos: usize = 3;
    for (p.usage_elements) |e| {
        @memcpy(out[pos..][0..e.len], e);
        pos += e.len;
    }
    @memcpy(out[pos..][0..p.operating_classes.len], p.operating_classes);
    pos += p.operating_classes.len;
    return pos;
}

/// Figure 9-723（p.1242）：Cat、WNM Action(22)、Dialog Token（自主 / 组播发送时 0）、
/// Channel Usage 元素（0 或多个）、Country String(3)、可选 Power Constraint /
/// EDCA Parameter Set / Transmit Power Envelope 元素。
pub const ChannelUsageResponseFrame = struct {
    dialog_token: u8,
    usage_elements: []const u8,
    country_string: [3]u8,
    optional_elements: []const u8,
};

pub fn parseChannelUsageResponseFrame(body: []const u8) Error!ChannelUsageResponseFrame {
    if (body.len < 6) return error.Truncated; // 头 3 + country 3（0 条 Usage 元素）
    try checkHeader(body, .channel_usage_response);
    var pos: usize = 3;
    const usage_start = pos;
    while (pos + 2 <= body.len and body[pos] == channel_usage_element_id) {
        const len: usize = body[pos + 1];
        if (body.len - pos - 2 < len) return error.Truncated;
        _ = try parseChannelUsageElement(body[pos + 2 ..][0..len]);
        pos += 2 + len;
    }
    if (body.len - pos < 3) return error.Truncated;
    const country: [3]u8 = body[pos..][0..3].*;
    pos += 3;
    // 可选元素：结构按 9.4.2.1 走一遍（内容不解释；Power Constraint / EDCA / TPE 的
    // 具体处理不在本组件）。
    var rest = body[pos..];
    while (rest.len != 0) {
        if (rest.len < 2) return error.Truncated;
        const len: usize = rest[1];
        if (rest.len - 2 < len) return error.Truncated;
        rest = rest[2 + len ..];
    }
    return .{
        .dialog_token = body[2],
        .usage_elements = body[usage_start..(usage_start + (pos - 3 - usage_start))],
        .country_string = country,
        .optional_elements = body[pos..],
    };
}

pub const ChannelUsageResponseParams = struct {
    dialog_token: u8,
    usage_elements: []const []const u8,
    country_string: [3]u8,
    /// 可选元素串（Power Constraint / EDCA Parameter Set / Transmit Power Envelope，
    /// 已编码；可为空）。
    optional_elements: []const u8 = &.{},
};

pub fn buildChannelUsageResponseFrame(out: []u8, p: ChannelUsageResponseParams) BuildError!usize {
    var total: usize = 3 + 3;
    for (p.usage_elements) |e| total += e.len;
    total += p.optional_elements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.channel_usage_response);
    out[2] = p.dialog_token;
    var pos: usize = 3;
    for (p.usage_elements) |e| {
        @memcpy(out[pos..][0..e.len], e);
        pos += e.len;
    }
    @memcpy(out[pos..][0..3], &p.country_string);
    pos += 3;
    @memcpy(out[pos..][0..p.optional_elements.len], p.optional_elements);
    pos += p.optional_elements.len;
    return pos;
}

// ---------------------------------------------------------------------------
// 21) WNM Notification（9.6.14.29 / 9.6.14.30；Table 9-360 / 9-361 / 9-362；11.24.17）
// ---------------------------------------------------------------------------

/// Table 9-360（p.1244）：0 = Firmware Update Notification；221 = Vendor Specific；
/// 1–220、222–255 保留。
pub const notification_type_firmware_update: u8 = 0;
pub const notification_type_vendor_specific: u8 = 221;

/// Figure 9-727（p.1244）：Cat、WNM Action(26)、Dialog Token（非 0）、Type(1)、Optional
/// Subelements（9.4.3 格式；Table 9-361：0 AP Descriptor、1 Firmware Version—Current、
/// 2 Firmware Version—New、3–255 保留）。Type = 0 时应带 AP Descriptor 与两个 Firmware
/// Version 子元素（内容不在本组件解释）。
pub const NotificationRequest = struct {
    dialog_token: u8,
    notification_type: u8,
    subelements: []const u8,
};

pub fn parseWnmNotificationRequest(body: []const u8) Error!NotificationRequest {
    if (body.len < 4) return error.Truncated;
    try checkHeader(body, .notification_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    const t = body[3];
    if (t != notification_type_firmware_update and t != notification_type_vendor_specific)
        return error.ReservedValue; // Table 9-360
    var w = rrm.SubWalker.init(body[4..]);
    var seen: u8 = 0;
    while (try w.next()) |s| {
        // Table 9-361（行 65848–65852）只为 Type 0 定义 0/1/2（3–255 保留）；Type 221
        // 的子元素由厂商定义，不在此约束。
        if (t == notification_type_firmware_update and s.id > 2) return error.ReservedValue;
        if (t == notification_type_firmware_update) seen |= @as(u8, 1) << @intCast(s.id);
    }
    // 「When the Type field is 0, the AP Descriptor, Firmware Version—Current, and Firmware
    // Version—New optional subelements are included」（9.6.14.29，行 65817–65819）。
    if (t == notification_type_firmware_update and seen != 0b0111) return error.MissingElement;
    return .{ .dialog_token = body[2], .notification_type = t, .subelements = body[4..] };
}

pub fn buildWnmNotificationRequest(out: []u8, dialog_token: u8, notification_type: u8, subelements: []const u8) BuildError!usize {
    if (dialog_token == 0) return error.ZeroDialogToken;
    if (notification_type != notification_type_firmware_update and notification_type != notification_type_vendor_specific)
        return error.ReservedValue;
    // Type 0 必带 AP Descriptor(0)/FW Current(1)/FW New(2)（9.6.14.29，行 65817–65819）。
    if (notification_type == notification_type_firmware_update) {
        var seen: u8 = 0;
        var w = rrm.SubWalker.init(subelements);
        while (w.next() catch return error.Truncated) |s| {
            if (s.id > 2) return error.ReservedValue;
            seen |= @as(u8, 1) << @intCast(s.id);
        }
        if (seen != 0b0111) return error.MissingElement;
    }
    const total = 4 + subelements.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.notification_request);
    out[2] = dialog_token;
    out[3] = notification_type;
    @memcpy(out[4..total], subelements);
    return total;
}

/// Figure 9-728（p.1245）：Cat、WNM Action(27)、Dialog Token（回显非 0）、Response
/// Status(1)。Table 9-362：0 = Notification Acknowledged；1–255 保留。
pub const WnmNotificationResponse = struct {
    dialog_token: u8,
    /// 恒为 0（其余值保留）。
    status: u8,
};

pub fn parseWnmNotificationResponse(body: []const u8) Error!WnmNotificationResponse {
    if (body.len < 4) return error.Truncated;
    try checkHeader(body, .notification_response);
    if (body[2] == 0) return error.ZeroDialogToken;
    if (body[3] != 0) return error.ReservedValue; // Table 9-362
    return .{ .dialog_token = body[2], .status = body[3] };
}

pub fn buildWnmNotificationResponse(out: []u8, r: WnmNotificationResponse) BuildError!usize {
    if (r.dialog_token == 0) return error.ZeroDialogToken;
    if (r.status != 0) return error.ReservedValue;
    if (out.len < 4) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.notification_response);
    out[2] = r.dialog_token;
    out[3] = r.status;
    return 4;
}

/// 11.24.17（p.1824）：收到 Type = 0 的 Request → 必须回 Response Status = 0；Type = 221
/// 是厂商自定义（响应规则在厂商手里）；保留类型在解析处已拒。
pub const NotificationAction = enum {
    /// 回 Response Status = 0。
    acknowledge,
    /// 厂商自定义。
    vendor_defined,
};

pub fn notificationResponseRule(notification_type: u8) ?NotificationAction {
    return switch (notification_type) {
        notification_type_firmware_update => .acknowledge,
        notification_type_vendor_specific => .vendor_defined,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// 22) Event / Diagnostic 容器（9.4.2.67–9.4.2.70；9.6.14.2–9.6.14.5；11.24.2 / 11.24.3）
// ---------------------------------------------------------------------------

/// Table 9-77：Event Request 78、Event Report 79、Diagnostic Request 80、Diagnostic
/// Report 81。
pub const event_request_element_id: u8 = 78;
pub const event_report_element_id: u8 = 79;
pub const diagnostic_request_element_id: u8 = 80;
pub const diagnostic_report_element_id: u8 = 81;

/// Table 9-171（p.961）：Event / Diagnostic 类型。保留值拒收（解析处）。
pub const EventType = struct {
    pub const transition: u8 = 0;
    pub const rsna: u8 = 1;
    pub const peer_to_peer: u8 = 2;
    pub const wnm_log: u8 = 3;
    pub const vendor_specific: u8 = 221;

    pub fn defined(t: u8) bool {
        return t == transition or t == rsna or t == peer_to_peer or t == wnm_log or t == vendor_specific;
    }
};

/// Table 9-178（p.973）：Diagnostic 类型 0–4 与 221 有定义（与 Table 9-171 不同：类型 4 在
/// 这里是 IEEE 802.1X Authentication Diagnostic）；5–220、222–255 保留。
pub const DiagType = struct {
    pub const vendor_specific: u8 = 221;

    pub fn defined(t: u8) bool {
        return t <= 4 or t == vendor_specific;
    }
};

/// Table 9-175（p.968）：Event Report Status；5–255 保留。
pub const EventReportStatus = struct {
    pub const successful: u8 = 0;
    pub const request_failed: u8 = 1;
    pub const request_refused: u8 = 2;
    pub const request_incapable: u8 = 3;
    pub const detected_frequent_transition: u8 = 4;
};

/// Figure 9-351（p.961）：Event Token(1，非 0)、Event Type(1)、Event Response Limit(1，
/// 0 = 不限)、Event Request 字段（子元素串；请求 WNM log（type 3）时不存在）。
pub const EventRequestElement = struct {
    event_token: u8,
    event_type: u8,
    response_limit: u8,
    /// 子元素串（各事件类型的子元素内容不在本组件解释）。
    request: []const u8,
};

pub fn parseEventRequestElement(body: []const u8) Error!EventRequestElement {
    if (body.len < 3) return error.Truncated;
    if (body[0] == 0) return error.BadValue; // 「nonzero number that is unique」
    if (!EventType.defined(body[1])) return error.ReservedValue; // Table 9-171
    if (body[1] == EventType.wnm_log and body.len != 3) return error.BadValue;
    return .{ .event_token = body[0], .event_type = body[1], .response_limit = body[2], .request = body[3..] };
}

pub fn buildEventRequestElement(out: []u8, e: EventRequestElement) BuildError!usize {
    if (e.event_token == 0) return error.BadValue;
    if (!EventType.defined(e.event_type)) return error.ReservedValue;
    if (e.event_type == EventType.wnm_log and e.request.len != 0) return error.BadValue;
    const body = 3 + e.request.len;
    const total = 2 + body;
    if (body > 255 or out.len < total) return error.NoRoom;
    out[0] = event_request_element_id;
    out[1] = @intCast(body);
    out[2] = e.event_token;
    out[3] = e.event_type;
    out[4] = e.response_limit;
    @memcpy(out[5..total], e.request);
    return total;
}

/// Figure 9-365（p.968）：Event Token(1，自主上报时 0)、Event Type(1)、Event Report
/// Status(1)；status = 0 时带 Event TSF(8)、UTC Offset(10)、Event Time Error(5)、
/// Event Report 字段；status ≠ 0 时只带前三个字段（「present only when … is 0」）。
pub const EventReportElement = struct {
    event_token: u8,
    event_type: u8,
    status: u8,
    tsf: u64 = 0,
    utc_offset: [10]u8 = @splat(0),
    time_error: [5]u8 = @splat(0),
    report: []const u8 = &.{},
};

pub fn parseEventReportElement(body: []const u8) Error!EventReportElement {
    if (body.len < 3) return error.Truncated;
    if (!EventType.defined(body[1])) return error.ReservedValue;
    if (body[2] > EventReportStatus.detected_frequent_transition) return error.ReservedValue;
    if (body[2] != EventReportStatus.successful) {
        if (body.len != 3) return error.BadLength;
        return .{ .event_token = body[0], .event_type = body[1], .status = body[2] };
    }
    if (body.len < 26) return error.BadLength; // 3 + 8 + 10 + 5
    return .{
        .event_token = body[0],
        .event_type = body[1],
        .status = body[2],
        .tsf = std.mem.readInt(u64, body[3..11], .little),
        .utc_offset = body[11..21].*,
        .time_error = body[21..26].*,
        .report = body[26..],
    };
}

pub fn buildEventReportElement(out: []u8, e: EventReportElement) BuildError!usize {
    if (!EventType.defined(e.event_type)) return error.ReservedValue;
    if (e.status > EventReportStatus.detected_frequent_transition) return error.ReservedValue;
    if (e.status != EventReportStatus.successful) {
        if (out.len < 5) return error.NoRoom;
        out[0] = event_report_element_id;
        out[1] = 3;
        out[2] = e.event_token;
        out[3] = e.event_type;
        out[4] = e.status;
        return 5;
    }
    const total = 5 + 23 + e.report.len;
    if (out.len < total) return error.NoRoom;
    out[0] = event_report_element_id;
    out[1] = @intCast(23 + e.report.len);
    out[2] = e.event_token;
    out[3] = e.event_type;
    out[4] = e.status;
    std.mem.writeInt(u64, out[5..13], e.tsf, .little);
    @memcpy(out[13..23], &e.utc_offset);
    @memcpy(out[23..28], &e.time_error);
    @memcpy(out[28..total], e.report);
    return total;
}

/// Figure 9-370（p.973）：Diagnostic Token(1)、Diagnostic Request Type(1)、Diagnostic
/// Timeout(2，秒)、Diagnostic Subelements（≥0；Length 最小 4）。Table 9-178：0–4、221。
pub const DiagnosticRequestElement = struct {
    token: u8,
    request_type: u8,
    timeout_s: u16,
    subelements: []const u8,
};

pub fn parseDiagnosticRequestElement(body: []const u8) Error!DiagnosticRequestElement {
    if (body.len < 4) return error.Truncated;
    if (!DiagType.defined(body[1])) return error.ReservedValue; // Table 9-178：5–220、222–255 保留
    // 「The Cancel Diagnostic Request, Manufacturer Information STA Report, and
    // Configuration Profile Diagnostic Request elements carry no Diagnostic subelements」
    // （9.4.2.69，行 53279–53280）：类型 0/1/2 的体必须恰 4 八位组。
    if (body[1] <= 2 and body.len != 4) return error.BadValue;
    return .{ .token = body[0], .request_type = body[1], .timeout_s = le16(body[2..4]), .subelements = body[4..] };
}

pub fn buildDiagnosticRequestElement(out: []u8, e: DiagnosticRequestElement) BuildError!usize {
    if (!DiagType.defined(e.request_type)) return error.ReservedValue;
    // 类型 0/1/2 不带子元素（9.4.2.69，行 53279–53280）。
    if (e.request_type <= 2 and e.subelements.len != 0) return error.BadValue;
    const total = 6 + e.subelements.len; // 头 2 + Token + Type + Timeout(2)
    if (e.subelements.len > 249 or out.len < total) return error.NoRoom;
    out[0] = diagnostic_request_element_id;
    out[1] = @intCast(total - 2);
    out[2] = e.token;
    out[3] = e.request_type;
    w16(out[4..6], e.timeout_s);
    @memcpy(out[6..total], e.subelements);
    return total;
}

/// Figure 9-393（p.984）：Diagnostic Token(1)、Diagnostic Report Type(1)、Diagnostic
/// Status(1)（复用 Table 9-175）、Diagnostic Subelements。Length 最小 3。
pub const DiagnosticReportElement = struct {
    token: u8,
    report_type: u8,
    status: u8,
    subelements: []const u8,
};

pub fn parseDiagnosticReportElement(body: []const u8) Error!DiagnosticReportElement {
    if (body.len < 3) return error.Truncated;
    if (!DiagType.defined(body[1])) return error.ReservedValue;
    if (body[2] > EventReportStatus.detected_frequent_transition) return error.ReservedValue;
    return .{ .token = body[0], .report_type = body[1], .status = body[2], .subelements = body[3..] };
}

pub fn buildDiagnosticReportElement(out: []u8, e: DiagnosticReportElement) BuildError!usize {
    if (!DiagType.defined(e.report_type)) return error.ReservedValue;
    if (e.status > EventReportStatus.detected_frequent_transition) return error.ReservedValue;
    const total = 5 + e.subelements.len; // 头 2 + Token + Type + Status
    if (e.subelements.len > 250 or out.len < total) return error.NoRoom;
    out[0] = diagnostic_report_element_id;
    out[1] = @intCast(total - 2);
    out[2] = e.token;
    out[3] = e.report_type;
    out[4] = e.status;
    @memcpy(out[5..total], e.subelements);
    return total;
}

/// 帧容器（9.6.14.2–9.6.14.5）：Event Request（action 0）/ Diagnostic Request（action 2）
/// 的 Dialog Token 非 0；Event Report（action 1）/ Diagnostic Report（action 3）回显；
/// 自主发送的 Event Report 允许 0（11.24.2）。两种请求帧都可选带一个 Destination URI
/// 元素（ID 141，9.4.2.90）。Event Report 允许 0 条元素：11.24.2「If there are no
/// available logged events … the STA shall send the Event Report frame without any Event
/// Report element」——9.6.14.3 的「one or more」按规程条款放宽（见文件头偏离清单）。
pub const EventDiagnosticFrame = struct {
    dialog_token: u8,
    elements: []const u8,
    count: usize,
    destination_uri: []const u8,
};

const ElementsWalk = struct {
    count: usize,
    /// Request 帧里解析出的 Destination URI **元素体**（ESS Detection Interval(1) +
    /// URI(1–253)，Figure 9-437；不含 ID/Length 头）；没有时为空。
    /// 注意：`buildEventDiagnosticFrame` 的同名参数收的是完整元素（[141][len][体]），
    /// 两者形式不同——解析出的体不能直接回填给构造。
    destination_uri: []const u8,
};

/// 走「want_id 元素（+ 可选 Destination URI）」的元素串。URI 规则（9.4.2.90 行 55030、
/// 9.6.14.2 行 65026）：仅 Request 帧带、zero or one、必须是最后一个元素；元素体 =
/// ESS Detection Interval(1) + URI(1–253)（Figure 9-437，行 55049）。Report 帧没有 URI
/// 槽位（Figure 9-695/9-697）→ 出现即拒。
fn parseElementsOfId(body: []const u8, comptime want_id: u8, comptime allow_empty: bool, comptime allow_uri: bool) Error!ElementsWalk {
    var pos: usize = 0;
    var n: usize = 0;
    var uri: []const u8 = &.{};
    while (pos < body.len) {
        if (body.len - pos < 2) return error.Truncated;
        const id = body[pos];
        const len: usize = body[pos + 1];
        if (body.len - pos - 2 < len) return error.Truncated;
        const el = body[pos + 2 ..][0..len];
        if (id == want_id) {
            if (uri.len != 0) return error.BadValue; // URI 必须排最后（9.4.2.90）
            switch (want_id) {
                event_request_element_id => _ = try parseEventRequestElement(el),
                event_report_element_id => _ = try parseEventReportElement(el),
                diagnostic_request_element_id => _ = try parseDiagnosticRequestElement(el),
                else => _ = try parseDiagnosticReportElement(el),
            }
            n += 1;
        } else if (id == destination_uri_element_id) {
            if (!allow_uri) return error.BadValue; // Figure 9-695 / 9-697：Report 帧无此槽位
            if (uri.len != 0) return error.BadValue; // zero or one（9.6.14.2）
            // Figure 9-437：元素体 = ESS Detection Interval(1) + URI(1–253) → 体 2–254；
            // 9.4.2.90（行 55028–55029）：「The URI field value is limited to 253 octets」。
            if (el.len < 2 or el.len > 254) return error.BadLength;
            uri = el; // 元素体：ESS Detection Interval(1) + URI（Figure 9-437，去掉 ID/Length 头）
        } else {
            return error.BadValue;
        }
        pos += 2 + len;
    }
    if (n == 0 and !allow_empty) return error.Empty;
    return .{ .count = n, .destination_uri = uri };
}

pub fn parseEventRequestFrame(body: []const u8) Error!EventDiagnosticFrame {
    if (body.len == 3) return error.Empty; // 一个元素都没有
    if (body.len < 4) return error.Truncated;
    try checkHeader(body, .event_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    const w = try parseElementsOfId(body[3..], event_request_element_id, false, true);
    return .{ .dialog_token = body[2], .elements = body[3..], .count = w.count, .destination_uri = w.destination_uri };
}

pub fn parseEventReportFrame(body: []const u8) Error!EventDiagnosticFrame {
    if (body.len < 3) return error.Truncated;
    try checkHeader(body, .event_report);
    const w = try parseElementsOfId(body[3..], event_report_element_id, true, false);
    return .{ .dialog_token = body[2], .elements = body[3..], .count = w.count, .destination_uri = w.destination_uri };
}

pub fn parseDiagnosticRequestFrame(body: []const u8) Error!EventDiagnosticFrame {
    if (body.len == 3) return error.Empty; // 一个元素都没有
    if (body.len < 4) return error.Truncated;
    try checkHeader(body, .diagnostic_request);
    if (body[2] == 0) return error.ZeroDialogToken;
    const w = try parseElementsOfId(body[3..], diagnostic_request_element_id, false, true);
    return .{ .dialog_token = body[2], .elements = body[3..], .count = w.count, .destination_uri = w.destination_uri };
}

pub fn parseDiagnosticReportFrame(body: []const u8) Error!EventDiagnosticFrame {
    if (body.len == 3) return error.Empty; // 一个元素都没有
    if (body.len < 4) return error.Truncated;
    try checkHeader(body, .diagnostic_report);
    if (body[2] == 0) return error.ZeroDialogToken;
    const w = try parseElementsOfId(body[3..], diagnostic_report_element_id, false, false);
    return .{ .dialog_token = body[2], .elements = body[3..], .count = w.count, .destination_uri = w.destination_uri };
}

pub fn buildEventDiagnosticFrame(out: []u8, action: Action, dialog_token: u8, elements: []const u8, destination_uri: []const u8) BuildError!usize {
    switch (action) {
        .event_request, .diagnostic_request, .diagnostic_report => {
            if (dialog_token == 0) return error.ZeroDialogToken;
        },
        .event_report => {},
        else => return error.BadValue,
    }
    if (destination_uri.len != 0) {
        if (action == .event_report or action == .diagnostic_report)
            return error.BadValue; // Figure 9-695 / 9-697：Report 帧没有 URI 槽位
        // 完整元素 ≥ 4：ID + Length + ESS Detection Interval(1) + URI(≥1)（Figure 9-437），
        // 与解析侧 el.len ≥ 2 对齐。
        if (destination_uri.len < 4 or destination_uri[0] != destination_uri_element_id)
            return error.BadValue;
        // 9.4.2.90（行 55028–55030）：URI ≤ 253 八位组 → 元素 ≤ 256；且必须是最后一个
        // 元素——调用方以追加顺序保证。
        if (destination_uri.len - 3 > 253) return error.BadLength;
    }
    const total = 3 + elements.len + destination_uri.len;
    if (out.len < total) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(action);
    out[2] = dialog_token;
    @memcpy(out[3..][0..elements.len], elements);
    @memcpy(out[3 + elements.len .. total], destination_uri);
    return total;
}

// ---------------------------------------------------------------------------
// 23) QoS Traffic Capability（9.4.2.78；9.6.14.23；Table 9-199 / 9-359；11.24.10）
// ---------------------------------------------------------------------------

/// Table 9-77：QoS Traffic Capability 元素 ID 89。
pub const qos_traffic_capability_element_id: u8 = 89;

/// Table 9-199（p.1001）：B0 AC_VO、B1 AC_VI、B2–B3 保留、B4 UP 4、B5 UP 5、B6 UP 6、
/// B7 保留。保留位没有「应拒收」的原文，接收端不检查。
pub const QosTrafficFlags = packed struct(u8) {
    ac_vo: bool = false,
    ac_vi: bool = false,
    reserved0: u2 = 0,
    up4: bool = false,
    up5: bool = false,
    up6: bool = false,
    reserved1: u1 = 0,

    pub fn word(self: QosTrafficFlags) u8 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u8) QosTrafficFlags {
        return .{
            .ac_vo = w & 0x01 != 0,
            .ac_vi = w & 0x02 != 0,
            .reserved0 = @as(u2, @truncate(w >> 2)),
            .up4 = w & 0x10 != 0,
            .up5 = w & 0x20 != 0,
            .up6 = w & 0x40 != 0,
            .reserved1 = @as(u1, @truncate(w >> 7)),
        };
    }
};

/// Table 9-199 里实际定义的位掩码（B0–B1、B4–B6）。
pub const qos_traffic_flags_mask: u8 = 0x73;

/// 9.4.2.78（p.1000–1001，行 54335–54362）的元素体：Length = 1 + n，n = Flags 的 B0–B1
/// 里非零位的个数；AC STA Count List（每项 1 字节，QoS AP 发送时才携带）原样返回。
pub const QosTrafficCapabilityElement = struct {
    flags: QosTrafficFlags,
    /// AC STA Count List；非 AP STA 发送（B0–B1 保留 → n = 0）时为空。
    ac_sta_counts: []const u8,
};

pub fn parseQosTrafficCapabilityElement(body: []const u8) Error!QosTrafficCapabilityElement {
    if (body.len < 1) return error.Truncated;
    // 「The value of the Length field is 1 + n, where n equals the total number of
    // nonzero bits in Bits 0–1」（9.4.2.78）；与 B0–B1 的非零位数不符 → BadLength。
    const n: usize = @popCount(body[0] & 0x03);
    if (body.len != 1 + n) return error.BadLength;
    return .{ .flags = QosTrafficFlags.fromWord(body[0]), .ac_sta_counts = body[1 .. 1 + n] };
}

pub fn buildQosTrafficCapabilityElement(out: []u8, flags: QosTrafficFlags, ac_sta_counts: []const u8) BuildError!usize {
    const n: usize = @popCount(flags.word() & 0x03);
    if (ac_sta_counts.len != n) return error.BadLength; // Length = 1 + n（9.4.2.78）
    const total = 3 + n;
    if (out.len < total) return error.NoRoom;
    out[0] = qos_traffic_capability_element_id;
    out[1] = @intCast(1 + n);
    out[2] = flags.word();
    @memcpy(out[3..total], ac_sta_counts);
    return total;
}

/// Table 9-359（p.1241，行 65672–65678）的 Update 帧 Flags：**0–3 Reserved**、4–6 UP 4–6、
/// 7 Reserved——与元素的 Table 9-199 不同（B0–B1 在元素里是 AC 位）。
pub const QosTrafficUpdateFlags = packed struct(u8) {
    reserved0: u4 = 0,
    up4: bool = false,
    up5: bool = false,
    up6: bool = false,
    reserved1: u1 = 0,

    pub fn word(self: QosTrafficUpdateFlags) u8 {
        return @bitCast(self);
    }

    pub fn fromWord(w: u8) QosTrafficUpdateFlags {
        return .{
            .reserved0 = @as(u4, @truncate(w)),
            .up4 = w & 0x10 != 0,
            .up5 = w & 0x20 != 0,
            .up6 = w & 0x40 != 0,
            .reserved1 = @as(u1, @truncate(w >> 7)),
        };
    }
};

/// Figure 9-721（p.1241）：Cat、WNM Action(20)、QoS Traffic Capability Flags(1)——位定义按
/// Table 9-359（0–3 保留）。
pub fn parseQosTrafficCapabilityUpdateFrame(body: []const u8) Error!QosTrafficUpdateFlags {
    if (body.len < 3) return error.Truncated;
    try checkHeader(body, .qos_traffic_capability_update);
    return QosTrafficUpdateFlags.fromWord(body[2]);
}

pub fn buildQosTrafficCapabilityUpdateFrame(out: []u8, flags: QosTrafficUpdateFlags) BuildError!usize {
    if (out.len < 3) return error.NoRoom;
    out[0] = category;
    out[1] = @backingInt(Action.qos_traffic_capability_update);
    out[2] = flags.word();
    return 3;
}

/// 11.24.10（p.1805）：关联期间 Flags 有任何变化 → 发 QoS Traffic Capability Update 帧。
/// 发往 AP 的位 0–3 是保留位（Table 9-359 的 0–3 Reserved；9.4.2.78 的「Bits 0–1 are
/// reserved in a transmission to an AP」），比较只看定义位 B4–B6（掩码 0x70）。
pub fn qosTrafficFlagsChanged(old: u8, new: u8) bool {
    return (old ^ new) & 0x70 != 0;
}

// ---------------------------------------------------------------------------
// 24) Extended Capabilities 里的 WNM 位（Table 9-135，p.891–893）
// ---------------------------------------------------------------------------

/// Table 9-135 的相关位号。「可能发某种 WNM 帧」的门槛都是同一句式：对端最后一个 Extended
/// Capabilities 元素里该位为 1。
pub const ExtCapBit = struct {
    pub const event: u8 = 7;
    pub const diagnostics: u8 = 8;
    pub const fms: u8 = 11;
    pub const collocated_interference_reporting: u8 = 13;
    pub const wnm_sleep_mode: u8 = 17;
    pub const tim_broadcast: u8 = 18;
    pub const qos_traffic_capability: u8 = 20;
    pub const channel_usage: u8 = 24;
    pub const dms: u8 = 26;
    pub const wnm_notification: u8 = 46;
};

/// Extended Capabilities 元素体里的第 `bit` 位（位 N → 第 N/8 字节的第 N%8 位，9.2.2）。
pub fn extCapBit(ext_capabilities_body: []const u8, bit: u8) bool {
    const byte = bit / 8;
    if (ext_capabilities_body.len <= byte) return false;
    return ext_capabilities_body[byte] & (@as(u8, 1) << @intCast(bit % 8)) != 0;
}
