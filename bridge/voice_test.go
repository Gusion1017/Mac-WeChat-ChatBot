package main

// 本文件由 ChatBot 项目新增（2026-10-26）：语音能力（voice.go）的单元测试。
// 覆盖 docs/voice.md §2.1 / §2.2 / §3.3 的 bridge 契约：
//   - <voicemsg> XML 解析（缺字段、非法 aeskey、非法长度）；
//   - 入站事件段替换与 pending job 登记；
//   - AES-ECB 解密 + 长度截断（合成数据）；
//   - WAV 头（16k / 单声道 / 16-bit）；
//   - SILK 解码（bridge/testdata/voice_sample.silk：TTS 合成 5.2s / 16k / Tencent 头）；
//   - /fetch_voice handler 鉴权、参数、未知 id、幂等、失败为 HTTP 200；
//   - /send_voice 与 /send_private_msg voice 段的发送契约（默认 voice_send_unsupported）；
//   - 日志不出现 aeskey / CDN key / 音频。
//
// 隐私红线：所有测试数据均为合成值或 TTS 合成样本，不含真实 wxid / 群 ID /
// 聊天原文 / 真实 aeskey / 真实 CDN key。

import (
	"bytes"
	"crypto/aes"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

const (
	// 合成密钥 / CDN key：全部为自造十六进制/字符串，与真实数据无关。
	testVoiceAESKeyHex      = "00112233445566778899aabbccddeeff"
	testVoiceWrongAESKeyHex = "ffeeddccbbaa99887766554433221100"
	testVoiceCDNKey         = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	testVoiceDurationMs     = 5200
	// testVoiceSampleSilk 是 testdata/voice_sample.silk：5.2s、16k、Tencent SILK 头。
	testVoiceSampleSilk = "testdata/voice_sample.silk"
)

// readVoiceSample 读取 TTS 合成的 SILK 样本（不是真人聊天音频）。
func readVoiceSample(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile(testVoiceSampleSilk)
	if err != nil {
		t.Fatalf("读取 SILK 样本失败: %v", err)
	}
	if !isVoiceSilkMagic(data) {
		t.Fatalf("样本不是 SILK: % x", data[:minIntForTest(len(data), 10)])
	}
	return data
}

func minIntForTest(a, b int) int {
	if a < b {
		return a
	}
	return b
}

// setupVoiceTestEnv 隔离语音测试用到的全局状态与预算，并在 t.Cleanup 中还原。
func setupVoiceTestEnv(t *testing.T) string {
	t.Helper()

	root := t.TempDir()

	oldConfigMediaDir := config.MediaDir
	oldMediaDir := mediaDir
	oldTriggerDownload := triggerIncomingVoiceDownload
	oldTriggerUpload := triggerVoiceUpload
	oldSelfID := myWechatId
	oldNaturalGrace := voiceNaturalGraceWindow
	oldCandidateBudget := voiceCandidateBudget

	// 下载代次是 media.go 之外的全局状态（msg.go），一并隔离。
	oldDownloadSeq := atomic.SwapInt64(&downloadSeq, 0)
	latestDownload.mu.Lock()
	oldLatestSeq, oldLatestKey := latestDownload.seq, latestDownload.key
	latestDownload.seq, latestDownload.key = 0, ""
	latestDownload.mu.Unlock()

	config.MediaDir = root
	mediaDir = ""
	clearSyncMap(&pendingVoiceJobs)
	clearSyncMap(&completedVoiceFetches)
	clearSyncMap(&userID2FileMsgMap)
	myWechatId = "wxid_test"
	// 单测用很短的时间预算，避免真实 8s/25s 预算拖慢测试。
	voiceNaturalGraceWindow = 20 * time.Millisecond
	voiceCandidateBudget = 250 * time.Millisecond
	// 默认关闭语音发送（Hook 未支持），并清掉下载 fileType 覆盖。
	withVoiceEnv(t, envVoiceSend, "")
	withVoiceEnv(t, envVoiceFileType, "")

	t.Cleanup(func() {
		config.MediaDir = oldConfigMediaDir
		mediaDir = oldMediaDir
		clearSyncMap(&pendingVoiceJobs)
		clearSyncMap(&completedVoiceFetches)
		clearSyncMap(&userID2FileMsgMap)
		triggerIncomingVoiceDownload = oldTriggerDownload
		triggerVoiceUpload = oldTriggerUpload
		myWechatId = oldSelfID
		voiceNaturalGraceWindow = oldNaturalGrace
		voiceCandidateBudget = oldCandidateBudget
		atomic.StoreInt64(&downloadSeq, oldDownloadSeq)
		latestDownload.mu.Lock()
		latestDownload.seq, latestDownload.key = oldLatestSeq, oldLatestKey
		latestDownload.mu.Unlock()
	})

	return root
}

// withVoiceEnv 设置/清空环境变量并在测试结束后还原。
func withVoiceEnv(t *testing.T, key, value string) {
	t.Helper()
	old, had := os.LookupEnv(key)
	if value == "" {
		_ = os.Unsetenv(key)
	} else {
		_ = os.Setenv(key, value)
	}
	t.Cleanup(func() {
		if had {
			_ = os.Setenv(key, old)
		} else {
			_ = os.Unsetenv(key)
		}
	})
}

// buildTestVoiceXML 生成与 4.2 `<msg><voicemsg …/></msg>` 同结构的合成 XML。
func buildTestVoiceXML(cdnKey, aesKey string, durationMs, cipherLen int) string {
	attributes := []string{
		`endflag="1"`, `cancelflag="0"`, `forwardflag="0"`, `voiceformat="4"`,
		fmt.Sprintf(`voicelength="%d"`, durationMs),
		fmt.Sprintf(`length="%d"`, cipherLen),
	}
	if cdnKey != "" {
		attributes = append(attributes, fmt.Sprintf(`voiceurl="%s"`, cdnKey))
	}
	if aesKey != "" {
		attributes = append(attributes, fmt.Sprintf(`aeskey="%s"`, aesKey))
	}
	return "<msg><voicemsg " + strings.Join(attributes, " ") + " /></msg>"
}

// testVoicePayload 构造一条与 hook 上报结构一致的入站语音事件。
func testVoicePayload(messageID string) map[string]interface{} {
	return map[string]interface{}{
		"msg_type":    float64(34),
		"message_id":  messageID,
		"raw_message": buildTestVoiceXML(testVoiceCDNKey, testVoiceAESKeyHex, testVoiceDurationMs, 0),
		"message": []interface{}{
			map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "[语音]"}},
			map[string]interface{}{"type": "at", "data": map[string]interface{}{"qq": "wxid_test"}},
		},
	}
}

