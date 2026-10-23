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

// 拍一拍的结构化目标字段也必须显式保留，否则 App 无法判断“拍的是不是机器人”。
func TestHandleMsgPreservesPatFields(t *testing.T) {
	payload := []byte(`{
		"group_id":"123@chatroom",
		"self_id":"wxid_bot",
		"user_id":"wxid_user",
		"sender":{"user_id":"wxid_user","nickname":"用户"},
		"time":1760000000000,
		"post_type":"message",
		"message_id":"2",
		"message":[{"type":"text","data":{"text":"\"用户\" 拍了拍 \"机器人\""}}],
		"raw_message":"<msg><appmsg><type>62</type><patinfo><fromusername>wxid_user</fromusername><chatusername>123@chatroom</chatusername><pattedusername>wxid_bot</pattedusername></patinfo></appmsg></msg>",
		"message_type":"group",
		"msg_type":49,
		"pat_from_wxid":"wxid_user",
		"pat_chat_wxid":"123@chatroom",
		"pat_target_wxid":"wxid_bot",
		"pat_template":"\"${wxid_user}\" 拍了拍 \"${wxid_bot}\""
	}`)

	out, err := HandleMsg(payload)
	if err != nil {
		t.Fatalf("HandleMsg 失败: %v", err)
	}
	var got WechatMessage
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("回包反序列化失败: %v", err)
	}
	if got.PatTargetWXID != "wxid_bot" || got.PatFromWXID != "wxid_user" || got.PatChatWXID != "123@chatroom" {
		t.Fatalf("pat 字段丢失: %#v", got)
	}
	if got.PatTemplate == "" {
		t.Fatalf("pat_template 丢失: %#v", got)
	}
}

// 2026-10-23：入站图片事件被 bridge 归一化为「无 data 的 image 段」，随后经
// SendWebSocketMsg → HandleMsg 转发。legacy image 分支若把空 data.text 当 XML
// 解析会返回 EOF 并丢弃整条事件；这里回归验证它能原样转发且不阻塞。
func TestHandleMsgToleratesInboundImageSegmentWithoutText(t *testing.T) {
	payload := []byte(`{
		"group_id":"123@chatroom",
		"self_id":"wxid_bot",
		"user_id":"wxid_user",
		"sender":{"user_id":"wxid_user","nickname":"用户"},
		"time":1760000000000,
		"post_type":"message",
		"message_id":"2313155729072926134",
		"message":[{"type":"image","data":{}}],
		"raw_message":"<msg><img aeskey=\"00112233445566778899aabbccddeeff\" cdnmidimgurl=\"0102\" length=\"32\" md5=\"00112233445566778899aabbccddeeff\"/></msg>",
		"show_content":"[图片]",
		"message_type":"group",
		"msg_type":3
	}`)

	out, err := HandleMsg(payload)
	if err != nil {
		t.Fatalf("空 image 段不应导致 HandleMsg 失败: %v", err)
	}
	var got WechatMessage
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("回包反序列化失败: %v", err)
	}
	if len(got.Message) != 1 || got.Message[0].Type != "image" {
		t.Fatalf("image 段应原样保留: %#v", got.Message)
	}
	if got.RawMessage == "" {
		t.Fatal("raw_message 不应被清空")
	}
}
