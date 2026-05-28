/**
 * ProfileView.tsx — Settings and AI model management view.
 *
 * Extracted from the Profile tab section of the App.tsx monolith.
 * Provides a clean, focused component for:
 * - Local AI model hub
 * - Bluesky login
 * - Runtime configuration
 * - Device sync/pairing
 *
 * Inspired by Atomic Chat's settings route pattern where each section
 * is its own clean component rather than inline JSX in a god component.
 */

import { Skeleton, SkeletonModelCard } from "../components/ui/Skeleton";
import { ModelsEmptyState } from "../components/ui/EmptyState";

type LocalModelCatalogItemDisplay = {
  id: string;
  title: string;
  description: string;
  family: string;
  engine: string;
  sizeLabel: string;
  sizeBytes?: number;
  installed: boolean;
  active: boolean;
  download?: {
    status: string;
    transferredBytes?: number;
    totalBytes?: number;
    error?: string;
  } | null;
};

type ProfileViewProps = {
  localModels: LocalModelCatalogItemDisplay[];
  localModelsStatus: string;
  localModelsLoading: boolean;
  localAiReady: boolean;
  localAiStateLabel: string;
  installedLocalModelCount: number;
  activeLocalModel: LocalModelCatalogItemDisplay | undefined;
  localModelBusyId: string;
  isMobileRuntime: boolean;
  onRefreshModels: () => void;
  onDownloadModel: (id: string) => void;
  onStartModel: (id: string) => void;
  onSelectModel: (id: string) => void;
};

function ModelCard({
  model,
  busyId,
  isMobileRuntime,
  onDownload,
  onStart,
  onSelect,
}: {
  model: LocalModelCatalogItemDisplay;
  busyId: string;
  isMobileRuntime: boolean;
  onDownload: (id: string) => void;
  onStart: (id: string) => void;
  onSelect: (id: string) => void;
}) {
  const download = model.download;
  const isDownloading = download?.status === "downloading";
  const transferred = download?.transferredBytes || 0;
  const total = download?.totalBytes || model.sizeBytes || 0;
  const progress = total > 0 ? Math.min(100, Math.round((transferred / total) * 100)) : 0;

  return (
    <article className="local-model-card">
      <div className="row-between">
        <span className="local-model-family">{model.family}</span>
        <span className={model.installed ? "local-model-pill installed" : "local-model-pill"}>
          {model.active ? "Active" : model.installed ? "Downloaded" : model.sizeLabel}
        </span>
      </div>
      <h3>{model.title}</h3>
      <p className="text-sm muted">{model.description}</p>
      <div className="model-card-meta">
        <span>{model.engine}</span>
        <span>{model.sizeLabel}</span>
        <span>{model.installed ? "On device" : "Not downloaded"}</span>
      </div>
      {isDownloading ? (
        <div className="local-model-progress">
          <div className="local-model-progress-track">
            <div className="local-model-progress-fill" style={{ width: `${progress}%` }} />
          </div>
          <span className="text-sm muted">{progress}%</span>
        </div>
      ) : null}
      {download?.status === "failed" && download.error ? (
        <p className="text-sm local-model-error">{download.error}</p>
      ) : null}
      <div className="model-card-actions">
        {model.installed ? (
          <>
            <button
              type="button"
              className="primary"
              onClick={() => onStart(model.id)}
              disabled={Boolean(busyId)}
            >
              {isMobileRuntime ? "Use On iPhone" : "Start Runtime"}
            </button>
            <button
              type="button"
              className="ghost"
              onClick={() => onSelect(model.id)}
              disabled={Boolean(busyId) || model.active}
            >
              {model.active ? "Selected" : "Set Default"}
            </button>
          </>
        ) : (
          <button
            type="button"
            className="primary"
            onClick={() => onDownload(model.id)}
            disabled={Boolean(busyId) || isDownloading}
          >
            {isDownloading ? "Downloading..." : "Download"}
          </button>
        )}
      </div>
    </article>
  );
}

export function ProfileView({
  localModels,
  localModelsStatus,
  localModelsLoading,
  localAiReady,
  localAiStateLabel,
  installedLocalModelCount,
  activeLocalModel,
  localModelBusyId,
  isMobileRuntime,
  onRefreshModels,
  onDownloadModel,
  onStartModel,
  onSelectModel,
}: ProfileViewProps) {
  return (
    <div className="stack view-enter">
      <div className="card local-models-card">
        <div className="model-hub-hero">
          <div>
            <p className="eyebrow">Local AI</p>
            <h2>Choose Your On-Device Brain</h2>
            <p className="text-sm muted">
              Download one private model, then use it to turn journal notes into tasks,
              insights, and your personalized Me feed.
            </p>
            <div className="model-hub-chips">
              <span>Journal notes</span>
              <span>Task extraction</span>
              <span>Me feed insights</span>
            </div>
          </div>
          <div className="model-hub-status-card">
            <span className={localAiReady ? "model-hub-orb ready" : "model-hub-orb"} />
            <p className="text-sm muted">Local AI status</p>
            <strong>{localAiStateLabel}</strong>
            <span className="text-sm muted">
              {installedLocalModelCount} downloaded
            </span>
            <button
              type="button"
              className="ghost"
              onClick={onRefreshModels}
              disabled={Boolean(localModelBusyId)}
            >
              Refresh
            </button>
          </div>
        </div>

        <div className="model-hub-selected">
          <div>
            <p className="text-sm muted">Selected model</p>
            <strong>{activeLocalModel?.title || "No model selected yet"}</strong>
            <p className="text-sm muted">
              {activeLocalModel
                ? `${activeLocalModel.family} · ${activeLocalModel.engine}`
                : "Pick a compact model below to keep SlowClaw private and phone-first."}
            </p>
          </div>
          <div className="model-hub-selected-meta">
            <span>{activeLocalModel?.sizeLabel || "GGUF"}</span>
            <span>{isMobileRuntime ? "iPhone bridge" : "Desktop server"}</span>
          </div>
        </div>

        {localModelsLoading ? (
          <div className="local-model-grid">
            <SkeletonModelCard />
            <SkeletonModelCard />
            <SkeletonModelCard />
          </div>
        ) : localModels.length === 0 ? (
          <ModelsEmptyState />
        ) : (
          <div className="local-model-grid">
            {localModels.map((model) => (
              <ModelCard
                key={model.id}
                model={model}
                busyId={localModelBusyId}
                isMobileRuntime={isMobileRuntime}
                onDownload={onDownloadModel}
                onStart={onStartModel}
                onSelect={onSelectModel}
              />
            ))}
          </div>
        )}

        {localModelsStatus ? (
          <p className="text-sm muted">{localModelsStatus}</p>
        ) : null}
      </div>
    </div>
  );
}
