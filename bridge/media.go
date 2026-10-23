package main

// 本文件由 ChatBot 项目新增（2026-10-23），实现入站图片获取的 bridge 侧契约：
//
//	微信收到图片 → hook 上报 [图片] 文本占位 + 完整 raw_message XML
//	→ registerIncomingImage 登记下载候选（mid/thumb 的 CDN file key + aeskey）
//	  并把事件 message 数组里的 [图片] 文本段替换成无 data 的 image 段
//	→ App 调 POST /fetch_image
//	→ fetchIncomingImage 用现有 Frida 导出 triggerDownload 触发微信自己的 CDN 下载
//	→ Download()（msg.go）把下载分片累积到 userID2FileMsgMap
//	→ 本文件等待分片稳定、AES-ECB 解密、校验图片魔数、落盘到 media_dir
//	→ 返回 file:// 路径给 App。
//
// 契约见 docs/architecture.md §3.2/§3.3 与 docs/bridge.md §3.4；已知限制见
// docs/bridge.md §6（真机 CDN key 是否被接受未验证）。日志/错误文案不得包含
// aeskey / CDN file key / 完整 XML。

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/frida/frida-go/frida"
)

const (
	// pendingImageJobTTL 是下载元数据在内存中的保留时间；App 一般几秒内就会请求。
	pendingImageJobTTL = 30 * time.Minute
	// pendingImageJobsLimit 是登记条目总量上限，超出时淘汰最旧的。
	pendingImageJobsLimit = 512

	// imageFetchConcurrency 是全局同时下载的图片数量上限。
	imageFetchConcurrency = 2
	// imageFetchSemaphoreWait 是排队拿下载槽的最长等待时间。
	imageFetchSemaphoreWait = 10 * time.Second
	// imageFetchTotalBudget 是单次 /fetch_image 的总预算（App 侧 HTTP 超时 30s）。
	imageFetchTotalBudget = 12 * time.Second
	// imageCandidateBudget 是单个候选（mid / thumb）的下载预算上限。
	imageCandidateBudget = 8 * time.Second
	// imageDownloadStableAfter 是分片停止增长多久后视为下载完成。
	imageDownloadStableAfter = 1200 * time.Millisecond
	// imageDownloadPollEvery 是轮询下载分片的间隔。
	imageDownloadPollEvery = 250 * time.Millisecond
	// imageDownloadFallbackAfter 触发后多久仍无 key 命中时，用「新出现的下载 key」兜底。
	imageDownloadFallbackAfter = 1 * time.Second
	// imageNaturalGraceWindow 是触发下载前的等待窗口：微信收到图片后通常会立即
	// 自行下载缩略图/中图，先等自然分片可避免重复触发与竞态。
	imageNaturalGraceWindow = 3 * time.Second
)

var (
	imageMD5Regexp = regexp.MustCompile(`^[a-fA-F0-9]{32}$`)

	// pendingImageJobs 保存 message_id → *incomingImageJob 的下载元数据。
	// 用 sync.Map 是因为 hook 回调与 HTTP handler 在不同 goroutine。
	pendingImageJobs sync.Map

	// imageFetchSemaphore 限制同时进行的图片下载数量。
	imageFetchSemaphore = make(chan struct{}, imageFetchConcurrency)

	// mediaDir 缓存最近一次解析出的图片落盘目录（便于测试与排障）。
	mediaDir string

	// 以下是返回给 App 的可读中文错误（不含 key / XML）。
	errImageJobNotFound       = errors.New("该消息的图片信息缺失或已过期")
	errBridgeFridaUnavailable = errors.New("bridge 尚未连接微信，无法获取图片")
	errImageFetchBusy         = errors.New("图片队列繁忙，请稍后重试")
	errImageDownloadTimeout   = errors.New("图片下载超时（微信未响应）")
	errImageDecryptFailed     = errors.New("图片解密失败，请稍后重试")
	errImageTriggerRejected   = errors.New("微信未接受图片下载请求")
	errImageUnsupportedFormat = errors.New("不支持的图片格式")
	errImageTriggerTimeout    = errors.New("微信下载请求超时")
	errImageIncomplete        = errors.New("图片数据不完整，正在等待微信下载完成")
)

