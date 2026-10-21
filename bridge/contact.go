package main

// 通讯录目录（好友昵称 / 群名）与 SQLCipher DB key 缓存。
//
// 微信 4.1.15 的入站事件只有 wxid，真实昵称/群名在加密的通讯录数据库里。Hook 在
// 微信进程内解密 contact.db 后通过 RPC 返回 JSON；bridge 缓存目录用于：
//   - 补全入站事件的 sender.nickname / group_name（Hook 事件里只有 wxid）；
//   - 群 @ 时进程内群成员缓存未命中，回退到通讯录昵称；
//   - 把 getContactDirectory 返回的 keys 持久化到
//     ~/Library/Caches/WeChatAI/db-keys.json，bridge 重启且微信未重启时用
//     setDbKeys 回灌，免去重新等登录期派生。
//
// 密钥只出现在内存与 0600 缓存文件中，绝不写日志。
// 契约见 docs/architecture.md §3。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/frida/frida-go/frida"
)

// contactFridaCallTimeout 限制一次 Frida RPC 的等待时间。Hook 未实现导出、
// 导出抛异常或解密卡住时，同步 ExportsCall 可能长时间不返回；WS 处理器是
// 单 goroutine 循环，一旦挂住 App 的整条动作通道就哑了。
const contactFridaCallTimeout = 15 * time.Second

var (
	errContactFridaUnavailable = errors.New("Frida 脚本未就绪")
	errContactPathUnknown      = errors.New("无法从 image_path 推导 db_storage 目录")
)

// ContactEntry 是 hook 返回的单个联系人/群条目（与 hook JSON 字段一致）。
type ContactEntry struct {
	Display  string `json:"display"`
	Nickname string `json:"nickname,omitempty"`
	Remark   string `json:"remark,omitempty"`
	Alias    string `json:"alias,omitempty"`
	// Members 只出现在 groups 条目：群成员 wxid → 群昵称。
	// 同一个人在群里的显示名可能与通讯录昵称/备注不同，群聊场景优先使用。
	Members map[string]ContactEntry `json:"members,omitempty"`
}

// displayName 优先用 hook 计算好的 display；缺失时按备注 → 昵称 → 微信号兜底。
func (e ContactEntry) displayName() string {
	switch {
	case e.Display != "":
		return e.Display
	case e.Remark != "":
		return e.Remark
	case e.Nickname != "":
		return e.Nickname
	default:
		return e.Alias
	}
}

// ContactKey 是单个 DB 的 SQLCipher 密钥（salt 32 hex，key 64 hex）。
// 只在内存与 0600 缓存文件中出现，不写日志。
type ContactKey struct {
	Salt string `json:"salt"`
	Key  string `json:"key"`
}

// ContactDirectory 对应 hook getContactDirectory 返回的 JSON。
// users/groups 是 ID → 显示名条目；keys 是 DB 名（contact/session/...）→ 密钥。
type ContactDirectory struct {
	OK          bool                    `json:"ok"`
	Reason      string                  `json:"reason,omitempty"`
	GeneratedAt int64                   `json:"generated_at,omitempty"`
	WALApplied  int                     `json:"wal_applied,omitempty"`
	Users       map[string]ContactEntry `json:"users,omitempty"`
	Groups      map[string]ContactEntry `json:"groups,omitempty"`
	Keys        map[string]ContactKey   `json:"keys,omitempty"`
}

// contactDirectoryCache 保存最近一次成功获取的目录（RWMutex 保护）。
var contactDirectoryCache struct {
	mu  sync.RWMutex
	dir *ContactDirectory
}

// contactDirectoryRefreshMu 串行化 Frida 目录调用：App 的周期刷新与手动动作
// 可能同时到达，避免并发解密同一批 DB。
var contactDirectoryRefreshMu sync.Mutex

// callFridaExport 是可注入的 Frida RPC 调用封装（包级变量，测试里替换）。
// 生产路径走带超时的 ExportsCallWithContext，避免 Hook 异常时永久阻塞。
var callFridaExport = func(fn string, args ...any) (any, error) {
	if fridaScript == nil {
		return nil, errContactFridaUnavailable
	}
	ctx, cancel := context.WithTimeout(context.Background(), contactFridaCallTimeout)
	defer cancel()
	ret := fridaScript.ExportsCallWithContext(ctx, fn, args...)
	if ret == frida.ErrContextCancelled {
		return nil, fmt.Errorf("Frida %s 调用超时（%s）", fn, contactFridaCallTimeout)
	}
	return ret, nil
}

