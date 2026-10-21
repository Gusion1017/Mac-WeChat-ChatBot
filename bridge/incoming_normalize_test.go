package main

import (
	"encoding/json"
	"testing"
)

func TestNormalizeIncomingIdentitySelfPrivate(t *testing.T) {
	payload := map[string]interface{}{
		"group_id":     "",
		"self_id":      "wxid_friend",
		"user_id":      "wxid_bot",
		"from_wxid":    "wxid_bot",
		"to_wxid":      "wxid_friend",
		"sender_wxid":  "wxid_bot",
		"message_type": "private",
	}
	normalizeIncomingIdentity(payload, "wxid_bot")

	if payload["self_id"] != "wxid_bot" {
		t.Fatalf("self_id 未修正: %#v", payload["self_id"])
	}
	if payload["user_id"] != "wxid_bot" {
		t.Fatalf("自消息 user_id 应保持发送者自己: %#v", payload["user_id"])
	}
	if payload["target_id"] != "wxid_friend" {
		t.Fatalf("自消息 target_id 应为对方: %#v", payload["target_id"])
	}
	if payload["is_self"] != true {
		t.Fatalf("自消息未标记 is_self: %#v", payload["is_self"])
	}
	sender, ok := payload["sender"].(map[string]interface{})
	if !ok || sender["user_id"] != "wxid_bot" {
		t.Fatalf("sender 未改写为自己: %#v", payload["sender"])
	}
}

func TestNormalizeIncomingIdentityIncomingPrivate(t *testing.T) {
	payload := map[string]interface{}{
		"group_id":    "",
		"self_id":     "wxid_bot",
		"user_id":     "wxid_friend",
		"from_wxid":   "wxid_friend",
		"to_wxid":     "wxid_bot",
		"sender_wxid": "wxid_friend",
	}
	normalizeIncomingIdentity(payload, "wxid_bot")

	if _, exists := payload["is_self"]; exists {
		t.Fatalf("入站消息不应带 is_self: %#v", payload["is_self"])
	}
	if payload["self_id"] != "wxid_bot" || payload["user_id"] != "wxid_friend" {
		t.Fatalf("入站身份被改写: self_id=%#v user_id=%#v", payload["self_id"], payload["user_id"])
	}
}

func TestNormalizeIncomingIdentitySelfGroup(t *testing.T) {
	payload := map[string]interface{}{
		"group_id":     "123@chatroom",
		"self_id":      "123@chatroom",
		"user_id":      "wxid_bot",
		"from_wxid":    "123@chatroom",
		"to_wxid":      "wxid_bot",
		"sender_wxid":  "wxid_bot",
		"message_type": "group",
	}
	normalizeIncomingIdentity(payload, "wxid_bot")

	if payload["is_self"] != true || payload["self_id"] != "wxid_bot" || payload["user_id"] != "wxid_bot" {
		t.Fatalf("群自消息归一化错误: %#v", payload)
	}
	if payload["target_id"] != "123@chatroom" {
		t.Fatalf("群自消息 target_id 错误: %#v", payload["target_id"])
	}
	if payload["group_id"] != "123@chatroom" {
		t.Fatalf("群 ID 被改写: %#v", payload["group_id"])
	}
}

func TestNormalizeIncomingIdentityGroupIncoming(t *testing.T) {
	payload := map[string]interface{}{
		"group_id":    "123@chatroom",
		"self_id":     "wxid_bot",
		"user_id":     "wxid_member",
		"from_wxid":   "123@chatroom",
		"to_wxid":     "wxid_bot",
		"sender_wxid": "wxid_member",
	}
	normalizeIncomingIdentity(payload, "wxid_bot")

	if _, exists := payload["is_self"]; exists {
		t.Fatalf("群入站消息不应带 is_self: %#v", payload["is_self"])
	}
	if payload["user_id"] != "wxid_member" {
		t.Fatalf("群成员被改写: %#v", payload["user_id"])
	}
}

// 拍一拍 appmsg 的 from/to 都是群 ID；没有真实 sender_wxid 时不能被当成自消息。
func TestNormalizeIncomingIdentityPatIsNotSelf(t *testing.T) {
	payload := map[string]interface{}{
		"group_id":  "123@chatroom",
		"self_id":   "123@chatroom",
		"user_id":   "123@chatroom",
		"from_wxid": "123@chatroom",
		"to_wxid":   "123@chatroom",
	}
	normalizeIncomingIdentity(payload, "wxid_bot")

	if _, exists := payload["is_self"]; exists {
		t.Fatalf("拍一拍被误判为自消息: %#v", payload["is_self"])
	}
	if payload["user_id"] != "123@chatroom" {
		t.Fatalf("拍一拍 user_id 被改写: %#v", payload["user_id"])
	}
}

