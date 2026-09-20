import Foundation
import CryptoKit

/// A separate Kev handle, used and closed only on OnDeviceAIExecutor.
final class ReadsDecisionModel: @unchecked Sendable {
    static let preset = LocalModelPreset(
        id: "kev-0.5b-q8-v1", title: "Kev-0.5B",
        detail: "Local judge for Reads and journal selections · Apache 2.0",
        fileName: "slowclaw-kev-q8.gguf",
        downloadURL: URL(string: "https://github.com/zanynik/slowclaw.social/releases/download/kev-lite-model-v1/slowclaw-kev-q8.gguf")!,
        sizeBytes: 532904896, sizeLabel: "533 MB")
    static let digest = "4606b739bd5fae0c77c2dc978a8983a9cc1eccd476d97d02f2e1e154ea537686"
    private var handle: UnsafeMutableRawPointer?
    init(path: String) throws {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == Self.digest else {
            throw PublishingError.message("Kev's download is incomplete or different. Remove it and download again.")
        }
        handle = path.withCString { slowclaw_feed_kev_open($0, path.utf8.count) }
        guard handle != nil else { throw PublishingError.message("Couldn't load Kev. Try again after closing other model work.") }
    }
    func evaluate(state: String, questions: [KevQuestion]) -> [[Double]]? {
        struct Request: Encodable { let state: String; let questions: [KevQuestion] }
        guard !state.isEmpty, (1...8).contains(questions.count),
              questions.allSatisfy({ (2...8).contains($0.options.count) }),
              let data = try? JSONEncoder().encode(Request(state: state, questions: questions)),
              let json = String(data: data, encoding: .utf8) else { return nil }
        var values = [Double](repeating: -1, count: questions.reduce(0) { $0 + $1.options.count })
        let capacity = values.count
        let count = json.withCString { slowclaw_feed_kev_evaluate(handle, $0, json.utf8.count, &values, capacity) }
        guard count == capacity else { return nil }
        var offset = 0
        var result: [[Double]] = []
        for q in questions {
            let row = Array(values[offset..<(offset + q.options.count)])
            guard KevLite.validDistribution(row) else { return nil }
            result.append(row); offset += q.options.count
        }
        return result
    }
    func judge(memory: String, document: String) -> KevReadingJudgement? {
        evaluate(state: document, questions: KevReadingJudgement.questions(memory: memory)).flatMap(KevReadingJudgement.init)
    }
    func close() { slowclaw_feed_kev_close(handle); handle = nil }
}

import SwiftUI

struct ReadsModelCard: View {
    @EnvironmentObject var state: AppState
    var showRemove = false
    var body: some View {
        let preset = ReadsDecisionModel.preset
        let downloading = state.activeDownloadIDs.contains(preset.id)
        VStack(alignment: .leading, spacing: 8) {
            if showRemove || !state.readsModelInstalled || !state.readsModelEnabled {
                Text("Kev-0.5B · Lite experiment").font(.headline)
                Text("Ranks reading and selects your own journal sentences, entirely on this device.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("533 MB · Apache 2.0 · Experimental rankings")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !state.readsModelInstalled {
                if downloading {
                    ProgressView(value: state.localModelProgress[preset.id] ?? 0)
                } else {
                    Button("Download · 533 MB") { Task { await state.downloadReadsModel() } }
                        .buttonStyle(.bordered)
                }
                if let error = state.localModelError { Text(error).font(.caption) }
            } else if showRemove || !state.readsModelEnabled {
                HStack {
                    if state.readsModelEnabled {
                        Label("Kev active", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                        Spacer()
                        Button("Deactivate") { state.deactivateReadsModel() }
                    } else {
                        Button(state.readsModelActivating ? "Activating…" : "Activate Kev") {
                            Task { await state.activateReadsModel() }
                        }.buttonStyle(.bordered)
                            .disabled(state.readsModelActivating || state.readsDecisionBusy || state.kevJournalBusy)
                    }
                }
            }
            if let status = state.readsDecisionStatus, state.readsModelInstalled {
                HStack {
                    if state.readsDecisionBusy || state.readsModelActivating { ProgressView() }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                    if state.readsModelEnabled && !state.readsDecisionBusy && !state.readsModelActivating {
                        Button("Retry") { Task { await state.refreshReadsDecisions() } }
                    }
                }
            }
            if showRemove && state.readsModelInstalled {
                Button("Remove Kev model", role: .destructive) { Task { await state.removeReadsModel() } }
                    .disabled(state.readsDecisionBusy || state.readsModelActivating || state.kevJournalBusy || downloading)
            }
        }.padding(.horizontal)
    }
}