// encryptVoiceECB 用测试内 AES-ECB 加密（末尾补 0 到整块），模拟微信 CDN 密文。
func encryptVoiceECB(t *testing.T, plain []byte, keyHex string) []byte {
	t.Helper()
	key, err := hex.DecodeString(keyHex)
	if err != nil {
		t.Fatalf("测试密钥解码失败: %v", err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatalf("构造 AES cipher 失败: %v", err)
	}
	padded := make([]byte, (len(plain)+aes.BlockSize-1)/aes.BlockSize*aes.BlockSize)
	copy(padded, plain)
	cipherData := make([]byte, len(padded))
	for offset := 0; offset < len(padded); offset += aes.BlockSize {
		block.Encrypt(cipherData[offset:offset+aes.BlockSize], padded[offset:offset+aes.BlockSize])
	}
	return cipherData
}

// stubVoiceDownload 让注入的下载触发器把一份「已稳定」的伪造密文塞进下载缓存。
// 返回触发次数计数，便于断言幂等请求不会重复触发下载。
func stubVoiceDownload(t *testing.T, silkPlain []byte) *int32 {
	t.Helper()
	var calls int32
	triggerIncomingVoiceDownload = func(job *incomingVoiceJob, fileType int, tempPath string) (string, error) {
		atomic.AddInt32(&calls, 1)
		cipherData := encryptVoiceECB(t, silkPlain, job.AESKey)
		userID2FileMsgMap.Store(job.CDNKey, &DownloadRequest{
			CDNURL:         job.CDNKey,
			Media:          cipherData,
			LastAppendTime: time.Now().Add(-2 * time.Second).UnixMilli(),
		})
		return "1", nil
	}
	return &calls
}

// ---------------------------------------------------------------------------
// 1. parseIncomingVoiceXML
// ---------------------------------------------------------------------------

func TestParseIncomingVoiceXML(t *testing.T) {
	t.Run("完整字段", func(t *testing.T) {
		raw := buildTestVoiceXML(testVoiceCDNKey, testVoiceAESKeyHex, testVoiceDurationMs, 9936)
		job, err := parseIncomingVoiceXML(raw)
		if err != nil {
			t.Fatalf("解析失败: %v", err)
		}
		if job.CDNKey != testVoiceCDNKey {
			t.Fatal("CDN key 解析错误")
		}
		if job.AESKey != testVoiceAESKeyHex {
			t.Fatal("aeskey 解析错误")
		}
		if job.DurationMs != testVoiceDurationMs || job.Format != 4 || job.CipherLen != 9936 {
			t.Fatalf("字段解析错误: %#v", job)
		}
	})

	t.Run("缺字段/非法字段", func(t *testing.T) {
		cases := []struct {
			name string
			raw  string
		}{
			{"空 XML", ""},
			{"坏 XML", `<msg><voicemsg aeskey="`},
			{"缺少 voicemsg", `<msg><img /></msg>`},
			{"缺少下载地址", buildTestVoiceXML("", testVoiceAESKeyHex, 1000, 0)},
			{"缺少 aeskey", buildTestVoiceXML(testVoiceCDNKey, "", 1000, 0)},
			{"非法 aeskey", buildTestVoiceXML(testVoiceCDNKey, "not-a-valid-aes-key", 1000, 0)},
		}
		for _, tc := range cases {
			t.Run(tc.name, func(t *testing.T) {
				if _, err := parseIncomingVoiceXML(tc.raw); err == nil {
					t.Fatal("应返回解析错误")
				}
			})
		}
	})

	t.Run("非法长度被收敛为未知", func(t *testing.T) {
		raw := `<msg><voicemsg voiceurl="` + testVoiceCDNKey +
			`" aeskey="` + testVoiceAESKeyHex +
			`" voicelength="-1" length="-99" voiceformat="-3" /></msg>`
		job, err := parseIncomingVoiceXML(raw)
		if err != nil {
			t.Fatalf("解析失败: %v", err)
		}
		if job.DurationMs != 0 || job.CipherLen != 0 || job.Format != 0 {
			t.Fatalf("非法长度未收敛: %#v", job)
		}
	})

	t.Run("权限错误不含密钥/Xml", func(t *testing.T) {
		_, err := parseIncomingVoiceXML(`<msg><voicemsg voiceurl="` + testVoiceCDNKey + `" aeskey="`)
		if err == nil {
			t.Fatal("坏 XML 应返回错误")
		}
		if strings.Contains(err.Error(), testVoiceCDNKey) || strings.Contains(err.Error(), "voicemsg") {
			t.Fatalf("错误文案泄露 XML 内容: %q", err.Error())
		}
	})
}

// ---------------------------------------------------------------------------
// 2. registerIncomingVoice（事件段替换 + pending job 登记）
// ---------------------------------------------------------------------------

func TestRegisterIncomingVoice(t *testing.T) {
	t.Run("替换 [语音] 并登记 job", func(t *testing.T) {
		setupVoiceTestEnv(t)
		payload := testVoicePayload("340001")

		registerIncomingVoice(payload)

		message, ok := payload["message"].([]interface{})
		if !ok {
			t.Fatalf("message 类型错误: %T", payload["message"])
		}
		if len(message) != 2 {
			t.Fatalf("message 段数 = %d, want 2: %#v", len(message), message)
		}
		first, ok := message[0].(map[string]interface{})
		if !ok || first["type"] != "voice" {
			t.Fatalf("首段应为 voice: %#v", message[0])
		}
		data, ok := first["data"].(map[string]interface{})
		if !ok {
			t.Fatalf("voice 段 data 类型错误: %#v", first["data"])
		}
		if data["duration_ms"] != testVoiceDurationMs {
			t.Fatalf("duration_ms = %v, want %d", data["duration_ms"], testVoiceDurationMs)
		}
		if _, exists := data["file"]; exists {
			t.Fatal("voice 段不应携带 file 字段（下载走 /fetch_voice）")
		}
		if message[1].(map[string]interface{})["type"] != "at" {
			t.Fatalf("at 段应原样保留: %#v", message[1])
		}

		value, ok := pendingVoiceJobs.Load("340001")
		if !ok {
			t.Fatal("语音事件未登记下载任务")
		}
		job := value.(*incomingVoiceJob)
		if job.CDNKey != testVoiceCDNKey || job.DurationMs != testVoiceDurationMs {
			t.Fatalf("登记内容错误: %#v", job)
		}
		if payload["raw_message"] != buildTestVoiceXML(testVoiceCDNKey, testVoiceAESKeyHex, testVoiceDurationMs, 0) {
			t.Fatal("raw_message 应保持原样")
		}
	})

	t.Run("非语音事件不改动", func(t *testing.T) {
		setupVoiceTestEnv(t)
		payload := map[string]interface{}{
			"msg_type":    float64(1),
			"message_id":  "340002",
			"raw_message": "你好",
			"message": []interface{}{
				map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "你好"}},
			},
		}
		registerIncomingVoice(payload)
		if _, ok := pendingVoiceJobs.Load("340002"); ok {
			t.Fatal("非语音事件不应登记")
		}
		if message := payload["message"].([]interface{}); len(message) != 1 {
			t.Fatalf("非语音事件被改写: %#v", message)
		}
	})

	t.Run("appmsg 49 含 voicemsg 文本不改动", func(t *testing.T) {
		setupVoiceTestEnv(t)
		payload := map[string]interface{}{
			"msg_type":    float64(49),
			"message_id":  "490001",
			"raw_message": `<msg><appmsg><title>&lt;voicemsg/&gt;</title></appmsg></msg>`,
			"message": []interface{}{
				map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "[链接/文件]"}},
			},
		}
		registerIncomingVoice(payload)
		if _, ok := pendingVoiceJobs.Load("490001"); ok {
			t.Fatal("非语音 msg_type 不应登记")
		}
		if message := payload["message"].([]interface{}); message[0].(map[string]interface{})["type"] != "text" {
			t.Fatalf("非语音事件段被改写: %#v", message)
		}
	})

	t.Run("message 是字符串时整体替换", func(t *testing.T) {
		setupVoiceTestEnv(t)
		payload := testVoicePayload("340003")
		payload["message"] = "[语音]"

		registerIncomingVoice(payload)

		message, ok := payload["message"].([]interface{})
		if !ok || len(message) != 1 || message[0].(map[string]interface{})["type"] != "voice" {
			t.Fatalf("字符串 message 未替换: %#v", payload["message"])
		}
	})

	t.Run("缺 message_id 仍替换但不登记", func(t *testing.T) {
		setupVoiceTestEnv(t)
		payload := testVoicePayload("")
		delete(payload, "message_id")

		registerIncomingVoice(payload)

		if countPendingVoiceJobs() != 0 {
			t.Fatal("缺 message_id 不应登记")
		}
		if _, ok := payload["message"].([]interface{}); !ok {
			t.Fatal("缺 message_id 时仍应替换 message")
		}
	})

	t.Run("XML 解析失败仍替换为无时长 voice 段", func(t *testing.T) {
		setupVoiceTestEnv(t)
		payload := map[string]interface{}{
			"msg_type":    float64(34),
			"message_id":  "340004",
			"raw_message": "not-xml",
			"message": []interface{}{
				map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "[语音]"}},
			},
		}
		registerIncomingVoice(payload)
		if countPendingVoiceJobs() != 0 {
			t.Fatal("解析失败不应登记")
		}
		message := payload["message"].([]interface{})
		data := message[0].(map[string]interface{})["data"].(map[string]interface{})
		if _, ok := data["duration_ms"]; ok {
			t.Fatalf("未知时长时不应带 duration_ms: %#v", data)
		}
	})

	t.Run("旧 bridge 无 msg_type 但 raw 含 voicemsg 也登记", func(t *testing.T) {
		setupVoiceTestEnv(t)
		payload := map[string]interface{}{
			"message_id":  "340005",
			"raw_message": buildTestVoiceXML(testVoiceCDNKey, testVoiceAESKeyHex, testVoiceDurationMs, 0),
			"message": []interface{}{
				map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "[语音]"}},
			},
		}
		registerIncomingVoice(payload)
		if _, ok := pendingVoiceJobs.Load("340005"); !ok {
			t.Fatal("旧事件应登记语音任务")
		}
	})

	t.Run("msg_type 多种数值形式可识别", func(t *testing.T) {
		numericTypes := map[string]interface{}{
			"float64":     float64(34),
			"json.Number": json.Number("34"),
			"string":      "34",
			"int":         34,
		}
		for name, value := range numericTypes {
			setupVoiceTestEnv(t)
			event := map[string]interface{}{
				"msg_type":    value,
				"message_id":  "34-" + name,
				"raw_message": buildTestVoiceXML(testVoiceCDNKey, testVoiceAESKeyHex, 1000, 0),
			}
			registerIncomingVoice(event)
			if _, ok := pendingVoiceJobs.Load("34-" + name); !ok {
				t.Fatalf("msg_type 为 %s 的语音事件未登记", name)
			}
		}
	})
}

