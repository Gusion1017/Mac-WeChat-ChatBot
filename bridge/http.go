package main

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"runtime/debug"
	"strings"
	"time"
)

func sendHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "仅支持 POST", http.StatusMethodNotAllowed)
		Error("仅支持 POST")
		return
	}

	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if config.OnebotToken == "" || token == "" || !hmac.Equal([]byte(token), []byte(config.OnebotToken)) {
		http.Error(w, "未授权", http.StatusUnauthorized)
		Error("未授权")
		return
	}

	req := new(SendRequest)
	if err := json.NewDecoder(r.Body).Decode(req); err != nil {
		http.Error(w, "无效的 JSON", http.StatusBadRequest)
		Error("无效的 JSON")
		return
	}

	// 参数校验
	if len(req.Message) == 0 || (req.UserID == "" && req.GroupID == "") {
		http.Error(w, "参数缺失", http.StatusBadRequest)
		Error("参数缺失")
		return
	}

	sendContent := ""
	atUserID := ""
	var resultChans []chan error
	var voiceDurations []int
	for _, v := range req.Message {
		if v.Type == "text" {
			sendContent += v.Data.Text
		} else if v.Type == "at" {
			// 群成员缓存未命中时回退通讯录昵称（docs/architecture.md §3）。
			if nickname, ok := resolveAtNickname(req.GroupID, v.Data.QQ); ok {
				sendContent += fmt.Sprintf("@%s\u2005", nickname)
				atUserID += v.Data.QQ + ","
			}

		} else if (v.Type == "voice" || v.Type == "record") && v.Data != nil && strings.TrimSpace(v.Data.PCM16K) != "" {
			// 语音发送契约（_local/voice-impl-spec.md §3.3）：优先复用
			// /send_private_msg 的 voice 段，data.pcm16k 是 base64 的 16k 单声道 s16le
			// PCM，bridge 用 go-silk 编码 Tencent SILK（不依赖 ffmpeg/pilk）。
			// Hook 未支持语音发送时返回 {"ok":false,"error":"voice_send_unsupported"}，
			// App 据此自动降级为文字；语音段同步处理，不经过发送 worker。
			durationMs, voiceErr := sendVoicePCM16k(req.UserID, req.GroupID, v.Data.PCM16K, v.Data.DurationMs)
			if voiceErr != nil {
				writeVoiceJSON(w, http.StatusOK, map[string]any{
					"ok":    false,
					"error": voiceSendErrorCode(voiceErr),
				})
				return
			}
			voiceDurations = append(voiceDurations, durationMs)
		} else if v.Type == "image" || v.Type == "video" || v.Type == "record" || v.Type == "voice" || v.Type == "file" {
			msgType := v.Type
			if msgType == "record" || msgType == "voice" {
				msgType = "voice"
			}
			// file: 走 iPad860 风格 uploadappattach 直传(不走 CDN)
			if msgType == "file" {
				msgType = "send_file_simple"
			}
			ch := make(chan error, 1)
			msg := &SendMsg{
				UserId:     req.UserID,
				GroupID:    req.GroupID,
				Content:    v.Data.File,
				Type:       msgType,
				ResultChan: ch,
			}
			msgChan <- msg
			resultChans = append(resultChans, ch)
		} else if v.Type == "pat" {
			// 拍一拍：群聊 data.qq 是群内被拍成员；私聊默认拍会话对方。
			target := ""
			if v.Data != nil {
				target = v.Data.QQ
			}
			if target == "" && req.GroupID == "" {
				target = req.UserID
			}
			if target == "" {
				Error("拍一拍目标为空")
				continue
			}
			ch := make(chan error, 1)
			msgChan <- &SendMsg{
				UserId:     target,
				GroupID:    req.GroupID,
				Type:       "pat",
				ResultChan: ch,
			}
			resultChans = append(resultChans, ch)
		} else if v.Type == "reply" {
			if v.Data.ReplyMessage == nil {
				Error("reply_message为空")
				continue
			}
			rm := v.Data.ReplyMessage

			// 顶层没有group_id时，从reply_message中取
			if req.GroupID == "" && rm.GroupId != "" {
				req.GroupID = rm.GroupId
			}

			// 提取被回复消息的内容
			referContent := ""
			referMsgType := 1 // 默认text
			if len(rm.Message) > 0 {
				switch rm.Message[0].Type {
				case "text":
					referContent = rm.Message[0].Data.Text
					referMsgType = 1
				case "image":
					referMsgType = 3
				case "video":
					referMsgType = 43
				case "file":
					referMsgType = 49
				}
			}

			// 提取发送者昵称
			displayName := ""
			if rm.Sender != nil {
				displayName = rm.Sender.Nickname
			}

			// msgsource需要JSON unescape（双重编码: \\u003c → \u003c → <）
			msgsource := jsonUnescapeString(rm.MsgResource)

			ch := make(chan error, 1)
			msgChan <- &SendMsg{
				UserId:           req.UserID,
				GroupID:          req.GroupID,
				Content:          v.Data.Text,
				Type:             "reply",
				ReferMsgId:       rm.MessageId,
				ReferMsgSender:   rm.UserID,
				ReferMsgType:     referMsgType,
				ReferCreateTime:  rm.Time,
				ReferMsgsource:   msgsource,
				ReferDisplayName: displayName,
				ReferContent:     referContent,
				ResultChan:       ch,
			}
			resultChans = append(resultChans, ch)
		}
	}

	if sendContent != "" {
		ch := make(chan error, 1)
		msgChan <- &SendMsg{
			UserId:     req.UserID,
			GroupID:    req.GroupID,
			Content:    sendContent,
			Type:       "text",
			AtUser:     strings.TrimRight(atUserID, ","),
			ResultChan: ch,
		}
		resultChans = append(resultChans, ch)
	}

	// 等待所有消息发送完成
	for _, ch := range resultChans {
		if err := <-ch; err != nil {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusInternalServerError)
			json.NewEncoder(w).Encode(map[string]any{
				"status": "failed",
				"error":  err.Error(),
			})
			return
		}
	}

	// 只含语音段的请求：语音已同步处理完（编码/上传触发），按 §3.3 的
	// {ok:true,duration_ms} 响应；若同一请求还带文本段，文本仍走上面的 worker。
	if len(voiceDurations) > 0 {
		writeVoiceJSON(w, http.StatusOK, map[string]any{
			"ok":          true,
			"status":      "ok",
			"duration_ms": voiceDurations[len(voiceDurations)-1],
		})
		return
	}

	json.NewEncoder(w).Encode(map[string]any{
		"status": "ok",
	})
}

