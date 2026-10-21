import Foundation

/// bridge 通讯录目录动作的线上契约（见 `docs/hook-contact-directory.md` §3.2/§4）。
///
/// App 只消费 bridge 的 WS 动作回包，不直接读微信数据库：
/// - 请求：`{"action":"get_contact_directory","echo":"contact-directory","params":{}}`
/// - 成功：`{"echo":"contact-directory","status":"ok","data":{ok,generated_at,users,groups,...}}`
/// - 失败：`{"echo":"contact-directory","status":"failed","error":"..."}`
enum OneBotContactDirectory {
    static let action = "get_contact_directory"
    static let echo = "contact-directory"

    /// 固定请求帧；`echo` 是 App 侧识别回包的唯一依据。
    static func requestPayload() -> String {
        #"{"action":"get_contact_directory","echo":"contact-directory","params":{}}"#
    }

    /// 解析 WS 回包。不是通讯录回包（消息事件 / `get_login_info` 回包）时返回 nil，
    /// 让帧继续走事件解析；通讯录请求失败返回 `ok=false` 的快照而不是抛错，
    /// 这样调用方只需按 `ok` 分支，消息链路不受影响。
    static func parseReply(data: Data) -> ContactDirectorySnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return parseReply(object: object)
    }

    /// 已经由调用方解析过一次 JSON 时复用同一对象，避免每个 WS 帧重复解析。
    static func parseReply(object: [String: Any]) -> ContactDirectorySnapshot? {
        guard let echoed = object["echo"] as? String, echoed == echo else { return nil }

        let status = object["status"] as? String
        if let status, status != "ok", status != "async" {
            let reason = (object["error"] as? String)
                ?? (object["message"] as? String)
                ?? status
            return ContactDirectorySnapshot(ok: false, reason: reason)
        }

        // bridge 正常把 Hook 返回的 JSON 解析成对象放进 `data`；
        // 兼容把 JSON 字符串原样透传的实现。
        let payloadData: Data?
        if let payload = object["data"] as? [String: Any] {
            payloadData = try? JSONSerialization.data(withJSONObject: payload)
        } else if let payload = object["data"] as? String {
            payloadData = payload.data(using: .utf8)
        } else {
            payloadData = nil
        }
        guard let payloadData,
              let snapshot = try? JSONDecoder().decode(ContactDirectorySnapshot.self, from: payloadData) else {
            return ContactDirectorySnapshot(ok: false, reason: "bad_payload")
        }
        return snapshot
    }
}

/// 把通讯录目录名落到 `Conversation.title` 的纯逻辑（持久化与 UI 状态由运行时负责）。
///
/// 规则（`docs/hook-contact-directory.md` §5）：
/// - 只在标题为空/占位（`ConversationName.isPlaceholderTitle`）时填；
/// - 用户重命名（非占位标题）绝不覆盖；
/// - 群聊会话只从 `groups` 取名，私聊/公众号只从 `users` 取名；
/// - 失败目录（`ok == false`）不产生任何标题。
enum ContactDirectoryTitles {
    /// 返回需要改标题的会话副本；未命中的会话不出现在结果里。
    static func updatedConversations(
        _ conversations: [Conversation],
        directory: ContactDirectorySnapshot
    ) -> [Conversation] {
        guard directory.ok else { return [] }
        return conversations.compactMap { conversation in
            guard ConversationName.isPlaceholderTitle(
                conversation.title,
                conversationID: conversation.id,
                kind: conversation.kind
            ) else { return nil }
            guard let name = directory.displayName(for: conversation.id, kind: conversation.kind) else {
                return nil
            }
            var updated = conversation
            updated.title = name
            return updated
        }
    }

    /// 新建会话时直接使用的标题，避免先闪一下兜底名。没有目录/无名字时返回 nil。
    static func title(
        for conversationID: String,
        kind: ConversationKind,
        in directory: ContactDirectorySnapshot?
    ) -> String? {
        guard let directory, directory.ok else { return nil }
        return directory.displayName(for: conversationID, kind: kind)
    }
}
