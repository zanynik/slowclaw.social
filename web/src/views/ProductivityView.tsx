import { useState } from "react";
import type {
  WorkspaceEventItem,
  WorkspaceSynthesizerStatus,
  WorkspaceTodoItem
} from "../lib/gatewayApi";

type WorkspaceSynthArtifactBadge = {
  key: string;
  label: string;
  toneClassName: string;
  title: string;
};

type ProductivityViewProps = {
  openTodos: WorkspaceTodoItem[];
  doneTodos: WorkspaceTodoItem[];
  overdueTodoCount: number;
  todayEventItems: WorkspaceEventItem[];
  upcomingEventItems: WorkspaceEventItem[];
  pastEventItems: WorkspaceEventItem[];
  workspaceSynthStatus: WorkspaceSynthesizerStatus;
  workspaceSynthArtifactBadges: WorkspaceSynthArtifactBadge[];
  formatTodoDueLabel: (value?: string | null) => string;
  formatEventTiming: (startAt: string, endAt?: string | null, allDay?: boolean) => string;
  formatTimestamp: (value?: number | string) => string;
  onToggleTodo: (item: WorkspaceTodoItem) => void;
};

type ProductivityFilter = "all" | "todos" | "events" | "done";

type TimelineEntry =
  | {
      id: string;
      kind: "todo";
      sortTime: number;
      priorityRank: number;
      sectionKey: string;
      sectionLabel: string;
      sectionOrder: number;
      item: WorkspaceTodoItem;
    }
  | {
      id: string;
      kind: "event";
      sortTime: number;
      priorityRank: number;
      sectionKey: string;
      sectionLabel: string;
      sectionOrder: number;
      item: WorkspaceEventItem;
    };

type TimelineSection = {
  key: string;
  label: string;
  order: number;
  items: TimelineEntry[];
};

