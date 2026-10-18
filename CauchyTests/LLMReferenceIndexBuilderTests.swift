import AppKit
import PDFKit
import XCTest
@testable import Cauchy

final class LLMReferenceIndexResponseParserTests: XCTestCase {
    func testParsesCleanJSON() throws {
        let raw = """
        {
          "references": [
            {
              "kind": "equation",
              "number": "1.4",
              "formatted_body": "$$x + y = z$$"
            }
          ]
        }
        """

        let parsed = try LLMReferenceIndexResponseParser.parse(raw)

        XCTAssertEqual(parsed.references.count, 1)
        XCTAssertEqual(parsed.references[0].kind, "equation")
        XCTAssertEqual(parsed.references[0].number, "1.4")
        XCTAssertEqual(parsed.references[0].formattedBody, "$$x + y = z$$")
    }

    func testParsesJSONWrappedInMarkdown() throws {
        let raw = """
        Here is the result:
        ```json
        {
          "references": [
            {
              "kind": "theorem",
              "number": "2.1",
              "formatted_body": "Every bounded sequence has a convergent subsequence."
            }
          ]
        }
        ```
        """

        let parsed = try LLMReferenceIndexResponseParser.parse(raw)

        XCTAssertEqual(parsed.references.count, 1)
        XCTAssertEqual(parsed.references[0].kind, "theorem")
        XCTAssertEqual(parsed.references[0].number, "2.1")
    }

    func testRejectsInvalidJSON() {
        XCTAssertThrowsError(try LLMReferenceIndexResponseParser.parse("not json at all"))
    }

    func testParsesCorrectedObjectAfterInvalidObject() throws {
        let raw = """
        {"references": [invalid]}
        Corrected:
        {"references": [{"kind":"lemma","number":"4.2","formatted_body":"A result with {braces}."}]}
        """

        let parsed = try LLMReferenceIndexResponseParser.parse(raw)

        XCTAssertEqual(parsed.references.count, 1)
        XCTAssertEqual(parsed.references[0].number, "4.2")
        XCTAssertEqual(parsed.references[0].formattedBody, "A result with {braces}.")
    }
}

final class ReferenceIndexCacheStoreTests: XCTestCase {
    func testFingerprintIsStableForSameContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("sample.pdf")
        try Data("same-content".utf8).write(to: url)

        let first = try ReferenceIndexCacheStore.fingerprint(for: url)
        let second = try ReferenceIndexCacheStore.fingerprint(for: url)

        XCTAssertEqual(first, second)
        // A bare SHA-256 of the file's bytes. The schema version used to be
        // glued on the end; it lives in the cache file itself now, so the
        // fingerprint stays a pure content hash.
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy(\.isHexDigit))
    }

    func testFingerprintChangesWhenContentChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("sample.pdf")
        try Data("version-a".utf8).write(to: url)
        let first = try ReferenceIndexCacheStore.fingerprint(for: url)

        try Data("version-b".utf8).write(to: url)
        let second = try ReferenceIndexCacheStore.fingerprint(for: url)

        XCTAssertNotEqual(first, second)
    }

    func testRoundTripPersistedIndex() throws {
        let fingerprint = "abc123-v\(PersistedReferenceIndex.schemaVersion)"
        let entries: [ReferenceKey: IndexedReference] = [
            ReferenceKey(kind: .equation, number: "1.2"): IndexedReference(
                reference: DetectedReference(kind: .equation, number: "1.2"),
                formattedBody: "$$x + y = z$$",
                pageIndex: 4,
                evidence: ReferenceEvidence(
                    status: .supported,
                    sourceExcerpt: "x + y = z (1.2)",
                    matchedText: "(1.2)",
                    occurrenceCount: 1,
                    startOffset: 10,
                    endOffset: 25
                )
            )
        ]
        let persisted = PersistedReferenceIndex(
            documentFingerprint: fingerprint,
            builtAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: entries,
            builtWith: "on-device",
            failedPageIndices: []
        )

        try ReferenceIndexCacheStore.save(persisted)
        let loaded = try ReferenceIndexCacheStore.load(fingerprint: fingerprint)
        defer { try? FileManager.default.removeItem(at: ReferenceIndexCacheStore.cacheFileURL(for: fingerprint)) }

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.documentFingerprint, fingerprint)
        XCTAssertEqual(loaded?.entries.count, 1)
        XCTAssertEqual(loaded?.entries.first?.formattedBody, "$$x + y = z$$")
        XCTAssertEqual(loaded?.entries.first?.evidence?.sourceExcerpt, "x + y = z (1.2)")
    }

    func testRoundTripPreservesOCRCandidateEvidenceAndRegion() throws {
        let fingerprint = "ocr-candidate-\(UUID().uuidString)"
        let region = NormalizedRect(x: 0.67, y: 0.41, width: 0.24, height: 0.04)
        let candidate = OCRReferenceCandidate(
            kind: ReferenceKind.theorem.rawValue,
            number: "2.3",
            rawLine: "Theorem 2.3. OCR source",
            normalizedLine: "Theorem 2.3. OCR source",
            confidence: 0.92,
            region: region
        )
        let indexed = try XCTUnwrap(candidate.indexedReference(pageIndex: 7))
        let persisted = PersistedReferenceIndex(
            documentFingerprint: fingerprint,
            builtAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [indexed.reference.key: indexed],
            builtWith: "Vision OCR candidates",
            failedPageIndices: []
        )

        try ReferenceIndexCacheStore.save(persisted)
        defer { try? FileManager.default.removeItem(at: ReferenceIndexCacheStore.cacheFileURL(for: fingerprint)) }
        let loaded = try XCTUnwrap(ReferenceIndexCacheStore.load(fingerprint: fingerprint))
        let entry = try XCTUnwrap(loaded.entries.first)

        XCTAssertEqual(entry.contentOrigin, .ocrCandidate)
        XCTAssertEqual(entry.evidence?.effectiveSource, .visionOCR)
        XCTAssertEqual(entry.evidence?.matchedRegion, region)
        XCTAssertEqual(loaded.asSnapshot(pageCount: 8).entries[indexed.reference.key]?.groundingBody, "")
    }

    func testSnapshotLoadsEntries() {
        let entries: [ReferenceKey: IndexedReference] = [
            ReferenceKey(kind: .theorem, number: "3.1"): IndexedReference(
                reference: DetectedReference(kind: .theorem, number: "3.1"),
                formattedBody: "A theorem statement.",
                pageIndex: 2
            )
        ]

        let persisted = PersistedReferenceIndex(
            documentFingerprint: "fp",
            builtAt: Date(),
            entries: entries,
            builtWith: "on-device",
            failedPageIndices: []
        )
        let snapshot = persisted.asSnapshot(pageCount: 10)
        let entry = snapshot.entries[ReferenceKey(kind: .theorem, number: "3.1")]

        XCTAssertEqual(entry?.formattedBody, "A theorem statement.")
        XCTAssertEqual(entry?.pageIndex, 2)
        XCTAssertEqual(snapshot.pageCount, 10)
    }
}