// 拍一拍归一化只能改方向字段，pat_* 结构化字段必须原样透传给 App。
func TestNormalizeIncomingIdentityKeepsPatTarget(t *testing.T) {
	payload := map[string]interface{}{
		"group_id":        "123@chatroom",
		"self_id":         "123@chatroom",
		"user_id":         "wxid_user",
		"from_wxid":       "123@chatroom",
		"to_wxid":         "123@chatroom",
		"sender_wxid":     "wxid_user",
		"pat_from_wxid":   "wxid_user",
		"pat_chat_wxid":   "123@chatroom",
		"pat_target_wxid": "wxid_bot",
		"pat_suffix":      "并说你好",
	}
	normalizeIncomingIdentity(payload, "wxid_bot")

	if _, exists := payload["is_self"]; exists {
		t.Fatalf("拍一拍被误判为自消息: %#v", payload["is_self"])
	}
	if payload["pat_target_wxid"] != "wxid_bot" || payload["pat_from_wxid"] != "wxid_user" {
		t.Fatalf("pat 字段被改写: %#v", payload)
	}
	if payload["pat_suffix"] != "并说你好" {
		t.Fatalf("pat_suffix 丢失: %#v", payload["pat_suffix"])
	}
}

// 私聊拍一拍：旧 hook 把 <chatusername>（wxid）当成群 ID，App 会为同一好友
// 拆出独立的「群」会话。bridge 必须把非法群 ID 清洗掉并降级为私聊。
func TestNormalizeIncomingIdentityCleansPatPseudoGroup(t *testing.T) {
	payload := map[string]interface{}{
		"group_id":        "wxid_friend",
		"self_id":         "wxid_friend",
		"user_id":         "wxid_friend",
		"from_wxid":       "wxid_friend",
		"to_wxid":         "wxid_bot",
		"sender_wxid":     "wxid_friend",
		"message_type":    "group",
		"pat_from_wxid":   "wxid_friend",
		"pat_chat_wxid":   "wxid_friend",
		"pat_target_wxid": "wxid_bot",
	}
	normalizeIncomingIdentity(payload, "wxid_bot")

	if payload["group_id"] != "" {
		t.Fatalf("伪群 ID 未清洗: %#v", payload["group_id"])
	}
	if payload["message_type"] != "private" {
		t.Fatalf("伪群消息类型未降级为 private: %#v", payload["message_type"])
	}
	if payload["pat_chat_wxid"] != "" {
		t.Fatalf("拍一拍伪群 ID 未清洗: %#v", payload["pat_chat_wxid"])
	}
	if _, exists := payload["is_self"]; exists {
		t.Fatalf("好友拍一拍被误判为自消息: %#v", payload["is_self"])
	}
	if payload["pat_target_wxid"] != "wxid_bot" {
		t.Fatalf("拍一拍目标被改写: %#v", payload["pat_target_wxid"])
	}
}

// 自己私聊拍一拍：from=自己、to=对方，pat_chat_wxid 为空；必须落进对方会话
// （target_id=对方），而不是「自己 wxid」的会话。
func TestNormalizeIncomingIdentitySelfPatPrivate(t *testing.T) {
	payload := map[string]interface{}{
		"group_id":        "",
		"self_id":         "wxid_friend",
		"user_id":         "wxid_bot",
		"from_wxid":       "wxid_bot",
		"to_wxid":         "wxid_friend",
		"sender_wxid":     "wxid_bot",
		"message_type":    "private",
		"pat_from_wxid":   "wxid_bot",
		"pat_chat_wxid":   "",
		"pat_target_wxid": "wxid_friend",
	}
	normalizeIncomingIdentity(payload, "wxid_bot")

	if payload["is_self"] != true {
		t.Fatalf("自己拍一拍未标记 is_self: %#v", payload["is_self"])
	}
	if payload["message_type"] != "private" || payload["target_id"] != "wxid_friend" {
		t.Fatalf("自己私聊拍一拍路由错误: type=%#v target=%#v",
			payload["message_type"], payload["target_id"])
	}
	if payload["pat_chat_wxid"] != "" || payload["pat_target_wxid"] != "wxid_friend" {
		t.Fatalf("pat 字段错误: %#v", payload)
	}
}

// 旧 hook 的群自消息：from=自己、to=群，但 group_id 缺失且 message_type=private。
// bridge 必须用 to_wxid 补回群字段，否则会落进私聊会话。
func TestNormalizeIncomingIdentitySelfGroupFromTo(t *testing.T) {
	payload := map[string]interface{}{
		"group_id":     "",
		"self_id":      "123@chatroom",
		"user_id":      "wxid_bot",
		"from_wxid":    "wxid_bot",
		"to_wxid":      "123@chatroom",
		"sender_wxid":  "wxid_bot",
		"message_type": "private",
	}
	normalizeIncomingIdentity(payload, "wxid_bot")

	if payload["group_id"] != "123@chatroom" {
		t.Fatalf("群自消息 group_id 未补齐: %#v", payload["group_id"])
	}
	if payload["message_type"] != "group" {
		t.Fatalf("群自消息类型未修正: %#v", payload["message_type"])
	}
	if payload["target_id"] != "123@chatroom" {
		t.Fatalf("群自消息 target_id 错误: %#v", payload["target_id"])
	}
	if payload["is_self"] != true {
		t.Fatalf("群自消息未标记 is_self: %#v", payload["is_self"])
	}
}

