var targetPath = "/Applications/WeChat.app/Contents/MacOS/WeChat";
var module = Process.enumerateModules().find(function(m) {
    return m.path === targetPath || m.name === "WeChat";
});
if (!module) {
    throw new Error("[-] Cannot find module: " + targetPath);
}
var moduleBase = module.base;
console.log("[+] WeChat module base: " + moduleBase);

// 基址解析(2026-09-20 E类事故修正): 模块表优先。真身 wechat.dylib 是全进程唯一
// >50MB 的同名模块(Frameworks/下是16KB stub), 基址确定无竞态。
// 原 "req2buf字符串+>100MB range" 扫描存在竞态误命中: 堆里 MallocHelperZone
// (合并range>100MB, rw-) 也有 "req2buf" 字符串拷贝, 扫描回调先到就赢 →
// 基址定到堆上, 全部 hook 挂空, 登录后零事件(静默死亡, 无报错)。
var searchSize = 1000 * 1024 * 1024;
var searchEnd = moduleBase.add(searchSize);
var _req2bufSearchAddr = null;
var baseAddr = null;

// 结构版本开关: 4.1.12 起上传完成结构 +0x08、下载任务结构 +0x18、寄存器漂移。
// JSON 里 "structVer": "2" = 4.1.12 布局; 旧版 JSON 无此键(渲染为 <no value>),
// 不等于 "2", 自动走 4.1.11 及以前的原路径。
var structVer = "{{.structVer}}";

// ===================== task-5: 版本化 req2buf layout =====================
// 4.1.15.55 的 req2buf 函数被重编译(旧 0x413e96c -> 新 0x4635b9c):
//   - taskId: x1/x20 -> x23; 容器基址: x24 -> x8; map 根: this+0x60 -> this+0x70;
//   - 虚调用 ABI: 旧 (vtable+0x10)(buffer, out, out, out) -> 新 (vtable+0x18)(buffer);
//   - 新版在虚调用前先 bl autoBufferWriteFunc 预写前缀串(0x46362f4), 旧版没有;
//   - 新版 found 路径新增 map erase + operator delete(0x4635ed0..0x4635f18)。
// 地址与开关的权威数据源：hook/versions/*.json。
//
// 4.2.0.5(270341): req2buf 函数同样被重编译, 但 R3 task 布局沿用 v4_1_15, 因此其版本
// JSON 仍置 "req2bufLayout": "v4_1_15" 仅作为 R3/结构布局开关, 地址仍全部由该 JSON 提供。
// 注意: C1/C2/legacy 路径里硬编码的 L415 常量(下方 L415, 0x4635xxx 段)以及 cgi 路径内联的
// slot13(0x4634710)/0xE0 模板常量都只适用于 4.1.15, 对 4.2.0.5 无效; 4.2.0.5 目前只走 R3。
//
// Go text/template 缺键渲染为 "<no value>", 所以只有精确等于 "v4_1_15" 才走新布局,
// 其余(含旧版 JSON 无该键)全部走 4.1.12 及以前的旧路径, 行为不变。
var req2bufLayout = "{{.req2bufLayout}}";
var isReq2bufLayout415 = (req2bufLayout === "v4_1_15");
// 入站消息接收: 4.1.15 的 buf2resp 不再承载普通消息, 改用 antirecall 已验证的
// 通用 Message 终结器 (270135 = 0x4cbc3ac). 布局见 antirecall MAINTAINING:
//   +0x0C type(u32), +0x18 from(std::string), +0x30 to(std::string),
//   +0xF8 serverId(u64), +0x114 created(u32), +0x130 content(std::string).
// vtable 0x9eb04f0 仅作诊断; 读取失败时用字段健全性兜底。
var messageFinalizerAddr = "{{.messageFinalizerAddr}}";
var messageVtableAddr = "{{.messageVtable}}";
var messageFinalizerEnabled = (typeof messageFinalizerAddr === "string" && messageFinalizerAddr.indexOf("0x") === 0);
var incomingMessageSeen = {};


// 诊断日志开关: 真机排查时用 HOOK_DEBUG=1 启动 bridge/微信即可打开, 也可直接改常量。
// 只在本进程自己的任务命中时打印, 避免刷屏。
var HOOK_DEBUG = false;
try {
    if (typeof Process !== "undefined" && Process.env && Process.env.HOOK_DEBUG) {
        HOOK_DEBUG = (Process.env.HOOK_DEBUG === "1" || Process.env.HOOK_DEBUG === "true");
    }
} catch (e) { /* Process.env 不可用时忽略 */ }
function hookDebug() {
    if (!HOOK_DEBUG) return;
    try {
        var parts = ["[dbg]"];
        for (var i = 0; i < arguments.length; i++) parts.push(arguments[i]);
        console.log(parts.join(" "));
    } catch (e) { /* 日志失败不影响 hook */ }
}

// ===================== task-6: 主动发送安全开关 (mode C) =====================
// 4.1.15 真机已证实 task-5 的发送路径会直接导致微信退出:
//   - 默认 skip-erase 在 onEnter 里做 mid-function `this.context.pc` 跳转, 真机在
//     "skip-erase ENTER" 后立刻断日志(无 JS error), 疑似 PC 修改未生效或跳转后
//     锁/寄存器/栈状态不一致;
//   - 若不做跳转, 原生 found 路径会 map erase + libc++ operator delete 伪造节点
//     (0x4635ed0..0x4635f18), 而伪造节点 +0x10(parent)=NULL 会在 0x4635ed8 崩。
//
// 因此 4.1.15 的发送路径默认完全关闭。需要真机验证时在 hook/versions JSON 里
// 设置 "enableSend": "true" + "req2bufSendMode": "C2"(推荐) 或 "C1"/"legacy"。
// 也可以用环境变量 HOOK_REQ2BUF_SEND_MODE=off|C1|C2|legacy 临时覆盖;
// HOOK_SEND_DISABLED=1 会强制关闭(与 bridge/script.js 的安全模式兼容)。
//
//   "C2"     = 安全发送(推荐先试): 伪造 map 节点改为 malloc 节点, 补齐
//              parent/color/key/value 让原生 erase/delete 正常执行; 在 0x4635f1c
//              (erase 之后、unlock 处) 用**纯 onEnter 内存恢复**还原 map 的
//              root/begin/size。全程不做 PC 跳转。
//   "C1"     = 不注入伪造节点: 让原生流程处理真实 map 节点(找到就正常编码,
//              找不到走 not-found 安全返回), 仅在 blrX8 处替换 autoBuffer 内容。
//   "replay" = task-7 真实任务 replay(默认 off): 用最近一次真实发送捕获的 0x300
//              snapshot 作为 payload, 只改 +0x00 taskId 和 +0xB8/+0x190 自指针,
//              保留 +0x18/+0x04/+0x10/+0x20 等真实运行期字段; 让 mars 走真实
//              dispatch/注册路径, 预写/blr 替换 payload。详见 docs §12。
//   "legacy" = task-5 旧实验(伪造节点 + skip-erase/PC 跳转), 已知会崩, 仅对照。
//   "r3"     = 原生 task 构造 + slot13 提交(2026-10-20 真机探针路线, 默认 off):
//              不注册任何发送 hook; 用真 ctor 0x30c2de4 造 newsendmsg task,
//              只把 task+0x78(B1) 换成 fake serializer 提供我们的 protobuf,
//              task+0x68 填运行时从真实 newsendmsg 捕获并 __clone() 的 hand-off 闭包,
//              然后直接调 slot13(0x4634710) 让微信自己注册/分配 taskId/dispatch。
//              前置: 必须先捕获到一份真实 newsendmsg 闭包 clone(人工发一条文本触发,
//              见 r3ClosureCapture); 无 clone 时发送安全 fail。
//              详见 docs/architecture.md §3（设置 → Hook）。
//   "off"    = 关闭(4.1.15 默认): 不注册 req2buf/blrX8/预写 hook, triggerSend* 直接 fail。
var enableSendFromJson = "{{.enableSend}}";
var req2bufSendModeFromJson = "{{.req2bufSendMode}}";
var sendEnableFlag = (enableSendFromJson === "true");

var REQ2BUF_SEND_MODE;
if (!isReq2bufLayout415) {
    // 旧布局(≤4.1.12)发送链路是已验证的, 保持原行为
    REQ2BUF_SEND_MODE = "legacy";
} else if (!sendEnableFlag) {
    REQ2BUF_SEND_MODE = "off";
} else {
    REQ2BUF_SEND_MODE = (req2bufSendModeFromJson === "C1" || req2bufSendModeFromJson === "C2" ||
        req2bufSendModeFromJson === "replay" || req2bufSendModeFromJson === "cgi" ||
        req2bufSendModeFromJson === "r3" || req2bufSendModeFromJson === "legacy") ?
        req2bufSendModeFromJson : "off";
}
try {
    if (typeof Process !== "undefined" && Process.env) {
        if (Process.env.HOOK_SEND_DISABLED === "1" || Process.env.HOOK_SEND_DISABLED === "true") {
            REQ2BUF_SEND_MODE = "off";
        }
        var _sendModeEnv = Process.env.HOOK_REQ2BUF_SEND_MODE;
        if (_sendModeEnv === "off" || _sendModeEnv === "C1" || _sendModeEnv === "C2" ||
            _sendModeEnv === "replay" || _sendModeEnv === "cgi" || _sendModeEnv === "r3" ||
            _sendModeEnv === "legacy") {
            REQ2BUF_SEND_MODE = _sendModeEnv;
        }
    }
} catch (e) { }
var sendPathEnabled = (REQ2BUF_SEND_MODE !== "off");
// R3: 原生 task 构造 + slot13 提交; 与 req2buf/blrX8/StartTask/slot13-capture 等发送 hook 互斥。
var r3ModeActive = (isReq2bufLayout415 && REQ2BUF_SEND_MODE === "r3");

// autoBuffer 预写注入策略(仅 v4_1_15 生效, 可用 HOOK_REQ2BUF_MODE=A|B 覆盖):
//   "B" = hook autoBufferWriteFunc(0x4659f18) 的 0x46362f8 调用点, 把 x1/x2 换成本进程
//         protobuf; 之后 blrX8 hook 只 stub 虚调用(默认);
//   "A" = 在 blrX8 hook 里把 autoBuffer 长度清零后重新写入我们的 protobuf(覆盖预写前缀)。
var REQ2BUF_PREWRITE_MODE = isReq2bufLayout415 ? "B" : "A";
try {
    if (typeof Process !== "undefined" && Process.env && Process.env.HOOK_REQ2BUF_MODE) {
        var _prewriteMode = Process.env.HOOK_REQ2BUF_MODE;
        if (_prewriteMode === "A" || _prewriteMode === "B") REQ2BUF_PREWRITE_MODE = _prewriteMode;
    }
} catch (e) { }

// legacy 模式的 found 路径清理策略(可用 HOOK_REQ2BUF_NODE_MODE 覆盖, 仅 legacy 有效):
//   "skip-erase" = 在 0x4635ed0 用 PC 跳转跳过 erase/delete(task-5 方案, 真机会崩);
//   "legacy"     = 保持原生流程(伪造节点 +0x10 为 NULL 时 0x4635ed8 崩)。
var REQ2BUF_NODE_MODE = isReq2bufLayout415 ? "skip-erase" : "legacy";
try {
    if (typeof Process !== "undefined" && Process.env && Process.env.HOOK_REQ2BUF_NODE_MODE) {
        var _nodeMode = Process.env.HOOK_REQ2BUF_NODE_MODE;
        if (_nodeMode === "legacy" || _nodeMode === "skip-erase") REQ2BUF_NODE_MODE = _nodeMode;
    }
} catch (e) { }

// v4_1_15 __TEXT 偏移常量(与 hook/versions/4_1_15_55_mac.json 同源)
var L415 = {
    req2bufFindRetErase: 0x4635ed0,    // found 路径父指针回爬/erase 入口
    req2bufSkipEraseResume: 0x4635f1c, // legacy: PC 跳转恢复点; C2: erase 后恢复 hook 点
    req2bufEraseDone: 0x4635f1c,       // C2: 原生 erase/delete 之后、unlock 之前
    autoBufferPreWriteRet: 0x46362f8   // 0x46362f4 bl autoBufferWriteFunc 的返回地址
};

// --------------------- mode C2: 让原生 RB-tree erase/delete 能安全处理伪造节点 ---------------------
// map 节点布局(4.1.15, 由 0x4635ed0..0x4635f1c 与 erase helper 0x24618 反推):
//   +0x00 left, +0x08 right, +0x10 parent, +0x18 color(1=black),
//   +0x20 key(u32 = taskId), +0x28 value(伪造 Message 对象指针)
// found 路径 climb 会读 node->parent(+0x10) 再解引用 [parent]; erase helper 0x24618
// 以 x0=root、x1=node 工作, node==root 且无子节点时走"直接删除根"分支, 不再平衡。
// 因此伪造节点用 libc malloc(0x30)(operator delete 兼容 free), parent 指向一个自建
// 哨兵 header(malloc 0x20), header.left=node, header.parent=header, color=1。
var req2bufTreeHeader = ptr(0);
var req2bufMallocFn = null;
var req2bufMallocNodeCount = 0;
function req2bufMalloc(size) {
    if (req2bufMallocFn === null) {
        req2bufMallocFn = new NativeFunction(Module.getExportByName(null, "malloc"), "pointer", ["size_t"]);
    }
    return req2bufMallocFn(size);
}
function ensureReq2bufTreeHeader() {
    if (!req2bufTreeHeader.isNull()) return req2bufTreeHeader;
    var h = req2bufMalloc(0x20);
    if (h.isNull()) throw new Error("malloc header failed");
    var zeros = [];
    for (var i = 0; i < 0x20; i++) zeros.push(0);
    h.writeByteArray(zeros);
    // header 自引用, 防止 erase helper 走 parent 链时读到 0
    h.add(0x10).writePointer(h);
    req2bufTreeHeader = h;
    console.log("[+] C2: fake tree header = " + h);
    return h;
}
function buildReq2bufFakeNode(valuePtr) {
    ensureReq2bufTreeHeader();
    var node = req2bufMalloc(0x30);
    if (node.isNull()) throw new Error("malloc node failed");
    var zeros = [];
    for (var i = 0; i < 0x30; i++) zeros.push(0);
    node.writeByteArray(zeros);
    node.add(0x10).writePointer(req2bufTreeHeader);   // parent: 自建 header
    node.add(0x18).writeU64(1);                       // color: black
    node.add(0x20).writeU32(taskIdGlobal);            // key: 我们的 taskId
    node.add(0x28).writePointer(valuePtr);            // value: 伪造 Message
    req2bufTreeHeader.add(0x00).writePointer(node);   // header.left = node
    req2bufMallocNodeCount++;
    return node;
}

// 每个线程的 req2buf 注入标记: enter 命中时登记, blrX8/预写/exit 消费。
// 4.1.15 不再依赖 x25(新版该寄存器不是 taskId), 用线程标记判断"这是我们的调用"。
var req2bufThreadMark = {};
var req2bufPreWriteRetAddr = ptr(0);
function req2bufThreadId(self) {
    try {
        if (self && self.threadId !== undefined) return self.threadId;
        return Process.getCurrentThreadId();
    } catch (e) {
        return -1;
    }
}
function req2bufGetThreadMark(self) {
    var tid = req2bufThreadId(self);
    var m = req2bufThreadMark[tid];
    if (!m) return null;
    // 5s 过期保护: enter 命中但异常路径未走到 exit 时, 避免标记泄漏影响后续判断
    if (Date.now() - m.loadedAt > 5000) {
        delete req2bufThreadMark[tid];
        return null;
    }
    return m;
}
function req2bufClearThreadMark(self) {
    delete req2bufThreadMark[req2bufThreadId(self)];
}

// 按 sendMsgType 选择 Go 侧传入的 protobuf hex(blrX8 / 预写注入共用)
function selectProtoHexForSend() {
    if (sendMsgType === "text") return textProtoHexGlobal;
    if (sendMsgType === "img") return imgProtoHexGlobal;
    if (sendMsgType === "video") return videoProtoHexGlobal;
    if (sendMsgType === "reply") return replyProtoHexGlobal;
    if (sendMsgType === "pat") return patProtoHexGlobal;
    if (sendMsgType === "file") return fileProtoHexGlobal;
    if (sendMsgType === "fileupload") return fileUploadProtoHexGlobal;
    if (sendMsgType === "appattach") return appAttachProtoHexGlobal;
    if (sendMsgType === "voice") return voiceProtoHexGlobal;
    return "";
}

function resolveBaseFromModuleTable() {
    var wechatModules = Process.enumerateModules().filter(function(m) {
        return m.name === "wechat.dylib";
    });
    wechatModules.sort(function(a, b) { return b.size - a.size; });
    if (wechatModules.length > 0 && wechatModules[0].size > 50 * 1024 * 1024) {
        return wechatModules[0];
    }
    return null;
}

// 必须 setImmediate 派发: initAddresses 内部依赖脚本中部 var 全局的初始化
// (fakeVtable 等)。同步调用会抢在 var 初始化前执行, var 随后又把已赋值的
// 全局重置回 ptr(0) —— 2026-09-20 D类 文本发送崩溃(fakeVtable=0 虚调用)即此因。
setImmediate(function () {
    var realModule = resolveBaseFromModuleTable();
    if (realModule) {
        baseAddr = realModule.base;
        console.log("[+] 基址解析(模块表): " + realModule.path + " base=" + baseAddr + " size=" + realModule.size);
        initAddresses();
    } else {
        console.log("[!] 模块表未找到真身 wechat.dylib, 回退 req2buf 字符串扫描");
        resolveBaseByScan();
    }
});

function resolveBaseByScan() {
var ranges = Process.enumerateRanges("r--").filter(function(r) {
    var rangeEnd = r.base.add(r.size);
    return r.base.compare(searchEnd) < 0 && rangeEnd.compare(moduleBase) > 0;
});

console.log("[+] Found " + ranges.length + " readable ranges within 1000MB window");

var pending = ranges.length;
if (pending === 0) {
    throw new Error("[-] No readable ranges found within 1000MB from module base");
}

ranges.forEach(function(r) {
    Memory.scan(r.base, r.size, "72 65 71 32 62 75 66", {
        onMatch: function(address, size) {
            if (_req2bufSearchAddr === null) {
                var rangeInfo = Process.findRangeByAddress(address);
                if (rangeInfo) {
                    // 必须是可执行映射: 排除堆区(MallocHelperZone等)里的字符串拷贝
                    if (rangeInfo.size > 100 * 1024 * 1024 && rangeInfo.protection.indexOf("x") !== -1) {
                        _req2bufSearchAddr = address;
                        console.log("[+] Range size > 100MB & executable, accepted as base address");
                    }
                }
            }
        },
        onError: function(reason) {
            // skip unreadable sub-pages
        },
        onComplete: function() {
            pending--;
            if (pending === 0) {
                if (_req2bufSearchAddr === null) {
                    throw new Error("[-] Cannot find 'req2buf' keyword in an executable range > 100MB");
                }

                var foundRange = Process.findRangeByAddress(_req2bufSearchAddr);
                baseAddr = foundRange.base;
                console.log("[+] Base address from range: " + baseAddr);
                console.log("[+] Range size: " + foundRange.size);

                initAddresses();
            }
        }
    });
});
}

function initAddresses() {
    // 文本消息全局变量 (new_text.js approach)
    blrX8Addr = baseAddr.add({{.blrX8Addr}});
    autoBufferWriteFunc = baseAddr.add({{.autoBufferWriteFunc}});

    // 双方公共使用的地址
    req2bufEnterAddr = baseAddr.add({{.req2bufEnterAddr}});
    req2bufExitAddr = baseAddr.add({{.req2bufExitAddr}});
    sendFuncAddr = baseAddr.add({{.sendFuncAddr}});
    buf2RespAddr = baseAddr.add({{.buf2RespAddr}});

    uploadImageAddr = baseAddr.add({{.uploadImageAddr}});
    cndOnCompleteAddr = baseAddr.add({{.cndOnCompleteAddr}});
    // 冷启动 CdnManager 解析(可选, 旧版本 JSON 无此键则保持 ptr(0), 走 hook 捕获老路)
    {{if .cdnGetServiceAddr}}cdnGetServiceAddr = baseAddr.add({{.cdnGetServiceAddr}});{{end}}
    {{if .cdnManagerGetterAddr}}cdnManagerGetterAddr = baseAddr.add({{.cdnManagerGetterAddr}});{{end}}

    uploadGetCallbackWrapperAddr = baseAddr.add({{.uploadGetCallbackWrapperAddr}});
    uploadGetCallbackWrapperFuncAddr = baseAddr.add({{.uploadGetCallbackWrapperFuncAddr}});
    uploadOnCompleteAddr = baseAddr.add({{.uploadOnCompleteAddr}});
    uploadOnCompleteFuncAddr = baseAddr.add({{.uploadOnCompleteFuncAddr}});
    downloadImagAddr = baseAddr.add({{.downloadImagAddr}});
    startDownloadMedia = baseAddr.add({{.startDownloadMedia}});
    downloadFileAddr = baseAddr.add({{.downloadFileAddr}});
    downloadVideoAddr = baseAddr.add({{.downloadVideoAddr}});

	sendMessageCallbackFunc = baseAddr.add(0x0);
	imgMessageCallbackFunc = baseAddr.add(0x0);
	videoMessageCallbackFunc = baseAddr.add(0x0);
    replyMessageCallbackFunc = baseAddr.add(0x0);
    voiceMessageCallbackFunc = baseAddr.add(0x0);

    setupRetOneStub();  // 必须同步先执行，初始化fakeVtable
    // R3 模式不注册任何发送 hook(避免 req2buf/StartTask/slot13 上的 JS 回调),
    // 只保留接收/媒体/下载链路。R3 的构造+提交完全在 triggerSend* 里同步完成。
    if (r3ModeActive) {
        console.log("[+] R3 原生发送模式: 跳过 req2buf/blrX8/StartTask/slot13-capture 等发送 hook");
        setImmediate(r3Init);
    } else {
        setImmediate(setupSendTextMessageDynamic);
        setImmediate(setupSendFileMessageDynamic);
        setImmediate(setupSendFileUploadMessageDynamic);
        setImmediate(setupSendAppAttachMessageDynamic);
        setImmediate(attachBlrX8Hook);
        setImmediate(attachAutoBufferPreWriteHook);   // task-5: 4.1.15 预写注入(方案 B)
        setImmediate(AttachSendFunc);
        setImmediate(attachReq2buf);
        setImmediate(attachSlot13Capture);
        setImmediate(setupSendImgMessageDynamic);
    }
    setImmediate(attachUploadMedia);
    setImmediate(patchCdnOnComplete);
    setImmediate(attachGetCallbackFromWrapper);
    if (!r3ModeActive) {
        setImmediate(setupSendReplyMessageDynamic);
    }
    setImmediate(setupDownloadFileDynamic);
    setImmediate(attachMessageFinalizer);
    setImmediate(contactSetupHooks);
    setImmediate(setReceiver);
}

// -------------------------基础函数分区-------------------------
function hexToByteArray(hexStr) {
    var bytes = [];
    for (var i = 0; i < hexStr.length; i += 2) {
        bytes.push(parseInt(hexStr.substr(i, 2), 16));
    }
    return bytes;
}

function patchString(addr, plainStr) {
    const bytes = [];
    for (let i = 0; i < plainStr.length; i++) {
        bytes.push(plainStr.charCodeAt(i));
    }

    addr.writeByteArray(bytes);
    addr.add(bytes.length).writeU8(0);
}

