import type { WorkspaceSynthesizerStatus, WorkspaceTodoItem } from "../lib/gatewayApi";

type WorkspaceSynthArtifactBadge = {
  key: string;
  label: string;
  toneClassName: string;
  title: string;
};

type TodosViewProps = {
  openTodos: WorkspaceTodoItem[];
  doneTodos: WorkspaceTodoItem[];
  overdueTodoCount: number;
  workspaceSynthStatus: WorkspaceSynthesizerStatus;
  workspaceSynthArtifactBadges: WorkspaceSynthArtifactBadge[];
  formatTodoDueLabel: (value?: string | null) => string;
  formatTimestamp: (value?: number | string) => string;
  onToggleTodo: (item: WorkspaceTodoItem) => void;
};

export function TodosView({
  openTodos,
  doneTodos,
  overdueTodoCount,
  workspaceSynthStatus,
  workspaceSynthArtifactBadges,
  formatTodoDueLabel,
  formatTimestamp,
  onToggleTodo
}: TodosViewProps) {
  return (
    <div className="stack">
      <div className="card">
        <div className="stack-sm">
          <h2 style={{ margin: 0 }}>Todos</h2>
          <p className="text-sm muted" style={{ margin: 0 }}>
            Action items extracted from journals and transcripts. Marking one done keeps the model
            suggestion but preserves your override locally.
          </p>
        </div>

        <div className="workspace-synth-card">
          <div className="planner-overview-row">
            <span className="status-pill">Open {openTodos.length}</span>
            <span className="status-pill">Done {doneTodos.length}</span>
            <span className="status-pill">Overdue {overdueTodoCount}</span>
          </div>
          <div className="workspace-synth-artifacts">
            {workspaceSynthArtifactBadges.map((artifact) => (
              <span
                key={artifact.key}
                className={`status-pill workspace-synth-pill ${artifact.toneClassName}`}
                title={artifact.title}
              >
                {artifact.label}
              </span>
            ))}
          </div>
          {workspaceSynthStatus.lastSummary ? (
            <span className="text-sm muted">{workspaceSynthStatus.lastSummary}</span>
          ) : null}
        </div>

        {openTodos.length === 0 && doneTodos.length === 0 ? (
          <div className="planner-empty-state">
            <p className="text-center muted" style={{ margin: 0 }}>
              No todos extracted from your workspace yet.
            </p>
          </div>
        ) : (
          <div className="stack">
            {openTodos.length > 0 ? (
              <div className="stack">
                <div className="planner-section-header">
                  <h3 style={{ margin: 0 }}>Open</h3>
                  <span className="text-sm muted">{openTodos.length}</span>
                </div>
                {openTodos.map((item) => (
                  <div key={item.id} className="planner-item-card">
                    <div className="row-between" style={{ gap: "0.8rem", alignItems: "flex-start" }}>
                      <div className="stack-sm" style={{ gap: "0.35rem" }}>
                        <strong>{item.title}</strong>
                        <div className="planner-chip-row">
                          <span className={`planner-chip planner-chip-priority-${item.priority || "medium"}`}>
                            {(item.priority || "medium").toUpperCase()}
                          </span>
                          <span className="planner-chip">{formatTodoDueLabel(item.dueAt)}</span>
                          <span className="planner-chip">{item.modelStatus || item.status}</span>
                        </div>
                      </div>
                      <button
                        type="button"
                        className="primary text-sm"
                        style={{ padding: "0.35rem 0.75rem", borderRadius: "999px" }}
                        onClick={() => onToggleTodo(item)}
                      >
                        Done
                      </button>
                    </div>
                    {item.details ? <div className="planner-item-body">{item.details}</div> : null}
                    {(item.sourcePath || item.sourceExcerpt) ? (
                      <div className="planner-item-meta text-sm muted">
                        {item.sourcePath ? <code>{item.sourcePath}</code> : null}
                        {item.sourceExcerpt ? <span>{item.sourceExcerpt}</span> : null}
                      </div>
                    ) : null}
                  </div>
                ))}
              </div>
            ) : null}

            {doneTodos.length > 0 ? (
              <div className="stack">
                <div className="planner-section-header">
                  <h3 style={{ margin: 0 }}>Completed</h3>
                  <span className="text-sm muted">{doneTodos.length}</span>
                </div>
                {doneTodos.map((item) => (
                  <div key={item.id} className="planner-item-card planner-item-card-done">
                    <div className="row-between" style={{ gap: "0.8rem", alignItems: "flex-start" }}>
                      <div className="stack-sm" style={{ gap: "0.35rem" }}>
                        <strong>{item.title}</strong>
                        <div className="planner-chip-row">
                          <span className="planner-chip">Completed</span>
                          <span className="planner-chip">Updated {formatTimestamp(item.updated)}</span>
                        </div>
                      </div>
                      <button
                        type="button"
                        className="ghost text-sm"
                        style={{ padding: "0.35rem 0.75rem", borderRadius: "999px" }}
                        onClick={() => onToggleTodo(item)}
                      >
                        Reopen
                      </button>
                    </div>
                    {item.details ? <div className="planner-item-body">{item.details}</div> : null}
                  </div>
                ))}
              </div>
            ) : null}
          </div>
        )}
      </div>
    </div>
  );
}

export type { WorkspaceSynthArtifactBadge };
