package main

// 本文件由 ChatBot 项目新增（2026-10-26），实现入站语音与出站语音的 bridge 侧契约，
// 对应 docs/voice.md §2.1 / §2.2 / §3.3。
//
// 入站链路：
//
//	微信收到语音 → hook 上报 msg_type=34、正文 [语音]、raw_message=<voicemsg …>
//	→ registerIncomingVoice 解析 XML、按 message_id 登记 pendingVoiceJob，
//	  并把 message 数组里的 [语音] 文本段替换成无文件的
//	  {"type":"voice","data":{"duration_ms":N}}（不新增 aeskey/CDN key 字段）
//	→ App 调 POST /fetch_voice {"message_id":…}
//	→ fetchIncomingVoice 先等自然分片，再用 triggerDownload(fileType=15，语音) 触发，
//	  用 XML aeskey AES-ECB 解密，校验 \x02#!SILK_V3 魔数，保存 .silk，
//	  go-silk 解码为 16k PCM，写 16k 单声道 WAV，返回 file:// 路径与时长。
//
// 出站链路（4.2.0.5 暂不可用，见 §3.3）：
//
//	App → POST /send_voice 或 /send_private_msg 的 voice 段（data.pcm16k = base64 的
//	16k 单声道 s16le PCM + data.duration_ms）
//	→ bridge 用 go-silk 编码 Tencent SILK（不依赖 ffmpeg/pilk）
//	→ 调 hook 现有 triggerUploadVoice → upload_voice_finish → send_voice（worker.go）。
//	Hook 尚未支持语音发送（R3 只有 text/pat，legacy uploadvoice/sendvoicemsg 未适配），
//	默认返回 {"ok":false,"error":"voice_send_unsupported"}，App 自动降级为文字；
//	只有显式设置 WECHATAI_VOICE_SEND=1 才真正尝试上传（供 Lead 真机 Spike）。
//
// 隐私红线：日志/响应都不打印 aeskey、CDN key(voiceurl)、XML 原文、音频字节；
// 错误文案使用固定中文/固定 code。所有测试数据均为合成值。
// 真机验证（2026-10-26）：4.2.0.5 语音下载使用 fileType=15（0x0F），走 downloadFile hook。

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/md5"
	"crypto/hmac"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/frida/frida-go/frida"
	"github.com/wdvxdr1123/go-silk"
	silkenc "github.com/yincongcyincong/weixin-macos/onebot/silkenc"
)

const (
	// pendingVoiceJobTTL 是语音下载元数据在内存中的保留时间；App 一般几秒内就会请求。
	pendingVoiceJobTTL = 30 * time.Minute
	// pendingVoiceJobsLimit 是登记条目总量上限，超出时淘汰最旧的。
	pendingVoiceJobsLimit = 512

	// voiceFetchConcurrency 是全局同时处理的语音获取数量上限。
	voiceFetchConcurrency = 2
	// voiceFetchSemaphoreWait 是排队拿下载槽的最长等待时间。
	voiceFetchSemaphoreWait = 5 * time.Second
	// voiceFetchTotalBudget 是单次 /fetch_voice 的总预算（契约 ≤ 25s）。
	voiceFetchTotalBudget = 25 * time.Second

	// voiceMagicRetryLimit 是同一次获取里「魔数/完整性不通过后继续等分片」的最多解密次数。
	voiceMagicRetryLimit = 3

	// 语音格式参数：微信语音是 16k 单声道 16-bit PCM 经 SILK 编码。
	voiceSampleRate    = 16000
	voiceChannels      = 1
	voiceBitsPerSample = 16
	voiceWAVHeaderSize = 44

	// voiceSilkFrameMs 是 SILK 帧时长（微信/微信 PC 采样率 16k 时每帧 20ms）。
	voiceSilkFrameMs = 20

	// maxVoiceCipherBytes 是 CDN 密文长度上限，防止异常 XML length 触发超大分配。
	maxVoiceCipherBytes = 8 << 20
	// maxSilkVoiceFrameBytes 是 go-silk 解码器在 16k 下允许的单帧最大字节数。
	maxSilkVoiceFrameBytes = 640
	// maxVoiceDurationMs 是 XML voicelength 的合理上限（5 分钟），超出按未知处理。
	maxVoiceDurationMs = 5 * 60 * 1000
	// voiceDurationToleranceMs 是「解码时长明显短于 voicelength」的容差，用于识别半截数据。
	voiceDurationToleranceMs = 600

	// maxVoiceSendPCMBytes / minVoiceSendPCMBytes 限制 App 传入的 pcm16k 大小。
	maxVoiceSendPCMBytes = voiceSampleRate * 2 * 120 // 120s
	minVoiceSendPCMBytes = voiceSampleRate * 2 / 50  // 20ms

	// envVoiceFileType 覆盖 /fetch_voice 的下载 fileType 尝试列表（默认 15=语音）。
	envVoiceFileType = "WECHATAI_VOICE_FILE_TYPE"
	// envVoiceSend 显式开启真机语音上传尝试（默认关闭，返回 voice_send_unsupported）。
	envVoiceSend = "WECHATAI_VOICE_SEND"

	// voiceSendUnsupportedCode 是 Hook 未支持语音发送时返回给 App 的固定错误码。
	voiceSendUnsupportedCode = "voice_send_unsupported"
)

var (
	// pendingVoiceJobs 保存 message_id → *incomingVoiceJob 的下载元数据。
	// 用 sync.Map 是因为 hook 回调与 HTTP handler 在不同 goroutine。
	pendingVoiceJobs sync.Map

	// completedVoiceFetches 保存 message_id → completedVoiceFetch，保证重复请求幂等。
	completedVoiceFetches sync.Map

	// voiceFetchSemaphore 限制同时进行的语音获取数量。
	voiceFetchSemaphore = make(chan struct{}, voiceFetchConcurrency)

	// 以下预算做成变量，便于单测缩短；生产值见常量。
	voiceNaturalGraceWindow = 800 * time.Millisecond
	voiceCandidateBudget    = 8 * time.Second

	// 以下是返回给 App 的可读中文错误（不含 key / XML / 音频）。
	errVoiceJobNotFound       = errors.New("该消息的语音信息缺失或已过期")
	errVoiceBridgeUnavailable = errors.New("bridge 尚未连接微信，无法获取语音")
	errVoiceFetchBusy         = errors.New("语音队列繁忙，请稍后重试")
	errVoiceDownloadTimeout   = errors.New("语音下载超时（微信未响应）")
	errVoiceDecryptFailed     = errors.New("语音解密失败，请稍后重试")
	errVoiceSilkInvalid       = errors.New("语音数据不完整或格式不支持")
	errVoiceDecodeFailed      = errors.New("语音解码失败")
	errVoiceTriggerRejected   = errors.New("微信未接受语音下载请求")
	errVoiceTriggerTimeout    = errors.New("微信语音下载请求超时")
	errVoiceEncodeFailed      = errors.New("语音编码失败")
	errVoiceUploadRejected    = errors.New("微信未接受语音上传请求")
	errVoiceTargetMissing     = errors.New("语音发送目标为空")
	errVoicePCMEmpty          = errors.New("pcm16k 参数缺失")
	errVoicePCMInvalid        = errors.New("pcm16k 不是合法的 16k 单声道 PCM")
	errVoicePCMLength         = errors.New("pcm16k 时长超出限制")
	errVoiceSendDisabled      = errors.New(voiceSendUnsupportedCode)
	errVoiceHandleMissing     = errors.New("voice_handle_missing")
	voiceXMLParseFailed       = errors.New("语音 XML 解析失败")
	voiceXMLMissingVoiceMsg   = errors.New("语音 XML 缺少 voicemsg")
	voiceXMLMissingVoiceURL   = errors.New("语音 XML 缺少下载地址")
	voiceXMLMissingAESKey     = errors.New("语音缺少解密密钥")
	voiceXMLBadAESKey         = errors.New("语音解密密钥格式不支持")
	voiceMediaDirCreateFailed = errors.New("创建语音保存目录失败")
	voiceTempDirCreateFailed  = errors.New("创建语音临时目录失败")
	voiceFileSaveFailed       = errors.New("保存语音文件失败")
	voiceWAVBuildFailed       = errors.New("生成语音 WAV 失败")
)

