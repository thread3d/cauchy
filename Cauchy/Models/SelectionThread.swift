import Foundation

enum ThreadRole: String, Codable, Sendable {
    case user
    case assistant
}

/// The evidence boundary the answering model declares in its machine-readable
/// trailer. This is deliberately not called a confidence score: Cauchy can
/// prove which PDF pages were supplied, but it cannot prove that a generative
/// model's prose logically follows from them.
enum AnswerBasis: String, Codable, Equatable, Sendable {
    case pdf
    case mixed
    case insufficient
    case unverified

    var label: String {
        switch self {
        case .pdf: "Claims PDF basis"
        case .mixed: "Claims mixed basis"
        case .insufficient: "Not established"
        case .unverified: "Basis unverified"
        }
    }

    var systemImage: String {
        switch self {
        case .pdf: "doc.text.magnifyingglass"
        case .mixed: "books.vertical"
        case .insufficient: "questionmark.circle"
        case .unverified: "exclamationmark.triangle"
        }
    }
}

/// Inspectable provenance stored beside an assistant reply. `sourcePages` are
/// pages Cauchy actually supplied to the model (selection first, then retrieved
/// excerpts); they are evidence inputs, not an automatic entailment claim.
struct AnswerSourceAnchor: Codable, Equatable, Sendable {
    /// A location Cauchy resolved against the original PDF, not a model citation.
    var label: String
    var pageIndex: Int
    var region: NormalizedRect
    /// nil for locations saved before per-answer source IDs existed.
    var sourceID: String? = nil
}

enum AnswerCitationStatus: String, Codable, Equatable, Sendable {
    /// At least one cited ID resolves to a supplied PDF region and none are invalid.
    /// This checks the link, not the truth of the linked claim.
    case idsResolve
    case noResolvableCitation
    case invalidID
    case uncitedPassage

    var label: String {
        switch self {
        case .idsResolve: "Cited locations resolve"
        case .noResolvableCitation: "No resolvable citation"
        case .invalidID: "Unresolved citation ID"
        case .uncitedPassage: "Some answer text has no PDF link"
        }
    }
}

struct AnswerEvidence: Codable, Equatable, Sendable {
    var basis: AnswerBasis
    var sourcePages: [Int]
    var referencedStatementCount: Int
    var retrievedPassageCount: Int
    var providerID: String
    /// Requested model id when Cauchy controls it; nil for connector-managed
    /// defaults such as Ollama and Antigravity.
    var modelID: String?
    /// nil for replies saved before exact source locations were recorded.
    /// These locate supplied inputs; they do not certify the answer's claims.
    var sourceAnchors: [AnswerSourceAnchor]?
    /// nil for replies saved before source-ID validation was introduced.
    var citationStatus: AnswerCitationStatus?
    var citedSourceIDs: [String]?
    /// The model's raw declaration when Cauchy applies an additional link gate.
    var declaredBasis: AnswerBasis?

    init(
        basis: AnswerBasis,
        sourcePages: [Int],
        referencedStatementCount: Int,
        retrievedPassageCount: Int,
        providerID: String,
        modelID: String? = nil,
        sourceAnchors: [AnswerSourceAnchor]? = nil,
        citationStatus: AnswerCitationStatus? = nil,
        citedSourceIDs: [String]? = nil,
        declaredBasis: AnswerBasis? = nil
    ) {
        self.basis = basis
        self.sourcePages = sourcePages
        self.referencedStatementCount = referencedStatementCount
        self.retrievedPassageCount = retrievedPassageCount
        self.providerID = providerID
        self.modelID = modelID
        self.sourceAnchors = sourceAnchors
        self.citationStatus = citationStatus
        self.citedSourceIDs = citedSourceIDs
        self.declaredBasis = declaredBasis
    }

    var sourcePagesLabel: String {
        guard !sourcePages.isEmpty else { return "No PDF pages recorded" }
        let prefix = sourcePages.count == 1 ? "p." : "pp."
        return "\(prefix) \(sourcePages.map(String.init).joined(separator: ", "))"
    }

    var auditDescription: String {
        let declaration: String
        switch basis {
        case .pdf:
            declaration = "The model declared that its material claims use only the supplied PDF text."
        case .mixed:
            declaration = "The model declared that this answer also uses general knowledge or inference."
        case .insufficient:
            declaration = "The model declared that the supplied evidence is not enough to establish an answer."
        case .unverified:
            declaration = declaredBasis == .pdf
                ? "The model declared PDF-only, but Cauchy could not verify its source links."
                : "The answer did not provide a valid evidence-boundary declaration."
        }
        let located = sourceAnchors?.count ?? 0
        let citationNote: String
        switch citationStatus {
        case .idsResolve:
            citationNote = "The answer's cited source IDs resolve to supplied PDF locations."
        case .noResolvableCitation:
            citationNote = "The answer has no resolvable source ID."
        case .invalidID:
            citationNote = "The answer cited a source ID Cauchy could not resolve."
        case .uncitedPassage:
            citationNote = "A substantive part of the answer has no resolvable source ID."
        case nil:
            citationNote = "Source IDs were not audited for this saved answer."
        }
        return "\(declaration) Cauchy verified that it supplied \(sourcePagesLabel) and resolved \(located) original-PDF source locations. \(citationNote) These checks do not prove every claim."
    }
}

struct ThreadMessage: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var role: ThreadRole
    var content: String
    var createdAt: Date
    /// nil for user messages and replies saved before evidence-bound answers.
    var answerEvidence: AnswerEvidence?

    init(
        id: UUID = UUID(),
        role: ThreadRole,
        content: String,
        createdAt: Date = Date(),
        answerEvidence: AnswerEvidence? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.answerEvidence = answerEvidence
    }
}

struct SelectionThread: Equatable, Sendable {
    var anchorID: UUID
    var pageIndex: Int
    var selectedText: String
    var surroundingText: String
    var bounds: NormalizedRect?
    var lines: [HighlightLine]?
    var messages: [ThreadMessage]
    var isPersisted: Bool
    var streamingAssistantText: String?

    init(
        anchorID: UUID,
        pageIndex: Int,
        selectedText: String,
        surroundingText: String,
        bounds: NormalizedRect? = nil,
        lines: [HighlightLine]? = nil,
        messages: [ThreadMessage] = [],
        isPersisted: Bool = false,
        streamingAssistantText: String? = nil
    ) {
        self.anchorID = anchorID
        self.pageIndex = pageIndex
        self.selectedText = selectedText
        self.surroundingText = surroundingText
        self.bounds = bounds
        self.lines = lines
        self.messages = messages
        self.isPersisted = isPersisted
        self.streamingAssistantText = streamingAssistantText
    }

    var anchor: TextAnchor {
        TextAnchor(
            id: anchorID,
            pageIndex: pageIndex,
            bounds: bounds,
            selectedText: selectedText,
            surroundingText: surroundingText
        )
    }
}

struct TextSelectionContext: Sendable, Equatable {
    let pageIndex: Int
    let selectedText: String
    let surroundingText: String
    let fingerprint: String
    let bounds: NormalizedRect?
    let lines: [HighlightLine]?

    var anchor: TextAnchor {
        TextAnchor(
            pageIndex: pageIndex,
            bounds: bounds,
            selectedText: selectedText,
            surroundingText: surroundingText
        )
    }
}
