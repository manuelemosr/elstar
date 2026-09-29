import Foundation

/// Identifies one conversation for the harness. Hosts keep their own richer
/// key type and hand the harness the stable absolute form.
public nonisolated struct HarnessConversationKey: Hashable, Sendable {
    public var absoluteKey: String

    public init(absoluteKey: String) {
        self.absoluteKey = absoluteKey
    }

    /// The conversation component of the absolute key, used for receipt
    /// attribution.
    public var conversationID: String {
        absoluteKey.split(separator: "/", maxSplits: 1).last.map(String.init) ?? absoluteKey
    }
}

/// Presentation seam for one executor: tool-card deltas, action receipts, and
/// permission interactions. The host maps these into its own event stream and
/// UI; the harness owns no presentation of its own.
public nonisolated protocol HarnessToolEventSink: Sendable {
    func actionReceipt(_ key: HarnessConversationKey, _ receipt: AppleToolReceipt)
    func interactionRequested(_ key: HarnessConversationKey, _ interaction: PendingInteraction)
    func interactionResolved(_ key: HarnessConversationKey, requestID: String)
    func toolDelta(_ key: HarnessConversationKey, messageID: String, part: ToolActivity)
}

extension HarnessToolEventSink {
    /// The standard "Allow once / Deny" permission card for a device mutation.
    /// Native confirmations never offer a persistent grant.
    public func confirmationInteraction(id: String, request: AppleToolRequest?, detailOverride: String? = nil) -> PendingInteraction {
        PendingInteraction(
            requestID: id,
            kind: .permission,
            title: request?.confirmationTitle ?? "Allow this action?",
            prompt: detailOverride ?? request?.confirmationDetail,
            options: ["Allow once", "Deny"],
            allowsMultiple: false,
            allowsFreeText: false,
            questions: nil,
            allowsPersistentApproval: false
        )
    }
}

/// Tracks which conversation owns an in-flight confirmation, so a reopened
/// chat can discover pending answers.
public nonisolated protocol HarnessActiveOperationTracking: Sendable {
    func recordActiveKey(_ operationID: String, key: HarnessConversationKey)
    func clearActiveKey(_ operationID: String)
}

#if DEBUG
/// Development-only recording seam. Hosts opt in explicitly by installing a
/// recorder; the harness never records on its own.
public nonisolated protocol HarnessDiagnosticRecording: Sendable {
    func recordToolCall(turnID: String, callID: String, operation: String, structured: [String: String]?, conversationKey: String)
    func recordToolResult(turnID: String, callID: String, operation: String, status: String, summary: String, structured: [String: String]?, conversationKey: String)
    func recordConfirmationRequested(turnID: String, callID: String, operation: String, detail: String?, conversationKey: String)
    func recordConfirmationResolved(turnID: String, callID: String, allowed: Bool, conversationKey: String)
}
#endif