// triggerIncomingImageDownload 是可注入的下载触发器（单测替换成伪造分片）。
// 生产实现只检查 Frida 是否就绪，然后调用 hook 已有的 triggerDownload 导出。
//
// fileType: HDImage=1 / Image=2 / thumbImage=3（见 hook/script.js）。
var triggerIncomingImageDownload = func(job *incomingImageJob, candidate imageCandidate, tempPath string) (string, error) {
	if fridaScript == nil {
		return "", errBridgeFridaUnavailable
	}
	// 微信的下载启动是同步调用；真机异常时可能长时间不返回。用带超时的 RPC，
	// 避免 HTTP handler / 图片队列被一直占用（超时后 WeChat 侧可能仍在下载，
	// 但本次请求会失败并在日志里给出原因）。
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ret := fridaScript.ExportsCallWithContext(ctx, "triggerDownload",
		myWechatId, candidate.CDNKey, candidate.AESKey, tempPath, candidate.FileType)
	if ret == frida.ErrContextCancelled {
		return "", errImageTriggerTimeout
	}
	return fmt.Sprint(ret), nil
}

// incomingImageXML 独立于 param.go 的上游 Image 结构，避免影响 legacy HandleMsg
// 的 XML 反序列化（上游文件只做最小改动）。
type incomingImageXML struct {
	XMLName xml.Name `xml:"msg"`
	Image   struct {
		AesKey      string `xml:"aeskey,attr"`
		EncryVer    string `xml:"encryver,attr"`
		ThumbAesKey string `xml:"cdnthumbaeskey,attr"`
		ThumbURL    string `xml:"cdnthumburl,attr"`
		MidURL      string `xml:"cdnmidimgurl,attr"`
		HDURL       string `xml:"cdnhdurl,attr"`
		BigURL      string `xml:"cdnbigimgurl,attr"`
		Length      int    `xml:"length,attr"`
		ThumbLength int    `xml:"cdnthumblength,attr"`
		HDLength    int    `xml:"hdlength,attr"`
		MD5         string `xml:"md5,attr"`
		HevcMidSize int    `xml:"hevc_mid_size,attr"`
		MidHeight   int    `xml:"cdnmidheight,attr"`
		EncryVerInt int    `xml:"-"` // 由 EncryVer 解析，保留给后续版本
	} `xml:"img"`
}

// incomingImageJob 是一条入站图片的下载元数据。
type incomingImageJob struct {
	MessageID  string
	MD5        string
	CreatedAt  time.Time
	Candidates []imageCandidate
}

// imageCandidate 是一个可尝试的下载候选（mid 大图 / thumb 缩略图）。
type imageCandidate struct {
	Variant  string // mid | thumb | hd（hd 本次不收集）
	CDNKey   string
	AESKey   string
	FileType int
	Length   int // XML 里的明文长度，用于等待完成与解密后截断
}

// resolvedMediaDir 解析并创建图片落盘目录（docs/bridge.md §3.4）。
// config.MediaDir 非空时展开 ~ 后使用；为空时落在
// ~/Library/Application Support/WeChatAI/media。
func resolvedMediaDir() (string, error) {
	dir := strings.TrimSpace(config.MediaDir)
	if dir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("无法确定图片保存目录: %w", err)
		}
		dir = filepath.Join(home, "Library", "Application Support", "WeChatAI", "media")
	} else {
		dir = expandUserPath(dir)
		dir = filepath.Clean(dir)
	}
	if dir == "" {
		return "", errors.New("图片保存目录无效")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("创建图片保存目录失败: %w", err)
	}
	mediaDir = dir
	return dir, nil
}

// expandUserPath 展开路径开头的 ~（支持 ~ 与 ~/xxx）。
func expandUserPath(path string) string {
	if path != "~" && !strings.HasPrefix(path, "~/") {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	if path == "~" {
		return home
	}
	return filepath.Join(home, path[2:])
}

// ensureWithinRoot 用 filepath.Rel 校验 target 落在 root 内，拒绝 .. 越界。
func ensureWithinRoot(root, target string) error {
	rel, err := filepath.Rel(root, target)
	if err != nil {
		return errors.New("图片保存路径不合法")
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		return errors.New("图片保存路径越界")
	}
	return nil
}

// parseIncomingImageXML 解析 raw_message 里的 <img> 属性，返回下载候选与 md5。
// 候选顺序固定为 mid → thumb；HD 候选本次不收集（下载体积不可控），
// incomingImageXML 里保留 HD 字段供后续版本使用。
func parseIncomingImageXML(raw string) ([]imageCandidate, string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, "", errors.New("图片 XML 为空")
	}

	var parsed incomingImageXML
	if err := xml.Unmarshal([]byte(raw), &parsed); err != nil {
		return nil, "", err
	}
	if strings.TrimSpace(parsed.Image.EncryVer) != "" {
		if version, err := strconv.Atoi(strings.TrimSpace(parsed.Image.EncryVer)); err == nil {
			parsed.Image.EncryVerInt = version
		}
	}

	md5 := normalizeIncomingMD5(parsed.Image.MD5)

	var candidates []imageCandidate
	// 4.2 的 mid 常是 HEVC（hevc_mid_size / cdnmidheight=0）；HEVC 解密后不是
	// jpg/png，当前只做「获取」时没有 HEVC 解码，优先用 JPEG 缩略图。
	midIsHevc := parsed.Image.HevcMidSize > 0 || parsed.Image.MidHeight == 0
	if key := strings.TrimSpace(parsed.Image.MidURL); key != "" && !midIsHevc {
		if aesKey := strings.TrimSpace(parsed.Image.AesKey); aesKey != "" {
			candidates = append(candidates, imageCandidate{
				Variant:  "mid",
				CDNKey:   key,
				AESKey:   aesKey,
				FileType: 2,
				Length:   parsed.Image.Length,
			})
		}
	}
	if key := strings.TrimSpace(parsed.Image.ThumbURL); key != "" {
		if aesKey := strings.TrimSpace(parsed.Image.ThumbAesKey); aesKey != "" {
			candidates = append(candidates, imageCandidate{
				Variant:  "thumb",
				CDNKey:   key,
				AESKey:   aesKey,
				FileType: 3,
				Length:   parsed.Image.ThumbLength,
			})
		}
	}
	return candidates, md5, nil
}

