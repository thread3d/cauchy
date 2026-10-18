# Cauchy reference-index benchmark

This benchmark answers a narrower, testable question than “does the AI look
good?”:

> Given a difficult PDF page, did Cauchy retain exactly the numbered statements,
> equations, and figure captions introduced there, abstain on pages without them, and
> preserve inspectable source evidence for every accepted result?

## Build a labelled set

Start with 20 PDFs that represent real failure modes rather than 20 clean papers:

- born-digital mathematics with dense notation;
- scanned or OCR-derived notes;
- two-column papers;
- long theorem statements crossing extraction chunks;
- tables of contents and theorem indexes;
- pages that cite many results but introduce none;
- equations whose numbers are easily confused with ordinary parentheticals;
- non-mathematical technical papers with numbered assumptions or propositions.

Copy `ground-truth.example.json` once per PDF. Page numbers are one-based, as in
the Cauchy UI. Label both positive pages and hard negative pages. A reference
belongs in the label only when its statement, equation, or printed figure
caption is introduced on that page; citations such as “by Theorem 2.1” or
“see Fig. 3a” do not count. Figure entries currently anchor the caption
heading, not the chart's visual contents or a complete caption transcription.
For a kind-specific slice, add `"evaluatedKinds": ["figure"]` to the labels:
the app still extracts normally, but precision, recall, and false-positive
comparison ignore other reference kinds on those pages. The scope appears in
the report so it cannot be mistaken for whole-index accuracy.

Keep PDFs outside this repository unless their licences explicitly permit
redistribution. Ground-truth JSON can be committed without the source PDFs when
`document` records a stable title, DOI, URL, or content hash.
When `document` includes `sha256:<digest>`, the runner checks the PDF bytes
before evaluating; a mismatched file is an error, not a benchmark result.

## Run

After building Cauchy, invoke the app executable:

```sh
/path/to/Cauchy.app/Contents/MacOS/Cauchy \
  --benchmark-indexing /path/to/document.pdf \
  --ground-truth /path/to/document.ground-truth.json \
  --output /path/to/report-directory
```

Without `--pages`, every labelled page is evaluated. Use `--pages N` only for a
quick prefix of the labelled set. Without `--ground-truth`, Cauchy preserves the
older exploratory mode: evenly spaced pages and an optional comparison with the
existing cache.

Each run emits `report.json` for analysis and `report.md` for review. The report
contains:

- precision, recall, and F1 for the production extractor;
- the same metrics for an all-syntactic-mentions baseline and a deterministic
  declaration heuristic;
- correct abstentions on labelled negative pages and missed positive pages;
- supported versus ambiguous source evidence counts;
- located versus unresolved original-page regions for accepted references;
- a failure atlas of extraction errors, false positives, false negatives,
  validation rejections, and ambiguous evidence;
- latency and the projected full-document runtime.

Pass `--source-only` to run the same page prefilters and source-backed
declaration fallbacks without invoking an AI model. This comparison mode does
not change the reader's production index. Compare its precision, recall,
anchor coverage, and latency with a model-backed run on the same fixed labels
before treating model formatting as a benefit.

The local `report.json` also includes `referenceAudit` for each page: the
accepted body, its model/source origin, verbatim PDF excerpt, evidence status,
occurrence count, UTF-16 source offsets, and (where PDFKit resolves it) the
normalized original-page region of the exact printed heading, equation label,
or figure caption label.
Compare these fields manually
before claiming that a transcription is faithful; reference-number accuracy
alone does not measure semantic correctness. These reports can contain source
text, so do not publish them without checking the PDF's redistribution rights.

The first checked-in corpus slices and results are:

- `corpus/metric-spaces-notes.ground-truth.json` with
  `results/2026-09-22-metric-spaces-on-device.md`;
- `corpus/scaling-deep-learning-materials.ground-truth.json` with
  `results/2026-09-22-materials-discovery-on-device.md`;
- `corpus/differential-equations-i.ground-truth.json` with
  `results/2026-09-22-differential-equations-on-device.md`.
