import Foundation
import BiliCore

public enum BiliError: LocalizedError {
    case notLoggedIn
    case shortLinkFailed
    case api(code: Int, message: String)
    case badResponse
    case noStream
    case emptyFile
    /// 请求被 B 站风控拦下来了。返回的是 412 那张 HTML 拦截页，不是接口自己的错误码，
    /// 所以这儿的判断在 get() 里，不在 decode() 里。
    case riskControl

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "需要登录后才能拿到这个画质"
        case .shortLinkFailed:
            return "短链没能展开，请改用完整链接"
        case .api(_, let message):
            return message
        case .badResponse:
            return "服务器返回了看不懂的内容"
        case .noStream:
            return "没有找到可下载的流"
        case .emptyFile:
            return "下到的文件是空的"
        case .riskControl:
            // 说清楚该往「网络」上想，不然用户只会觉得是我们 App 坏了。
            // 实测换个网络出口（比如切到手机流量）立刻就好。
            // 措辞留有余地：B 站偶尔也用 412 表示别的意思，别把话说死。
            return "可能被风控拦截，请换个网络再试"
        }
    }
}

/// B 站 API 客户端。持有登录 Cookie，负责 WBI 签名。
public actor BiliClient {

    public static let shared = BiliClient()

    /// 不设 Cookie 存储，Cookie 一律手动塞请求头，
    /// 免得 URLSession 自己的 Cookie 库和 WKWebView 那套打架。
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let session: URLSession
    private var credential: BiliCredential?
    private var cachedWBIKeys: WBIKeys?

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: configuration)
    }

    public func setCredential(_ credential: BiliCredential?) {
        self.credential = credential
        self.cachedWBIKeys = nil
    }

    public var isLoggedIn: Bool { credential != nil }

    // MARK: - 短链

    public func resolveShortLink(_ code: String) async throws -> VideoRef {
        guard let url = URL(string: "https://b23.tv/\(code)") else { throw BiliError.shortLinkFailed }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        if let final = response.url?.absoluteString,
           let ref = ShareLinkParser.parse(final)?.ref, ref.isResolved {
            return ref
        }
        if let body = String(data: data, encoding: .utf8),
           let ref = ShareLinkParser.parse(body)?.ref, ref.isResolved {
            return ref
        }
        throw BiliError.shortLinkFailed
    }

    public func resolve(_ ref: VideoRef) async throws -> VideoRef {
        switch ref {
        case .shortLink(let code): return try await resolveShortLink(code)
        default: return ref
        }
    }

    // MARK: - 视频信息

    public func videoInfo(ref: VideoRef) async throws -> VideoInfo {
        let resolved = try await resolve(ref)

        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/view")!
        switch resolved {
        case .bvid(let bvid):
            components.queryItems = [URLQueryItem(name: "bvid", value: bvid)]
        case .avid(let aid):
            components.queryItems = [URLQueryItem(name: "aid", value: String(aid))]
        case .shortLink:
            throw BiliError.shortLinkFailed
        }

        let data = try await get(components.url!)
        let payload = try decode(ViewData.self, from: data)

        return VideoInfo(
            bvid: payload.bvid,
            aid: payload.aid,
            title: payload.title,
            coverURL: Self.secureURL(payload.pic),
            ownerName: payload.owner.name,
            pages: payload.pages.map {
                VideoPage(cid: $0.cid, page: $0.page, title: $0.part, duration: $0.duration)
            }
        )
    }

    // MARK: - 收藏夹

    /// 自己创建的收藏夹（含默认收藏夹）。
    ///
    /// 这个列表接口本身**不带封面**：`created/list` 那个分页版倒是有个 cover 字段，
    /// 但实测永远是空串，等于没有。所以收藏夹在界面上统一用灰底占位图，不去取封面。
    ///
    /// 曾经试着按夹子并发去 `fav/resource/list` 里翻第一条的封面 —— 别再加回来了。
    /// 那个接口现在有风控，本来一次只发一个请求都可能被拦，并发发 N 个等于自投罗网：
    /// 实测会把整个出口 IP 打进黑名单，之后连打开收藏夹都会 412
    /// （换到手机流量立刻恢复，所以确实是按 IP 算的账）。
    /// 拿 N 个请求换几张列表缩略图，这个代价不值。
    public func favoriteFolders() async throws -> [FavFolder] {
        guard let credential, !credential.userId.isEmpty else { throw BiliError.notLoggedIn }

        var components = URLComponents(string: "https://api.bilibili.com/x/v3/fav/folder/created/list-all")!
        components.queryItems = [URLQueryItem(name: "up_mid", value: credential.userId)]

        let data = try await get(components.url!)
        let payload = try decode(FavFolderListData.self, from: data)

        return (payload.list ?? []).map {
            FavFolder(
                id: $0.id,
                title: $0.title,
                mediaCount: $0.media_count,
                // attr 是按位来的：bit0 = 私密，bit1 = 非默认收藏夹。
                // 直接判 == 1 会漏掉「私密且非默认」的（那种是 3）。
                isPrivate: ($0.attr ?? 0) & 1 == 1
            )
        }
    }

    /// 某个收藏夹里的一页内容。一页 20 条，和网页端一致。
    public func favoriteItems(folderID: Int, page: Int = 1) async throws -> (items: [FavItem], hasMore: Bool) {
        var components = URLComponents(string: "https://api.bilibili.com/x/v3/fav/resource/list")!
        components.queryItems = [
            URLQueryItem(name: "media_id", value: String(folderID)),
            URLQueryItem(name: "pn", value: String(page)),
            URLQueryItem(name: "ps", value: "20"),
            URLQueryItem(name: "platform", value: "web")
        ]

        let data = try await get(components.url!)
        let payload = try decode(FavResourceData.self, from: data)

        let items = (payload.medias ?? []).compactMap { media -> FavItem? in
            // 失效稿件没有 bvid，跳过
            guard let bvid = media.bvid, !bvid.isEmpty else { return nil }
            return FavItem(
                bvid: bvid,
                title: media.title,
                coverURL: Self.secureURL(media.cover),
                duration: media.duration,
                upperName: media.upper?.name ?? "",
                pageCount: media.page ?? 1
            )
        }
        return (items, payload.has_more)
    }

    // MARK: - UP 主投稿 / 合集

    /// 展开一类「一整批」来源的一页。第一页顺带把来源自己的信息也拉回来
    /// （UP 主的昵称头像 / 合集的名字封面），列表行要显示的就是这些。
    public func bulkPage(_ source: BulkSource, page: Int) async throws -> BulkResult {
        switch source {
        case .uploads(let mid):
            return try await uploadsPage(mid: mid, page: page)
        case .collection(let mid, let seasonID):
            return try await collectionPage(mid: mid, seasonID: seasonID, page: page)
        }
    }

    /// UP 主投稿列表。这个接口上了 WBI 签名，不签会被直接拦掉。
    private func uploadsPage(mid: Int, page: Int) async throws -> BulkResult {
        var components = URLComponents(string: "https://api.bilibili.com/x/space/wbi/arc/search")!
        components.queryItems = try await signedQuery([
            "mid": String(mid),
            "order": "pubdate",
            "pn": String(page),
            "ps": "30",
            "platform": "web",
            "web_location": "1550101"
        ])

        let data = try await get(components.url!)
        let payload = try decode(SpaceArcData.self, from: data)

        let videos = (payload.list?.vlist ?? []).map {
            BulkVideo(
                bvid: $0.bvid,
                title: $0.title,
                coverURL: Self.secureURL($0.pic),
                duration: Self.seconds(fromLength: $0.length),
                // 投稿列表不带分 P 数，多 P 的在入队展开时才知道
                pageCount: 1
            )
        }
        let total = payload.page?.count ?? videos.count

        var profile: UserProfile?
        if page == 1 {
            // 头像拿不到不算错，行里少张图而已
            profile = try? await userProfile(mid: mid)
        }

        return BulkResult(
            videos: videos,
            total: total,
            hasMore: !videos.isEmpty && page * 30 < total,
            profile: profile
        )
    }

    /// UP 主的昵称和头像。
    public func userProfile(mid: Int) async throws -> UserProfile {
        var components = URLComponents(string: "https://api.bilibili.com/x/space/wbi/acc/info")!
        components.queryItems = try await signedQuery(["mid": String(mid), "platform": "web"])

        let data = try await get(components.url!)
        let payload = try decode(SpaceUserData.self, from: data)
        return UserProfile(mid: mid, name: payload.name, avatarURL: Self.secureURL(payload.face))
    }

    /// 合集里的一页。这个接口不强制签名，Referer 带上就行（get 里已经带了）。
    private func collectionPage(mid: Int, seasonID: Int, page: Int) async throws -> BulkResult {
        var components = URLComponents(string: "https://api.bilibili.com/x/polymer/web-space/seasons_archives_list")!
        components.queryItems = [
            URLQueryItem(name: "mid", value: String(mid)),
            URLQueryItem(name: "season_id", value: String(seasonID)),
            URLQueryItem(name: "page_num", value: String(page)),
            URLQueryItem(name: "page_size", value: "30"),
            URLQueryItem(name: "sort_reverse", value: "false"),
            URLQueryItem(name: "web_location", value: "333.999")
        ]

        let data = try await get(components.url!)
        let payload = try decode(SeasonArchivesData.self, from: data)

        let videos = payload.archives.map {
            BulkVideo(
                bvid: $0.bvid,
                title: $0.title,
                coverURL: Self.secureURL($0.pic),
                // 合集接口直接给秒数，和投稿那边的 "12:34" 不一样
                duration: $0.duration,
                pageCount: 1
            )
        }
        let total = payload.meta?.total ?? payload.page?.total ?? videos.count

        return BulkResult(
            videos: videos,
            total: total,
            hasMore: !videos.isEmpty && page * 30 < total,
            collectionTitle: payload.meta?.name,
            collectionCoverURL: Self.secureURL(payload.meta?.cover ?? ""),
            collectionID: payload.meta?.season_id ?? seasonID
        )
    }

    // MARK: - 我订阅的合集

    /// 收藏页「合集」那一栏。platform=web 才会把合集一起带回来。
    public func subscribedCollections(page: Int = 1) async throws -> (items: [SubscribedCollection], hasMore: Bool) {
        guard let credential, !credential.userId.isEmpty else { throw BiliError.notLoggedIn }

        var components = URLComponents(string: "https://api.bilibili.com/x/v3/fav/folder/collected/list")!
        components.queryItems = [
            URLQueryItem(name: "up_mid", value: credential.userId),
            URLQueryItem(name: "pn", value: String(page)),
            URLQueryItem(name: "ps", value: "20"),
            URLQueryItem(name: "platform", value: "web")
        ]

        let data = try await get(components.url!)
        let payload = try decode(CollectedListData.self, from: data)

        let items = (payload.list ?? []).map {
            SubscribedCollection(
                seasonID: $0.id,
                mid: $0.mid,
                title: $0.title,
                coverURL: Self.secureURL($0.cover ?? ""),
                videoCount: $0.media_count,
                ownerName: $0.upper?.name ?? ""
            )
        }
        return (items, items.count >= 20)
    }

    /// 打开订阅列表里的一条。这个列表里收藏夹和合集是混在一起的，
    /// 文档上没给区分的字段，所以先按合集查，查不到再按收藏夹查。
    public func collectedItems(_ entry: SubscribedCollection, page: Int) async throws -> BulkResult {
        do {
            let result = try await collectionPage(mid: entry.mid, seasonID: entry.seasonID, page: page)
            // 合集接口认了但一条都没有 —— 多半这压根就是个收藏夹，换个接口再试
            if !result.videos.isEmpty || result.total > 0 || page > 1 { return result }
        } catch {
            // 合集查不到，往下走收藏夹
        }

        let fav = try await favoriteItems(folderID: entry.seasonID, page: page)
        return BulkResult(
            videos: fav.items.map {
                BulkVideo(
                    bvid: $0.bvid,
                    title: $0.title,
                    coverURL: $0.coverURL,
                    duration: $0.duration,
                    pageCount: $0.pageCount
                )
            },
            total: fav.hasMore ? page * 20 + 1 : (page - 1) * 20 + fav.items.count,
            hasMore: fav.hasMore,
            collectionTitle: entry.title,
            // 收藏夹那条路没有合集信息，用列表里带回来的封面
            collectionCoverURL: entry.coverURL,
            collectionID: entry.seasonID
        )
    }

    // MARK: - 我追的番 / 我追的剧

    /// 追番 / 追剧列表。`type`：1 = 番剧（含国创），2 = 影视（剧 / 电影 / 纪录片 / 综艺）。
    ///
    /// 列表里是**一整季**，不是单个分集 —— 分集见 `seasonEpisodes(seasonID:)`。
    /// 这个接口上了 WBI 签名。
    public func followedSeasons(type: Int, page: Int = 1) async throws -> (items: [FollowedSeason], hasMore: Bool) {
        guard let credential, !credential.userId.isEmpty else { throw BiliError.notLoggedIn }

        let perPage = 15
        var components = URLComponents(string: "https://api.bilibili.com/x/space/bangumi/follow/list")!
        components.queryItems = try await signedQuery([
            "type": String(type),
            // 0 = 全部。1 / 2 / 3 分别是想看 / 在看 / 看过，
            // 这儿要的是「我追的」全部，不按状态分
            "follow_status": "0",
            "pn": String(page),
            "ps": String(perPage),
            "vmid": credential.userId,
            "web_location": "333.1387"
        ])

        let data = try await get(components.url!)
        let payload = try decode(FollowListData.self, from: data)

        let items = (payload.list ?? []).map {
            FollowedSeason(
                seasonID: $0.season_id,
                title: $0.title,
                coverURL: Self.secureURL($0.cover),
                episodeCount: $0.total_count,
                // 「更新至第220话」。没开播 / 没更新过的这儿是空的
                progressText: $0.new_ep?.index_show ?? ""
            )
        }
        let total = payload.total ?? 0
        return (items, !items.isEmpty && page * perPage < total)
    }

    /// 一季的全部分集。
    ///
    /// **不分页**：一个 season 的分集是一次全给的（几百集也一次给完）。
    /// 电影这种只有一集，就是「正片」那一条。
    ///
    /// 两个坑：这个接口**不套 `data`**，结果直接摆在顶层 `result` 里；
    /// 还有 `duration` 是**毫秒**（收藏夹那边是秒），这儿除掉了。
    ///
    /// 顺带一个坑：路径**没有 `x/`**。`api.bilibili.com/x/pgc/...` 会回 404 的
    /// HTML 页（openresty 那张），解码的时候只会报一句「读不到」——
    /// 别的接口几乎都带那个 `x/`，就这个不带。
    public func seasonEpisodes(seasonID: Int) async throws -> [FavItem] {
        var components = URLComponents(string: "https://api.bilibili.com/pgc/view/web/season")!
        components.queryItems = [URLQueryItem(name: "season_id", value: String(seasonID))]

        let data = try await get(components.url!)
        let payload = try decodeResult(SeasonData.self, from: data)

        return payload.episodes.map {
            FavItem(
                bvid: $0.bvid,
                // show_title 是「第1话 为了消灭鬼舞辻无惨」这种拼好的整句，
                // 单独一个 title 只有「1」。接口没给整句才退回 title。
                title: $0.show_title ?? $0.title,
                coverURL: Self.secureURL($0.cover),
                duration: $0.duration / 1000,
                // 分集这一页不报 UP 主：一季的投稿人就是版权方，
                // 每一行都挂同一个名字没有意义
                upperName: "",
                pageCount: 1
            )
        }
    }

    // MARK: - 稍后再看 / 历史记录

    /// 稍后再看。**不分页**：B 站这个列表最多就 100 条，一次给全。
    /// 返回的 `total` 是接口报的条数，界面拿它当「全选」的数。
    ///
    /// 这个接口本身不查 WBI 签名，但还是照签 —— 签了在查 / 不查两种情况下都能过，
    /// 不签就押在「它确实不查」上，哪天 B 站加一道就得回来改。
    /// 签名用的 keys 是缓存的，这儿不多花一个请求。
    public func watchLater() async throws -> (items: [FavItem], total: Int) {
        var components = URLComponents(string: "https://api.bilibili.com/x/v2/history/toview")!
        components.queryItems = try await signedQuery(["web_location": "333.1387"])

        let data = try await get(components.url!)
        let payload = try decode(ToViewData.self, from: data)

        // 这个接口给的是完整的稿件对象，字段跟收藏夹那两个不一样：
        // 封面叫 pic、UP 主在 owner.name 里、分 P 数是 videos。
        let items = (payload.list ?? []).compactMap { entry -> FavItem? in
            // 失效稿件没有 bvid，下不了，跳过
            guard let bvid = entry.bvid, !bvid.isEmpty else { return nil }
            return FavItem(
                bvid: bvid,
                title: entry.title,
                coverURL: Self.secureURL(entry.pic ?? ""),
                duration: entry.duration ?? 0,
                upperName: entry.owner?.name ?? "",
                pageCount: entry.videos ?? 1
            )
        }
        return (items, payload.count ?? items.count)
    }

    /// 历史记录。游标翻页：`cursor` 传上一页拿到的那个，第一页传 nil。
    ///
    /// 这个接口上了 WBI 签名。里面的条目什么都有（视频 / 直播 / 专栏 / 番剧），
    /// 只有带 bvid 的才是能下的视频，其余的在这儿滤掉。
    ///
    /// `hasMore` 判的是「这一页有没有东西」：历史这边没有总数，翻到头就是空页。
    /// 宁可多问一次空的，也别拿一个猜的结束条件把后面的记录截掉。
    public func history(cursor: HistoryCursor?) async throws -> (items: [FavItem], hasMore: Bool, cursor: HistoryCursor) {
        var components = URLComponents(string: "https://api.bilibili.com/x/web-interface/history/cursor")!
        components.queryItems = try await signedQuery([
            "ps": "30",
            "max": String(cursor?.max ?? 0),
            "view_at": String(cursor?.viewAt ?? 0),
            "business": cursor?.business ?? "",
            "web_location": "333.1387"
        ])

        let data = try await get(components.url!)
        let payload = try decode(HistoryData.self, from: data)

        let raw = payload.list ?? []
        let items = raw.compactMap { entry -> FavItem? in
            // 直播 / 专栏那几条 bvid 是空串，只有视频能下
            guard let bvid = entry.history?.bvid, !bvid.isEmpty else { return nil }
            return FavItem(
                bvid: bvid,
                title: entry.title,
                coverURL: Self.secureURL(entry.cover ?? ""),
                duration: entry.duration ?? 0,
                upperName: entry.author_name ?? "",
                pageCount: entry.videos ?? 1,
                playedAt: entry.view_at.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }

        let next = payload.cursor.map {
            HistoryCursor(max: $0.max, viewAt: $0.view_at, business: $0.business)
        } ?? cursor ?? HistoryCursor(max: 0, viewAt: 0, business: "")
        // 判空用**原始**那一条：整页都是直播 / 专栏的时候 items 是空的，
        // 但记录还没翻完，不能就此停住
        return (items, !raw.isEmpty, next)
    }

    // MARK: - 取流

    /// qn 直接要最高，服务器会按当前账号的权限降级。
    /// 不登录就是普通画质，登录了就是账号能看的最高画质，不碰会员内容。
    public func playInfo(bvid: String, cid: Int) async throws -> PlayInfo {
        let keys = try await wbiKeys()

        let signed = keys.sign(params: [
            "bvid": bvid,
            "cid": String(cid),
            "qn": "127",
            "fnver": "0",
            "fnval": "4048",
            "fourk": "1"
        ])

        var components = URLComponents(string: "https://api.bilibili.com/x/player/wbi/playurl")!
        components.queryItems = signed
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }

        let data = try await get(components.url!)
        let payload = try decode(PlayData.self, from: data)

        var videos: [MediaStream] = []
        var audios: [MediaStream] = []

        if let dash = payload.dash {
            videos = dash.video.compactMap { item in
                guard let url = URL(string: item.baseUrl) else { return nil }
                return MediaStream(
                    url: url,
                    qualityID: item.id,
                    bandwidth: item.bandwidth,
                    codecID: item.codecid,
                    codecs: item.codecs ?? "",
                    mimeType: item.mimeType ?? "video/mp4",
                    width: item.width,
                    height: item.height,
                    backupURLs: (item.backupUrl ?? []).compactMap(URL.init(string:))
                )
            }
            audios = (dash.audio ?? []).compactMap { item in
                guard let url = URL(string: item.baseUrl) else { return nil }
                return MediaStream(
                    url: url,
                    qualityID: item.id,
                    bandwidth: item.bandwidth,
                    codecID: 0,
                    codecs: item.codecs ?? "",
                    mimeType: item.mimeType ?? "audio/mp4",
                    backupURLs: (item.backupUrl ?? []).compactMap(URL.init(string:))
                )
            }
        }

        guard !videos.isEmpty else { throw BiliError.noStream }

        return PlayInfo(
            duration: dash(payload)?.duration ?? payload.timelength / 1000,
            videos: videos,
            audios: audios,
            acceptQuality: payload.accept_quality ?? []
        )
    }

    private func dash(_ payload: PlayData) -> PlayData.Dash? { payload.dash }

    // MARK: - 下载

    /// 给 CDN 用的请求头。缺 Referer 会被直接 403。
    public nonisolated func mediaHeaders() -> [String: String] {
        [
            "User-Agent": Self.userAgent,
            "Referer": "https://www.bilibili.com/",
            "Origin": "https://www.bilibili.com"
        ]
    }

    // MARK: - 内部

    private func wbiKeys() async throws -> WBIKeys {
        if let cachedWBIKeys { return cachedWBIKeys }

        let data = try await get(URL(string: "https://api.bilibili.com/x/web-interface/nav")!)
        let envelope = try JSONDecoder().decode(Envelope<NavData>.self, from: data)
        guard let nav = envelope.data else { throw BiliError.badResponse }

        let keys = WBIKeys(imgURL: nav.wbi_img.img_url, subURL: nav.wbi_img.sub_url)
        cachedWBIKeys = keys
        return keys
    }

    /// 取当前登录用户的昵称和头像，界面拿它显示账号。
    /// 没登录时 nav 会回 -101，这里当失败处理。
    ///
    /// 昵称和头像都从同一个 nav 接口出来，所以合成一次请求 ——
    /// 分成两个方法就是同一个接口打两遍。
    public func navProfile() async throws -> NavProfile {
        let data = try await get(URL(string: "https://api.bilibili.com/x/web-interface/nav")!)
        let profile = try decode(NavProfileData.self, from: data)
        guard let name = profile.uname, !name.isEmpty else { throw BiliError.notLoggedIn }
        return NavProfile(name: name, avatarURL: profile.face.flatMap(Self.secureURL))
    }

    /// 签名 + 排序。签名算的就是排好序的那串，发出去时顺序也得对得上。
    private func signedQuery(_ params: [String: String]) async throws -> [URLQueryItem] {
        let keys = try await wbiKeys()
        return keys.sign(params: params)
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    /// 投稿接口的时长是 "12:34"（长的还有 "1:02:03"），收藏那边直接给秒数。
    static func seconds(fromLength length: String) -> Int {
        let parts = length.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        if let credential {
            request.setValue(credential.cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BiliError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            guard http.statusCode != 412 else { throw BiliError.riskControl }
            throw BiliError.api(code: http.statusCode, message: "HTTP \(http.statusCode)")
        }
        return data
    }

    /// B 站图床返回的是明文 http://i0.hdslb.com/... 和 //i0.hdslb.com/...，
    /// ATS 默认拦明文 HTTP，封面会一直下不来。统一升成 https。
    static func secureURL(_ string: String) -> URL? {
        var value = string
        if value.hasPrefix("//") {
            value = "https:" + value
        } else if value.hasPrefix("http://") {
            value = "https://" + value.dropFirst("http://".count)
        }
        return URL(string: value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        guard envelope.code == 0 else {
            if envelope.code == -101 { throw BiliError.notLoggedIn }
            throw BiliError.api(code: envelope.code, message: envelope.message ?? "请求失败（\(envelope.code)）")
        }
        guard let payload = envelope.data else { throw BiliError.badResponse }
        return payload
    }

    /// 跟 `decode` 一样，只是结果取的是顶层 `result`。
    /// PGC 那一套接口（season、ep）不套 `data` 那一层，别的接口都套。
    private func decodeResult<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let envelope = try JSONDecoder().decode(ResultEnvelope<T>.self, from: data)
        guard envelope.code == 0 else {
            if envelope.code == -101 { throw BiliError.notLoggedIn }
            throw BiliError.api(code: envelope.code, message: envelope.message ?? "请求失败（\(envelope.code)）")
        }
        guard let payload = envelope.result else { throw BiliError.badResponse }
        return payload
    }
}

// MARK: - 响应结构

private struct Envelope<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: T?
}