// fetchImageRequest 是 POST /fetch_image 的请求体。
type fetchImageRequest struct {
	MessageID string `json:"message_id"`
}

// fetchImageHandler 处理 App 的入站图片获取请求（docs/bridge.md §3.4）：
// 鉴权与 sendHandler 一致；参数缺失/未登记 400、下载失败 502、成功 200。
// 响应与日志都不包含 aeskey / CDN file key / 完整 XML。
func fetchImageHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeFetchImageResponse(w, http.StatusMethodNotAllowed, map[string]any{
			"status": "failed",
			"error":  "仅支持 POST",
		})
		Error("图片获取仅支持 POST")
		return
	}

	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if config.OnebotToken == "" || token == "" || !hmac.Equal([]byte(token), []byte(config.OnebotToken)) {
		writeFetchImageResponse(w, http.StatusUnauthorized, map[string]any{
			"status": "failed",
			"error":  "未授权",
		})
		Error("图片获取未授权")
		return
	}

	var req fetchImageRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeFetchImageResponse(w, http.StatusBadRequest, map[string]any{
			"status": "failed",
			"error":  "无效的 JSON",
		})
		Error("图片获取请求 JSON 无效")
		return
	}
	req.MessageID = strings.TrimSpace(req.MessageID)
	if req.MessageID == "" {
		writeFetchImageResponse(w, http.StatusBadRequest, map[string]any{
			"status": "failed",
			"error":  "参数缺失",
		})
		Error("图片获取请求参数缺失")
		return
	}

	path, err := fetchIncomingImage(req.MessageID)
	if err != nil {
		status := http.StatusBadGateway
		if errors.Is(err, errImageJobNotFound) {
			status = http.StatusBadRequest
		}
		writeFetchImageResponse(w, status, map[string]any{
			"status": "failed",
			"error":  err.Error(),
		})
		return
	}

	fileURL := (&url.URL{Scheme: "file", Path: path}).String()
	writeFetchImageResponse(w, http.StatusOK, map[string]any{
		"status": "ok",
		"data": map[string]any{
			"file":       fileURL,
			"message_id": req.MessageID,
		},
	})
}

