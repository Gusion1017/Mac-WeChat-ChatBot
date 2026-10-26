package main

import (
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	wxproto "github.com/yincongcyincong/weixin-macos/onebot/proto"
	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

// BuildVoiceMsgProto 构建发送语音消息的protobuf并返回hex编码的字符串
func BuildVoiceMsgProto(sender, targetId, cdnKey, aesKey string, voiceDuration int32, silkDataLen int32, unknown13 int32) (string, error) {
	return BuildVoiceMsgProtoWithHeader(sender, targetId, cdnKey, aesKey, voiceDuration, silkDataLen, unknown13, "")
}

// BuildVoiceMsgProtoWithHeader 同 BuildVoiceMsgProto，但可用真实语音 header（frame0
// 的 field10 原始字节）里的 session_id/device_id 构造 4.2 的最小 header。
// 真机对比（2026-10-26）：4.2 真实语音 header 只有 17B（field2 session_id +
// field4 device_id）；带 platform/client_proof 的旧 header 无法关联音频。
func BuildVoiceMsgProtoWithHeader(sender, targetId, cdnKey, aesKey string, voiceDuration int32, silkDataLen int32, unknown13 int32, headerHex string) (string, error) {
	// client_msg_id: UUID格式
	clientMsgId := uuid.New().String()

	header := legacyVoiceHeader()
	if hdr, ok := parseVoiceHeaderHex(headerHex); ok {
		header = hdr
	}
	msg := &wxproto.WxSendVoiceMsg{
		FromUser:    sender,
		ToUser:      targetId,
		Unknown3:    0,
		Unknown4:    silkDataLen,
		ClientMsgId: clientMsgId,
		Duration:    voiceDuration,
		Unknown9:    1,
		Header:    header,
		Unknown11: 0,
		Unknown13: 4,
		Unknown15: 0,
		Unknown16: 0,
		Unknown17: time.Now().Unix(),
		CdnKey:    []byte(cdnKey),
		AesKey:    []byte(aesKey),
		Unknown24: []byte{},
		Unknown25: 0,
	}

	data, err := proto.Marshal(msg)
	if err != nil {
		return "", fmt.Errorf("marshal voice proto failed: %w", err)
	}

	// 手动追加proto3不会序列化的0值字段
	// field 3 (unknown3=0)
	data = appendZeroVarintField(data, 3)
	// field 11 (unknown11=0)
	data = appendZeroVarintField(data, 11)
	// field 15 (unknown15=0)
	data = appendZeroVarintField(data, 15)
	// field 16 (unknown16=0)
	data = appendZeroVarintField(data, 16)
	// field 25 (unknown25=0)
	data = appendZeroVarintField(data, 25)

	//fmt.Printf("[voice-proto] final protobuf hex dump:\n%s\n", HexDump(data, 0))

	return hex.EncodeToString(data), nil
}


// legacyVoiceHeader 是 R3 语音最初使用的 4.1 形态 header；真实 4.2 语音只用
// session_id/device_id，捕获到真实 header 时会替换为最小 header。
func legacyVoiceHeader() *wxproto.VoiceMsgHeader {
	return &wxproto.VoiceMsgHeader{
		Flag:        []byte{0x00},
		SessionId:   int64(globalSessionId),
		ClientProof: globalClientProof,
		DeviceId:    int64(globalDeviceId),
		Platform:    []byte("UnifiedPCMac 26 arm64"),
		Version:     int32(NextVersion()),
		Unknown8:    4,
	}
}

// parseVoiceHeaderHex 解析真实语音 header 的 protobuf，只保留 4.2 使用的
// field2 session_id 与 field4 device_id。
func parseVoiceHeaderHex(headerHex string) (*wxproto.VoiceMsgHeader, bool) {
	raw, err := hex.DecodeString(strings.TrimSpace(headerHex))
	if err != nil || len(raw) == 0 {
		return nil, false
	}
	hdr := &wxproto.VoiceMsgHeader{}
	seen := false
	for len(raw) > 0 {
		num, typ, n := protowire.ConsumeTag(raw)
		if n < 0 {
			return nil, false
		}
		raw = raw[n:]
		if typ == protowire.VarintType {
			v, m := protowire.ConsumeVarint(raw)
			if m < 0 {
				return nil, false
			}
			raw = raw[m:]
			switch num {
			case 2:
				hdr.SessionId = int64(v)
				seen = true
			case 4:
				hdr.DeviceId = int64(v)
				seen = true
			}
			continue
		}
		m := protowire.ConsumeFieldValue(num, typ, raw)
		if m < 0 {
			return nil, false
		}
		raw = raw[m:]
	}
	return hdr, seen && (hdr.SessionId != 0 || hdr.DeviceId != 0)
}
