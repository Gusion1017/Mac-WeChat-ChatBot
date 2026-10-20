package main

import "encoding/json"

// HandleIncomingMessage receives a normalized OneBot event produced by the
// Frida Message-finalizer hook (hook/script.js) and pushes it to the configured
// OneBot transport. This bypasses the 4.1.15 buf2resp path, which no longer
// carries ordinary incoming messages.
func HandleIncomingMessage(payload map[string]interface{}) {
	if self, ok := payload["self_id"].(string); !ok || self == "" {
		if myWechatId != "" {
			payload["self_id"] = myWechatId
		}
	}
	data, err := json.Marshal(payload)
	if err != nil {
		Error("入站消息序列化失败", "err", err)
		return
	}
	Info("收到入站消息事件", "data_len", len(data))
	if config.ConnType == "http" {
		SendHttpReq(data)
	} else {
		SendWebSocketMsg(data)
	}
}