// normalizeIncomingMD5 只接受 32 位十六进制，非法值返回空（仅用于文件名去重）。
func normalizeIncomingMD5(value string) string {
	value = strings.TrimSpace(value)
	if !imageMD5Regexp.MatchString(value) {
		return ""
	}
	return strings.ToLower(value)
}

// registerIncomingImage 在入站事件推送前登记图片下载元数据，并修正 message 数组
// （docs/architecture.md §3.2）。解析失败不影响事件转发。
func registerIncomingImage(payload map[string]interface{}) {
	if payload == nil {
		return
	}
	if !isIncomingImagePayload(payload) {
		return
	}

	// 先替换 message（即使后续解析失败/缺 message_id），App 需要 image 段才能把
	// 消息渲染成图片气泡；解析失败只影响「能否下载」。
	replaceIncomingImageMessage(payload)

	raw, _ := payload["raw_message"].(string)
	candidates, md5, err := parseIncomingImageXML(raw)
	if err != nil {
		Warn("入站图片 XML 解析失败", "err", err)
		return
	}
	if len(candidates) == 0 {
		Debug("入站图片没有可下载候选，跳过登记")
		return
	}

	messageID := payloadStringValue(payload["message_id"])
	if messageID == "" {
		Debug("入站图片缺少 message_id，跳过登记")
		return
	}

	prunePendingImageJobs()
	pendingImageJobs.Store(messageID, &incomingImageJob{
		MessageID:  messageID,
		MD5:        md5,
		CreatedAt:  time.Now(),
		Candidates: candidates,
	})
	Debug("已登记入站图片", "message_id", messageID, "candidates", len(candidates))
}

// isIncomingImagePayload 判断事件是否图片：msg_type 兼容多种数值类型等于 3；
// 只有事件完全没有 msg_type（旧 hook）时才回退看 raw_message 是否带 <img>。
// 这样 appmsg（49）等卡片里恰好出现 <img 文本时不会被误判成图片。
func isIncomingImagePayload(payload map[string]interface{}) bool {
	if hasPayloadMsgType(payload["msg_type"]) {
		return payloadMsgTypeIsImage(payload["msg_type"])
	}
	raw, _ := payload["raw_message"].(string)
	return containsImageXMLTag(raw)
}

// hasPayloadMsgType 判断事件是否带有有效的消息类型值（nil / 空串 / 0 视为缺失）。
func hasPayloadMsgType(value interface{}) bool {
	switch typed := value.(type) {
	case nil:
		return false
	case string:
		trimmed := strings.TrimSpace(typed)
		return trimmed != "" && trimmed != "0"
	case json.Number:
		return typed.String() != "" && typed.String() != "0"
	case float64:
		return typed != 0
	case float32:
		return typed != 0
	case int:
		return typed != 0
	case int32:
		return typed != 0
	case int64:
		return typed != 0
	case uint:
		return typed != 0
	case uint64:
		return typed != 0
	}
	return true
}

func payloadMsgTypeIsImage(value interface{}) bool {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed) == "3"
	case json.Number:
		return typed.String() == "3"
	case float64:
		return typed == 3
	case float32:
		return typed == 3
	case int:
		return typed == 3
	case int32:
		return typed == 3
	case int64:
		return typed == 3
	case uint:
		return typed == 3
	case uint64:
		return typed == 3
	}
	return false
}