func countPendingVoiceJobs() int {
	count := 0
	pendingVoiceJobs.Range(func(_, _ interface{}) bool {
		count++
		return true
	})
	return count
}

// ---------------------------------------------------------------------------
// 3. AES-ECB 解密 / 长度截断
// ---------------------------------------------------------------------------

func TestDecryptVoiceBytes(t *testing.T) {
	sample := readVoiceSample(t)
	cipherData := encryptVoiceECB(t, sample, testVoiceAESKeyHex)

	t.Run("AES-ECB 密文解密", func(t *testing.T) {
		got, err := decryptVoiceBytes(cipherData, testVoiceAESKeyHex, 0)
		if err != nil {
			t.Fatalf("解密失败: %v", err)
		}
		if !bytes.Equal(got, sample) {
			t.Fatalf("解密结果与明文不一致: got %d bytes want %d", len(got), len(sample))
		}
	})

	t.Run("SILK 明文直通", func(t *testing.T) {
		got, err := decryptVoiceBytes(sample, "", 0)
		if err != nil {
			t.Fatalf("明文直通失败: %v", err)
		}
		if !bytes.Equal(got, sample) {
			t.Fatal("明文直通内容被改写")
		}
	})

	t.Run("按整块 length 截断密文", func(t *testing.T) {
		const cipherLen = 1600 // 16 的整数倍
		got, err := decryptVoiceBytes(cipherData, testVoiceAESKeyHex, cipherLen)
		if err != nil {
			t.Fatalf("解密失败: %v", err)
		}
		expected, ok := trimSilkToFrames(sample[:cipherLen])
		if !ok {
			t.Fatal("测试样本前 1600 字节应包含完整帧")
		}
		if !bytes.Equal(got, expected) {
			t.Fatalf("截断结果错误: got %d bytes want %d", len(got), len(expected))
		}
	})

	t.Run("错误 key 失败", func(t *testing.T) {
		// 用错误 key 加密的密文，按正确 key 解密后不是 SILK。
		wrongCipher := encryptVoiceECB(t, []byte("not a silk stream at all"), testVoiceWrongAESKeyHex)
		if _, err := decryptVoiceBytes(wrongCipher, testVoiceAESKeyHex, 0); err == nil {
			t.Fatal("错误 key 应解密失败")
		}
	})

	t.Run("缺失/非法 key 失败", func(t *testing.T) {
		if _, err := decryptVoiceBytes(cipherData, "", 0); err == nil {
			t.Fatal("缺 key 应失败")
		}
		if _, err := decryptVoiceBytes(cipherData, "short-key", 0); err == nil {
			t.Fatal("非法 key 应失败")
		}
	})

	t.Run("空数据/坏魔数失败", func(t *testing.T) {
		if _, err := decryptVoiceBytes(nil, testVoiceAESKeyHex, 0); err == nil {
			t.Fatal("空数据应失败")
		}
		random := make([]byte, 64)
		for i := range random {
			random[i] = byte(i * 7)
		}
		cipherRandom := encryptVoiceECB(t, random, testVoiceAESKeyHex)
		if _, err := decryptVoiceBytes(cipherRandom, testVoiceAESKeyHex, 0); err == nil {
			t.Fatal("非 SILK 数据应失败")
		}
	})
}

// ---------------------------------------------------------------------------
// 4. SILK 解码 / 编码 / 帧与时长
// ---------------------------------------------------------------------------

func TestDecodeVoiceSilkSample(t *testing.T) {
	sample := readVoiceSample(t)

	trimmed, ok := trimSilkToFrames(sample)
	if !ok || len(trimmed) != len(sample) {
		t.Fatalf("完整样本不应被裁剪: ok=%v trimmed=%d sample=%d", ok, len(trimmed), len(sample))
	}

	frames, ok := countSilkFrames(sample)
	if !ok || frames != 260 {
		t.Fatalf("帧数 = %d (ok=%v), want 260", frames, ok)
	}

	pcm, err := decodeVoiceSilkPCM(sample)
	if err != nil {
		t.Fatalf("解码失败: %v", err)
	}
	if len(pcm) != 166400 {
		t.Fatalf("PCM 长度 = %d, want 166400（5.2s × 16000 × 2）", len(pcm))
	}
	if got := voicePCMDurationMs(pcm); got != 5200 {
		t.Fatalf("时长 = %dms, want 5200ms", got)
	}
	if got := voiceSilkDurationMs(sample); got != 5200 {
		t.Fatalf("SILK 帧时长 = %dms, want 5200ms", got)
	}
}

