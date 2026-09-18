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
}