// containsImageXMLTag 只认真正的 <img ...> / <img> / <img/> 标签，避免把正文
// 里恰好出现 "<img" 的文本误判成图片。
func containsImageXMLTag(raw string) bool {
	if raw == "" {
		return false
	}
	offset := 0
	for {
		index := strings.Index(raw[offset:], "<img")
		if index < 0 {
			return false
		}
		pos := offset + index + len("<img")
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

// replaceIncomingImageMessage 把 message 数组里的 [图片]/空文本段替换成一个
// 无 data 的 image 段（放在最前），其它段（如 at）原样保留；message 是字符串时
// 整体替换。payload 类型异常时保持原样，绝不 panic。
func replaceIncomingImageMessage(payload map[string]interface{}) {
	newImageSegment := func() map[string]interface{} {
		return map[string]interface{}{
			"type": "image",
			"data": map[string]interface{}{},
		}
	}

	switch message := payload["message"].(type) {
	case nil:
		payload["message"] = []interface{}{newImageSegment()}
	case string:
		payload["message"] = []interface{}{newImageSegment()}
	case []interface{}:
		kept := make([]interface{}, 0, len(message)+1)
		hasImage := false
		for _, segment := range message {
			segmentMap, ok := segment.(map[string]interface{})
			if !ok {
				kept = append(kept, segment)
				continue
			}
			segmentType, _ := segmentMap["type"].(string)
			if segmentType == "image" {
				hasImage = true
				kept = append(kept, segment)
				continue
			}
			if segmentType == "text" {
				text := ""
				if data, ok := segmentMap["data"].(map[string]interface{}); ok {
					text, _ = data["text"].(string)
				}
				if text == "[图片]" || strings.TrimSpace(text) == "" {
					continue
				}
			}
			kept = append(kept, segment)
		}
		if !hasImage {
			kept = append([]interface{}{newImageSegment()}, kept...)
		}
		payload["message"] = kept
	default:
		// 旧 hook / 异常类型：不猜结构，保持原样。
	}
}

// payloadStringValue 把事件字段（string / json.Number / 数字）转成字符串。
func payloadStringValue(value interface{}) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case json.Number:
		return typed.String()
	case float64:
		return strconv.FormatInt(int64(typed), 10)
	case float32:
		return strconv.FormatInt(int64(typed), 10)
	case int:
		return strconv.Itoa(typed)
	case int32:
		return strconv.FormatInt(int64(typed), 10)
	case int64:
		return strconv.FormatInt(typed, 10)
	case uint:
		return strconv.FormatUint(uint64(typed), 10)
	case uint64:
		return strconv.FormatUint(typed, 10)
	}
	return ""
}

// prunePendingImageJobs 清理过期登记，并在超过总量上限时删除最旧的条目。
func prunePendingImageJobs() {
	now := time.Now()
	type jobEntry struct {
		messageID string
		createdAt time.Time
	}
	alive := make([]jobEntry, 0, pendingImageJobsLimit)
	pendingImageJobs.Range(func(key, value interface{}) bool {
		job, ok := value.(*incomingImageJob)
		if !ok || job == nil || now.Sub(job.CreatedAt) > pendingImageJobTTL {
			pendingImageJobs.Delete(key)
			return true
		}
		messageID, _ := key.(string)
		alive = append(alive, jobEntry{messageID: messageID, createdAt: job.CreatedAt})
		return true
	})
	if len(alive) < pendingImageJobsLimit {
		return
	}
	sort.Slice(alive, func(i, j int) bool { return alive[i].createdAt.Before(alive[j].createdAt) })
	remove := len(alive) - pendingImageJobsLimit + 1
	for i := 0; i < remove && i < len(alive); i++ {
		pendingImageJobs.Delete(alive[i].messageID)
	}
}