func TestEncodeVoicePCM16kToTencentSilk(t *testing.T) {
	pcm := syntheticVoicePCM(16000) // 1s

	silkData, durationMs, err := encodeVoicePCM16kToTencentSilk(pcm)
	if err != nil {
		t.Fatalf("编码失败: %v", err)
	}
	if !isVoiceSilkMagic(silkData) {
		t.Fatalf("编码结果不是 Tencent SILK: % x", silkData[:minIntForTest(len(silkData), 10)])
	}
	// go-silk 以 20ms 帧编码，允许 ±40ms 误差。
	if durationMs < 960 || durationMs > 1040 {
		t.Fatalf("时长 = %dms, want ≈1000ms", durationMs)
	}

	// 编解码往返：解码后的 PCM 时长应接近编码时长（不依赖 ffmpeg/pilk）。
	roundTripPCM, err := decodeVoiceSilkPCM(silkData)
	if err != nil {
		t.Fatalf("解码失败: %v", err)
	}
	if len(roundTripPCM) == 0 {
		t.Fatal("解码 PCM 为空")
	}
	if got := voicePCMDurationMs(roundTripPCM); got < 900 || got > 1100 {
		t.Fatalf("往返时长 = %dms, want ≈1000ms", got)
	}

	t.Run("非法 PCM", func(t *testing.T) {
		if _, _, err := encodeVoicePCM16kToTencentSilk(nil); err == nil {
			t.Fatal("空 PCM 应失败")
		}
		if _, _, err := encodeVoicePCM16kToTencentSilk(make([]byte, 641)); err == nil {
			t.Fatal("奇数长度 PCM 应失败")
		}
	})
}

func TestBuildVoiceWAV(t *testing.T) {
	pcm := syntheticVoicePCM(1600) // 100ms
	wav, err := buildVoiceWAV(pcm)
	if err != nil {
		t.Fatalf("生成 WAV 失败: %v", err)
	}
	if len(wav) != voiceWAVHeaderSize+len(pcm) {
		t.Fatalf("WAV 长度 = %d, want %d", len(wav), voiceWAVHeaderSize+len(pcm))
	}
	if string(wav[0:4]) != "RIFF" || string(wav[8:12]) != "WAVE" || string(wav[12:16]) != "fmt " || string(wav[36:40]) != "data" {
		t.Fatalf("WAV 头标记错误: % x", wav[:44])
	}
	if got := binary.LittleEndian.Uint32(wav[4:8]); got != uint32(36+len(pcm)) {
		t.Fatalf("RIFF size = %d, want %d", got, 36+len(pcm))
	}
	if got := binary.LittleEndian.Uint16(wav[20:22]); got != 1 {
		t.Fatalf("audioFormat = %d, want 1 (PCM)", got)
	}
	if got := binary.LittleEndian.Uint16(wav[22:24]); got != 1 {
		t.Fatalf("channels = %d, want 1", got)
	}
	if got := binary.LittleEndian.Uint32(wav[24:28]); got != 16000 {
		t.Fatalf("sampleRate = %d, want 16000", got)
	}
	if got := binary.LittleEndian.Uint32(wav[28:32]); got != 32000 {
		t.Fatalf("byteRate = %d, want 32000", got)
	}
	if got := binary.LittleEndian.Uint16(wav[34:36]); got != 16 {
		t.Fatalf("bitsPerSample = %d, want 16", got)
	}
	if got := binary.LittleEndian.Uint32(wav[40:44]); got != uint32(len(pcm)) {
		t.Fatalf("data size = %d, want %d", got, len(pcm))
	}
	if !bytes.Equal(wav[voiceWAVHeaderSize:], pcm) {
		t.Fatal("WAV 数据段与 PCM 不一致")
	}
	if got := voicePCMDurationMs(wav[voiceWAVHeaderSize:]); got != 100 {
		t.Fatalf("WAV 时长 = %dms, want 100ms", got)
	}
	if _, err := buildVoiceWAV(nil); err == nil {
		t.Fatal("空 PCM 应失败")
	}
}

// syntheticVoicePCM 生成 16k 单声道 s16le 的确定性合成 PCM（非真人音频）。
func syntheticVoicePCM(samples int) []byte {
	pcm := make([]byte, samples*2)
	for i := 0; i < samples; i++ {
		value := int16((i*37)%2000 - 1000)
		binary.LittleEndian.PutUint16(pcm[i*2:], uint16(value))
	}
	return pcm
}

// ---------------------------------------------------------------------------
// 5. fetchIncomingVoice（下载/解密/解码/幂等）
// ---------------------------------------------------------------------------

func TestFetchIncomingVoice(t *testing.T) {
	root := setupVoiceTestEnv(t)
	sample := readVoiceSample(t)
	cipherLen := len(encryptVoiceECB(t, sample, testVoiceAESKeyHex))
	payload := testVoicePayload("350001")
	payload["raw_message"] = buildTestVoiceXML(testVoiceCDNKey, testVoiceAESKeyHex, testVoiceDurationMs, cipherLen)
	registerIncomingVoice(payload)
	calls := stubVoiceDownload(t, sample)

	result, err := fetchIncomingVoice("350001")
	if err != nil {
		t.Fatalf("获取语音失败: %v", err)
	}
	if !filepath.IsAbs(result.Path) || !filepath.IsAbs(result.SilkPath) {
		t.Fatalf("返回路径不是绝对路径: %#v", result)
	}
	for _, path := range []string{result.Path, result.SilkPath} {
		rel, err := filepath.Rel(root, path)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			t.Fatalf("返回路径不在 mediaDir 内: %q (rel=%q)", path, rel)
		}
		if filepath.Base(filepath.Dir(path)) != time.Now().Format("2006-01-02") {
			t.Fatalf("语音未按日期目录保存: %q", path)
		}
	}
	if want := "voice_350001.silk"; filepath.Base(result.SilkPath) != want {
		t.Fatalf("SILK 文件名 = %q, want %q", filepath.Base(result.SilkPath), want)
	}
	if want := "voice_350001_16k.wav"; filepath.Base(result.Path) != want {
		t.Fatalf("WAV 文件名 = %q, want %q", filepath.Base(result.Path), want)
	}
	if result.DurationMs != testVoiceDurationMs {
		t.Fatalf("duration_ms = %d, want %d", result.DurationMs, testVoiceDurationMs)
	}

	silkContent, err := os.ReadFile(result.SilkPath)
	if err != nil {
		t.Fatalf("读取 SILK 文件失败: %v", err)
	}
	if !bytes.Equal(silkContent, sample) {
		t.Fatalf("落盘 SILK 与样本不一致: got %d bytes", len(silkContent))
	}
	wavContent, err := os.ReadFile(result.Path)
	if err != nil {
		t.Fatalf("读取 WAV 文件失败: %v", err)
	}
	if len(wavContent) != voiceWAVHeaderSize+166400 {
		t.Fatalf("WAV 文件长度 = %d, want %d", len(wavContent), voiceWAVHeaderSize+166400)
	}
	if got := binary.LittleEndian.Uint32(wavContent[24:28]); got != 16000 {
		t.Fatalf("落盘 WAV 采样率 = %d, want 16000", got)
	}

	// 幂等：重复请求复用同一结果，不重复触发下载。
	triggerCount := atomic.LoadInt32(calls)
	second, err := fetchIncomingVoice("350001")
	if err != nil {
		t.Fatalf("二次获取语音失败: %v", err)
	}
	if second != result {
		t.Fatalf("幂等结果不一致: first=%#v second=%#v", result, second)
	}
	if got := atomic.LoadInt32(calls); got != triggerCount {
		t.Fatalf("幂等请求重复触发下载: %d → %d", triggerCount, got)
	}
}