final class LLMReferenceIndexSupportTests: XCTestCase {
    func testImageOnlyDocumentErrorExplainsIndexingBoundary() {
        XCTAssertTrue(
            ReferenceIndexBuildError.noExtractableText.localizedDescription.contains("local OCR")
        )
    }

    /// A tripwire, not a fact worth asserting on its own: bumping the schema
    /// invalidates every cache on disk, so each quality-driven rebuild must be
    /// a deliberate edit here too.
    func testSchemaVersionMatchesCurrentIndexQualityContract() {
        XCTAssertEqual(PersistedReferenceIndex.schemaVersion, 11)
    }

    func testShouldUseVisionWhenCloudAndImagePresent() {
        XCTAssertTrue(
            LLMReferenceIndexSupport.shouldUseVision(cloudVisionAvailable: true, pageImagePNG: Data([0x89]))
        )
        XCTAssertFalse(
            LLMReferenceIndexSupport.shouldUseVision(cloudVisionAvailable: false, pageImagePNG: Data([0x89]))
        )
        XCTAssertFalse(
            LLMReferenceIndexSupport.shouldUseVision(cloudVisionAvailable: true, pageImagePNG: nil)
        )
    }

    func testOCRFallbackTreatsPageNumberOnlyTextLayerAsImageOnly() {
        XCTAssertTrue(LLMReferenceIndexSupport.shouldUseOCRFallback(sourceText: "12"))
        XCTAssertTrue(LLMReferenceIndexSupport.shouldUseOCRFallback(sourceText: "Scanned by Library · 12"))
    }

    func testOCRFallbackDoesNotOverrideShortGroundedDeclaration() {
        XCTAssertFalse(LLMReferenceIndexSupport.shouldUseOCRFallback(
            sourceText: "Theorem 1.1. A short exact statement."
        ))
    }

    func testOCRFallbackDoesNotRunOnSubstantiveSearchableText() {
        let prose = String(repeating: "This is searchable technical prose. ", count: 4)
        XCTAssertFalse(LLMReferenceIndexSupport.shouldUseOCRFallback(sourceText: prose))
    }

    func testOnDeviceIndexingUsesOneModelCallAtATime() {
        XCTAssertEqual(LLMReferenceIndexBuilder.maxConcurrentPagesOnDevice, 1)
    }

    func testPreprocessPageTextConvertsUnicodeMath() {
        let raw = "Let f be continuous and x ≤ y."
        let processed = LLMReferenceIndexSupport.preprocessPageText(raw)
        XCTAssertTrue(processed.contains("$"))
        XCTAssertTrue(processed.contains("\\leq"))
    }

    func testPreprocessPageTextReturnsEmptyForBlankInput() {
        XCTAssertEqual(LLMReferenceIndexSupport.preprocessPageText("   "), "")
    }

    func testTableOfContentsDetectionSeparatesSectionListingsFromStatements() {
        let contents = """
        CONTENTS
        6.1 Interiors and closures 39
        6.2 Limit points 40
        7.1 Basic definitions 43
        7.2 Complete metric spaces 44
        8.1 Connectedness 49
        """

        XCTAssertTrue(LLMReferenceIndexSupport.isLikelyTableOfContents(contents))
        XCTAssertFalse(
            LLMReferenceIndexSupport.isLikelyTableOfContents(
                "Definition 3.1.1 (Limit). A sequence converges when..."
            )
        )
    }

    func testFinalizeReferenceBodyAcceptsValidLaTeX() {
        let body = "We have $$x + y = z$$"
        XCTAssertEqual(
            LLMReferenceIndexSupport.finalizeReferenceBody(normalized: body, repaired: nil),
            body
        )
    }

    func testFinalizeReferenceBodyUsesRepairedOutputWhenInitialInvalid() {
        let invalid = "Broken $$\\notacommand{x$$"
        let repaired = "$$x + y = z$$"
        XCTAssertEqual(
            LLMReferenceIndexSupport.finalizeReferenceBody(normalized: invalid, repaired: repaired),
            "$$x + y = z$$"
        )
    }

    func testFinalizeReferenceBodySkipsWhenStillInvalidAfterRepair() {
        let invalid = "Broken $$\\notacommand{x$$"
        XCTAssertNil(
            LLMReferenceIndexSupport.finalizeReferenceBody(normalized: invalid, repaired: invalid)
        )
    }

    func testMergeKeepsOriginalStatementOverLongerLaterDiscussion() {
        var results: [ReferenceKey: IndexedReference] = [:]
        let key = ReferenceKey(kind: .theorem, number: "3.1")

        LLMReferenceIndexSupport.merge(
            IndexedReference(
                reference: DetectedReference(kind: .theorem, number: "3.1"),
                formattedBody: "Short.",
                pageIndex: 0
            ),
            into: &results
        )
        LLMReferenceIndexSupport.merge(
            IndexedReference(
                reference: DetectedReference(kind: .theorem, number: "3.1"),
                formattedBody: "A much longer theorem statement.",
                pageIndex: 2
            ),
            into: &results
        )

        XCTAssertEqual(results[key]?.formattedBody, "Short.")
        XCTAssertEqual(results[key]?.pageIndex, 0)
    }

