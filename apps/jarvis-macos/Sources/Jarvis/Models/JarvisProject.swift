import Foundation

struct JarvisProject: Codable, Identifiable, Hashable {
    enum SourceType: String, Codable {
        case folder
        case document
    }

    let id: String
    var name: String
    var rootPath: String
    var order: Int
    var sourceType: SourceType = .folder
    var createdAt: Date = .now
    var updatedAt: Date = .now

    var isFolder: Bool { sourceType == .folder }

    init(
        id: String,
        name: String,
        rootPath: String,
        order: Int,
        sourceType: SourceType = .folder,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.order = order
        self.sourceType = sourceType
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Custom decode so the `[JarvisProject]` blob already persisted in
    /// UserDefaults (from before `createdAt`/`updatedAt` existed) keeps
    /// decoding instead of losing the user's project list -- missing dates
    /// default to now rather than failing the whole array.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        rootPath = try container.decode(String.self, forKey: .rootPath)
        order = try container.decode(Int.self, forKey: .order)
        sourceType = try container.decodeIfPresent(SourceType.self, forKey: .sourceType) ?? .folder
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }

    static let initialProjects = [
        JarvisProject(
            id: "limule",
            name: "Limule",
            rootPath: "/Users/davyokemba/Documents/limule",
            order: 0,
            sourceType: .folder
        ),
        JarvisProject(
            id: "zola",
            name: "ZOLA",
            rootPath: "/Users/davyokemba/Documents/ZOLA",
            order: 1,
            sourceType: .folder
        ),
        JarvisProject(
            id: "kompta",
            name: "KOMPTA",
            rootPath: "/Users/davyokemba/Documents/KOMPTA",
            order: 2,
            sourceType: .folder
        )
    ]
}

struct GitSnapshot: Equatable {
    var branch: String
    var lastCommitSubject: String
    var lastCommitDate: Date?
    var changedFileCount: Int
    var changedFiles: [String]
    var isRepository: Bool
    var activityHistory: [ProjectActivityPoint]
    var inspectedAt: Date

    static func unavailable(at date: Date = .now) -> GitSnapshot {
        GitSnapshot(
            branch: "Unavailable",
            lastCommitSubject: "Git information is not available.",
            lastCommitDate: nil,
            changedFileCount: 0,
            changedFiles: [],
            isRepository: false,
            activityHistory: [],
            inspectedAt: date
        )
    }
}

struct ProjectActivityPoint: Identifiable, Equatable {
    let date: Date
    let commitCount: Int

    var id: Date { date }
}

enum BuildTool: String, Codable {
    case xcodebuild
    case swiftPackage
    case npm
    case yarn
    case pnpm
    case cargo
    case make

    var label: String {
        switch self {
        case .xcodebuild: return "xcodebuild"
        case .swiftPackage: return "swift build"
        case .npm: return "npm run build"
        case .yarn: return "yarn build"
        case .pnpm: return "pnpm build"
        case .cargo: return "cargo build"
        case .make: return "make"
        }
    }
}

struct BuildSnapshot: Equatable {
    enum State: Equatable {
        case unknown
        case notDetected
        case running
        case success
        case failed(detail: String)
    }

    var tool: BuildTool?
    var state: State
    var checkedAt: Date?

    static let unknown = BuildSnapshot(tool: nil, state: .unknown, checkedAt: nil)
}
