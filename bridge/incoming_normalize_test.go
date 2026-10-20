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
