import Foundation

/// 设置页那个「清理缓存」。
///
/// 故意不碰登录态 —— 凭证在 Keychain 里，清掉就等于把人踢下线了。
/// 也不碰下载中转的临时目录 —— 清的时候可能正有个任务在里面写着。
@MainActor
public enum CacheCleaner {

    /// 封面图占的磁盘 + 系统 URL 缓存
    public static func totalSize() -> Int64 {
        CoverImageStore.shared.diskUsage() + Int64(URLCache.shared.currentDiskUsage)
    }

    public static func clearAll() {
        CoverImageStore.shared.clearCache()
        URLCache.shared.removeAllCachedResponses()
        clearCachedUserNames()
    }

    /// 缓存下来的昵称。删了不影响当前会话，下次冷启动重新拉一遍。
    private static func clearCachedUserNames() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("userName-") {
            defaults.removeObject(forKey: key)
        }
    }
}
