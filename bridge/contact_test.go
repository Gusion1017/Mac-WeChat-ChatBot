package main

// 本文件不是上游源码，由 ChatBot 项目为「通讯录目录 / DB key 缓存 / 入站昵称补全」
// 新增。测试只覆盖纯逻辑与 httptest WS，不连接微信、不启动 Frida：
// Frida RPC 经 callFridaExport 包级变量注入替身，密钥缓存路径也重定向到临时目录。
// 契约见 docs/architecture.md §3。

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// contactDirectorySample 是 hook getContactDirectory 的响应样例（数据均为占位符）。
const contactDirectorySample = `{
  "ok": true,
  "generated_at": 1760000000000,
  "wal_applied": 3,
  "users": {
    "wxid_alice": {"display": "Alice Display", "nickname": "Alice Nick", "remark": "Alice Remark", "alias": "alice"},
    "wxid_bob": {"display": "Bob Display", "nickname": "Bob Nick"},
    "wxid_carol": {"display": "Carol Display", "nickname": "Carol Nick"}
  },
  "groups": {
    "123456@chatroom": {
      "display": "Test Group",
      "nickname": "Test Group",
      "remark": "",
      "members": {
        "wxid_alice": {"display": "Alice Group Nick", "nickname": "Alice Group Nick"},
        "wxid_bob": {"display": "Bob Group Nick", "nickname": "Bob Group Nick"}
      }
    }
  },
  "keys": {
    "contact": {"salt": "00112233445566778899aabbccddeeff", "key": "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"}
  }
}`

const contactExampleAccountDir = "/Users/example/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_example_bcce"
const contactExampleDBStorage = contactExampleAccountDir + "/db_storage"

func withContactDBKeysPath(t *testing.T, path string) {
	t.Helper()
	old := contactDBKeysFilePath
	contactDBKeysFilePath = func() string { return path }
	t.Cleanup(func() { contactDBKeysFilePath = old })
}

func stubContactFridaExport(t *testing.T, fn func(string, ...any) (any, error)) {
	t.Helper()
	old := callFridaExport
	callFridaExport = fn
	t.Cleanup(func() { callFridaExport = old })
}

func withImagePath(t *testing.T, imagePath string) {
	t.Helper()
	old := config.ImagePath
	config.ImagePath = imagePath
	t.Cleanup(func() { config.ImagePath = old })
}

func resetContactDirectoryCache(t *testing.T) {
	t.Helper()
	storeContactDirectory(nil)
	t.Cleanup(func() { storeContactDirectory(nil) })
}

func TestDeriveDBStoragePath(t *testing.T) {
	accountDir := "/Users/example/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_example_bcce"
	tests := []struct {
		name      string
		imagePath string
		want      string
	}{
		{"空值", "", ""},
		{"temp 结尾", accountDir + "/temp", accountDir + "/db_storage"},
		{"结尾斜杠", accountDir + "/temp/", accountDir + "/db_storage"},
		{"temp 深层媒体目录", accountDir + "/temp/2026-10/Img/", accountDir + "/db_storage"},
		{"逗号与空白", "  " + accountDir + "/temp  ", accountDir + "/db_storage"},
		{"非标准布局", "/data/accounts/acct/temp/2026-10/Img", "/data/accounts/acct/db_storage"},
		{"反斜杠分隔符", `C:\wechat\xwechat_files\wxid_example_bcce\temp\Img`, "C:/wechat/xwechat_files/wxid_example_bcce/db_storage"},
		{"无法识别", "/tmp/somewhere", ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := deriveDBStoragePath(tc.imagePath); got != tc.want {
				t.Fatalf("deriveDBStoragePath(%q) = %q, want %q", tc.imagePath, got, tc.want)
			}
		})
	}
}