func TestFetchIncomingVoiceNaturalChunksWhenTriggerRejected(t *testing.T) {
	setupVoiceTestEnv(t)
	sample := readVoiceSample(t)
	cipherData := encryptVoiceECB(t, sample, testVoiceAESKeyHex)
	payload := testVoicePayload("350002")
	payload["raw_message"] = buildTestVoiceXML(testVoiceCDNKey, testVoiceAESKeyHex, testVoiceDurationMs, len(cipherData))
	registerIncomingVoice(payload)

	triggerIncomingVoiceDownload = func(job *incomingVoiceJob, fileType int, tempPath string) (string, error) {
		// 模拟「触发返回 fail，但微信自己的下载随后落到了同一 key」。
		userID2FileMsgMap.Store(job.CDNKey, &DownloadRequest{
			CDNURL:         job.CDNKey,
			Media:          cipherData,
			LastAppendTime: time.Now().Add(-2 * time.Second).UnixMilli(),
		})
		return "fail", nil
	}

	result, err := fetchIncomingVoice("350002")
	if err != nil {
		t.Fatalf("触发被拒绝但自然分片可用时应成功: %v", err)
	}
	if result.DurationMs != testVoiceDurationMs {
		t.Fatalf("duration_ms = %d, want %d", result.DurationMs, testVoiceDurationMs)
	}
}

func TestFetchIncomingVoicePartialDataRetriesMagic(t *testing.T) {
	setupVoiceTestEnv(t)
	sample := readVoiceSample(t)
	cipherData := encryptVoiceECB(t, sample, testVoiceAESKeyHex)

	// 只有一半数据 → 魔数/完整性不通过 → 继续等分片；第二次增长为完整数据后成功。
	half := len(cipherData) / 2
	half -= half % aes.BlockSize
	var calls int32
	triggerIncomingVoiceDownload = func(job *incomingVoiceJob, fileType int, tempPath string) (string, error) {
		atomic.AddInt32(&calls, 1)
		userID2FileMsgMap.Store(job.CDNKey, &DownloadRequest{
			CDNURL:         job.CDNKey,
			Media:          append([]byte(nil), cipherData[:half]...),
			LastAppendTime: time.Now().Add(-2 * time.Second).UnixMilli(),
		})
		go func() {
			time.Sleep(30 * time.Millisecond)
			userID2FileMsgMap.Store(job.CDNKey, &DownloadRequest{
				CDNURL:         job.CDNKey,
				Media:          append([]byte(nil), cipherData...),
				LastAppendTime: time.Now().Add(-2 * time.Second).UnixMilli(),
			})
		}()
		return "1", nil
	}

	payload := testVoicePayload("350003")
	payload["raw_message"] = buildTestVoiceXML(testVoiceCDNKey, testVoiceAESKeyHex, testVoiceDurationMs, len(cipherData))
	registerIncomingVoice(payload)

	result, err := fetchIncomingVoice("350003")
	if err != nil {
		t.Fatalf("分片增长后应成功: %v", err)
	}
	if result.DurationMs != testVoiceDurationMs {
		t.Fatalf("duration_ms = %d, want %d", result.DurationMs, testVoiceDurationMs)
	}
}

func TestFetchIncomingVoiceFailuresAndRetry(t *testing.T) {
	t.Run("未知 id", func(t *testing.T) {
		setupVoiceTestEnv(t)
		if _, err := fetchIncomingVoice("not-registered"); !errors.Is(err, errVoiceJobNotFound) {
			t.Fatalf("未知 id 应报缺失: %v", err)
		}
		if _, err := fetchIncomingVoice(""); !errors.Is(err, errVoiceJobNotFound) {
			t.Fatalf("空 id 应报缺失: %v", err)
		}
	})

	t.Run("触发被拒绝且无分片，失败后允许重试", func(t *testing.T) {
		setupVoiceTestEnv(t)
		payload := testVoicePayload("350004")
		registerIncomingVoice(payload)
		triggerIncomingVoiceDownload = func(job *incomingVoiceJob, fileType int, tempPath string) (string, error) {
			return "fail", nil
		}

		if _, err := fetchIncomingVoice("350004"); err == nil {
			t.Fatal("无分片时应失败")
		}
		if _, ok := pendingVoiceJobs.Load("350004"); !ok {
			t.Fatal("失败后应恢复登记以便 App 重试")
		}

		// 重试：本次下载可用则成功。
		sample := readVoiceSample(t)
		stubVoiceDownload(t, sample)
		if _, err := fetchIncomingVoice("350004"); err != nil {
			t.Fatalf("恢复登记后重试应成功: %v", err)
		}
	})

	t.Run("Frida 不可用", func(t *testing.T) {
		setupVoiceTestEnv(t)
		payload := testVoicePayload("350005")
		registerIncomingVoice(payload)
		triggerIncomingVoiceDownload = func(job *incomingVoiceJob, fileType int, tempPath string) (string, error) {
			return "", errVoiceBridgeUnavailable
		}
		if _, err := fetchIncomingVoice("350005"); !errors.Is(err, errVoiceBridgeUnavailable) {
			t.Fatalf("应返回 Frida 不可用: %v", err)
		}
	})
}

func TestVoiceDownloadFileTypes(t *testing.T) {
	setupVoiceTestEnv(t)

	if got := voiceDownloadFileTypes(); len(got) != 1 || got[0] != 15 {
		t.Fatalf("默认 fileType = %v, want [15]", got)
	}
	withVoiceEnv(t, envVoiceFileType, "7")
	if got := voiceDownloadFileTypes(); len(got) != 1 || got[0] != 7 {
		t.Fatalf("单值覆盖 = %v, want [7]", got)
	}
	withVoiceEnv(t, envVoiceFileType, "6")
	if got := voiceDownloadFileTypes(); len(got) != 1 || got[0] != 6 {
		t.Fatalf("单值覆盖 = %v, want [6]", got)
	}
	withVoiceEnv(t, envVoiceFileType, "5,6")
	if got := voiceDownloadFileTypes(); len(got) != 2 || got[0] != 5 || got[1] != 6 {
		t.Fatalf("列表覆盖 = %v, want [5 6]", got)
	}
	withVoiceEnv(t, envVoiceFileType, "bad-value")
	if got := voiceDownloadFileTypes(); len(got) != 1 || got[0] != 15 {
		t.Fatalf("非法覆盖应回退默认: %v", got)
	}
}

// ---------------------------------------------------------------------------
// 5.5 /voice_status handler（语音发送倒计时/句柄诊断）
// ---------------------------------------------------------------------------

