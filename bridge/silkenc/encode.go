// Package silkenc 封装官方 SILK SDK 的 WeChat/QQ 兼容 v3 编码器。
//
// 背景（2026-10-26 真机）：go-silk 的输出能被 go-silk 自身解码，但微信播放
// 无声/不停止；真实微信 SILK 与官方 -tencent 编码器输出可正常播放。因此出站
// 编码改为官方 SDK，入站解码仍由 go-silk 完成。
package silkenc

/*
#cgo CFLAGS: -O2 -I${SRCDIR}
#include "wechat_silk.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"unsafe"
)

// ErrInvalidInput 表示 PCM 不是 20ms 整数倍或参数非法。
var ErrInvalidInput = errors.New("silk: invalid pcm")

// Encode 把单声道 s16le PCM（sampleRate 必须是 8000/12000/16000/24000/32000/44100/48000）
// 编码为带 `\x02#!SILK_V3` 头的 WeChat SILK。输出缓冲区按输入大小动态分配。
func Encode(pcm []byte, sampleRate int) ([]byte, error) {
	if len(pcm) == 0 || len(pcm)%2 != 0 {
		return nil, ErrInvalidInput
	}
	samples := len(pcm) / 2
	packet := sampleRate / 50
	if packet <= 0 || samples%packet != 0 {
		return nil, ErrInvalidInput
	}
	// SILK 峰值每 20ms 帧 250B；留足余量。
	capBytes := samples/2 + 1024
	if capBytes < 4096 {
		capBytes = 4096
	}
	out := make([]byte, capBytes)
	n := C.wechat_silk_encode(
		(*C.int16_t)(unsafe.Pointer(&pcm[0])),
		C.int(samples),
		C.int(sampleRate),
		(*C.uchar)(unsafe.Pointer(&out[0])),
		C.int(len(out)),
	)
	if n < 0 {
		return nil, fmt.Errorf("%w: code %d", ErrInvalidInput, int(n))
	}
	return out[:int(n)], nil
}