func TestParseContactDirectory(t *testing.T) {
	dir, err := parseContactDirectory(contactDirectorySample)
	if err != nil {
		t.Fatalf("解析样例失败: %v", err)
	}
	if !dir.OK {
		t.Fatal("ok 应为 true")
	}
	if dir.GeneratedAt != 1760000000000 || dir.WALApplied != 3 {
		t.Fatalf("顶层字段解析错误: %#v", dir)
	}
	if got := dir.Users["wxid_alice"]; got.Display != "Alice Display" || got.Remark != "Alice Remark" || got.Alias != "alice" {
		t.Fatalf("用户条目解析错误: %#v", got)
	}
	if got := dir.Groups["123456@chatroom"].Display; got != "Test Group" {
		t.Fatalf("群条目解析错误: %q", got)
	}
	if got := dir.Keys["contact"]; got.Salt == "" || got.Key == "" {
		t.Fatalf("keys 解析错误: %#v", got)
	}

	failed, err := parseContactDirectory(`{"ok":false,"reason":"key_missing"}`)
	if err != nil {
		t.Fatalf("解析失败响应出错: %v", err)
	}
	if failed.OK || failed.Reason != "key_missing" {
		t.Fatalf("失败响应解析错误: %#v", failed)
	}

	if _, err := parseContactDirectory("  "); err == nil {
		t.Fatal("空响应应返回错误")
	}
	if _, err := parseContactDirectory("{not-json"); err == nil {
		t.Fatal("非法 JSON 应返回错误")
	}
}

func TestContactDirectoryCacheAndDisplay(t *testing.T) {
	resetContactDirectoryCache(t)
	dir, err := parseContactDirectory(contactDirectorySample)
	if err != nil {
		t.Fatalf("解析样例失败: %v", err)
	}
	storeContactDirectory(dir)

	if got := directoryUserName("wxid_alice"); got != "Alice Display" {
		t.Fatalf("directoryUserName = %q, want Alice Display", got)
	}
	if got := directoryUserName("123456@chatroom"); got != "" {
		t.Fatalf("directoryUserName 不应命中群: %q", got)
	}
	if got := contactGroupDisplayName("123456@chatroom"); got != "Test Group" {
		t.Fatalf("contactGroupDisplayName = %q, want Test Group", got)
	}
	if got := contactDisplayName("wxid_alice"); got != "Alice Display" {
		t.Fatalf("contactDisplayName(用户) = %q", got)
	}
	if got := contactDisplayName("123456@chatroom"); got != "Test Group" {
		t.Fatalf("contactDisplayName(群) = %q", got)
	}
	if got := contactDisplayName("wxid_unknown"); got != "" {
		t.Fatalf("未知 ID 应返回空: %q", got)
	}
	if got := directoryGroupMemberName("123456@chatroom", "wxid_alice"); got != "Alice Group Nick" {
		t.Fatalf("directoryGroupMemberName = %q, want Alice Group Nick", got)
	}
	if got := directoryGroupMemberName("123456@chatroom", "wxid_carol"); got != "" {
		t.Fatalf("非群成员应返回空: %q", got)
	}
	if got := directoryGroupMemberName("", "wxid_alice"); got != "" {
		t.Fatalf("空群 ID 应返回空: %q", got)
	}

	// display 缺失时依次回退 remark/nickname/alias。
	storeContactDirectory(&ContactDirectory{OK: true, Users: map[string]ContactEntry{
		"wxid_remark":   {Remark: "Remark Name"},
		"wxid_nickname": {Nickname: "Nick Name"},
		"wxid_alias":    {Alias: "alias_name"},
	}})
	if got := contactDisplayName("wxid_remark"); got != "Remark Name" {
		t.Fatalf("remark 回退错误: %q", got)
	}
	if got := contactDisplayName("wxid_nickname"); got != "Nick Name" {
		t.Fatalf("nickname 回退错误: %q", got)
	}
	if got := contactDisplayName("wxid_alias"); got != "alias_name" {
		t.Fatalf("alias 回退错误: %q", got)
	}

	// 群 @ 昵称：历史群成员缓存优先，未命中回退通讯录。
	storeContactDirectory(dir)
	userID2NicknameMap.Store("123456@chatroom_wxid_bob", "Bob Cached")
	t.Cleanup(func() { userID2NicknameMap.Delete("123456@chatroom_wxid_bob") })
	if name, ok := resolveAtNickname("123456@chatroom", "wxid_bob"); !ok || name != "Bob Cached" {
		t.Fatalf("群成员缓存未命中: name=%q ok=%v", name, ok)
	}
	if name, ok := resolveAtNickname("123456@chatroom", "wxid_alice"); !ok || name != "Alice Group Nick" {
		t.Fatalf("群成员昵称回退失败: name=%q ok=%v", name, ok)
	}
	if name, ok := resolveAtNickname("123456@chatroom", "wxid_carol"); !ok || name != "Carol Display" {
		t.Fatalf("通讯录回退失败: name=%q ok=%v", name, ok)
	}
	// primeNicknameCache 预热 group_member key（群昵称优先）。
	primeNicknameCache(dir)
	t.Cleanup(func() { userID2NicknameMap.Delete("123456@chatroom_wxid_alice") })
	if name, ok := resolveAtNickname("123456@chatroom", "wxid_alice"); !ok || name != "Alice Group Nick" {
		t.Fatalf("预热后群成员昵称错误: name=%q ok=%v", name, ok)
	}
	if _, ok := resolveAtNickname("", "wxid_alice"); ok {
		t.Fatal("空群 ID 不应解析 at 昵称")
	}
}

