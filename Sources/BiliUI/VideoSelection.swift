import Foundation

/// 挑视频的结果。关键是「全都要」不能写成一串 bvid —— 上千个视频还没加载完，
/// 根本凑不出那个集合，凑出来也只是已经翻过的那几十个，数量就假了。
/// 所以分两种说法：全都要（除了这几个），和只要这几个。
/// 前者不需要加载完也不怕漏，全选才敢真的写「全选」。
public enum VideoSelection: Hashable {

    /// 全都要，除了这几个。默认状态就是 `.all(except: [])`
    case all(except: Set<String>)
    /// 只要这几个
    case only(Set<String>)

    /// 是不是「一个不落」
    public var isEverything: Bool {
        if case .all(let except) = self { return except.isEmpty }
        return false
    }

    public var isEmpty: Bool {
        if case .only(let set) = self { return set.isEmpty }
        return false
    }

    public func contains(_ bvid: String) -> Bool {
        switch self {
        case .all(let except): return !except.contains(bvid)
        case .only(let set): return set.contains(bvid)
        }
    }

    /// 挑了多少个。全都要的时候只有总数能算，减掉排除的就行。
    public func count(total: Int) -> Int {
        switch self {
        case .all(let except): return max(total - except.count, 0)
        case .only(let set): return set.count
        }
    }

    public func toggling(_ bvid: String) -> VideoSelection {
        switch self {
        case .all(var except):
            if except.contains(bvid) { except.remove(bvid) } else { except.insert(bvid) }
            return .all(except: except)
        case .only(var set):
            if set.contains(bvid) { set.remove(bvid) } else { set.insert(bvid) }
            return .only(set)
        }
    }

    /// 全选 / 全部取消
    public var toggledAll: VideoSelection {
        isEverything ? .only([]) : .all(except: [])
    }

    /// 三态复选框的状态
    public var checkState: SelectAllRow.State {
        if isEverything { return .all }
        return isEmpty ? .none : .partial
    }
}