/// One rendered piece of an assistant message's tool work, reported live as a
/// stable event and persisted with the message.
public nonisolated struct ToolActivity: Equatable, Hashable, Sendable, Codable {
    public enum Status: Equatable, Sendable, Codable {
        case running
        case completed
        case failed
    }

    public var id: String
    public var name: String
    public var status: Status
    /// Short description of what the tool is doing, e.g. the file path.
    public var detail: String?
    /// Bounded excerpt of tool output; never the full transcript.
    public var outputExcerpt: String?
    public let startedAt: Date?
    /// Structured, persisted map payload for a places read. Additive and
    /// optional so old documents decode unchanged.
    public var mapPresentation: AppleMapPresentation?
    /// Structured, persisted WeatherKit attribution for a weather read. Additive and optional so old documents decode unchanged.
    public var weatherPresentation: AppleWeatherPresentation?

    public init(id: String, name: String, status: Status, detail: String? = nil, outputExcerpt: String? = nil, startedAt: Date? = nil, mapPresentation: AppleMapPresentation? = nil, weatherPresentation: AppleWeatherPresentation? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.detail = detail
        self.outputExcerpt = outputExcerpt
        self.startedAt = startedAt
        self.mapPresentation = mapPresentation
        self.weatherPresentation = weatherPresentation
    }

    /// Repository documents persist messages verbatim, so the persisted field
    /// names stay stable across versions; `status` defaulted to `completed`
    /// for records stored before it existed.
    enum CodingKeys: String, CodingKey {
        case id, name, status, detail
        case outputExcerpt = "output_excerpt"
        case startedAt = "started_at"
        case mapPresentation = "map_presentation"
        case weatherPresentation = "weather_presentation"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .completed
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        outputExcerpt = try container.decodeIfPresent(String.self, forKey: .outputExcerpt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        mapPresentation = try container.decodeIfPresent(AppleMapPresentation.self, forKey: .mapPresentation)
        weatherPresentation = try container.decodeIfPresent(AppleWeatherPresentation.self, forKey: .weatherPresentation)
    }
}

/// One question inside an agent question request. OpenCode (verified v1.18.31)
/// sends each request with an ordered list of questions; every question has
/// its own options, multiple-choice flag, and custom-answer permission
/// (`custom` defaults to true server-side).
public nonisolated struct PendingQuestion: Equatable, Hashable, Sendable, Codable {
    public var question: String
    public var header: String?
    public var options: [String]
    public var allowsMultiple: Bool
    public var allowsFreeText: Bool

    public init(
        question: String,
        header: String? = nil,
        options: [String] = [],
        allowsMultiple: Bool = false,
        allowsFreeText: Bool = false
    ) {
        self.question = question
        self.header = header
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.allowsFreeText = allowsFreeText
    }
}

/// An unresolved permission request or agent question, keyed by the server's
/// request ID so duplicate deliveries and stale answers stay distinguishable.
public nonisolated struct PendingInteraction: Equatable, Hashable, Sendable, Codable {
    public nonisolated enum Kind: Hashable, Sendable, Codable {
        /// Permission request: the agent asks to run a tool or touch a path.
        case permission
        /// Single-choice, multiple-choice, or free-text agent question.
        case question
        case unknown(kind: String)

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .permission: try container.encode("permission")
            case .question: try container.encode("question")
            case .unknown(let kind): try container.encode(kind)
            }
        }

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            switch value {
            case "permission": self = .permission
            case "question": self = .question
            default: self = .unknown(kind: value)
            }
        }
    }

    public nonisolated enum PermissionDecision: String, Sendable {
        case once
        case always
        case deny
    }

    public var requestID: String
    public var kind: Kind
    public var title: String?
    public var prompt: String?
    public var options: [String]
    public var allowsMultiple: Bool
    public var allowsFreeText: Bool
    /// Ordered questions for agent question requests. Nil on records stored
    /// before questions were modeled per-question; those render from the
    /// flattened legacy fields below.
    public var questions: [PendingQuestion]?
    /// Additive native flag. Server permissions default to `true` (an
    /// "Always" grant is offered); the built-in on-device backend sets this
    /// to `false` so the UI hides "Always" and persistent grants are refused.
    /// Optional so existing stored documents decode unchanged.
    public var allowsPersistentApproval: Bool? = nil

    public init(
        requestID: String,
        kind: Kind,
        title: String? = nil,
        prompt: String? = nil,
        options: [String] = [],
        allowsMultiple: Bool = false,
        allowsFreeText: Bool = false,
        questions: [PendingQuestion]? = nil,
        allowsPersistentApproval: Bool? = nil
    ) {
        self.requestID = requestID
        self.kind = kind
        self.title = title
        self.prompt = prompt
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.allowsFreeText = allowsFreeText
        self.questions = questions
        self.allowsPersistentApproval = allowsPersistentApproval
    }

    /// Whether a persistent ("Always") grant may be offered. Defaults to true
    /// so server cards keep their existing behavior for legacy records.
    public var permitsPersistentApproval: Bool { allowsPersistentApproval ?? true }

    /// The questions to render and answer. Legacy records without the
    /// per-question list fall back to one question built from the flattened
    /// fields, so stored documents keep working.
    public var effectiveQuestions: [PendingQuestion] {
        if let questions, !questions.isEmpty { return questions }
        guard kind == .question else { return [] }
        return [PendingQuestion(
            question: prompt ?? "",
            header: title,
            options: options,
            allowsMultiple: allowsMultiple,
            allowsFreeText: allowsFreeText
        )]
    }

    /// Stable persisted field names for repository documents.
    enum CodingKeys: String, CodingKey {
        case kind, title, prompt, options, questions
        case requestID = "request_id"
        case allowsMultiple = "allows_multiple"
        case allowsFreeText = "allows_free_text"
        case allowsPersistentApproval = "allows_persistent_approval"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        allowsMultiple = try container.decodeIfPresent(Bool.self, forKey: .allowsMultiple) ?? false
        allowsFreeText = try container.decodeIfPresent(Bool.self, forKey: .allowsFreeText) ?? false
        questions = try container.decodeIfPresent([PendingQuestion].self, forKey: .questions)
        allowsPersistentApproval = try container.decodeIfPresent(Bool.self, forKey: .allowsPersistentApproval)
    }
}
