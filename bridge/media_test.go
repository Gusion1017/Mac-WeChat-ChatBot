package main

// 本文件由 ChatBot 项目新增（2026-10-23）：入站图片获取（media.go）的单元测试。
// 覆盖 docs/bridge.md §3.4 与 bridge/media.go 的六类场景。
//
// 隐私红线：所有测试数据均为合成值（wxid_test / 自造十六进制 / 合成图片字节），
// 不含真实 wxid、群 ID、聊天原文、aeskey 或 CDN file key。

import (
	"crypto/aes"
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
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const (
	// 合成密钥 / key / md5：全部为自造十六进制，与真实数据无关。
	testImageAESKeyHex   = "000102030405060708090a0b0c0d0e0f"
	testImageThumbKeyHex = "0f0e0d0c0b0a09080706050403020100"
	testMidCDNKey        = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
	testThumbCDNKey      = "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
	testImageMD5         = "00112233445566778899aabbccddeeff"
	testWrongAESKeyHex   = "ffffffffffffffffffffffffffffffff"
)

// setupMediaTestEnv 隔离 media 测试用到的全局状态，并在 t.Cleanup 中还原。
func setupMediaTestEnv(t *testing.T) string {
	t.Helper()

	root := t.TempDir()

	oldConfigMediaDir := config.MediaDir
	oldMediaDir := mediaDir
	oldTrigger := triggerIncomingImageDownload
	oldSelfID := myWechatId

	// 下载代次是 media.go 之外的全局状态（msg.go），一并隔离。
	oldDownloadSeq := atomic.SwapInt64(&downloadSeq, 0)
	latestDownload.mu.Lock()
	oldLatestSeq, oldLatestKey := latestDownload.seq, latestDownload.key
	latestDownload.seq, latestDownload.key = 0, ""
	latestDownload.mu.Unlock()

	config.MediaDir = root
	mediaDir = ""
	clearSyncMap(&pendingImageJobs)
	clearSyncMap(&userID2FileMsgMap)
	myWechatId = "wxid_test"

	t.Cleanup(func() {
		config.MediaDir = oldConfigMediaDir
		mediaDir = oldMediaDir
		clearSyncMap(&pendingImageJobs)
		clearSyncMap(&userID2FileMsgMap)
		triggerIncomingImageDownload = oldTrigger
		myWechatId = oldSelfID
		atomic.StoreInt64(&downloadSeq, oldDownloadSeq)
		latestDownload.mu.Lock()
		latestDownload.seq, latestDownload.key = oldLatestSeq, oldLatestKey
		latestDownload.mu.Unlock()
	})

	return root
}

// clearSyncMap 原地清空 sync.Map，避免复制它（go vet copylocks）。
func clearSyncMap(target *sync.Map) {
	target.Range(func(key, _ interface{}) bool {
		target.Delete(key)
		return true
	})
}

// syntheticImageJPEG 生成以 JPEG 魔数开头、长度为 size（>=12）的合成图片字节。
func syntheticImageJPEG(size int) []byte {
	if size < 16 {
		size = 16
	}
	data := make([]byte, size)
	for index := range data {
		data[index] = byte((index*7 + 11) % 256)
	}
	copy(data, []byte{0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01})
	// 合法 JPEG 以 EOI 结束；完整性校验会拒绝缺少 EOI 的截断图片。
	data[len(data)-2] = 0xFF
	data[len(data)-1] = 0xD9
	return data
}

// encryptImageECB 用测试内 AES-ECB 加密（末尾补 0 到整块），模拟微信 CDN 密文。
func encryptImageECB(t *testing.T, plain []byte, keyHex string) []byte {
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

// buildTestImageXML 生成与真机同结构的 <msg><img …/></msg>；midKey/thumbKey
// 为空时省略对应候选。
func buildTestImageXML(midKey, thumbKey, md5 string, midLength, thumbLength int) string {
	attributes := []string{`encryver="1"`, fmt.Sprintf(`md5="%s"`, md5)}
	if midKey != "" {
		attributes = append(attributes,
			fmt.Sprintf(`aeskey="%s"`, testImageAESKeyHex),
			fmt.Sprintf(`cdnmidimgurl="%s"`, midKey),
			fmt.Sprintf(`length="%d"`, midLength),
			`cdnmidheight="120"`,
		)
	}
	if thumbKey != "" {
		attributes = append(attributes,
			fmt.Sprintf(`cdnthumbaeskey="%s"`, testImageThumbKeyHex),
			fmt.Sprintf(`cdnthumburl="%s"`, thumbKey),
			fmt.Sprintf(`cdnthumblength="%d"`, thumbLength),
		)
	}
	return "<msg><img " + strings.Join(attributes, " ") + " /></msg>"
}

func testImageXML() string {
	return buildTestImageXML(testMidCDNKey, testThumbCDNKey, strings.ToUpper(testImageMD5), 48, 48)
}

// testImagePayload 构造一条与 hook 上报结构一致的入站图片事件。
func testImagePayload(messageID string) map[string]interface{} {
	return map[string]interface{}{
		"msg_type":    float64(3),
		"message_id":  messageID,
		"raw_message": testImageXML(),
		"message": []interface{}{
			map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "[图片]"}},
			map[string]interface{}{"type": "at", "data": map[string]interface{}{"qq": "wxid_test"}},
		},
	}
}