// incomingVoiceXML 独立于 param.go 的 VoiceMsg，避免影响 legacy HandleMsg 的
// XML 反序列化（上游文件只做最小改动）。字段与 4.2 `<voicemsg …/>` 对齐。
type incomingVoiceXML struct {
	XMLName  xml.Name           `xml:"msg"`
	VoiceMsg *incomingVoiceInfo `xml:"voicemsg"`
}

// incomingVoiceInfo 对应 `<voicemsg>` 的属性。
type incomingVoiceInfo struct {
	AESKey      string `xml:"aeskey,attr"`
	VoiceURL    string `xml:"voiceurl,attr"`
	VoiceLength int    `xml:"voicelength,attr"`
	VoiceFormat int    `xml:"voiceformat,attr"`
	Length      int    `xml:"length,attr"`
	EndFlag     int    `xml:"endflag,attr"`
	CancelFlag  int    `xml:"cancelflag,attr"`
}

// incomingVoiceJob 是一条入站语音的下载元数据（明文 aeskey 只在内存里，不落日志）。
type incomingVoiceJob struct {
	MessageID  string
	CDNKey     string
	AESKey     string
	DurationMs int
	Format     int
	CipherLen  int
	CreatedAt  time.Time
}

// voiceFetchResult 是 /fetch_voice 成功时返回给 App 的本地文件信息。
type voiceFetchResult struct {
	Path       string
	SilkPath   string
	DurationMs int
}

// completedVoiceFetch 是幂等缓存条目。
type completedVoiceFetch struct {
	CreatedAt time.Time
	Result    voiceFetchResult
}

// ---------------------------------------------------------------------------
// 入站：XML 解析 / 登记 / 事件段替换
// ---------------------------------------------------------------------------

// parseIncomingVoiceXML 解析 raw_message 里的 `<voicemsg>` 属性。
// 解析错误一律返回固定文案，不携带 XML 原文（属性里可能有 aeskey/voiceurl）。
func parseIncomingVoiceXML(raw string) (*incomingVoiceJob, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, voiceXMLParseFailed
	}

	var parsed incomingVoiceXML
	if err := xml.Unmarshal([]byte(raw), &parsed); err != nil {
		return nil, voiceXMLParseFailed
	}
	if parsed.VoiceMsg == nil {
		return nil, voiceXMLMissingVoiceMsg
	}
	info := parsed.VoiceMsg

	cdnKey := strings.TrimSpace(info.VoiceURL)
	if cdnKey == "" {
		return nil, voiceXMLMissingVoiceURL
	}
	aesKey := strings.TrimSpace(info.AESKey)
	if aesKey == "" {
		return nil, voiceXMLMissingAESKey
	}
	if _, err := parseVoiceAESKey(aesKey); err != nil {
		return nil, err
	}

	durationMs := info.VoiceLength
	if durationMs < 0 || durationMs > maxVoiceDurationMs {
		// 非法/异常 voicelength 不影响下载，时长回退为解码后的 WAV 采样数。
		durationMs = 0
	}
	cipherLen := info.Length
	if cipherLen < 0 || cipherLen > maxVoiceCipherBytes {
		cipherLen = 0
	}
	format := info.VoiceFormat
	if format < 0 {
		format = 0
	}

	return &incomingVoiceJob{
		CDNKey:     cdnKey,
		AESKey:     aesKey,
		DurationMs: durationMs,
		Format:     format,
		CipherLen:  cipherLen,
	}, nil
}

// parseVoiceAESKey 校验并解析 XML aeskey：
//   - 32 位十六进制 → 16 字节密钥（腾讯 CDN 的常见形式）；
//   - 16 / 32 字节原始字符串 → 兼容少数版本直接填报原始字节。
func parseVoiceAESKey(raw string) ([]byte, error) {
	key := strings.TrimSpace(raw)
	if key == "" {
		return nil, voiceXMLMissingAESKey
	}
	if len(key) == 32 {
		if decoded, err := hex.DecodeString(key); err == nil {
			return decoded, nil
		}
	}
	if len(key) == 16 || len(key) == 32 {
		return []byte(key), nil
	}
	return nil, voiceXMLBadAESKey
}

// registerIncomingVoice 在入站事件推送前登记语音下载元数据，并修正 message 数组
// （docs/voice.md §2.1）。解析失败不影响事件转发：App 仍能收到
// 无文件的 voice 段（只是没有 duration_ms、也无法下载）。
func registerIncomingVoice(payload map[string]interface{}) {
	if payload == nil || !isIncomingVoicePayload(payload) {
		return
	}

	raw, _ := payload["raw_message"].(string)
	job, err := parseIncomingVoiceXML(raw)
	durationMs := 0
	if err != nil {
		// 只记固定错误（可能是不含 voicemsg 的语音事件）；不回传 XML 原文。
		Warn("入站语音 XML 解析失败", "reason", err)
	} else {
		durationMs = job.DurationMs
		messageID := payloadStringValue(payload["message_id"])
		if messageID == "" {
			Debug("入站语音缺少 message_id，跳过登记")
		} else {
			job.MessageID = messageID
			job.CreatedAt = time.Now()
			prunePendingVoiceJobs()
			pendingVoiceJobs.Store(messageID, job)
			Debug("已登记入站语音", "message_id", messageID, "duration_ms", job.DurationMs)
		}
	}

	// 即使登记失败也要替换 message：App 需要 voice 段才能把消息渲染成语音气泡。
	replaceIncomingVoiceMessage(payload, durationMs)
}

// isIncomingVoicePayload 判断事件是否语音：msg_type 兼容多种数值类型等于 34；
// 只有事件完全没有 msg_type（旧 hook）时才回退看 raw_message 是否带 <voicemsg。
func isIncomingVoicePayload(payload map[string]interface{}) bool {
	if hasPayloadMsgType(payload["msg_type"]) {
		return payloadMsgTypeIsVoice(payload["msg_type"])
	}
	raw, _ := payload["raw_message"].(string)
	return containsVoiceXMLTag(raw)
}

func payloadMsgTypeIsVoice(value interface{}) bool {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed) == "34"
	case json.Number:
		return typed.String() == "34"
	case float64:
		return typed == 34
	case float32:
		return typed == 34
	case int:
		return typed == 34
	case int32:
		return typed == 34
	case int64:
		return typed == 34
	case uint:
		return typed == 34
	case uint64:
		return typed == 34
	}
	return false
}

// containsVoiceXMLTag 只认真正的 `<voicemsg …>` 标签，避免正文里恰好出现
// "<voicemsg" 的文本被误判成语音事件。
func containsVoiceXMLTag(raw string) bool {
	if raw == "" {
		return false
	}
	offset := 0
	for {
		index := strings.Index(raw[offset:], "<voicemsg")
		if index < 0 {
			return false
		}
		pos := offset + index + len("<voicemsg")
		if pos >= len(raw) {
			return false
		}
		switch raw[pos] {
		case ' ', '\t', '\n', '\r', '>', '/':
			return true
		}
		offset = pos
	}
}

// replaceIncomingVoiceMessage 把 message 数组里的 [语音] 文本段替换成一个无文件的
// voice 段，其它段（如 at）原样保留；message 是字符串时整体替换。
// payload 类型异常时保持原样，绝不 panic。
func replaceIncomingVoiceMessage(payload map[string]interface{}, durationMs int) {
	newVoiceSegment := func() map[string]interface{} {
		data := map[string]interface{}{}
		if durationMs > 0 {
			data["duration_ms"] = durationMs
		}
		return map[string]interface{}{
			"type": "voice",
			"data": data,
		}
	}

	switch message := payload["message"].(type) {
	case nil:
		payload["message"] = []interface{}{newVoiceSegment()}
	case string:
		payload["message"] = []interface{}{newVoiceSegment()}
	case []interface{}:
		kept := make([]interface{}, 0, len(message)+1)
		hasVoice := false
		for _, segment := range message {
			segmentMap, ok := segment.(map[string]interface{})
			if !ok {
				kept = append(kept, segment)
				continue
			}
			segmentType, _ := segmentMap["type"].(string)
			if segmentType == "voice" {
				hasVoice = true
				kept = append(kept, segment)
				continue
			}
			if segmentType == "text" {
				text := ""
				if data, ok := segmentMap["data"].(map[string]interface{}); ok {
					text, _ = data["text"].(string)
				}
				if text == "[语音]" {
					if !hasVoice {
						kept = append(kept, newVoiceSegment())
						hasVoice = true
					}
					continue
				}
			}
			kept = append(kept, segment)
		}
		if !hasVoice {
			kept = append([]interface{}{newVoiceSegment()}, kept...)
		}
		payload["message"] = kept
	default:
		// 旧 hook / 异常类型：不猜结构，保持原样。
	}
}