func TestVoiceStatusHandler(t *testing.T) {
	const token = "7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b"
	withToken(t, token)
	withVoiceEnv(t, envVoiceSend, "1")
	old := voiceDiagQuery
	voiceDiagQuery = func() (string, error) {
		return `{"mode":"r3","voiceSend":true,"textSeed":true,"voiceSeed":true,"cdnReady":true,"loginSettled":false,"warmupRemainingMs":42000,"voiceReady":false}`, nil
	}
	t.Cleanup(func() { voiceDiagQuery = old })

	req := httptest.NewRequest(http.MethodGet, "/voice_status", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	voiceStatusHandler(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 body=%s", rec.Code, rec.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("响应不是 JSON: %v", err)
	}
	if body["ok"] != true || body["configured"] != true {
		t.Fatalf("ok/configured 不符: %v", body)
	}
	hook, _ := body["hook"].(map[string]any)
	if hook["warmupRemainingMs"] != float64(42000) || hook["voiceSeed"] != true {
		t.Fatalf("hook 诊断字段不符: %v", hook)
	}
}

// ---------------------------------------------------------------------------
// 6. /fetch_voice handler
// ---------------------------------------------------------------------------

func TestFetchVoiceHandler(t *testing.T) {
	const token = "6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a"
	withToken(t, token)

	setupVoiceTestEnv(t)
	server := httptest.NewServer(http.HandlerFunc(fetchVoiceHandler))
	t.Cleanup(server.Close)
	endpoint := server.URL + "/fetch_voice"
	auth := "Bearer " + token

	assertNoSecrets := func(t *testing.T, body string) {
		t.Helper()
		for _, secret := range []string{testVoiceAESKeyHex, testVoiceCDNKey} {
			if strings.Contains(body, secret) {
				t.Fatalf("响应体泄露 key: %q", body)
			}
		}
	}

	t.Run("未鉴权返回 401", func(t *testing.T) {
		setupVoiceTestEnv(t)
		resp := doRequest(t, http.MethodPost, endpoint, "", `{"message_id":"360001"}`)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("status = %d, want 401", resp.StatusCode)
		}
		if body := readBody(t, resp); !strings.Contains(body, "未授权") {
			t.Fatalf("body = %q, want 未授权", body)
		}
	})

	t.Run("非 POST 返回 405", func(t *testing.T) {
		setupVoiceTestEnv(t)
		resp := doRequest(t, http.MethodGet, endpoint, auth, "")
		if resp.StatusCode != http.StatusMethodNotAllowed {
			t.Fatalf("status = %d, want 405", resp.StatusCode)
		}
	})

	t.Run("坏 JSON 返回 400", func(t *testing.T) {
		setupVoiceTestEnv(t)
		resp := doRequest(t, http.MethodPost, endpoint, auth, `{not-json`)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", resp.StatusCode)
		}
	})

	t.Run("缺 message_id 返回 400", func(t *testing.T) {
		setupVoiceTestEnv(t)
		resp := doRequest(t, http.MethodPost, endpoint, auth, `{}`)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", resp.StatusCode)
		}
		if body := readBody(t, resp); !strings.Contains(body, "参数缺失") {
			t.Fatalf("body = %q, want 参数缺失", body)
		}
	})

	t.Run("未知 id 返回 HTTP 200 + ok:false", func(t *testing.T) {
		setupVoiceTestEnv(t)
		resp := doRequest(t, http.MethodPost, endpoint, auth, `{"message_id":"not-registered"}`)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
		body := readBody(t, resp)
		assertNoSecrets(t, body)
		if !strings.Contains(body, `"ok":false`) || !strings.Contains(body, "缺失或已过期") {
			t.Fatalf("body = %q", body)
		}
	})

	t.Run("成功返回 200 且幂等脱敏", func(t *testing.T) {
		setupVoiceTestEnv(t)
		// 目录名带空格，验证 file:// 的百分号转义。
		mediaRoot := filepath.Join(t.TempDir(), "voice media dir")
		if err := os.MkdirAll(mediaRoot, 0o755); err != nil {
			t.Fatalf("创建测试目录失败: %v", err)
		}
		config.MediaDir = mediaRoot

		sample := readVoiceSample(t)
		cipherLen := len(encryptVoiceECB(t, sample, testVoiceAESKeyHex))
		payload := testVoicePayload("360002")
		payload["raw_message"] = buildTestVoiceXML(testVoiceCDNKey, testVoiceAESKeyHex, testVoiceDurationMs, cipherLen)
		registerIncomingVoice(payload)
		calls := stubVoiceDownload(t, sample)

		resp := doRequest(t, http.MethodPost, endpoint, auth, `{"message_id":"360002"}`)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
		body := readBody(t, resp)
		assertNoSecrets(t, body)

		var parsed struct {
			OK         bool   `json:"ok"`
			Path       string `json:"path"`
			SilkPath   string `json:"silk_path"`
			DurationMs int    `json:"duration_ms"`
		}
		if err := json.Unmarshal([]byte(body), &parsed); err != nil {
			t.Fatalf("解析响应失败: %v (body=%q)", err, body)
		}
		if !parsed.OK || parsed.DurationMs != testVoiceDurationMs {
			t.Fatalf("响应内容错误: %#v", parsed)
		}
		for _, field := range []string{parsed.Path, parsed.SilkPath} {
			if !strings.HasPrefix(field, "file://") {
				t.Fatalf("路径字段不是 file:// URL: %q", field)
			}
			if !strings.Contains(field, "voice%20media%20dir") {
				t.Fatalf("file URL 未做百分号转义: %q", field)
			}
			fileURL, err := url.Parse(field)
			if err != nil {
				t.Fatalf("解析 file URL 失败: %v", err)
			}
			rel, err := filepath.Rel(mediaRoot, fileURL.Path)
			if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				t.Fatalf("file URL 路径不在 mediaDir 内: %q", fileURL.Path)
			}
			if _, err := os.Stat(fileURL.Path); err != nil {
				t.Fatalf("file URL 指向的文件不存在: %v", err)
			}
		}

		// 幂等：二次请求返回同一路径，不重复触发下载。
		triggerCount := atomic.LoadInt32(calls)
		secondResp := doRequest(t, http.MethodPost, endpoint, auth, `{"message_id":"360002"}`)
		if secondResp.StatusCode != http.StatusOK {
			t.Fatalf("二次 status = %d, want 200", secondResp.StatusCode)
		}
		var second struct {
			OK       bool   `json:"ok"`
			Path     string `json:"path"`
			SilkPath string `json:"silk_path"`
		}
		if err := json.Unmarshal([]byte(readBody(t, secondResp)), &second); err != nil {
			t.Fatalf("解析二次响应失败: %v", err)
		}
		if !second.OK || second.Path != parsed.Path || second.SilkPath != parsed.SilkPath {
			t.Fatalf("幂等响应不一致: first=%#v second=%#v", parsed, second)
		}
		if got := atomic.LoadInt32(calls); got != triggerCount {
			t.Fatalf("幂等请求重复触发下载: %d → %d", triggerCount, got)
		}
	})

	t.Run("下载失败返回 HTTP 200 + ok:false", func(t *testing.T) {
		setupVoiceTestEnv(t)
		payload := testVoicePayload("360003")
		registerIncomingVoice(payload)
		triggerIncomingVoiceDownload = func(job *incomingVoiceJob, fileType int, tempPath string) (string, error) {
			return "fail", nil
		}

		resp := doRequest(t, http.MethodPost, endpoint, auth, `{"message_id":"360003"}`)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200（契约：失败不返回 500）", resp.StatusCode)
		}
		body := readBody(t, resp)
		assertNoSecrets(t, body)
		if !strings.Contains(body, `"ok":false`) || !strings.Contains(body, "微信未接受语音下载请求") {
			t.Fatalf("失败响应内容错误: %q", body)
		}
	})
}

// ---------------------------------------------------------------------------
// 7. 发送契约（/send_voice 与 /send_private_msg voice 段）
// ---------------------------------------------------------------------------