func countPendingImageJobs() int {
	count := 0
	pendingImageJobs.Range(func(_, _ interface{}) bool {
		count++
		return true
	})
	return count
}

// stubImageDownload 让注入的下载触发器把一组伪造分片塞进 userID2FileMsgMap，
// 返回 "1" 表示触发成功。lastAppend 控制分片是否已稳定。
func stubImageDownload(t *testing.T, plain []byte, lastAppend time.Time) {
	t.Helper()
	triggerIncomingImageDownload = func(job *incomingImageJob, candidate imageCandidate, tempPath string) (string, error) {
		userID2FileMsgMap.Store(candidate.CDNKey, &DownloadRequest{
			CDNURL:         candidate.CDNKey,
			Media:          encryptImageECB(t, plain, candidate.AESKey),
			LastAppendTime: lastAppend.UnixMilli(),
		})
		return "1", nil
	}
}

// ---------------------------------------------------------------------------
// 1. parseIncomingImageXML
// ---------------------------------------------------------------------------

func TestParseIncomingImageXML(t *testing.T) {
	t.Run("mid 优先、thumb 回退、md5 归一化", func(t *testing.T) {
		candidates, md5, err := parseIncomingImageXML(testImageXML())
		if err != nil {
			t.Fatalf("解析失败: %v", err)
		}
		if md5 != testImageMD5 {
			t.Fatalf("md5 未小写归一化: %q", md5)
		}
		if len(candidates) != 2 {
			t.Fatalf("候选数量 = %d, want 2: %#v", len(candidates), candidates)
		}
		if candidates[0].Variant != "mid" || candidates[0].CDNKey != testMidCDNKey ||
			candidates[0].AESKey != testImageAESKeyHex || candidates[0].FileType != 2 || candidates[0].Length != 48 {
			t.Fatalf("mid 候选错误: %#v", candidates[0])
		}
		if candidates[1].Variant != "thumb" || candidates[1].CDNKey != testThumbCDNKey ||
			candidates[1].AESKey != testImageThumbKeyHex || candidates[1].FileType != 3 || candidates[1].Length != 48 {
			t.Fatalf("thumb 候选错误: %#v", candidates[1])
		}
	})

	t.Run("只有 thumb", func(t *testing.T) {
		candidates, _, err := parseIncomingImageXML(buildTestImageXML("", testThumbCDNKey, testImageMD5, 0, 48))
		if err != nil {
			t.Fatalf("解析失败: %v", err)
		}
		if len(candidates) != 1 || candidates[0].Variant != "thumb" {
			t.Fatalf("thumb 回退候选错误: %#v", candidates)
		}
	})

	t.Run("缺 aeskey 的候选被忽略", func(t *testing.T) {
		// 只有 cdnmidimgurl、没有 aeskey → 不产生 mid 候选。
		candidates, _, err := parseIncomingImageXML(`<msg><img cdnmidimgurl="` + testMidCDNKey + `" length="32" /></msg>`)
		if err != nil {
			t.Fatalf("解析失败: %v", err)
		}
		if len(candidates) != 0 {
			t.Fatalf("缺 aeskey 不应有候选: %#v", candidates)
		}
	})

	t.Run("无候选", func(t *testing.T) {
		candidates, md5, err := parseIncomingImageXML(`<msg><img md5="` + testImageMD5 + `" /></msg>`)
		if err != nil {
			t.Fatalf("解析失败: %v", err)
		}
		if len(candidates) != 0 {
			t.Fatalf("不应有候选: %#v", candidates)
		}
		if md5 != testImageMD5 {
			t.Fatalf("md5 = %q, want %q", md5, testImageMD5)
		}
	})

	t.Run("坏 XML", func(t *testing.T) {
		if _, _, err := parseIncomingImageXML(`<msg><img aeskey="`); err == nil {
			t.Fatal("坏 XML 应返回错误")
		}
		if _, _, err := parseIncomingImageXML(""); err == nil {
			t.Fatal("空 XML 应返回错误")
		}
	})

	t.Run("md5 校验", func(t *testing.T) {
		_, md5, err := parseIncomingImageXML(buildTestImageXML(testMidCDNKey, "", "not-a-md5", 32, 0))
		if err != nil {
			t.Fatalf("解析失败: %v", err)
		}
		if md5 != "" {
			t.Fatalf("非法 md5 应归一化为空: %q", md5)
		}
	})
}