// writeFetchImageResponse 输出 JSON 响应。
func writeFetchImageResponse(w http.ResponseWriter, status int, payload map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func SendHttpReq(jsonData []byte) {
	defer func() {
		if r := recover(); r != nil {
			Error("http panic", "err", r, "stack", string(debug.Stack()))
		}
	}()

	// 事件推送不节流：入站事件需要立即 POST，send_interval 只约束真正
	// 发往微信的消息（worker.go SendWechatMsg）。
	jsonReq, err := HandleMsg(jsonData)
	if err != nil {
		Error("JSON 序列化失败", "err", err)
		return
	}
	if jsonReq == nil {
		return
	}

	logEventDebug("发送数据", jsonReq)
	req, err := http.NewRequest("POST", config.SendURL, bytes.NewBuffer(jsonReq))
	if err != nil {
		Error("创建请求失败", "err", err)
		return
	}

	// 5. 设置 Header (OneBot 接口通常要求 application/json)
	h := hmac.New(sha1.New, []byte(config.OnebotToken))
	h.Write(jsonReq)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Signature", "sha1="+hex.EncodeToString(h.Sum(nil)))

	client := &http.Client{
		Timeout: 10 * time.Second,
	}
	// 6. 执行请求
	resp, err := client.Do(req)
	if err != nil {
		Error("请求执行失败", "err", err)
		return
	}
	defer resp.Body.Close()

	// 7. 读取返回结果
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		Error("读取响应失败", "err", err)
		return
	}

	Info("返回内容", "status", resp.StatusCode, "body", string(body))
}

// jsonUnescapeString 对双重JSON编码的字符串做unescape
// 例如: \\u003c → \u003c (第一次json.Unmarshal) → < (本函数)
func jsonUnescapeString(s string) string {
	if s == "" {
		return s
	}
	var result string
	if err := json.Unmarshal([]byte(`"`+s+`"`), &result); err != nil {
		return s
	}
	return result
}

// getFileExt 从文件名中提取扩展名(不含.)
func getFileExt(fileName string) string {
	idx := strings.LastIndex(fileName, ".")
	if idx == -1 || idx == len(fileName)-1 {
		return ""
	}
	return fileName[idx+1:]
}

// extractFileName 从路径或URL中提取文件名
func extractFileName(s string) string {
	if s == "" {
		return ""
	}
	// 跳过 base64 数据
	if strings.HasPrefix(s, "base64://") || strings.Contains(s, ";base64,") {
		return ""
	}
	// URL 路径
	if strings.HasPrefix(s, "http://") || strings.HasPrefix(s, "https://") || strings.HasPrefix(s, "file://") {
		if u, err := url.Parse(s); err == nil {
			p := u.Path
			if idx := strings.LastIndex(p, "/"); idx != -1 {
				return p[idx+1:]
			}
			return p
		}
	}
	// 本地文件路径
	if strings.Contains(s, "/") || strings.Contains(s, "\\") {
		if idx := strings.LastIndexAny(s, "/\\"); idx != -1 {
			return s[idx+1:]
		}
	}
	return s
}