// prunePendingVoiceJobs 清理过期登记，并在超过总量上限时删除最旧的条目；
// 幂等缓存用同一个 TTL 清理。
func prunePendingVoiceJobs() {
	now := time.Now()
	type jobEntry struct {
		messageID string
		createdAt time.Time
	}
	alive := make([]jobEntry, 0, pendingVoiceJobsLimit)
	pendingVoiceJobs.Range(func(key, value interface{}) bool {
		job, ok := value.(*incomingVoiceJob)
		if !ok || job == nil || now.Sub(job.CreatedAt) > pendingVoiceJobTTL {
			pendingVoiceJobs.Delete(key)
			return true
		}
		messageID, _ := key.(string)
		alive = append(alive, jobEntry{messageID: messageID, createdAt: job.CreatedAt})
		return true
	})
	completedVoiceFetches.Range(func(key, value interface{}) bool {
		entry, ok := value.(completedVoiceFetch)
		if !ok || now.Sub(entry.CreatedAt) > pendingVoiceJobTTL {
			completedVoiceFetches.Delete(key)
		}
		return true
	})
	if len(alive) < pendingVoiceJobsLimit {
		return
	}
	sort.Slice(alive, func(i, j int) bool { return alive[i].createdAt.Before(alive[j].createdAt) })
	remove := len(alive) - pendingVoiceJobsLimit + 1
	for i := 0; i < remove && i < len(alive); i++ {
		pendingVoiceJobs.Delete(alive[i].messageID)
	}
}

// ---------------------------------------------------------------------------
// 入站：/fetch_voice 下载 / 解密 / 解码 / 落盘
// ---------------------------------------------------------------------------

// triggerIncomingVoiceDownload 是可注入的下载触发器（单测替换成伪造分片）。
// 生产实现只检查 Frida 是否就绪，然后调用 hook 已有的 triggerDownload 导出。
//
// 真机验证：4.2.0.5 语音下载 fileType=15（0x0F），见 docs/voice.md；
// voiceurl 是否被 download hook 接受、分片 CDNURL 是否与 XML 一致都需 Lead 真机 Spike。
var triggerIncomingVoiceDownload = func(job *incomingVoiceJob, fileType int, tempPath string) (string, error) {
	if fridaScript == nil {
		return "", errVoiceBridgeUnavailable
	}
	// 微信的下载启动是同步调用；真机异常时可能长时间不返回。用带超时的 RPC，
	// 避免 HTTP handler / 语音队列被一直占用。
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ret := fridaScript.ExportsCallWithContext(ctx, "triggerDownload",
		myWechatId, job.CDNKey, job.AESKey, tempPath, fileType)
	if ret == frida.ErrContextCancelled {
		return "", errVoiceTriggerTimeout
	}
	return fmt.Sprint(ret), nil
}

// voiceDownloadFileTypes 返回 /fetch_voice 依次尝试的 triggerDownload fileType。
// 默认 [15]（语音 / 0x0F）；WECHATAI_VOICE_FILE_TYPE 可覆盖（支持 "15" 或 "15,5,6"）。
func voiceDownloadFileTypes() []int {
	raw := strings.TrimSpace(os.Getenv(envVoiceFileType))
	if raw == "" {
		return []int{15}
	}
	types := make([]int, 0, 2)
	seen := make(map[int]bool, 2)
	for _, part := range strings.Split(raw, ",") {
		value, err := strconv.Atoi(strings.TrimSpace(part))
		if err != nil || value <= 0 || value > 32 || seen[value] {
			continue
		}
		seen[value] = true
		types = append(types, value)
	}
	if len(types) == 0 {
		Warn("WECHATAI_VOICE_FILE_TYPE 无效，回退默认 fileType", "values", "15")
		return []int{15}
	}
	return types
}

// resolvedVoiceMediaDir 解析并创建语音落盘目录（与入站图片共用 media_dir 契约）。
func resolvedVoiceMediaDir() (string, error) {
	dir := strings.TrimSpace(config.MediaDir)
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", voiceMediaDirCreateFailed
		}
		dir = filepath.Join(home, "Library", "Application Support", "WeChatAI", "media")
	} else {
		dir = expandUserPath(dir)
		dir = filepath.Clean(dir)
	}
	if dir == "" {
		return "", voiceMediaDirCreateFailed
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("%w: %v", voiceMediaDirCreateFailed, err)
	}
	mediaDir = dir
	return dir, nil
}

// prepareVoiceTempDir 创建 `<media_dir>/.tmp` 并校验仍在 media_dir 内。
func prepareVoiceTempDir(mediaRoot string) (string, error) {
	tempDir := filepath.Join(mediaRoot, ".tmp")
	if err := ensureWithinRoot(mediaRoot, tempDir); err != nil {
		return "", err
	}
	if err := os.MkdirAll(tempDir, 0o755); err != nil {
		return "", fmt.Errorf("%w: %v", voiceTempDirCreateFailed, err)
	}
	return tempDir, nil
}

// expectedVoiceCipherLength 估算下载密文长度：XML length 无论代表明文还是密文长度，
// 密文都是明文向上取整到 AES 块（与图片 decryptImageBytes 的 expectedCipherLength
// 同一规则）；没有 length 时返回 0，交给「分片稳定」判定。
func expectedVoiceCipherLength(job *incomingVoiceJob) int {
	if job == nil || job.CipherLen <= 0 {
		return 0
	}
	return expectedCipherLength(job.CipherLen)
}

// waitForVoiceMedia 在 deadline 内等待该 CDN key 的分片达到「足够长或稳定」。
// minSize > 0 时要求数据至少到达 minSize 字节（用于等待分片增长）。
func waitForVoiceMedia(cdnKey string, expected, minSize int, deadline time.Time) ([]byte, bool) {
	if cdnKey == "" {
		return nil, false
	}
	for {
		if media, done := snapshotImageDownload(cdnKey, expected, minSize); done {
			return media, true
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil, false
		}
		sleep := imageDownloadPollEvery
		if remaining < sleep {
			sleep = remaining
		}
		time.Sleep(sleep)
	}
}

// hasVoiceMedia 表示该 CDN key 已经有任意分片到达（不要求已完成）。
func hasVoiceMedia(cdnKey string) bool {
	return hasImageMedia(cdnKey)
}

// isVoiceTriggerRejected 判断 hook triggerDownload 的返回值是否表示未接受请求。
func isVoiceTriggerRejected(result string) bool {
	switch strings.ToLower(strings.TrimSpace(result)) {
	case "", "fail", "0":
		return true
	}
	return false
}

// fetchIncomingVoice 触发微信下载一条入站语音，解密、保存 .silk、解码为 16k WAV
// 后返回本地路径（docs/voice.md §2.2）。总预算 ≤ 25s；成功结果按
// message_id 幂等缓存。
func fetchIncomingVoice(messageID string) (voiceFetchResult, error) {
	return fetchIncomingVoiceWithTypes(messageID, nil)
}