// fetchIncomingImage 触发微信下载一条入站图片，解密并保存后返回本地路径。
// 总预算 12s；并发上限 2；先 mid 后 thumb（docs/bridge.md §3.4）。
func fetchIncomingImage(messageID string) (string, error) {
	messageID = strings.TrimSpace(messageID)
	if messageID == "" {
		return "", errImageJobNotFound
	}

	jobValue, ok := pendingImageJobs.Load(messageID)
	if !ok {
		Debug("未找到入站图片登记", "message_id", messageID)
		return "", errImageJobNotFound
	}
	job, ok := jobValue.(*incomingImageJob)
	if !ok || job == nil {
		pendingImageJobs.Delete(messageID)
		return "", errImageJobNotFound
	}

	deadline := time.Now().Add(imageFetchTotalBudget)

	// 全局并发上限 2：拿不到槽最多等 10s。
	select {
	case imageFetchSemaphore <- struct{}{}:
		defer func() { <-imageFetchSemaphore }()
	case <-time.After(imageFetchSemaphoreWait):
		pendingImageJobs.Delete(messageID)
		Warn("图片获取失败", "message_id", messageID, "reason", errImageFetchBusy)
		return "", errImageFetchBusy
	}

	// 抢占该消息的下载任务：同一 message_id 的并发请求只有一个真正下载。
	claimed, ok := pendingImageJobs.LoadAndDelete(messageID)
	if !ok {
		return "", errImageJobNotFound
	}
	job, ok = claimed.(*incomingImageJob)
	if !ok || job == nil {
		return "", errImageJobNotFound
	}

	mediaRoot, err := resolvedMediaDir()
	if err != nil {
		Warn("图片获取失败", "message_id", messageID, "reason", err)
		return "", err
	}
	tempDir := filepath.Join(mediaRoot, ".tmp")
	if err := ensureWithinRoot(mediaRoot, tempDir); err != nil {
		Warn("图片获取失败", "message_id", messageID, "reason", err)
		return "", err
	}
	if err := os.MkdirAll(tempDir, 0o755); err != nil {
		saveErr := fmt.Errorf("创建图片临时目录失败: %w", err)
		Warn("图片获取失败", "message_id", messageID, "reason", saveErr)
		return "", saveErr
	}

	var lastErr error
	for _, candidate := range job.Candidates {
		if !time.Now().Before(deadline) {
			lastErr = errImageDownloadTimeout
			break
		}
		path, err := fetchImageCandidate(job, candidate, mediaRoot, tempDir, deadline)
		if err == nil {
			return path, nil
		}
		lastErr = err
		if errors.Is(err, errBridgeFridaUnavailable) {
			// Frida 不可用时后续候选也一定失败，避免重复报警。
			break
		}
		Debug("图片候选下载失败",
			"message_id", job.MessageID, "variant", candidate.Variant, "reason", err)
	}
	if lastErr == nil {
		lastErr = errImageDownloadTimeout
	}
	Warn("图片获取失败", "message_id", messageID, "reason", lastErr)
	return "", lastErr
}

// fetchImageCandidate 尝试一个下载候选：优先自然分片（必要时触发），分片完整
// （图片自带结束标记）后才解密落盘；不完整时继续等更多分片，避免半张图。
func fetchImageCandidate(job *incomingImageJob, candidate imageCandidate, mediaRoot, tempDir string, deadline time.Time) (string, error) {
	if candidate.CDNKey == "" {
		return "", errors.New("图片下载候选为空")
	}
	budget := imageCandidateBudget
	if remaining := time.Until(deadline); remaining < budget {
		budget = remaining
	}
	if budget <= 0 {
		return "", errImageDownloadTimeout
	}
	candidateDeadline := time.Now().Add(budget)

	tempPath := filepath.Join(tempDir, "fetch-"+randomHex(8))
	if err := ensureWithinRoot(mediaRoot, tempPath); err != nil {
		return "", err
	}
	defer func() { _ = os.Remove(tempPath) }()

	// 不要删除同名 CDN key 的分片：微信收到图片后常常已经开始自然下载，
	// 删掉会把已经到达的数据丢弃（真机 2026-10-23 即因此失败）。
	seqBefore := currentDownloadSeq()

	graceDeadline := time.Now().Add(imageNaturalGraceWindow)
	if candidateDeadline.Before(graceDeadline) {
		graceDeadline = candidateDeadline
	}
	media, mediaKey, ok := waitForImageMedia(candidate.CDNKey, candidate.Length, seqBefore, graceDeadline)
	lastLen := 0
	if ok {
		if path, err := saveDecryptedCandidate(job, candidate, media, mediaRoot); err == nil {
			return path, nil
		} else if !errors.Is(err, errImageIncomplete) {
			return "", err
		}
		lastLen = len(media)
	}

	// 没有自然分片时才主动触发；已有分片（哪怕不完整）绝不触发，
	// 否则自然下载与触发会共用同一 CDN key，分片重复追加导致图片尾部损坏。
	triggerErr := error(nil)
	if lastLen == 0 && !hasImageMedia(candidate.CDNKey) {
		triggered, err := triggerIncomingImageDownload(job, candidate, tempPath)
		if err != nil {
			Debug("图片下载触发失败，继续等待微信自然下载",
				"message_id", job.MessageID, "variant", candidate.Variant, "reason", err)
			triggerErr = err
		} else {
			switch strings.ToLower(strings.TrimSpace(fmt.Sprint(triggered))) {
			case "", "fail", "0":
				Debug("图片下载触发被拒绝，继续等待微信自然下载",
					"message_id", job.MessageID, "variant", candidate.Variant)
				triggerErr = errImageTriggerRejected
			}
		}
	}
	// 触发后重新按「候选 key + 规范化兜底」找一次，确定实际数据落在哪个 key。
	if mediaKey == "" {
		media, mediaKey, ok = waitForImageMedia(candidate.CDNKey, candidate.Length, seqBefore, candidateDeadline)
		if ok {
			if path, err := saveDecryptedCandidate(job, candidate, media, mediaRoot); err == nil {
				return path, nil
			} else if !errors.Is(err, errImageIncomplete) {
				return "", err
			}
			lastLen = len(media)
		}
	}
	if mediaKey != "" {
		candidate.CDNKey = mediaKey
	}

	// 分片不完整（例如传了一半）时，不落盘，继续等数据增长到 deadline。
	for time.Now().Before(candidateDeadline) {
		minSize := lastLen + 1
		media, ok = waitForImageMediaGrowth(candidate.CDNKey, candidate.Length, minSize, candidateDeadline)
		if !ok {
			break
		}
		if path, err := saveDecryptedCandidate(job, candidate, media, mediaRoot); err == nil {
			return path, nil
		} else if !errors.Is(err, errImageIncomplete) {
			return "", err
		}
		if len(media) <= lastLen {
			break
		}
		lastLen = len(media)
	}
	if triggerErr != nil && !errors.Is(triggerErr, errBridgeFridaUnavailable) && lastLen == 0 {
		return "", triggerErr
	}
	return "", errImageIncomplete
}