// ---------------------------------------------------------------------------
// 2. registerIncomingImage
// ---------------------------------------------------------------------------

func TestParseIncomingImageXMLPrefersThumbForHevcMid(t *testing.T) {
	// 4.2 常见：mid 是 HEVC（hevc_mid_size / cdnmidheight=0），没有 HEVC 解码时
	// 应只保留 JPEG 缩略图候选。
	xml := `<msg><img encryver="1" md5="` + testImageMD5 + `" aeskey="` + testImageAESKeyHex +
		`" cdnmidimgurl="` + testMidCDNKey + `" length="32" hevc_mid_size="32" cdnmidheight="0" ` +
		`cdnthumbaeskey="` + testImageThumbKeyHex + `" cdnthumburl="` + testThumbCDNKey +
		`" cdnthumblength="48" /></msg>`
	candidates, _, err := parseIncomingImageXML(xml)
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if len(candidates) != 1 || candidates[0].Variant != "thumb" {
		t.Fatalf("HEVC mid 应回退到 thumb，got %#v", candidates)
	}
}

func TestRegisterIncomingImage(t *testing.T) {
	t.Run("替换 [图片] 占位并登记候选", func(t *testing.T) {
		setupMediaTestEnv(t)
		payload := testImagePayload("300001")
		payload["message"] = []interface{}{
			map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "[图片]"}},
			map[string]interface{}{"type": "at", "data": map[string]interface{}{"qq": "wxid_test"}},
			map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "   "}},
		}

		registerIncomingImage(payload)

		message, ok := payload["message"].([]interface{})
		if !ok {
			t.Fatalf("message 类型错误: %T", payload["message"])
		}
		if len(message) != 2 {
			t.Fatalf("message 段数 = %d, want 2: %#v", len(message), message)
		}
		first, ok := message[0].(map[string]interface{})
		if !ok || first["type"] != "image" {
			t.Fatalf("首段应为 image: %#v", message[0])
		}
		if data, ok := first["data"].(map[string]interface{}); !ok || len(data) != 0 {
			t.Fatalf("image 段 data 应为空对象: %#v", first["data"])
		}
		if message[1].(map[string]interface{})["type"] != "at" {
			t.Fatalf("at 段应原样保留: %#v", message[1])
		}

		jobValue, ok := pendingImageJobs.Load("300001")
		if !ok {
			t.Fatal("图片事件未登记下载任务")
		}
		job := jobValue.(*incomingImageJob)
		if len(job.Candidates) != 2 || job.MD5 != testImageMD5 {
			t.Fatalf("登记内容错误: %#v", job)
		}
	})

	t.Run("非图片事件不改动", func(t *testing.T) {
		setupMediaTestEnv(t)
		message := []interface{}{
			map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "你好"}},
		}
		payload := map[string]interface{}{
			"msg_type":    float64(1),
			"message_id":  "300002",
			"raw_message": "你好",
			"message":     message,
		}

		registerIncomingImage(payload)

		if got, ok := payload["message"].([]interface{}); !ok || len(got) != 1 {
			t.Fatalf("非图片事件被改写: %#v", payload["message"])
		}
		if countPendingImageJobs() != 0 {
			t.Fatal("非图片事件不应登记下载任务")
		}
	})

	t.Run("message 是字符串时整体替换", func(t *testing.T) {
		setupMediaTestEnv(t)
		payload := testImagePayload("300003")
		payload["message"] = "[图片]"

		registerIncomingImage(payload)

		message, ok := payload["message"].([]interface{})
		if !ok || len(message) != 1 {
			t.Fatalf("字符串 message 未替换: %#v", payload["message"])
		}
		if message[0].(map[string]interface{})["type"] != "image" {
			t.Fatalf("替换后的段不是 image: %#v", message[0])
		}
		if _, ok := pendingImageJobs.Load("300003"); !ok {
			t.Fatal("字符串 message 的图片事件应登记")
		}
	})

	t.Run("旧 bridge 无 msg_type 但 raw 含 img 也登记", func(t *testing.T) {
		setupMediaTestEnv(t)
		payload := map[string]interface{}{
			"message_id":  "300004",
			"raw_message": testImageXML(),
			"message": []interface{}{
				map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "[图片]"}},
			},
		}

		registerIncomingImage(payload)

		if _, ok := pendingImageJobs.Load("300004"); !ok {
			t.Fatal("raw_message 含 <img> 的旧事件应登记")
		}
		message := payload["message"].([]interface{})
		if len(message) != 1 || message[0].(map[string]interface{})["type"] != "image" {
			t.Fatalf("旧事件 message 未替换: %#v", message)
		}
	})

	t.Run("缺 message_id 仍替换但不登记", func(t *testing.T) {
		setupMediaTestEnv(t)
		payload := testImagePayload("")
		delete(payload, "message_id")

		registerIncomingImage(payload)

		if countPendingImageJobs() != 0 {
			t.Fatal("缺 message_id 不应登记")
		}
		if _, ok := payload["message"].([]interface{}); !ok {
			t.Fatal("缺 message_id 时仍应替换 message")
		}
	})
}