func TestEnrichIncomingSender(t *testing.T) {
	resetContactDirectoryCache(t)
	dir, err := parseContactDirectory(contactDirectorySample)
	if err != nil {
		t.Fatalf("解析样例失败: %v", err)
	}
	storeContactDirectory(dir)

	t.Run("私聊覆盖昵称", func(t *testing.T) {
		payload := map[string]interface{}{
			"user_id": "wxid_alice",
			"sender":  map[string]interface{}{"user_id": "wxid_alice", "nickname": "wxid_alice"},
		}
		enrichIncomingSender(payload)
		sender := payload["sender"].(map[string]interface{})
		if sender["nickname"] != "Alice Display" {
			t.Fatalf("sender.nickname = %v, want Alice Display", sender["nickname"])
		}
		if _, exists := payload["group_name"]; exists {
			t.Fatalf("私聊不应写 group_name: %v", payload["group_name"])
		}
	})

	t.Run("自消息不覆盖昵称", func(t *testing.T) {
		payload := map[string]interface{}{
			"user_id": "wxid_alice",
			"is_self": true,
			"sender":  map[string]interface{}{"user_id": "wxid_alice", "nickname": "wxid_self"},
		}
		enrichIncomingSender(payload)
		sender := payload["sender"].(map[string]interface{})
		if sender["nickname"] != "wxid_self" {
			t.Fatalf("自消息昵称被改写: %v", sender["nickname"])
		}
	})

	t.Run("群消息附加群名", func(t *testing.T) {
		payload := map[string]interface{}{
			"group_id": "123456@chatroom",
			"user_id":  "wxid_alice",
			"sender":   map[string]interface{}{"user_id": "wxid_alice", "nickname": "wxid_alice"},
		}
		enrichIncomingSender(payload)
		sender := payload["sender"].(map[string]interface{})
		if sender["nickname"] != "Alice Group Nick" {
			t.Fatalf("群成员昵称 = %v, want Alice Group Nick", sender["nickname"])
		}
		if payload["group_name"] != "Test Group" {
			t.Fatalf("group_name = %v, want Test Group", payload["group_name"])
		}
	})

	t.Run("群成员未命中回退通讯录", func(t *testing.T) {
		payload := map[string]interface{}{
			"group_id": "123456@chatroom",
			"user_id":  "wxid_carol",
			"sender":   map[string]interface{}{"user_id": "wxid_carol", "nickname": "wxid_carol"},
		}
		enrichIncomingSender(payload)
		sender := payload["sender"].(map[string]interface{})
		if sender["nickname"] != "Carol Display" {
			t.Fatalf("回退通讯录昵称错误 = %v", sender["nickname"])
		}
	})

	t.Run("群昵称优先于通讯录昵称", func(t *testing.T) {
		// alice 在通讯录是 Alice Display、在本群是 Alice Group Nick；伪造历史群成员缓存
		// 存在时仍以缓存为准（数据来自历史消息），缓存缺失时用目录群昵称。
		payload := map[string]interface{}{
			"group_id": "123456@chatroom",
			"user_id":  "wxid_alice",
			"sender":   map[string]interface{}{"user_id": "wxid_alice", "nickname": "wxid_alice"},
		}
		enrichIncomingSender(payload)
		sender := payload["sender"].(map[string]interface{})
		if sender["nickname"] != "Alice Group Nick" {
			t.Fatalf("群昵称未生效 = %v", sender["nickname"])
		}
	})

	t.Run("未知群与成员保持原样", func(t *testing.T) {
		payload := map[string]interface{}{
			"group_id": "999999@chatroom",
			"user_id":  "wxid_unknown",
			"sender":   map[string]interface{}{"user_id": "wxid_unknown", "nickname": "wxid_unknown"},
		}
		enrichIncomingSender(payload)
		sender := payload["sender"].(map[string]interface{})
		if sender["nickname"] != "wxid_unknown" {
			t.Fatalf("未知成员昵称被改写: %v", sender["nickname"])
		}
		if _, exists := payload["group_name"]; exists {
			t.Fatalf("未知群不应写 group_name: %v", payload["group_name"])
		}
	})

	t.Run("无 sender 的群系统消息", func(t *testing.T) {
		payload := map[string]interface{}{"group_id": "123456@chatroom"}
		enrichIncomingSender(payload)
		if payload["group_name"] != "Test Group" {
			t.Fatalf("group_name = %v, want Test Group", payload["group_name"])
		}
	})

	t.Run("nil 不 panic", func(t *testing.T) {
		enrichIncomingSender(nil)
	})
}

func TestContactDBKeysCacheRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "WeChatAI", "db-keys.json")
	withContactDBKeysPath(t, path)

	if keys, err := loadContactDBKeys(); err != nil || len(keys) != 0 {
		t.Fatalf("缺失文件应返回空: keys=%v err=%v", keys, err)
	}

	keys := map[string]ContactKey{
		"contact": {Salt: strings.Repeat("ab", 16), Key: strings.Repeat("cd", 32)},
	}
	if err := persistContactDBKeys(keys); err != nil {
		t.Fatalf("写入密钥缓存失败: %v", err)
	}

	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat 缓存文件失败: %v", err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("缓存文件权限 = %o, want 600", perm)
	}
	di, err := os.Stat(filepath.Dir(path))
	if err != nil {
		t.Fatalf("stat 缓存目录失败: %v", err)
	}
	if perm := di.Mode().Perm(); perm != 0o700 {
		t.Fatalf("缓存目录权限 = %o, want 700", perm)
	}

	got, err := loadContactDBKeys()
	if err != nil {
		t.Fatalf("读取密钥缓存失败: %v", err)
	}
	if !reflect.DeepEqual(got, keys) {
		t.Fatalf("密钥缓存往返不一致: got=%v want=%v", got, keys)
	}

	// 空 keys 不覆盖已有缓存。
	if err := persistContactDBKeys(nil); err != nil {
		t.Fatalf("空 keys 写入失败: %v", err)
	}
	if again, err := loadContactDBKeys(); err != nil || !reflect.DeepEqual(again, keys) {
		t.Fatalf("空 keys 覆盖了缓存: got=%v err=%v", again, err)
	}
}