    func testLongPageChunkingPreservesBeginningMiddleAndEnd() {
        let text = "BEGIN " + String(repeating: "a", count: 5_000)
            + "\n\nMIDDLE\n\n" + String(repeating: "b", count: 5_000) + " END"

        let chunks = ReferenceIndexPromptBuilder.pageTextChunks(text, maxCharacters: 2_000, overlapCharacters: 200)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 2_000 })
        XCTAssertTrue(chunks.contains { $0.contains("BEGIN") })
        XCTAssertTrue(chunks.contains { $0.contains("MIDDLE") })
        XCTAssertTrue(chunks.contains { $0.contains("END") })
    }

    func testGroundingRequiresMatchingKindAndNumber() {
        let page = "Definition 3.2 (Compactness). A space is compact when... Equation (4.1) follows."

        XCTAssertTrue(LLMReferenceIndexSupport.isGrounded(kind: .definition, number: "3.2", in: page))
        XCTAssertTrue(LLMReferenceIndexSupport.isGrounded(kind: .equation, number: "4.1", in: page))
        XCTAssertFalse(LLMReferenceIndexSupport.isGrounded(kind: .theorem, number: "3.2", in: page))
        XCTAssertFalse(LLMReferenceIndexSupport.isGrounded(kind: .definition, number: "9.9", in: page))
    }

    func testGroundedNameDropsInventedTitle() {
        let page = "Definition 3.2 (Compactness). A space is compact when..."

        XCTAssertEqual(LLMReferenceIndexSupport.groundedName("compactness", in: page), "compactness")
        XCTAssertNil(LLMReferenceIndexSupport.groundedName("Completeness", in: page))
    }

    func testEvidenceRetainsVerbatimSourceAndOffsets() {
        let page = "Introduction\n\nDefinition 3.2 (Compactness). A space is compact when every open cover has a finite subcover.\n\nProof."
        let reference = DetectedReference(kind: .definition, number: "3.2")

        let evidence = LLMReferenceIndexSupport.evidence(for: reference, in: page)

        XCTAssertEqual(evidence?.status, .supported)
        XCTAssertEqual(evidence?.matchedText, "Definition 3.2")
        XCTAssertEqual(evidence?.occurrenceCount, 1)
        XCTAssertTrue(evidence?.sourceExcerpt.contains("every open cover") == true)
        if let evidence {
            let start = String.Index(utf16Offset: evidence.startOffset, in: page)
            let end = String.Index(utf16Offset: evidence.endOffset, in: page)
            XCTAssertEqual(String(page[start..<end]), evidence.sourceExcerpt)
        }
    }

    func testEvidenceMarksRepeatedReferenceAsUncertainAndPrefersDeclaration() {
        let page = "By Theorem 2.1 we get the result.\n\nTheorem 2.1. Every bounded sequence has a convergent subsequence."
        let reference = DetectedReference(kind: .theorem, number: "2.1")

        let evidence = LLMReferenceIndexSupport.evidence(for: reference, in: page)

        XCTAssertEqual(evidence?.status, .uncertain)
        XCTAssertEqual(evidence?.occurrenceCount, 2)
        XCTAssertTrue(evidence?.sourceExcerpt.contains("Every bounded sequence") == true)
        let declaration = page.range(of: "Theorem 2.1", options: .backwards)!
        XCTAssertEqual(evidence?.matchStartOffset, declaration.lowerBound.utf16Offset(in: page))
        XCTAssertEqual(evidence?.matchEndOffset, declaration.upperBound.utf16Offset(in: page))
    }

    func testPageRegionContextStaysWithinPage() {
        let nearTop = NormalizedRect(x: 0.2, y: 0.96, width: 0.1, height: 0.02)
        let context = ReferenceEvidenceRegionResolver.contextRegion(for: nearTop)

        XCTAssertEqual(context.x, 0)
        XCTAssertEqual(context.width, 1)
        XCTAssertGreaterThanOrEqual(context.y, 0)
        XCTAssertLessThanOrEqual(context.y + context.height, 1)
        XCTAssertTrue(context.y <= nearTop.y && context.y + context.height >= nearTop.y + nearTop.height)
    }

    func testEvidenceRejectsUnsupportedModelReference() {
        XCTAssertNil(
            LLMReferenceIndexSupport.evidence(
                for: DetectedReference(kind: .lemma, number: "9.9"),
                in: "Theorem 1.1. A real statement."
            )
        )
    }

    func testIncompleteEquationTranscriptionFallsBackToSource() {
        XCTAssertNil(
            LLMReferenceIndexSupport.finalizeReferenceBody(
                normalized: "|x| ≤ r ⇒ |ψ(x)| ≤ 2|x| ≤",
                repaired: nil
            )
        )
        XCTAssertEqual(
            LLMReferenceIndexSupport.finalizeReferenceBody(
                normalized: "|x| ≤ r ⇒ |ψ(x)| ≤ r/2.",
                repaired: nil
            ),
            "|x| ≤ r ⇒ |ψ(x)| ≤ r/2."
        )
    }

    func testEvidenceCoversHardWrappedStatementBeforeNextDeclaration() {
        let page = "Example 1.4.1. Let f be continuous.\nIts derivative exists on the interior.\nThe boundary is excluded.\nExample 1.4.2. A different example follows."
        let evidence = LLMReferenceIndexSupport.evidence(
            for: DetectedReference(kind: .example, number: "1.4.1"),
            in: page
        )

        XCTAssertTrue(evidence?.sourceExcerpt.contains("The boundary is excluded") == true)
        XCTAssertFalse(evidence?.sourceExcerpt.contains("A different example") == true)
    }

    func testSourceFallbackStopsAtNextNumberedSection() {
        let page = "Example 1.4.2. A statement with an answer.\nThe last line of the example.\n1.5. Continuity and the chain rule\nUnrelated section prose."
        let match = LLMReferenceIndexSupport.declarationMatches(in: page).first!

        let body = LLMReferenceIndexSupport.fallbackBody(for: match, in: page)
        let evidence = LLMReferenceIndexSupport.evidence(for: match.reference, in: page)

        XCTAssertTrue(body?.contains("The last line") == true)
        XCTAssertFalse(body?.contains("Continuity and the chain rule") == true)
        XCTAssertFalse(evidence?.sourceExcerpt.contains("Unrelated section prose") == true)
    }

    func testDeclarationGuardSeparatesHeadingsFromCitations() {
        let page = "By Theorem 1.1 we know this.\n\nTheorem 2.1. Every bounded sequence has a convergent subsequence."
        let declarations = LLMReferenceIndexSupport.declarationMatches(in: page).map(\.reference)

        XCTAssertFalse(declarations.contains(DetectedReference(kind: .theorem, number: "1.1")))
        XCTAssertTrue(declarations.contains(DetectedReference(kind: .theorem, number: "2.1")))
    }

    func testFigureCaptionIsSourceOnlyAndPanelCitationsAreNotDeclarations() {
        let page = """
        Figure 3a shows an earlier result.
        Fig. 3 | Scaling learned interatomic potentials. a, Classification error.
        We compare this with Fig. 3d and Figure 3.
        """
        let figure = DetectedReference(kind: .figure, number: "3")
        let declarations = LLMReferenceIndexSupport.declarationMatches(in: page)
        XCTAssertEqual(declarations.filter { $0.reference == figure }.count, 1)

        let entries = LLMReferenceIndexSupport.sourceDeclarationFallbacks(
            sourceText: page, pageIndex: 4
        )
        let indexed = entries[figure.key]
        XCTAssertEqual(indexed?.formattedBody, "Scaling learned interatomic potentials")
        XCTAssertEqual(indexed?.contentOrigin, .sourceFallback)
        XCTAssertEqual(indexed?.evidence?.sourceExcerpt,
                       "Fig. 3 | Scaling learned interatomic potentials. a, Classification error.")
        XCTAssertEqual(indexed?.evidence?.matchedText, "Fig. 3")
        XCTAssertEqual(indexed?.evidence?.status, .supported)
        XCTAssertEqual(indexed?.evidence?.occurrenceCount, 4)
    }

    func testFigureCaptionTitleContinuesOnlyThroughLowercaseWrappedLine() {
        let page = """
        Figure 2.5: A contour inside a horseshoe domain can be contracted to a
        point along the dotted lines.
        Example 2.4.5. An annulus is not simply connected.
        """
        let figure = DetectedReference(kind: .figure, number: "2.5")
        let entry = LLMReferenceIndexSupport.sourceDeclarationFallbacks(
            sourceText: page, pageIndex: 54
        )[figure.key]

        XCTAssertEqual(entry?.formattedBody,
                       "A contour inside a horseshoe domain can be contracted to a point along the dotted lines")
        XCTAssertEqual(entry?.evidence?.sourceExcerpt,
                       "Figure 2.5: A contour inside a horseshoe domain can be contracted to a\npoint along the dotted lines.")
        XCTAssertFalse(entry?.evidence?.sourceExcerpt.contains("Example") == true)
    }

    func testAppendixDeclarationRetainedButCitationExcluded() {
        let page = "By Theorem A.0.1, the extension exists.\n\nRemark A.0.5. The two forms are independent."
        let declarations = LLMReferenceIndexSupport.declarationMatches(in: page).map(\.reference)

        XCTAssertFalse(declarations.contains(DetectedReference(kind: .theorem, number: "A.0.1")))
        XCTAssertTrue(declarations.contains(DetectedReference(kind: .remark, number: "A.0.5")))
    }

    func testDeclarationGuardAcceptsEquationNumberOnOwnLine() {
        let page = """
        We minimize the joint loss
        L = λE ∑ LHuber(δE, Ê, E) + λF ∑ LHuber(δF, −∂Ê/∂r, F)
        (1)
        where the two terms measure energy and force error.
        """

        let declarations = LLMReferenceIndexSupport.declarationMatches(in: page).map(\.reference)

        XCTAssertTrue(declarations.contains(DetectedReference(kind: .equation, number: "1")))
    }

    func testDeclarationGuardAcceptsEquationLabelAtBeginningOfLine() {
        let page = """
        By the mean value theorem we have
        (1.10) |x| ≤ r ⇒ |ψ(x)| ≤ r/2.
        Then by (1.10) the map has a fixed point.
        """

        let declarations = LLMReferenceIndexSupport.declarationMatches(in: page).map(\.reference)

        XCTAssertEqual(
            declarations.filter { $0 == DetectedReference(kind: .equation, number: "1.10") }.count,
            1
        )
    }

    func testPageGeometryAcceptsRightMarginEquationDespiteTextOrder() {
        let page = """
        A long displayed conditional-probability identity satisfies A = B = C = D = E = F. (5.1)
        To be precise, (5.1) assumes positive probability.
        Lemma 1.2. Let f : R→R be a solution of the IVP (1.1)
        with x = y on the following line.
        Theorem 6.13. Detailed balance holds iff
        (6.8)
        π_i p_ij = π_j p_ji.
        The relations (6.8) are known as detailed balance.
        """
        let nsPage = page as NSString
        let positions = [
            nsPage.range(of: "(5.1)").location: 0.788,
            nsPage.range(of: "(1.1)").location: 0.816,
            nsPage.range(of: "(6.8)").location: 0.788,
        ]

        let declarations = LLMReferenceIndexSupport.declarationMatches(
            in: page, equationLabelX: positions
        ).map(\.reference)

        XCTAssertEqual(declarations.filter { $0 == DetectedReference(kind: .equation, number: "5.1") }.count, 1)
        XCTAssertEqual(declarations.filter { $0 == DetectedReference(kind: .equation, number: "6.8") }.count, 1)
        XCTAssertFalse(declarations.contains(DetectedReference(kind: .equation, number: "1.1")))
    }

    func testPageGeometryRejectsEnumeratedProofStepsButKeepsLeftEquationLabel() {
        let page = """
        Proof.
        (1) f ∈ W ⇒ f = 0
        (2) f ∈ U ⇒ f = 0
        (3) f ∈ V ⇒ f = 0
        (1.10) |x| ≤ r ⇒ |ψ(x)| ≤ r/2.
        """
        let nsPage = page as NSString
        let positions = [
            nsPage.range(of: "(1)").location: 0.315,
            nsPage.range(of: "(2)").location: 0.269,
            nsPage.range(of: "(3)").location: 0.275,
            nsPage.range(of: "(1.10)").location: 0.118,
        ]
        let declarations = LLMReferenceIndexSupport.declarationMatches(
            in: page, equationLabelX: positions
        ).map(\.reference)

        for step in ["1", "2", "3"] {
            XCTAssertFalse(declarations.contains(DetectedReference(kind: .equation, number: step)))
        }
        XCTAssertTrue(declarations.contains(DetectedReference(kind: .equation, number: "1.10")))
    }

    func testTheoremEvidenceKeepsEquationWithinItsStatement() {
        let page = """
        Theorem 6.13. Detailed balance holds iff
        (6.8)
        π_i p_ij = π_j p_ji.
        Theorem 6.14. Another result.
        """
        let evidence = LLMReferenceIndexSupport.evidence(
            for: DetectedReference(kind: .theorem, number: "6.13"), in: page
        )

        XCTAssertTrue(evidence?.sourceExcerpt.contains("(6.8)") == true)
        XCTAssertTrue(evidence?.sourceExcerpt.contains("π_i p_ij = π_j p_ji") == true)
        XCTAssertFalse(evidence?.sourceExcerpt.contains("Theorem 6.14") == true)
    }

    func testStandaloneEquationLabelKeepsPrecedingFormulaWhenPageEnds() {
        let page = """
        Proof. The estimate follows by integration.
        |f(t,y(t))| ds ≤ M|x−a|
        < M h ≤ k
        (1.17)
        15
        """
        let evidence = LLMReferenceIndexSupport.evidence(
            for: DetectedReference(kind: .equation, number: "1.17"),
            in: page
        )

        XCTAssertNotNil(evidence)
        XCTAssertTrue(evidence?.sourceExcerpt.contains("M h ≤ k") == true)
        XCTAssertTrue(evidence?.sourceExcerpt.contains("(1.17)") == true)
    }

    func testDeclarationGuardRejectsCitationYearsAndEquationCitations() {
        let page = """
        The method was introduced by Smith (2019) and refined later.
        See equation (3) for the corresponding objective.
        If z₀ = γ₁(0) = γ₂(0) then the two paths share a point.
        """

        XCTAssertTrue(LLMReferenceIndexSupport.declarationMatches(in: page).isEmpty)
    }

    func testDeclarationGuardRejectsEquationCitationAtEndOfLemmaLine() {
        let page = """
        Lemma 1.2. Let f : R → R be so that P(i) holds and let y(x) be any solution of the IVP (1.1)
        which is defined on an interval. Then |y(x)−b| ≤ k.
        """

        let declarations = LLMReferenceIndexSupport.declarationMatches(in: page).map(\.reference)

        XCTAssertTrue(declarations.contains(DetectedReference(kind: .lemma, number: "1.2")))
        XCTAssertFalse(declarations.contains(DetectedReference(kind: .equation, number: "1.1")))
    }

    func testNamedFallbackRetainsVerbatimStatementWhenModelMissesIt() {
        let page = "Example 2.3.8 (Hamming distance). Let X = {0, 1}ⁿ. Define d(x, y) to be the number of differing coordinates.\n\nRemark. More follows."
        var results: [ReferenceKey: IndexedReference] = [:]

        LLMReferenceIndexSupport.addNamedDeclarationFallbacks(
            sourceText: page,
            pageIndex: 4,
            to: &results
        )

        let entry = results[ReferenceKey(kind: .example, number: "2.3.8")]
        XCTAssertNotNil(entry)
        XCTAssertTrue(entry?.formattedBody.contains("Hamming distance") == true)
        XCTAssertTrue(entry?.formattedBody.contains("differing coordinates") == true)
        XCTAssertEqual(entry?.evidence?.sourceExcerpt, page)
    }

    func testEquationFallbackRetainsSourceEvidenceWhenModelMissesIt() {
        let page = """
        We minimize the joint loss
        L = λE ∑ LHuber(δE, Ê, E) + λF ∑ LHuber(δF, −∂Ê/∂r, F)
        (1)
        where the two terms measure energy and force error.
        """
        var results: [ReferenceKey: IndexedReference] = [:]

        LLMReferenceIndexSupport.addEquationDeclarationFallbacks(
            sourceText: page,
            pageIndex: 9,
            to: &results
        )

        let entry = results[ReferenceKey(kind: .equation, number: "1")]
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.contentOrigin, .sourceFallback)
        XCTAssertTrue(entry?.formattedBody.contains("joint loss") == true)
        XCTAssertEqual(entry?.evidence?.sourceExcerpt, page)
    }

    func testDeclarationContextCentresEquationAndDropsDistantCitations() {
        let leading = String(repeating: "background prose ", count: 240)
        let trailing = String(repeating: " bibliography (2019)", count: 240)
        let page = leading + "\nL = λE ∑ loss + λF ∑ force\n(1)\nwhere the terms are defined.\n" + trailing

        let chunks = LLMReferenceIndexSupport.declarationContextChunks(
            pageText: page,
            sourceText: page
        )

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 2_800 })
        XCTAssertTrue(chunks.joined().contains("(1)"))
        XCTAssertFalse(chunks.joined().hasSuffix("bibliography (2019)"))
    }
}