// deriveDBStoragePath 从 -image_path 推导同账号的 db_storage 目录。
//
// image_path 通常形如 <account_dir>/temp（也可能更深，如 temp/2026-10/Img），
// 返回同级的 <account_dir>/db_storage；容器路径无法识别时返回空串。
func deriveDBStoragePath(imagePath string) string {
	p := strings.TrimSpace(imagePath)
	if p == "" {
		return ""
	}
	// App 在 macOS 上传 POSIX 路径；这里兼容一下 Windows 风格分隔符，
	// 避免把反斜杠路径整段当成一个目录名。
	p = strings.ReplaceAll(p, "\\", "/")
	for strings.HasSuffix(p, "/") {
		p = strings.TrimSuffix(p, "/")
	}
	if p == "" {
		return ""
	}

	// 标准容器路径：.../xwechat_files/<account>/... → .../xwechat_files/<account>/db_storage
	const marker = "xwechat_files/"
	if idx := strings.Index(p, marker); idx >= 0 {
		prefix := p[:idx+len(marker)]
		rest := p[idx+len(marker):]
		account := rest
		if slash := strings.Index(rest, "/"); slash >= 0 {
			account = rest[:slash]
		}
		if account == "" {
			return ""
		}
		return prefix + account + "/db_storage"
	}

	// 非标准布局：<account_dir>/temp[/...] → <account_dir>/db_storage
	if idx := strings.LastIndex(p, "/temp/"); idx > 0 {
		return p[:idx] + "/db_storage"
	}
	if strings.HasSuffix(p, "/temp") {
		return p[:len(p)-len("/temp")] + "/db_storage"
	}
	return ""
}

// parseContactDirectory 解析 hook 返回的 JSON 字符串。错误信息只带偏移/类型，
// 不回显原始 JSON（其中可能含 DB key）。
func parseContactDirectory(raw string) (*ContactDirectory, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, errors.New("通讯录响应为空")
	}
	var dir ContactDirectory
	if err := json.Unmarshal([]byte(raw), &dir); err != nil {
		return nil, fmt.Errorf("通讯录响应不是合法 JSON: %w", err)
	}
	return &dir, nil
}

// contactRPCResultString 把 Frida RPC 返回值统一成字符串。
// hook 约定返回 JSON 字符串；这里兼容 []byte 与其他可 JSON 序列化的值。
func contactRPCResultString(result any) (string, error) {
	switch v := result.(type) {
	case nil:
		return "", errors.New("Hook 未返回通讯录数据")
	case string:
		return v, nil
	case []byte:
		return string(v), nil
	case json.RawMessage:
		return string(v), nil
	default:
		data, err := json.Marshal(v)
		if err != nil {
			return "", fmt.Errorf("通讯录响应序列化失败: %w", err)
		}
		return string(data), nil
	}
}

// storeContactDirectory 更新目录缓存（dir 为 nil 表示清空）。
func storeContactDirectory(dir *ContactDirectory) {
	contactDirectoryCache.mu.Lock()
	contactDirectoryCache.dir = dir
	contactDirectoryCache.mu.Unlock()
}

// directoryUserName 查好友/联系人显示名（只查 users，用于入站 sender 补全）。
func directoryUserName(userID string) string {
	if userID == "" {
		return ""
	}
	contactDirectoryCache.mu.RLock()
	defer contactDirectoryCache.mu.RUnlock()
	if contactDirectoryCache.dir == nil {
		return ""
	}
	return contactDirectoryCache.dir.Users[userID].displayName()
}

// contactGroupDisplayName 查群名（只查 groups）。
func contactGroupDisplayName(groupID string) string {
	if groupID == "" {
		return ""
	}
	contactDirectoryCache.mu.RLock()
	defer contactDirectoryCache.mu.RUnlock()
	if contactDirectoryCache.dir == nil {
		return ""
	}
	return contactDirectoryCache.dir.Groups[groupID].displayName()
}