// saveDecryptedCandidate 解密并落盘一个候选的数据；失败返回可读错误。
func saveDecryptedCandidate(job *incomingImageJob, candidate imageCandidate, cipherData []byte, mediaRoot string) (string, error) {
	plain, err := decryptImageBytes(cipherData, candidate.AESKey, candidate.Length)
	if err != nil {
		return "", err
	}
	ext := strings.ToLower(DetectFileFormat(plain))
	if !isSupportedImageExt(ext) {
		return "", errImageUnsupportedFormat
	}

	path, err := saveIncomingImage(mediaRoot, plain, job.MD5, ext, candidate.Variant)
	if err != nil {
		return "", err
	}
	Info("图片获取成功", "message_id", job.MessageID, "bytes", len(plain), "variant", candidate.Variant)
	return path, nil
}

// waitForImageMedia 在 deadline 内等待候选分片出现。返回实际命中的 key，
// 便于调用方在 key 被规范化后用同一个 key 继续等待增长。
//   - 优先按候选 CDNKey 命中；
//   - 等待 imageDownloadFallbackAfter 后仍无命中时，允许用「本次等待开始后新出现的
//     下载 key」兜底（真机 key 可能被规范化，与 XML 里的 key 不同）。
func waitForImageMedia(cdnKey string, plainLength int, seqBefore int64, deadline time.Time) ([]byte, string, bool) {
	startedAt := time.Now()
	fallbackKey := ""
	expected := expectedCipherLength(plainLength)

	for {
		if media, done := snapshotImageDownload(cdnKey, expected, 0); done {
			return media, cdnKey, true
		}
		if fallbackKey == "" && time.Since(startedAt) >= imageDownloadFallbackAfter {
			if key, ok := latestDownloadAfter(seqBefore); ok && key != cdnKey {
				fallbackKey = key
			}
		}
		if fallbackKey != "" {
			if media, done := snapshotImageDownload(fallbackKey, expected, 0); done {
				return media, fallbackKey, true
			}
		}
		if !time.Now().Before(deadline) {
			return nil, "", false
		}
		time.Sleep(imageDownloadPollEvery)
	}
}

// waitForImageMediaGrowth 等待某个 key 的数据增长到至少 minSize 并稳定/达到预期长度。
func waitForImageMediaGrowth(cdnKey string, plainLength, minSize int, deadline time.Time) ([]byte, bool) {
	expected := expectedCipherLength(plainLength)
	for {
		if media, done := snapshotImageDownload(cdnKey, expected, minSize); done {
			return media, true
		}
		if !time.Now().Before(deadline) {
			return nil, false
		}
		time.Sleep(imageDownloadPollEvery)
	}
}