function parseDateValue(value?: string | null) {
  if (!value) {
    return null;
  }
  const normalized = String(value).trim();
  const localDateOnly = normalized.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (localDateOnly) {
    const [, year, month, day] = localDateOnly;
    return new Date(Number(year), Number(month) - 1, Number(day));
  }
  const parsed = new Date(normalized);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function startOfLocalDay(date: Date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function isSameLocalDay(a: Date, b: Date) {
  return (
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
  );
}

function formatDayKey(date: Date) {
  const year = date.getFullYear();
  const month = `${date.getMonth() + 1}`.padStart(2, "0");
  const day = `${date.getDate()}`.padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function todoPriorityRank(priority: string) {
  if (priority === "high") {
    return 0;
  }
  if (priority === "medium") {
    return 1;
  }
  return 2;
}

function hasExplicitTime(value?: string | null) {
  return Boolean(value && /[T\s]\d{2}:\d{2}/.test(String(value)));
}

function sectionLabelForDay(day: Date, now: Date) {
  const today = startOfLocalDay(now);
  const tomorrow = new Date(today);
  tomorrow.setDate(today.getDate() + 1);
  if (isSameLocalDay(day, today)) {
    return "Today";
  }
  if (isSameLocalDay(day, tomorrow)) {
    return "Tomorrow";
  }
  return day.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" });
}

function buildTimelineSections(entries: TimelineEntry[]) {
  const groups = new Map<string, TimelineSection>();
  for (const entry of entries) {
    const existing = groups.get(entry.sectionKey);
    if (existing) {
      existing.items.push(entry);
      continue;
    }
    groups.set(entry.sectionKey, {
      key: entry.sectionKey,
      label: entry.sectionLabel,
      order: entry.sectionOrder,
      items: [entry]
    });
  }

  return Array.from(groups.values())
    .sort((a, b) => a.order - b.order)
    .map((section) => ({
      ...section,
      items: section.items.slice().sort((a, b) => {
        if (a.sortTime !== b.sortTime) {
          return a.sortTime - b.sortTime;
        }
        if (a.priorityRank !== b.priorityRank) {
          return a.priorityRank - b.priorityRank;
        }
        if (a.kind !== b.kind) {
          return a.kind === "event" ? -1 : 1;
        }
        return a.id.localeCompare(b.id);
      })
    }));
}

function buildActiveTimelineSections(
  openTodos: WorkspaceTodoItem[],
  activeEvents: WorkspaceEventItem[]
) {
  const now = new Date();
  const today = startOfLocalDay(now);
  const entries: TimelineEntry[] = [];

  for (const item of openTodos) {
    const due = parseDateValue(item.dueAt);
    if (!due) {
      entries.push({
        id: item.id,
        kind: "todo",
        sortTime: Number.MAX_SAFE_INTEGER - todoPriorityRank(item.priority),
        priorityRank: todoPriorityRank(item.priority),
        sectionKey: "todo-undated",
        sectionLabel: "No due date",
        sectionOrder: Number.MAX_SAFE_INTEGER,
        item
      });
      continue;
    }

    const isOverdue = hasExplicitTime(item.dueAt)
      ? due.getTime() < now.getTime()
      : startOfLocalDay(due).getTime() < today.getTime();
    if (isOverdue) {
      entries.push({
        id: item.id,
        kind: "todo",
        sortTime: due.getTime(),
        priorityRank: todoPriorityRank(item.priority),
        sectionKey: "todo-overdue",
        sectionLabel: "Overdue",
        sectionOrder: -1,
        item
      });
      continue;
    }

    const day = startOfLocalDay(due);
    entries.push({
      id: item.id,
      kind: "todo",
      sortTime: due.getTime(),
      priorityRank: todoPriorityRank(item.priority),
      sectionKey: `day-${formatDayKey(day)}`,
      sectionLabel: sectionLabelForDay(day, now),
      sectionOrder: day.getTime(),
      item
    });
  }

  for (const item of activeEvents) {
    const start = parseDateValue(item.startAt);
    if (!start) {
      continue;
    }
    const day = startOfLocalDay(start);
    entries.push({
      id: item.id,
      kind: "event",
      sortTime: start.getTime(),
      priorityRank: 1,
      sectionKey: `day-${formatDayKey(day)}`,
      sectionLabel: sectionLabelForDay(day, now),
      sectionOrder: day.getTime(),
      item
    });
  }

  return buildTimelineSections(entries);
}

function TodoCard({
  item,
  formatTodoDueLabel,
  formatTimestamp,
  onToggle,
  completed = false
}: {
  item: WorkspaceTodoItem;
  formatTodoDueLabel: ProductivityViewProps["formatTodoDueLabel"];
  formatTimestamp: ProductivityViewProps["formatTimestamp"];
  onToggle: ProductivityViewProps["onToggleTodo"];
  completed?: boolean;
}) {
  return (
    <div className={`planner-item-card${completed ? " planner-item-card-done" : ""}`}>
      <div className="row-between" style={{ gap: "0.8rem", alignItems: "flex-start" }}>
        <div className="stack-sm" style={{ gap: "0.35rem" }}>
          <strong>{item.title}</strong>
          <div className="planner-chip-row">
            <span className="planner-chip planner-chip-kind">Todo</span>
            {completed ? (
              <span className="planner-chip">Completed</span>
            ) : (
              <>
                <span className={`planner-chip planner-chip-priority-${item.priority || "medium"}`}>
                  {(item.priority || "medium").toUpperCase()}
                </span>
                <span className="planner-chip">{formatTodoDueLabel(item.dueAt)}</span>
                <span className="planner-chip">{item.modelStatus || item.status}</span>
              </>
            )}
            {completed ? (
              <span className="planner-chip">Updated {formatTimestamp(item.updated)}</span>
            ) : null}
          </div>
        </div>
        <button
          type="button"
          className={completed ? "ghost text-sm" : "primary text-sm"}
          style={{ padding: "0.35rem 0.75rem", borderRadius: "999px" }}
          onClick={() => onToggle(item)}
        >
          {completed ? "Reopen" : "Done"}
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
  );
}

function EventCard({
  item,
  formatEventTiming,
  past = false
}: {
  item: WorkspaceEventItem;
  formatEventTiming: ProductivityViewProps["formatEventTiming"];
  past?: boolean;
}) {
  return (
    <div className={`planner-item-card${past ? " planner-item-card-past" : ""}`}>
      <div className="stack-sm" style={{ gap: "0.35rem" }}>
        <div className="row-between" style={{ gap: "0.8rem", alignItems: "flex-start" }}>
          <strong>{item.title}</strong>
          <span className="planner-chip">{item.status}</span>
        </div>
        <div className="planner-chip-row">
          <span className="planner-chip planner-chip-kind">Event</span>
          <span className="planner-chip">
            {formatEventTiming(item.startAt, item.endAt, item.allDay)}
          </span>
          {item.location ? <span className="planner-chip">{item.location}</span> : null}
        </div>
      </div>
      {item.details ? <div className="planner-item-body">{item.details}</div> : null}
      {(item.sourcePath || item.sourceExcerpt) ? (
        <div className="planner-item-meta text-sm muted">
          {item.sourcePath ? <code>{item.sourcePath}</code> : null}
          {item.sourceExcerpt ? <span>{item.sourceExcerpt}</span> : null}
        </div>
      ) : null}
    </div>
  );
}

function TimelineSectionList({
  sections,
  formatTodoDueLabel,
  formatEventTiming,
  formatTimestamp,
  onToggleTodo
}: {
  sections: TimelineSection[];
  formatTodoDueLabel: ProductivityViewProps["formatTodoDueLabel"];
  formatEventTiming: ProductivityViewProps["formatEventTiming"];
  formatTimestamp: ProductivityViewProps["formatTimestamp"];
  onToggleTodo: ProductivityViewProps["onToggleTodo"];
}) {
  return (
    <div className="stack">
      {sections.map((section) => (
        <div key={section.key} className="stack">
          <div className="planner-section-header">
            <h3 style={{ margin: 0 }}>{section.label}</h3>
            <span className="text-sm muted">{section.items.length}</span>
          </div>
          {section.items.map((entry) =>
            entry.kind === "todo" ? (
              <TodoCard
                key={entry.id}
                item={entry.item}
                formatTodoDueLabel={formatTodoDueLabel}
                formatTimestamp={formatTimestamp}
                onToggle={onToggleTodo}
              />
            ) : (
              <EventCard
                key={entry.id}
                item={entry.item}
                formatEventTiming={formatEventTiming}
              />
            )
          )}
        </div>
      ))}
    </div>
  );
}

export function ProductivityView({
  openTodos,
  doneTodos,
  overdueTodoCount,
  todayEventItems,
  upcomingEventItems,
  pastEventItems,
  workspaceSynthStatus,
  workspaceSynthArtifactBadges,
  formatTodoDueLabel,
  formatEventTiming,
  formatTimestamp,
  onToggleTodo
}: ProductivityViewProps) {
  const [filter, setFilter] = useState<ProductivityFilter>("all");
  const activeEvents = [...todayEventItems, ...upcomingEventItems];
  const allSections = buildActiveTimelineSections(openTodos, activeEvents);
  const todoSections = buildActiveTimelineSections(openTodos, []);
  const eventSections = buildTimelineSections([
    ...todayEventItems.map((item) => {
      const start = parseDateValue(item.startAt);
      const day = start ? startOfLocalDay(start) : new Date();
      return {
        id: item.id,
        kind: "event" as const,
        sortTime: start?.getTime() || 0,
        priorityRank: 1,
        sectionKey: `day-${formatDayKey(day)}`,
        sectionLabel: sectionLabelForDay(day, new Date()),
        sectionOrder: day.getTime(),
        item
      };
    }),
    ...upcomingEventItems.map((item) => {
      const start = parseDateValue(item.startAt);
      const day = start ? startOfLocalDay(start) : new Date();
      return {
        id: item.id,
        kind: "event" as const,
        sortTime: start?.getTime() || 0,
        priorityRank: 1,
        sectionKey: `day-${formatDayKey(day)}`,
        sectionLabel: sectionLabelForDay(day, new Date()),
        sectionOrder: day.getTime(),
        item
      };
    })
  ]);
  const hasActiveItems = openTodos.length > 0 || activeEvents.length > 0;
  const hasDoneItems = doneTodos.length > 0 || pastEventItems.length > 0;
  const upcomingCount = activeEvents.length;

  return (
    <div className="stack">
      <div className="card">
        <div className="stack-sm">
          <h2 style={{ margin: 0 }}>Productivity</h2>
          <p className="text-sm muted" style={{ margin: 0 }}>
            Todos and calendar commitments extracted from the workspace, ranked by what needs
            attention next.
          </p>
        </div>

        <div className="workspace-synth-card">
          <div className="planner-overview-row">
            <span className="status-pill">Open {openTodos.length}</span>
            <span className="status-pill">Upcoming {upcomingCount}</span>
            <span className="status-pill">Overdue {overdueTodoCount}</span>
            <span className="status-pill">Done {doneTodos.length}</span>
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

        <div className="segmented-control productivity-filter-strip" role="tablist" aria-label="Productivity filters">
          <button
            type="button"
            className={filter === "all" ? "active" : ""}
            onClick={() => setFilter("all")}
          >
            All
          </button>
          <button
            type="button"
            className={filter === "todos" ? "active" : ""}
            onClick={() => setFilter("todos")}
          >
            Todos
          </button>
          <button
            type="button"
            className={filter === "events" ? "active" : ""}
            onClick={() => setFilter("events")}
          >
            Events
          </button>
          <button
            type="button"
            className={filter === "done" ? "active" : ""}
            onClick={() => setFilter("done")}
          >
            Done
          </button>
        </div>

        {filter === "all" ? (
          hasActiveItems ? (
            <TimelineSectionList
              sections={allSections}
              formatTodoDueLabel={formatTodoDueLabel}
              formatEventTiming={formatEventTiming}
              formatTimestamp={formatTimestamp}
              onToggleTodo={onToggleTodo}
            />
          ) : (
            <div className="planner-empty-state">
              <p className="text-center muted" style={{ margin: 0 }}>
                {hasDoneItems
                  ? "Nothing pressing right now. Switch to Done to review completed tasks and past events."
                  : "No todos or events extracted from your workspace yet."}
              </p>
            </div>
          )
        ) : null}

        {filter === "todos" ? (
          openTodos.length > 0 ? (
            <TimelineSectionList
              sections={todoSections}
              formatTodoDueLabel={formatTodoDueLabel}
              formatEventTiming={formatEventTiming}
              formatTimestamp={formatTimestamp}
              onToggleTodo={onToggleTodo}
            />
          ) : (
            <div className="planner-empty-state">
              <p className="text-center muted" style={{ margin: 0 }}>
                No open todos extracted from your workspace yet.
              </p>
            </div>
          )
        ) : null}

        {filter === "events" ? (
          eventSections.length > 0 || pastEventItems.length > 0 ? (
            <div className="stack">
              {eventSections.length > 0 ? (
                <TimelineSectionList
                  sections={eventSections}
                  formatTodoDueLabel={formatTodoDueLabel}
                  formatEventTiming={formatEventTiming}
                  formatTimestamp={formatTimestamp}
                  onToggleTodo={onToggleTodo}
                />
              ) : null}
              {pastEventItems.length > 0 ? (
                <div className="stack">
                  <div className="planner-section-header">
                    <h3 style={{ margin: 0 }}>Recent Past</h3>
                    <span className="text-sm muted">{pastEventItems.length}</span>
                  </div>
                  {pastEventItems.map((item) => (
                    <EventCard
                      key={item.id}
                      item={item}
                      formatEventTiming={formatEventTiming}
                      past
                    />
                  ))}
                </div>
              ) : null}
            </div>
          ) : (
            <div className="planner-empty-state">
              <p className="text-center muted" style={{ margin: 0 }}>
                No events extracted from your workspace yet.
              </p>
            </div>
          )
        ) : null}

        {filter === "done" ? (
          hasDoneItems ? (
            <div className="stack">
              {doneTodos.length > 0 ? (
                <div className="stack">
                  <div className="planner-section-header">
                    <h3 style={{ margin: 0 }}>Completed Todos</h3>
                    <span className="text-sm muted">{doneTodos.length}</span>
                  </div>
                  {doneTodos.map((item) => (
                    <TodoCard
                      key={item.id}
                      item={item}
                      formatTodoDueLabel={formatTodoDueLabel}
                      formatTimestamp={formatTimestamp}
                      onToggle={onToggleTodo}
                      completed
                    />
                  ))}
                </div>
              ) : null}
              {pastEventItems.length > 0 ? (
                <div className="stack">
                  <div className="planner-section-header">
                    <h3 style={{ margin: 0 }}>Past Events</h3>
                    <span className="text-sm muted">{pastEventItems.length}</span>
                  </div>
                  {pastEventItems.map((item) => (
                    <EventCard
                      key={item.id}
                      item={item}
                      formatEventTiming={formatEventTiming}
                      past
                    />
                  ))}
                </div>
              ) : null}
            </div>
          ) : (
            <div className="planner-empty-state">
              <p className="text-center muted" style={{ margin: 0 }}>
                No completed todos or past events yet.
              </p>
            </div>
          )
        ) : null}
      </div>
    </div>
  );
}