final class ReferenceIndexBenchmarkTests: XCTestCase {
    func testSourceOnlyBenchmarkConfigDoesNotRequireModelArguments() {
        let config = ReferenceIndexBenchmark.Config(arguments: [
            "Cauchy", "--benchmark-indexing", "/tmp/sample.pdf", "--source-only"
        ])

        XCTAssertNotNil(config)
        XCTAssertEqual(config?.sourceOnly, true)
        XCTAssertEqual(config?.sampleSize, 12)
    }

    func testReferenceAuditRetainsSourceOffsetsAndOrigin() throws {
        let source = "Theorem A.0.1. A source-backed statement."
        let entry = IndexedReference(
            reference: DetectedReference(kind: .theorem, number: "A.0.1"),
            formattedBody: "A formatted statement.",
            pageIndex: 2,
            evidence: ReferenceEvidence(
                status: .supported,
                sourceExcerpt: source,
                matchedText: "Theorem A.0.1",
                occurrenceCount: 1,
                startOffset: 0,
                endOffset: source.utf16.count
            ),
            contentOrigin: .modelTranscription
        )

        let audit = ReferenceIndexBenchmark.ReferenceAudit(entry)
        let decoded = try JSONDecoder().decode(
            ReferenceIndexBenchmark.ReferenceAudit.self,
            from: JSONEncoder().encode(audit)
        )

        XCTAssertEqual(decoded, audit)
        XCTAssertEqual(decoded.sourceExcerpt, source)
        XCTAssertEqual(decoded.formattedBody, "A formatted statement.")
        XCTAssertEqual(decoded.endOffset, source.utf16.count)
    }