// fetchIncomingVoiceWithTypes 允许调用方（App/真机 Spike）覆盖 triggerDownload 的 fileType
// 列表；nil 表示按环境变量/默认值。失败后 job 会恢复登记，便于同一 message_id 换类型重试。
func fetchIncomingVoiceWithTypes(messageID string, override []int) (voiceFetchResult, error) {
	messageID = strings.TrimSpace(messageID)
	if messageID == "" {
		return voiceFetchResult{}, errVoiceJobNotFound
	}

	// 幂等：App 重试/重复调用直接复用已落盘结果。
	if cached, ok := lookupCompletedVoiceFetch(messageID); ok {
		Debug("语音获取命中缓存", "message_id", messageID)
		return cached, nil
	}

	value, ok := pendingVoiceJobs.LoadAndDelete(messageID)
	if !ok {
		Debug("未找到入站语音登记", "message_id", messageID)
		return voiceFetchResult{}, errVoiceJobNotFound
	}
	job, ok := value.(*incomingVoiceJob)
	if !ok || job == nil {
		return voiceFetchResult{}, errVoiceJobNotFound
	}

	select {
	case voiceFetchSemaphore <- struct{}{}:
		defer func() { <-voiceFetchSemaphore }()
	case <-time.After(voiceFetchSemaphoreWait):
		restorePendingVoiceJob(job)
		Warn("语音获取失败", "message_id", messageID, "reason", errVoiceFetchBusy)
		return voiceFetchResult{}, errVoiceFetchBusy
	}

	mediaRoot, err := resolvedVoiceMediaDir()
	if err != nil {
		restorePendingVoiceJob(job)
		Warn("语音获取失败", "message_id", messageID, "reason", err)
		return voiceFetchResult{}, err
	}

	deadline := time.Now().Add(voiceFetchTotalBudget)
	expected := expectedVoiceCipherLength(job)
	fileTypes := voiceDownloadFileTypes()
	if len(override) > 0 {
		fileTypes = override
	}
	Debug("开始获取语音", "message_id", messageID,
		"file_types", fileTypes, "cipher_len", job.CipherLen, "duration_ms", job.DurationMs)

	var lastErr error
	lastLen := 0

	// 1. 先等自然分片：微信可能在事件到达前后自行下载语音。
	naturalDeadline := time.Now().Add(voiceNaturalGraceWindow)
	if naturalDeadline.After(deadline) {
		naturalDeadline = deadline
	}
	if media, ok := waitForVoiceMedia(job.CDNKey, expected, 0, naturalDeadline); ok {
		lastLen = len(media)
		if result, err := decodeAndSaveIncomingVoice(job, media, mediaRoot); err == nil {
			storeCompletedVoiceFetch(messageID, result)
			Info("语音获取成功", "message_id", messageID, "source", "natural",
				"bytes", len(media), "duration_ms", result.DurationMs)
			return result, nil
		} else {
			lastErr = err
			Debug("自然分片解码失败，继续等待/触发", "message_id", messageID, "reason", err)
		}
	}

	// 2. 依次尝试 fileType（默认 15=语音），每种最多 8s；已有分片时不再触发，
	//    避免自然下载与触发共用同一 CDN key 导致分片重复追加。
	for _, fileType := range fileTypes {
		if !time.Now().Before(deadline) {
			if lastErr == nil {
				lastErr = errVoiceDownloadTimeout
			}
			break
		}
		startedAt := time.Now()
		candidateDeadline := time.Now().Add(voiceCandidateBudget)
		if candidateDeadline.After(deadline) {
			candidateDeadline = deadline
		}
		attemptResult := "incomplete"
		var triggerErr error

		if lastLen == 0 && !hasVoiceMedia(job.CDNKey) {
			tempDir, err := prepareVoiceTempDir(mediaRoot)
			if err != nil {
				lastErr = err
				break
			}
			tempPath := filepath.Join(tempDir, "voice-fetch-"+randomHex(8)+".bin")
			if err := ensureWithinRoot(mediaRoot, tempPath); err != nil {
				lastErr = err
				break
			}
			triggered, err := triggerIncomingVoiceDownload(job, fileType, tempPath)
			_ = os.Remove(tempPath)
			Debug("语音下载触发返回", "message_id", messageID, "file_type", fileType,
				"result", triggered)
			if err != nil {
				triggerErr = err
			} else if isVoiceTriggerRejected(triggered) {
				triggerErr = errVoiceTriggerRejected
			}
			if triggerErr != nil {
				Debug("语音下载触发失败，继续等待微信自然下载",
					"message_id", messageID, "file_type", fileType, "reason", triggerErr)
			}
		}

		magicAttempts := 0
		for time.Now().Before(candidateDeadline) {
			minSize := lastLen + 1
			if lastLen == 0 {
				minSize = 0
			}
			media, ok := waitForVoiceMedia(job.CDNKey, expected, minSize, candidateDeadline)
			if !ok {
				break
			}
			lastLen = len(media)
			result, err := decodeAndSaveIncomingVoice(job, media, mediaRoot)
			if err == nil {
				Debug("语音下载尝试", "message_id", messageID, "file_type", fileType,
					"elapsed_ms", time.Since(startedAt).Milliseconds(), "result", "ok",
					"bytes", len(media))
				storeCompletedVoiceFetch(messageID, result)
				Info("语音获取成功", "message_id", messageID, "source", "trigger",
					"file_type", fileType, "bytes", len(media), "duration_ms", result.DurationMs)
				return result, nil
			}
			lastErr = err
			attemptResult = voiceAttemptResult(err)
			magicAttempts++
			if magicAttempts >= voiceMagicRetryLimit {
				break
			}
		}
		Debug("语音下载尝试", "message_id", messageID, "file_type", fileType,
			"elapsed_ms", time.Since(startedAt).Milliseconds(), "result", attemptResult,
			"bytes", lastLen)

		if triggerErr != nil && lastLen == 0 && lastErr == nil {
			// 既没有分片、也没有解码错误时，用触发失败原因作为最终错误（更可诊断）。
			lastErr = triggerErr
		}
		if errors.Is(triggerErr, errVoiceBridgeUnavailable) {
			// Frida 不可用时后续 fileType 也一定失败，避免重复等待。
			lastErr = triggerErr
			break
		}
	}

	if lastErr == nil {
		lastErr = errVoiceDownloadTimeout
	}
	restorePendingVoiceJob(job)
	Warn("语音获取失败", "message_id", messageID, "reason", lastErr)
	return voiceFetchResult{}, lastErr
}

// restorePendingVoiceJob 在获取失败时恢复登记，允许 App 重试（成功结果走幂等缓存）。
func restorePendingVoiceJob(job *incomingVoiceJob) {
	if job == nil || job.MessageID == "" {
		return
	}
	if time.Since(job.CreatedAt) > pendingVoiceJobTTL {
		return
	}
	if _, ok := completedVoiceFetches.Load(job.MessageID); ok {
		return
	}
	pendingVoiceJobs.Store(job.MessageID, job)
}

// lookupCompletedVoiceFetch 读取幂等缓存；文件已被清理时视为未命中。
func lookupCompletedVoiceFetch(messageID string) (voiceFetchResult, bool) {
	value, ok := completedVoiceFetches.Load(messageID)
	if !ok {
		return voiceFetchResult{}, false
	}
	entry, ok := value.(completedVoiceFetch)
	if !ok || time.Since(entry.CreatedAt) > pendingVoiceJobTTL {
		completedVoiceFetches.Delete(messageID)
		return voiceFetchResult{}, false
	}
	if entry.Result.Path == "" || entry.Result.SilkPath == "" {
		completedVoiceFetches.Delete(messageID)
		return voiceFetchResult{}, false
	}
	if _, err := os.Stat(entry.Result.Path); err != nil {
		completedVoiceFetches.Delete(messageID)
		return voiceFetchResult{}, false
	}
	if _, err := os.Stat(entry.Result.SilkPath); err != nil {
		completedVoiceFetches.Delete(messageID)
		return voiceFetchResult{}, false
	}
	return entry.Result, true
}

// storeCompletedVoiceFetch 写入幂等缓存（message_id → 本地文件）。
func storeCompletedVoiceFetch(messageID string, result voiceFetchResult) {
	if messageID == "" || result.Path == "" {
		return
	}
	completedVoiceFetches.Store(messageID, completedVoiceFetch{
		CreatedAt: time.Now(),
		Result:    result,
	})
}

