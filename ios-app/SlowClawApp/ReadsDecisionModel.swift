import Foundation
import CryptoKit

/// Native operations run only on OnDeviceAIExecutor. The handle never escapes
/// this wrapper and is released on that executor after each curation pass.
final class ReadsDecisionModel: @unchecked Sendable {
    static let preset = LocalModelPreset(
        id: "reads-qwen3-reranker-0.6b-q4km-v1",
        title: "Reads relevance model",
        detail: "Qwen3-Reranker 0.6B · Apache 2.0 · only used on this device",
        fileName: "Qwen3-Reranker-0.6B.Q4_K_M.gguf",
        downloadURL: URL(string: "https://huggingface.co/QuantFactory/Qwen3-Reranker-0.6B-GGUF/resolve/9bdee8f1ad01d7896a20823d5affd66c494eee8b/Qwen3-Reranker-0.6B.Q4_K_M.gguf")!,
        sizeBytes: 484_000_000, sizeLabel: "484 MB")

    private var handle: UnsafeMutableRawPointer?
    init(path: String) throws {
        // Validate the actual trained weights, not the uninformative GGUF name.
        // Stream the hash off-main; never allocate the 484 MB file as one Data.
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == "783d816e7541ba78a5105f949a010217fecf31795c267d69ffa5a96403dff4a7" else {
            throw PublishingError.message("The Reads model is incomplete or different. Remove it in Settings and download it again.")
        }
        handle = path.withCString { slowclaw_feed_reads_model_open($0, path.utf8.count) }
        guard handle != nil else {
            throw PublishingError.message("Couldn't load the Reads model. Remove it in Settings and download it again.")
        }
    }
    func score(query: String, document: String) -> Double? {
        var result = -1.0
        let status = query.withCString { queryBytes in
            document.withCString { documentBytes in
                slowclaw_feed_reads_score(handle, queryBytes, query.utf8.count,
                    documentBytes, document.utf8.count, &result)
            }
        }
        return status == 0 && result.isFinite && (0...1).contains(result) ? result : nil
    }
    func close() {
        slowclaw_feed_reads_model_close(handle)
        handle = nil
    }
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
                Text("Qwen3-Reranker 0.6B").font(.headline)
                Text("Fast local relevance for articles and Nostr posts, using your journals and personal memory.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("484 MB · Apache 2.0 · Separate from your writing model")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if !state.readsModelInstalled {
                if downloading {
                    ProgressView(value: state.localModelProgress[preset.id] ?? 0)
                } else {
                    Button("Download · 484 MB") { Task { await state.downloadReadsModel() } }
                        .buttonStyle(.bordered)
                }
                if let error = state.localModelError { Text(error).font(.caption) }
            } else if showRemove || !state.readsModelEnabled {
                HStack {
                    if state.readsModelEnabled {
                        Label("Active for Reads", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                        Spacer()
                        Button("Deactivate") { state.deactivateReadsModel() }
                    } else {
                        Button(state.readsModelActivating ? "Activating…" : "Activate for Reads") {
                            Task { await state.activateReadsModel() }
                        }.buttonStyle(.bordered)
                            .disabled(state.readsModelActivating || state.readsDecisionBusy)
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
                Button("Remove Reads model", role: .destructive) { Task { await state.removeReadsModel() } }
                    .disabled(state.readsDecisionBusy || state.readsModelActivating || downloading)
            }
        }.padding(.horizontal)
    }
}
