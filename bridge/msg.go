package main

import (
	"encoding/json"
	"sync"
	"sync/atomic"
	"time"
)

// downloadSeq / latestDownload 记录最近一次「全新 CDN 下载」的首个 key 与代次。
// 入站图片获取（media.go）在触发下载前记下代次，1 秒内 XML 里的 CDN key 没有
// 命中时，用触发后新出现的下载 key 兜底——真机 CDN 任务里的 key 可能被规范化。
var downloadSeq int64

var latestDownload struct {
	mu  sync.Mutex
	seq int64
	key string
}

// recordLatestDownload 在一个下载 key 的首个分片到达时推进代次。
func recordLatestDownload(cdnKey string) {
	seq := atomic.AddInt64(&downloadSeq, 1)
	latestDownload.mu.Lock()
	latestDownload.seq = seq
	latestDownload.key = cdnKey
	latestDownload.mu.Unlock()
}

// latestDownloadAfter 返回代次大于 seq 的最近一次下载 key。
func latestDownloadAfter(seq int64) (string, bool) {
	latestDownload.mu.Lock()
	defer latestDownload.mu.Unlock()
	if latestDownload.seq > seq && latestDownload.key != "" {
		return latestDownload.key, true
	}
	return "", false
}

// currentDownloadSeq 返回当前下载代次。
func currentDownloadSeq() int64 {
	return atomic.LoadInt64(&downloadSeq)
}

func cleanExpiredDownloads() {
	ticker := time.NewTicker(1 * time.Hour)
	for range ticker.C {
		now := time.Now().UnixMilli()
		userID2FileMsgMap.Range(func(key, value any) bool {
			req := value.(*DownloadRequest)
			req.mu.Lock()
			expired := now-req.LastAppendTime > 24*60*60*1000
			req.mu.Unlock()
			if expired {
				userID2FileMsgMap.Delete(key)
			}
			return true
		})
	}
}

func Download(rawMsg []byte) error {
	downloadReq := new(DownloadRequest)
	err := json.Unmarshal(rawMsg, downloadReq)
	if err != nil {
		Error("JSON解析失败", "err", err)
		return err
	}

	// 隐私红线：file_id 里可能带当前账号，日志只保留长度。
	Info("下载文件", "media_len", len(downloadReq.Media))

	// LoadOrStore 保证同一 CDNURL 只建一份，消除 Load+Store 之间的竞态。
	// 首个分片直接作为占位存入，后续分片走 append 分支。
	actual, loaded := userID2FileMsgMap.LoadOrStore(downloadReq.CDNURL, downloadReq)
	req := actual.(*DownloadRequest)

	req.mu.Lock()
	defer req.mu.Unlock()

	if !loaded {
		// 本次就是首个分片（downloadReq 已被存入），只更新时间戳，
		// 并记录下载代次供入站图片获取做「触发后新下载」匹配。
		req.LastAppendTime = time.Now().UnixMilli()
		recordLatestDownload(downloadReq.CDNURL)
		return nil
	}

	if req.FilePath != "" {
		return nil
	}
	if time.Now().UnixMilli()-req.LastAppendTime > 10000000 {
		// 距上次追加过久，视为新文件，重置数据
		req.Media = append(req.Media[:0], downloadReq.Media...)
	} else {
		req.Media = append(req.Media, downloadReq.Media...)
	}
	req.LastAppendTime = time.Now().UnixMilli()

	return nil
}