// decodeAndSaveIncomingVoice 对一份密文快照做解密 + 魔数校验 + 时长完整性校验，
// 通过后保存 .silk、解码 16k PCM、保存 16k 单声道 WAV。
func decodeAndSaveIncomingVoice(job *incomingVoiceJob, media []byte, mediaRoot string) (voiceFetchResult, error) {
	plain, err := decryptVoiceBytes(media, job.AESKey, job.CipherLen)
	if err != nil {
		return voiceFetchResult{}, err
	}
	if !isVoiceSilkMagic(plain) {
		return voiceFetchResult{}, errVoiceSilkInvalid
	}
	trimmedSilk, ok := trimSilkToFrames(plain)
	if !ok {
		return voiceFetchResult{}, errVoiceSilkInvalid
	}
	pcm, err := decodeVoiceSilkPCM(trimmedSilk)
	if err != nil {
		return voiceFetchResult{}, err
	}

	// 完整性：解码时长明显短于 XML voicelength 时视为半截数据，继续等分片。
	durationMs := job.DurationMs
	if durationMs <= 0 {
		durationMs = voicePCMDurationMs(pcm)
	} else if voicePCMDurationMs(pcm)+voiceDurationToleranceMs < durationMs {
		return voiceFetchResult{}, errVoiceSilkInvalid
	}

	silkPath, err := saveIncomingVoiceFile(mediaRoot, job.MessageID, "", "silk", trimmedSilk)
	if err != nil {
		return voiceFetchResult{}, err
	}
	wavData, err := buildVoiceWAV(pcm)
	if err != nil {
		return voiceFetchResult{}, err
	}
	wavPath, err := saveIncomingVoiceFile(mediaRoot, job.MessageID, "_16k", "wav", wavData)
	if err != nil {
		return voiceFetchResult{}, err
	}
	return voiceFetchResult{
		Path:       wavPath,
		SilkPath:   silkPath,
		DurationMs: durationMs,
	}, nil
}

// decryptVoiceBytes 把下载到的数据还原成明文 SILK。
//
//   - 已经是 SILK 明文（部分账号本地缓存/encryver=0）时直接使用；
//   - 否则按 AES-ECB 逐块解密（key 支持 32 位十六进制 / 16 字节原始 / 32 字节
//     ASCII，与图片 decryptImageBytes 同一套规则），数据长度非 16 倍数时末尾补 0；
//   - 按 XML length 截断：length 是 CDN 密文长度（契约 §2.1 cipherLen），
//     只在它是整块且小于数据长度时用于裁掉重复分片；解密后再按 length 截断一次，
//     兼容少数把 length 当成明文长度的版本；
//   - 最后校验 Tencent SILK 魔数。
func decryptVoiceBytes(data []byte, aesKey string, cipherLen int) ([]byte, error) {
	if len(data) == 0 {
		return nil, errVoiceSilkInvalid
	}
	if isVoiceSilkMagic(data) {
		// 明文直通：length 是密文长度时不能拿来裁剪明文帧。
		return data, nil
	}

	key, err := parseVoiceAESKey(aesKey)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, errVoiceDecryptFailed
	}

	aligned := data
	if cipherLen > 0 && cipherLen < len(aligned) && cipherLen%block.BlockSize() == 0 {
		aligned = aligned[:cipherLen]
	}
	if remainder := len(aligned) % block.BlockSize(); remainder != 0 {
		padded := make([]byte, len(aligned)+block.BlockSize()-remainder)
		copy(padded, aligned)
		aligned = padded
	}
	if len(aligned) == 0 {
		return nil, errVoiceDecryptFailed
	}

	decrypted := make([]byte, len(aligned))
	for offset := 0; offset < len(aligned); offset += block.BlockSize() {
		block.Decrypt(decrypted[offset:offset+block.BlockSize()], aligned[offset:offset+block.BlockSize()])
	}

	if cipherLen > 0 && cipherLen < len(decrypted) {
		decrypted = decrypted[:cipherLen]
	}
	// AES 补齐/裁断后仍可能残留尾部字节，SILK 解码前按帧裁齐。
	trimmed, ok := trimSilkToFrames(decrypted)
	if !ok {
		if isVoiceSilkMagic(decrypted) {
			return decrypted, nil
		}
		return nil, errVoiceSilkInvalid
	}
	return trimmed, nil
}

// silkHeaderLength 返回 SILK 文件头长度：Tencent 变体是 `\x02#!SILK_V3`（10 字节），
// 标准变体是 `#!SILK_V3`（9 字节，兼容少数来源）。
func silkHeaderLength(data []byte) (int, bool) {
	if len(data) >= 10 && data[0] == 0x02 && bytes.HasPrefix(data[1:], []byte("#!SILK_V3")) {
		return 10, true
	}
	if len(data) >= 9 && bytes.HasPrefix(data, []byte("#!SILK_V3")) {
		return 9, true
	}
	return 0, false
}

// isVoiceSilkMagic 校验是否是 SILK 明文（Tencent 变体优先）。
func isVoiceSilkMagic(data []byte) bool {
	_, ok := silkHeaderLength(data)
	return ok
}

// trimSilkToFrames 按 SILK 帧结构裁掉尾部半帧/AES 补齐字节。
// 返回裁剪后的完整帧数据；一个完整帧都没有时返回 ok=false。
func trimSilkToFrames(data []byte) ([]byte, bool) {
	headerLen, ok := silkHeaderLength(data)
	if !ok {
		return nil, false
	}
	offset := headerLen
	for offset+2 <= len(data) {
		frameLen := int(binary.LittleEndian.Uint16(data[offset : offset+2]))
		if frameLen <= 0 || frameLen > maxSilkVoiceFrameBytes {
			break
		}
		if offset+2+frameLen > len(data) {
			break
		}
		offset += 2 + frameLen
	}
	if offset <= headerLen {
		return nil, false
	}
	return data[:offset], true
}

// decodeVoiceSilkPCM 用 go-silk 把 SILK 解码成 16k 单声道 s16le PCM。
func decodeVoiceSilkPCM(silkData []byte) ([]byte, error) {
	trimmed, ok := trimSilkToFrames(silkData)
	if !ok {
		return nil, errVoiceSilkInvalid
	}
	pcm, err := silk.DecodeSilkBuffToPcm(trimmed, voiceSampleRate)
	if err != nil || len(pcm) == 0 {
		return nil, errVoiceDecodeFailed
	}
	if len(pcm)%2 != 0 {
		pcm = pcm[:len(pcm)-1]
	}
	if len(pcm) == 0 {
		return nil, errVoiceDecodeFailed
	}
	return pcm, nil
}

// voicePCMDurationMs 由 16k 单声道 s16le PCM 计算时长（毫秒）。
func voicePCMDurationMs(pcm []byte) int {
	if len(pcm) <= 0 {
		return 0
	}
	return int(int64(len(pcm)) * 1000 / (voiceSampleRate * 2))
}

// voiceSilkDurationMs 由 SILK 解码后的 PCM 采样数计算时长；
// 解码失败时回退为「帧数 × 20ms」。语音气泡/发送时长以 SILK 帧为准，不用 TTS 采样数。
func voiceSilkDurationMs(silkData []byte) int32 {
	if pcm, err := decodeVoiceSilkPCM(silkData); err == nil {
		if duration := voicePCMDurationMs(pcm); duration > 0 {
			return int32(duration)
		}
	}
	if frames, ok := countSilkFrames(silkData); ok && frames > 0 {
		return int32(frames * voiceSilkFrameMs)
	}
	return 0
}

// countSilkFrames 统计完整 SILK 帧数量。
func countSilkFrames(silkData []byte) (int, bool) {
	trimmed, ok := trimSilkToFrames(silkData)
	if !ok {
		return 0, false
	}
	headerLen, _ := silkHeaderLength(trimmed)
	offset := headerLen
	frames := 0
	for offset+2 <= len(trimmed) {
		frameLen := int(binary.LittleEndian.Uint16(trimmed[offset : offset+2]))
		if frameLen <= 0 || frameLen > maxSilkVoiceFrameBytes || offset+2+frameLen > len(trimmed) {
			break
		}
		frames++
		offset += 2 + frameLen
	}
	return frames, frames > 0
}

// buildVoiceWAV 把 16k 单声道 s16le PCM 包成标准 44 字节 WAV。
func buildVoiceWAV(pcm []byte) ([]byte, error) {
	if len(pcm) == 0 {
		return nil, voiceWAVBuildFailed
	}
	if len(pcm)%2 != 0 {
		pcm = pcm[:len(pcm)-1]
	}
	dataLen := len(pcm)
	wav := make([]byte, voiceWAVHeaderSize+dataLen)
	copy(wav[0:4], "RIFF")
	binary.LittleEndian.PutUint32(wav[4:8], uint32(36+dataLen))
	copy(wav[8:12], "WAVE")
	copy(wav[12:16], "fmt ")
	binary.LittleEndian.PutUint32(wav[16:20], 16) // PCM fmt chunk size
	binary.LittleEndian.PutUint16(wav[20:22], 1)  // PCM
	binary.LittleEndian.PutUint16(wav[22:24], voiceChannels)
	binary.LittleEndian.PutUint32(wav[24:28], voiceSampleRate)
	binary.LittleEndian.PutUint32(wav[28:32], voiceSampleRate*voiceChannels*voiceBitsPerSample/8)
	binary.LittleEndian.PutUint16(wav[32:34], voiceChannels*voiceBitsPerSample/8)
	binary.LittleEndian.PutUint16(wav[34:36], voiceBitsPerSample)
	copy(wav[36:40], "data")
	binary.LittleEndian.PutUint32(wav[40:44], uint32(dataLen))
	copy(wav[voiceWAVHeaderSize:], pcm)
	return wav, nil
}

