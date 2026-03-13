import type { WorkspaceEventItem } from "../lib/gatewayApi";
import type { WorkspaceSynthArtifactBadge } from "./TodosView";

type EventsViewProps = {
  workspaceEvents: WorkspaceEventItem[];
  todayEventItems: WorkspaceEventItem[];
  upcomingEventItems: WorkspaceEventItem[];
  pastEventItems: WorkspaceEventItem[];
  filteredEventItems: WorkspaceEventItem[];
  monthStripDays: Date[];
  monthStripLabel: string;
  selectedEventDay: string;
  selectedDayHeading: string;
  eventCountByDay: Record<string, number>;
  workspaceSynthArtifactBadges: WorkspaceSynthArtifactBadge[];
  formatDayKey: (date: Date) => string;
  formatEventTiming: (startAt: string, endAt?: string | null, allDay?: boolean) => string;
  onSelectEventDay: (dayKey: string) => void;
};

function EventCard({
  item,
  formatEventTiming,
  className = "planner-item-card"
}: {
  item: WorkspaceEventItem;
  formatEventTiming: EventsViewProps["formatEventTiming"];
  className?: string;
}) {
  return (
    <div className={className}>
      <div className="stack-sm" style={{ gap: "0.35rem" }}>
        <div className="row-between" style={{ gap: "0.8rem", alignItems: "flex-start" }}>
          <strong>{item.title}</strong>
          <span className="planner-chip">{item.status}</span>
        </div>
        <div className="planner-chip-row">
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

export function EventsView({
  workspaceEvents,
  todayEventItems,
  upcomingEventItems,
  pastEventItems,
  filteredEventItems,
  monthStripDays,
  monthStripLabel,
  selectedEventDay,
  selectedDayHeading,
  eventCountByDay,
  workspaceSynthArtifactBadges,
  formatDayKey,
  formatEventTiming,
  onSelectEventDay
}: EventsViewProps) {
  return (
    <div className="stack">
      <div className="card">
        <div className="stack-sm">
          <h2 style={{ margin: 0 }}>Events</h2>
          <p className="text-sm muted" style={{ margin: 0 }}>
            Calendar-style commitments extracted from the workspace. Upcoming sections are ordered
            chronologically so mobile and desktop show the same timeline.
          </p>
        </div>

        <div className="workspace-synth-card">
          <div className="planner-overview-row">
            <span className="status-pill">Today {todayEventItems.length}</span>
            <span className="status-pill">Upcoming {upcomingEventItems.length}</span>
            <span className="status-pill">Past {pastEventItems.length}</span>
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
          {workspaceEvents.length > 0 ? (
            <div className="events-calendar-strip">
              <div className="planner-section-header" style={{ marginTop: 0 }}>
                <strong>{monthStripLabel}</strong>
                <button
                  type="button"
                  className="ghost text-sm"
                  onClick={() => onSelectEventDay(formatDayKey(new Date()))}
                >
                  Today
                </button>
              </div>
              <div className="events-calendar-days" role="tablist" aria-label="Event day filter">
                {monthStripDays.map((day) => {
                  const dayKey = formatDayKey(day);
                  const isSelected = dayKey === selectedEventDay;
                  const hasEvents = (eventCountByDay[dayKey] || 0) > 0;
                  return (
                    <button
                      key={dayKey}
                      type="button"
                      role="tab"
                      aria-selected={isSelected}
                      className={`events-calendar-day${isSelected ? " selected" : ""}${hasEvents ? " has-events" : ""}`}
                      onClick={() => onSelectEventDay(dayKey)}
                    >
                      <span className="events-calendar-dow">
                        {day.toLocaleDateString([], { weekday: "short" })}
                      </span>
                      <span className="events-calendar-date">{day.getDate()}</span>
                      <span className="events-calendar-count">
                        {hasEvents ? eventCountByDay[dayKey] : ""}
                      </span>
                    </button>
                  );
                })}
              </div>
            </div>
          ) : null}
        </div>

        {workspaceEvents.length === 0 ? (
          <div className="planner-empty-state">
            <p className="text-center muted" style={{ margin: 0 }}>
              No events extracted from your workspace yet.
            </p>
          </div>
        ) : (
          <div className="stack">
            <div className="stack">
              <div className="planner-section-header">
                <h3 style={{ margin: 0 }}>Agenda</h3>
                <span className="text-sm muted">
                  {selectedDayHeading} · {filteredEventItems.length}
                </span>
              </div>
              {filteredEventItems.length === 0 ? (
                <div className="planner-empty-state">
                  <p className="text-center muted" style={{ margin: 0 }}>
                    No events on {selectedDayHeading}.
                  </p>
                </div>
              ) : (
                filteredEventItems.map((item) => (
                  <EventCard
                    key={`agenda-${item.id}`}
                    item={item}
                    formatEventTiming={formatEventTiming}
                  />
                ))
              )}
            </div>

            {todayEventItems.length > 0 ? (
              <div className="stack">
                <div className="planner-section-header">
                  <h3 style={{ margin: 0 }}>Today</h3>
                  <span className="text-sm muted">{todayEventItems.length}</span>
                </div>
                {todayEventItems.map((item) => (
                  <EventCard key={item.id} item={item} formatEventTiming={formatEventTiming} />
                ))}
              </div>
            ) : null}

            {upcomingEventItems.length > 0 ? (
              <div className="stack">
                <div className="planner-section-header">
                  <h3 style={{ margin: 0 }}>Upcoming</h3>
                  <span className="text-sm muted">{upcomingEventItems.length}</span>
                </div>
                {upcomingEventItems.map((item) => (
                  <EventCard key={item.id} item={item} formatEventTiming={formatEventTiming} />
                ))}
              </div>
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
                    className="planner-item-card planner-item-card-past"
                  />
                ))}
              </div>
            ) : null}
          </div>
        )}
      </div>
    </div>
  );
}