- `corpus/complex-analysis.ground-truth.json` with
  `results/2026-09-22-complex-analysis-on-device.md`.
- `corpus/materials-figures.ground-truth.json` and
  `corpus/materials-figure-mentions.ground-truth.json` with
  `results/2026-09-24-figure-caption-evidence.md`.
- `corpus/differential-equations-figures.holdout.ground-truth.json` with
  `results/2026-09-24-figure-caption-holdout-baseline.md`.

They are intentionally reported per document rather than presented as proof about
arbitrary PDFs. The original materials-discovery, differential-equations, and
complex-analysis results predate figure indexing and treated figures as out of scope. Their
ground-truth files now include the visually confirmed caption objects; the
September 22 snapshots are historical results, not directly comparable with
fresh runs under the expanded target.

To combine labelled run directories without averaging away document failures:

```sh
python3 Benchmarks/aggregate_reports.py /path/to/first-run /path/to/second-run
python3 -m unittest discover -s Benchmarks -p 'test_*.py'
```

The output is a per-document table plus micro-averaged corpus metrics. The
first two-document snapshot is `results/2026-09-22-two-document-corpus.md`;
the updated three-document snapshot is `results/2026-09-22-three-document-corpus.md`.
The latest four-document development snapshot is
`results/2026-09-22-four-document-corpus.md`.
The model-free comparison on three of those documents is
`results/2026-09-22-source-only-three-document.md`.
The first untuned result on two held-out mathematics PDFs is
`results/2026-09-22-two-document-holdout-baseline.md`; keep it distinct from
post-fix reruns. The post-fix comparison is
`results/2026-09-23-geometry-aware-equation-indexing.md`.
The first fixed citation-edge slice is
`corpus/reference-mentions.ground-truth.json`, with results and limitations in
`results/2026-09-23-later-mentions-probe.md`. Run it against the local source
PDFs with:

```sh
python3 Benchmarks/evaluate_mentions.py \
  --app /path/to/Cauchy.app/Contents/MacOS/Cauchy \
  --pdf-dir /path/to/labelled-pdfs
```

This separate benchmark checks exact later mention counts and pages, including
same-page citations after the defining statement and no-mention controls. It
checks the source PDF SHA-256 before running and reports unlocated matches.
The first predeclared, independent mention check is
`corpus/reference-mentions.holdout.ground-truth.json`, with its first-run result
preserved in `results/2026-09-23-reference-mentions-holdout-baseline.md`.
Portable index/graph validation and its automated export-delete-import
acceptance path are documented in
`results/2026-09-23-portable-evidence-roundtrip.md`.
The answer-evidence boundary, failure semantics, and persistence checks are
documented in `results/2026-09-23-answer-evidence-boundary.md`.
An image-only one-page control is documented in
`results/2026-09-22-image-only-control.md`; that result is the preserved
pre-OCR baseline. The labelled OCR development slice, predeclared holdout, and
production-path acceptance result are documented in
`results/2026-09-23-ocr-candidate-holdout.md`. They remain separate from the
born-digital corpus aggregate.
For local diagnostics, `Cauchy --probe-ocr <pdf> <page> fast --json` prints
Vision's transcript candidates. Add `--output <dir>` to render crops with the
accepted regions outlined. `Cauchy --probe-vision <pdf> <page>` asks an installed
Ollama vision model for visible numbered references; it reports the limitation
when no installed model advertises vision support. Only the conservative local
OCR candidate detector participates in production image-only indexing;
image-model guesses do not.

## Review protocol

1. Read every production false positive and false negative in the failure atlas.
2. Open the corresponding PDF page and decide whether the label or extractor is
   wrong; fix labels before tuning code.
3. Treat ambiguous evidence as a review queue, not a passing result.
   Also inspect any `unresolved_page_region` failure: text grounding alone does
   not prove the reader can show the exact printed location.
4. Report corpus composition and per-document results. A single aggregate score
   can hide total failure on scans or two-column layouts.
5. Keep the corpus fixed while comparing implementations. Add a separate holdout
   set before making public quality claims.