    func testEvaluationMeasuresAccuracyAndAbstention() {
        let theorem = ReferenceIndexBenchmark.BenchmarkReference(kind: "theorem", number: "1.1")
        let extra = ReferenceIndexBenchmark.BenchmarkReference(kind: "lemma", number: "4.2")
        let metrics = ReferenceIndexBenchmark.evaluate(
            system: "test",
            predictionsByPage: [0: [theorem], 1: [], 2: [extra]],
            truthByPage: [0: [theorem], 1: [], 2: []],
            pageIndices: [0, 1, 2]
        )

        XCTAssertEqual(metrics.truePositives, 1)
        XCTAssertEqual(metrics.falsePositives, 1)
        XCTAssertEqual(metrics.falseNegatives, 0)
        XCTAssertEqual(metrics.precision, 0.5)
        XCTAssertEqual(metrics.recall, 1)
        XCTAssertEqual(metrics.correctAbstentions, 1)
        XCTAssertEqual(metrics.falsePositivePages, 1)
    }

    func testDeterministicBaselinesSeparateMentionsFromHeadings() {
        let page = "By Theorem 1.1 this follows.\nTheorem 2.1. A new statement.\nx + y = z (3.1)"

        let all = ReferenceIndexBenchmark.detectorBaseline(in: page)
        let declarations = ReferenceIndexBenchmark.declarationBaseline(in: page)

        XCTAssertTrue(all.contains(.init(kind: "theorem", number: "1.1")))
        XCTAssertTrue(all.contains(.init(kind: "theorem", number: "2.1")))
        XCTAssertFalse(declarations.contains(.init(kind: "theorem", number: "1.1")))
        XCTAssertTrue(declarations.contains(.init(kind: "theorem", number: "2.1")))
        XCTAssertTrue(declarations.contains(.init(kind: "equation", number: "3.1")))
    }