func TestRestoreContactDBKeys(t *testing.T) {
	path := filepath.Join(t.TempDir(), "WeChatAI", "db-keys.json")
	withContactDBKeysPath(t, path)
	keys := map[string]ContactKey{
		"contact": {Salt: strings.Repeat("ab", 16), Key: strings.Repeat("cd", 32)},
	}
	if err := persistContactDBKeys(keys); err != nil {
		t.Fatalf("写入密钥缓存失败: %v", err)
	}

	var calls int
	var gotFn, gotArg string
	stubContactFridaExport(t, func(fn string, args ...any) (any, error) {
		calls++
		gotFn = fn
		if len(args) == 1 {
			gotArg, _ = args[0].(string)
		}
		return `{"contact":true}`, nil
	})
	restoreContactDBKeys()
	if calls != 1 || gotFn != "setDbKeys" {
		t.Fatalf("回灌调用错误: calls=%d fn=%q", calls, gotFn)
	}
	var sent map[string]ContactKey
	if err := json.Unmarshal([]byte(gotArg), &sent); err != nil {
		t.Fatalf("回灌参数不是合法 JSON: %v", err)
	}
	if !reflect.DeepEqual(sent, keys) {
		t.Fatalf("回灌参数不一致: got=%v want=%v", sent, keys)
	}

	// 回灌失败只记日志，不影响调用方。
	stubContactFridaExport(t, func(string, ...any) (any, error) {
		return nil, errors.New("rpc failed")
	})
	restoreContactDBKeys()

	// 无缓存时不应调用 Frida。
	withContactDBKeysPath(t, filepath.Join(t.TempDir(), "missing", "db-keys.json"))
	calls = 0
	stubContactFridaExport(t, func(string, ...any) (any, error) {
		calls++
		return "", nil
	})
	restoreContactDBKeys()
	if calls != 0 {
		t.Fatalf("无缓存时仍调用了 Frida: calls=%d", calls)
	}
}

func TestRefreshContactDirectory(t *testing.T) {
	resetContactDirectoryCache(t)
	withImagePath(t, contactExampleAccountDir+"/temp/2026-10/Img/")
	keysPath := filepath.Join(t.TempDir(), "WeChatAI", "db-keys.json")
	withContactDBKeysPath(t, keysPath)
	t.Cleanup(func() {
		for _, id := range []string{"wxid_alice", "wxid_bob", "wxid_carol", "123456@chatroom",
			"123456@chatroom_wxid_alice", "123456@chatroom_wxid_bob"} {
			userID2NicknameMap.Delete(id)
		}
	})

	var gotFn, gotPath string
	stubContactFridaExport(t, func(fn string, args ...any) (any, error) {
		gotFn = fn
		if len(args) > 0 {
			gotPath, _ = args[0].(string)
		}
		return contactDirectorySample, nil
	})

	dir, err := refreshContactDirectory()
	if err != nil {
		t.Fatalf("刷新通讯录失败: %v", err)
	}
	if gotFn != "getContactDirectory" {
		t.Fatalf("调用的 RPC = %q, want getContactDirectory", gotFn)
	}
	if gotPath != contactExampleDBStorage {
		t.Fatalf("db_storage 路径 = %q, want %q", gotPath, contactExampleDBStorage)
	}
	if dir == nil || !dir.OK || len(dir.Users) != 3 || len(dir.Groups) != 1 {
		t.Fatalf("目录内容错误: %#v", dir)
	}
	if got := len(dir.Groups["123456@chatroom"].Members); got != 2 {
		t.Fatalf("群成员数 = %d, want 2", got)
	}
	if got := contactDisplayName("wxid_alice"); got != "Alice Display" {
		t.Fatalf("缓存未更新: %q", got)
	}
	if got, ok := userID2NicknameMap.Load("wxid_alice"); !ok || got != "Alice Display" {
		t.Fatalf("昵称缓存未预热: got=%v ok=%v", got, ok)
	}
	if got, ok := userID2NicknameMap.Load("123456@chatroom"); !ok || got != "Test Group" {
		t.Fatalf("群名缓存未预热: got=%v ok=%v", got, ok)
	}
	keys, err := loadContactDBKeys()
	if err != nil || len(keys) != 1 || keys["contact"].Salt == "" {
		t.Fatalf("DB key 缓存未写入: keys=%v err=%v", keys, err)
	}
}