func TestSendVoiceUnsupportedContract(t *testing.T) {
	const token = "7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b"
	withToken(t, token)
	setupVoiceTestEnv(t)

	server := httptest.NewServer(http.HandlerFunc(sendVoiceHandler))
	t.Cleanup(server.Close)
	sendEndpoint := server.URL + "/send_voice"
	auth := "Bearer " + token
	pcmBase64 := base64.StdEncoding.EncodeToString(syntheticVoicePCM(1600) /* 100ms */)

	t.Run("未鉴权返回 401", func(t *testing.T) {
		resp := doRequest(t, http.MethodPost, sendEndpoint, "", `{"user_id":"wxid_test","pcm16k":"`+pcmBase64+`"}`)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("status = %d, want 401", resp.StatusCode)
		}
	})

	t.Run("缺参数返回 400", func(t *testing.T) {
		resp := doRequest(t, http.MethodPost, sendEndpoint, auth, `{"pcm16k":"`+pcmBase64+`"}`)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", resp.StatusCode)
		}
		resp = doRequest(t, http.MethodPost, sendEndpoint, auth, `{"user_id":"wxid_test"}`)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("缺 pcm16k status = %d, want 400", resp.StatusCode)
		}
	})

	t.Run("默认返回 voice_send_unsupported（HTTP 200）", func(t *testing.T) {
		resp := doRequest(t, http.MethodPost, sendEndpoint, auth,
			`{"user_id":"wxid_test","pcm16k":"`+pcmBase64+`","duration_ms":100}`)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
		body := readBody(t, resp)
		if !strings.Contains(body, `"ok":false`) || !strings.Contains(body, voiceSendUnsupportedCode) {
			t.Fatalf("body = %q, want voice_send_unsupported", body)
		}
		if strings.Contains(body, testVoiceAESKeyHex) || strings.Contains(body, testVoiceCDNKey) {
			t.Fatalf("响应体泄露 key: %q", body)
		}
	})

	t.Run("非法 pcm16k 返回可读错误", func(t *testing.T) {
		resp := doRequest(t, http.MethodPost, sendEndpoint, auth, `{"user_id":"wxid_test","pcm16k":"!!!"}`)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
		body := readBody(t, resp)
		if strings.Contains(body, voiceSendUnsupportedCode) {
			t.Fatalf("非法 PCM 不应返回 unsupported: %q", body)
		}
		if !strings.Contains(body, `"ok":false`) {
			t.Fatalf("body = %q", body)
		}
	})

	t.Run("/send_private_msg voice 段走同一契约", func(t *testing.T) {
		server := httptest.NewServer(http.HandlerFunc(sendHandler))
		t.Cleanup(server.Close)
		endpoint := server.URL + "/send_private_msg"
		body := `{"user_id":"wxid_test","message":[{"type":"voice","data":{"pcm16k":"` + pcmBase64 + `","duration_ms":100}}]}`
		resp := doRequest(t, http.MethodPost, endpoint, auth, body)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
		respBody := readBody(t, resp)
		if !strings.Contains(respBody, `"ok":false`) || !strings.Contains(respBody, voiceSendUnsupportedCode) {
			t.Fatalf("body = %q, want voice_send_unsupported", respBody)
		}
	})
}

func TestSendVoiceEnabledPath(t *testing.T) {
	setupVoiceTestEnv(t)
	withVoiceEnv(t, envVoiceSend, "1")
	pcm := syntheticVoicePCM(16000) // 1s

	var gotDuration int32
	var gotAudioHex, gotPayloadHex, gotPath string
	triggerVoiceUpload = func(targetID, voicePath, payloadHex, audioHex string, durationMs int32, voiceFileID string) (string, error) {
		gotDuration = durationMs
		gotAudioHex = audioHex
		gotPayloadHex = payloadHex
		gotPath = voicePath
		if _, err := os.Stat(voicePath); err != nil {
			t.Errorf("上传前 SILK 临时文件不存在: %v", err)
		}
		return "0", nil
	}

	durationMs, err := sendVoicePCM16k("wxid_test", "", base64.StdEncoding.EncodeToString(pcm), 1000)
	if err != nil {
		t.Fatalf("启用发送应成功: %v", err)
	}
	if durationMs < 960 || durationMs > 1040 {
		t.Fatalf("duration_ms = %d, want ≈1000", durationMs)
	}
	if int(gotDuration) != durationMs {
		t.Fatalf("上传 duration = %d, want %d", gotDuration, durationMs)
	}
	if !strings.HasPrefix(gotAudioHex, "02232153494c4b5f5633") {
		t.Fatalf("上传数据不是 Tencent SILK hex: %.20s", gotAudioHex)
	}
	if gotPayloadHex != BuildVoiceUploadPayload() {
		t.Fatal("上传 payload 模板错误")
	}
	if gotPath == "" || !strings.HasSuffix(gotPath, ".silk") {
		t.Fatalf("上传路径错误: %q", gotPath)
	}
	if _, err := os.Stat(gotPath); !os.IsNotExist(err) {
		t.Fatalf("上传后临时 SILK 应被清理: %v", err)
	}

	t.Run("上传被拒绝", func(t *testing.T) {
		setupVoiceTestEnv(t)
		withVoiceEnv(t, envVoiceSend, "1")
		triggerVoiceUpload = func(targetID, voicePath, payloadHex, audioHex string, durationMs int32, voiceFileID string) (string, error) {
			return "fail", nil
		}
		if _, err := sendVoicePCM16k("wxid_test", "", base64.StdEncoding.EncodeToString(pcm), 0); !errors.Is(err, errVoiceUploadRejected) {
			t.Fatalf("应返回上传被拒绝: %v", err)
		}
	})

	t.Run("Frida 不可用", func(t *testing.T) {
		setupVoiceTestEnv(t)
		withVoiceEnv(t, envVoiceSend, "1")
		triggerVoiceUpload = func(targetID, voicePath, payloadHex, audioHex string, durationMs int32, voiceFileID string) (string, error) {
			return "", errVoiceBridgeUnavailable
		}
		if _, err := sendVoicePCM16k("wxid_test", "", base64.StdEncoding.EncodeToString(pcm), 0); !errors.Is(err, errVoiceBridgeUnavailable) {
			t.Fatalf("应返回 Frida 不可用: %v", err)
		}
	})
}

