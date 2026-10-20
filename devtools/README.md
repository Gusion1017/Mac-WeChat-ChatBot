# devtools — 本地联调 Mock

无需微信、Frida 或真实 API Key，即可跑通
「模拟收消息 → 规则/人格 → AI → 模拟发送」全链路，用于 UI/核心开发与演示。

## 1. 启动 Mock OpenAI（默认 8787）

```bash
python3 devtools/mock_ai.py --port 8787
```

- 兼容 `/v1/models`、`/v1/chat/completions`
- 支持 `stream=true` 的 SSE 与普通 JSON
- 回复内容会带上「这是本地 Mock 模型的回复」，便于断言

在 App 的「AI 模型」里新增通道：

| 字段 | 值 |
| --- | --- |
| 类型 | 自定义兼容 |
| Base URL | `http://127.0.0.1:8787/v1` |
| 模型 | `mock-chat` |
| API Key | 任意非空字符串（Mock 不校验） |

## 2. 启动 Mock OneBot（默认 58080）

```bash
python3 devtools/mock_onebot.py --port 58080 \
  --token wechatai-local-token --demo
```

- `GET /health`：状态
- `POST /send_private_msg` / `send_group_msg`：需要
  `Authorization: Bearer wechatai-local-token`，发送内容记录到
  `/tmp/wechatai-mock-sent.jsonl`
- `POST /inject`：推送任意事件 JSON（单条或数组）
- `POST /demo`：手动触发内置演示消息
- `GET /ws`：WebSocket 推送；连接后推 2 条私聊 + 1 条群聊 @

在 App 的「设置 → OneBot」里把端口设为 58080、Token 设为
`wechatai-local-token`，启动机器人即可看到会话与自动回复（AI 通道指向 Mock AI）。

## 3. 手工注入事件示例

```bash
curl -s -X POST http://127.0.0.1:58080/inject \
  -H 'Content-Type: application/json' \
  -d '{
    "self_id": "wxid_self",
    "user_id": "wxid_test",
    "group_id": "",
    "sender": {"user_id": "wxid_test", "nickname": "测试号"},
    "time": 1760000000,
    "message_id": "manual-1",
    "message": [{"type":"text","data":{"text":"你好，请自我介绍"}}],
    "message_type": "private"
  }'
```

## 4. 断言发送结果

```bash
tail -f /tmp/wechatai-mock-sent.jsonl
```

## 注意

- Mock 只监听 `127.0.0.1`，不要暴露到局域网。
- 真实模式必须使用 `bridge/onebot` + Frida Gadget；Mock 不参与打包产物。