// ---------------------------------------------------------------------------
// 3. decryptImageBytes
// ---------------------------------------------------------------------------

func TestRegisterIncomingImageIgnoresNonImageMsgType(t *testing.T) {
	setupMediaTestEnv(t)

	// appmsg（msg_type=49）即使正文/卡片里恰好出现 <img，也不能被当成图片事件。
	payload := map[string]interface{}{
		"msg_type":    float64(49),
		"message_id":  "610001",
		"raw_message": `<msg><appmsg><type>5</type><title>t</title><img src="x"/></appmsg></msg>`,
		"message": []interface{}{
			map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "[链接/文件]"}},
		},
	}
	registerIncomingImage(payload)

	if _, ok := pendingImageJobs.Load("610001"); ok {
		t.Fatal("非图片 msg_type 不应登记图片任务")
	}
	message, ok := payload["message"].([]interface{})
	if !ok || len(message) != 1 {
		t.Fatalf("非图片事件 message 不应被改写: %#v", payload["message"])
	}
	segment, _ := message[0].(map[string]interface{})
	if segment["type"] != "text" {
		t.Fatalf("非图片事件段类型被改写: %#v", segment)
	}
}

func TestDecryptImageBytes(t *testing.T) {
	plain := syntheticImageJPEG(48)
	cipherData := encryptImageECB(t, plain, testImageAESKeyHex)

	t.Run("AES-ECB 密文解密", func(t *testing.T) {
		got, err := decryptImageBytes(cipherData, testImageAESKeyHex, len(plain))
		if err != nil {
			t.Fatalf("解密失败: %v", err)
		}
		if string(got) != string(plain) {
			t.Fatalf("解密结果与明文不一致: got %d bytes", len(got))
		}
		if DetectFileFormat(got) != "jpg" {
			t.Fatalf("解密结果不是 jpg: %q", DetectFileFormat(got))
		}
	})

	t.Run("明文直通", func(t *testing.T) {
		got, err := decryptImageBytes(plain, "", 0)
		if err != nil {
			t.Fatalf("明文直通失败: %v", err)
		}
		if string(got) != string(plain) {
			t.Fatal("明文直通内容被改写")
		}
	})

	t.Run("忽略不可信的 length，按 JPEG EOI 裁齐", func(t *testing.T) {
		// XML 里的 length 不总是真实明文长度；按它截断会切掉 EOI，导致半张图。
		got, err := decryptImageBytes(cipherData, testImageAESKeyHex, 20)
		if err != nil {
			t.Fatalf("解密失败: %v", err)
		}
		if len(got) != len(plain) || string(got) != string(plain) {
			t.Fatalf("应按 EOI 保留完整图片: got %d bytes want %d", len(got), len(plain))
		}
	})

	t.Run("缺少 EOI 的半张图返回不完整", func(t *testing.T) {
		truncated := encryptImageECB(t, plain[:16], testImageAESKeyHex)
		if _, err := decryptImageBytes(truncated, testImageAESKeyHex, len(plain)); !errors.Is(err, errImageIncomplete) {
			t.Fatalf("缺少 EOI 应返回 errImageIncomplete，got %v", err)
		}
	})

	t.Run("错误 key 失败", func(t *testing.T) {
		wrongCipher := encryptImageECB(t, plain, testWrongAESKeyHex)
		if _, err := decryptImageBytes(wrongCipher, testImageAESKeyHex, len(plain)); err == nil {
			t.Fatal("错误 key 应解密失败")
		}
	})

	t.Run("异常输入", func(t *testing.T) {
		if _, err := decryptImageBytes(nil, testImageAESKeyHex, 0); err == nil {
			t.Fatal("空数据应失败")
		}
		if _, err := decryptImageBytes(cipherData, "", 0); err == nil {
			t.Fatal("缺 key 应失败")
		}
		if _, err := decryptImageBytes(cipherData, "short-key", 0); err == nil {
			t.Fatal("非法 key 应失败")
		}
	})
}