func TestDecodeVoicePCM16kBase64(t *testing.T) {
	pcm := syntheticVoicePCM(1600)
	encoded := base64.StdEncoding.EncodeToString(pcm)

	t.Run("标准 base64 / data URI / base64 前缀", func(t *testing.T) {
		for name, input := range map[string]string{
			"plain":    encoded,
			"dataURI":  "data:audio/wav;base64," + encoded,
			"base64":   "base64://" + encoded,
			"rawNoPad": strings.TrimRight(encoded, "="),
		} {
			got, err := decodeVoicePCM16kBase64(input)
			if err != nil {
				t.Fatalf("%s: 解码失败: %v", name, err)
			}
			if !bytes.Equal(got, pcm) {
				t.Fatalf("%s: 解码内容不一致", name)
			}
		}
	})

	t.Run("兼容 16k WAV base64", func(t *testing.T) {
		// 契约是 s16le PCM，但也接受 App 直接传 16k WAV（bridge 负责去掉 RIFF 头）。
		wav, err := buildVoiceWAV(pcm)
		if err != nil {
			t.Fatalf("生成 WAV 失败: %v", err)
		}
		got, err := decodeVoicePCM16kBase64(base64.StdEncoding.EncodeToString(wav))
		if err != nil {
			t.Fatalf("WAV base64 解码失败: %v", err)
		}
		if !bytes.Equal(got, pcm) {
			t.Fatalf("WAV 提取 PCM 不一致: got %d bytes want %d", len(got), len(pcm))
		}

		// 非 16k WAV 必须拒绝（避免把错误采样率的音频当 pcm16k 编码）。
		badWAV := append([]byte(nil), wav...)
		binary.LittleEndian.PutUint32(badWAV[24:28], 44100)
		if _, err := decodeVoicePCM16kBase64(base64.StdEncoding.EncodeToString(badWAV)); !errors.Is(err, errVoicePCMInvalid) {
			t.Fatalf("非 16k WAV 应失败: %v", err)
		}
	})

	t.Run("非法输入", func(t *testing.T) {
		if _, err := decodeVoicePCM16kBase64(""); !errors.Is(err, errVoicePCMEmpty) {
			t.Fatalf("空输入应返回 errVoicePCMEmpty: %v", err)
		}
		if _, err := decodeVoicePCM16kBase64("!!!"); !errors.Is(err, errVoicePCMInvalid) {
			t.Fatalf("非法 base64 应失败: %v", err)
		}
		odd := base64.StdEncoding.EncodeToString(make([]byte, 641))
		if _, err := decodeVoicePCM16kBase64(odd); !errors.Is(err, errVoicePCMInvalid) {
			t.Fatalf("奇数长度应失败: %v", err)
		}
		tooLong := base64.StdEncoding.EncodeToString(make([]byte, maxVoiceSendPCMBytes+2))
		if _, err := decodeVoicePCM16kBase64(tooLong); !errors.Is(err, errVoicePCMLength) {
			t.Fatalf("超长应失败: %v", err)
		}
		if _, err := sendVoicePCM16k("", "", encoded, 0); !errors.Is(err, errVoiceTargetMissing) {
			t.Fatalf("缺目标应失败: %v", err)
		}
	})
}

// ---------------------------------------------------------------------------
// 8. 入站 voice 段经 HandleMsg 再序列化不丢 duration_ms
// ---------------------------------------------------------------------------

func TestIncomingVoiceSegmentSurvivesHandleMsg(t *testing.T) {
	setupVoiceTestEnv(t)
	payload := testVoicePayload("370001")
	registerIncomingVoice(payload)

	eventJSON, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("序列化事件失败: %v", err)
	}
	output, err := HandleMsg(eventJSON)
	if err != nil {
		t.Fatalf("HandleMsg 失败: %v", err)
	}
	text := string(output)
	if !strings.Contains(text, `"type":"voice"`) || !strings.Contains(text, `"duration_ms":5200`) {
		t.Fatalf("voice 段的 duration_ms 在 HandleMsg 后丢失: %s", text)
	}
	// 契约：raw_message 保持 hook 原始 XML（历史行为），但 message 段不得新增
	// aeskey / voiceurl 字段。
	var reparsed WechatMessage
	if err := json.Unmarshal(output, &reparsed); err != nil {
		t.Fatalf("解析输出失败: %v", err)
	}
	if len(reparsed.Message) != 2 || reparsed.Message[0].Type != "voice" || reparsed.Message[0].Data == nil {
		t.Fatalf("输出 message 段错误: %s", text)
	}
	if reparsed.Message[0].Data.DurationMs != testVoiceDurationMs {
		t.Fatalf("duration_ms 丢失: %#v", reparsed.Message[0].Data)
	}
	segmentJSON, err := json.Marshal(reparsed.Message[0])
	if err != nil {
		t.Fatalf("序列化 voice 段失败: %v", err)
	}
	if strings.Contains(string(segmentJSON), "aeskey") || strings.Contains(string(segmentJSON), "voiceurl") {
		t.Fatalf("voice 段泄露 aeskey/CDN key: %s", segmentJSON)
	}
}

// ---------------------------------------------------------------------------
// 9. 日志隐私
// ---------------------------------------------------------------------------

func TestVoiceLogsDoNotLeakSecrets(t *testing.T) {
	setupVoiceTestEnv(t)

	oldLogger := Logger.logger
	oldLevel := zerolog.GlobalLevel()
	var buffer bytes.Buffer
	Logger.logger = zerolog.New(&buffer).Level(zerolog.DebugLevel).With().Timestamp().Logger()
	zerolog.SetGlobalLevel(zerolog.DebugLevel)
	t.Cleanup(func() {
		Logger.logger = oldLogger
		zerolog.SetGlobalLevel(oldLevel)
	})

	sample := readVoiceSample(t)
	cipherLen := len(encryptVoiceECB(t, sample, testVoiceAESKeyHex))
	payload := testVoicePayload("380001")
	payload["raw_message"] = buildTestVoiceXML(testVoiceCDNKey, testVoiceAESKeyHex, testVoiceDurationMs, cipherLen)
	registerIncomingVoice(payload)
	stubVoiceDownload(t, sample)
	if _, err := fetchIncomingVoice("380001"); err != nil {
		t.Fatalf("获取语音失败: %v", err)
	}

	// 发送契约默认路径也会写日志。
	if _, err := sendVoicePCM16k("wxid_test", "", base64.StdEncoding.EncodeToString(syntheticVoicePCM(1600)), 100); !errors.Is(err, errVoiceSendDisabled) {
		t.Fatalf("默认发送应返回 unsupported: %v", err)
	}

	logs := buffer.String()
	if logs == "" {
		t.Fatal("应产生日志")
	}
	for _, secret := range []string{testVoiceAESKeyHex, testVoiceCDNKey} {
		if strings.Contains(logs, secret) {
			t.Fatalf("日志泄露 key: %s", logs)
		}
	}
	if strings.Contains(logs, string(sample[:16])) || strings.Contains(logs, base64.StdEncoding.EncodeToString(sample[:16])) {
		t.Fatal("日志泄露音频字节")
	}
}

// ---------------------------------------------------------------------------
// 10. 无 panic 路径
// ---------------------------------------------------------------------------

func TestIncomingVoicePanicSafety(t *testing.T) {
	setupVoiceTestEnv(t)

	registerIncomingVoice(nil)
	registerIncomingVoice(map[string]interface{}{})
	registerIncomingVoice(map[string]interface{}{"msg_type": float64(34)})
	registerIncomingVoice(map[string]interface{}{"msg_type": json.Number("34"), "message": nil})
	registerIncomingVoice(map[string]interface{}{"msg_type": "34", "message": 42})
	registerIncomingVoice(map[string]interface{}{"msg_type": 34, "message": []interface{}{nil, "raw"}})
	registerIncomingVoice(map[string]interface{}{"msg_type": float64(1), "message": nil})

	if _, err := parseIncomingVoiceXML(""); err == nil {
		t.Fatal("空 XML 应返回错误")
	}
	if _, err := decryptVoiceBytes(nil, "", 0); err == nil {
		t.Fatal("空数据解密应返回错误")
	}
	if _, err := buildVoiceWAV(nil); err == nil {
		t.Fatal("空 PCM 应返回错误")
	}
	if _, err := fetchIncomingVoice(""); !errors.Is(err, errVoiceJobNotFound) {
		t.Fatalf("空 message_id 应报缺失: %v", err)
	}
}
