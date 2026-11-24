import Foundation

public enum GitLabScope: String, CaseIterable, Sendable {
    case assigned = "assigned_to_me"
    case mine = "created_by_me"
    case all = "all"
}

public struct GitLabUser: Decodable, Equatable, Sendable {
    public let name: String
    public let username: String
    public init(name: String, username: String) { self.name = name; self.username = username }
}

public struct GitLabPipeline: Decodable, Equatable, Sendable {
    public let status: String
    public let webURL: String?

    /// `web_url` arrives as `webUrl` after snake-case conversion.
    enum CodingKeys: String, CodingKey {
        case status
        case webURL = "webUrl"
    }
}

public struct GitLabDiffRefs: Decodable, Equatable, Sendable {
    public let baseSHA: String
    public let headSHA: String
    public let startSHA: String

    public init(baseSHA: String, headSHA: String, startSHA: String) {
        self.baseSHA = baseSHA
        self.headSHA = headSHA
        self.startSHA = startSHA
    }

    enum CodingKeys: String, CodingKey {
        case baseSHA = "baseSha", headSHA = "headSha", startSHA = "startSha"
    }
}

public struct GitLabMR: Decodable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let iid: Int
    public let projectID: Int
    public let title: String
    public let sourceBranch: String
    public let targetBranch: String
    public let webURL: String
    /// "group/project!12", or "!12" when the server sent no references.
    public let reference: String
    public let author: GitLabUser
    public let draft: Bool
    public let userNotesCount: Int
    public let updatedAt: Date?
    public let description: String?
    public let headPipeline: GitLabPipeline?
    public let diffRefs: GitLabDiffRefs?

    enum CodingKeys: String, CodingKey {
        case id, iid, title, sourceBranch, targetBranch, author, draft, userNotesCount, updatedAt,
             description, headPipeline, diffRefs, references
        case projectID = "projectId"
        case webURL = "webUrl"
    }

    private struct References: Decodable { let full: String? }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        iid = try c.decode(Int.self, forKey: .iid)
        projectID = try c.decode(Int.self, forKey: .projectID)
        title = try c.decode(String.self, forKey: .title)
        sourceBranch = try c.decodeIfPresent(String.self, forKey: .sourceBranch) ?? ""
        targetBranch = try c.decodeIfPresent(String.self, forKey: .targetBranch) ?? ""
        webURL = try c.decodeIfPresent(String.self, forKey: .webURL) ?? ""
        reference = (try? c.decodeIfPresent(References.self, forKey: .references))?.full ?? "!\(iid)"
        author = try c.decodeIfPresent(GitLabUser.self, forKey: .author) ?? GitLabUser(name: "", username: "")
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        userNotesCount = try c.decodeIfPresent(Int.self, forKey: .userNotesCount) ?? 0
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        headPipeline = try? c.decodeIfPresent(GitLabPipeline.self, forKey: .headPipeline)
        diffRefs = try? c.decodeIfPresent(GitLabDiffRefs.self, forKey: .diffRefs)
    }
}

public struct GitLabDiffEntry: Decodable, Equatable, Sendable {
    public let oldPath: String
    public let newPath: String
    public let diff: String
    public let newFile: Bool
    public let renamedFile: Bool
    public let deletedFile: Bool
    public let generatedFile: Bool?

    public init(oldPath: String, newPath: String, diff: String, newFile: Bool, renamedFile: Bool,
                deletedFile: Bool, generatedFile: Bool?) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.diff = diff
        self.newFile = newFile
        self.renamedFile = renamedFile
        self.deletedFile = deletedFile
        self.generatedFile = generatedFile
    }
}

public struct GitLabPosition: Decodable, Equatable, Sendable {
    public let newPath: String?
    public let oldPath: String?
    public let newLine: Int?
    public let oldLine: Int?

    public init(newPath: String?, oldPath: String?, newLine: Int?, oldLine: Int?) {
        self.newPath = newPath
        self.oldPath = oldPath
        self.newLine = newLine
        self.oldLine = oldLine
    }
}

public struct GitLabNote: Decodable, Equatable, Sendable, Identifiable {
    public let id: Int
    public let body: String
    public let author: GitLabUser
    public let system: Bool
    public let position: GitLabPosition?
    public let createdAt: Date?

    public init(id: Int, body: String, author: GitLabUser, system: Bool, position: GitLabPosition?, createdAt: Date?) {
        self.id = id
        self.body = body
        self.author = author
        self.system = system
        self.position = position
        self.createdAt = createdAt
    }
}

public struct GitLabDiscussion: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let notes: [GitLabNote]

    public init(id: String, notes: [GitLabNote]) {
        self.id = id
        self.notes = notes
    }
}

public enum GitLabJSON {
    /// snake_case keys; ISO 8601 dates with or without fractional seconds.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { d in
            let text = try d.singleValueContainer().decode(String.self)
            guard let date = parseEventTimestamp(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad date \(text)"))
            }
            return date
        }
        return decoder
    }
}