// ---------------------------------------------------------------------------
// 4. fetchIncomingImage
// ---------------------------------------------------------------------------

func TestFetchIncomingImage(t *testing.T) {
	root := setupMediaTestEnv(t)
	registerIncomingImage(testImagePayload("400001"))

	plain := syntheticImageJPEG(48)
	// 分片时间戳已稳定；mid 候选 length=32 也会触发「长度足够」完成判定。
	stubImageDownload(t, plain, time.Now())

	path, err := fetchIncomingImage("400001")
	if err != nil {
		t.Fatalf("获取图片失败: %v", err)
	}

	if !filepath.IsAbs(path) {
		t.Fatalf("返回路径不是绝对路径: %q", path)
	}
	rel, err := filepath.Rel(root, path)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		t.Fatalf("返回路径不在 mediaDir 内: %q (rel=%q)", path, rel)
	}
	wantDir := time.Now().Format("2006-01-02")
	if filepath.Base(filepath.Dir(path)) != wantDir {
		t.Fatalf("图片未按日期目录保存: %q", path)
	}
	if filepath.Base(path) != testImageMD5+".jpg" {
		t.Fatalf("图片文件名 = %q, want %q", filepath.Base(path), testImageMD5+".jpg")
	}

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取落盘图片失败: %v", err)
	}
	// mid 候选 XML length=32 → 按 length 截断。
	if string(content) != string(plain) {
		t.Fatalf("落盘内容与明文不一致: got %d bytes", len(content))
	}

	if _, err := fetchIncomingImage("400001"); !errors.Is(err, errImageJobNotFound) {
		t.Fatalf("二次请求应报缺失或已过期: %v", err)
	}
}