func TestRefreshContactDirectoryFailures(t *testing.T) {
	resetContactDirectoryCache(t)
	withImagePath(t, contactExampleAccountDir+"/temp")
	withContactDBKeysPath(t, filepath.Join(t.TempDir(), "WeChatAI", "db-keys.json"))

	tests := []struct {
		name    string
		result  any
		rpcErr  error
		wantSub string
	}{
		{"RPC 错误", nil, errors.New("rpc boom"), "rpc boom"},
		{"hook 返回失败", `{"ok":false,"reason":"key_missing"}`, nil, "key_missing"},
		{"hook 返回非法 JSON", "{not-json", nil, "JSON"},
		{"hook 返回空", "", nil, "为空"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			stubContactFridaExport(t, func(string, ...any) (any, error) {
				return tc.result, tc.rpcErr
			})
			if _, err := refreshContactDirectory(); err == nil || !strings.Contains(err.Error(), tc.wantSub) {
				t.Fatalf("err = %v, want substring %q", err, tc.wantSub)
			}
			if got := contactDisplayName("wxid_alice"); got != "" {
				t.Fatalf("失败时不应更新缓存: %q", got)
			}
		})
	}

	t.Run("image_path 无法推导", func(t *testing.T) {
		withImagePath(t, "/tmp/not-wechat")
		if _, err := refreshContactDirectory(); !errors.Is(err, errContactPathUnknown) {
			t.Fatalf("err = %v, want errContactPathUnknown", err)
		}
	})
}

func TestWebSocketGetContactDirectory(t *testing.T) {
	newServer := func(t *testing.T) *websocket.Conn {
		t.Helper()
		srv := httptest.NewServer(http.HandlerFunc(handleWebSocket))
		t.Cleanup(srv.Close)
		wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
		conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
		if err != nil {
			t.Fatalf("dial %s: %v", wsURL, err)
		}
		t.Cleanup(func() { conn.Close() })
		return conn
	}

	t.Run("成功", func(t *testing.T) {
		resetContactDirectoryCache(t)
		withImagePath(t, contactExampleAccountDir+"/temp")
		withContactDBKeysPath(t, filepath.Join(t.TempDir(), "WeChatAI", "db-keys.json"))
		stubContactFridaExport(t, func(string, ...any) (any, error) {
			return contactDirectorySample, nil
		})

		conn := newServer(t)
		if err := conn.WriteJSON(map[string]any{
			"action": "get_contact_directory",
			"echo":   "contact-directory",
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
		if got["echo"] != "contact-directory" || got["status"] != "ok" {
			t.Fatalf("响应错误: %v", got)
		}
		data, ok := got["data"].(map[string]any)
		if !ok || data["ok"] != true {
			t.Fatalf("data 不是目录对象: %v", got["data"])
		}
		users, ok := data["users"].(map[string]any)
		if !ok {
			t.Fatalf("data.users 缺失: %v", data)
		}
		alice, ok := users["wxid_alice"].(map[string]any)
		if !ok || alice["display"] != "Alice Display" {
			t.Fatalf("data.users 内容错误: %v", users)
		}
	})

	t.Run("Frida 失败", func(t *testing.T) {
		resetContactDirectoryCache(t)
		withImagePath(t, contactExampleAccountDir+"/temp")
		stubContactFridaExport(t, func(string, ...any) (any, error) {
			return `{"ok":false,"reason":"key_missing"}`, nil
		})

		conn := newServer(t)
		if err := conn.WriteJSON(map[string]any{
			"action": "get_contact_directory",
			"echo":   "contact-directory-2",
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
		if got["echo"] != "contact-directory-2" || got["status"] != "failed" {
			t.Fatalf("响应错误: %v", got)
		}
		if msg, _ := got["error"].(string); !strings.Contains(msg, "key_missing") {
			t.Fatalf("error = %q, want key_missing", msg)
		}
		if _, exists := got["data"]; exists {
			t.Fatalf("失败响应不应带 data: %v", got["data"])
		}
	})
}