/// PGC 那一套用的信封：结果在顶层 `result` 里，不是 `data`。
private struct ResultEnvelope<T: Decodable>: Decodable {
    let code: Int
    let message: String?
    let result: T?
}

private struct NavProfileData: Decodable {
    let uname: String?
    /// 头像是 `//i0.hdslb.com/...` 这种协议相对写法，交给 secureURL 补全
    let face: String?
}

/// 登录用户的自报家门：昵称 + 头像。就这两个字段。
public struct NavProfile: Sendable {
    public let name: String
    public let avatarURL: URL?

    public init(name: String, avatarURL: URL?) {
        self.name = name
        self.avatarURL = avatarURL
    }
}

private struct NavData: Decodable {
    struct WBI: Decodable {
        let img_url: String
        let sub_url: String
    }
    let wbi_img: WBI
}

private struct ViewData: Decodable {
    struct Owner: Decodable { let name: String }
    struct Page: Decodable {
        let cid: Int
        let page: Int
        let part: String
        let duration: Int
    }

    let bvid: String
    let aid: Int
    let title: String
    let pic: String
    let owner: Owner
    let pages: [Page]
}

private struct PlayData: Decodable {
    struct Dash: Decodable {
        struct Video: Decodable {
            let id: Int
            let baseUrl: String
            let backupUrl: [String]?
            let bandwidth: Int
            let codecid: Int
            let codecs: String?
            let mimeType: String?
            let width: Int?
            let height: Int?
        }
        struct Audio: Decodable {
            let id: Int
            let baseUrl: String
            let backupUrl: [String]?
            let bandwidth: Int
            let codecs: String?
            let mimeType: String?
        }

