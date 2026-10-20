package main

import "encoding/json"

// HandleIncomingMessage receives a normalized OneBot event produced by the
// Frida Message-finalizer hook (hook/script.js) and pushes it to the configured
// OneBot transport. This bypasses the 4.1.15 buf2resp path, which no longer
// carries ordinary incoming messages.
func HandleIncomingMessage(payload map[string]interface{}) {
	normalizeIncomingIdentity(payload, myWechatId)

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

// normalizeIncomingIdentity 修正 hook 事件的账号/方向字段。
//
// hook 只能看到 Message 的 from/to：对**本账号发出**的私聊消息，
// from=自己、to=对方，而它过去把 self_id 写成 to，于是 App 把这个事件当成
// 「对方发来的」，并按 user_id(=自己) 建出一个「自己 wxid」的会话——这正是
// 私聊消息出现在错误会话里的根因。bridge 知道当前账号（myWechatId），
// 因此在这里统一改写：
//
//   - 入站：self_id = 自己，user_id = 发送者（好友/群成员），方向不变；
//   - 自消息·私聊：is_self=true，self_id = 自己，user_id/sender = 自己，
//     target_id = 对方；App 据此把它记进**对方会话**并标为 outgoing；
//   - 自消息·群聊：is_self=true，self_id/user_id = 自己，target_id = 群 ID；
//   - 拍一拍/系统 appmsg 的 from/to 都可能是群 ID，sender_wxid 不是自己时
//     保持入站语义，避免误判成自消息。
//
// selfID 为空（老 bridge / 无 -self_id / image_path 无法推导）时保持旧行为，
// 不猜测方向，App 侧有历史回放/修复兜底。
func normalizeIncomingIdentity(payload map[string]interface{}, selfID string) {
	if payload == nil || selfID == "" {
		return
	}
	payload["self_id"] = selfID

	groupID, _ := payload["group_id"].(string)
	from, _ := payload["from_wxid"].(string)
	to, _ := payload["to_wxid"].(string)
	sender, _ := payload["sender_wxid"].(string)
	if sender == "" {
		sender = from
	}

	if sender != selfID {
		// 入站：不要留下旧的 is_self（重放/重试时 map 可能被复用）。
		delete(payload, "is_self")
		return
	}

	payload["is_self"] = true
	payload["sender"] = map[string]interface{}{
		"user_id":  selfID,
		"nickname": selfID,
	}
	// user_id 保持 OneBot 语义（发送者＝自己）；会话目标单独放 target_id。
	// App 旧的 self_id==user_id 判定对群自消息仍然成立，私聊自消息则用 target_id
	// 落进对方会话，不会再把消息记进「自己 wxid」的会话。
	if groupID != "" {
		payload["target_id"] = groupID
		payload["message_type"] = "group"
		return
	}
	payload["message_type"] = "private"
	if to != "" {
		payload["target_id"] = to
	}
}