// hasImageMedia 表示该 CDN key 已经有任意分片到达（不要求已完成）。
func hasImageMedia(cdnKey string) bool {
	if cdnKey == "" {
		return false
	}
	value, ok := userID2FileMsgMap.Load(cdnKey)
	if !ok {
		return false
	}
	req, ok := value.(*DownloadRequest)
	if !ok || req == nil {
		return false
	}
	req.mu.Lock()
	defer req.mu.Unlock()
	return len(req.Media) > 0
}

// snapshotImageDownload 读取一次下载分片快照；done 表示数据已达到完成判定。
func snapshotImageDownload(cdnKey string, expected, minSize int) ([]byte, bool) {
	if cdnKey == "" {
		return nil, false
	}
	value, ok := userID2FileMsgMap.Load(cdnKey)
	if !ok {
		return nil, false
	}
	req, ok := value.(*DownloadRequest)
	if !ok || req == nil {
		return nil, false
	}

	now := time.Now().UnixMilli()
	req.mu.Lock()
	defer req.mu.Unlock()

	size := len(req.Media)
	if size == 0 || size < minSize {
		return nil, false
	}
	stable := now-req.LastAppendTime >= imageDownloadStableAfter.Milliseconds()
	enough := expected > 0 && size >= expected
	if !stable && !enough {
		return nil, false
	}
	media := make([]byte, size)
	copy(media, req.Media)
	return media, true
}

// expectedCipherLength 估算下载密文长度：明文字节数向上取整到 16 字节
// （PKCS#7 已包含在明文长度之外的那部分补齐里，不再额外加一个块；
// 加一个块会让完成判定永远达不到，进而诱发重复触发/重复追加）。
func expectedCipherLength(plainLength int) int {
	if plainLength <= 0 {
		return 0
	}
	return (plainLength + aes.BlockSize - 1) / aes.BlockSize * aes.BlockSize
}

// decryptImageBytes 把下载到的数据还原成明文图片。
//
//   - 先按明文试：以 JPEG/PNG/GIF/WEBP/BMP 魔数开头直接使用（encryver=0 常见）；
//   - 否则按 AES-ECB 逐块解密（key 支持 32 位十六进制 / 16 字节原始 / 32 字节
//     ASCII），数据长度非 16 倍数时末尾补 0（与 utils.go 的下载解密一致）；
//   - 按 XML 里的明文 length 截断；
//   - 只接受 jpg/png/gif/webp/bmp，否则该候选失败。
func decryptImageBytes(data []byte, aesKey string, plainLength int) ([]byte, error) {
	if len(data) == 0 {
		return nil, errors.New("图片数据为空")
	}

	if ext := DetectFileFormat(data); isSupportedImageExt(ext) {
		trimmed, ok := trimImageToEnd(data, ext)
		if !ok {
			return nil, errImageIncomplete
		}
		return trimmed, nil
	}

	key, err := parseImageAESKey(aesKey)
	if err != nil {
		return nil, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, errImageDecryptFailed
	}

	blockSize := block.BlockSize()
	aligned := data
	if remainder := len(aligned) % blockSize; remainder != 0 {
		padded := make([]byte, len(aligned)+blockSize-remainder)
		copy(padded, aligned)
		aligned = padded
	}
	if len(aligned) == 0 {
		return nil, errImageDecryptFailed
	}

	decrypted := make([]byte, len(aligned))
	for offset := 0; offset < len(aligned); offset += blockSize {
		block.Decrypt(decrypted[offset:offset+blockSize], aligned[offset:offset+blockSize])
	}

	ext := DetectFileFormat(decrypted)
	if !isSupportedImageExt(ext) {
		return nil, errImageDecryptFailed
	}
	// XML 里的 length / cdnthumblength 并不总是可靠的真实明文长度，按它截断
	// 会把 JPEG 的 EOI 尾部切掉（真机 2026-10-23 显示半张图）。改为按图片
	// 自身结束标记裁齐，多余的是 AES 补齐字节。
	trimmed, ok := trimImageToEnd(decrypted, ext)
	if !ok {
		return nil, errImageIncomplete
	}
	return trimmed, nil
}