// directoryGroupMemberName 查群成员在本群的昵称；群或成员未缓存时返回空串。
func directoryGroupMemberName(groupID, userID string) string {
	if groupID == "" || userID == "" {
		return ""
	}
	contactDirectoryCache.mu.RLock()
	defer contactDirectoryCache.mu.RUnlock()
	if contactDirectoryCache.dir == nil {
		return ""
	}
	return contactDirectoryCache.dir.Groups[groupID].Members[userID].displayName()
}

// contactDisplayName 查目录显示名：先联系人，再群（群 ID 以 @chatroom 结尾，
// 与 wxid 不会混淆）。缓存未命中返回空串。
func contactDisplayName(id string) string {
	if id == "" {
		return ""
	}
	contactDirectoryCache.mu.RLock()
	defer contactDirectoryCache.mu.RUnlock()
	if contactDirectoryCache.dir == nil {
		return ""
	}
	if name := contactDirectoryCache.dir.Users[id].displayName(); name != "" {
		return name
	}
	return contactDirectoryCache.dir.Groups[id].displayName()
}

// primeNicknameCache 用目录内容预热 userID2NicknameMap：好友/群 ID 的显示名
// 可按 ID 直接查（群成员级别的 groupID_userID 映射仍由历史消息补充）。
func primeNicknameCache(dir *ContactDirectory) {
	if dir == nil {
		return
	}
	for id, entry := range dir.Users {
		if name := entry.displayName(); name != "" {
			userID2NicknameMap.Store(id, name)
		}
	}
	for id, entry := range dir.Groups {
		if name := entry.displayName(); name != "" {
			userID2NicknameMap.Store(id, name)
		}
		// 群成员级别 key（group_user）供 @ 昵称使用；群昵称优先于通讯录昵称。
		for memberID, member := range entry.Members {
			if memberID == "" {
				continue
			}
			if name := member.displayName(); name != "" {
				userID2NicknameMap.Store(id+"_"+memberID, name)
			}
		}
	}
}

// resolveAtNickname 解析群 @ 的显示昵称：优先历史消息建立的群成员缓存，
// 未命中时回退通讯录目录（docs/architecture.md §3）。
func resolveAtNickname(groupID, userID string) (string, bool) {
	if groupID == "" || userID == "" {
		return "", false
	}
	if nickname, ok := userID2NicknameMap.Load(groupID + "_" + userID); ok {
		if name, ok := nickname.(string); ok && name != "" {
			return name, true
		}
	}
	if name := directoryGroupMemberName(groupID, userID); name != "" {
		return name, true
	}
	if name := directoryUserName(userID); name != "" {
		return name, true
	}
	return "", false
}

// refreshContactDirectory 通过 Frida 拉取最新通讯录目录：
// 推导 db_storage → getContactDirectory → 解析 → 更新缓存、预热昵称、持久化 keys。
func refreshContactDirectory() (*ContactDirectory, error) {
	contactDirectoryRefreshMu.Lock()
	defer contactDirectoryRefreshMu.Unlock()

	dbStoragePath := deriveDBStoragePath(config.ImagePath)
	if dbStoragePath == "" {
		return nil, errContactPathUnknown
	}
	result, err := callFridaExport("getContactDirectory", dbStoragePath)
	if err != nil {
		return nil, err
	}
	raw, err := contactRPCResultString(result)
	if err != nil {
		return nil, err
	}
	dir, err := parseContactDirectory(raw)
	if err != nil {
		return nil, err
	}
	if !dir.OK {
		reason := strings.TrimSpace(dir.Reason)
		if reason == "" {
			reason = "unknown"
		}
		return nil, fmt.Errorf("通讯录不可用：%s", reason)
	}

	storeContactDirectory(dir)
	primeNicknameCache(dir)
	if err := persistContactDBKeys(dir.Keys); err != nil {
		Warn("DB key 缓存写入失败", "err", err)
	}
	// 只记录数量，密钥本身绝不落日志。
	memberCount := 0
	for _, group := range dir.Groups {
		memberCount += len(group.Members)
	}
	Info("通讯录目录已更新", "users", len(dir.Users), "groups", len(dir.Groups),
		"group_members", memberCount, "keys", len(dir.Keys))
	return dir, nil
}

// defaultContactDBKeysFilePath 返回 db-keys.json 默认路径：与 r3-seed.json 同目录。
func defaultContactDBKeysFilePath() string {
	dir, err := os.UserCacheDir()
	if err != nil || dir == "" {
		dir = os.TempDir()
	}
	return filepath.Join(dir, "WeChatAI", "db-keys.json")
}