// saveIncomingVoiceFile 保存到 `<media_dir>/<yyyy-MM-dd>/voice_<id><suffix>.<ext>`；
// 文件名中的 message_id 只保留安全字符。同名同大小文件直接复用（幂等）。
func saveIncomingVoiceFile(mediaRoot, messageID, suffix, ext string, data []byte) (string, error) {
	dayDir := filepath.Join(mediaRoot, time.Now().Format("2006-01-02"))
	if err := ensureWithinRoot(mediaRoot, dayDir); err != nil {
		return "", err
	}
	if err := os.MkdirAll(dayDir, 0o755); err != nil {
		return "", fmt.Errorf("%w: %v", voiceFileSaveFailed, err)
	}
	name := "voice_" + sanitizeVoiceFileID(messageID) + suffix + "." + ext
	path := filepath.Join(dayDir, name)
	if err := ensureWithinRoot(mediaRoot, path); err != nil {
		return "", err
	}
	if info, err := os.Stat(path); err == nil && info.Size() == int64(len(data)) {
		return path, nil
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return "", fmt.Errorf("%w: %v", voiceFileSaveFailed, err)
	}
	return path, nil
}

// sanitizeVoiceFileID 只保留字母/数字/-/_，限制 64 字符；空值用随机串。
func sanitizeVoiceFileID(messageID string) string {
	var builder strings.Builder
	for _, r := range messageID {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			builder.WriteRune(r)
		}
	}
	safe := builder.String()
	if safe == "" {
		return randomHex(6)
	}
	if len(safe) > 64 {
		safe = safe[:64]
	}
	return safe
}

// voiceAttemptResult 把内部错误映射成短标签，只用于 debug 日志（不含 key/路径）。
func voiceAttemptResult(err error) string {
	switch {
	case err == nil:
		return "ok"
	case errors.Is(err, errVoiceSilkInvalid):
		return "silk_invalid"
	case errors.Is(err, errVoiceDecryptFailed):
		return "decrypt_failed"
	case errors.Is(err, errVoiceDecodeFailed):
		return "decode_failed"
	case errors.Is(err, errVoiceBridgeUnavailable):
		return "frida_unavailable"
	case errors.Is(err, errVoiceTriggerRejected):
		return "trigger_rejected"
	case errors.Is(err, errVoiceDownloadTimeout):
		return "timeout"
	default:
		return "failed"
	}
}

// ---------------------------------------------------------------------------
// 入站：HTTP handler
// ---------------------------------------------------------------------------

// fetchVoiceRequest 是 POST /fetch_voice 的请求体。
type fetchVoiceRequest struct {
	MessageID string `json:"message_id"`
	// FileTypes 可选：真机 Spike 时覆盖 triggerDownload 的 fileType 列表（1..32）。
	FileTypes []int `json:"file_types,omitempty"`
}

// writeVoiceJSON 输出 /fetch_voice 与 /send_voice 的 JSON 响应。
func writeVoiceJSON(w http.ResponseWriter, status int, payload map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

// fetchVoiceHandler 处理 App 的入站语音获取请求（docs/voice.md §2.2）：
// 鉴权与 /send_* 一致；成功 200 `{ok:true,path,silk_path,duration_ms}`；
// 未登记/下载失败都是 HTTP 200 `{ok:false,error:"中文原因"}`（不返回 500）。
// 响应与日志都不包含 aeskey / voiceurl(CDN key) / XML / 音频。
func fetchVoiceHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeVoiceJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"ok":    false,
			"error": "仅支持 POST",
		})
		Error("语音获取仅支持 POST")
		return
	}

	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if config.OnebotToken == "" || token == "" || !hmac.Equal([]byte(token), []byte(config.OnebotToken)) {
		writeVoiceJSON(w, http.StatusUnauthorized, map[string]any{
			"ok":    false,
			"error": "未授权",
		})
		Error("语音获取未授权")
		return
	}

	var req fetchVoiceRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeVoiceJSON(w, http.StatusBadRequest, map[string]any{
			"ok":    false,
			"error": "无效的 JSON",
		})
		Error("语音获取请求 JSON 无效")
		return
	}
	req.MessageID = strings.TrimSpace(req.MessageID)
	if req.MessageID == "" {
		writeVoiceJSON(w, http.StatusBadRequest, map[string]any{
			"ok":    false,
			"error": "参数缺失",
		})
		Error("语音获取请求参数缺失")
		return
	}

	override := make([]int, 0, len(req.FileTypes))
	for _, ft := range req.FileTypes {
		if ft > 0 && ft <= 32 {
			override = append(override, ft)
		}
	}
	result, err := fetchIncomingVoiceWithTypes(req.MessageID, override)
	if err != nil {
		// 契约：下载/未登记等失败都是 HTTP 200 + ok:false，不做 500 语义。
		writeVoiceJSON(w, http.StatusOK, map[string]any{
			"ok":    false,
			"error": err.Error(),
		})
		return
	}

	writeVoiceJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"path":        fileURLForPath(result.Path),
		"silk_path":   fileURLForPath(result.SilkPath),
		"duration_ms": result.DurationMs,
	})
}

// fileURLForPath 把本地绝对路径转成 file:// URL（含百分号转义）。
func fileURLForPath(path string) string {
	return (&url.URL{Scheme: "file", Path: path}).String()
}

// ---------------------------------------------------------------------------
// 出站：16k PCM → Tencent SILK → 现有 upload/send
// ---------------------------------------------------------------------------

// voiceSendEnabled 判断是否显式开启真机语音上传尝试。
// 默认关闭：4.2.0.5 Hook 没有语音发送通道，bridge 返回 voice_send_unsupported，
// App 自动降级为文字（docs/voice.md §3.3）。
// voiceWarmupError 表示 bridge/Hook 刚启动，登录稳定门禁未过（默认 60s）。
// 携带剩余毫秒，App 用它显示倒计时并在此之前不发语音。
type voiceWarmupError struct {
	RemainingMS int64
}

func (e *voiceWarmupError) Error() string { return "voice_warming_up" }

// voiceDiagQuery 可注入（单测替换），生产调用 Hook 的 r3VoiceDiag。
var voiceDiagQuery = func() (string, error) {
	if fridaScript == nil {
		return "", errVoiceBridgeUnavailable
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ret := fridaScript.ExportsCallWithContext(ctx, "r3VoiceDiag")
	if ret == frida.ErrContextCancelled {
		return "", errVoiceTriggerTimeout
	}
	return fmt.Sprint(ret), nil
}

func voiceSendEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(envVoiceSend))) {
	case "1", "true", "yes", "on", "legacy":
		return true
	}
	// App 运行期合并后的 hook JSON 会带 r3VoiceSend=true；bridge 无需额外环境变量。
	conf := strings.TrimSpace(config.WechatConf)
	if conf == "" {
		return false
	}
	data, err := os.ReadFile(conf)
	if err != nil {
		return false
	}
	var cfg map[string]interface{}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return false
	}
	if v, ok := cfg["r3VoiceSend"].(string); ok {
		switch strings.ToLower(strings.TrimSpace(v)) {
		case "true", "1", "yes", "on":
			return true
		}
	}
	return false
}

