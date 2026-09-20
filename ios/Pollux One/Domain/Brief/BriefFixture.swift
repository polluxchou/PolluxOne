import Foundation

/// 测试台是命令行二进制，没有 app bundle，所以加载器必须接受路径。
/// app 里走 `loadFromBundle()`，harness 走 `load(at:)`。
enum BriefFixture {
    enum LoadError: Error, CustomStringConvertible {
        case missing(String)
        case undecodable(String)

        var description: String {
            switch self {
            case .missing(let path): "读不到 fixture：\(path)"
            case .undecodable(let why): "fixture 解不开：\(why)"
            }
        }
    }

    static func load(at path: String) throws -> Brief {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LoadError.missing(path)
        }
        do {
            return try JSONDecoder().decode(Brief.self, from: data)
        } catch {
            throw LoadError.undecodable(String(describing: error))
        }
    }

    static func loadFromBundle() throws -> Brief {
        guard let url = Bundle.main.url(forResource: "brief-fixture", withExtension: "json") else {
            throw LoadError.missing("brief-fixture.json (bundle)")
        }
        return try JSONDecoder().decode(Brief.self, from: Data(contentsOf: url))
    }

    /// bundle 里放 demo 稿的那个目录名。
    static let demoDirectory = "demo-briefs"

    /// 一个目录里的所有 `.json`，逐个解。
    ///
    /// 三条规矩：
    ///
    /// 1. **一份坏的不许拖垮一整批**。上游是另一条管线写进来的文件，
    ///    某一份写坏了只应该少一篇，不该让 app 一篇都没有。
    /// 2. **一份都没有就退回 `fallback`**，于是"目录还没建好"跟今天的
    ///    单份行为完全一样，不是一个空列表。
    /// 3. **按 id 排序**。目录枚举的顺序是文件系统说了算的，不排的话
    ///    每次启动「换一篇」的顺序都可能不同。
    ///
    /// 同 id 的两份只留先到的那一份：界面拿 id 当字典键，重复会让它炸。
    static func loadAll(inDirectory path: String, fallback fallbackPath: String? = nil) throws -> [Brief] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        let urls = names
            .filter { $0.hasSuffix(".json") }
            .map { URL(fileURLWithPath: path).appendingPathComponent($0) }
        let loaded = decodeSkippingBad(urls)
        if !loaded.isEmpty { return loaded }

        guard let fallbackPath else { throw LoadError.missing(path) }
        return [try load(at: fallbackPath)]
    }

    /// app 侧的那一版。读不到就退回单份 fixture，再读不到就是空数组——
    /// 没有稿不是崩，相机照常开，右下角那一格显示「交给我」。
    static func loadAllFromBundle() -> [Brief] {
        let loaded = decodeSkippingBad(demoURLsInBundle())
        if !loaded.isEmpty { return loaded }
        return (try? loadFromBundle()).map { [$0] } ?? []
    }

    /// Xcode 的同步文件夹默认把子目录里的资源**摊平**拷进 bundle 根，
    /// 只有标成 folder reference 时才保留 `demo-briefs/` 这一层。两种都认：
    /// 先问子目录，没有就扫根上的 json（解不成 Brief 的自然会被跳掉，
    /// 所以扫到无关的 json 也不会有事）。
    private static func demoURLsInBundle() -> [URL] {
        if let nested = Bundle.main.urls(forResourcesWithExtension: "json",
                                         subdirectory: demoDirectory),
           !nested.isEmpty {
            return nested
        }
        let flat = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return flat.filter { $0.lastPathComponent != "brief-fixture.json" }
    }

    private static func decodeSkippingBad(_ urls: [URL]) -> [Brief] {
        var byID: [String: Brief] = [:]
        for url in urls.sorted(by: { $0.path < $1.path }) {
            guard let data = try? Data(contentsOf: url),
                  let brief = try? JSONDecoder().decode(Brief.self, from: data)
            else { continue }
            if byID[brief.id] == nil { byID[brief.id] = brief }
        }
        return byID.values.sorted { $0.id < $1.id }
    }
}