func TestFetchIncomingImageFallsBackToThumb(t *testing.T) {
	root := setupMediaTestEnv(t)
	registerIncomingImage(testImagePayload("400002"))

	plain := syntheticImageJPEG(48)
	triggerIncomingImageDownload = func(job *incomingImageJob, candidate imageCandidate, tempPath string) (string, error) {
		if candidate.Variant == "mid" {
			return "fail", nil
		}
		userID2FileMsgMap.Store(candidate.CDNKey, &DownloadRequest{
			CDNURL:         candidate.CDNKey,
			Media:          encryptImageECB(t, plain, candidate.AESKey),
			LastAppendTime: time.Now().Add(-2 * time.Second).UnixMilli(),
		})
		return "1", nil
	}

	path, err := fetchIncomingImage("400002")
	if err != nil {
		t.Fatalf("thumb 回退获取失败: %v", err)
	}
	rel, err := filepath.Rel(root, path)
	if err != nil || strings.HasPrefix(rel, "..") {
		t.Fatalf("返回路径不在 mediaDir 内: %q", path)
	}
	if want := testImageMD5 + "-thumb.jpg"; filepath.Base(path) != want {
		t.Fatalf("缩略图文件名 = %q, want %q", filepath.Base(path), want)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取落盘图片失败: %v", err)
	}
	if string(content) != string(plain) {
		t.Fatal("thumb 回退落盘内容与明文不一致")
	}
}