// triggerVoiceUpload 是可注入的上传触发器（单测替换，避免连接 Frida）。
// 生产实现调用 hook 现有 triggerUploadVoice；upload_voice_finish 由 main.go 的
// 消息回调把 send_voice 任务交给 worker（现有链路，不新增 Hook 导出）。
//
// 未真机验证：4.2.0.5 的 uploadvoice/sendvoicemsg 尚未适配，只有 Lead 真机 Spike 能确认。
var triggerVoiceUpload = func(targetID, voicePath, payloadHex, audioHex string, durationMs int32, voiceFileID string) (string, error) {
	if fridaScript == nil {
		return "", errVoiceBridgeUnavailable
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ret := fridaScript.ExportsCallWithContext(ctx, "triggerUploadVoice",
		targetID, voicePath, payloadHex, audioHex, durationMs, voiceFileID)
	if ret == frida.ErrContextCancelled {
		return "", errVoiceTriggerTimeout
	}
	return fmt.Sprint(ret), nil
}

// decodeVoicePCM16kBase64 解码 App 传入的 pcm16k（base64 的 16k 单声道 s16le）。
func decodeVoicePCM16kBase64(encoded string) ([]byte, error) {
	raw := strings.TrimSpace(encoded)
	if raw == "" {
		return nil, errVoicePCMEmpty
	}
	if strings.HasPrefix(raw, "base64://") {
		raw = strings.TrimPrefix(raw, "base64://")
	} else if idx := strings.Index(raw, ","); idx != -1 {
		// 兼容 data:audio/wav;base64,... 形式（App 正常只会传纯 base64）。
		raw = raw[idx+1:]
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, errVoicePCMEmpty
	}
	data, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		if fallback, fallbackErr := base64.RawStdEncoding.DecodeString(strings.TrimRight(raw, "=")); fallbackErr == nil {
			data = fallback
		} else {
			return nil, errVoicePCMInvalid
		}
	}
	if len(data) == 0 {
		return nil, errVoicePCMEmpty
	}
	// 契约是 base64 的 s16le PCM；同时兼容 App 直接传 16k WAV base64
	//（去掉 RIFF 头后取 data chunk），降低 App 侧拆 WAV 头的集成风险。
	data, err = extractPCMFromWAVIfPresent(data)
	if err != nil {
		return nil, err
	}
	if len(data)%2 != 0 || len(data) < minVoiceSendPCMBytes {
		return nil, errVoicePCMInvalid
	}
	if len(data) > maxVoiceSendPCMBytes {
		return nil, errVoicePCMLength
	}
	return data, nil
}

// extractPCMFromWAVIfPresent 若输入是 WAV（RIFF/WAVE）则校验 16k / 单声道 / 16-bit
// 并返回 data chunk 的 s16le PCM；普通 PCM 原样返回。
func extractPCMFromWAVIfPresent(data []byte) ([]byte, error) {
	if len(data) < 12 || string(data[0:4]) != "RIFF" || string(data[8:12]) != "WAVE" {
		return data, nil
	}
	offset := 12
	sampleRate := 0
	channels := 0
	bitsPerSample := 0
	var pcm []byte
	for offset+8 <= len(data) {
		chunkID := string(data[offset : offset+4])
		chunkSize := int(binary.LittleEndian.Uint32(data[offset+4 : offset+8]))
		if chunkSize < 0 || offset+8+chunkSize > len(data) {
			return nil, errVoicePCMInvalid
		}
		body := offset + 8
		switch chunkID {
		case "fmt ":
			if chunkSize < 16 {
				return nil, errVoicePCMInvalid
			}
			audioFormat := binary.LittleEndian.Uint16(data[body : body+2])
			channels = int(binary.LittleEndian.Uint16(data[body+2 : body+4]))
			sampleRate = int(binary.LittleEndian.Uint32(data[body+4 : body+8]))
			bitsPerSample = int(binary.LittleEndian.Uint16(data[body+14 : body+16]))
			if audioFormat != 1 {
				return nil, errVoicePCMInvalid
			}
		case "data":
			pcm = data[body : body+chunkSize]
		}
		offset = body + chunkSize
		if chunkSize%2 == 1 {
			offset++ // RIFF 奇数长度 chunk 的补齐字节
		}
	}
	if len(pcm) == 0 || sampleRate != voiceSampleRate || channels != voiceChannels || bitsPerSample != voiceBitsPerSample {
		return nil, errVoicePCMInvalid
	}
	return pcm, nil
}

// encodeVoicePCM16kToTencentSilk 用 go-silk 把 16k 单声道 s16le PCM 编码成
// Tencent SILK（`\x02#!SILK_V3` 头），返回 SILK 与以帧时长计算的 duration_ms。
// 不依赖 ffmpeg / pilk（与 legacy ConvertToSilk 的外部依赖解耦）。
func encodeVoicePCM16kToTencentSilk(pcm []byte) ([]byte, int32, error) {
	if len(pcm) == 0 || len(pcm)%2 != 0 {
		return nil, 0, errVoicePCMInvalid
	}
	silkData, err := silk.EncodePcmBuffToSilk(pcm, voiceSampleRate, voiceSampleRate, true)
	if err != nil || len(silkData) == 0 {
		return nil, 0, errVoiceEncodeFailed
	}
	trimmed, ok := trimSilkToFrames(silkData)
	if !ok {
		return nil, 0, errVoiceEncodeFailed
	}
	durationMs := voiceSilkDurationMs(trimmed)
	if durationMs <= 0 {
		return nil, 0, errVoiceEncodeFailed
	}
	return trimmed, durationMs, nil
}

// encodeVoicePCM16kToWeChatSilk 用官方 SILK SDK 编出微信可播放的 24k SILK。
// 真机（2026-10-26）：go-silk 输出在微信无声/不停止；官方 -tencent 24k 可播放。
func encodeVoicePCM16kToWeChatSilk(pcm []byte) ([]byte, int32, error) {
	if len(pcm) == 0 || len(pcm)%2 != 0 {
		return nil, 0, errVoicePCMInvalid
	}
	pcm24 := resamplePCM16kTo24k(pcm)
	// 官方编码器要求 20ms 整数帧；TTS 采样数通常不是整数帧，补静音对齐。
	const packetSamples = 24000 / 50
	if samples := len(pcm24) / 2; samples%packetSamples != 0 {
		pad := (packetSamples - samples%packetSamples) * 2
		pcm24 = append(pcm24, make([]byte, pad)...)
	}
	silkData, err := silkenc.Encode(pcm24, 24000)
	if err != nil || len(silkData) == 0 {
		return nil, 0, fmt.Errorf("%w: %v", errVoiceEncodeFailed, err)
	}
	trimmed, ok := trimSilkToFrames(silkData)
	if !ok {
		return nil, 0, errVoiceEncodeFailed
	}
	durationMs := voiceSilkDurationMs(trimmed)
	if durationMs <= 0 {
		return nil, 0, errVoiceEncodeFailed
	}
	return trimmed, durationMs, nil
}

// resamplePCM16kTo24k 线性插值 16k→24k（s16le，单声道）。
func resamplePCM16kTo24k(pcm []byte) []byte {
	inSamples := len(pcm) / 2
	if inSamples == 0 {
		return nil
	}
	outSamples := inSamples * 3 / 2
	out := make([]byte, outSamples*2)
	read := func(i int) float64 {
		if i < 0 { i = 0 }
		if i >= inSamples { i = inSamples - 1 }
		return float64(int16(binary.LittleEndian.Uint16(pcm[i*2:])))
	}
	for i := 0; i < outSamples; i++ {
		pos := float64(i) * 2.0 / 3.0
		idx := int(pos)
		frac := pos - float64(idx)
		v := read(idx)*(1-frac) + read(idx+1)*frac
		if v > 32767 { v = 32767 }
		if v < -32768 { v = -32768 }
		binary.LittleEndian.PutUint16(out[i*2:], uint16(int16(math.Round(v))))
	}
	return out
}

// sendVoicePCM16k 处理一次语音发送：校验/解码 16k PCM → 编码 Tencent SILK →
// 调现有 triggerUploadVoice（Hook 未支持时直接返回 voice_send_unsupported）。
// 返回 duration_ms（由 SILK 帧计算，忽略 TTS 采样数）。
func sendVoicePCM16k(userID, groupID, pcm16kBase64 string, durationHintMs int) (int, error) {
	targetID := strings.TrimSpace(groupID)
	if targetID == "" {
		targetID = strings.TrimSpace(userID)
	}
	if targetID == "" {
		return 0, errVoiceTargetMissing
	}

	pcm, err := decodeVoicePCM16kBase64(pcm16kBase64)
	if err != nil {
		return 0, err
	}

	// 默认不尝试上传：Hook 未支持时返回固定 code，App 据此降级文字。
	if !voiceSendEnabled() {
		Debug("语音发送未启用", "reason", voiceSendUnsupportedCode,
			"pcm_bytes", len(pcm), "duration_hint_ms", durationHintMs)
		return 0, errVoiceSendDisabled
	}

	silkData, _, err := encodeVoicePCM16kToWeChatSilk(pcm)
	if err != nil {
		return 0, err
	}
	return sendVoiceSilk(targetID, silkData)
}

