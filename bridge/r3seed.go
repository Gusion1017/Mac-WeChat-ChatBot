package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"
)

// R3 发送句柄（newsendmsg hand-off 闭包 clone）与微信进程绑定：
// 微信不重启、仅 bridge 重启时，clone 对象仍在微信堆中，可凭 PID 恢复，避免
// 每次重启 bridge 都要人工发一条微信消息来重新捕获句柄（那会造成回复排队/延迟）。
type r3SeedRecord struct {
	PID       int    `json:"pid"`
	Seed      string `json:"seed"`
	VoiceSeed   string `json:"voice_seed,omitempty"`
	VoiceHeader string `json:"voice_header,omitempty"`
	UpdatedAt   int64  `json:"updated_at"`
}

// attachedWechatPid 记录本次 attach 的微信 PID（本地 attach 模式可预知；
// gadget 模式由 JS 上报 Process.id）。
var attachedWechatPid int

// r3SendMode 由脚本在 R3 初始化完成后上报：R3 的 slot13 提交是 fire-and-forget，
// 不再等待 buf2resp（否则 15s 后误报 send timeout，而消息实际已送达）。
var r3SendMode atomic.Bool

// initR3ModeFromConfig 在启动时读取运行期 hook 配置，避免脚本上报前的竞态。
func initR3ModeFromConfig() {
	if config.WechatConf == "" {
		return
	}
	data, err := os.ReadFile(config.WechatConf)
	if err != nil {
		return
	}
	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return
	}
	if mode, ok := cfg["req2bufSendMode"].(string); ok && mode == "r3" {
		r3SendMode.Store(true)
		Info("R3 模式（配置文件）：文本发送跳过 buf2resp 等待")
	}
}

func r3SeedFile() string {
	dir, err := os.UserCacheDir()
	if err != nil || dir == "" {
		dir = os.TempDir()
	}
	base := filepath.Join(dir, "WeChatAI")
	_ = os.MkdirAll(base, 0o755)
	return filepath.Join(base, "r3-seed.json")
}

func persistR3Seed(pid int, seed string) {
	if pid <= 0 || seed == "" {
		return
	}
	rec, _ := loadR3SeedRecord()
	if rec.PID != pid {
		rec = r3SeedRecord{PID: pid}
	}
	rec.Seed = seed
	rec.UpdatedAt = time.Now().Unix()
	writeR3SeedRecord(rec)
}

// persistR3VoiceHeader 保存真实语音 proto 的最小 header（session/device）。
func persistR3VoiceHeader(pid int, header string) {
	if pid <= 0 || header == "" {
		return
	}
	rec, _ := loadR3SeedRecord()
	if rec.PID != pid {
		rec = r3SeedRecord{PID: pid}
	}
	rec.VoiceHeader = header
	rec.UpdatedAt = time.Now().Unix()
	writeR3SeedRecord(rec)
}

// persistR3VoiceSeed 单独保存 uploadvoice 任务闭包；与文本句柄共用同一记录。
func persistR3VoiceSeed(pid int, seed string) {
	if pid <= 0 || seed == "" {
		return
	}
	rec, _ := loadR3SeedRecord()
	if rec.PID != pid {
		rec = r3SeedRecord{PID: pid}
	}
	rec.VoiceSeed = seed
	rec.UpdatedAt = time.Now().Unix()
	writeR3SeedRecord(rec)
}

func writeR3SeedRecord(rec r3SeedRecord) {
	data, err := json.Marshal(rec)
	if err != nil {
		return
	}
	_ = os.WriteFile(r3SeedFile(), data, 0o600)
}

func loadR3SeedRecord() (r3SeedRecord, bool) {
	data, err := os.ReadFile(r3SeedFile())
	if err != nil {
		return r3SeedRecord{}, false
	}
	var rec r3SeedRecord
	if err := json.Unmarshal(data, &rec); err != nil || rec.PID <= 0 ||
		(rec.Seed == "" && rec.VoiceSeed == "" && rec.VoiceHeader == "") {
		return r3SeedRecord{}, false
	}
	return rec, true
}

func loadR3Seed(pid int) string {
	data, err := os.ReadFile(r3SeedFile())
	if err != nil {
		return ""
	}
	var rec r3SeedRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return ""
	}
	if rec.PID != pid || rec.Seed == "" {
		return ""
	}
	return rec.Seed
}