function generateAESKey() {
    const chars = 'abcdef0123456789';
    let key = '';
    for (let i = 0; i < 32; i++) {
        key += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return key;
}

const MAX_FRIDA_MESSAGE_BYTES = 4 * 1024 * 1024;

// 轻量可读性探测（2026-10-21 性能修复）。
// 不要改回 Process.findRangeByAddress：Frida 17 每次调用都会遍历进程内存映射
// (mach_vm_region_recurse) 并对命中区间查 proc_info(PROC_PIDREGIONPATHINFO)，
// 在微信这种数百 MB、上万 mapping 的进程里单次 20~50ms。Message finalizer 每条
// 消息要探测 10+ 个指针，历史回放（上滑聊天记录）时会把微信自己的消息线程按
// 「约 1 条/秒」拖住。这里直接试读 1 字节：非法地址由 Frida 转成可捕获异常，
// 调用方已有 try/catch 兜底；跨页/字符串长度越界仍由后续读取的 try/catch 处理。
function isReadablePointer(addr) {
    try {
        if (!addr || addr.isNull()) {
            return false;
        }
        addr.readU8();
        return true;
    } catch (e) {
        return false;
    }
}

function readPointerIfReadable(addr) {
    try {
        if (!isReadablePointer(addr)) {
            return ptr(0);
        }
        const value = addr.readPointer();
        if (!isReadablePointer(value)) {
            return ptr(0);
        }
        return value;
    } catch (e) {
        return ptr(0);
    }
}

function readUtf8StringIfReadable(addr) {
    try {
        if (!isReadablePointer(addr)) {
            return "";
        }
        return addr.readUtf8String();
    } catch (e) {
        return "";
    }
}

// libc++ std::string (24 bytes): byte[23] high bit = long; long => data ptr +0,
// size +8; short => inline bytes at +0, size in byte[23]. Returns null on failure.
function readStdStringCompat(addr, limit) {
    try {
        if (!isReadablePointer(addr)) return null;
        var sizeByte = addr.add(23).readU8();
        var dataPtr = addr;
        var size = sizeByte;
        if (sizeByte & 0x80) {
            dataPtr = addr.readPointer();
            size = addr.add(8).readU64().toNumber();
        }
        if (size < 0 || size > (limit || 65536)) return null;
        if (size === 0) return "";
        if (!isReadablePointer(dataPtr)) return null;
        var out = dataPtr.readUtf8String(size);
        return out === null ? "" : out;
    } catch (e) {
        return null;
    }
}

// 群 @ 目标列表：<msgsource><atuserlist>wxid_a,wxid_b</atuserlist></msgsource>。
// 不同客户端/版本可能写成 CDATA（<![CDATA[wxid_a,wxid_b]]>）或嵌套 <atuser> 标签，
// 这里统一剥壳后再按逗号/空白切分；保留非 wxid_ 目标（如 openim id）交给规则层精确比对。
function parseMentionList(msgSource) {
    var mentions = [];
    if (!msgSource || typeof msgSource !== "string") return mentions;
    var listRe = /<atuserlist>([\s\S]*?)<\/atuserlist>/g;
    var listMatch;
    while ((listMatch = listRe.exec(msgSource)) !== null) {
        var body = listMatch[1] || "";
        body = body.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1");
        body = body.replace(/<[^>]+>/g, ",");
        var parts = body.split(/[,;\s]+/);
        for (var i = 0; i < parts.length; i++) {
            var value = parts[i].trim();
            if (value && mentions.indexOf(value) < 0) mentions.push(value);
        }
    }
    return mentions;
}

// 微信群 ID 契约：一律以 @chatroom 结尾（大小写不敏感）。hook 侧判群和清洗
// 拍一拍 <chatusername> 都用它：私聊时该字段是 wxid，直接当群 ID 会为好友
// 伪造出一个「群」会话（2026-10-21 修复）。
function isChatroomID(value) {
    if (!value || typeof value !== "string") return false;
    return /@chatroom$/i.test(value);
}

// 微信「拍一拍」在 4.1.15 以 appmsg（type=49，appmsg/type=62）下发，正文在 <title> 里。
// 提取标题后作为消息文本，聊天列表/规则引擎都能直接看到「拍了拍」。
function extractWeChatPatTitle(content) {
    if (!content || typeof content !== "string") return null;
    if (content.indexOf("拍了拍") < 0 &&
        content.indexOf("patted") < 0 &&
        content.indexOf("<type>62</type>") < 0) {
        return null;
    }
    var match = content.match(/<title>([\s\S]*?)<\/title>/);
    if (!match || !match[1]) return null;
    var title = decodeXmlText(match[1]);
    return title.length > 0 ? title : null;
}

function decodeXmlText(value) {
    if (!value) return "";
    return String(value)
        .replace(/&lt;/g, "<")
        .replace(/&gt;/g, ">")
        .replace(/&quot;/g, '"')
        .replace(/&apos;/g, "'")
        .replace(/&amp;/g, "&");
}

// 从 appmsg/patinfo（4.1.15）或 sysmsg/pat（4.1.12 及更早）解析「谁拍了谁」。
// 规则层必须用 target_wxid 判断是否拍的是机器人：只看标题里的「拍了拍」会把
// 群里拍别人的消息也当成唤醒（2026-10-21 修复）。
function extractWeChatPatInfo(content) {
    if (!content || typeof content !== "string") return null;
    var block = null;
    var infoMatch = content.match(/<patinfo>([\s\S]*?)<\/patinfo>/i);
    if (infoMatch) {
        block = infoMatch[1];
    } else {
        var patMatch = content.match(/<pat>([\s\S]*?)<\/pat>/i) ||
            content.match(/<patmsg>([\s\S]*?)<\/patmsg>/i);
        if (patMatch) block = patMatch[1];
    }
    if (!block) return null;
    function pick(name) {
        var match = block.match(new RegExp("<" + name + "[^>]*>([\\s\\S]*?)</" + name + ">", "i"));
        return match && match[1] ? decodeXmlText(match[1]).trim() : "";
    }
    var target = pick("pattedusername");
    if (!target) return null;
    return {
        from_wxid: pick("fromusername"),
        chat_wxid: pick("chatusername"),
        target_wxid: target,
        suffix: pick("patsuffix"),
        template: pick("template")
    };
}

function attachMessageFinalizer() {
    if (!messageFinalizerEnabled) {
        console.log("[!] 入站消息接收: messageFinalizer 未配置, 跳过");
        return;
    }
    try {
        var finalizerPtr = baseAddr.add(parseInt(messageFinalizerAddr, 16));
        var expectedVtable = null;
        try { expectedVtable = baseAddr.add(parseInt(messageVtableAddr, 16)); } catch (e) { expectedVtable = null; }
        console.log("[+] 入站消息接收: hook Message finalizer @ " + finalizerPtr +
            " (layout=" + req2bufLayout + ", vtable=" + messageVtableAddr + ")");
        Interceptor.attach(finalizerPtr, {
            onEnter: function (args) {
                try {
                    var mode = this.context.x1.toInt32();
                    if (mode !== 1) return;
                    var obj = this.context.x0;
                    if (!isReadablePointer(obj)) return;
                    // 定长字段先读并按 serverId 去重：历史回放时同一条消息可能被重复
                    // finalize，重复命中直接返回，不再做字符串拷贝/正则/JSON。
                    var type = obj.add(0x0c).readU32();
                    var created = obj.add(0x114).readU32();
                    var serverId = obj.add(0xf8).readU64().toString();
                    if (serverId !== "0" && incomingMessageSeen[serverId]) return;
                    var from = readStdStringCompat(obj.add(0x18), 256);
                    var to = readStdStringCompat(obj.add(0x30), 256);
                    var content = readStdStringCompat(obj.add(0x130), 4 * 1024 * 1024);
                    if (from === null || to === null || content === null) return;
                    if (!from || !to) return;
                    if (serverId !== "0") incomingMessageSeen[serverId] = true;
                    var group = "";
                    var user = from;
                    var text = content;
                    var nickname = from;
                    var member = "";
                    var msgSource = "";
                    var mentions = [];
                    // 普通消息不做 patinfo 正则；4.1.15 拍一拍是 type=49，旧版 sysmsg
                    // 则含 patinfo/pattedusername 标记。用轻量 indexOf 先筛。
                    var patInfo = null;
                    if (type === 49 || content.indexOf("patinfo") >= 0 ||
                        content.indexOf("pattedusername") >= 0 || content.indexOf("patmsg") >= 0) {
                        patInfo = extractWeChatPatInfo(content);
                    }
                    // 判群：from 或 to 任一以 @chatroom 结尾。入站群消息 from=群；
                    // 自己发出的群消息 from=自己、to=群。只有 from 是群时才需要读
                    // 群成员/正文前缀；仅 to 是群时只置 group，不做成员解析。
                    if (isChatroomID(from)) {
                        // 群消息的真实发送者 wxid 在 +0x48；@ 目标列表在 +0x160 的
                        // <atuserlist>。私聊不需要这两次字符串读取（历史回放时省开销）。
                        member = readStdStringCompat(obj.add(0x48), 256) || "";
                        msgSource = readStdStringCompat(obj.add(0x160), 64 * 1024) || "";
                        mentions = parseMentionList(msgSource);
                        group = from;
                        if (member.indexOf("wxid_") === 0) user = member;
                        var prefixes = [user + ": ", user + ":\n"];
                        var stripped = false;
                        for (var pi = 0; pi < prefixes.length; pi++) {
                            if (content.indexOf(prefixes[pi]) === 0) {
                                text = content.substring(prefixes[pi].length);
                                stripped = true;
                                break;
                            }
                        }
                        if (!stripped) {
                            var split = content.indexOf(":\n");
                            if (split > 0 && split < 200) {
                                user = content.substring(0, split);
                                text = content.substring(split + 2);
                                nickname = user;
                            }
                        }
                        if (!nickname || nickname === from) nickname = user;
                    } else if (isChatroomID(to)) {
                        // 自己发出的群消息：from=自己、to=群；不能按私聊处理，
                        // 否则会被归进「自己 wxid」的会话（2026-10-21 修复）。
                        group = to;
                    }
                    // 拍一拍 appmsg 的 from/to 可能是群 ID（群内拍人），也可能是
                    // 私聊双方的 wxid。真实拍人者/被拍者在 <patinfo> 里，优先采用，
                    // 供 App 判定「是否拍的是机器人」。
                    if (patInfo) {
                        if (patInfo.from_wxid && patInfo.from_wxid.indexOf("wxid_") === 0) {
                            user = patInfo.from_wxid;
                            if (!member) member = user;
                            nickname = user;
                        }
                        // 只有 <chatusername> 是合法群 ID 时才当群：私聊拍一拍里它是
                        // wxid，旧逻辑会据此伪造群会话（2026-10-21 修复）。
                        if (!group && isChatroomID(patInfo.chat_wxid)) group = patInfo.chat_wxid;
                    }
                    var shown = text;
                    if (type === 3) shown = "[图片]";
                    else if (type === 34) shown = "[语音]";
                    else if (type === 43) shown = "[视频]";
                    else if (type === 47) shown = "[表情]";
                    else if (type === 49) {
                        var patTitle = extractWeChatPatTitle(content);
                        shown = patTitle ? patTitle : "[链接/文件]";
                    }
                    if (msgSource.indexOf("<atuserlist>") >= 0 && mentions.length === 0) {
                        console.log("[!] atuserlist 非空但未解析出目标: " + msgSource.substring(0, 240));
                    }
                    // 逐条日志在历史回放时每条会多一次 Frida IPC，默认关闭（HOOK_DEBUG=1 打开）。
                    hookDebug("[+] incoming message: type=" + type + " from=" + from +
                        " group=" + group + " len=" + text.length + " id=" + serverId +
                        " mentions=" + mentions.length);
                    var payload = {
                        // self_id 仅作为兜底；bridge 会用当前账号把它改写成
                        // 「自己」，并结合 from/to/sender_wxid 判定 is_self。
                        self_id: to,
                        user_id: user,
                        group_id: group,
                        from_wxid: from,
                        to_wxid: to,
                        sender_wxid: user,
                        member_wxid: member,
                        sender: { user_id: user, nickname: nickname },
                        time: created * 1000,
                        post_type: "message",
                        message_id: serverId,
                        message: [{ type: "text", data: { text: shown } }].concat(mentions.map(function (wxid) {
                            return { type: "at", data: { qq: wxid } };
                        })),
                        mentions: mentions,
                        raw_message: text,
                        show_content: shown,
                        message_type: group ? "group" : "private",
                        msg_type: type
                    };
                    if (patInfo) {
                        payload.pat_from_wxid = patInfo.from_wxid || user;
                        // 契约：pat_chat_wxid 是群 ID（私聊为空），与 group 保持一致。
                        payload.pat_chat_wxid = group;
                        payload.pat_target_wxid = patInfo.target_wxid;
                        if (patInfo.suffix) payload.pat_suffix = patInfo.suffix;
                        if (patInfo.template) payload.pat_template = patInfo.template;
                    }
                    send({ type: "incoming_message", payload: payload });
                } catch (e) {
                    console.log("[!] incoming message parse error: " + e);
                }
            }
        });
    } catch (e) {
        console.error("[!] Message finalizer hook failed: " + e);
    }
}

function readByteArrayIfReadable(addr, len) {
    try {
        if (len <= 0 || !isReadablePointer(addr)) {
            return null;
        }
        return addr.readByteArray(len);
    } catch (e) {
        return null;
    }
}

function sendDownloadChunks(dataPtr, dataLen, fileId, cdnUrl) {
    if (!cdnUrl || dataLen <= 0) {
        return;
    }

	if (dataLen > 0 && dataLen <= 10 * 1024 * 1024) {
		var buffer = dataPtr.readByteArray(dataLen);
		var uint8Array = new Uint8Array(buffer);

		send({
			type: "download",
			media: Array.from(uint8Array),
			file_id: fileId,
			cdn_url: cdnUrl,
		})
	}
}

// mars::cdn::CdnManager 单例解析: 上传(uploadGlobalX0)/下载(downloadGlobalX0)共用的 this。
// 2026-09-02 静态分析 4.1.10: 上传/下载分发链(0x4e5a6e4/0x4e5a7f4)都走
// GetService("default")[0x4ca2130] -> 按类型名 "N4mars3cdn10CdnManagerE" getter[0x4e59dec]
// -> [ctx+0x40]。该单例登录后即注册进全局服务表, 不需要先发一张图片触发。
// ⚠️ 2026-09-03 事故教训: 登录未完成时服务表锁被登录流程持有, 此时在 Frida 线程调
// GetService 会与微信主线程死锁, 微信整个冻结。因此必须有"登录稳定门禁":
// 只在 (收到过任意同步消息 = 确已登录) 或 (脚本已跑 60s) 之后才允许解析。
var scriptLoadTime = Date.now();
var incomingTrafficSeen = false;
function loginSettled() {
    if (incomingTrafficSeen) return true;
    if (Date.now() - scriptLoadTime > 60 * 1000) return true;
    return false;
}
function resolveCdnManager() {
    if (cdnGetServiceAddr.equals(ptr(0)) || cdnManagerGetterAddr.equals(ptr(0))) {
        return ptr(0);
    }
    if (!loginSettled()) {
        console.log("[!] 登录尚未稳定, 暂缓 CdnManager 解析(防死锁), 稍后任务重试");
        return ptr(0);
    }
    try {
        // libc++ SSO 短字符串: 数据在 +0, 长度写在 +0x17 (对照 wechat.dylib std::string ctor)
        var strDefault = Memory.alloc(24);
        strDefault.writeUtf8String("default");
        strDefault.add(0x17).writeU8(7);

        var getService = new NativeFunction(cdnGetServiceAddr, 'pointer', ['pointer']);
        var svc = getService(strDefault);
        if (!isReadablePointer(svc)) {
            console.error("[!] GetService(\"default\") 返回不可读: " + svc);
            return ptr(0);
        }
        var getCtx = new NativeFunction(cdnManagerGetterAddr, 'pointer', ['pointer']);
        var ctx = getCtx(svc);
        if (!isReadablePointer(ctx)) {
            console.error("[!] CdnManager getter 返回不可读: " + ctx);
            return ptr(0);
        }
        var mgr = readPointerIfReadable(ctx.add(0x40));
        if (!isReadablePointer(mgr)) {
            console.error("[!] ctx+0x40 管理器指针不可读: ctx=" + ctx);
            return ptr(0);
        }
        return mgr;
    } catch (e) {
        console.error("[!] resolveCdnManager 异常: " + e);
        return ptr(0);
    }
}

// CdnManager 兜底: 1) hook 已捕获的互回填(同一单例) 2) 都没有则走服务定位器解析
function ensureCdnManagerX0() {
    if (uploadGlobalX0.equals(ptr(0)) && downloadGlobalX0) {
        uploadGlobalX0 = downloadGlobalX0;
        console.log("[+] downloadGlobalX0 回填 uploadGlobalX0: " + uploadGlobalX0);
    }
    if (!downloadGlobalX0 && !uploadGlobalX0.equals(ptr(0))) {
        downloadGlobalX0 = uploadGlobalX0;
        console.log("[+] uploadGlobalX0 回填 downloadGlobalX0: " + downloadGlobalX0);
    }
    if (uploadGlobalX0.equals(ptr(0))) {
        var mgr = resolveCdnManager();
        if (!mgr.equals(ptr(0))) {
            uploadGlobalX0 = mgr;
            if (!downloadGlobalX0) {
                downloadGlobalX0 = mgr;
            }
            console.log("[+] 冷启动服务定位器解析 CdnManager: " + mgr);
        }
    }
    return !uploadGlobalX0.equals(ptr(0));
}

function fillUploadX1AndStart(idAddr, pathAddr, x1Buffer, receiver, md5, filePath, payloadHex) {
    if (uploadGlobalX0.equals(ptr(0))) {
        ensureCdnManagerX0();
    }
    if (uploadGlobalX0.equals(ptr(0))) {
        console.error("[!] uploadGlobalX0 尚未初始化，请等待 hook 捕获");
        return "fail";
    }

    const payload = hexToByteArray(payloadHex);
    patchString(idAddr, receiver + "_" + String(Math.floor(Date.now() / 1000)) + "_" + Math.floor(Math.random() * 1001) + "_1");
    patchString(md5Addr, md5);
    patchString(uploadAesKeyAddr, generateAESKey());
    patchString(pathAddr, filePath);

    x1Buffer.writeByteArray(payload);
    x1Buffer.writePointer(uploadFunc1Addr);
    x1Buffer.add(0x08).writePointer(uploadFunc2Addr);
    x1Buffer.add(0x48).writePointer(idAddr);
    x1Buffer.add(0x68).writeUtf8String(receiver);
    x1Buffer.add(0xa8).writePointer(md5Addr);
    x1Buffer.add(0xe8).writePointer(pathAddr);
    x1Buffer.add(0x118).writePointer(pathAddr);
    x1Buffer.add(0x148).writePointer(pathAddr);
    x1Buffer.add(0x200).writePointer(uploadAesKeyAddr);

    const startUploadMedia = new NativeFunction(uploadImageAddr, 'int64', ['pointer', 'pointer']);
    return startUploadMedia(uploadGlobalX0, x1Buffer);
}

// -------------------------基础函数分区-------------------------

// -------------------------全局变量分区-------------------------

// 文本消息全局变量 (new_text.js approach)
var blrX8Addr;
var autoBufferWriteFunc;
var textCgiAddr = ptr(0);
var sendTextMessageAddr = ptr(0);
var textMessageAddr = ptr(0);
var sendMessageCallbackFunc;
var retOneStub = ptr(0);
var fakeVtable = ptr(0);
// 等待buf2resp的任务表: taskId -> { addr, msgType, timerId }
// 支持多任务并存 + 超时兜底: ack迟迟不来时提前清零 X24+0x60, 避免mars
// 回收死任务时对伪造结构体做虚调用/delete导致SIGSEGV (2026-08-17 crash)
var pendingBuf2RespTasks = {};
// 正常ack在1s内返回; 3s未回视为失败。必须赶在mars短链CGI失败窗口(~5s)之前
// 复原原始指针: 8/20崩溃即任务无ack, ~5s失败回调在协程线程erase任务map时踩坏
// 节点, 10s兜底来不及。original指针本就是sendFunc构造的合法消息, 提前复原=
// 回到原生行为; 迟到ack仍能命中(entry保留30s), 只是entry.addr已空不再清理
var PENDING_CLEANUP_TIMEOUT_MS = 3 * 1000;
var textProtoDataAddr = ptr(0);


// 双方公共使用的地址
var triggerX1Payload;
var triggerTaskSnapshot = null;
var triggerX0;
var req2bufEnterAddr;
var req2bufExitAddr;
var sendFuncAddr;
var insertMsgAddr = ptr(0);
var originalInsertMsgPtr = ptr(0);  // hook前X24+0x60的原始消息指针, 超时兜底时复原
var sendMsgType = "";
var buf2RespAddr;

var uploadImageAddr;
var cdnGetServiceAddr = ptr(0);      // GetService(std::string) 服务定位器, 冷启动解析 CdnManager 用
var cdnManagerGetterAddr = ptr(0);   // 按类型名 "N4mars3cdn10CdnManagerE" 取 ctx 的 getter
var cndOnCompleteAddr;
var imgMessageCallbackFunc;
var videoMessageCallbackFunc;

var uploadGetCallbackWrapperAddr;
var uploadGetCallbackWrapperFuncAddr;
var uploadOnCompleteAddr;
var uploadOnCompleteFuncAddr;
var downloadImagAddr;
var startDownloadMedia;
var downloadFileAddr;
var downloadVideoAddr;

var downloadGlobalX0;
var downloadFileX1 = ptr(0)
var fileIdAddr = ptr(0)
var downloadAesKeyAddr = ptr(0)
var filePathAddr = ptr(0)
var fileCdnUrlAddr = ptr(0)
var uploadImageX1 = ptr(0);
var imgCgiAddr = ptr(0);
var sendImgMessageAddr = ptr(0);
var imgMessageAddr = ptr(0);
var uploadGlobalX0 = ptr(0)
var uploadFunc1Addr = ptr(0)
var uploadFunc2Addr = ptr(0)
var imageIdAddr = ptr(0)
var md5Addr = ptr(0)
var uploadAesKeyAddr = ptr(0)
var ImagePathAddr1 = ptr(0)
var uploadCallback = ptr(0)

var videoCgiAddr = ptr(0);
var sendVideoMessageAddr = ptr(0);
var videoMessageAddr = ptr(0);
var uploadVideoX1 = ptr(0);
var videoIdAddr = ptr(0);
var videoPathAddr1 = ptr(0)

// 语音消息全局变量
var voiceMessageCallbackFunc;
var voiceCgiAddr = ptr(0);
var sendVoiceMessageAddr = ptr(0);
var voiceMessageAddr = ptr(0);
var uploadVoiceX1 = ptr(0);
var voiceIdAddr = ptr(0);
var voicePathAddr1 = ptr(0);
var voiceProtoHexGlobal = "";
var voiceDurationGlobal = 0;
var voiceSilkDataLenGlobal = 0;
var voiceAudioDataAddr = ptr(0);


// 发送消息的全局变量
var taskIdGlobal = 0x20000090 // 最好比较大，不和原始的微信消息重复

// 文本消息protobuf全局变量 (从Go直接传入hex编码)
var textProtoHexGlobal = "";
// 图片消息protobuf全局变量 (从Go直接传入hex编码)
var imgProtoHexGlobal = "";
// 视频消息protobuf全局变量 (从Go直接传入hex编码)
var videoProtoHexGlobal = "";
// 回复消息protobuf全局变量 (从Go直接传入hex编码)
var replyProtoHexGlobal = "";
// 拍一拍 appmsg protobuf全局变量 (从Go直接传入hex编码)
var patProtoHexGlobal = "";
// 文件消息protobuf全局变量 (从Go直接传入hex编码)
var fileProtoHexGlobal = "";
var fileUploadProtoHexGlobal = "";
// uploadappattach protobuf全局变量 (从Go直接传入hex编码)
var appAttachProtoHexGlobal = "";

// 文件消息全局变量
var fileCgiAddr = ptr(0);
var sendFileMessageAddr = ptr(0);
var fileMessageAddr = ptr(0);
var uploadFileIdAddr = ptr(0);
var uploadFileX1 = ptr(0);

// sendfileuploadmsg 全局变量
var fileUploadCgiAddr = ptr(0);
var sendFileUploadMessageAddr = ptr(0);
var fileUploadMessageAddr = ptr(0);

// uploadappattach 全局变量
var appAttachCgiAddr = ptr(0);
var sendAppAttachMessageAddr = ptr(0);
var appAttachMessageAddr = ptr(0);

// 回复消息全局变量
var replyMessageCallbackFunc;
var replyCgiAddr = ptr(0);
var sendReplyMessageAddr = ptr(0);
var replyMessageAddr = ptr(0);

// -------------------------全局变量分区-------------------------


// -------------------------发送文本消息分区-------------------------
// 初始化进行内存的分配
function setupSendTextMessageDynamic() {
    // 动态分配内存

    textCgiAddr = Memory.alloc(128);
    sendTextMessageAddr = Memory.alloc(256);
    textMessageAddr = Memory.alloc(256);
    textProtoDataAddr = Memory.alloc(64 * 1024); // 支持 50KB 分片(uploadappattach)的 protobuf

    // A. 写入字符串内容
    patchString(textCgiAddr, "/cgi-bin/micromsg-bin/newsendmsg");

    // B. 构建 sendTextMessageAddr 结构体 (X24 基址位置)
    sendTextMessageAddr.add(0x00).writeU64(0);
    sendTextMessageAddr.add(0x08).writeU64(0);
    sendTextMessageAddr.add(0x10).writeU64(0);
    sendTextMessageAddr.add(0x18).writeU64(1);
    sendTextMessageAddr.add(0x20).writeU32(taskIdGlobal);
    sendTextMessageAddr.add(0x28).writePointer(textMessageAddr);

    // C. 构建 Message 结构体
    textMessageAddr.add(0x00).writePointer(fakeVtable);
    textMessageAddr.add(0x08).writeU32(taskIdGlobal);
    textMessageAddr.add(0x0c).writeU32(0x20a);
    textMessageAddr.add(0x10).writeU64(0x3);
    textMessageAddr.add(0x18).writePointer(textCgiAddr);
    textMessageAddr.add(0x20).writeU64(uint64("0x20"));

    console.log("[+] Dynamic Text Message Setup Complete.");
}


// -------------------------发送文件消息分区-------------------------
function setupSendFileMessageDynamic() {
    fileCgiAddr = Memory.alloc(128);
    sendFileMessageAddr = Memory.alloc(256);
    fileMessageAddr = Memory.alloc(256);
    uploadFileIdAddr = Memory.alloc(128);
    uploadFileX1 = Memory.alloc(1024);
    patchString(uploadFileIdAddr, "file_upload_not_init");

    patchString(fileCgiAddr, "/cgi-bin/micromsg-bin/sendappmsg");

    sendFileMessageAddr.add(0x00).writeU64(0);
    sendFileMessageAddr.add(0x08).writeU64(0);
    sendFileMessageAddr.add(0x10).writeU64(0);
    sendFileMessageAddr.add(0x18).writeU64(1);
    sendFileMessageAddr.add(0x20).writeU32(taskIdGlobal);
    sendFileMessageAddr.add(0x28).writePointer(fileMessageAddr);

    fileMessageAddr.add(0x00).writePointer(fakeVtable);
    fileMessageAddr.add(0x08).writeU32(taskIdGlobal);
    fileMessageAddr.add(0x0c).writeU32(0x6e);
    fileMessageAddr.add(0x10).writeU64(0x3);
    fileMessageAddr.add(0x18).writePointer(fileCgiAddr);
    fileMessageAddr.add(0x20).writeU64(0x20);
    fileMessageAddr.add(0x28).writeU64(uint64("0x8000000000000030"));
    fileMessageAddr.add(0x30).writeU64(uint64("0x0000000001010100"));
}

function triggerSendFileMessage(taskId, sender, receiver, protoHex, payloadHex) {
    return triggerSendMediaMessage(taskId, sender, receiver, protoHex, payloadHex, "file");
}

function triggerUploadFile(receiver, md5, filePath, payloadHex) {
    return fillUploadX1AndStart(uploadFileIdAddr, ImagePathAddr1, uploadFileX1, receiver, md5, filePath, payloadHex);
}

// -------------------------sendfileuploadmsg分区-------------------------
function setupSendFileUploadMessageDynamic() {
    fileUploadCgiAddr = Memory.alloc(128);
    sendFileUploadMessageAddr = Memory.alloc(256);
    fileUploadMessageAddr = Memory.alloc(256);

    patchString(fileUploadCgiAddr, "/cgi-bin/micromsg-bin/sendfileuploadmsg");

    sendFileUploadMessageAddr.add(0x00).writeU64(0);
    sendFileUploadMessageAddr.add(0x08).writeU64(0);
    sendFileUploadMessageAddr.add(0x10).writeU64(0);
    sendFileUploadMessageAddr.add(0x18).writeU64(1);
    sendFileUploadMessageAddr.add(0x20).writeU32(taskIdGlobal);
    sendFileUploadMessageAddr.add(0x28).writePointer(fileUploadMessageAddr);

    fileUploadMessageAddr.add(0x00).writePointer(fakeVtable);
    fileUploadMessageAddr.add(0x08).writeU32(taskIdGlobal);
    fileUploadMessageAddr.add(0x0c).writeU32(0x6e);
    fileUploadMessageAddr.add(0x10).writeU64(0x3);
    fileUploadMessageAddr.add(0x18).writePointer(fileUploadCgiAddr);
    fileUploadMessageAddr.add(0x20).writeU64(0x20);
    fileUploadMessageAddr.add(0x28).writeU64(uint64("0x8000000000000030"));
    fileUploadMessageAddr.add(0x30).writeU64(uint64("0x0000000001010100"));
}

function triggerSendFileUploadMessage(taskId, sender, receiver, protoHex, payloadHex) {
    return triggerSendMediaMessage(taskId, sender, receiver, protoHex, payloadHex, "fileupload");
}

// -------------------------uploadappattach分区-------------------------
function setupSendAppAttachMessageDynamic() {
    appAttachCgiAddr = Memory.alloc(128);
    sendAppAttachMessageAddr = Memory.alloc(256);
    appAttachMessageAddr = Memory.alloc(256);

    patchString(appAttachCgiAddr, "/cgi-bin/micromsg-bin/uploadappattach");

    sendAppAttachMessageAddr.add(0x00).writeU64(0);
    sendAppAttachMessageAddr.add(0x08).writeU64(0);
    sendAppAttachMessageAddr.add(0x10).writeU64(0);
    sendAppAttachMessageAddr.add(0x18).writeU64(1);
    sendAppAttachMessageAddr.add(0x20).writeU32(taskIdGlobal);
    sendAppAttachMessageAddr.add(0x28).writePointer(appAttachMessageAddr);

    appAttachMessageAddr.add(0x00).writePointer(fakeVtable);
    appAttachMessageAddr.add(0x08).writeU32(taskIdGlobal);
    appAttachMessageAddr.add(0x0c).writeU32(0x6e);
    appAttachMessageAddr.add(0x10).writeU64(0x3);
    appAttachMessageAddr.add(0x18).writePointer(appAttachCgiAddr);
    appAttachMessageAddr.add(0x20).writeU64(0x25);
    appAttachMessageAddr.add(0x28).writeU64(uint64("0x8000000000000030"));
    appAttachMessageAddr.add(0x30).writeU64(uint64("0x0000000001010100"));
}

function triggerUploadAppAttach(taskId, sender, receiver, protoHex, payloadHex) {
    return triggerSendMediaMessage(taskId, sender, receiver, protoHex, payloadHex, "appattach");
}

// -------------------------发送文件消息分区-------------------------



// 创建一个只返回1的小函数stub
function setupRetOneStub() {
    retOneStub = Memory.alloc(Process.pageSize);
    Memory.patchCode(retOneStub, 8, code => {
        // MOV W0, #1 = 0x52800020, RET = 0xD65F03C0 (little-endian)
        code.writeByteArray([0x20, 0x00, 0x80, 0x52, 0xC0, 0x03, 0x5F, 0xD6]);
    });
    console.log("[+] Return-1 stub created at: " + retOneStub);

    // 构造假vtable：所有槽位指向retOneStub，这样mars对我们伪造结构做虚调用时不会崩溃
    fakeVtable = Memory.alloc(512);
    for (var i = 0; i < 64; i++) {
        fakeVtable.add(i * 8).writePointer(retOneStub);
    }
    console.log("[+] Fake vtable created at: " + fakeVtable);
}

// -------------------------task-5: autoBuffer 注入辅助-------------------------
// 4.1.15 AutoBuffer 结构: [autoBuffer] -> ctrl; ctrl+0x00=数据指针, ctrl+0xc=已用长度。
// autoBufferWriteFunc(0x4659f18) 的写入逻辑: reserve(len) -> memcpy(ctrl->data + ctrl->len, src, len)
// -> ctrl->len += len。因此把 ctrl+0xc 清零即可覆盖 mars 预写的前缀串。
function injectPayloadIntoAutoBuffer(nativeAutoBufferWrite, autoBuffer, protoHex, self) {
    var finalPayload = hexToByteArray(protoHex);
    textProtoDataAddr.writeByteArray(finalPayload);
    if (isReq2bufLayout415) {
        try {
            var ctrl = autoBuffer.readPointer();
            if (!ctrl.isNull()) {
                var oldLen = ctrl.add(0xc).readU32();
                ctrl.add(0xc).writeU32(0);
                hookDebug("planA: 清空 autoBuffer 前缀, oldLen=" + oldLen + " ctrl=" + ctrl);
            }
        } catch (e) {
            console.error("[!] 清空 autoBuffer 失败: " + e);
        }
    }
    nativeAutoBufferWrite(autoBuffer, textProtoDataAddr, finalPayload.length);
    var m = req2bufGetThreadMark(self);
    if (m) {
        m.preWriteDone = true;
        m.preWriteLen = finalPayload.length;
    }
    hookDebug("autoBufferWrite 注入 " + finalPayload.length + "B, autoBuffer=" + autoBuffer);
    return finalPayload.length;
}

// 方案 B: 4.1.15 在 0x46362f4 处先 bl autoBufferWriteFunc 把 [sp+0x30] 的前缀串写进
// autoBuffer(sp+0x50), 之后才取 vtable+0x18 虚调用。此处用 returnAddress==0x46362f8
// 精确识别该调用点, 把 (x1=src, x2=len) 换成本进程 protobuf; blrX8 hook 只 stub。
function attachAutoBufferPreWriteHook() {
    if (!sendPathEnabled) {
        hookDebug("发送已关闭, 跳过预写 hook (mode=" + REQ2BUF_SEND_MODE + ")");
        return;
    }
    if (r3ModeActive) {
        hookDebug("R3 模式: 跳过预写 hook (发送由 slot13 原生提交)");
        return;
    }
    if (REQ2BUF_SEND_MODE === "cgi") {
        hookDebug("CGI 模式: 由 slot13/CGI task 直接编码, 跳过预写 hook");
        return;
    }
    if (!isReq2bufLayout415 || REQ2BUF_PREWRITE_MODE !== "B") {
        hookDebug("跳过预写 hook (layout=" + req2bufLayout + ", mode=" + REQ2BUF_PREWRITE_MODE + ")");
        return;
    }
    req2bufPreWriteRetAddr = baseAddr.add(L415.autoBufferPreWriteRet);
    console.log("[+] 4.1.15 预写注入(plan B): hook autoBufferWriteFunc=" + autoBufferWriteFunc +
        " 调用点 ret=" + req2bufPreWriteRetAddr);

    Interceptor.attach(autoBufferWriteFunc, {
        onEnter: function (args) {
            if (!this.returnAddress.equals(req2bufPreWriteRetAddr)) {
                return;
            }
            var m = req2bufGetThreadMark(this);
            if (!m) {
                // 调用点命中但没有本线程标记: 可能不是我们触发的任务, 不要动数据
                hookDebug("预写调用点命中但无本线程标记, 跳过 (autoBuffer=" + this.context.x0 + ")");
                return;
            }
            var protoHex = selectProtoHexForSend();
            if (!protoHex || protoHex.length === 0) {
                console.error("[!] 4.1.15 预写: protoHex 为空, sendMsgType=" + sendMsgType);
                return;
            }
            var finalPayload = hexToByteArray(protoHex);
            textProtoDataAddr.writeByteArray(finalPayload);
            var oldLen = this.context.x2.toInt32();
            var oldData = this.context.x1;
            this.context.x1 = textProtoDataAddr;
            this.context.x2 = ptr(finalPayload.length);
            m.preWriteDone = true;
            m.preWriteLen = finalPayload.length;
            hookDebug("planB 预写替换: ret=" + this.returnAddress + " autoBuffer=" + this.context.x0 +
                " oldData=" + oldData + " oldLen=" + oldLen + " newLen=" + finalPayload.length);
        }
    });
}

function attachBlrX8Hook() {
    if (!sendPathEnabled) {
        console.log("[!] 主动发送已关闭 (REQ2BUF_SEND_MODE=off): 跳过 BLR X8 hook; 接收链路不受影响");
        return;
    }
    if (r3ModeActive) {
        console.log("[+] R3 模式: 不注册 BLR X8 hook (发送由 slot13 原生提交)");
        return;
    }
    if (REQ2BUF_SEND_MODE === "cgi") {
        console.log("[+] CGI 模式: 不注册 BLR X8 hook (编码由 slot13 CGI task 负责)");
        return;
    }
    console.log("[+] Hooking BLR X8 at: " + blrX8Addr +
        " (layout=" + req2bufLayout + ", sendMode=" + REQ2BUF_SEND_MODE +
        ", prewrite=" + (isReq2bufLayout415 ? REQ2BUF_PREWRITE_MODE : "legacy") + ")");

    var nativeAutoBufferWrite = new NativeFunction(autoBufferWriteFunc, 'int', ['pointer', 'pointer', 'int']);

    Interceptor.attach(blrX8Addr, {
        onEnter: function(args) {
            var currentTaskId;
            if (isReq2bufLayout415) {
                // 4.1.15: taskId 在 x23(旧版 x20); x1 仍是 autoBuffer(sp+0x50)
                currentTaskId = this.context.x23.toUInt32();
            } else {
                currentTaskId = this.context.x20.toUInt32();
            }
            if (currentTaskId !== taskIdGlobal) {
                hookDebug("blrX8 跳过: taskId_reg=" + currentTaskId + " expect=" + taskIdGlobal);
                return;
            }

            console.log("[+] BLR X8 命中! taskId=" + currentTaskId + " sendMsgType=" + sendMsgType +
                (isReq2bufLayout415 ? " [4.1.15]" : ""));
            hookDebug("blrX8: x1(autoBuffer)=" + this.context.x1 + " x8(vtable fn)=" + this.context.x8 +
                " x23=" + this.context.x23 + " retAddr=" + this.returnAddress);

            var autoBuffer = this.context.x1;
            var protoHex = selectProtoHexForSend();

            if (!protoHex || protoHex.length === 0) {
                console.error("[!] protoHex 为空, sendMsgType=" + sendMsgType);
                return;
            }

            if (isReq2bufLayout415 && REQ2BUF_PREWRITE_MODE === "B") {
                var mark = req2bufGetThreadMark(this);
                if (mark && mark.preWriteDone) {
                    hookDebug("planB: 预写已完成(" + mark.preWriteLen + "B), 仅 stub 虚调用");
                } else {
                    // 兜底: 预写调用点没命中(版本偏移不符/分支未走)时退回方案 A
                    console.error("[!] 4.1.15 预写未命中, 回退 plan A 注入 (sendMsgType=" + sendMsgType + ")");
                    injectPayloadIntoAutoBuffer(nativeAutoBufferWrite, autoBuffer, protoHex, this);
                }
                this.context.x8 = retOneStub;
                return;
            }

            // 旧版 / 4.1.15 方案 A: 直写我们的 protobuf 后 stub 虚调用
            injectPayloadIntoAutoBuffer(nativeAutoBufferWrite, autoBuffer, protoHex, this);
            this.context.x8 = retOneStub;
        }
    });
}


function triggerSendTextMessage(taskId, receiver, content, atUser, protoHex, payloadHex) {
    return triggerSendMediaMessage(taskId, "", receiver, protoHex, payloadHex, "text");
}

function AttachSendFunc() {
    if (r3ModeActive) {
        console.log("[+] R3 模式: 不注册 StartTask(sendFunc+0x10) hook");
        return;
    }
    Interceptor.attach(sendFuncAddr.add(0x10), {
        onEnter: function (args) {

            // 每次都刷新捕获(upstream 只抓第一次): 保证 payload 指向最近的任务,
            // 并快照完整任务结构(入口时任务已完整构造, 含回调子对象);
            // 注入前整块恢复, 避免复用 free 后残骸里的野回调指针(4.1.12 崩溃根因)
            triggerX0 = this.context.x0;
            triggerX1Payload = this.context.x1;
            try {
                triggerTaskSnapshot = triggerX1Payload.readByteArray(0x300);
            } catch (e) {
                console.log("[-] 任务快照失败: " + e);
            }
            console.log(`[+] 捕获到 StartTask 调用，X0：${triggerX0}, Payload: ${triggerX1Payload}`);
        }
    })
}


// -------------------------发送文本消息分区-------------------------


// -------------------------buf2resp超时兜底分区-------------------------
// req2bufExit后登记待ack任务: 命中buf2resp时清理指针并取消timer;
// 超时未命中则复原X24+0x60的原始指针(而不是清零/留着伪造结构体),
// 任务回到未注入的合法状态, mars无论重试重序列化还是超时回收delete都安全
function armPendingBuf2RespTask(taskId, addr, msgType, originalPtr) {
    pendingBuf2RespTasks[taskId] = {
        addr: addr,
        msgType: msgType,
        originalPtr: originalPtr || ptr(0),
        timerId: setTimeout(function () {
            fallbackCleanupPendingTask(taskId);
        }, PENDING_CLEANUP_TIMEOUT_MS),
    };
}

// ack命中: 取消timer并移除登记, 返回entry供调用方读取msgType
function finishPendingBuf2RespTask(taskId) {
    var entry = pendingBuf2RespTasks[taskId];
    if (!entry) {
        return null;
    }
    delete pendingBuf2RespTasks[taskId];
    if (entry.timerId !== null) {
        clearTimeout(entry.timerId);
        entry.timerId = null;
    }
    return entry;
}

// 超时兜底: 复原X24+0x60为原始消息指针(与成功路径写0不同, 此时任务
// 可能仍被mars重试, 必须留合法对象)。entry再保留30s, 迟到的ack
// 仍能匹配并把响应转发给Go (此时entry.addr已空, 只转发不再清理)
function fallbackCleanupPendingTask(taskId) {
    var entry = pendingBuf2RespTasks[taskId];
    if (!entry) {
        return;
    }
    entry.timerId = null;
    try {
        if (!entry.originalPtr.isNull()) {
            entry.addr.writePointer(entry.originalPtr);
            console.log("[!] buf2resp超时兜底: 已复原原始消息指针, msgType=" + entry.msgType + " taskId=" + taskId);
        } else {
            entry.addr.writeU64(0x0);
            console.log("[!] buf2resp超时兜底: 原始指针不可用, 已清零 insertMsgAddr, msgType=" + entry.msgType + " taskId=" + taskId);
        }
    } catch (e) {
        console.error("[!] buf2resp超时兜底清理失败: taskId=" + taskId + " err=" + e);
    }
    entry.addr = ptr(0);
    setTimeout(function () {
        delete pendingBuf2RespTasks[taskId];
    }, 30 * 1000);
}

// -------------------------Req2Buf公共部分分区-------------------------
function attachReq2buf() {
    console.log("[+] attachReq2buf: layout=" + req2bufLayout +
        " (enter=" + req2bufEnterAddr + ", exit=" + req2bufExitAddr +
        ", sendMode=" + REQ2BUF_SEND_MODE + ")");

    if (!sendPathEnabled) {
        console.log("[!] 主动发送已关闭 (REQ2BUF_SEND_MODE=off): 不注册 req2buf/exit hook;" +
            " 需要真机验证时设置 JSON enableSend=true + req2bufSendMode=C2(推荐)/C1");
        return;
    }
    if (r3ModeActive) {
        console.log("[+] R3 模式: 不注册 req2buf fake-node hook (slot13 原生提交)");
        return;
    }
    if (REQ2BUF_SEND_MODE === "cgi") {
        console.log("[+] CGI 模式: 不注册 req2buf fake-node hook (slot13 原生注册)");
        return;
    }

    // legacy(task-5 旧实验): found 路径用 PC 跳转跳过 erase/delete。
    // ⚠️ 真机已证实会退出微信, 仅在明确设置 legacy 时启用。
    if (isReq2bufLayout415 && REQ2BUF_SEND_MODE === "legacy" && REQ2BUF_NODE_MODE === "skip-erase") {
        console.log("[!] 4.1.15 legacy skip-erase hook(不安全, 仅对照) @ " + baseAddr.add(L415.req2bufFindRetErase) +
            " -> 恢复点 " + baseAddr.add(L415.req2bufSkipEraseResume));
        Interceptor.attach(baseAddr.add(L415.req2bufFindRetErase), {
            onEnter: function (args) {
                var m = req2bufGetThreadMark(this);
                if (!m) return;
                if (this.context.x23.toUInt32() !== taskIdGlobal) {
                    hookDebug("skip-erase: 命中但 taskId 不匹配, x23=" + this.context.x23);
                    return;
                }
                // 正常流程会在 0x4635ee8 处 ldr x22,[x25,#0x28]; 这里直接给出等价的值
                this.context.x22 = m.fakeValue;
                // 恢复 enter 时被覆盖的 map root, 避免容器指向伪造节点(新版后续可能再次遍历)
                if (m.baseAddr) {
                    m.baseAddr.add(0x70).writePointer(m.originalRoot);
                }
                hookDebug("skip-erase: taskId=" + taskIdGlobal + " fakeValue=" + m.fakeValue +
                    " originalRoot=" + m.originalRoot + " resume=" + baseAddr.add(L415.req2bufSkipEraseResume));
                this.context.pc = baseAddr.add(L415.req2bufSkipEraseResume);
            }
        });
    } else if (isReq2bufLayout415 && REQ2BUF_SEND_MODE === "legacy") {
        console.error("[!] 4.1.15 legacy node 模式: found 路径会对伪造节点 operator delete," +
            " 预计崩溃(0x4635ed8 解引用 NULL parent), 仅用于对照实验");
    }

    // C2(安全发送): 不跳 PC。原生 erase/delete 会正常执行(伪造节点用 malloc 分配且
    // 补齐 left/right/parent/color), 这里只在 erase+delete 之后、unlock 之前
    // (0x4635f1c, 纯 onEnter 内存写) 把 map 的 root/begin/size 恢复成注入前的值。
    if (isReq2bufLayout415 && REQ2BUF_SEND_MODE === "C2") {
        console.log("[+] 4.1.15 C2 安全发送: restore hook @ " + baseAddr.add(L415.req2bufEraseDone));
        Interceptor.attach(baseAddr.add(L415.req2bufEraseDone), {
            onEnter: function (args) {
                var m = req2bufGetThreadMark(this);
                if (!m || m.mode !== "C2") return;
                try {
                    m.baseAddr.add(0x70).writePointer(m.originalRoot);
                    m.baseAddr.add(0x68).writePointer(m.originalBegin);
                    m.baseAddr.add(0x78).writeU64(m.originalSize);
                    hookDebug("C2 restore(erase 后): root=" + m.originalRoot +
                        " begin=" + m.originalBegin + " size=" + m.originalSize);
                } catch (e) {
                    console.error("[!] C2 restore 失败: " + e);
                }
            }
        });
    }

    Interceptor.attach(req2bufEnterAddr, {
        onEnter: function (args) {
            var taskIdNow, baseReg, insertOff, taskMatched;
            if (isReq2bufLayout415) {
                // 4.1.15: taskId 在 w23/x23(旧版 x1/w20), 容器基址在 x8(旧版 x24),
                // map 根在 this+0x70(旧版 this+0x60)
                taskIdNow = this.context.x23.toUInt32();
                baseReg = this.context.x8;
                insertOff = 0x70;
                taskMatched = (taskIdNow === taskIdGlobal);
            } else {
                // 旧路径保持上游原语义: NativePointer.equals(值) 判断, 不做截断
                taskIdNow = this.context.x1.toUInt32();
                baseReg = this.context.x24;
                insertOff = 0x60;
                taskMatched = this.context.x1.equals(taskIdGlobal);
            }
            hookDebug("req2buf enter: taskId_reg=" + taskIdNow + " expect=" + taskIdGlobal +
                " base=" + baseReg + " off=0x" + insertOff.toString(16));

            if (!taskMatched) {
                return;
            }

            insertMsgAddr = baseReg.add(insertOff);
            // 保存hook前的原始消息指针(校验过可读), 超时兜底时复原,
            // 让任务回到未注入的合法状态, mars重试/回收/delete都不会踩到伪造结构体
            originalInsertMsgPtr = readPointerIfReadable(insertMsgAddr);
            // C2/legacy 需要记录 map 的三个字段以便恢复: root(+0x70)、begin(+0x68)、size(+0x78)
            var originalRoot = ptr(0);
            var originalBegin = ptr(0);
            var originalSize = 0;
            if (isReq2bufLayout415) {
                originalRoot = readPointerIfReadable(insertMsgAddr);
                originalBegin = readPointerIfReadable(baseReg.add(0x68));
                try {
                    originalSize = baseReg.add(0x78).readU64().toNumber();
                } catch (e) {
                    originalSize = 0;
                }
            }

            if (sendMsgType === "text") {
                insertMsgAddr.writePointer(sendTextMessageAddr);
                console.log("[+] 发送文本消息成功! Req2Buf 已将 " +
                    (isReq2bufLayout415 ? "X8+0x70" : "X24+0x60") + " 指向新地址: " + sendTextMessageAddr +
                    " (insertMsgAddr=" + insertMsgAddr + ")");
            } else if (sendMsgType === "img") {
                insertMsgAddr.writePointer(sendImgMessageAddr);
                console.log("[+] 发送图片消息成功! Req2Buf 已将 " +
                    (isReq2bufLayout415 ? "X8+0x70" : "X24+0x60") + " 指向新地址: " + sendImgMessageAddr +
                    " (insertMsgAddr=" + insertMsgAddr + ")");
            } else if (sendMsgType === "video") {
                insertMsgAddr.writePointer(sendVideoMessageAddr);
                console.log("[+] 发送视频消息成功! Req2Buf 已将 " +
                    (isReq2bufLayout415 ? "X8+0x70" : "X24+0x60") + " 指向新地址: " + sendVideoMessageAddr +
                    " (insertMsgAddr=" + insertMsgAddr + ")");
            } else if (sendMsgType === "reply") {
                insertMsgAddr.writePointer(sendReplyMessageAddr);
                console.log("[+] 发送回复消息成功! Req2Buf 已将 " +
                    (isReq2bufLayout415 ? "X8+0x70" : "X24+0x60") + " 指向新地址: " + sendReplyMessageAddr +
                    " (insertMsgAddr=" + insertMsgAddr + ")");
            } else if (sendMsgType === "pat") {
                // 拍一拍复用 sendappmsg 的 reply Message 结构（同一 CGI/opcode）。
                insertMsgAddr.writePointer(sendReplyMessageAddr);
                console.log("[+] 发送拍一拍消息成功! Req2Buf 已将 " +
                    (isReq2bufLayout415 ? "X8+0x70" : "X24+0x60") + " 指向新地址: " + sendReplyMessageAddr +
                    " (insertMsgAddr=" + insertMsgAddr + ")");
            } else if (sendMsgType === "voice") {
                insertMsgAddr.writePointer(sendVoiceMessageAddr);
                console.log("[+] 发送语音消息成功! Req2Buf 已将 " +
                    (isReq2bufLayout415 ? "X8+0x70" : "X24+0x60") + " 指向新地址: " + sendVoiceMessageAddr +
                    " (insertMsgAddr=" + insertMsgAddr + ")");
            } else if (sendMsgType === "file") {
                insertMsgAddr.writePointer(sendFileMessageAddr);
                console.log("[+] 发送文件消息成功! Req2Buf 已将 " +
                    (isReq2bufLayout415 ? "X8+0x70" : "X24+0x60") + " 指向新地址: " + sendFileMessageAddr +
                    " (insertMsgAddr=" + insertMsgAddr + ")");
            } else if (sendMsgType === "fileupload") {
                insertMsgAddr.writePointer(sendFileUploadMessageAddr);
                console.log("[+] 发送fileUploadMsg成功! Req2Buf 已将 " +
                    (isReq2bufLayout415 ? "X8+0x70" : "X24+0x60") + " 指向新地址: " + sendFileUploadMessageAddr +
                    " (insertMsgAddr=" + insertMsgAddr + ")");
            } else if (sendMsgType === "appattach") {
                insertMsgAddr.writePointer(sendAppAttachMessageAddr);
                console.log("[+] 发送uploadAppAttach成功! Req2Buf 已将 " +
                    (isReq2bufLayout415 ? "X8+0x70" : "X24+0x60") + " 指向新地址: " + sendAppAttachMessageAddr +
                    " (insertMsgAddr=" + insertMsgAddr + ")");
            }

            if (isReq2bufLayout415) {
                // 按发送模式决定最终注入内容, 并登记线程标记(供预写/exit/erase 恢复使用)
                var effectiveMode = REQ2BUF_SEND_MODE;
                var injectedNode = readPointerIfReadable(insertMsgAddr);
                var fakeValue = ptr(0);
                if (effectiveMode === "C1" || effectiveMode === "replay") {
                    // C1/replay: 不注入伪造节点 -> 立即把 enter 时读到的真实 root 写回;
                    // 原生 find 会按真实 map 走(找到=正常编码, 找不到=安全 not-found)
                    insertMsgAddr.writePointer(originalRoot);
                    console.log("[+] " + effectiveMode + ": 不注入伪造节点, 使用真实 map 节点 (root=" +
                        originalRoot + ")");
                } else if (effectiveMode === "C2") {
                    // C2: 伪造结构是为了取 value(伪造 Message); map 节点改为 malloc 合法节点
                    fakeValue = injectedNode.isNull() ? ptr(0) : readPointerIfReadable(injectedNode.add(0x28));
                    try {
                        injectedNode = buildReq2bufFakeNode(fakeValue);
                        insertMsgAddr.writePointer(injectedNode);
                        console.log("[+] C2: 已注入 malloc 伪造节点 " + injectedNode +
                            " (value=" + fakeValue + ", header=" + req2bufTreeHeader + ")");
                    } catch (e) {
                        // malloc 不可用/失败: 安全退化 C1, 绝不留下半成品伪造节点
                        console.error("[!] C2 构造伪造节点失败, 退化为 C1(不注入): " + e);
                        effectiveMode = "C1";
                        insertMsgAddr.writePointer(originalRoot);
                        injectedNode = ptr(0);
                        fakeValue = ptr(0);
                    }
                } else {
                    // legacy: 注入 Memory.alloc 的伪造结构(配合 skip-erase/PC 跳转, 已知不安全)
                    fakeValue = injectedNode.isNull() ? ptr(0) : readPointerIfReadable(injectedNode.add(0x28));
                }
                var tid = req2bufThreadId(this);
                req2bufThreadMark[tid] = {
                    taskId: taskIdGlobal,
                    baseAddr: baseReg,
                    mode: effectiveMode,
                    originalRoot: originalRoot,
                    originalBegin: originalBegin,
                    originalSize: originalSize,
                    fakeValue: fakeValue,
                    fakeNode: injectedNode,
                    loadedAt: Date.now()
                };
                hookDebug("req2buf enter 登记: tid=" + tid + " mode=" + effectiveMode + " base=" + baseReg +
                    " originalRoot=" + originalRoot + " begin=" + originalBegin + " size=" + originalSize +
                    " fakeNode=" + injectedNode + " fakeValue=" + fakeValue);
            }
        }
    });

    // 在出口处拦截req2buf，记录insertMsgAddr等buf2resp回调后再清理
    Interceptor.attach(req2bufExitAddr, {
        onEnter: function (args) {
            if (isReq2bufLayout415) {
                // 新版不再用 x25(不是 taskId), 用 enter 时的线程标记判定"这是我们的调用"
                var m = req2bufGetThreadMark(this);
                if (!m) {
                    hookDebug("req2buf exit: 无本线程标记, 跳过 (x23=" + this.context.x23 + ")");
                    return;
                }
                hookDebug("req2buf exit: taskId=" + m.taskId + " mode=" + m.mode +
                    " insertMsgAddr=" + insertMsgAddr + " originalInsertMsgPtr=" + originalInsertMsgPtr);
                req2bufClearThreadMark(this);
            } else {
                if (!this.context.x25.equals(taskIdGlobal)) {
                    return;
                }
            }
            // 不立即清除insertMsgAddr，让mars能路由buf2resp回调
            // 用fakeVtable保护结构体，防止中间被访问时崩溃
            // 登记任务并挂超时兜底timer: ack超时则复原X24+0x60原始指针
            armPendingBuf2RespTask(taskIdGlobal, insertMsgAddr, sendMsgType, originalInsertMsgPtr);
            taskIdGlobal = 0;
        }
    });
}


// -------------------------Req2Buf公共部分分区-------------------------

// -------------------------发送图片消息分区-------------------------

// 初始化进行内存的分配
function setupSendImgMessageDynamic() {

    // 1. 动态分配内存块（按需分配大小）
    // 分配原则：字符串给 64-128 字节，结构体按实际大小分配
    imgCgiAddr = Memory.alloc(128);
    sendImgMessageAddr = Memory.alloc(256);
    imgMessageAddr = Memory.alloc(256);
    uploadFunc1Addr = Memory.alloc(24);
    uploadFunc2Addr = Memory.alloc(24);
    uploadCallback = Memory.alloc(128);
    imageIdAddr = Memory.alloc(256);
    md5Addr = Memory.alloc(256);
    uploadAesKeyAddr = Memory.alloc(256);
    ImagePathAddr1 = Memory.alloc(256);
    uploadImageX1 = Memory.alloc(1024);

    // 图片数据写入
    patchString(imgCgiAddr, "/cgi-bin/micromsg-bin/uploadmsgimg");

    sendImgMessageAddr.add(0x00).writeU64(0);
    sendImgMessageAddr.add(0x08).writeU64(0);
    sendImgMessageAddr.add(0x10).writeU64(0);
    sendImgMessageAddr.add(0x18).writeU64(1);
    sendImgMessageAddr.add(0x20).writeU32(taskIdGlobal);
    sendImgMessageAddr.add(0x28).writePointer(imgMessageAddr);

    imgMessageAddr.add(0x00).writePointer(fakeVtable);
    imgMessageAddr.add(0x08).writeU32(taskIdGlobal);
    imgMessageAddr.add(0x0c).writeU32(0x6e);
    imgMessageAddr.add(0x10).writeU64(0x3);
    imgMessageAddr.add(0x18).writePointer(imgCgiAddr);
    imgMessageAddr.add(0x20).writeU64(0x22);
    imgMessageAddr.add(0x28).writeU64(uint64("0x8000000000000030"));
    imgMessageAddr.add(0x30).writeU64(uint64("0x0000000001010100"));

    // 视频数据写入
    videoCgiAddr = Memory.alloc(128);
    sendVideoMessageAddr = Memory.alloc(256);
    videoMessageAddr = Memory.alloc(256);
    videoIdAddr = Memory.alloc(256);
    videoPathAddr1 = Memory.alloc(256);
    uploadVideoX1 = Memory.alloc(1024);

    patchString(videoCgiAddr, "/cgi-bin/micromsg-bin/uploadvideo");

    sendVideoMessageAddr.add(0x00).writeU64(0);
    sendVideoMessageAddr.add(0x08).writeU64(0);
    sendVideoMessageAddr.add(0x10).writeU64(0);
    sendVideoMessageAddr.add(0x18).writeU64(1);
    sendVideoMessageAddr.add(0x20).writeU32(taskIdGlobal);
    sendVideoMessageAddr.add(0x28).writePointer(videoMessageAddr);

    videoMessageAddr.add(0x00).writePointer(fakeVtable);
    videoMessageAddr.add(0x08).writeU32(taskIdGlobal);
    videoMessageAddr.add(0x0c).writeU32(0x6e);
    videoMessageAddr.add(0x10).writeU64(0x3);
    videoMessageAddr.add(0x18).writePointer(videoCgiAddr);
    videoMessageAddr.add(0x20).writeU64(0x21);
    videoMessageAddr.add(0x28).writeU64(uint64("0x8000000000000030"));
    videoMessageAddr.add(0x30).writeU64(uint64("0x0000000001010100"));

    // 语音数据写入
    voiceCgiAddr = Memory.alloc(128);
    sendVoiceMessageAddr = Memory.alloc(256);
    voiceMessageAddr = Memory.alloc(256);
    voiceIdAddr = Memory.alloc(256);
    voicePathAddr1 = Memory.alloc(256);
    uploadVoiceX1 = Memory.alloc(1024);
    voiceAudioDataAddr = Memory.alloc(5 * 1024 * 1024); // 预分配5MB

    patchString(voiceCgiAddr, "/cgi-bin/micromsg-bin/uploadvoice");

    sendVoiceMessageAddr.add(0x00).writeU64(0);
    sendVoiceMessageAddr.add(0x08).writeU64(0);
    sendVoiceMessageAddr.add(0x10).writeU64(0);
    sendVoiceMessageAddr.add(0x18).writeU64(1);
    sendVoiceMessageAddr.add(0x20).writeU32(taskIdGlobal);
    sendVoiceMessageAddr.add(0x28).writePointer(voiceMessageAddr);

    voiceMessageAddr.add(0x00).writePointer(fakeVtable);
    voiceMessageAddr.add(0x08).writeU32(taskIdGlobal);
    voiceMessageAddr.add(0x0c).writeU32(0x6e);
    voiceMessageAddr.add(0x10).writeU64(0x3);
    voiceMessageAddr.add(0x18).writePointer(voiceCgiAddr);
    voiceMessageAddr.add(0x20).writeU64(0x21);
    voiceMessageAddr.add(0x28).writeU64(uint64("0x8000000000000030"));
    voiceMessageAddr.add(0x30).writeU64(uint64("0x0000000001010100"));
}




// ================= task-8: CGI task 直发(slot13) =================
// 思路: 用真实 task 类 ctor 构造 vtable/成员, 用 fake serializer vtable
// (NativeCallback: +0x48=size, +0x58=write) 把请求体换成我们的 protobuf,
// 再调用 slot13(0x4634710) 让原生完成 lock/native-taskId/RB-tree insert/dispatch。
// 默认仅 REQ2BUF_SEND_MODE=cgi 时启用; manager/template 由 slot13 后台流量被动捕获。
var cgiManager = ptr(0);
var cgiTemplate = null;          // ArrayBuffer(0xE0) 最近一次真实 slot13 task
var cgiTemplateOpcode = 0;
var cgiTemplateUrl = "";
var cgiTemplateCtx = ptr(0);     // 真实 task +0x68 context(供 req2buf hand-off)
var cgiProtoBytes = null;        // 本次要发送的 protobuf 字节
var cgiSerializerVtable = ptr(0);
var cgiSerializerSizeCb = null;
var cgiSerializerWriteCb = null;
var cgiMallocFn = null;

function resolveGlobalExportCompat(name) {
    try {
        if (typeof Module.findGlobalExportByName === "function") return Module.findGlobalExportByName(name);
        if (typeof Module.getGlobalExportByName === "function") return Module.getGlobalExportByName(name);
        if (typeof Module.findExportByName === "function") return Module.findExportByName(null, name);
        if (typeof Module.getExportByName === "function") return Module.getExportByName(null, name);
    } catch (e) { }
    try {
        var lib = Process.getModuleByName("libSystem.B.dylib");
        if (lib && typeof lib.getExportByName === "function") return lib.getExportByName(name);
    } catch (e) { }
    return null;
}

function cgiMalloc(size) {
    if (cgiMallocFn === null) {
        var p = resolveGlobalExportCompat("malloc");
        if (p === null || p.isNull()) throw new Error("malloc not found");
        cgiMallocFn = new NativeFunction(p, "pointer", ["size_t"]);
    }
    return cgiMallocFn(size);
}

// fake serializer vtable: slot9(+0x48) 返回 size, slot11(+0x58) 写入 protobuf
function ensureCgiSerializerVtable() {
    if (!cgiSerializerVtable.isNull()) return cgiSerializerVtable;
    if (typeof NativeCallback !== "function") throw new Error("NativeCallback unavailable");
    cgiSerializerSizeCb = new NativeCallback(function (obj) {
        var proto = cgiProtoBytes;
        return proto ? proto.length : 0;
    }, 'uint64', ['pointer']);
    cgiSerializerWriteCb = new NativeCallback(function (obj, dst) {
        var proto = cgiProtoBytes;
        if (!proto || !dst || dst.isNull()) return dst;
        dst.writeByteArray(proto);
        return dst.add(proto.length);
    }, 'pointer', ['pointer', 'pointer']);
    var vt = Memory.alloc(0x80);
    for (var i = 0; i < 16; i++) vt.add(i * 8).writePointer(retOneStub);
    vt.add(0x08).writePointer(retOneStub);      // 子对象 dtor: 不 free 我们的结构
    vt.add(0x48).writePointer(cgiSerializerSizeCb);
    vt.add(0x58).writePointer(cgiSerializerWriteCb);
    cgiSerializerVtable = vt;
    console.log("[+] CGI: fake serializer vtable = " + vt +
        " (size cb=" + cgiSerializerSizeCb + ", write cb=" + cgiSerializerWriteCb + ")");
    return vt;
}

// 被动捕获 manager 与真实 CGI task 模板(后台同步/心跳等也会命中 slot13)
function attachSlot13Capture() {
    if (!sendPathEnabled || r3ModeActive || REQ2BUF_SEND_MODE !== "cgi") return;
    try {
        var slot13Addr = baseAddr.add(0x4634710);
        Interceptor.attach(slot13Addr, {
            onEnter: function (args) {
                try {
                    var mgr = args[0], task = args[1];
                    if (!isReadablePointer(mgr) || !isReadablePointer(task)) return;
                    var vt = readPointerIfReadable(task);
                    if (vt === null || vt.isNull()) return;
                    if (cgiManager.isNull()) {
                        cgiManager = mgr;
                        console.log("[+] CGI: manager captured = " + mgr);
                    }
                    var op = task.add(0xC).readU32();
                    var url = readStdStringCompat(task.add(0x18), 256) || "";
                    var isNews = url.indexOf("newsendmsg") >= 0;
                    if (isNews || cgiTemplate === null) {
                        cgiTemplate = task.readByteArray(0xE0);
                        cgiTemplateOpcode = op;
                        cgiTemplateUrl = url;
                        cgiTemplateCtx = readPointerIfReadable(task.add(0x68));
                        console.log("[+] CGI: template captured opcode=0x" + op.toString(16) +
                            " url=" + url + " ctx=" + cgiTemplateCtx +
                            (isNews ? " (newsendmsg)" : " (fallback)"));
                    }
                } catch (e) { hookDebug("CGI capture: " + e); }
            }
        });
        console.log("[+] CGI: slot13 capture hook @ " + slot13Addr +
            " (等待后台/真实 CGI 任务捕获 manager/template)");
    } catch (e) {
        console.error("[!] CGI: slot13 hook 失败: " + e);
    }
}

// 构造真实类 vtable 的 CGI task, 请求体由 fake serializer 提供
function triggerSendCgiMessage(taskId, protoHex, msgType) {
    if (msgType !== "text") {
        console.error("[!] CGI 模式当前只支持 text (msgType=" + msgType + ")");
        return "fail";
    }
    if (cgiManager.isNull() || cgiTemplate === null) {
        console.error("[!] CGI: 尚未捕获 manager/template; 需要 WeChat 先发生一次 CGI 任务" +
            " (后台同步/心跳/任意发送都会命中 slot13, 不需要 UI 自动化, 但要等流量)");
        return "fail";
    }
    var proto;
    try { proto = hexToByteArray(protoHex); } catch (e) { proto = null; }
    if (!proto || proto.length === 0) {
        console.error("[!] CGI: protoHex 为空/非法");
        return "fail";
    }
    cgiProtoBytes = proto;
    try {
        var vt = ensureCgiSerializerVtable();
        var task = cgiMalloc(0xE0);
        if (task.isNull()) throw new Error("malloc task failed");
        var ctor = new NativeFunction(baseAddr.add(0x30C2FE4), "pointer", ["pointer"]);
        ctor(task);
        task.add(0x0C).writeU32(0x20A);                 // text opcode
        var urlText = "/cgi-bin/micromsg-bin/newsendmsg";
        var urlPtr = cgiMalloc(urlText.length + 1);
        urlPtr.writeUtf8String(urlText);
        task.add(0x18).writePointer(urlPtr);
        task.add(0x20).writeU64(urlText.length);
        task.add(0x28).writeU64(uint64("0x8000000000000030"));
        task.add(0x30).writeU32(0x01010100);
        task.add(0x78).writePointer(vt);                 // fake serializer
        if (!cgiTemplateCtx.isNull()) task.add(0x68).writePointer(cgiTemplateCtx);
        console.log("[+] CGI: task=" + task + " mgr=" + cgiManager +
            " templateOpcode=0x" + cgiTemplateOpcode.toString(16) +
            " protoLen=" + proto.length + " ctx=" + cgiTemplateCtx);
        var slot13 = new NativeFunction(baseAddr.add(0x4634710), "int64", ["pointer", "pointer"]);
        var ret = slot13(cgiManager, task);
        console.log("[+] CGI: slot13(manager, task) 返回 " + ret);
        return "1";
    } catch (e) {
        console.error("[!] CGI: 构造/调用 slot13 失败: " + e);
        return "fail";
    }
}

function triggerSendMediaMessage(taskId, sender, receiver, protoHex, payloadHex, msgType) {
    if (!sendPathEnabled) {
        console.error("[!] 主动发送已关闭 (REQ2BUF_SEND_MODE=off): " + msgType + " 请求被拒绝。" +
            " 需要真机验证时: hook/versions JSON 设 enableSend=true + req2bufSendMode=C2(推荐), " +
            "或环境变量 HOOK_REQ2BUF_SEND_MODE=C2");
        return "fail";
    }

    // R3: 原生 task 构造 + slot13 提交; 不依赖 req2buf/StartTask 捕获与 Message 结构。
    if (r3ModeActive) {
        if (msgType === "text") return r3SendTextMessage(taskId, protoHex);
        // 拍一拍是实验路径：复用 newsendmsg 种子闭包构造 sendappmsg task，
        // 只有运行期配置 r3AppMsgSend=true 才允许（App 在“R3 + 回拍”都开启时合并）。
        if (msgType === "pat") return r3SendPatMessage(taskId, protoHex);
        console.error("[!] R3 模式当前只支持 text/pat (收到 " + msgType + ")");
        return "fail";
    }

    if (!taskId || !receiver) {
        console.error("[!] " + msgType + ": taskId or receiver is empty!");
        return "fail";
    }

    // replay 模式不需要 triggerX1Payload(用自己的 0x300 snapshot buffer), 只要求 triggerX0;
    // cgi 模式连 triggerX0 都不需要(只依赖 slot13 捕获的 manager/template)。
    var replayModeActive = (isReq2bufLayout415 && REQ2BUF_SEND_MODE === "replay");
    var cgiModeActive = (isReq2bufLayout415 && REQ2BUF_SEND_MODE === "cgi");
    if (!triggerX0 || (!triggerX1Payload && !replayModeActive && !cgiModeActive)) {
        if (!cgiModeActive) {
            console.error("[!] triggerX0 或 triggerX1Payload 尚未初始化，请等待 hook 捕获");
            return "fail";
        }
    }

    var msgAddrInfo = {
        "text":  { messageAddr: textMessageAddr,  sendMessageAddr: sendTextMessageAddr,  cgiAddr: textCgiAddr,  protoHexSetter: function(h) { textProtoHexGlobal = h; } },
        "img":   { messageAddr: imgMessageAddr,   sendMessageAddr: sendImgMessageAddr,   cgiAddr: imgCgiAddr,   protoHexSetter: function(h) { imgProtoHexGlobal = h; } },
        "video": { messageAddr: videoMessageAddr, sendMessageAddr: sendVideoMessageAddr, cgiAddr: videoCgiAddr, protoHexSetter: function(h) { videoProtoHexGlobal = h; } },
        "reply": { messageAddr: replyMessageAddr, sendMessageAddr: sendReplyMessageAddr, cgiAddr: replyCgiAddr, protoHexSetter: function(h) { replyProtoHexGlobal = h; } },
        // 拍一拍与 reply 共用 sendappmsg 的 Message 结构，仅 protobuf/appmsg XML 不同。
        "pat":   { messageAddr: replyMessageAddr, sendMessageAddr: sendReplyMessageAddr, cgiAddr: replyCgiAddr, protoHexSetter: function(h) { patProtoHexGlobal = h; } },
        "voice": { messageAddr: voiceMessageAddr, sendMessageAddr: sendVoiceMessageAddr, cgiAddr: voiceCgiAddr, protoHexSetter: function(h) { voiceProtoHexGlobal = h; } },
        "file":  { messageAddr: fileMessageAddr,  sendMessageAddr: sendFileMessageAddr,  cgiAddr: fileCgiAddr,  protoHexSetter: function(h) { fileProtoHexGlobal = h; } },
        "fileupload": { messageAddr: fileUploadMessageAddr, sendMessageAddr: sendFileUploadMessageAddr, cgiAddr: fileUploadCgiAddr, protoHexSetter: function(h) { fileUploadProtoHexGlobal = h; } },
        "appattach": { messageAddr: appAttachMessageAddr, sendMessageAddr: sendAppAttachMessageAddr, cgiAddr: appAttachCgiAddr, protoHexSetter: function(h) { appAttachProtoHexGlobal = h; } },
    };

    var info = msgAddrInfo[msgType];
    if (!info) {
        console.error("[!] unknown msgType: " + msgType);
        return "fail";
    }

    info.protoHexSetter(protoHex);
    taskIdGlobal = taskId;

    info.messageAddr.add(0x08).writeU32(taskIdGlobal);
    info.sendMessageAddr.add(0x20).writeU32(taskIdGlobal);

    // task-7 replay: 用最近一次真实发送捕获的 0x300 snapshot 作为 payload。
    // 保留全部真实运行期字段(+0x04 类型/+0x10/+0x18 Message 指针/+0x20 ...),
    // 只改 +0x00 taskId 和 +0xB8/+0x190 两个自指针(必须指向新 buffer)。
    // 后续 req2buf 的预写/blr hook 会把编码 buffer 换成我们的 protobuf。
    if (isReq2bufLayout415 && REQ2BUF_SEND_MODE === "replay") {
        if (!triggerTaskSnapshot || !triggerX0) {
            console.error("[!] replay: 缺少真实任务快照(triggerTaskSnapshot/triggerX0);" +
                " 需要先发生一次真实发送(由 WeChat 自己走到 sendFuncAddr)");
            return "fail";
        }
        var snapBytes = new Uint8Array(triggerTaskSnapshot);
        if (snapBytes.length < 0x300) {
            console.error("[!] replay: snapshot 长度不足 0x300 (" + snapBytes.length + "B)");
            return "fail";
        }
        var replayBuf = Memory.alloc(0x300);
        replayBuf.writeByteArray(snapBytes);
        replayBuf.add(0x00).writeU32(taskIdGlobal);                // 新 taskId(低 32 位)
        replayBuf.add(0xB8).writePointer(replayBuf.add(0xC0));     // 真实快照 +0xB8 = x1+0xC0
        replayBuf.add(0x190).writePointer(replayBuf.add(0x198));   // 真实快照 +0x190 = x1+0x198
        sendMsgType = msgType;
        console.log("[+] replay: 使用真实 0x300 snapshot, taskId=" + taskIdGlobal +
            " (" + msgType + ") x1=" + replayBuf + " x0=" + triggerX0);
        const MMStartTaskReplay = new NativeFunction(sendFuncAddr, 'int64', ['pointer', 'pointer']);
        try {
            MMStartTaskReplay(triggerX0, replayBuf);
            return "1";
        } catch (e) {
            console.error("[!] replay MMStartTask error: " + e);
            return "fail";
        }
    }

    // task-8: CGI 模式 (slot13 原生注册/编码)
    if (isReq2bufLayout415 && REQ2BUF_SEND_MODE === "cgi") {
        return triggerSendCgiMessage(taskId, protoHex, msgType);
    }

    const payloadData = hexToByteArray(payloadHex);
    // 先恢复完整任务结构快照(重建合法回调子对象, free 残骸的野回调指针会崩)
    if (triggerTaskSnapshot) {
        triggerX1Payload.writeByteArray(triggerTaskSnapshot);
    }
    triggerX1Payload.writeByteArray(payloadData);
    triggerX1Payload.add(0x18).writePointer(info.cgiAddr);
    triggerX1Payload.add(0xb8).writePointer(triggerX1Payload.add(0xc0));
    triggerX1Payload.add(0x190).writePointer(triggerX1Payload.add(0x198));
    sendMsgType = msgType;

    const MMStartTask = new NativeFunction(sendFuncAddr, 'int64', ['pointer', 'pointer']);

    try {
        MMStartTask(triggerX0, triggerX1Payload);
        return "1";
    } catch (e) {
        console.error("[!] Error trigger " + msgType + " MMStartTask: " + e);
        return "fail";
    }
}

function triggerSendImgMessage(taskId, sender, receiver, protoHex, payloadHex) {
    return triggerSendMediaMessage(taskId, sender, receiver, protoHex, payloadHex, "img");
}

function triggerSendVideoMessage(taskId, sender, receiver, protoHex, payloadHex) {
    return triggerSendMediaMessage(taskId, sender, receiver, protoHex, payloadHex, "video");
}


function triggerUploadImg(receiver, md5, imagePath, payloadHex) {
    return fillUploadX1AndStart(imageIdAddr, ImagePathAddr1, uploadImageX1, receiver, md5, imagePath, payloadHex);
}

function triggerUploadVideo(receiver, md5, videoPath, payloadHex) {
    return fillUploadX1AndStart(videoIdAddr, videoPathAddr1, uploadVideoX1, receiver, md5, videoPath, payloadHex);
}

function triggerUploadVoice(receiver, voicePath, payloadHex, audioDataHex, durationMs) {
    if (uploadGlobalX0.equals(ptr(0))) {
        ensureCdnManagerX0();
    }
    if (uploadGlobalX0.equals(ptr(0))) {
        console.error("[!] uploadGlobalX0 尚未初始化，请等待 hook 捕获");
        return "fail";
    }

    voiceDurationGlobal = durationMs;
    const payload = hexToByteArray(payloadHex);

    // 解码音频二进制数据，写入预分配的5MB内存
    const audioBytes = hexToByteArray(audioDataHex);
    const audioLen = audioBytes.length;
    voiceSilkDataLenGlobal = audioLen;
    voiceAudioDataAddr.writeByteArray(audioBytes);

    const voiceIdStr = receiver + "_" + String(Math.floor(Date.now() / 1000)) + "_" + Math.floor(Math.random() * 1001) + "_1";
    patchString(voiceIdAddr, voiceIdStr);
    patchString(voicePathAddr1, voicePath);

    uploadVoiceX1.writeByteArray(payload);
    uploadVoiceX1.writePointer(uploadFunc1Addr);
    uploadVoiceX1.add(0x08).writePointer(uploadFunc2Addr);
    uploadVoiceX1.add(0x48).writePointer(voiceIdAddr);
    uploadVoiceX1.add(0x50).writeU64(voiceIdStr.length);
    uploadVoiceX1.add(0x58).writeU64(uint64("0x8000000000000000").add(voiceIdStr.length + 1));
    uploadVoiceX1.add(0x68).writeUtf8String(receiver);
    // 音频二进制数据: 0x100=指针, 0x108=长度, 0x110=容量(长度+1)|高位
    uploadVoiceX1.add(0x100).writePointer(voiceAudioDataAddr);
    uploadVoiceX1.add(0x108).writeU64(audioLen);
    uploadVoiceX1.add(0x110).writeU64(uint64("0x8000000000000000").add(audioLen + 1));

    const startUploadMedia = new NativeFunction(uploadImageAddr, 'int64', ['pointer', 'pointer']);

    return startUploadMedia(uploadGlobalX0, uploadVoiceX1);
}

function attachUploadMedia() {
    Interceptor.attach(uploadImageAddr.add(0x10), {
        onEnter: function (args) {
			uploadGlobalX0 = this.context.x0;
			if (!downloadGlobalX0) {
				// 上传/下载共用同一 mars::cdn::CdnManager 单例, 顺手回填
				downloadGlobalX0 = this.context.x0;
				console.log("[+] 上传hook回填 downloadGlobalX0: " + downloadGlobalX0);
			}
		}
    })
}



// 视频上传成功钥匙缓存: cdnKey -> { aesKey, md5Key, videoId }
// CDN 秒传去重的响应不带 aesKey, 按 cdnKey 命中回填 (见 patchCdnOnComplete)
var cdnVideoKeyCache = {};

// Go 启动时回灌持久化(./cdn_video_keys.json)的钥匙, 解决缓存跨进程丢失:
// onebot 重启后同一视频首次上传必撞秒传去重(响应无 aesKey), 内存缓存为空
// 就只能 abort → send timeout (2026-09-07 四次实锤)
function hydrateCdnVideoCache(jsonStr) {
    var persisted = JSON.parse(jsonStr);
    var n = 0;
    for (var k in persisted) {
        if (persisted.hasOwnProperty(k) && persisted[k] && persisted[k].aesKey && !cdnVideoKeyCache[k]) {
            cdnVideoKeyCache[k] = persisted[k];
            n++;
        }
    }
    console.log("[+] hydrateCdnVideoCache: 回灌 " + n + " 条视频钥匙");
    return n;
}

function patchCdnOnComplete() {
    Interceptor.attach(cndOnCompleteAddr, {
        onEnter: function (args) {

            try {
                const x2 = this.context.x2;
                // 4.1.12(structVer=2): 完成结构整体 +0x08 (DIAG 实证: fileId 0x20→0x28,
                // cdnKey 0x60→0x68, aesKey 0x78→0x80, md5Key 0x90→0x98, targetId 0x40→0x48);
                // 且 videoId 字段整个消失(宽扫 0x00-0x260 无候选, 见 docs/version-upgrade.md
                // 铁律9), structVer=2 直接传空串
                const cndShift = (structVer === "2") ? 0x08 : 0;
                const currentFileId = x2.add(0x20 + cndShift).readPointer().readUtf8String();
                const imageFileId = imageIdAddr.readUtf8String();
                const videoFileId = videoIdAddr.readUtf8String();
                const voiceFileId = voiceIdAddr.readUtf8String();
                const fileUploadFileId = uploadFileIdAddr.readUtf8String();
                if (currentFileId !== imageFileId && currentFileId !== videoFileId && currentFileId !== voiceFileId && currentFileId !== fileUploadFileId) {
                    console.log("[-] CndOnComplete x2: " + x2 + " currentFileId: " + currentFileId +
                        " imageFileId: " + imageFileId + " videoFileId:" + videoFileId + " voiceFileId:" + voiceFileId + " fileUploadFileId:" + fileUploadFileId);
                    return;
                }

                const cdnKey = x2.add(0x60 + cndShift).readPointer().readUtf8String();
                const aesKey = x2.add(0x78 + cndShift).readPointer().readUtf8String();
                const md5Key = x2.add(0x90 + cndShift).readPointer().readUtf8String();
                const videoId = (structVer === "2") ? "" : x2.add(0xf0).readPointer().readUtf8String();
                const targetId = x2.add(0x40 + cndShift).readUtf8String();

                console.log("cndOnComplete x2: " + x2 + " cdnKey: " + cdnKey + " aesKey: " + aesKey + " md5Key: " + md5Key + " videoId: " + videoId + " targetId: " + targetId);

                if (cdnKey !== "" && cdnKey != null && aesKey !== "" && aesKey != null) {

                    // 判断是语音、视频、文件还是图片
                    if (currentFileId === voiceFileId) {
                        // 语音
                        send({
                            type: "upload_voice_finish",
                            target_id: targetId,
                            cdn_key: cdnKey,
                            aes_key: aesKey,
                            voice_duration: voiceDurationGlobal,
                            silk_data_len: voiceSilkDataLenGlobal
                        });
                    } else if (currentFileId === fileUploadFileId) {
                        // 文件
                        var attachId = "@cdn_" + cdnKey + "_" + aesKey + "_1";
                        send({
                            type: "upload_file_finish",
                            target_id: targetId,
                            cdn_key: cdnKey,
                            aes_key: aesKey,
                            md5_key: md5Key,
                            attach_id: attachId,
                            file_upload_token: "",
                            overwrite_msg_id: ""
                        });
                    } else if (currentFileId === videoFileId) {
                        // 视频: 缓存成功上传的钥匙, 供秒传去重时回填
                        // videoId || "" 兜底: null 会让 Go 侧 videoId.(string) panic
                        // (被 main.go recover 吞掉, 表现为 HTTP 超时假象); proto3 空 bytes
                        // 字段会被省略, 4.1.12 实测服务端 ack、视频可播放
                        cdnVideoKeyCache[cdnKey] = { aesKey: aesKey, md5Key: md5Key, videoId: videoId || "" };
                        send({
                            type: "upload_video_finish",
                            target_id: targetId,
                            cdn_key: cdnKey,
                            aes_key: aesKey,
                            md5_key: md5Key,
                            video_id: videoId || ""
                        });
                    } else {
                        // 图片
                        send({
                            type: "upload_image_finish",
                            target_id: targetId,
                            cdn_key: cdnKey,
                            aes_key: aesKey,
                            md5_key: md5Key
                        });
                    }
                } else if (currentFileId === videoFileId && cdnKey !== "" && cdnKey != null && cdnVideoKeyCache[cdnKey]) {
                    // CDN 秒传去重: 同一视频重复上传时服务端直接返回已有 filekey
                    // (cdnKey 相同), 但响应不带 aesKey/md5Key (2026-08-27 先发个人再发群,
                    // 群发送三次全部死在 "cdnKey or aesKey 为空")。文件就是上次我们自己传的,
                    // 回填缓存钥匙即可正确解密; videoId 优先用本次响应里的(秒传响应会带)。
                    var cached = cdnVideoKeyCache[cdnKey];
                    console.log("[+] cndOnComplete 秒传命中, 回填缓存钥匙 cdnKey: " + cdnKey);
                    send({
                        type: "upload_video_finish",
                        target_id: targetId,
                        cdn_key: cdnKey,
                        aes_key: cached.aesKey,
                        md5_key: cached.md5Key,
                        video_id: (videoId !== "" && videoId != null) ? videoId : (cached.videoId || "")
                    });
                } else {
                    console.error("cdnKey or aesKey 为空");
                }
            } catch (e) {
                console.error("[-] CdnOnComplete error: " + e);
            }
        }
    });
}


function attachGetCallbackFromWrapper() {
    Interceptor.attach(uploadGetCallbackWrapperAddr, {
        onEnter: function (args) {
            try {
                const tmpFileId = this.context.x1.readPointer().readUtf8String();
                const imageFileId = imageIdAddr.readUtf8String();
                const videoFileId = videoIdAddr.readUtf8String();
                const voiceFileId = voiceIdAddr.readUtf8String();
                const fileUploadFileId = uploadFileIdAddr.readUtf8String();
                if (tmpFileId !== imageFileId && tmpFileId !== videoFileId && tmpFileId !== voiceFileId && tmpFileId !== fileUploadFileId) {
                    console.log("[+] GetCallbackFromWrapper tmpFileId: " + tmpFileId + " imageFileId: " + imageFileId + " videoFileId:" + videoFileId + " voiceFileId:" + voiceFileId + " fileUploadFileId:" + fileUploadFileId);
                    return
                }

                uploadCallback.add(0x10).writePointer(uploadGetCallbackWrapperFuncAddr);
                this.context.x8 = uploadCallback;
            } catch (e) {
                console.error("[-] GetCallbackFromWrapper error: " + e);
            }
        }
    })

    Interceptor.attach(uploadOnCompleteAddr, {
        onEnter: function (args) {
            try {
                const tmpFileId = this.context.x1.readPointer().readUtf8String();
                const imageFileId = imageIdAddr.readUtf8String();
                const videoFileId = videoIdAddr.readUtf8String();
                const voiceFileId = voiceIdAddr.readUtf8String();
                const fileUploadFileId = uploadFileIdAddr.readUtf8String();
                if (tmpFileId !== imageFileId && tmpFileId !== videoFileId && tmpFileId !== voiceFileId && tmpFileId !== fileUploadFileId) {
                    console.log("[+] OnComplete tmpFileId: " + tmpFileId + " imageFileId: " + imageFileId + " videoFileId:" + videoFileId + " voiceFileId:" + voiceFileId + " fileUploadFileId:" + fileUploadFileId);
                    return
                }

                uploadCallback.add(0x30).writePointer(uploadOnCompleteFuncAddr);
                this.context.x8 = uploadCallback;
            } catch (e) {
                console.error("[-] OnComplete error: " + e);
            }
        }
    })
}


// -------------------------发送回复消息分区-------------------------
function setupSendReplyMessageDynamic() {
    replyCgiAddr = Memory.alloc(128);
    sendReplyMessageAddr = Memory.alloc(256);
    replyMessageAddr = Memory.alloc(256);

    patchString(replyCgiAddr, "/cgi-bin/micromsg-bin/sendappmsg");

    sendReplyMessageAddr.add(0x00).writeU64(0);
    sendReplyMessageAddr.add(0x08).writeU64(0);
    sendReplyMessageAddr.add(0x10).writeU64(0);
    sendReplyMessageAddr.add(0x18).writeU64(1);
    sendReplyMessageAddr.add(0x20).writeU32(taskIdGlobal);
    sendReplyMessageAddr.add(0x28).writePointer(replyMessageAddr);

    replyMessageAddr.add(0x00).writePointer(fakeVtable);
    replyMessageAddr.add(0x08).writeU32(taskIdGlobal);
    replyMessageAddr.add(0x0c).writeU32(0x6e);
    replyMessageAddr.add(0x10).writeU64(0x3);
    replyMessageAddr.add(0x18).writePointer(replyCgiAddr);
    replyMessageAddr.add(0x20).writeU64(0x20);
    replyMessageAddr.add(0x28).writeU64(uint64("0x8000000000000030"));
    replyMessageAddr.add(0x30).writeU64(uint64("0x0000000001010100"));

    console.log("[+] Reply message setup complete. CgiAddr: " + replyCgiAddr + " SendAddr: " + sendReplyMessageAddr);
}


function triggerSendReplyMessage(taskId, sender, receiver, protoHex, payloadHex) {
    return triggerSendMediaMessage(taskId, sender, receiver, protoHex, payloadHex, "reply");
}

// 拍一拍：bridge 构建 appmsg type=62 的 protobuf，这里沿用 sendappmsg 的发送路径。
function triggerSendPatMessage(taskId, sender, receiver, protoHex, payloadHex) {
    return triggerSendMediaMessage(taskId, sender, receiver, protoHex, payloadHex, "pat");
}

// -------------------------发送回复消息分区-------------------------

// -------------------------发送语音消息分区-------------------------
function triggerSendVoiceMessage(taskId, sender, receiver, protoHex, payloadHex) {
    return triggerSendMediaMessage(taskId, sender, receiver, protoHex, payloadHex, "voice");
}
// -------------------------发送语音消息分区-------------------------

// ============ R3: 原生 task 构造 + slot13 提交 (4.1.15/4.2.0.5, 默认 off) ============
// 真机探针(2026-10-20, 4.1.15.55)确认:
//   - 全局 service holder: [0xA45DF38]; holder->vt[3]() 返回 class A 的 +0x10 次基址;
//     class A 主对象 = service - 0x10, vptr = base+0x9E8FC30;
//   - class A +0x70/+0x78 = slot13 使用的 RB-tree(root/size), 节点 0x30B:
//     +0x20 key(u32)、+0x28 value(task*);
//   - newsendmsg task: vptr = base+0x9DE8268, +0xC = 0x20A, +0x78/+0xA8 = 内嵌 serializer,
//     +0x68 = hand-off std::function __f_(vtable base+0x9DE82C0, 可 __clone());
//   - UI 提交 = service->vt[+0x28] = 0x46353A0 → `sub x0,x0,#0x10; b 0x4634710`(slot13)。
// 因此 R3: 手工 ctor 造 task → 只把 +0x78(B1) 换 fake serializer 提供 protobuf →
// +0x68 填真实闭包 clone → 直接调 slot13(classA, task)。B2(+0xA8) 保留真实对象,
// 由 req2buf 的 encoder#2 原生 ParseFromArray 接收 B1 产出的字节(避免在 worker 线程跑 JS)。
// 前置: 先捕获一次真实 newsendmsg 闭包(人工发一条文本), 否则发送安全 fail。
// 4.2.0.5(270341) 沿用同一 R3 布局, 但任务类 ctor/vtable/闭包 vtable 与各地址全部不同,
// 一律以版本 JSON 为准; task 尺寸同为 0xE0, 仍由 newSendMsgTaskSize 显式给出。
var r3Cfg = {
    classAVtable: "{{.classAVtable}}",
    globalServiceHolder: "{{.globalServiceHolder}}",
    defaultScopeString: "{{.defaultScopeString}}",
    stringCtorAddr: "{{.stringCtorAddr}}",
    serviceScopeAddr: "{{.serviceScopeAddr}}",
    taskCtorAddr: "{{.newSendMsgTaskCtorAddr}}",
    taskVtable: "{{.newSendMsgTaskVtable}}",
    newSendMsgTaskSize: "{{.newSendMsgTaskSize}}",
    closureVtable: "{{.r3ClosureVtable}}",
    slot13Addr: "{{.slot13Addr}}",
    operatorNewAddr: "{{.operatorNewAddr}}",
    newsendmsgUrl: "{{.newsendmsgUrl}}",
    appmsgUrl: "{{.appmsgUrl}}",
    r3AppMsgSend: "{{.r3AppMsgSend}}",
    sendPatTaskCtorAddr: "{{.sendPatTaskCtorAddr}}",
    sendPatTaskVtable: "{{.sendPatTaskVtable}}",
    sendPatClosureVtable: "{{.sendPatClosureVtable}}",
    sendPatUrl: "{{.sendPatUrl}}",
    sendPatOpcode: "{{.sendPatOpcode}}",
    sendPatTaskSize: "{{.sendPatTaskSize}}",
    r3PatSend: "{{.r3PatSend}}",
    sendPatCopyAddr: "{{.sendPatCopyAddr}}",
    sendPatRequestCtorAddr: "{{.sendPatRequestCtorAddr}}",
    sendPatRequestType: "{{.sendPatRequestType}}",
    protoParseAddr: "{{.protoParseAddr}}",
    closureCapture: "{{.r3ClosureCapture}}",
    slot13Capture: "{{.r3Slot13Capture}}",
    queueUntilSeed: "{{.r3QueueUntilSeed}}",
    maxClones: "{{.r3MaxClones}}"
};
var r3State = {
    cfg: null,
    resolved: false,
    classA: null,
    service: null,
    fakeVt: null,
    sizeCb: null,
    writeCb: null,
    protoBytes: null,
    protoLen: 0,
    seed: null,
    clones: [],
    captureSeen: {},
    capturedCount: 0,
    captureTimer: null,
    sendQueue: [],
    queueFlushing: false,
    pendingSeedPersist: null,
    slot13Hooked: false,
    slot13Listener: null,
    slot13Calls: 0,
    slot13OpCounts: {},
    sentTasks: {},
    taskSeen: {},
    patReqSeen: {},
    pendingCaptures: [],
    pendingResponses: [],
    appmsgSeed: null,
    patReqHooked: false,
    patReqHookedQuiet: false,
    patBuilderHooked: false,
    patBuilderArgs: null,
    patX2Copy: null,
    patX3Copy: null,
    patX4Ptr: null,
    pendingLog: null,
    captureTicks: 0,
    scanTicks: 0,
    nullScans: 0,
    lastScan: null,
    lastError: null
};

function r3ParseAddr(v) {
    // 返回数值偏移: 后续统一用 baseAddr.add(offset), 避免 NativePointer 参与加法
    if (typeof v !== "string" || v.indexOf("0x") !== 0) return null;
    var n = parseInt(v, 16);
    return isNaN(n) ? null : n;
}

function r3IsHeapPtr(p) {
    try {
        return p && !p.isNull() && p.compare(ptr("0x100000000")) > 0 && p.compare(ptr("0x10000000000")) < 0;
    } catch (e) { return false; }
}

function r3Ready() {
    if (!r3ModeActive) return false;
    if (r3State.cfg) return true;
    var cfg = {};
    var keys = ["classAVtable", "globalServiceHolder", "defaultScopeString", "stringCtorAddr",
        "serviceScopeAddr", "taskCtorAddr", "taskVtable", "closureVtable", "slot13Addr",
        "operatorNewAddr"];
    var missing = [];
    for (var i = 0; i < keys.length; i++) {
        var p = r3ParseAddr(r3Cfg[keys[i]]);
        if (p === null) missing.push(keys[i]);
        cfg[keys[i]] = p;
    }
    cfg.newsendmsgUrl = (typeof r3Cfg.newsendmsgUrl === "string" &&
        r3Cfg.newsendmsgUrl.indexOf("/") === 0) ? r3Cfg.newsendmsgUrl : "/cgi-bin/micromsg-bin/newsendmsg";
    cfg.appmsgUrl = (typeof r3Cfg.appmsgUrl === "string" &&
        r3Cfg.appmsgUrl.indexOf("/") === 0) ? r3Cfg.appmsgUrl : "/cgi-bin/micromsg-bin/sendappmsg";
    // 实验能力：复用 newsendmsg 种子构造 sendappmsg task。默认关闭，
    // 由 App 运行期 JSON 在「R3 原生发送 + 被拍时回拍」同时开启时置 true。
    cfg.appMsgSend = (r3Cfg.r3AppMsgSend === "true");
    cfg.sendPatCtor = r3ParseAddr(r3Cfg.sendPatTaskCtorAddr);
    cfg.sendPatVtable = r3ParseAddr(r3Cfg.sendPatTaskVtable);
    cfg.sendPatClosureVtable = r3ParseAddr(r3Cfg.sendPatClosureVtable);
    cfg.sendPatUrl = (typeof r3Cfg.sendPatUrl === "string" && r3Cfg.sendPatUrl.indexOf("/") === 0)
        ? r3Cfg.sendPatUrl : "/cgi-bin/micromsg-bin/sendpat";
    cfg.sendPatOpcode = (typeof r3Cfg.sendPatOpcode === "string")
        ? parseInt(r3Cfg.sendPatOpcode, 16) : 0x351;
    if (isNaN(cfg.sendPatOpcode)) cfg.sendPatOpcode = 0x351;
    cfg.sendPatTaskSize = (typeof r3Cfg.sendPatTaskSize === "string")
        ? parseInt(r3Cfg.sendPatTaskSize, 16) : 0xF8;
    if (isNaN(cfg.sendPatTaskSize) || cfg.sendPatTaskSize < 0xE0) cfg.sendPatTaskSize = 0xF8;
    cfg.sendPatCopy = r3ParseAddr(r3Cfg.sendPatCopyAddr);
    if (cfg.sendPatCopy === null) cfg.sendPatCopy = 0x50eb5c0;
    cfg.sendPatReqCtor = r3ParseAddr(r3Cfg.sendPatRequestCtorAddr);
    if (cfg.sendPatReqCtor === null) cfg.sendPatReqCtor = 0x50ea7d4;
    cfg.sendPatReqType = parseInt(r3Cfg.sendPatRequestType || "62", 10);
    if (isNaN(cfg.sendPatReqType)) cfg.sendPatReqType = 62;
    cfg.protoParse = r3ParseAddr(r3Cfg.protoParseAddr);
    if (cfg.protoParse === null) cfg.protoParse = 0x5ab3ab8;
    cfg.patSend = (r3Cfg.r3PatSend === "true") && cfg.sendPatCtor !== null &&
        cfg.sendPatVtable !== null && cfg.sendPatClosureVtable !== null;
    cfg.closureCapture = (r3Cfg.closureCapture === "true");
    cfg.slot13Capture = (r3Cfg.slot13Capture === "true");
    cfg.queueUntilSeed = (r3Cfg.queueUntilSeed === "true");
    cfg.maxClones = parseInt(r3Cfg.maxClones, 10);
    if (isNaN(cfg.maxClones) || cfg.maxClones < 1) cfg.maxClones = 8;
    // task 结构尺寸: 缺省 0xE0(4.1.15); 4.2.0.5 同样为 0xE0, 由版本 JSON 的
    // newSendMsgTaskSize 显式提供, 便于未来版本变化时不改脚本。
    // 缺键("<no value>")/非法/过小一律回退 0xE0, 保证旧版 4.1.15 JSON 行为不变。
    cfg.taskSize = r3ParseAddr(r3Cfg.newSendMsgTaskSize);
    if (cfg.taskSize === null || isNaN(cfg.taskSize) || cfg.taskSize < 0xE0) cfg.taskSize = 0xE0;
    if (missing.length) {
        r3State.lastError = "R3 JSON 缺少地址键: " + missing.join(",");
        console.error("[!] R3: " + r3State.lastError + " (需要与当前微信版本对应的版本 JSON)");
        return false;
    }
    r3State.cfg = cfg;
    return true;
}

function r3BuildFakeSerializer() {
    if (r3State.fakeVt) return true;
    if (!r3Ready()) return false;
    try {
        if (typeof NativeCallback !== "function") throw new Error("NativeCallback unavailable");
        var vt = Memory.alloc(0x80);
        for (var i = 0; i < 16; i++) vt.add(i * 8).writePointer(retOneStub);
        r3State.sizeCb = new NativeCallback(function (ser) {
            return r3State.protoLen >>> 0;
        }, 'uint32', ['pointer']);
        r3State.writeCb = new NativeCallback(function (ser, dst) {
            var bytes = r3State.protoBytes;
            if (!bytes || !dst || dst.isNull()) return dst;
            dst.writeByteArray(bytes);
            return dst.add(bytes.length);
        }, 'pointer', ['pointer', 'pointer']);
        vt.add(0x48).writePointer(r3State.sizeCb);   // ByteSize
        vt.add(0x58).writePointer(r3State.writeCb);  // SerializeToArray
        r3State.fakeVt = vt;
        console.log("[+] R3: fake B1 serializer vtable = " + vt);
        return true;
    } catch (e) {
        r3State.lastError = "fake serializer: " + e.message;
        console.error("[!] R3: " + r3State.lastError);
        return false;
    }
}

function r3TryResolve(verbose) {
    if (!r3State.cfg) return false;
    if (r3State.resolved && r3State.classA) return true;
    try {
        if (!baseAddr) throw new Error("baseAddr 尚未初始化");
        var cfg = r3State.cfg;
        var str = Memory.alloc(0x18);
        new NativeFunction(baseAddr.add(cfg.stringCtorAddr), 'pointer', ['pointer', 'pointer'])(
            str, baseAddr.add(cfg.defaultScopeString));
        var scope = new NativeFunction(baseAddr.add(cfg.serviceScopeAddr), 'pointer', ['pointer'])(str);
        if (!scope || scope.isNull()) throw new Error("service scope 为空");
        var holder = baseAddr.add(cfg.globalServiceHolder).readPointer();
        if (!r3IsHeapPtr(holder)) throw new Error("全局 service holder 为空");
        var gvt = holder.readPointer();
        var getService = gvt.add(0x18).readPointer();
        var service = new NativeFunction(getService, 'pointer', ['pointer'])(holder);
        if (!service || service.isNull()) throw new Error("service 为空");
        var classA = service.sub(0x10);
        var actual = classA.readPointer();
        if (!actual.equals(baseAddr.add(cfg.classAVtable))) {
            throw new Error("classA vtable 不匹配: " + actual + " != " + baseAddr.add(cfg.classAVtable));
        }
        r3State.service = service;
        r3State.classA = classA;
        r3State.resolved = true;
        console.log("[+] R3: classA=" + classA + " service=" + service + " (vptr 校验通过)");
        return true;
    } catch (e) {
        r3State.lastError = "resolve: " + e.message;
        if (verbose) console.error("[!] R3: 解析 classA 失败: " + e.message);
        return false;
    }
}

function r3ConsiderTask(task) {
    // 返回: 0=不是 task vtable; 1=vtable 命中但不是 newsendmsg; 2=newsendmsg 但 +0x68 不是闭包; 3=已捕获
    try {
        var cfg = r3State.cfg;
        var vt = task.readPointer();
        if (!vt.equals(baseAddr.add(cfg.taskVtable))) return 0;
        if (task.add(0xC).readU32() !== 0x20A) return 1;   // newsendmsg
        var closure = task.add(0x68).readPointer();
        if (!r3IsHeapPtr(closure)) return 2;
        var cvt = closure.readPointer();
        if (!cvt.equals(baseAddr.add(cfg.closureVtable))) return 2;
        var key = closure.toString();
        if (r3State.captureSeen[key]) return 3;
        r3State.captureSeen[key] = true;
        var cloneFn = cvt.add(0x10).readPointer();       // __clone()
        var clone = new NativeFunction(cloneFn, 'pointer', ['pointer'])(closure);
        if (!clone || clone.isNull()) return 2;
        r3State.capturedCount++;
        if (!r3State.seed) r3State.seed = clone;
        if (r3State.clones.length < cfg.maxClones) r3State.clones.push(clone);
        console.log("[+] R3: 捕获 newsendmsg 闭包 " + closure + " -> clone " + clone +
            " (captured=" + r3State.capturedCount + ", kept=" + r3State.clones.length + ")");
        r3State.pendingSeedPersist = clone.toString();
        r3ScheduleFlush();
        return 3;
    } catch (e) {
        r3State.lastError = "capture task: " + e.message;
        return -1;
    }
}

function r3ScanMapOnce() {
    if (!r3State.resolved || !r3State.classA) return;
    var root;
    try { root = r3State.classA.add(0x70).readPointer(); } catch (e) { return; }
    if (!r3IsHeapPtr(root)) { r3State.nullScans = (r3State.nullScans || 0) + 1; return; }
    var stack = [root];
    var seen = 0;
    var st = { nodes: 0, values: 0, vtMatch: 0, opcodeMatch: 0, closureMatch: 0, sampled: [] };
    while (stack.length && seen < 96) {
        var n = stack.pop();
        seen++;
        if (!r3IsHeapPtr(n) || n.and(7).toInt32() !== 0) continue;
        st.nodes++;
        var val = null;
        try { val = n.add(0x28).readPointer(); } catch (e) { val = null; }
        if (r3IsHeapPtr(val)) {
            st.values++;
            var rc = r3ConsiderTask(val);
            if (rc === 0) {
                // 非 newsendmsg task: 采样前几个的 vtable/opcode, 用于诊断
                if (st.sampled.length < 8) {
                    try {
                        st.sampled.push({ vptr: val.readPointer().toString(),
                            opcode: val.add(0xC).readU32(),
                            hasClosure: r3IsHeapPtr(val.add(0x68).readPointer()) });
                    } catch (e) { }
                }
            } else if (rc === 1) st.opcodeMatch++;
            else if (rc === 2) st.vtMatch++;
            else if (rc === 3) { st.vtMatch++; st.opcodeMatch++; st.closureMatch++; }
        }
        try {
            var l = n.readPointer();
            var r = n.add(8).readPointer();
            if (r3IsHeapPtr(r)) stack.push(r);
            if (r3IsHeapPtr(l)) stack.push(l);
        } catch (e) { }
    }
    st.scanTicks = ++r3State.scanTicks;
    r3State.lastScan = st;
}

// slot13 捕获: 只读 onEnter(不写内存、不做 PC 跳转), 在调用线程上直接 __clone 闭包。
// slot13 是 UI 提交的真实入口(0x46353A0 -> 0x4634710), 不在 owl coroutine 上;
// 回调只做少量指针读取 + 一次 __clone, 日志延迟到 10ms 定时器里输出。
// 捕获 sendpat 真实请求对象：高层构造器 0x3399258 会把 requestObject 复制进 B1
// (0x50eb5c0)。记录其 vtable，供后续找到 New/ctor 并复用真实请求类型。
function r3StartPatRequestCapture() {
    if (r3State.patReqHooked) return;
    try {
        var addr = baseAddr.add(0x50eb5c0);
        Interceptor.attach(addr, {
            onEnter: function (args) {
                try {
                    var serializer = args[0];
                    var req = args[1];
                    if (!r3IsHeapPtr(req)) return;
                    var vt = req.readPointer().toString();
                    if (r3State.patReqSeen[vt]) return;
                    r3State.patReqSeen[vt] = true;
                    var line = "[capture] sendpat requestObj=" + req + " vtable=" + vt +
                        " serializer=" + serializer;
                    try {
                        var mod = Process.findModuleByAddress(ptr(vt));
                        if (mod) line += " module=" + mod.name + "@0x" + mod.base.toString(16);
                    } catch (e) { }
                    try {
                        var s10 = readStdStringCompat(req.add(0x10), 256) || "";
                        var s20 = readStdStringCompat(req.add(0x20), 256) || "";
                        var p30 = req.add(0x30).readPointer();
                        var u38 = req.add(0x38).readU32();
                        function ptrStr(off) {
                            try {
                                var p = req.add(off).readPointer();
                                if (p.isNull() || !r3IsHeapPtr(p)) return "";
                                return readStdStringCompat(p, 256) || "";
                            } catch (e) { return "?"; }
                        }
                        line += " s10=" + JSON.stringify(s10) + " s20=" + JSON.stringify(s20) +
                            " p30=" + p30 + " u38=" + u38 +
                            " str10=" + JSON.stringify(ptrStr(0x10)) +
                            " str18=" + JSON.stringify(ptrStr(0x18)) +
                            " str20=" + JSON.stringify(ptrStr(0x20)) +
                            " str28=" + JSON.stringify(ptrStr(0x28));
                        var dump = req.readByteArray(0x48);
                        if (dump) {
                            var arr = new Uint8Array(dump); var hex = "";
                            for (var i = 0; i < arr.length; i++) hex += ("0" + arr[i].toString(16)).slice(-2);
                            line += " objHex=" + hex;
                        }
                    } catch (eMem) { line += " memError=" + eMem.message; }
                    if (r3State.pendingCaptures.length < 8) r3State.pendingCaptures.push(line);
                } catch (e) {
                    if (r3State.pendingCaptures.length < 8) {
                        r3State.pendingCaptures.push("[capture] sendpat request inspect failed: " + e.message);
                    }
                }
            }
        });
        r3State.patReqHooked = true;
        if (!r3State.patReqHookedQuiet) console.log("[+] R3: sendpat request capture hooked");
    } catch (e) {
        console.error("[!] R3: sendpat request hook failed: " + e.message);
    }
}

// 捕获 sendpat 高层构造器 0x3399258 的调用参数：
// x0=service, x1=requestObject, x2=string, x3=context, x4=closure。
function r3StartPatBuilderCapture() {
    if (r3State.patBuilderHooked) return;
    try {
        Interceptor.attach(baseAddr.add(0x3399258), {
            onEnter: function (args) {
                try {
                    var a0 = args[0].toString(), a1 = args[1].toString();
                    var a2 = args[2].toString(), a3 = args[3].toString(), a4 = args[4].toString();
                    r3State.patBuilderArgs = { a0: a0, a1: a1, a2: a2, a3: a3, a4: a4 };
                    try {
                        // 栈上的 x2(std::string)/x3(struct) 在真实调用期间复制到稳定内存；
                        // x4 是真实 std::function/上下文，保留指针（不合成闭包）。
                        r3State.patX2Copy = Memory.alloc(0x18);
                        r3State.patX2Copy.writeByteArray(ptr(a2).readByteArray(0x18));
                        r3State.patX3Copy = Memory.alloc(0x28);
                        r3State.patX3Copy.writeByteArray(ptr(a3).readByteArray(0x28));
                        r3State.patX4Ptr = ptr(a4);
                    } catch (eClone) { }
                    var line = "[capture] sendpat builder args x0=" + a0 + " x1=" + a1 +
                        " x2=" + a2 + " x3=" + a3 + " x4=" + a4;
                    if (r3State.classA) line += " classA=" + r3State.classA;
                    try {
                        var x4p = ptr(a4);
                        var x4vt = x4p.readPointer();
                        line += " x4vt=" + x4vt;
                        var m4 = Process.findModuleByAddress(x4p);
                        if (m4) line += " x4mod=" + m4.name + "@0x" + m4.base.toString(16);
                        var d4 = x4p.readByteArray(0x40);
                        if (d4) {
                            var a4b = new Uint8Array(d4); var h4 = "";
                            for (var i4 = 0; i4 < a4b.length; i4++) h4 += ("0" + a4b[i4].toString(16)).slice(-2);
                            line += " x4hex=" + h4;
                        }
                    } catch (e4) { line += " x4err=" + e4.message; }
                    if (r3State.pendingCaptures.length < 8) r3State.pendingCaptures.push(line);
                } catch (e) {
                    if (r3State.pendingCaptures.length < 8) {
                        r3State.pendingCaptures.push("[capture] sendpat builder inspect failed: " + e.message);
                    }
                }
            }
        });
        r3State.patBuilderHooked = true;
        console.log("[+] R3: sendpat high-level builder hooked");
    } catch (e) {
        console.error("[!] R3: sendpat builder hook failed: " + e.message);
    }
}

function r3StartSlot13Capture(quiet) {
    if (r3State.slot13Hooked) return;
    if (!r3State.cfg) return;
    try {
        var addr = baseAddr.add(r3State.cfg.slot13Addr);
        r3State.slot13Listener = Interceptor.attach(addr, {
            onEnter: function (args) {
                try {
                    var task = args[1];
                    if (!r3IsHeapPtr(task)) return;
                    r3State.slot13Calls++;
                    var op = task.add(0xC).readU32();
                    r3State.slot13OpCounts[op] = (r3State.slot13OpCounts[op] || 0) + 1;
                    // 诊断/取证：只记录 appmsg/非 newsendmsg 任务，避免在高频文本
                    // 发送/启动同步流量里调用 JS/native（曾导致 bridge 启动卡住）。
                    if (op !== 0x20A) {
                        try {
                            var vt = task.readPointer().toString();
                            var url = readStdStringCompat(task.add(0x18), 512) || "";
                            var closure2 = task.add(0x68).readPointer();
                            var cvt2 = (closure2 && !closure2.isNull()) ? closure2.readPointer().toString() : "";
                            var serVt = "";
                            try { serVt = task.add(0x78).readPointer().toString(); } catch (e2) { serVt = ""; }
                            var sig = op + "|" + vt + "|" + url + "|" + cvt2;
                            if (!r3State.taskSeen[sig]) {
                                r3State.taskSeen[sig] = true;
                                // 不能在 slot13 onEnter 里 console.log（Frida IPC 可能与
                                // bridge 的同步 RPC 互相等待）；交给 10ms 定时器输出。
                                if (r3State.pendingCaptures.length < 8) {
                                    var line = "[capture] slot13 task=" + task +
                                        " op=0x" + op.toString(16) + " vtable=" + vt + " url=" + url +
                                        " closureVtable=" + cvt2 + " serVt=" + serVt;
                                    try {
                                        var vtMod = Process.findModuleByAddress(task.readPointer());
                                        if (vtMod) line += " vtModule=" + vtMod.name + "@0x" + vtMod.base.toString(16);
                                        var cvtMod = Process.findModuleByAddress(ptr(cvt2));
                                        if (cvtMod) line += " cvtModule=" + cvtMod.name + "@0x" + cvtMod.base.toString(16);
                                    } catch (eMod) { }
                                    r3State.pendingCaptures.push(line);
                                    if (op === 0x351) {
                                        try {
                                            var ser = task.add(0x78);
                                            var sVt = ser.readPointer();
                                            var sizeFn = new NativeFunction(sVt.add(0x48).readPointer(), 'uint32', ['pointer']);
                                            var protoLen = sizeFn(ser);
                                            var protoHex = "";
                                            if (protoLen > 0 && protoLen < 65536) {
                                                var outBuf = Memory.alloc(protoLen);
                                                var writeFn = new NativeFunction(sVt.add(0x58).readPointer(), 'pointer', ['pointer', 'pointer']);
                                                writeFn(ser, outBuf);
                                                var arr = new Uint8Array(outBuf.readByteArray(protoLen));
                                                for (var bi = 0; bi < arr.length; bi++) {
                                                    protoHex += ("0" + arr[bi].toString(16)).slice(-2);
                                                }
                                            }
                                            var closure3 = task.add(0x68).readPointer();
                                            var seedHex = "";
                                            if (r3IsHeapPtr(closure3)) {
                                                var cvt3 = closure3.readPointer();
                                                var cloneFn3 = cvt3.add(0x10).readPointer();
                                                var clone3 = new NativeFunction(cloneFn3, 'pointer', ['pointer'])(closure3);
                                                if (clone3 && !clone3.isNull()) {
                                                    r3State.appmsgSeed = clone3;
                                                    seedHex = clone3.toString();
                                                }
                                            }
                                            var extra = "";
                                            try {
                                                extra = " t10=" + task.add(0x10).readU32() +
                                                    " b31=" + task.add(0x31).readU8() +
                                                    " b33=" + task.add(0x33).readU8() +
                                                    " s38=" + JSON.stringify(readStdStringCompat(task.add(0x38), 512) || "") +
                                                    " b70=" + task.add(0x70).readU8() +
                                                    " u74=" + task.add(0x74).readU32() +
                                                    " b8vt=" + task.add(0xB8).readPointer();
                                            } catch (eFields) { extra = " fields_error=" + eFields.message; }
                                            r3State.pendingCaptures.push("[capture] sendpat protoLen=" + protoLen +
                                                " protoHex=" + protoHex + " seed=" + seedHex + extra);
                                        } catch (ePat) {
                                            r3State.pendingCaptures.push("[capture] sendpat inspect failed: " + ePat.message);
                                        }
                                    }
                                }
                            }
                        } catch (e4) {
                            console.log("[capture] task inspect failed: " + e4.message);
                        }
                        return;
                    }
                    var closure = task.add(0x68).readPointer();
                    if (!r3IsHeapPtr(closure)) return;
                    var cvt = closure.readPointer();
                    if (!cvt.equals(baseAddr.add(r3State.cfg.closureVtable))) return;
                    if (r3State.captureSeen[closure.toString()]) return;
                    r3State.captureSeen[closure.toString()] = true;
                    var cloneFn = cvt.add(0x10).readPointer();
                    var clone = new NativeFunction(cloneFn, 'pointer', ['pointer'])(closure);
                    if (!clone || clone.isNull()) return;
                    r3State.capturedCount++;
                    if (!r3State.seed) r3State.seed = clone;
                    if (r3State.clones.length < r3State.cfg.maxClones) r3State.clones.push(clone);
                    r3State.pendingLog = "[+] R3: slot13 捕获 newsendmsg 闭包 " + closure + " -> clone " + clone +
                        " (captured=" + r3State.capturedCount + ", kept=" + r3State.clones.length + ")";
                    r3State.pendingSeedPersist = clone.toString();
                    r3ScheduleFlush();
                } catch (e) {
                    r3State.lastError = "slot13 capture: " + e.message;
                }
            }
        });
        r3State.slot13Hooked = true;
        if (!quiet) console.log("[+] R3: slot13 捕获 hook 已安装 @ " + addr + " (只读 onEnter)");
    } catch (e) {
        r3State.lastError = "slot13 hook: " + e.message;
        console.error("[!] R3: slot13 捕获 hook 安装失败: " + e.message);
    }
}

function r3StartCaptureLoop() {
    if (r3State.captureTimer) return;
    if (typeof setInterval !== "function") {
        console.error("[!] R3: 当前 JS 运行时没有 setInterval, 闭包捕获不可用");
        return;
    }
    var tick = 0;
    r3State.captureTimer = setInterval(function () {
        try {
            tick++;
            r3State.captureTicks++;
            if (r3State.pendingLog) {
                console.log(r3State.pendingLog);
                r3State.pendingLog = null;
            }
            while (r3State.pendingCaptures && r3State.pendingCaptures.length) {
                console.log(r3State.pendingCaptures.shift());
            }
            while (r3State.pendingResponses && r3State.pendingResponses.length) {
                console.log(r3State.pendingResponses.shift());
            }
            if (r3State.pendingSeedPersist) {
                try {
                    send({ type: "r3_seed", pid: Process.id, seed: r3State.pendingSeedPersist });
                    console.log("[+] R3: 发送句柄已提交持久化 (seed=" + r3State.pendingSeedPersist + ")");
                } catch (e) { }
                r3State.pendingSeedPersist = null;
            }
            if (!r3State.resolved && (tick % 50) === 0) r3TryResolve(false);
            if (r3State.resolved) r3ScanMapOnce();
        } catch (e) {
            r3State.lastError = "capture tick: " + e.message;
        }
    }, 10);
    console.log("[+] R3: 闭包捕获已启动(10ms 轮询 classA map; 需要一次真实 newsendmsg 发送产生闭包)");
}

function r3Init() {
    if (!r3ModeActive) return;
    if (!r3Ready()) return;
    r3BuildFakeSerializer();
    r3TryResolve(true);
    if (r3State.cfg.slot13Capture) r3StartSlot13Capture();
    if (r3State.cfg.patSend) r3StartPatRequestCapture();
    if (r3State.cfg.patSend) r3StartPatBuilderCapture();
    if (r3State.cfg.closureCapture) r3StartCaptureLoop();
    console.log("[+] R3: init 完成 (capture=" + r3State.cfg.closureCapture +
        ", url=" + r3State.cfg.newsendmsgUrl + ")");
    try {
        send({ type: "r3_mode", enabled: true, url: r3State.cfg.newsendmsgUrl });
    } catch (e) { }
}

// 种子就绪后自动重放排队中的发送请求。队列默认关闭(repo JSON), 产品运行配置会开启。
function r3ScheduleFlush() {
    if (!r3State.cfg || !r3State.cfg.queueUntilSeed) return;
    if (r3State.queueFlushing) return;
    if (!r3State.sendQueue.length) return;
    setImmediate(function () {
        try { r3FlushQueue(); } catch (e) { r3State.lastError = "flush queue: " + e.message; }
    });
}

function r3FlushQueue() {
    if (r3State.queueFlushing) return;
    if (!r3State.seed) return;
    if (!r3State.sendQueue.length) return;
    var pending = r3State.sendQueue;
    r3State.sendQueue = [];
    r3State.queueFlushing = true;
    try {
        var now = Date.now();
        for (var i = 0; i < pending.length; i++) {
            var item = pending[i];
            if (!item) continue;
            if (now - item.ts > 10 * 60 * 1000) {
                console.error("[!] R3: 排队消息已超时(>10min), 丢弃 taskId=" + item.taskId);
                continue;
            }
            try {
                var r = r3SendTextMessage(item.taskId, item.protoHex, true);
                console.log("[+] R3: flush 排队消息 taskId=" + item.taskId + " -> " + r);
            } catch (e) {
                console.error("[!] R3: flush 失败 taskId=" + item.taskId + ": " + e.message);
            }
        }
    } finally {
        r3State.queueFlushing = false;
    }
}

function r3SendTextMessage(taskId, protoHex, fromQueue) {
    if (!r3ModeActive) return "fail";
    if (!r3BuildFakeSerializer()) return "fail";
    if (!r3TryResolve(true)) return "fail";
    if (!r3State.seed) {
        if (r3State.cfg.queueUntilSeed && !fromQueue) {
            r3State.sendQueue.push({ taskId: taskId, protoHex: protoHex, ts: Date.now() });
            if (r3State.sendQueue.length > 8) r3State.sendQueue.shift();
            console.error("[!] R3: 尚无发送句柄(种子闭包), 消息已排队(" + r3State.sendQueue.length +
                "); 请在本机微信(非手机)手动发送一条消息以捕获句柄, 之后会自动重发。");
            return "1";
        }
        console.error("[!] R3: 尚无真实 newsendmsg 闭包 clone; 需要先人工发送一条文本" +
            "(或已有 clone) 才能自动化发送。");
        return "fail";
    }
    return r3SendProtoTask(taskId, protoHex, 0x20A, r3State.cfg.newsendmsgUrl, "text");
}

// 拍一拍：4.1.15 独立 sendpat task（opcode 0x351）。
// 种子来自真实手动拍一拍 task 的 hand-off 闭包（slot13 捕获，见 appmsgSeed）。
function r3SendPatMessage(taskId, protoHex) {
    if (!r3ModeActive) return "fail";
    if (!r3State.cfg) r3Ready();
    if (!r3State.cfg || !r3State.cfg.patSend) {
        console.error("[!] R3 sendpat: 未启用 (r3PatSend=false 或缺少 sendpat 地址)");
        return "fail";
    }
    if (!r3BuildFakeSerializer()) return "fail";
    if (!r3TryResolve(true)) return "fail";
    if (!r3State.appmsgSeed) {
        console.error("[!] R3 sendpat: 尚无发送句柄; 请先在本机微信手动拍一次以捕获 sendpat 闭包。");
        return "fail";
    }
    return r3SendProtoTask(taskId, protoHex, r3State.cfg.sendPatOpcode, r3State.cfg.sendPatUrl,
        "sendpat", {
            ctor: r3State.cfg.sendPatCtor,
            vtable: r3State.cfg.sendPatVtable,
            size: r3State.cfg.sendPatTaskSize,
            seed: r3State.appmsgSeed,
            closureVtable: r3State.cfg.sendPatClosureVtable,
            parseIntoReal: true
        });
}

// 构造 sendpat 真实请求 wrapper（vtable 0x9edcd38 / ctor 0x50ea7d4）：
// +0x10=from, +0x18=chat, +0x20=patted, +0x28=clientMsgId, +0x38=62。
function r3BuildSendPatRequest(sender, chat, patted) {
    var cfg = r3State.cfg;
    if (!cfg || !cfg.sendPatReqCtor) return null;
    var opNew = new NativeFunction(baseAddr.add(cfg.operatorNewAddr), 'pointer', ['size_t']);
    var obj = opNew(0x48);
    if (!obj || obj.isNull()) return null;
    new NativeFunction(baseAddr.add(cfg.sendPatReqCtor), 'void', ['pointer'])(obj);
    var stringCtor = new NativeFunction(baseAddr.add(cfg.stringCtorAddr), 'pointer', ['pointer', 'pointer']);
    function setStr(off, text) {
        if (!text) return;
        var strObj = Memory.alloc(0x18);
        var cstr = Memory.allocUtf8String(text);
        stringCtor(strObj, cstr);
        obj.add(off).writePointer(strObj);
    }
    var chatOrTarget = chat || patted;
    var clientMsgId = chatOrTarget + "_" + Math.floor(Date.now() / 1000) + "_" +
        Math.floor(Math.random() * 1000) + "_" + Date.now();
    setStr(0x10, sender);
    setStr(0x18, chat);
    setStr(0x20, patted);
    setStr(0x28, clientMsgId);
    obj.add(0x38).writeU32(cfg.sendPatReqType);
    return obj;
}

function r3SendPatNative(taskId, sender, chat, patted, protoHex) {
    if (!r3ModeActive) return "fail";
    if (!r3State.cfg) r3Ready();
    if (!r3State.cfg || !r3State.cfg.patSend) return "fail";
    if (!r3TryResolve(true)) return "fail";
    if (!r3State.appmsgSeed) {
        console.error("[!] R3 sendpat: 尚无发送句柄; 请先在本机微信手动拍一次。");
        return "fail";
    }
    if (!r3State.patX2Copy || !r3State.patX3Copy || !r3State.patX4Ptr) {
        console.error("[!] R3 sendpat: 缺少真实高层构造器上下文; 请先手动拍一次。");
        return "fail";
    }
    try {
        var cfg = r3State.cfg;
        var chatForReq = chat || patted;
        var reqObj = r3BuildSendPatRequest(sender, chatForReq, patted);
        if (!reqObj) throw new Error("构造 requestObject 失败");
        var builderFn = new NativeFunction(baseAddr.add(0x3399258), 'int',
            ['pointer', 'pointer', 'pointer', 'pointer', 'pointer']);
        var service = r3State.classA.add(0x10);
        var ret = builderFn(service, reqObj, r3State.patX2Copy, r3State.patX3Copy, r3State.patX4Ptr);
        console.log("[+] R3 sendpat builder-real: service=" + service + " req=" + reqObj +
            " x2=" + r3State.patX2Copy + " x3=" + r3State.patX3Copy +
            " x4=" + r3State.patX4Ptr + " -> " + ret);
        return ret ? "1" : "fail";
    } catch (e) {
        console.error("[!] R3 sendpat builder-real 失败: " + e.message + "\n" + (e.stack || ""));
        return "fail";
    }
}

// 拍一拍旧实验路径：复用 newsendmsg 种子构造 sendappmsg（真机未送达，保留作对照）。
function r3SendAppMsgMessage(taskId, protoHex) {
    if (!r3ModeActive) return "fail";
    if (!r3State.cfg) r3Ready();
    if (!r3State.cfg || !r3State.cfg.appMsgSend) {
        console.error("[!] R3 appmsg: 未启用实验路径 (r3AppMsgSend=false)");
        return "fail";
    }
    if (!r3BuildFakeSerializer()) return "fail";
    if (!r3TryResolve(true)) return "fail";
    if (!r3State.seed) {
        console.error("[!] R3 appmsg: 尚无发送句柄(种子闭包); 请先在本机微信手动发一条文本。");
        return "fail";
    }
    return r3SendProtoTask(taskId, protoHex, 0x6E, r3State.cfg.appmsgUrl, "appmsg");
}

// opcode: 0x20A=newsendmsg text / 0x6E=sendappmsg。url 来自运行期配置。
function r3SendProtoTask(taskId, protoHex, opcode, url, label, opts) {
    var bytes = [];
    try { bytes = hexToByteArray(protoHex || ""); } catch (e) { bytes = []; }
    if (!bytes.length && !(opts && opts.requestObject)) {
        console.error("[!] R3 " + label + ": protoHex 为空");
        return "fail";
    }
    try {
        if (r3State.slot13Listener) {
            try { r3State.slot13Listener.detach(); } catch (e) { }
            r3State.slot13Listener = null;
            r3State.slot13Hooked = false;
            console.log("[+] R3: 发送前卸载 slot13 捕获 hook(避免 JS 重入)");
        }
        var cfg = r3State.cfg;
        opts = opts || {};
        var ctorAddr = opts.ctor || cfg.taskCtorAddr;
        var taskVtable = opts.vtable || cfg.taskVtable;
        var taskSize = opts.size || cfg.taskSize || 0xE0;
        var closureVtableAddr = opts.closureVtable || cfg.closureVtable;
        var closureSeed = opts.seed || r3State.seed;
        console.log("[r3] step1 (" + label + ") proto bytes=" + bytes.length);
        var buf = bytes.length > 0 ? Memory.alloc(bytes.length) : ptr(0);
        if (bytes.length > 0) buf.writeByteArray(bytes);
        r3State.protoBytes = bytes;
        r3State.protoLen = bytes.length;

        // 每次发送从 seed 克隆一个独立闭包: task 析构会销毁(+0x68 heap 形态)
        var closureVtable = baseAddr.add(closureVtableAddr);
        var cloneFn = closureVtable.add(0x10).readPointer();
        console.log("[r3] step1b closureVtable=" + closureVtable + " slot0=" + closureVtable.readPointer() + " cloneFn=" + cloneFn);
        var closure = new NativeFunction(cloneFn, 'pointer', ['pointer'])(closureSeed);
        if (!closure || closure.isNull()) throw new Error("闭包 clone 失败");
        console.log("[r3] step2 closure clone=" + closure);

        // desc(0x38): +0x00/+0x10=opcode, +0x0C=1, +0x18=URL std::string, +0x30=1
        var desc = Memory.alloc(0x38);
        desc.add(0x00).writeU32(opcode);
        desc.add(0x04).writeU32(0);
        desc.add(0x08).writeU32(0);
        desc.add(0x0C).writeU32(1);
        desc.add(0x10).writeU32(opcode);
        desc.add(0x14).writeU32(0);
        var urlCStr = Memory.allocUtf8String(url);
        new NativeFunction(baseAddr.add(cfg.stringCtorAddr), 'pointer', ['pointer', 'pointer'])(
            desc.add(0x18), urlCStr);
        desc.add(0x30).writeU8(1);
        console.log("[r3] step3 (" + label + ") desc=" + desc + " opcode=0x" + opcode.toString(16) + " url=" + url);

        // task := operator new(cfg.taskSize); ctor(task, desc)
        // 尺寸来自版本 JSON(4.1.15/4.2.0.5 均为 0xE0), opts.size 仅 sendpat 等特殊路径覆盖。
        var operatorNew = new NativeFunction(baseAddr.add(cfg.operatorNewAddr), 'pointer', ['size_t']);
        var task = operatorNew(taskSize);
        if (!task || task.isNull()) throw new Error("operator new(0x" + taskSize.toString(16) + ") 失败");
        console.log("[r3] step4 (" + label + ") task=" + task + " size=0x" + taskSize.toString(16));
        new NativeFunction(baseAddr.add(ctorAddr), 'void', ['pointer', 'pointer'])(task, desc);
        console.log("[r3] step5 (" + label + ") ctor done");
        var tv = task.readPointer();
        if (!tv.equals(baseAddr.add(taskVtable))) {
            throw new Error("task vtable 不匹配: " + tv + " expect=" + baseAddr.add(taskVtable));
        }

        // sendpat 的 encoder 直接对 B1(+0x78) 调 SerializeAsString；
        // 对它调原生 ParseFromArray 填入真实 protobuf，避免 fake serializer 兼容问题。
        // 其它文本任务仍用 fake B1；B2 始终保留原生对象。
        if (opts.requestObject) {
            // 真实高层构造器路径：把请求 wrapper 复制进 B1 serializer。
            var copyFn = new NativeFunction(baseAddr.add(cfg.sendPatCopy), 'void', ['pointer', 'pointer']);
            copyFn(task.add(0x78), opts.requestObject);
            console.log("[r3] step5b (" + label + ") copied requestObject=" + opts.requestObject);
        } else if (opts.parseIntoReal) {
            var parseFn = new NativeFunction(baseAddr.add(cfg.protoParse), 'int', ['pointer', 'pointer', 'int']);
            var parsed = parseFn(task.add(0x78), buf, bytes.length);
            if (!parsed) throw new Error("sendpat ParseFromArray 失败");
            console.log("[r3] step5b (" + label + ") real B1 ParseFromArray ok len=" + bytes.length);
        } else {
            task.add(0x78).writePointer(r3State.fakeVt);
        }
        task.add(0x68).writePointer(closure);

        console.log("[r3] step6 (" + label + ") fakeVt=" + r3State.fakeVt + " closure=" + closure + " -> calling slot13");
        var slot13 = new NativeFunction(baseAddr.add(cfg.slot13Addr), 'int', ['pointer', 'pointer']);
        var ret = slot13(r3State.classA, task);
        // 诊断：记录任务 id，便于在 buf2resp 里确认 R3 任务是否真的发出/回包。
        // slot13 可能把原生 taskId 写到 task+0x08；不确定时同时登记入参 taskId。
        var nativeTaskId = 0;
        try { nativeTaskId = task.add(0x08).readU32(); } catch (e) { nativeTaskId = 0; }
        var now = Date.now();
        r3State.sentTasks[taskId] = { label: label, at: now };
        if (nativeTaskId > 0 && nativeTaskId !== taskId) {
            r3State.sentTasks[nativeTaskId] = { label: label, at: now };
        }
        for (var k in r3State.sentTasks) {
            if (now - r3State.sentTasks[k].at > 5 * 60 * 1000) delete r3State.sentTasks[k];
        }
        console.log("[+] R3 " + label + ": slot13(classA=" + r3State.classA + ", task=" + task + ") -> " + ret +
            " (proto=" + bytes.length + "B, clone=" + closure + ", taskIdArg=" + taskId +
            ", nativeTaskId=" + nativeTaskId + ")");
        if (cfg.slot13Capture) {
            setImmediate(function () {
                try { r3StartSlot13Capture(true); } catch (e) { }
            });
        }
        return "1";
    } catch (e) {
        r3State.lastError = label + " send: " + e.message;
        console.error("[!] R3 " + label + " 发送失败: " + e.message + "\n" + (e.stack || ""));
        return "fail";
    }
}

function r3ScanOnce() {
    if (!r3TryResolve(false)) return JSON.stringify({ resolved: false, lastError: r3State.lastError });
    r3ScanMapOnce();
    return JSON.stringify({ resolved: true, lastScan: r3State.lastScan, captured: r3State.capturedCount });
}

function r3MapDump(limit) {
    limit = limit || 24;
    if (!r3TryResolve(false)) return JSON.stringify({ resolved: false, lastError: r3State.lastError });
    var out = { classA: r3State.classA.toString(), root: null, size: null, entries: [] };
    try {
        var root = r3State.classA.add(0x70).readPointer();
        out.root = root.toString();
        out.size = r3State.classA.add(0x78).readU32();
        var stack = [root], seen = 0;
        while (stack.length && seen < limit) {
            var n = stack.pop();
            seen++;
            if (!r3IsHeapPtr(n) || n.and(7).toInt32() !== 0) continue;
            var key = null, val = null, vptr = null, op = null, cl = null;
            try { key = n.add(0x20).readU32(); } catch (e) { }
            try { val = n.add(0x28).readPointer(); } catch (e) { }
            if (r3IsHeapPtr(val)) {
                try { vptr = val.readPointer().toString(); } catch (e) { }
                try { op = val.add(0xC).readU32(); } catch (e) { }
                try { cl = val.add(0x68).readPointer(); } catch (e) { }
                out.entries.push({ node: n.toString(), key: key, value: val.toString(), vptr: vptr,
                    opcode: op, closure: (cl && !cl.isNull()) ? cl.toString() : null });
            }
            try {
                var l = n.readPointer(), r = n.add(8).readPointer();
                if (r3IsHeapPtr(r)) stack.push(r);
                if (r3IsHeapPtr(l)) stack.push(l);
            } catch (e) { }
        }
    } catch (e) { out.error = e.message; }
    return JSON.stringify(out);
}

function r3Dbg() {
    var out = { base: baseAddr ? baseAddr.toString() : null };
    try {
        out.cfg = { closureVtable: r3State.cfg.closureVtable, taskVtable: r3State.cfg.taskVtable,
            slot13Addr: r3State.cfg.slot13Addr, stringCtorAddr: r3State.cfg.stringCtorAddr };
        out.cfgTypes = { closureVtable: typeof r3State.cfg.closureVtable };
        var cvt = baseAddr.add(r3State.cfg.closureVtable);
        out.closureVtable = cvt.toString();
        out.slot0 = cvt.readPointer().toString();
        out.cloneFn = cvt.add(0x10).readPointer().toString();
        out.seed = r3State.seed ? r3State.seed.toString() : null;
        out.seedVptr = r3State.seed ? r3State.seed.readPointer().toString() : null;
    } catch (e) {
        out.error = e.message;
        out.stack = e.stack;
    }
    return JSON.stringify(out);
}

// 采用 bridge 持久化的句柄（clone 对象仍在微信进程堆中，需校验 vtable）。
function r3AdoptSeed(seedHex) {
    if (!r3ModeActive || !r3Ready()) return "off";
    if (r3State.seed) return "ok";
    try {
        var seed = ptr(seedHex);
        if (!r3IsHeapPtr(seed)) return "invalid";
        var vptr = seed.readPointer();
        if (!vptr.equals(baseAddr.add(r3State.cfg.closureVtable))) return "invalid";
        r3State.seed = seed;
        r3State.capturedCount++;
        console.log("[+] R3: 从 bridge 恢复发送句柄 seed=" + seed);
        r3ScheduleFlush();
        return "ok";
    } catch (e) {
        return "invalid: " + e.message;
    }
}

function r3SetSeed(seedHex) {
    return r3AdoptSeed(seedHex);
}

// bridge 重启后恢复：先校验持久化记录里的微信 PID 是否仍是当前进程。
function r3RestoreSeed(pid, seedHex) {
    if (!r3ModeActive || !r3Ready()) return "off";
    if (typeof pid === "number" && pid !== Process.id) return "stale";
    return r3AdoptSeed(seedHex);
}

function r3Status() {
    return JSON.stringify({
        mode: REQ2BUF_SEND_MODE,
        active: r3ModeActive,
        resolved: !!r3State.resolved,
        classA: r3State.classA ? r3State.classA.toString() : null,
        keptClones: r3State.clones.length,
        captured: r3State.capturedCount,
        captureTimer: !!r3State.captureTimer,
        slot13Hooked: r3State.slot13Hooked,
        slot13Calls: r3State.slot13Calls,
        queued: r3State.sendQueue.length,
        slot13OpCounts: r3State.slot13OpCounts,
        captureTicks: r3State.captureTicks,
        scanTicks: r3State.scanTicks,
        nullScans: r3State.nullScans,
        lastScan: r3State.lastScan,
        appMsgSend: r3State.cfg ? !!r3State.cfg.appMsgSend : false,
        lastError: r3State.lastError
    });
}

// ===================== 通讯录（好友昵称/群名）分区 =====================
// 微信 4.1.15 的入站事件只有 wxid，真实昵称/群名在 SQLCipher4 加密的
// db_storage/contact/contact.db 里。这里在微信进程内：
//   1) Hook 系统 CommonCrypto，捕获 SQLCipher 的 32 字节 enc_key
//      （CCCryptorCreate / CCCrypt / CCCryptorCreateWithMode），
//      以及登录期 CCKeyDerivationPBKDF 的 passphrase/派生 key；
//   2) 用捕获的 key 在进程内解密 contact.db（含 WAL 当前代帧）到容器 tmp；
//   3) 用 Frida 内置 SqliteDatabase 查询 contact 表，返回 wxid→昵称/备注、群→群名；
//   4) 查完立即删除临时明文库。
//
// 页格式（4.1.15 实测）：4096 字节/页，reserve=80（IV16+HMAC64），AES-256-CBC；
// 页 1 前 16 字节是 salt；其余页密文 [0,4016)、IV [4016,4032)、HMAC [4032,4096)。
// 密钥只用页 1 试解密校验（SQLite format 3\0），不依赖 HMAC 实现。
// 契约见 docs/architecture.md §3。
var contactDirectoryEnabled = "{{.contactDirectory}}" === "true";
var CONTACT_PAGE_SIZE = 4096;
var CONTACT_RESERVE = 80;
var CONTACT_CT_LEN = CONTACT_PAGE_SIZE - CONTACT_RESERVE; // 4016
var CONTACT_SALT_LEN = 16;
var CONTACT_IV_LEN = 16;
var CONTACT_MAX_DB_BYTES = 64 * 1024 * 1024;
var CONTACT_MAX_CANDIDATES = 128;
var CONTACT_MAX_ENTRIES = 20000;
var CONTACT_MAX_GROUP_MEMBERS = 2000;
var CONTACT_SQLITE_HDR = [0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, 0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00];
var contactState = {
    installed: false,
    ccCrypt: null,
    pbkdf2: null,
    unlinkFn: null,
    inCrypto: false,
    keysBySalt: {},      // saltHex -> keyHex（已用页 1 校验）
    providedKeys: {},    // saltHex -> keyHex（bridge 从缓存回灌）
    candidates: [],      // 未校验的 keyHex（AES 调用 / PBKDF2 输出）
    candidateSet: {},
    passphraseHex: null,
    derivedBySalt: {},   // saltHex -> keyHex（PBKDF2 输出，已校验前）
    lastError: null
};

function contactDebug() {
    if (!HOOK_DEBUG) return;
    try {
        var parts = ["[contact]"];
        for (var i = 0; i < arguments.length; i++) parts.push(arguments[i]);
        console.log(parts.join(" "));
    } catch (e) { /* 日志失败不影响 Hook */ }
}

function contactFindExport(name) {
    try {
        if (typeof Module.findGlobalExportByName === "function") {
            var p = Module.findGlobalExportByName(name);
            if (p) return p;
        }
    } catch (e) { /* 旧版 Frida 没有该 API */ }
    try {
        if (typeof Module.findExportByName === "function") {
            var q = Module.findExportByName(null, name);
            if (q) return q;
        }
    } catch (e) { }
    try {
        var m = Process.findModuleByName("libcommonCrypto.dylib");
        if (m && typeof m.findExportByName === "function") {
            var r = m.findExportByName(name);
            if (r) return r;
        }
    } catch (e) { }
    return null;
}

function contactHexToBytes(hex) {
    var out = [];
    for (var i = 0; i + 1 < hex.length; i += 2) out.push(parseInt(hex.substr(i, 2), 16));
    return out;
}

function contactBytesToHex(bytes) {
    var s = "";
    for (var i = 0; i < bytes.length; i++) s += ("0" + bytes[i].toString(16)).slice(-2);
    return s;
}

function contactPtrHex(p, len) {
    if (!p || p.isNull() || len <= 0) return null;
    try {
        return contactBytesToHex(new Uint8Array(p.readByteArray(len)));
    } catch (e) {
        return null;
    }
}

function contactU32BE(u8, off) {
    return ((u8[off] << 24) | (u8[off + 1] << 16) | (u8[off + 2] << 8) | u8[off + 3]) >>> 0;
}

function contactU32LE(u8, off) {
    return (u8[off] | (u8[off + 1] << 8) | (u8[off + 2] << 16) | (u8[off + 3] << 24)) >>> 0;
}

// 候选 key 去重；日志里绝不打印 key 本身。
function contactNoteCandidate(hex, source) {
    try {
        if (!hex || hex.length !== 64) return;
        if (contactState.candidateSet[hex]) return;
        if (contactState.candidates.length >= CONTACT_MAX_CANDIDATES) return;
        contactState.candidateSet[hex] = source || "aes";
        contactState.candidates.push(hex);
        contactDebug("新 key 候选 source=" + (source || "aes") + " total=" + contactState.candidates.length);
    } catch (e) {
        contactState.lastError = String(e);
    }
}

function contactCaptureAesKey(keyPtr, keyLen, source) {
    try {
        if (!contactDirectoryEnabled || contactState.inCrypto) return;
        if (keyLen !== 32) return;
        contactNoteCandidate(contactPtrHex(keyPtr, 32), source);
    } catch (e) {
        contactState.lastError = String(e);
    }
}

function contactSetupHooks() {
    if (contactState.installed) return;
    if (!contactDirectoryEnabled) {
        console.log("[contact] 通讯录读取未启用（版本 JSON contactDirectory != true）");
        return;
    }
    try {
        if (typeof File === "undefined" || typeof SqliteDatabase === "undefined") {
            console.log("[!] [contact] 当前 Frida 运行时不支持 File/SqliteDatabase，通讯录读取关闭");
            return;
        }
        var cc = contactFindExport("CCCrypt");
        if (!cc) {
            console.log("[!] [contact] 找不到系统 CCCrypt，通讯录读取关闭");
            return;
        }
        contactState.ccCrypt = new NativeFunction(cc, "int",
            ["uint32", "uint32", "uint32", "pointer", "ulong", "pointer", "pointer", "ulong", "pointer", "ulong", "pointer"]);
        var pbkdf2 = contactFindExport("CCKeyDerivationPBKDF");
        if (pbkdf2) {
            contactState.pbkdf2 = new NativeFunction(pbkdf2, "int",
                ["uint32", "pointer", "ulong", "pointer", "ulong", "uint32", "uint32", "pointer", "ulong"]);
        }
        var create = contactFindExport("CCCryptorCreate");
        var createMode = contactFindExport("CCCryptorCreateWithMode");
        var crypt = contactFindExport("CCCrypt");
        if (create) {
            Interceptor.attach(create, {
                onEnter: function (args) {
                    try {
                        var alg = args[1].toInt32();
                        if (alg !== 0) return; // kCCAlgorithmAES
                        contactCaptureAesKey(args[3], args[4].toInt32(), "create");
                    } catch (e) { contactState.lastError = String(e); }
                }
            });
        }
        if (createMode) {
            Interceptor.attach(createMode, {
                onEnter: function (args) {
                    try {
                        if (args[2].toInt32() !== 0) return; // kCCAlgorithmAES
                        contactCaptureAesKey(args[5], args[6].toInt32(), "createMode");
                    } catch (e) { contactState.lastError = String(e); }
                }
            });
        }
        if (crypt) {
            Interceptor.attach(crypt, {
                onEnter: function (args) {
                    try {
                        if (args[1].toInt32() !== 0) return; // kCCAlgorithmAES
                        contactCaptureAesKey(args[3], args[4].toInt32(), "crypt");
                    } catch (e) { contactState.lastError = String(e); }
                }
            });
        }
        if (pbkdf2) {
            // 登录期：rounds=256000 输出 32 字节 → passphrase 与 enc_key。
            Interceptor.attach(pbkdf2, {
                onEnter: function (args) {
                    try {
                        if (contactState.inCrypto) return;
                        if (args[6].toInt32() !== 256000) return;
                        if (args[2].toInt32() !== 32 || args[8].toInt32() !== 32) return;
                        var pw = contactPtrHex(args[1], 32);
                        var out = contactPtrHex(args[7], 32);
                        var salt = contactPtrHex(args[3], 16);
                        if (pw) contactState.passphraseHex = pw;
                        if (out) contactNoteCandidate(out, "pbkdf2");
                        if (salt && out) contactState.derivedBySalt[salt] = out;
                        contactDebug("捕获 PBKDF2 passphrase/enc_key salt=" + (salt ? salt.substring(0, 8) : "?"));
                    } catch (e) { contactState.lastError = String(e); }
                }
            });
        }
        contactState.installed = true;
        console.log("[+] [contact] 通讯录 Hook 已安装（AES key + PBKDF2 passphrase 捕获）");
    } catch (e) {
        console.log("[!] [contact] Hook 安装失败: " + e);
    }
}

function contactAesDecrypt(keyBuf, ctBytes, ivBytes) {
    try {
        var inBuf = Memory.alloc(ctBytes.length);
        inBuf.writeByteArray(ctBytes);
        var ivBuf = Memory.alloc(16);
        ivBuf.writeByteArray(ivBytes);
        var outBuf = Memory.alloc(ctBytes.length);
        var moved = Memory.alloc(8);
        moved.writeU64(0);
        contactState.inCrypto = true;
        var rc;
        try {
            rc = contactState.ccCrypt(1, 0, 0, keyBuf, 32, ivBuf, inBuf, ctBytes.length, outBuf, ctBytes.length, moved);
        } finally {
            contactState.inCrypto = false;
        }
        if (rc !== 0) return null;
        return new Uint8Array(outBuf.readByteArray(ctBytes.length));
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

function contactPage1MatchesKey(keyHex, page1) {
    try {
        var keyBuf = Memory.alloc(32);
        keyBuf.writeByteArray(contactHexToBytes(keyHex));
        var plain = contactAesDecrypt(keyBuf, page1.subarray(16, CONTACT_CT_LEN), page1.subarray(CONTACT_CT_LEN, CONTACT_CT_LEN + 16));
        if (!plain) return false;
        // 页 1 的明文中 [0,16) 是 "SQLite format 3\0"，但 SQLCipher 只加密
        // [16,4016)，所以解密输出的 plain[0] 对应明文第 16 字节：页大小高位、
        // 保留区大小等固定字段，用来校验 key 是否正确。
        return plain[0] === 0x10 && plain[1] === 0x00 && plain[4] === 0x50;
    } catch (e) {
        contactState.lastError = String(e);
        return false;
    }
}

function contactDeriveKeyFromPassphrase(passphraseHex, saltHex) {
    if (!contactState.pbkdf2) return null;
    try {
        var pw = Memory.alloc(32);
        pw.writeByteArray(contactHexToBytes(passphraseHex));
        var salt = Memory.alloc(16);
        salt.writeByteArray(contactHexToBytes(saltHex));
        var out = Memory.alloc(32);
        contactState.inCrypto = true;
        var rc;
        try {
            // CommonCrypto: kCCPBKDF2=2, kCCPRFHmacAlgSHA512=5
            rc = contactState.pbkdf2(2, pw, 32, salt, 16, 5, 256000, out, 32);
        } finally {
            contactState.inCrypto = false;
        }
        if (rc !== 0) return null;
        return contactBytesToHex(new Uint8Array(out.readByteArray(32)));
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

// 用页 1 校验并缓存某个 DB 的 key。
function contactResolveKeyByPage1(page1) {
    try {
        if (!page1 || page1.length < CONTACT_PAGE_SIZE) return null;
        var salt = contactBytesToHex(page1.subarray(0, 16));
        var cached = contactState.keysBySalt[salt];
        if (cached && contactPage1MatchesKey(cached, page1)) return { salt: salt, keyHex: cached };
        var provided = contactState.providedKeys[salt];
        if (provided && contactPage1MatchesKey(provided, page1)) {
            contactState.keysBySalt[salt] = provided;
            return { salt: salt, keyHex: provided };
        }
        var derived = contactState.derivedBySalt[salt];
        if (derived && contactPage1MatchesKey(derived, page1)) {
            contactState.keysBySalt[salt] = derived;
            return { salt: salt, keyHex: derived };
        }
        for (var i = 0; i < contactState.candidates.length; i++) {
            var candidate = contactState.candidates[i];
            if (contactPage1MatchesKey(candidate, page1)) {
                contactState.keysBySalt[salt] = candidate;
                contactDebug("页 1 校验通过 salt=" + salt.substring(0, 8) + " source=candidate");
                return { salt: salt, keyHex: candidate };
            }
        }
        if (contactState.passphraseHex) {
            var k = contactDeriveKeyFromPassphrase(contactState.passphraseHex, salt);
            if (k && contactPage1MatchesKey(k, page1)) {
                contactState.keysBySalt[salt] = k;
                contactDebug("页 1 校验通过 salt=" + salt.substring(0, 8) + " source=passphrase");
                return { salt: salt, keyHex: k };
            }
        }
        return null;
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

function contactDecryptPageAt(u8, offset, pgno, keyBuf) {
    try {
        var ctOff, ctLen, ivOff;
        if (pgno === 1) {
            ctOff = offset + CONTACT_SALT_LEN;
            ctLen = CONTACT_CT_LEN - CONTACT_SALT_LEN; // 4000
            ivOff = offset + CONTACT_CT_LEN;
        } else {
            ctOff = offset;
            ctLen = CONTACT_CT_LEN; // 4016
            ivOff = offset + CONTACT_CT_LEN;
        }
        var ct = u8.subarray(ctOff, ctOff + ctLen);
        var iv = u8.subarray(ivOff, ivOff + 16);
        var plain = contactAesDecrypt(keyBuf, ct, iv);
        if (!plain) return null;
        var page = new Uint8Array(CONTACT_PAGE_SIZE);
        page.set(plain, pgno === 1 ? CONTACT_SALT_LEN : 0);
        if (pgno === 1) {
            for (var i = 0; i < 16; i++) page[i] = CONTACT_SQLITE_HDR[i];
        }
        return page;
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

// SQLite WAL 校验和：8 字节一组，按本机字节序读 u32；
// magic 低 bit=1 表示异序（byte-swapped），与 sqlite walChecksumBytes 一致。
function contactWalChecksum(u8, offset, len, s1, s2, bigEndCksum) {
    var end = offset + len;
    for (var i = offset; i < end; i += 8) {
        var w0 = bigEndCksum ? contactU32BE(u8, i) : contactU32LE(u8, i);
        var w1 = bigEndCksum ? contactU32BE(u8, i + 4) : contactU32LE(u8, i + 4);
        s1 = (s1 + w0 + s2) >>> 0;
        s2 = (s2 + w1 + s1) >>> 0;
    }
    return [s1, s2];
}

// 把 WAL 中「当前代」已提交帧合并进 pages。旧代帧（salt 不匹配/校验和断链）忽略。
function contactApplyWal(dbPath, keyBuf, pages) {
    var wal;
    try {
        wal = new Uint8Array(File.readAllBytes(dbPath + "-wal"));
    } catch (e) {
        return 0; // 没有 WAL 或不可读：主库已是最新
    }
    if (wal.length < 32 + 24 + CONTACT_PAGE_SIZE) return 0;
    try {
        var magic = contactU32BE(wal, 0);
        if (contactU32BE(wal, 8) !== CONTACT_PAGE_SIZE) return 0;
        if (magic !== 0x377f0682 && magic !== 0x377f0683) return 0;
        var bigEndCksum = (magic & 1) === 1;
        var hs1 = contactU32BE(wal, 16), hs2 = contactU32BE(wal, 20);
        var hc1 = contactU32BE(wal, 24), hc2 = contactU32BE(wal, 28);
        var headerCk = contactWalChecksum(wal, 0, 24, 0, 0, bigEndCksum);
        if (headerCk[0] !== hc1 || headerCk[1] !== hc2) {
            contactDebug("WAL 头校验失败，忽略 WAL");
            return 0;
        }
        var frames = [];
        var cs1 = hc1, cs2 = hc2;
        var off = 32;
        var lastCommit = -1;
        while (off + 24 + CONTACT_PAGE_SIZE <= wal.length) {
            var pgno = contactU32BE(wal, off);
            var ntrunc = contactU32BE(wal, off + 4);
            var fs1 = contactU32BE(wal, off + 8);
            var fs2 = contactU32BE(wal, off + 12);
            var fc1 = contactU32BE(wal, off + 16);
            var fc2 = contactU32BE(wal, off + 20);
            if (fs1 !== hs1 || fs2 !== hs2) break; // 上一代残留帧
            var ck = contactWalChecksum(wal, off, 16, cs1, cs2, bigEndCksum);
            ck = contactWalChecksum(wal, off + 24, CONTACT_PAGE_SIZE, ck[0], ck[1], bigEndCksum);
            if (ck[0] !== fc1 || ck[1] !== fc2) break;
            frames.push({ pgno: pgno, offset: off + 24 });
            if (ntrunc !== 0) lastCommit = frames.length - 1;
            cs1 = fc1;
            cs2 = fc2;
            off += 24 + CONTACT_PAGE_SIZE;
        }
        if (lastCommit < 0) return 0;
        var applied = 0;
        for (var i = 0; i <= lastCommit; i++) {
            var f = frames[i];
            if (f.pgno < 1 || f.pgno > 200000) continue;
            var plain = contactDecryptPageAt(wal, f.offset, f.pgno, keyBuf);
            if (plain) {
                pages[f.pgno] = plain;
                applied++;
            }
        }
        if (applied > 0) contactDebug("WAL 已合并帧 " + applied + "/" + frames.length);
        return applied;
    } catch (e) {
        contactState.lastError = String(e);
        return 0;
    }
}

function contactDecryptDatabase(dbBytes, keyHex, dbPath) {
    try {
        var keyBuf = Memory.alloc(32);
        keyBuf.writeByteArray(contactHexToBytes(keyHex));
        var pageCount = Math.floor(dbBytes.length / CONTACT_PAGE_SIZE);
        if (pageCount <= 0) return null;
        var pages = new Array(pageCount + 1);
        var bad = 0;
        for (var p = 1; p <= pageCount; p++) {
            var page = contactDecryptPageAt(dbBytes, (p - 1) * CONTACT_PAGE_SIZE, p, keyBuf);
            if (!page) bad++;
            pages[p] = page;
        }
        if (!pages[1]) return null;
        var walApplied = contactApplyWal(dbPath, keyBuf, pages);
        var total = 0;
        for (var k in pages) {
            if (pages[k] && parseInt(k, 10) > total) total = parseInt(k, 10);
        }
        var out = new Uint8Array(total * CONTACT_PAGE_SIZE);
        for (var i = 1; i <= total; i++) {
            if (pages[i]) out.set(pages[i], (i - 1) * CONTACT_PAGE_SIZE);
        }
        return { bytes: out, pages: total, bad: bad, walApplied: walApplied };
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

function contactTempDir(dbStoragePath) {
    var idx = dbStoragePath.indexOf("/Documents/");
    if (idx > 0) return dbStoragePath.substring(0, idx) + "/tmp";
    return null;
}

function contactWriteTempDb(bytes, dbStoragePath) {
    try {
        var dir = contactTempDir(dbStoragePath);
        if (!dir) return null;
        var path = dir + "/wechatai-contact-" + Process.id + "-" + Date.now().toString(36) + ".db";
        File.writeAllBytes(path, bytes.buffer);
        return path;
    } catch (e) {
        contactState.lastError = String(e);
        return null;
    }
}

function contactUnlink(path) {
    try {
        if (!path) return;
        if (!contactState.unlinkFn) {
            var p = contactFindExport("unlink");
            if (p) contactState.unlinkFn = new NativeFunction(p, "int", ["pointer"]);
        }
        if (contactState.unlinkFn) {
            contactState.unlinkFn(Memory.allocUtf8String(path));
        }
    } catch (e) { /* 清理失败不影响结果 */ }
}

function contactCleanupTempDb(path) {
    if (!path) return;
    contactUnlink(path);
    contactUnlink(path + "-wal");
    contactUnlink(path + "-shm");
    contactUnlink(path + "-journal");
}

// 群成员「群昵称」解析：chat_room.ext_buffer 是 protobuf：
//   field 1 (repeated) Member { 1: username, 2: group_nickname, 3: flags(varint), 4: inviter }
// 同一个人在群里的显示名可能和通讯录昵称/备注不同（如好友昵称 "小明"、
// 群昵称 "群里的昵称"），群聊场景应优先用群昵称。
function contactUtf8(u8) {
    var out = "";
    var i = 0;
    while (i < u8.length) {
        var c = u8[i++];
        if (c < 0x80) {
            out += String.fromCharCode(c);
        } else if (c >= 0xc0 && c < 0xe0) {
            if (i >= u8.length) break;
            out += String.fromCharCode(((c & 0x1f) << 6) | (u8[i++] & 0x3f));
        } else if (c >= 0xe0 && c < 0xf0) {
            if (i + 1 >= u8.length) break;
            out += String.fromCharCode(((c & 0x0f) << 12) | ((u8[i++] & 0x3f) << 6) | (u8[i++] & 0x3f));
        } else if (c >= 0xf0) {
            if (i + 2 >= u8.length) break;
            var cp = (((c & 0x07) << 18) | ((u8[i++] & 0x3f) << 12) |
                ((u8[i++] & 0x3f) << 6) | (u8[i++] & 0x3f)) - 0x10000;
            out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
        }
    }
    return out;
}

function contactParseGroupMembers(hex) {
    var members = {};
    if (!hex || hex.length < 6 || hex.length % 2 !== 0) return members;
    var bytes;
    try {
        bytes = new Uint8Array(contactHexToBytes(hex));
    } catch (e) {
        return members;
    }
    var count = 0;
    function readVarint(buf, pos) {
        var value = 0, shift = 0, b;
        do {
            if (pos >= buf.length || shift > 49) throw new Error("varint");
            b = buf[pos++];
            value += (b & 0x7f) * Math.pow(2, shift);
            shift += 7;
        } while (b & 0x80);
        return [value, pos];
    }
    function readBytes(buf, pos) {
        var r = readVarint(buf, pos);
        var len = r[0];
        pos = r[1];
        if (len < 0 || pos + len > buf.length) throw new Error("len");
        return [buf.subarray(pos, pos + len), pos + len];
    }
    try {
        var pos = 0;
        while (pos < bytes.length && count < CONTACT_MAX_GROUP_MEMBERS) {
            var tr = readVarint(bytes, pos);
            var key = tr[0];
            pos = tr[1];
            var field = Math.floor(key / 8), wire = key % 8;
            if (field !== 1 || wire !== 2) break; // 成员列表之后是房间级字段，不再需要
            var sr = readBytes(bytes, pos);
            var msg = sr[0];
            pos = sr[1];
            var mp = 0, username = "", display = "";
            while (mp < msg.length) {
                var mr = readVarint(msg, mp);
                var mk = mr[0];
                mp = mr[1];
                var mf = Math.floor(mk / 8), mw = mk % 8;
                if (mw === 2) {
                    var vr = readBytes(msg, mp);
                    var val = vr[0];
                    mp = vr[1];
                    if (mf === 1) username = contactUtf8(val);
                    else if (mf === 2) display = contactUtf8(val);
                } else if (mw === 0) {
                    var skip = readVarint(msg, mp);
                    mp = skip[1];
                } else if (mw === 5) {
                    mp += 4;
                } else if (mw === 1) {
                    mp += 8;
                } else {
                    break;
                }
                if (username.length > 128) break;
            }
            if (username) {
                // 未设置群昵称时 display 留空：调用方（bridge）回退到通讯录显示名，
                // 不能把 wxid 当成群昵称写进 sender.nickname。
                members[username] = {
                    display: display,
                    nickname: display,
                    remark: "",
                    alias: ""
                };
                count++;
            }
        }
    } catch (e) {
        contactDebug("群昵称解析失败: " + e);
    }
    return members;
}

function contactQueryDirectory(dbPath) {
    var users = {};
    var groups = {};
    var count = 0;
    var db = null;
    try {
        db = SqliteDatabase.open(dbPath);
        var stmt = db.prepare("SELECT username, nick_name, remark, alias, delete_flag FROM contact;");
        var row = stmt.step();
        while (row && count < CONTACT_MAX_ENTRIES) {
            var username = row[0] ? String(row[0]) : "";
            var deleted = row[4] ? Number(row[4]) : 0;
            if (username && !deleted) {
                var nick = row[1] ? String(row[1]) : "";
                var remark = row[2] ? String(row[2]) : "";
                var alias = row[3] ? String(row[3]) : "";
                var entry = {
                    display: remark || nick || alias || username,
                    nickname: nick,
                    remark: remark,
                    alias: alias
                };
                if (username.indexOf("@chatroom") >= 0) groups[username] = entry;
                else users[username] = entry;
                count++;
            }
            row = stmt.step();
        }
        // 群昵称：同一个人在群里的显示名可能与通讯录不同，群聊优先用群昵称。
        var roomStmt = db.prepare("SELECT username, hex(ext_buffer) FROM chat_room WHERE username IS NOT NULL;");
        var roomRow = roomStmt.step();
        var roomCount = 0;
        while (roomRow && roomCount < CONTACT_MAX_ENTRIES) {
            var roomID = roomRow[0] ? String(roomRow[0]) : "";
            if (roomID) {
                var members = contactParseGroupMembers(roomRow[1] ? String(roomRow[1]) : "");
                if (Object.keys(members).length > 0) {
                    if (!groups[roomID]) {
                        groups[roomID] = {
                            display: roomID,
                            nickname: "",
                            remark: "",
                            alias: ""
                        };
                    }
                    groups[roomID].members = members;
                }
                roomCount++;
            }
            roomRow = roomStmt.step();
        }
    } finally {
        try {
            if (db) db.close();
        } catch (e) { }
    }
    return { users: users, groups: groups, count: count };
}

function getContactDirectory(dbStoragePath) {
    var startedAt = Date.now();
    try {
        if (!contactDirectoryEnabled) return JSON.stringify({ ok: false, reason: "unsupported" });
        if (!contactState.installed) contactSetupHooks();
        if (!contactState.installed || !contactState.ccCrypt) return JSON.stringify({ ok: false, reason: "unsupported" });
        var base = String(dbStoragePath || "").replace(/\/+$/, "");
        if (!base) return JSON.stringify({ ok: false, reason: "db_missing" });
        var contactPath = base + "/contact/contact.db";
        var dbBytes;
        try {
            dbBytes = new Uint8Array(File.readAllBytes(contactPath));
        } catch (e) {
            return JSON.stringify({ ok: false, reason: "db_missing" });
        }
        if (dbBytes.length < CONTACT_PAGE_SIZE || dbBytes.length > CONTACT_MAX_DB_BYTES) {
            return JSON.stringify({ ok: false, reason: "db_missing" });
        }
        var resolved = contactResolveKeyByPage1(dbBytes.subarray(0, CONTACT_PAGE_SIZE));
        if (!resolved) {
            console.log("[!] [contact] 缺少 contact.db 密钥（需登录期 Hook 或打开一次通讯录/聊天触发页读）");
            return JSON.stringify({ ok: false, reason: "key_missing" });
        }
        var dec = contactDecryptDatabase(dbBytes, resolved.keyHex, contactPath);
        if (!dec) return JSON.stringify({ ok: false, reason: "decrypt_failed" });
        var tmpPath = contactWriteTempDb(dec.bytes, base);
        if (!tmpPath) return JSON.stringify({ ok: false, reason: "decrypt_failed" });
        var directory = null;
        try {
            directory = contactQueryDirectory(tmpPath);
        } finally {
            contactCleanupTempDb(tmpPath);
        }
        if (!directory) return JSON.stringify({ ok: false, reason: "decrypt_failed" });
        var keys = {};
        keys.contact = { salt: resolved.salt, key: resolved.keyHex };
        try {
            var sessionBytes = new Uint8Array(File.readAllBytes(base + "/session/session.db"));
            if (sessionBytes.length >= CONTACT_PAGE_SIZE) {
                var sessionKey = contactResolveKeyByPage1(sessionBytes.subarray(0, CONTACT_PAGE_SIZE));
                if (sessionKey) keys.session = { salt: sessionKey.salt, key: sessionKey.keyHex };
            }
        } catch (e) { /* session.db 可选 */ }
        var result = {
            ok: true,
            generated_at: Date.now(),
            wal_applied: dec.walApplied,
            users: directory.users,
            groups: directory.groups,
            keys: keys
        };
        var memberTotal = 0;
        for (var gid in directory.groups) {
            if (directory.groups[gid].members) memberTotal += Object.keys(directory.groups[gid].members).length;
        }
        contactDebug("目录完成 users=" + Object.keys(directory.users).length +
            " groups=" + Object.keys(directory.groups).length +
            " members=" + memberTotal +
            " wal=" + dec.walApplied + " ms=" + (Date.now() - startedAt));
        return JSON.stringify(result);
    } catch (e) {
        contactState.lastError = String(e);
        return JSON.stringify({ ok: false, reason: "decrypt_failed", message: String(e) });
    }
}

function setDbKeys(keysJson) {
    var accepted = 0;
    try {
        var obj = JSON.parse(String(keysJson || "{}"));
        for (var k in obj) {
            if (!Object.prototype.hasOwnProperty.call(obj, k)) continue;
            var item = obj[k];
            if (!item || !item.salt || !item.key) continue;
            if (String(item.key).length !== 64 || String(item.salt).length !== 32) continue;
            contactState.providedKeys[String(item.salt)] = String(item.key);
            contactNoteCandidate(String(item.key), "provided");
            accepted++;
        }
        contactDebug("回灌 DB key 缓存 accepted=" + accepted);
        return JSON.stringify({ ok: true, accepted: accepted });
    } catch (e) {
        contactState.lastError = String(e);
        return JSON.stringify({ ok: false, reason: "bad_json" });
    }
}

function getDbKeyStatus() {
    try {
        return JSON.stringify({
            installed: contactState.installed,
            validated: Object.keys(contactState.keysBySalt).length,
            candidates: contactState.candidates.length,
            passphrase: !!contactState.passphraseHex,
            last_error: contactState.lastError
        });
    } catch (e) {
        return JSON.stringify({ installed: false, error: String(e) });
    }
}

rpc.exports = {
    hydrateCdnVideoCache: hydrateCdnVideoCache,
    triggerSendImgMessage: triggerSendImgMessage,
    triggerUploadImg: triggerUploadImg,
    triggerSendTextMessage: triggerSendTextMessage,
    triggerDownload: triggerDownload,
    triggerUploadVideo: triggerUploadVideo,
    triggerSendVideoMessage: triggerSendVideoMessage,
    triggerSendReplyMessage: triggerSendReplyMessage,
    triggerUploadVoice: triggerUploadVoice,
    triggerSendVoiceMessage: triggerSendVoiceMessage,
    triggerSendFileMessage: triggerSendFileMessage,
    triggerSendFileUploadMessage: triggerSendFileUploadMessage,
    triggerUploadFile: triggerUploadFile,
    triggerUploadAppAttach: triggerUploadAppAttach,
    r3SetSeed: r3SetSeed,
    r3RestoreSeed: r3RestoreSeed,
    r3Dbg: r3Dbg,
    r3Status: r3Status,
    r3ScanOnce: r3ScanOnce,
    r3MapDump: r3MapDump,
    getContactDirectory: getContactDirectory,
    setDbKeys: setDbKeys,
    getDbKeyStatus: getDbKeyStatus,
};

// -------------------------发送图片消息分区-------------------------

// -------------------------接收消息分区-------------------------
function setupDownloadFileDynamic() {
    downloadFileX1 = Memory.alloc(1624)
    fileIdAddr = Memory.alloc(128)
    downloadAesKeyAddr = Memory.alloc(128)
    filePathAddr = Memory.alloc(256)
    fileCdnUrlAddr = Memory.alloc(256)

}


function setReceiver() {
	Interceptor.attach(buf2RespAddr, {
		onEnter: function (args) {
			// 通过 SP+0x140 读取当前 buf2resp 对应的 taskId
			var respTaskId = this.context.sp.add(0x140).readS32();
			const currentPtr = this.context.x20;
			const x2 = this.context.x0.toInt32();
            // R3 诊断: 只读记录异步发送任务是否收到回包（slot13 返回 0 不代表服务端已接收）。
            var r3Sent = (r3State && r3State.sentTasks) ? r3State.sentTasks[respTaskId] : null;
            if (r3Sent) {
                delete r3State.sentTasks[respTaskId];
                var head = [];
                try {
                    if (isReadablePointer(currentPtr) && x2 > 0 && x2 <= 64) {
                        var headBuf = readByteArrayIfReadable(currentPtr, x2);
                        if (headBuf) head = Array.prototype.slice.call(new Uint8Array(headBuf), 0, Math.min(16, x2));
                    }
                } catch (e) { }
                if (r3State.pendingResponses.length < 8) {
                    r3State.pendingResponses.push("[+] R3 " + r3Sent.label + " response: taskId=" +
                        respTaskId + " len=" + x2 + " head=" + head.join(","));
                }
                return;
            }
            // 先处理我们发送任务的ack: 无论响应数据是否可读, 清理动作都必须执行
            // (错误响应往往指针不可读, 在校验前早退会跳过清理留下悬空伪造指针)
            var pendingEntry = finishPendingBuf2RespTask(respTaskId);
            if (pendingEntry && !pendingEntry.addr.isNull()) {
                // 成功路径同样复原原始消息指针, 而不是写0: 已完成的任务若带 NULL
                // 消息指针留在 mars 任务 map 里, 后续(数秒~数天后)清理 erase 时会
                // 踩坏红黑树 (2026-09-02 02:22 crash: 文本成功后留下 NULL 节点,
                // 图片失败的清理路径踩雷)。originalPtr 是 sendFunc 构造的合法消息,
                // 复原后任务全程处于原生合法状态, OnTaskEnd 按原生流程回收即可
                try {
                    if (pendingEntry.originalPtr && !pendingEntry.originalPtr.isNull()) {
                        pendingEntry.addr.writePointer(pendingEntry.originalPtr);
                        console.log("[+] buf2resp: 已复原原始消息指针, msgType=" + pendingEntry.msgType + " taskId=" + respTaskId);
                    } else {
                        pendingEntry.addr.writeU64(0x0);
                        console.log("[+] buf2resp: 原始指针不可用, 已清零 insertMsgAddr, msgType=" + pendingEntry.msgType + " taskId=" + respTaskId);
                    }
                } catch (e) {
                    console.error("[!] buf2resp 清理异常: taskId=" + respTaskId + " err=" + e);
                }
            }

            if (!isReadablePointer(currentPtr) || x2 < 4 || x2 > MAX_FRIDA_MESSAGE_BYTES) {
                if (pendingEntry) {
                    console.log("[+] buf2resp: ack响应数据不可读, 已跳过数据转发, taskId=" + respTaskId);
                } else {
                    console.error("[-] buf2resp: pointer 不可读 或 x2 大小不正确, ptr=" + currentPtr + " x2=" + x2);
                }
				return;
            }

            // 判断是否是我们发送的消息的 ack
            if (pendingEntry) {
                // 读取响应数据
				var respData = x2 >= 4 && x2 <= MAX_FRIDA_MESSAGE_BYTES ? readByteArrayIfReadable(currentPtr, x2) : null;
				if (respData) {
					var bytes = new Uint8Array(respData);
					console.log("[+] buf2resp: 收到响应, msgType=" + pendingEntry.msgType + " taskId=" + respTaskId + " len=" + x2);
					send({
						type: "buf2resp",
						msg_type: pendingEntry.msgType,
						data: Array.from(bytes),
					});
				}
				return
            }

            const mem = readByteArrayIfReadable(currentPtr, x2);
            if (!mem) {
                console.warn("[skip] protobuf_msg memory read failed, length=" + x2);
                return;
            }
            const uint8Array = new Uint8Array(mem);
            // 与已验证稳定的旧版本保持一致，只做最宽松的消息候选判断。
            // 具体结构交给 Go 解析，宁可产生误判日志，也不要在 JS 层漏掉消息。
            if (uint8Array[0] !== 0x08) {
                return;
            }

            // 任何同步消息到达 = 微信已登录, 解锁 CdnManager 解析门禁
            incomingTrafficSeen = true;
            send({
                type: "protobuf_msg",
                data: Array.from(uint8Array),
            })
        },
    });

    Interceptor.attach(startDownloadMedia, {
        onEnter: function (args) {
            downloadGlobalX0 = this.context.x0;
            if (uploadGlobalX0.equals(ptr(0))) {
                // 上传/下载共用同一 mars::cdn::CdnManager 单例, 顺手回填
                uploadGlobalX0 = this.context.x0;
                console.log("[+] 下载hook回填 uploadGlobalX0: " + uploadGlobalX0);
            }
            var fileIDAddr = readPointerIfReadable(this.context.x1.add(0x40));
            var fileId = readUtf8StringIfReadable(fileIDAddr);
            if (!fileId || !isReadablePointer(this.context.x1.add(0xA0))) {
                return;
            }
            const t = this.context.x1.add(0xA0).readU32()
            if (t === 3) {
                if (fileId.endsWith("_1")) {
                    this.context.x1.add(0xA0).writeU32(0x02);
                }
                if (fileId.endsWith("_31")) {
                    this.context.x1.add(0xA0).writeU32(0x04);
                }
            }
        }
    })

    // 4.1.12(structVer=2) 下载链路漂移(DIAG 实证, 详见 docs/version-upgrade.md):
    // - file/imag 数据寄存器 x22→x21 (寄存器分配漂移, JSON hook 点即 mov x1,xN 指令)
    // - 任务结构 +0x18: fileId 0x2E0→0x2F8, cdnUrl 0x2F8→0x310
    // - 视频数据变为 libc++ std::string(x20+0x178), 长度必须读结构体(4.1.12 x23=0)
    var dlIsV2 = (structVer === "2");
    var dlFileIdOff = dlIsV2 ? 0x2F8 : 0x2E0;
    var dlCdnUrlOff = dlIsV2 ? 0x310 : 0x2F8;

    try {
        Interceptor.attach(downloadFileAddr, {
            onEnter: function (args) {
                var dataPtr = dlIsV2 ? this.context.x21 : this.context.x22;
                var dataLen = this.context.x2.toInt32();
                var fileId = readUtf8StringIfReadable(readPointerIfReadable(this.context.x19.add(dlFileIdOff)));
                var cdnUrl = readUtf8StringIfReadable(readPointerIfReadable(this.context.x19.add(dlCdnUrlOff)));

                sendDownloadChunks(dataPtr, dataLen, fileId, cdnUrl);
            }
        });
    } catch (e) {
        console.log("[!] downloadFile hook skipped (file media; non-fatal): " + e);
    }

    try {
        Interceptor.attach(downloadImagAddr, {
            onEnter: function (args) {
                var dataPtr = dlIsV2 ? this.context.x21 : this.context.x22;
                var dataLen = this.context.x2.toInt32();
                var fileId = readUtf8StringIfReadable(readPointerIfReadable(this.context.x19.add(dlFileIdOff)));
                var cdnUrl = readUtf8StringIfReadable(readPointerIfReadable(this.context.x19.add(dlCdnUrlOff)));

                sendDownloadChunks(dataPtr, dataLen, fileId, cdnUrl);
            }
        });
    } catch (e) {
        console.log("[!] downloadImag hook skipped (image media; non-fatal): " + e);
    }

    try {
        Interceptor.attach(downloadVideoAddr, {
            onEnter: function (args) {
                var dataPtr, dataLen;
                if (dlIsV2) {
                    var sObj = this.context.x20.add(0x178);
                    try {
                        var ssoFlag = sObj.add(0x17).readU8();
                        if (ssoFlag & 0x80) {
                            dataPtr = sObj;
                            dataLen = ssoFlag & 0x7f;
                        } else {
                            dataPtr = readPointerIfReadable(sObj);
                            dataLen = sObj.add(8).readU64().toUInt32();
                        }
                    } catch (e) { dataPtr = ptr(0); dataLen = 0; }
                } else {
                    dataPtr = readPointerIfReadable(this.context.x20.add(0x178));
                    dataLen = this.context.x23.toInt32();
                }
                var fileId = readUtf8StringIfReadable(readPointerIfReadable(this.context.x19.add(dlFileIdOff)));
                var cdnUrl = readUtf8StringIfReadable(readPointerIfReadable(this.context.x19.add(dlCdnUrlOff)));

                sendDownloadChunks(dataPtr, dataLen, fileId, cdnUrl);
            }
        });
    } catch (e) {
        console.log("[!] downloadVideo hook skipped (video media; non-fatal): " + e);
    }
}


// fileType:  HdImage => 1,Image => 2, thumbImage => 3, Video => 4, File => 5,
function triggerDownload(receiver, cdnUrl, aesKey, filePath, fileType) {
    if (!downloadGlobalX0) {
        ensureCdnManagerX0();
    }
    if (!downloadGlobalX0) {
        console.error("[!] downloadGlobalX0 尚未初始化，请等待 hook 捕获");
        return "fail";
    }

    const downloadMediaPayload = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x00
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x10
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x20
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x30
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xF0, 0xB6, 0x4C, 0xFC, 0x0A, 0x00, 0x00, 0x00, // 0x40
        0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
        0x80, 0x10, 0x4B, 0xFA, 0x0A, 0x00, 0x00, 0x00, // 0x58
        0xB2, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
        0xF0, 0xB3, 0x4C, 0xFC, 0x0A, 0x00, 0x00, 0x00, // 0x70
        0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80,
        0x60, 0xC4, 0x2D, 0xFE, 0x0A, 0x00, 0x00, 0x00, // 0x88
        0xC8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x90
        0xD0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, // 0x98
        0x03, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, // 0xa0
        0x00, 0x00, 0x00, 0x00, 0x01, 0xAA, 0xAA, 0xAA, // 0xa8
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0xb0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0xc0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0xd0
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0xd8
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0xe0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0xf0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x100
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x110
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x02, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, // 0x128
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x11, 0x28, 0x28, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x148
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x02, 0x00, 0x00, 0xAA, 0xAA, 0xAA, // 0x170
        0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, // 0x180
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x1E, 0x00, 0x00, 0x00, 0xAA, 0xAA, 0xAA, 0xAA, // 0x1a0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xAA, 0xAA, 0xAA, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x22, 0x1A, 0xFE, 0x0A, 0x00, 0x00, 0x00, // 0x1d0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x1f0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x200
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x288
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x298
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x2a0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x4F, 0x56, 0xFC, 0x0A, 0x00, 0x00, 0x00, // 0x2c0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x300
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, // 0x318
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 0x340
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00, // 0x378
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x0A, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0x00, // 0x3e0
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];

    patchString(fileIdAddr, receiver + "_" + String(Math.floor(Date.now() / 1000)) + "_" + Math.floor(Math.random() * 1001) + "_1");
    patchString(fileCdnUrlAddr, cdnUrl)
    patchString(downloadAesKeyAddr, aesKey)
    patchString(filePathAddr, filePath);

    downloadFileX1.writeByteArray(downloadMediaPayload);
    downloadFileX1.add(0x40).writePointer(fileIdAddr);
    downloadFileX1.add(0x58).writePointer(fileCdnUrlAddr);
    downloadFileX1.add(0x70).writePointer(downloadAesKeyAddr);
    downloadFileX1.add(0x88).writePointer(filePathAddr);
    downloadFileX1.add(0xa0).writeU32(fileType);

    const startDwMedia = new NativeFunction(startDownloadMedia, 'int64', ['pointer', 'pointer']);
    return startDwMedia(downloadGlobalX0, downloadFileX1);
}

// -------------------------接收消息分区-------------------------