func TestFetchIncomingImageReusesExistingFile(t *testing.T) {
	setupMediaTestEnv(t)
	plain := syntheticImageJPEG(48)
	stubImageDownload(t, plain, time.Now())

	registerIncomingImage(testImagePayload("400003"))
	firstPath, err := fetchIncomingImage("400003")
	if err != nil {
		t.Fatalf("首次获取图片失败: %v", err)
	}

	// 同一张图（同 md5 / 同内容）再次获取应复用已有文件，不再重复写盘。
	registerIncomingImage(testImagePayload("400004"))
	secondPath, err := fetchIncomingImage("400004")
	if err != nil {
		t.Fatalf("二次获取图片失败: %v", err)
	}
	if secondPath != firstPath {
		t.Fatalf("同名同大小文件未复用: first=%q second=%q", firstPath, secondPath)
	}
	entries, err := os.ReadDir(filepath.Dir(firstPath))
	if err != nil {
		t.Fatalf("读取日期目录失败: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("重复获取产生了多个文件: %d", len(entries))
	}
}

func TestFetchIncomingImageMatchesNormalizedDownloadKey(t *testing.T) {
	root := setupMediaTestEnv(t)

	// 只有 mid 候选；模拟真机 CDN 任务把 key 规范化成另一个值。
	payload := map[string]interface{}{
		"msg_type":    float64(3),
		"message_id":  "400005",
		"raw_message": buildTestImageXML(testMidCDNKey, "", testImageMD5, 48, 0),
		"message": []interface{}{
			map[string]interface{}{"type": "text", "data": map[string]interface{}{"text": "[图片]"}},
		},
	}
	registerIncomingImage(payload)

	plain := syntheticImageJPEG(48)
	const normalizedKey = testThumbCDNKey // 仅作伪造的「被规范化」key
	triggerIncomingImageDownload = func(job *incomingImageJob, candidate imageCandidate, tempPath string) (string, error) {
		// 分片落在规范化后的 key 上（与 XML 里的 candidate.CDNKey 不同）。
		raw, err := json.Marshal(map[string]interface{}{
			"cdn_url": normalizedKey,
			"media":   encryptImageECB(t, plain, candidate.AESKey),
		})
		if err != nil {
			return "", err
		}
		if err := Download(raw); err != nil {
			return "", err
		}
		return "1", nil
	}

	path, err := fetchIncomingImage("400005")
	if err != nil {
		t.Fatalf("规范化 key 兜底获取失败: %v", err)
	}
	rel, err := filepath.Rel(root, path)
	if err != nil || strings.HasPrefix(rel, "..") {
		t.Fatalf("返回路径不在 mediaDir 内: %q", path)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取落盘图片失败: %v", err)
	}
	if string(content) != string(plain) {
		t.Fatal("规范化 key 兜底落盘内容与明文不一致")
	}
}

// ---------------------------------------------------------------------------
// 5. fetchImageHandler
// ---------------------------------------------------------------------------

// 真机场景：App 收到图片后立即请求，但微信的自然下载分片可能比触发更晚到达。
// 触发被拒绝时不能直接失败，必须继续等待自然分片。
func TestFetchIncomingImageUsesNaturalChunksWhenTriggerRejected(t *testing.T) {
	root := setupMediaTestEnv(t)
	registerIncomingImage(testImagePayload("400010"))

	plain := syntheticImageJPEG(48)
	triggerIncomingImageDownload = func(job *incomingImageJob, candidate imageCandidate, tempPath string) (string, error) {
		// 模拟「触发返回 fail，但微信自己的下载随后落到了同一 key」。
		userID2FileMsgMap.Store(candidate.CDNKey, &DownloadRequest{
			CDNURL:         candidate.CDNKey,
			Media:          encryptImageECB(t, plain, candidate.AESKey),
			LastAppendTime: time.Now().Add(-2 * time.Second).UnixMilli(),
		})
		return "fail", nil
	}

	path, err := fetchIncomingImage("400010")
	if err != nil {
		t.Fatalf("触发被拒绝但自然分片可用时应成功: %v", err)
	}
	rel, err := filepath.Rel(root, path)
	if err != nil || strings.HasPrefix(rel, "..") {
		t.Fatalf("返回路径不在 mediaDir 内: %q", path)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取落盘图片失败: %v", err)
	}
	if string(content) != string(plain) {
		t.Fatal("自然分片解密内容与预期不一致")
	}
}

func TestFetchImageHandler(t *testing.T) {
	const token = "5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f5f"
	withToken(t, token)

	server := httptest.NewServer(http.HandlerFunc(fetchImageHandler))
	t.Cleanup(server.Close)
	endpoint := server.URL + "/fetch_image"
	auth := "Bearer " + token

	assertNoSecrets := func(t *testing.T, body string) {
		t.Helper()
		for _, secret := range []string{testImageAESKeyHex, testImageThumbKeyHex, testMidCDNKey, testThumbCDNKey} {
			if strings.Contains(body, secret) {
				t.Fatalf("响应体泄露 key: %q", body)
			}
		}
	}

	t.Run("未鉴权返回 401", func(t *testing.T) {
		setupMediaTestEnv(t)
		resp := doRequest(t, http.MethodPost, endpoint, "", `{"message_id":"500001"}`)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("status = %d, want 401", resp.StatusCode)
		}
		if body := readBody(t, resp); !strings.Contains(body, "未授权") {
			t.Fatalf("body = %q, want 未授权", body)
		}
	})

	t.Run("缺参数返回 400", func(t *testing.T) {
		setupMediaTestEnv(t)
		resp := doRequest(t, http.MethodPost, endpoint, auth, `{}`)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", resp.StatusCode)
		}
		if body := readBody(t, resp); !strings.Contains(body, "参数缺失") {
			t.Fatalf("body = %q, want 参数缺失", body)
		}
	})

	t.Run("未登记返回 400", func(t *testing.T) {
		setupMediaTestEnv(t)
		resp := doRequest(t, http.MethodPost, endpoint, auth, `{"message_id":"not-registered"}`)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("status = %d, want 400", resp.StatusCode)
		}
		if body := readBody(t, resp); !strings.Contains(body, "缺失或已过期") {
			t.Fatalf("body = %q, want 缺失或已过期", body)
		}
	})

	t.Run("成功返回 200 且响应脱敏", func(t *testing.T) {
		setupMediaTestEnv(t)
		// 目录名带空格，验证 file:// 的百分号转义。
		mediaRoot := filepath.Join(t.TempDir(), "media dir")
		if err := os.MkdirAll(mediaRoot, 0o755); err != nil {
			t.Fatalf("创建测试目录失败: %v", err)
		}
		config.MediaDir = mediaRoot

		registerIncomingImage(testImagePayload("500002"))
		plain := syntheticImageJPEG(48)
		stubImageDownload(t, plain, time.Now())

		resp := doRequest(t, http.MethodPost, endpoint, auth, `{"message_id":"500002"}`)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("status = %d, want 200", resp.StatusCode)
		}
		body := readBody(t, resp)
		assertNoSecrets(t, body)

		var parsed struct {
			Status string `json:"status"`
			Data   struct {
				File      string `json:"file"`
				MessageID string `json:"message_id"`
			} `json:"data"`
		}
		if err := json.Unmarshal([]byte(body), &parsed); err != nil {
			t.Fatalf("解析响应失败: %v (body=%q)", err, body)
		}
		if parsed.Status != "ok" || parsed.Data.MessageID != "500002" {
			t.Fatalf("响应内容错误: %#v", parsed)
		}
		if !strings.HasPrefix(parsed.Data.File, "file://") {
			t.Fatalf("file 字段不是 file:// URL: %q", parsed.Data.File)
		}
		if !strings.Contains(parsed.Data.File, "media%20dir") {
			t.Fatalf("file URL 未做百分号转义: %q", parsed.Data.File)
		}
		fileURL, err := url.Parse(parsed.Data.File)
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
	})

	t.Run("下载失败返回 502", func(t *testing.T) {
		setupMediaTestEnv(t)
		registerIncomingImage(testImagePayload("500003"))
		triggerIncomingImageDownload = func(job *incomingImageJob, candidate imageCandidate, tempPath string) (string, error) {
			return "fail", nil
		}

		resp := doRequest(t, http.MethodPost, endpoint, auth, `{"message_id":"500003"}`)
		if resp.StatusCode != http.StatusBadGateway {
			t.Fatalf("status = %d, want 502", resp.StatusCode)
		}
		body := readBody(t, resp)
		assertNoSecrets(t, body)
		if !strings.Contains(body, `"status":"failed"`) || !strings.Contains(body, "微信未接受图片下载请求") {
			t.Fatalf("失败响应内容错误: %q", body)
		}
	})
}