    func testGroundTruthValidationRejectsDuplicatePages() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("truth.json")
        let data = """
        {"schemaVersion":1,"document":"sample.pdf","pages":[
          {"pageNumber":1,"references":[],"notes":null},
          {"pageNumber":1,"references":[],"notes":null}
        ]}
        """.data(using: .utf8)!
        try data.write(to: url)

        XCTAssertThrowsError(try ReferenceIndexBenchmark.loadGroundTruth(from: url, pageCount: 2))
    }

    func testGroundTruthRejectsTheWrongPDFBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("sample.pdf")
        let truthURL = directory.appendingPathComponent("truth.json")
        try Data("original PDF".utf8).write(to: documentURL)
        let originalHash = try ReferenceIndexCacheStore.fingerprint(for: documentURL)
        let truth = """
        {"schemaVersion":1,"document":"doi:example;sha256:\(originalHash)","pages":[]}
        """.data(using: .utf8)!
        try truth.write(to: truthURL)

        XCTAssertNoThrow(try ReferenceIndexBenchmark.loadGroundTruth(
            from: truthURL, pageCount: 1, documentURL: documentURL
        ))
        try Data("different PDF".utf8).write(to: documentURL)
        XCTAssertThrowsError(try ReferenceIndexBenchmark.loadGroundTruth(
            from: truthURL, pageCount: 1, documentURL: documentURL
        )) { error in
            guard case ReferenceIndexBenchmark.GroundTruthError.documentMismatch = error else {
                return XCTFail("Expected documentMismatch, got \(error)")
            }
        }
    }
}

final class ReferenceMentionFinderTests: XCTestCase {
    func testCandidateMentionsMatchExactReferenceKindAndNumber() {
        let page = """
        By Theorem 2.2.13 we see that f is constant.
        Proposition 2.2.13 gives a different statement.
        Theorem 2.2.14 is not the result cited here.
        """

        let matches = ReferenceMentionFinder.candidateMatches(
            in: page,
            for: DetectedReference(kind: .theorem, number: "2.2.13")
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.matchedText, "Theorem 2.2.13")
        XCTAssertEqual(matches.first?.context, "By Theorem 2.2.13 we see that f is constant.")
    }

    func testCandidateOffsetsRemainUTF16CorrectAfterMathSymbols() {
        let page = "π → f. By Theorem 2.2.13 we conclude the claim."
        let matches = ReferenceMentionFinder.candidateMatches(
            in: page,
            for: DetectedReference(kind: .theorem, number: "2.2.13")
        )

        XCTAssertEqual(matches.count, 1)
        guard let match = matches.first else { return XCTFail("Expected a citation match") }
        let range = NSRange(location: match.startOffset,
                            length: match.endOffset - match.startOffset)
        XCTAssertEqual((page as NSString).substring(with: range), "Theorem 2.2.13")
    }

    func testStandaloneCitationIncludesPreviousProofLine() {
        let page = """
        Proof. Extend a basis of U to a basis of V. By
        Theorem 3.9
        the asserted block matrix follows.
        """
        let matches = ReferenceMentionFinder.candidateMatches(
            in: page,
            for: DetectedReference(kind: .theorem, number: "3.9")
        )

        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(matches.first?.context.contains("basis of V. By Theorem 3.9") == true)
    }
}

@MainActor
final class AskContextRetrieverEvidenceTests: XCTestCase {
    func testFigureRetrievalLabelsCaptionWithoutClaimingImageInterpretation() {
        let reference = DetectedReference(kind: .figure, number: "3")
        let source = "Fig. 3 | Scaling learned interatomic potentials. a, Classification error."
        let entry = IndexedReference(
            reference: reference,
            formattedBody: "Scaling learned interatomic potentials",
            pageIndex: 4,
            evidence: ReferenceEvidence(
                status: .supported,
                sourceExcerpt: source,
                matchedText: "Fig. 3",
                occurrenceCount: 1,
                startOffset: 0,
                endOffset: source.utf16.count
            ),
            contentOrigin: .sourceFallback
        )
        let index = DocumentReferenceIndex()
        index.replace(with: DocumentReferenceIndexSnapshot(entries: [reference.key: entry], pageCount: 5))

        let retrieval = AskContextRetriever.retrieve(
            question: "What does Fig. 3 show?",
            selectedText: "",
            surroundingText: "",
            pageIndex: nil,
            referenceIndex: index,
            documentIndex: nil,
            passageLimit: 0
        )

        XCTAssertEqual(retrieval.statements.count, 1)
        XCTAssertTrue(retrieval.statements[0].contains("caption heading only; image not interpreted"))
        XCTAssertTrue(retrieval.statements[0].contains(source))
        XCTAssertEqual(retrieval.statementReferences.map(\.reference), [reference])
    }

