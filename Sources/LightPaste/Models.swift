import Foundation

enum ClipKind: String, Codable, CaseIterable {
    case text, link, image, files, other
    var label: String {
        switch self { case .text: return "文本"; case .link: return "链接"; case .image: return "图片"; case .files: return "文件"; case .other: return "其他" }
    }
    var symbol: String {
        switch self { case .text: return "text.alignleft"; case .link: return "link"; case .image: return "photo"; case .files: return "doc"; case .other: return "square.on.square" }
    }
}

struct ClipboardRepresentation: Codable, Equatable {
    var type: String
    var data: Data
}

struct ClipboardEntry: Codable, Equatable {
    var representations: [ClipboardRepresentation]
}

struct CapturedClip {
    var entries: [ClipboardEntry]
    var kind: ClipKind
    var title: String
    var text: String
    var sourceName: String
    var sourceBundleID: String?
    /// A secret was found in any of the stored text representations, not only in the summary.
    var containsSecret = false
}

struct ClipItem: Identifiable, Equatable {
    var id: UUID
    var kind: ClipKind
    var title: String
    var text: String
    var sourceName: String
    var sourceBundleID: String?
    var createdAt: Date
    var lastCopiedAt: Date
    var isFavorite: Bool
    /// What the text turned out to be (code, color, secret…); nil for plain content.
    var detail: ClipDetail? = nil
    /// Secrets and one-time codes remove themselves unless favorited.
    var expiresAt: Date? = nil
    /// Text recognized in an image on this Mac. Empty means recognition ran and found nothing.
    var ocrText: String? = nil
    /// Page title fetched for a link. Empty means the fetch ran and failed.
    var linkTitle: String? = nil
}

enum ClipDetail: String, Codable, CaseIterable {
    case color, code, phone, email, otp, sensitive
    var label: String {
        switch self {
        case .color: return "颜色"; case .code: return "代码"; case .phone: return "电话"
        case .email: return "邮箱"; case .otp: return "验证码"; case .sensitive: return "敏感"
        }
    }
    var symbol: String {
        switch self {
        case .color: return "paintpalette"; case .code: return "chevron.left.forwardslash.chevron.right"
        case .phone: return "phone"; case .email: return "envelope"; case .otp: return "number"
        case .sensitive: return "lock"
        }
    }
}

struct FavoriteBoard: Identifiable, Equatable {
    var id: UUID
    var name: String
}

enum SidebarFilter: String, CaseIterable, Identifiable {
    case history, favorites, text, link, image, files
    var id: String { rawValue }
    var title: String {
        switch self { case .history: return "全部历史"; case .favorites: return "我的收藏"; case .text: return "文本"; case .link: return "链接"; case .image: return "图片"; case .files: return "文件" }
    }
    var symbol: String {
        switch self { case .history: return "clock.arrow.circlepath"; case .favorites: return "star"; case .text: return "text.alignleft"; case .link: return "link"; case .image: return "photo"; case .files: return "doc" }
    }
    func matches(_ item: ClipItem) -> Bool {
        switch self { case .history: return true; case .favorites: return item.isFavorite; case .text: return item.kind == .text; case .link: return item.kind == .link; case .image: return item.kind == .image; case .files: return item.kind == .files }
    }
}

/// Copy-date ranges for the drawer filter, measured by the last copy time shown on cards.
enum DateFilter: String, CaseIterable, Identifiable {
    case all, today, yesterday, week, month
    var id: String { rawValue }
    var title: String {
        switch self { case .all: return "全部日期"; case .today: return "今天"; case .yesterday: return "昨天"; case .week: return "最近 7 天"; case .month: return "最近 30 天" }
    }
    func range(now: Date, calendar: Calendar = .current) -> Range<Date>? {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        switch self {
        case .all: return nil
        case .today: return today..<tomorrow
        case .yesterday: return (calendar.date(byAdding: .day, value: -1, to: today) ?? today)..<today
        case .week: return (calendar.date(byAdding: .day, value: -6, to: today) ?? today)..<tomorrow
        case .month: return (calendar.date(byAdding: .day, value: -29, to: today) ?? today)..<tomorrow
        }
    }
}

struct SourceOption {
    let key: String
    let name: String
    var count: Int
}

/// The search line split into words and filters, e.g. “报价 app:微信 type:图片 date:今天 is:收藏”.
/// A filter word with a value it does not know is dropped rather than searched, so typing
/// “type:图” on the way to “type:图片” does not empty the results.
struct SearchQuery: Equatable {
    /// The words left after the filters, separated by spaces.
    var text = ""
    var sources: [String] = []
    var kinds: Set<ClipKind> = []
    var details: Set<ClipDetail> = []
    var date: DateFilter?
    var favoritesOnly = false

    var keywords: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    var hasFilters: Bool { !sources.isEmpty || !kinds.isEmpty || !details.isEmpty || date != nil || favoritesOnly }

    private static let kindWords: [String: ClipKind] = [
        "文本": .text, "文字": .text, "text": .text, "txt": .text,
        "链接": .link, "网址": .link, "link": .link, "url": .link,
        "图片": .image, "截图": .image, "image": .image, "img": .image, "photo": .image,
        "文件": .files, "file": .files, "files": .files
    ]
    private static let detailWords: [String: ClipDetail] = [
        "代码": .code, "code": .code, "颜色": .color, "color": .color, "邮箱": .email, "email": .email, "mail": .email,
        "电话": .phone, "phone": .phone, "tel": .phone, "验证码": .otp, "otp": .otp,
        "敏感": .sensitive, "sensitive": .sensitive, "secret": .sensitive
    ]
    private static let dateWords: [String: DateFilter] = [
        "今天": .today, "today": .today, "昨天": .yesterday, "yesterday": .yesterday,
        "本周": .week, "7天": .week, "最近7天": .week, "week": .week,
        "本月": .month, "30天": .month, "最近30天": .month, "month": .month
    ]
    private static let favoriteWords: Set<String> = ["收藏", "星标", "fav", "favorite", "star", "starred"]

    static func parse(_ line: String) -> SearchQuery {
        var query = SearchQuery()
        var words: [Substring] = []
        for token in line.split(whereSeparator: \.isWhitespace) {
            guard let colon = token.firstIndex(where: { $0 == ":" || $0 == "：" }), colon != token.startIndex else {
                words.append(token); continue
            }
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...]).lowercased()
            switch key {
            case "app", "来源", "应用":
                if !value.isEmpty { query.sources.append(value) }
            case "type", "类型":
                if let kind = kindWords[value] { query.kinds.insert(kind) }
                else if let detail = detailWords[value] { query.details.insert(detail) }
            case "date", "日期", "时间":
                if let date = dateWords[value] { query.date = date }
            case "is", "是":
                if favoriteWords.contains(value) { query.favoritesOnly = true }
            default:
                words.append(token)
            }
        }
        query.text = words.joined(separator: " ")
        return query
    }

    /// The filter part only; the words are matched by the search index.
    func matches(_ item: ClipItem, now: Date = Date()) -> Bool {
        if favoritesOnly && !item.isFavorite { return false }
        if !sources.isEmpty {
            let name = item.sourceName.lowercased(), bundleID = (item.sourceBundleID ?? "").lowercased()
            guard sources.contains(where: { name.contains($0) || bundleID.contains($0) }) else { return false }
        }
        if !kinds.isEmpty || !details.isEmpty {
            guard kinds.contains(item.kind) || item.detail.map(details.contains) == true else { return false }
        }
        if let range = date?.range(now: now), !range.contains(item.lastCopiedAt) { return false }
        return true
    }
}