        let duration: Int
        let video: [Video]
        let audio: [Audio]?
    }

    let dash: Dash?
    let timelength: Int
    let accept_quality: [Int]?
    let accept_description: [String]?
}

private struct FavFolderListData: Decodable {
    struct Folder: Decodable {
        let id: Int
        let title: String
        let media_count: Int
        /// 位域：bit0 私密，bit1 非默认收藏夹
        let attr: Int?
        // 这个接口不返回封面，别再往这儿加 cover 了 —— 封面是并发去
        // resource/list 里取的，见 folderCover(folderID:)
    }
    let list: [Folder]?
}

private struct SpaceArcData: Decodable {
    struct VideoList: Decodable {
        struct Video: Decodable {
            let bvid: String
            let title: String
            let pic: String
            /// "12:34"，不是秒数
            let length: String
        }
        let vlist: [Video]?
    }
    struct Page: Decodable { let count: Int }

    let list: VideoList?
    let page: Page?
}

private struct SpaceUserData: Decodable {
    let name: String
    let face: String
}

private struct SeasonArchivesData: Decodable {
    struct Meta: Decodable {
        let name: String
        let cover: String?
        let total: Int
        let season_id: Int?
        let mid: Int?
    }
    struct Archive: Decodable {
        let bvid: String
        let title: String
        let pic: String
        /// 秒
        let duration: Int
    }
    struct Page: Decodable { let total: Int }

