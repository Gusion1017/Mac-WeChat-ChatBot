package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"runtime/debug"
	"strings"
	"syscall"
	"text/template"
	"time"

	"github.com/frida/frida-go/frida"
)

// str 从 Frida 回调消息的 map 里安全读取字符串字段：
// key 缺失或类型不是 string 时返回 ""。原来直接 `msg["type"].(string)` 在
// JS 侧字段缺失/类型不符时会 panic，整条消息（如上传完成回包）被丢掉。
func str(m map[string]interface{}, key string) string {
	if v, ok := m[key]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

func main() {
	initFlag()
	initLogger()
	initR3ModeFromConfig()
	if config.FridaType == "gadget" {
		initFridaGadget()
	} else {
		initFrida()
	}
	go SendWorker()
	go cleanExpiredDownloads()

	http.HandleFunc("/send_private_msg", sendHandler)
	http.HandleFunc("/send_group_msg", sendHandler)
	http.HandleFunc("/fetch_image", fetchImageHandler)
	http.HandleFunc("/fetch_voice", fetchVoiceHandler)
	http.HandleFunc("/send_voice", sendVoiceHandler)
	http.HandleFunc("/voice_status", voiceStatusHandler)

	http.HandleFunc("/ws", handleWebSocket)
	http.HandleFunc("/test_ws", testWebSocket)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	go func() {
		<-stop
		// SIGTERM/SIGINT 是 App 主动停止 bridge 的正常路径：先释放 Frida 资源，
		// 再以退出码 0 退出。原来走 zerolog Fatal（os.Exit(1)），App 会把正常
		// 停止误判为 bridge 崩溃。
		if fridaScript != nil {
			fridaScript.Clean()
		}
		if session != nil {
			session.Clean()
		}
		if device != nil {
			device.Clean()
		}
		Info("正在释放 Frida 资源并退出...")
		os.Exit(0)
	}()

	// 3. 启动服务
	Info("HTTP 服务启动在", "host", config.ReceiveHost)
	if err := http.ListenAndServe(config.ReceiveHost, nil); err != nil {
		Error("服务启动失败", "err", err)
	}

}

func initFlag() {
	flag.StringVar(&config.FridaType, "type", "local", "frida 类型: local | gadget")
	flag.StringVar(&config.SendURL, "send_url", "http://127.0.0.1:36060/onebot", "发送消息的 URL: http://127.0.0.1:36060/onebot")
	flag.StringVar(&config.ReceiveHost, "receive_host", "127.0.0.1:58080", "接收消息的地址: 127.0.0.1:58080")
	flag.StringVar(&config.FridaGadgetAddr, "gadget_addr", "127.0.0.1:27042", "Gadget 地址: 127.0.0.1:27042 仅当 type 为 gadget 时有效")
	flag.StringVar(&config.OnebotToken, "token", "MuseBot", "OneBot Token: MuseBot")
	flag.StringVar(&config.ImagePath, "image_path", "", "图片路径: /Users/xxx/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/xxx/temp/xxx/2026-01/Img/")
	flag.StringVar(&config.MediaDir, "media_dir", "",
		"入站图片落盘目录（App 传入；留空则 ~/Library/Application Support/WeChatAI/media）")
	flag.StringVar(&config.WechatConf, "wechat_conf", "../wechat_version/4_1_11_53_mac.json", "微信配置文件路径: ../wechat_version/4_1_6_12_mac.json")
	flag.StringVar(&config.ConnType, "conn_type", "http", "连接类型: http | websocket")
	flag.IntVar(&config.SendInterval, "send_interval", 1000, "发送间隔: ms")
	flag.IntVar(&config.WechatPid, "wechat_pid", 0, "微信进程 PID，不设置则自动查找")
	flag.StringVar(&selfIDFlag, "self_id", "", "当前微信账号 wxid（App 已知时传入；优先于 image_path 推导）")
	flag.StringVar(&logFilePath, "log_file", "./log/macos.log", "日志文件路径（App 会指向 ~/Library/Logs/WeChatAI/bridge/macos.log，避免写入 app bundle）")
	flag.StringVar(&logLevel, "log_level", "info", "log level")

	flag.Parse()

	if selfIDFlag != "" {
		myWechatId = selfIDFlag
	}
	if myWechatId == "" && config.ImagePath != "" {
		if idx := strings.Index(config.ImagePath, "xwechat_files/"); idx != -1 {
			rest := config.ImagePath[idx+len("xwechat_files/"):]
			if end := strings.Index(rest, "/"); end != -1 {
				rest = rest[:end]
			}
			// 去掉末尾的 "_xxxx" 后缀，保留 wxid_xxx 部分
			if last := strings.LastIndex(rest, "_"); last > strings.Index(rest, "_") {
				myWechatId = rest[:last]
			}
		}
	}

	fmt.Println("FridaType", config.FridaType)
	fmt.Println("SendURL", config.SendURL)
	fmt.Println("ReceiveHost", config.ReceiveHost)
	fmt.Println("FridaGadgetAddr", config.FridaGadgetAddr)
	fmt.Println("OnebotToken", config.OnebotToken)
	fmt.Println("ImagePath", config.ImagePath)
	fmt.Println("MediaDir", config.MediaDir)
	fmt.Println("WechatConf", config.WechatConf)
	fmt.Println("ConnType", config.ConnType)
	fmt.Println("SendInterval", config.SendInterval)
	fmt.Println("WechatPid", config.WechatPid)
	fmt.Println("LogLevel", logLevel)
}

func initFridaGadget() {
	var err error
	mgr := frida.NewDeviceManager()
	// 连接到 Gadget 默认端口
	device, err = mgr.AddRemoteDevice(config.FridaGadgetAddr, frida.NewRemoteDeviceOptions())
	if err != nil {
		Fatal("❌ 无法连接 Gadget", err)
	}

	session, err = device.Attach("Gadget", nil)
	if err != nil {
		Fatal("❌ 附加失败", err)
	}

	loadJs()

}

func initFrida() {
	var err error
	// 1. 获取本地设备管理器
	mgr := frida.NewDeviceManager()

	// 2. 枚举并获取本地设备 (TypeLocal)
	device, err = mgr.DeviceByType(frida.DeviceTypeLocal)
	if err != nil {
		Fatal("无法获取本地设备", "err", err)
	}

	attachWechat()
}

func attachWechat() {
	var pid int
	var err error
	if config.WechatPid > 0 {
		pid = config.WechatPid
		Info("使用指定的微信进程 PID", "PID", pid)
	} else {
		for {
			pid, err = GetWeChatPID()
			if err == nil {
				break
			}
			Info("未发现正在运行的微信进程，20秒后重试...")
			time.Sleep(20 * time.Second)
		}
		Info("自动发现微信进程 PID", "PID", pid)
	}

	session, err = device.Attach(pid, nil)
	if err != nil {
		Fatal("Attach 失败 (请检查 SIP 状态或权限)", "err", err)
	}
	Info("成功 Attach 微信进程", "PID", pid)
	attachedWechatPid = pid

	loadJs()
	MonitorProcess(pid)
}

func loadJs() {
	jsonData, err := os.ReadFile(config.WechatConf)
	if err != nil {
		Fatal("读取文件失败", "err", err)
	}

	// 2. 将 JSON 解析为 Map
	var wechatHookConf map[string]interface{}
	if err = json.Unmarshal(jsonData, &wechatHookConf); err != nil {
		Fatal("解析 JSON 失败", "err", err)
	}

	codeTemplate, err := os.ReadFile("./script.js")
	if err != nil {
		Fatal("读取脚本失败", "err", err)
	}

	tmpl, err := template.New("fridaScript").Parse(string(codeTemplate))
	if err != nil {
		Fatal("解析模板失败", "err", err)
		return
	}

	var buf bytes.Buffer
	err = tmpl.Execute(&buf, wechatHookConf)
	if err != nil {
		Fatal("执行模板失败", "err", err)
	}

	script, err := session.CreateScript(buf.String())
	if err != nil {
		Fatal("创建脚本失败", "err", err)
	}

	// 打印 JS 里的 console.log
	script.On("message", func(rawMsg string) {
		defer func() {
			if r := recover(); r != nil {
				Error("message panic", "err", r, "stack", string(debug.Stack()))
			}
		}()

		var msg map[string]interface{}
		err = json.Unmarshal([]byte(rawMsg), &msg)
		if err != nil {
			Error("JSON解析失败", "err", err)
			return
		}

		msgType := str(msg, "type")

		switch msgType {
		case "send":
			if p, ok := msg["payload"]; ok {
				if pMap, ok := p.(map[string]interface{}); ok {
					payloadJson, _ := json.Marshal(pMap)
					if _, ok := pMap["type"]; ok {
						switch str(pMap, "type") {
						case "protobuf_msg":
							go HandleProtobufMsgAndSend(pMap)
						case "send":
							if config.ConnType == "http" {
								go SendHttpReq(payloadJson)
							} else {
								go SendWebSocketMsg(payloadJson)
							}
						case "buf2resp":
							go func() {
								msgType := str(pMap, "msg_type")
								if dataInter, ok := pMap["data"]; ok {
									if dataArr, ok := dataInter.([]interface{}); ok {
										rawBytes := make([]byte, len(dataArr))
										for i, v := range dataArr {
											if f, ok := v.(float64); ok {
												rawBytes[i] = byte(int(f))
											}
										}
										HandleBuf2Resp(msgType, rawBytes)
									}
								}
							}()
						case "r3_seed":
							seed, _ := pMap["seed"].(string)
							pidFloat, _ := pMap["pid"].(float64)
							pid := int(pidFloat)
							if pid <= 0 {
								pid = attachedWechatPid
							}
							if seed != "" && pid > 0 {
								attachedWechatPid = pid
								persistR3Seed(pid, seed)
								Info("R3 发送句柄已持久化", "pid", pid, "seed", seed)
							}
						case "r3_voice_header":
							header, _ := pMap["header"].(string)
							pidFloat, _ := pMap["pid"].(float64)
							pid := int(pidFloat)
							if pid <= 0 {
								pid = attachedWechatPid
							}
							if header != "" && pid > 0 {
								attachedWechatPid = pid
								persistR3VoiceHeader(pid, header)
								Info("R3 语音 header 已持久化", "pid", pid)
							}
						case "r3_voice_seed":
							seed, _ := pMap["seed"].(string)
							pidFloat, _ := pMap["pid"].(float64)
							pid := int(pidFloat)
							if pid <= 0 {
								pid = attachedWechatPid
							}
							if seed != "" && pid > 0 {
								attachedWechatPid = pid
								persistR3VoiceSeed(pid, seed)
								Info("R3 语音句柄已持久化", "pid", pid, "seed", seed)
							}
						case "r3_mode":
							enabled := true
							if v, ok := pMap["enabled"].(bool); ok {
								enabled = v
							}
							r3SendMode.Store(enabled)
							if enabled {
								Info("R3 模式已启用：文本发送将跳过 buf2resp 等待")
							}
						case "incoming_message":
							event := pMap
							if nested, ok := pMap["payload"].(map[string]interface{}); ok {
								event = nested
							}
							go HandleIncomingMessage(event)
						case "upload_image_finish":
							m := &SendMsg{
								Type: "send_image",
							}
							targetId := str(pMap, "target_id")
							if targetId != "" {
								if strings.Contains(targetId, "wxid_") {
									m.UserId = targetId
								} else {
									m.GroupID = targetId
								}
							}
							m.CdnKey = str(pMap, "cdn_key")
							m.AesKey = str(pMap, "aes_key")
							m.Md5Key = str(pMap, "md5_key")
							if ch, ok := pendingResultMap.LoadAndDelete(targetId); ok {
								m.ResultChan = ch.(chan error)
							}
							msgChan <- m
						case "upload_video_finish":
							m := &SendMsg{
								Type: "send_video",
							}
							targetId := str(pMap, "target_id")
							if targetId != "" {
								if strings.Contains(targetId, "wxid_") {
									m.UserId = targetId
								} else {
									m.GroupID = targetId
								}
							}
							m.CdnKey = str(pMap, "cdn_key")
							m.AesKey = str(pMap, "aes_key")
							m.Md5Key = str(pMap, "md5_key")
							m.VideoId = str(pMap, "video_id")
							if ch, ok := pendingResultMap.LoadAndDelete(targetId); ok {
								m.ResultChan = ch.(chan error)
							}
							msgChan <- m
						case "upload_voice_finish":
							m := &SendMsg{
								Type: "send_voice",
							}
							targetId := str(pMap, "target_id")
							if targetId != "" {
								if strings.Contains(targetId, "wxid_") {
									m.UserId = targetId
								} else {
									m.GroupID = targetId
								}
							}
							m.CdnKey = str(pMap, "cdn_key")
							m.AesKey = str(pMap, "aes_key")
							if voiceDuration, ok := pMap["voice_duration"]; ok {
								if vd, ok := voiceDuration.(float64); ok {
									m.VoiceDuration = int32(vd)
								}
							}
							if silkDataLen, ok := pMap["silk_data_len"]; ok {
								if sdl, ok := silkDataLen.(float64); ok {
									m.SilkDataLen = int32(sdl)
								}
							}
							if ch, ok := pendingResultMap.LoadAndDelete(targetId); ok {
								m.ResultChan = ch.(chan error)
							}
							msgChan <- m
						case "download":
							err = Download(payloadJson)
							if err != nil {
								Error("下载失败", "err", err)
							}
						}

					}
				}
			}
		case "log":
			Info("[JS日志]", "payload", msg["payload"])
		case "error":
			Error("[JS日志报错]", "err", msg["description"], "stack", msg["stack"])
		}
	})

	if err := script.Load(); err != nil {
		Fatal("❌ 加载脚本失败", err)
	}

	fridaScript = script
	Info("✅ Frida 已就绪，微信控制通道已打通")

	// 通讯录 DB key：回灌上次缓存的密钥，hook 可直接解密 contact.db，不必等
	// 用户重新打开一次通讯录触发页读。密钥只在内存/Frida 间传递，不打印；
	// 无缓存或失败只记日志，不影响启动。
	restoreContactDBKeys()

	// 4.1.15.55 R3：bridge 重启但微信未重启时，恢复上次捕获的发送句柄，避免回复排队。
	// gadget 模式拿不到微信 PID，由 JS 用 Process.id 做新鲜度校验。
	if rec, ok := loadR3SeedRecord(); ok {
		if rec.Seed != "" {
			result := fridaScript.ExportsCall("r3RestoreSeed", rec.PID, rec.Seed)
			switch fmt.Sprint(result) {
			case "ok":
				Info("R3 发送句柄恢复（bridge 重启）", "pid", rec.PID, "seed", rec.Seed)
			case "stale":
				Info("R3 发送句柄记录已过期（微信已重启），等待重新捕获")
				_ = os.Remove(r3SeedFile())
			default:
				// 只有 "stale"（微信已重启）才删除记录；"off"/"fail" 等临时状态
				// （脚本未启用、暂时取不到句柄）必须保留，文档承诺跨 bridge 重启
				// 恢复，删了下次重启就失去恢复机会。
				Warn("R3 发送句柄暂不可恢复，保留记录等待下次重启重试", "result", result)
			}
		}
		if rec.VoiceSeed != "" {
			result := fridaScript.ExportsCall("r3RestoreVoiceSeed", rec.PID, rec.VoiceSeed)
			switch fmt.Sprint(result) {
			case "1":
				Info("R3 语音句柄恢复（bridge 重启）", "pid", rec.PID, "seed", rec.VoiceSeed)
			case "stale":
				Info("R3 语音句柄记录已过期（微信已重启）")
				_ = os.Remove(r3SeedFile())
			default:
				Warn("R3 语音句柄恢复失败", "result", result)
			}
		}
		if rec.VoiceHeader != "" {
			result := fridaScript.ExportsCall("r3RestoreVoiceHeader", rec.PID, rec.VoiceHeader)
			if fmt.Sprint(result) != "1" {
				Warn("R3 语音 header 恢复失败", "result", result)
			} else {
				Info("R3 语音 header 恢复（bridge 重启）", "pid", rec.PID)
			}
		}
	}
}