// ---------------------------------------------------------------------------
// 6. 无 panic 路径
// ---------------------------------------------------------------------------

func TestIncomingImagePanicSafety(t *testing.T) {
	setupMediaTestEnv(t)

	// nil payload / 缺字段 / 类型异常都不应 panic。
	registerIncomingImage(nil)
	registerIncomingImage(map[string]interface{}{})
	registerIncomingImage(map[string]interface{}{"msg_type": float64(3)})
	registerIncomingImage(map[string]interface{}{"msg_type": json.Number("3"), "message": nil})
	registerIncomingImage(map[string]interface{}{"msg_type": "3", "message": 42})
	registerIncomingImage(map[string]interface{}{"msg_type": 3, "message": []interface{}{nil, "raw"}})
	registerIncomingImage(map[string]interface{}{"msg_type": float64(1), "message": nil})

	payload := map[string]interface{}{"msg_type": float64(3)}
	registerIncomingImage(payload)
	message, ok := payload["message"].([]interface{})
	if !ok || len(message) != 1 {
		t.Fatalf("message 为 nil 时应补 image 段: %#v", payload["message"])
	}

	// msg_type 的 float64 / json.Number / string / int 形式都能识别为图片。
	numericTypes := map[string]interface{}{
		"float64":     float64(3),
		"json.Number": json.Number("3"),
		"string":      "3",
		"int":         3,
	}
	for name, value := range numericTypes {
		event := map[string]interface{}{
			"msg_type":    value,
			"message_id":  "panic-" + name,
			"raw_message": testImageXML(),
		}
		registerIncomingImage(event)
		if _, ok := pendingImageJobs.Load("panic-" + name); !ok {
			t.Fatalf("msg_type 为 %s 的图片事件未登记", name)
		}
	}

	// 异常输入下有可读错误、不 panic。
	if _, _, err := parseIncomingImageXML(""); err == nil {
		t.Fatal("空 XML 应返回错误")
	}
	if _, err := decryptImageBytes(nil, "", 0); err == nil {
		t.Fatal("空数据解密应返回错误")
	}
	if _, err := fetchIncomingImage(""); !errors.Is(err, errImageJobNotFound) {
		t.Fatalf("空 message_id 应报缺失: %v", err)
	}
}