// sendVoiceSilk 把已编码的 Tencent SILK 上传并触发 R3 发送（入站/调试可直接复用）。
func sendVoiceSilk(targetID string, silkData []byte) (int, error) {
	durationMs := voiceSilkDurationMs(silkData)
	if durationMs <= 0 {
		return 0, errVoiceEncodeFailed
	}
	mediaRoot, err := resolvedVoiceMediaDir()
	if err != nil {
		return 0, err
	}
	tempDir, err := prepareVoiceTempDir(mediaRoot)
	if err != nil {
		return 0, err
	}
	voicePath := filepath.Join(tempDir, "voice-upload-"+randomHex(8)+".silk")
	if err := ensureWithinRoot(mediaRoot, voicePath); err != nil {
		return 0, err
	}
	if err := os.WriteFile(voicePath, silkData, 0o600); err != nil {
		return 0, fmt.Errorf("%w: %v", voiceFileSaveFailed, err)
	}
	defer func() { _ = os.Remove(voicePath) }()

	// R3 语音发送需要先过登录稳定门禁（默认 60s）并具备文本/语音句柄；
	// 未就绪时直接返回可判定错误并带剩余时间，避免上传后静默失败。
	var sendResult chan error
	if r3SendMode.Load() && fridaScript != nil {
		if raw, err := voiceDiagQuery(); err == nil {
			var diag struct {
				VoiceSend         bool  `json:"voiceSend"`
				VoiceSeed         bool  `json:"voiceSeed"`
				VoiceHeader       bool  `json:"voiceHeader"`
				LoginSettled      bool  `json:"loginSettled"`
				WarmupRemainingMS int64 `json:"warmupRemainingMs"`
			}
			if json.Unmarshal([]byte(raw), &diag) == nil {
				if !diag.LoginSettled {
					remaining := diag.WarmupRemainingMS
					if remaining <= 0 {
						remaining = 60000
					}
					return 0, &voiceWarmupError{RemainingMS: remaining}
				}
				if !diag.VoiceSend || !diag.VoiceSeed || !diag.VoiceHeader {
					Debug("语音发送句柄未就绪", "voice_send", diag.VoiceSend, "voice_seed", diag.VoiceSeed, "voice_header", diag.VoiceHeader)
					return 0, errVoiceHandleMissing
				}
			}
		}
		sendResult = make(chan error, 1)
		pendingResultMap.Store(targetID, sendResult)
		defer pendingResultMap.Delete(targetID)
	}

	// 4.2 真实语音上传文件 ID：alita_1_<md5>_15_0_<seq>（真机抓包 2026-10-26）。
	sum := md5.Sum(silkData)
	voiceFileID := fmt.Sprintf("alita_1_%x_15_0_%03d", sum, time.Now().UnixNano()%1000)
	result, err := triggerVoiceUpload(targetID, voicePath,
		BuildVoiceUploadPayload(), hex.EncodeToString(silkData), durationMs, voiceFileID)
	if err != nil {
		return 0, err
	}
	if strings.TrimSpace(result) != "0" {
		return 0, errVoiceUploadRejected
	}
	Info("语音上传任务已提交", "silk_bytes", len(silkData), "duration_ms", durationMs)
	if sendResult != nil {
		select {
		case err := <-sendResult:
			if err != nil {
				return 0, fmt.Errorf("voice send failed: %w", err)
			}
			Info("语音发送任务已完成", "duration_ms", durationMs)
		case <-time.After(25 * time.Second):
			Warn("语音发送结果等待超时（按已提交处理）", "duration_ms", durationMs)
		}
	}
	return int(durationMs), nil
}

// sendVoiceRequest 是 POST /send_voice（/send_private_msg voice 段的别名端点）请求体。
type sendVoiceRequest struct {
	UserID     string `json:"user_id"`
	GroupID    string `json:"group_id"`
	PCM16K     string `json:"pcm16k"`
	DurationMs int    `json:"duration_ms"`
}

// sendVoiceHandler 是 POST /send_voice：与 /send_private_msg 的 voice 段共用
// sendVoicePCM16k 契约。默认返回 voice_send_unsupported（HTTP 200 + ok:false）。
func sendVoiceHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeVoiceJSON(w, http.StatusMethodNotAllowed, map[string]any{
			"ok":    false,
			"error": "仅支持 POST",
		})
		Error("语音发送仅支持 POST")
		return
	}

	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if config.OnebotToken == "" || token == "" || !hmac.Equal([]byte(token), []byte(config.OnebotToken)) {
		writeVoiceJSON(w, http.StatusUnauthorized, map[string]any{
			"ok":    false,
			"error": "未授权",
		})
		Error("语音发送未授权")
		return
	}

	var req sendVoiceRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeVoiceJSON(w, http.StatusBadRequest, map[string]any{
			"ok":    false,
			"error": "无效的 JSON",
		})
		Error("语音发送请求 JSON 无效")
		return
	}
	req.UserID = strings.TrimSpace(req.UserID)
	req.GroupID = strings.TrimSpace(req.GroupID)
	req.PCM16K = strings.TrimSpace(req.PCM16K)
	if req.UserID == "" && req.GroupID == "" {
		writeVoiceJSON(w, http.StatusBadRequest, map[string]any{
			"ok":    false,
			"error": "参数缺失",
		})
		Error("语音发送请求目标缺失")
		return
	}
	if req.PCM16K == "" {
		writeVoiceJSON(w, http.StatusBadRequest, map[string]any{
			"ok":    false,
			"error": "参数缺失",
		})
		Error("语音发送请求缺少 pcm16k")
		return
	}

	durationMs, err := sendVoicePCM16k(req.UserID, req.GroupID, req.PCM16K, req.DurationMs)
	if err != nil {
		var warm *voiceWarmupError
		if errors.As(err, &warm) {
			writeVoiceJSON(w, http.StatusOK, map[string]any{
				"ok":             false,
				"error":          "voice_warming_up",
				"retry_after_ms": warm.RemainingMS,
			})
			return
		}
		writeVoiceJSON(w, http.StatusOK, map[string]any{
			"ok":    false,
			"error": voiceSendErrorCode(err),
		})
		return
	}
	writeVoiceJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"duration_ms": durationMs,
	})
}

// voiceStatusHandler 是 GET/POST /voice_status：返回 R3 语音发送的运行时状态
// （登录稳定门禁剩余时间、文本/语音句柄、CdnManager）。只读，不含地址/密钥。
func voiceStatusHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		writeVoiceJSON(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "仅支持 GET/POST"})
		return
	}
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if config.OnebotToken == "" || token == "" || !hmac.Equal([]byte(token), []byte(config.OnebotToken)) {
		writeVoiceJSON(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "未授权"})
		return
	}
	raw, err := voiceDiagQuery()
	if err != nil {
		writeVoiceJSON(w, http.StatusOK, map[string]any{
			"ok":         false,
			"error":      err.Error(),
			"configured": voiceSendEnabled(),
		})
		return
	}
	var hook map[string]any
	if err := json.Unmarshal([]byte(raw), &hook); err != nil {
		writeVoiceJSON(w, http.StatusOK, map[string]any{
			"ok":         false,
			"error":      "语音诊断返回无法解析",
			"configured": voiceSendEnabled(),
		})
		return
	}
	writeVoiceJSON(w, http.StatusOK, map[string]any{
		"ok":         true,
		"configured": voiceSendEnabled(),
		"hook":       hook,
	})
}

// voiceSendErrorCode 把发送错误映射成 App 可判定的错误串：
// Hook 未支持时固定 voice_send_unsupported，其它错误用可读中文。
func voiceSendErrorCode(err error) string {
	if err == nil {
		return ""
	}
	if errors.Is(err, errVoiceSendDisabled) {
		return voiceSendUnsupportedCode
	}
	if errors.Is(err, errVoiceHandleMissing) {
		return "voice_handle_missing"
	}
	return err.Error()
}
