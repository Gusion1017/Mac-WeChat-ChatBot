package main

// 本文件不是上游源码，由 ChatBot 项目为“无 Gadget 情况下验证 HTTP 鉴权/参数校验
// 与 /ws 动作契约”而添加。它只使用 httptest，不连接 Frida、不启动真实监听端口。
// 上游源码见 NOTICE。

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/rs/zerolog"
)

// TestMain 避免测试期间的日志写入 ./log/macos.log（上游 initLogger 的副作用），
// 同时保证未初始化的 zerolog.Logger 不会影响 handler 的错误分支。
func TestMain(m *testing.M) {
	Logger.logger = zerolog.Nop()
	os.Exit(m.Run())
}

func withToken(t *testing.T, token string) {
	t.Helper()
	old := config.OnebotToken
	config.OnebotToken = token
	t.Cleanup(func() { config.OnebotToken = old })
}

func doRequest(t *testing.T, method, url, auth, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

// TestSendHandlerAuth 覆盖 docs/architecture.md §3.3 的 HTTP 鉴权与参数校验：
// 方法错误 405、缺失/错误 token 401、坏 JSON/缺参数 400。
func TestSendHandlerAuth(t *testing.T) {
	const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	withToken(t, token)

	// 注意：上游用 strings.TrimPrefix(header, "Bearer ") 解析 Authorization，
	// 若 header 恰好等于 token（无 Bearer 前缀）也会通过鉴权。这里只构造错误
	// token 的场景，避免进入会等待 SendWorker 的真实发送分支（测试不启动 worker）。
	srv := httptest.NewServer(http.HandlerFunc(sendHandler))
	defer srv.Close()
	sendURL := srv.URL + "/send_private_msg"

	tests := []struct {
		name       string
		method     string
		auth       string
		body       string
		wantStatus int
		wantSubstr string
	}{
		{
			name:       "GET 被拒绝",
			method:     http.MethodGet,
			auth:       "Bearer " + token,
			wantStatus: http.StatusMethodNotAllowed,
			wantSubstr: "仅支持 POST",
		},
		{
			name:       "缺少 Authorization",
			method:     http.MethodPost,
			body:       `{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}`,
			wantStatus: http.StatusUnauthorized,
			wantSubstr: "未授权",
		},
		{
			name:       "错误 token",
			method:     http.MethodPost,
			auth:       "Bearer wrong-token",
			body:       `{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}`,
			wantStatus: http.StatusUnauthorized,
			wantSubstr: "未授权",
		},
		{
			name:       "无 Bearer 前缀且 token 错误",
			method:     http.MethodPost,
			auth:       "wrong-token",
			body:       `{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}`,
			wantStatus: http.StatusUnauthorized,
			wantSubstr: "未授权",
		},
		{
			name:       "坏 JSON",
			method:     http.MethodPost,
			auth:       "Bearer " + token,
			body:       `{not-json`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "无效的 JSON",
		},
		{
			name:       "message 为空",
			method:     http.MethodPost,
			auth:       "Bearer " + token,
			body:       `{"user_id":"wxid_x","message":[]}`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "参数缺失",
		},
		{
			name:       "缺少 user_id/group_id",
			method:     http.MethodPost,
			auth:       "Bearer " + token,
			body:       `{"message":[{"type":"text","data":{"text":"hi"}}]}`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "参数缺失",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			resp := doRequest(t, tc.method, sendURL, tc.auth, tc.body)
			if resp.StatusCode != tc.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tc.wantStatus)
			}
			body := readBody(t, resp)
			if !strings.Contains(body, tc.wantSubstr) {
				t.Fatalf("body = %q, want substring %q", body, tc.wantSubstr)
			}
		})
	}
}

// TestWebSocketGetLoginInfo 覆盖 §3.3 的 get_login_info 动作（含 echo 回包）。
func TestWebSocketGetLoginInfo(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(handleWebSocket))
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", wsURL, err)
	}
	defer conn.Close()

	if err := conn.WriteJSON(map[string]any{
		"action": "get_login_info",
		"echo":   "test-echo-1",
		"params": map[string]any{},
	}); err != nil {
		t.Fatalf("write: %v", err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, raw, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal %q: %v", raw, err)
	}
	if got["echo"] != "test-echo-1" {
		t.Fatalf("echo = %v, want test-echo-1", got["echo"])
	}
	if got["status"] != "ok" {
		t.Fatalf("status = %v, want ok", got["status"])
	}
	if _, ok := got["data"].(map[string]any); !ok {
		t.Fatalf("data is not object: %v", got["data"])
	}
}

func readBody(t *testing.T, resp *http.Response) string {
	t.Helper()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(b)
}
