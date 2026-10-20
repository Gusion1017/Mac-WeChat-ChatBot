package main

import (
	"encoding/json"
	"testing"
)

// HandleMsg 会把 hook 的入站事件反序列化成 WechatMessage 再序列化发送。
// 未在结构体里声明的字段会被静默丢弃——mentions 丢失会直接导致群 @ 唤醒失效。
func TestHandleMsgPreservesMentionsAndMsgType(t *testing.T) {
	payload := []byte(`{
		"group_id":"123@chatroom",
		"self_id":"wxid_bot",
		"user_id":"wxid_user",
		"sender":{"user_id":"wxid_user","nickname":"用户"},
		"time":1760000000000,
		"post_type":"message",
		"message_id":"1000000000000000001",
		"message":[
			{"type":"text","data":{"text":"@机器人 你好"}},
			{"type":"at","data":{"qq":"wxid_bot"}}
		],
		"msgsource":"",
		"raw_message":"@机器人 你好",
		"show_content":"@机器人 你好",
		"message_type":"group",
		"msg_type":1,
		"mentions":["wxid_bot"]
	}`)

	out, err := HandleMsg(payload)
	if err != nil {
		t.Fatalf("HandleMsg 失败: %v", err)
	}
	var got WechatMessage
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("回包反序列化失败: %v", err)
	}
	if len(got.Mentions) != 1 || got.Mentions[0] != "wxid_bot" {
		t.Fatalf("mentions 丢失: got %#v", got.Mentions)
	}
	if got.MsgType != 1 {
		t.Fatalf("msg_type 丢失: got %d", got.MsgType)
	}
	if len(got.Message) != 2 {
		t.Fatalf("消息段数量错误: got %d", len(got.Message))
	}
	if got.Message[1].Type != "at" || got.Message[1].Data == nil || got.Message[1].Data.QQ != "wxid_bot" {
		t.Fatalf("at 段被改写: %#v", got.Message[1])
	}
	if got.Sender == nil || got.Sender.Nickname != "用户" {
		t.Fatalf("sender 丢失: %#v", got.Sender)
	}
}

// 只有 mentions、没有 at 段时也必须原样透传（部分客户端/版本用 msgsource 承载 @）。
func TestHandleMsgPreservesMentionsWithoutAtSegment(t *testing.T) {
	payload := []byte(`{
		"group_id":"123@chatroom",
		"self_id":"wxid_bot",
		"user_id":"wxid_user",
		"sender":{"user_id":"wxid_user","nickname":"用户"},
		"time":1760000000000,
		"post_type":"message",
		"message_id":"1",
		"message":[{"type":"text","data":{"text":"@机器人 你好"}}],
		"raw_message":"@机器人 你好",
		"message_type":"group",
		"mentions":["wxid_bot"]
	}`)

	out, err := HandleMsg(payload)
	if err != nil {
		t.Fatalf("HandleMsg 失败: %v", err)
	}
	var got WechatMessage
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("回包反序列化失败: %v", err)
	}
	if len(got.Mentions) != 1 || got.Mentions[0] != "wxid_bot" {
		t.Fatalf("mentions 丢失: got %#v", got.Mentions)
	}
}