// trimImageToEnd 按图片格式的结束标记裁掉 AES 补齐字节；找不到结束标记说明
// 数据尚未下载完整（返回 ok=false，调用方继续等待更多分片）。
func trimImageToEnd(data []byte, ext string) ([]byte, bool) {
	switch strings.ToLower(ext) {
	case "jpg", "jpeg":
		idx := bytes.LastIndex(data, []byte{0xFF, 0xD9})
		if idx < 0 {
			return nil, false
		}
		return data[:idx+2], true
	case "png":
		idx := bytes.LastIndex(data, []byte("IEND"))
		if idx < 0 || idx+8 > len(data) {
			return nil, false
		}
		return data[:idx+8], true
	case "gif":
		idx := bytes.LastIndexByte(data, 0x3B)
		if idx < 0 {
			return nil, false
		}
		return data[:idx+1], true
	case "webp":
		if len(data) < 12 {
			return nil, false
		}
		size := int(data[4]) | int(data[5])<<8 | int(data[6])<<16 | int(data[7])<<24
		end := size + 8
		if end <= 0 || end > len(data) {
			return nil, false
		}
		return data[:end], true
	case "bmp":
		if len(data) < 6 {
			return nil, false
		}
		size := int(data[2]) | int(data[3])<<8 | int(data[4])<<16 | int(data[5])<<24
		if size <= 0 || size > len(data) {
			return nil, false
		}
		return data[:size], true
	default:
		return data, true
	}
}

// parseImageAESKey 依次尝试：32 位十六进制 → 16 字节原始 → 32 字节 ASCII。
func parseImageAESKey(raw string) ([]byte, error) {
	key := strings.TrimSpace(raw)
	if key == "" {
		return nil, errors.New("图片缺少解密密钥")
	}
	if len(key) == 32 {
		if decoded, err := hex.DecodeString(key); err == nil {
			return decoded, nil
		}
	}
	if len(key) == 16 || len(key) == 32 {
		return []byte(key), nil
	}
	return nil, errors.New("图片解密密钥格式不支持")
}

// clipImagePlaintext 按 XML 的明文长度截断；length<=0 或大于数据长度时忽略。
func clipImagePlaintext(data []byte, plainLength int) []byte {
	if plainLength > 0 && plainLength <= len(data) {
		return data[:plainLength]
	}
	return data
}

// isCompleteImage 检查图片尾部是否完整；不完整的 JPEG（缺 EOI）在界面上会显示成
// 半张图/灰块，必须等下载完成后再落盘。
func isCompleteImage(data []byte, ext string) bool {
	switch strings.ToLower(ext) {
	case "jpg", "jpeg":
		idx := bytes.LastIndex(data, []byte{0xFF, 0xD9})
		return idx >= 0 && len(data)-idx <= 32
	case "png":
		return bytes.Contains(data[len(data)-minInt(len(data), 32):], []byte("IEND"))
	case "gif":
		return len(data) > 0 && data[len(data)-1] == 0x3B
	case "webp":
		if len(data) < 12 || !bytes.Equal(data[8:12], []byte("WEBP")) {
			return false
		}
		size := int(data[4]) | int(data[5])<<8 | int(data[6])<<16 | int(data[7])<<24
		return size+8 <= len(data)
	default:
		return true
	}
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func isSupportedImageExt(ext string) bool {
	switch strings.ToLower(ext) {
	case "jpg", "png", "gif", "webp", "bmp":
		return true
	}
	return false
}

// saveIncomingImage 保存到 <mediaDir>/<yyyy-MM-dd>/<md5>.<ext>；
// 缩略图回退（variant=thumb）时加 `-thumb` 后缀，避免与同一张图的高清版本互相覆盖。
// md5 非法时用 fetched-<UnixMilli>-<rand>.<ext>。同名同大小文件直接复用。
// 写入前用 filepath.Rel 校验仍在 mediaDir 内。
func saveIncomingImage(mediaRoot string, plain []byte, md5 string, ext string, variant string) (string, error) {
	dayDir := filepath.Join(mediaRoot, time.Now().Format("2006-01-02"))
	if err := ensureWithinRoot(mediaRoot, dayDir); err != nil {
		return "", err
	}
	if err := os.MkdirAll(dayDir, 0o755); err != nil {
		return "", fmt.Errorf("创建图片日期目录失败: %w", err)
	}

	name := ""
	if normalized := normalizeIncomingMD5(md5); normalized != "" {
		base := normalized
		if variant == "thumb" {
			base += "-thumb"
		}
		name = base + "." + ext
	} else {
		name = fmt.Sprintf("fetched-%d-%s.%s", time.Now().UnixMilli(), randomHex(4), ext)
	}
	path := filepath.Join(dayDir, name)
	if err := ensureWithinRoot(mediaRoot, path); err != nil {
		return "", err
	}

	if info, err := os.Stat(path); err == nil && info.Size() == int64(len(plain)) {
		return path, nil
	}
	if err := os.WriteFile(path, plain, 0o644); err != nil {
		return "", fmt.Errorf("保存图片失败: %w", err)
	}
	return path, nil
}

// randomHex 生成 n 字节随机数的十六进制串（仅用于临时文件名）。
func randomHex(n int) string {
	if n <= 0 {
		n = 4
	}
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return fmt.Sprintf("%x", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf)
}