    func testRetrievalReportsOnlyPagesActuallySupplied() {
        let retrieval = AskRetrieval(
            statements: ["Theorem 1.2, p. 7 [PDF source excerpt]:\nStatement"],
            statementRoutes: ["cited"],
            passages: ["[p. 11] Another passage", "malformed passage"]
        )

        XCTAssertEqual(retrieval.sourcePageNumbers, [7, 11])
    }

    func testPassageLocationAllowsParagraphWhitespaceButNotAmbiguousText() {
        let page = "Introduction.\n\nA theorem has a first line.\n\nIts conclusion follows.\n\nEnd."
        let chunk = "A theorem has a first line.\nIts conclusion follows."
        let location = LexicalDocumentIndex.sourceLocation(
            for: chunk,
            in: page,
            pageIndex: 2,
            after: 0
        )
        XCTAssertEqual(location?.pageIndex, 2)
        XCTAssertEqual(location?.matchedText, "A theorem has a first line.\n\nIts conclusion follows.")
        XCTAssertEqual(location?.startOffset, (page as NSString).range(of: "A theorem").location)
        XCTAssertNil(LexicalDocumentIndex.sourceLocation(
            for: "Repeated source text.",
            in: "Repeated source text.\nRepeated source text.",
            pageIndex: 0,
            after: 0
        ))
    }

    func testPromptClippingDropsPassageLocationWhenSourceTextIsTruncated() {
        let passage = "[p. 3] " + String(repeating: "source ", count: 130)
        let location = PDFTextLocation(
            pageIndex: 2,
            matchedText: String(repeating: "source ", count: 130),
            startOffset: 0,
            endOffset: 910
        )
        let retrieval = AskRetrieval(
            statements: [],
            statementRoutes: [],
            passages: [passage],
            passageRecords: [DocumentPassage(text: passage, location: location)]
        )

        let clipped = retrieval.clippedForPrompt(provider: .ollama)

        XCTAssertEqual(clipped.passages.count, 1)
        XCTAssertLessThan(clipped.passages[0].count, passage.count)
        XCTAssertNil(clipped.passageRecords[0].location)

        let complete = DocumentPassage(
            text: "[p. 3] A complete source passage that is long enough for the prompt budget.",
            location: location
        )
        let completeRetrieval = AskRetrieval(
            statements: [],
            statementRoutes: [],
            passages: [complete.text],
            passageRecords: [complete]
        ).clippedForPrompt(provider: .ollama)
        XCTAssertEqual(completeRetrieval.passageRecords.first?.location, location)
    }

    func testAskRetrievalCarriesAnchoredPassageWithoutInventingARegion() {
        let location = PDFTextLocation(
            pageIndex: 2,
            matchedText: "A passage from the PDF.",
            startOffset: 50,
            endOffset: 73
        )
        let record = DocumentPassage(
            text: "[p. 3] A passage from the PDF.",
            location: location
        )
        let retrieval = AskContextRetriever.retrieve(
            question: "What does the passage say?",
            selectedText: "",
            surroundingText: "",
            pageIndex: nil,
            referenceIndex: nil,
            documentIndex: AnchoredPassageIndexStub(record: record),
            passageLimit: 1
        )

        XCTAssertEqual(retrieval.passages, [record.text])
        XCTAssertEqual(retrieval.passageRecords, [record])
    }

    func testAnswerContextUsesPDFEvidenceInsteadOfModelTranscription() {
        let reference = DetectedReference(kind: .theorem, number: "A.0.1")
        let source = "Theorem A.0.1. For each x_n in the sequence, its limit is x."
        let entry = IndexedReference(
            reference: reference,
            formattedBody: "For each x^n in the sequence, its limit is x.",
            pageIndex: 2,
            evidence: ReferenceEvidence(
                status: .supported,
                sourceExcerpt: source,
                matchedText: "Theorem A.0.1",
                occurrenceCount: 1,
                startOffset: 0,
                endOffset: source.utf16.count
            )
        )
        let index = DocumentReferenceIndex()
        index.replace(with: DocumentReferenceIndexSnapshot(entries: [reference.key: entry], pageCount: 3))

        let retrieval = AskContextRetriever.retrieve(
            question: "What does Theorem A.0.1 say?",
            selectedText: "",
            surroundingText: "",
            pageIndex: nil,
            referenceIndex: index,
            documentIndex: nil,
            passageLimit: 0
        )

        XCTAssertEqual(retrieval.statements.count, 1)
        XCTAssertTrue(retrieval.statements[0].contains(source))
        XCTAssertFalse(retrieval.statements[0].contains("x^n"))
        XCTAssertTrue(DocumentReferenceIndexSnapshot.searchableText(for: entry).contains("x_n"))
    }

    func testLegacyEntryWithoutEvidenceIsNotInjectedAsGroundTruth() {
        let reference = DetectedReference(kind: .theorem, number: "1.1")
        let entry = IndexedReference(
            reference: reference,
            formattedBody: "A model-only statement.",
            pageIndex: 0
        )
        let index = DocumentReferenceIndex()
        index.replace(with: DocumentReferenceIndexSnapshot(entries: [reference.key: entry], pageCount: 1))

        let retrieval = AskContextRetriever.retrieve(
            question: "What does Theorem 1.1 say?",
            selectedText: "",
            surroundingText: "",
            pageIndex: nil,
            referenceIndex: index,
            documentIndex: nil,
            passageLimit: 0
        )

        XCTAssertTrue(retrieval.statements.isEmpty)
    }