    let meta: Meta?
    let archives: [Archive]
    let page: Page?
}

private struct CollectedListData: Decodable {
    struct Item: Decodable {
        struct Upper: Decodable { let name: String }
        let id: Int
        let mid: Int
        let title: String
        let cover: String?
        let media_count: Int
        let upper: Upper?
    }
    let list: [Item]?
    let count: Int?
}

private struct FavResourceData: Decodable {
    struct Media: Decodable {
        struct Upper: Decodable { let name: String }
        let bvid: String?
        let title: String
        let cover: String
        let duration: Int
        /// 分 P 数量
        let page: Int?
        let upper: Upper?
    }
    let medias: [Media]?
    let has_more: Bool
}

/// 追番 / 追剧列表。里面是**一季**，没有 bvid —— 分集另问（SeasonData）。
private struct FollowListData: Decodable {
    struct Season: Decodable {
        struct NewEp: Decodable {
            /// 「更新至第220话」
            let index_show: String?
        }
        let season_id: Int
        let title: String
        let cover: String
        /// 一共几集
        let total_count: Int
        let new_ep: NewEp?
    }
    let list: [Season]?
    let total: Int?
}

/// 一季的分集。字段跟别的接口对不上，是 PGC 那一套自己的：
/// `duration` 是**毫秒**，标题拼好的整句在 `show_title` 里。
private struct SeasonData: Decodable {
    struct Episode: Decodable {
        let bvid: String
        let title: String
        let long_title: String?
        let show_title: String?
        let cover: String
        /// 毫秒
        let duration: Int
    }
    let episodes: [Episode]
}