// 合法群入站消息（group_id 以 @chatroom 结尾）不能被清洗逻辑误改。
func TestNormalizeIncomingIdentityKeepsValidGroup(t *testing.T) {
	payload := map[string]interface{}{
		"group_id":      "123@chatroom",
		"self_id":       "wxid_bot",
		"user_id":       "wxid_member",
		"from_wxid":     "123@chatroom",
		"to_wxid":       "wxid_bot",
		"sender_wxid":   "wxid_member",
		"message_type":  "group",
		"pat_chat_wxid": "123@chatroom",
	}
	normalizeIncomingIdentity(payload, "wxid_bot")

	if payload["group_id"] != "123@chatroom" || payload["message_type"] != "group" {
		t.Fatalf("合法群字段被误改: %#v", payload)
	}
	if payload["pat_chat_wxid"] != "123@chatroom" {
		t.Fatalf("合法群拍一拍字段被误改: %#v", payload["pat_chat_wxid"])
	}
	if _, exists := payload["is_self"]; exists {
		t.Fatalf("群入站消息不应带 is_self: %#v", payload["is_self"])
	}
}

// selfID 为空（老 bridge）无法判定方向，但非法群 ID 仍必须清洗，避免伪群会话。
func TestNormalizeIncomingIdentityWithoutSelfIDStillSanitizes(t *testing.T) {
	payload := map[string]interface{}{
		"group_id":        "wxid_friend",
		"self_id":         "wxid_friend",
		"user_id":         "wxid_friend",
		"from_wxid":       "wxid_friend",
		"to_wxid":         "wxid_bot",
		"sender_wxid":     "wxid_friend",
		"message_type":    "group",
		"pat_chat_wxid":   "wxid_friend",
		"pat_target_wxid": "wxid_bot",
	}
	normalizeIncomingIdentity(payload, "")

	if payload["group_id"] != "" || payload["pat_chat_wxid"] != "" {
		t.Fatalf("无 selfID 时非法群 ID 未清洗: %#v", payload)
	}
	if payload["message_type"] != "private" {
		t.Fatalf("无 selfID 时消息类型未降级: %#v", payload["message_type"])
	}
	if payload["self_id"] != "wxid_friend" || payload["user_id"] != "wxid_friend" {
		t.Fatalf("无 selfID 时不应改写身份: %#v", payload)
	}
	if _, exists := payload["is_self"]; exists {
		t.Fatalf("无 selfID 时不应写 is_self: %#v", payload["is_self"])
	}
}

func TestIsChatroomID(t *testing.T) {
	for _, id := range []string{"123@chatroom", "123@ChatRoom"} {
		if !isChatroomID(id) {
			t.Fatalf("%q 应视为群 ID", id)
		}
	}
	for _, id := range []string{"", "wxid_bot", "123@chatroom_wxid_bot", "@chatroom_extra"} {
		if isChatroomID(id) {
			t.Fatalf("%q 不应视为群 ID", id)
		}
	}
}

func TestNormalizeIncomingIdentityWithoutSelfID(t *testing.T) {
	payload := map[string]interface{}{
		"self_id":     "wxid_friend",
		"user_id":     "wxid_bot",
		"from_wxid":   "wxid_bot",
		"to_wxid":     "wxid_friend",
		"sender_wxid": "wxid_bot",
	}
	normalizeIncomingIdentity(payload, "")

	if payload["self_id"] != "wxid_friend" || payload["user_id"] != "wxid_bot" {
		t.Fatalf("无 selfID 时不应改写: %#v", payload)
	}
	if _, exists := payload["is_self"]; exists {
		t.Fatalf("无 selfID 时不应写 is_self: %#v", payload["is_self"])
	}
}

// HandleMsg 的 WechatMessage 结构必须保留 is_self，否则 bridge 归一化后的方向
// 会在 JSON→struct→JSON 这一步被静默丢弃。
func TestHandleMsgPreservesIsSelf(t *testing.T) {
	payload := []byte(`{
		"group_id":"",
		"self_id":"wxid_bot",
		"user_id":"wxid_bot",
		"sender":{"user_id":"wxid_bot","nickname":"wxid_bot"},
		"time":1760000000000,
		"post_type":"message",
		"message_id":"1",
		"message":[{"type":"text","data":{"text":"hello"}}],
		"raw_message":"hello",
		"message_type":"private",
		"is_self":true,
		"from_wxid":"wxid_bot",
		"to_wxid":"wxid_friend",
		"sender_wxid":"wxid_bot",
		"target_id":"wxid_friend"
	}`)

	out, err := HandleMsg(payload)
	if err != nil {
		t.Fatalf("HandleMsg 失败: %v", err)
	}
	var got WechatMessage
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("回包反序列化失败: %v", err)
	}
	if !got.IsSelf {
		t.Fatalf("is_self 丢失: %#v", got.IsSelf)
	}
	if got.ToWXID != "wxid_friend" || got.SenderWXID != "wxid_bot" || got.TargetID != "wxid_friend" {
		t.Fatalf("自消息路由字段丢失: %#v", got)
	}
}