    func testReplacingIndexRetainsMentionGraphAndClearingRemovesIt() {
        let reference = DetectedReference(kind: .theorem, number: "1.1")
        let entry = IndexedReference(
            reference: reference,
            formattedBody: "A theorem.",
            pageIndex: 0
        )
        let expected = ReferenceMentionSearchResult(
            mentions: [],
            pagesWithoutText: 1,
            unresolvedMatches: 0,
            truncated: false
        )
        let graph = ReferenceMentionGraph(
            schemaVersion: ReferenceMentionGraph.schemaVersion,
            documentFingerprint: "fingerprint",
            records: [ReferenceGraphRecord(
                definition: ReferenceGraphDefinition(
                    reference: reference,
                    pageIndex: 0,
                    definingEndOffset: nil
                ),
                result: expected
            )]
        )
        let index = DocumentReferenceIndex()

        index.replace(with: DocumentReferenceIndexSnapshot(
            entries: [reference.key: entry],
            pageCount: 1,
            mentionGraph: graph
        ))
        XCTAssertEqual(index.laterMentions(for: reference), expected)

        index.clear()
        XCTAssertNil(index.laterMentions(for: reference))
    }
}

final class OCRReferenceCandidateDetectorTests: XCTestCase {
    func testRepairsOnlyPunctuationNoiseInNumberedHeadings() {
        XCTAssertEqual(
            OCRReferenceCandidateDetector.normalizeReferenceLabel(
                in: "Definition 1.3. 2. Suppose that u is twice differentiable."
            ),
            "Definition 1.3.2. Suppose that u is twice differentiable."
        )
        XCTAssertEqual(
            OCRReferenceCandidateDetector.normalizeReferenceLabel(
                in: "Theorem 1,3.3. Let U be open."
            ),
            "Theorem 1.3.3. Let U be open."
        )
        XCTAssertEqual(
            OCRReferenceCandidateDetector.normalizeReferenceLabel(
                in: "Remark 1.4.1 r. OCR did not resolve the final digit."
            ),
            "Remark 1.4.1 r. OCR did not resolve the final digit."
        )
    }

    func testFindsNamedAndRightMarginEquationCandidatesWithRegions() {
        let headingRegion = NormalizedRect(x: 0.2, y: 0.7, width: 0.6, height: 0.04)
        let equationRegion = NormalizedRect(x: 0.8, y: 0.5, width: 0.1, height: 0.03)
        let result = OCRResult(
            rawText: "",
            observations: [
                OCRTextObservation(
                    text: "Definition 1.3. 2. Suppose that u is twice differentiable.",
                    confidence: 0.91,
                    boundingBox: headingRegion
                ),
                OCRTextObservation(
                    text: "(1.3.4)",
                    confidence: 0.88,
                    boundingBox: equationRegion
                ),
                OCRTextObservation(
                    text: "By (1.3.5) the result follows.",
                    confidence: 0.95,
                    boundingBox: NormalizedRect(x: 0.2, y: 0.4, width: 0.6, height: 0.03)
                ),
            ],
            latexSnippet: ""
        )

        let candidates = OCRReferenceCandidateDetector.candidates(in: result)

        XCTAssertEqual(candidates.map { "\($0.kind):\($0.number)" }, [
            "definition:1.3.2", "equation:1.3.4",
        ])
        XCTAssertEqual(candidates[0].region, headingRegion)
        XCTAssertEqual(candidates[1].region, equationRegion)
    }

    func testCandidateIsRegionAnchoredButNeverAnswerGrounding() throws {
        let region = NormalizedRect(x: 0.1, y: 0.8, width: 0.7, height: 0.04)
        let candidate = OCRReferenceCandidate(
            kind: ReferenceKind.definition.rawValue,
            number: "1.3.2",
            rawLine: "Definition 1.3. 2. OCR text",
            normalizedLine: "Definition 1.3.2. OCR text",
            confidence: 0.9,
            region: region
        )

        let indexed = try XCTUnwrap(candidate.indexedReference(pageIndex: 4))

        XCTAssertEqual(indexed.contentOrigin, .ocrCandidate)
        XCTAssertEqual(indexed.evidence?.effectiveSource, .visionOCR)
        XCTAssertEqual(indexed.evidence?.matchedRegion, region)
        XCTAssertEqual(indexed.groundingBody, "")
    }

    func testOCRRegionResolverAcceptsOnlyValidNormalizedBoxes() throws {
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        image.unlockFocus()
        let page = try XCTUnwrap(PDFPage(image: image))
        let valid = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04)
        let evidence = ReferenceEvidence(
            status: .uncertain,
            sourceExcerpt: "Theorem 1.1",
            matchedText: "Theorem 1.1",
            occurrenceCount: 1,
            startOffset: 0,
            endOffset: 11,
            source: .visionOCR,
            matchedRegion: valid
        )
        let invalid = ReferenceEvidence(
            status: .uncertain,
            sourceExcerpt: "Theorem 1.1",
            matchedText: "Theorem 1.1",
            occurrenceCount: 1,
            startOffset: 0,
            endOffset: 11,
            source: .visionOCR,
            matchedRegion: NormalizedRect(x: 0.9, y: 0.2, width: 0.2, height: 0.04)
        )

        XCTAssertEqual(ReferenceEvidenceRegionResolver.exactRegion(for: evidence, on: page), valid)
        XCTAssertNil(ReferenceEvidenceRegionResolver.exactRegion(for: invalid, on: page))
    }
}

final class DocumentBlockExtractorTests: XCTestCase {
    func testBuildsBlockFromIndexedReference() {
        let indexed = IndexedReference(
            reference: DetectedReference(kind: .equation, number: "9.9"),
            formattedBody: "$$a=b$$",
            pageIndex: 7
        )

        let block = DocumentBlockExtractor.block(from: indexed)

        XCTAssertEqual(block.reference.number, "9.9")
        XCTAssertEqual(block.formattedBody, "$$a=b$$")
        XCTAssertEqual(block.pageIndex, 7)
    }
}

private struct AnchoredPassageIndexStub: DocumentIndexProtocol {
    let record: DocumentPassage

    func passages(matching query: String, limit: Int, excludingPage: Int?) -> [String] {
        limit > 0 ? [record.text] : []
    }

    func passageRecords(
        matching query: String,
        queryVector: [Float]?,
        limit: Int,
        excludingPage: Int?
    ) -> [DocumentPassage] {
        limit > 0 ? [record] : []
    }
}