// contactDBKeysFilePath 是密钥缓存文件路径；包级变量便于测试替换，避免写用户目录。
var contactDBKeysFilePath = defaultContactDBKeysFilePath

// publicCopy 返回不含 keys 的目录副本。DB 密钥只留在 bridge 内存与 0600
// 缓存文件中，不下发 App（避免密钥出现在 App 日志/WS 调试输出）。
func (d *ContactDirectory) publicCopy() *ContactDirectory {
	if d == nil {
		return nil
	}
	c := *d
	c.Keys = nil
	return &c
}

// persistContactDBKeys 原子写入密钥缓存：同目录临时文件（0600）→ rename，
// 目录不存在时创建为 0700。keys 为空时不动已存在的缓存。
func persistContactDBKeys(keys map[string]ContactKey) error {
	if len(keys) == 0 {
		return nil
	}
	data, err := json.Marshal(keys)
	if err != nil {
		return err
	}
	path := contactDBKeysFilePath()
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	// 目录可能由 r3-seed.json 以 0755 创建，这里统一收紧到 0700。
	_ = os.Chmod(dir, 0o700)

	tmp, err := os.CreateTemp(dir, ".db-keys-*.json")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // rename 成功后是 no-op
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, path)
}

// loadContactDBKeys 读取密钥缓存；文件不存在时返回 (nil, nil)。
// 损坏/空条目被丢弃，避免把无效密钥回灌给 hook。
func loadContactDBKeys() (map[string]ContactKey, error) {
	path := contactDBKeysFilePath()
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var keys map[string]ContactKey
	if err := json.Unmarshal(data, &keys); err != nil {
		return nil, fmt.Errorf("解析 %s 失败: %w", filepath.Base(path), err)
	}
	valid := make(map[string]ContactKey, len(keys))
	for name, key := range keys {
		if strings.TrimSpace(key.Salt) == "" || strings.TrimSpace(key.Key) == "" {
			continue
		}
		valid[name] = key
	}
	return valid, nil
}

// restoreContactDBKeys 在 Frida ready 后把缓存密钥回灌给 hook（setDbKeys）。
// 没有缓存/回灌失败都只记日志，不影响 bridge 启动；密钥内容不打印。
func restoreContactDBKeys() {
	keys, err := loadContactDBKeys()
	if err != nil {
		Warn("读取 DB key 缓存失败", "err", err)
		return
	}
	if len(keys) == 0 {
		Info("无 DB key 缓存，等待 Hook 捕获登录期派生")
		return
	}
	data, err := json.Marshal(keys)
	if err != nil {
		Warn("DB key 缓存序列化失败", "err", err)
		return
	}
	if _, err := callFridaExport("setDbKeys", string(data)); err != nil {
		Warn("回灌 DB key 缓存失败", "err", err)
		return
	}
	Info("已向 Hook 回灌 DB key 缓存", "dbs", len(keys))
}

// enrichIncomingSender 用通讯录目录补全入站事件：
//   - 非自消息且 sender.user_id 命中 users.display 时覆盖 sender.nickname；
//   - 群事件（不论是否自消息）附带 group_name；查不到时保持原样不写。
//
// 必须在 normalizeIncomingIdentity 之后调用（那时 sender/self_id 已归一化）。
func enrichIncomingSender(payload map[string]interface{}) {
	if payload == nil {
		return
	}

	isSelf, _ := payload["is_self"].(bool)
	sender, _ := payload["sender"].(map[string]interface{})
	userID := ""
	if sender != nil {
		userID, _ = sender["user_id"].(string)
	}
	if userID == "" {
		userID, _ = payload["user_id"].(string)
	}
	groupID, _ := payload["group_id"].(string)
	if !isSelf && sender != nil && userID != "" {
		// 群聊优先群昵称（同一个人在群里可能用完全不同的名字），
		// 群成员未缓存时回退通讯录显示名。
		name := ""
		if groupID != "" {
			name = directoryGroupMemberName(groupID, userID)
		}
		if name == "" {
			name = directoryUserName(userID)
		}
		if name != "" {
			sender["nickname"] = name
		}
	}

	if groupID != "" {
		if name := contactGroupDisplayName(groupID); name != "" {
			payload["group_name"] = name
		}
	}
}