/// 稍后再看。给的是完整的稿件对象：封面是 `pic`、UP 主在 `owner` 里、
/// 分 P 数是 `videos` —— 跟收藏夹那边（cover / upper / page）不是一套写法。
///
/// 数字都写成可空：失效稿件的这几个字段是缺的，硬解会让**整页**解不出来
///（一条坏的拖垮三十条），缺的按 0 算，后面反正会被 bvid 那道滤掉。
private struct ToViewData: Decodable {
    struct Entry: Decodable {
        struct Owner: Decodable { let name: String }
        let bvid: String?
        let title: String
        let pic: String?
        /// 秒
        let duration: Int?
        /// 分 P 数量
        let videos: Int?
        let owner: Owner?
    }
    let count: Int?
    let list: [Entry]?
}

/// 历史记录。条目里混着直播 / 专栏 / 番剧，只有 `history.bvid` 有值的是视频。
/// 数字同样可空 —— 直播那几条就没有 `duration` / `videos`。
private struct HistoryData: Decodable {
    struct Cursor: Decodable {
        let max: Int
        let view_at: Int
        let business: String
    }
    struct Entry: Decodable {
        struct History: Decodable {
            let bvid: String?
        }
        let title: String
        let cover: String?
        /// 秒
        let duration: Int?
        let videos: Int?
        let author_name: String?
        /// 上次看这条的时间，unix 秒
        let view_at: Int?
        let history: History?
    }
    /// 翻到头的时候这个也可能不给，所以可空 —— 缺了就把传进来的游标原样带回去
    let cursor: Cursor?
    let list: [Entry]?
}
