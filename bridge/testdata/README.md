# 测试数据

## `voice_sample.silk`

- 用途：Go bridge 入站语音解码回归（`bridge/voice_test.go`），验证 Tencent SILK v3
  容器解析与 go-silk 解码链路。
- 来源：**TTS 合成**（中文女声，5.08s、16 kHz、单声道、Tencent SILK 头），
  不含任何真人聊天录音；SILK 容器本身不携带可识别元数据。
- 大小 / 校验：

  ```text
  bytes  : 9921
  sha256 : f2f070409c90ef98e0ce539e7f6a31101062e7e9d1c07ee79e34062ca20f9ad5
  ```

- 许可：测试样本由本项目生成，随仓库以 GPL-3.0 分发。

> 音频文件默认不入库（`.gitignore` 中的 `*.silk` / `*.wav` 等）；
> 本文件是唯一例外（`!bridge/testdata/voice_sample.silk`）。
> 更新样本时请同时更新上面的 SHA256 与 `voice_test.go` 中的时长断言。
