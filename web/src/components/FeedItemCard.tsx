/**
 * FeedItemCard.tsx — Individual feed item card component.
 *
 * Extracted from the massive inline feed rendering in App.tsx.
 * Encapsulates:
 * - Draft inline editor
 * - Post-to-Bluesky action
 * - Comment composer
 * - Delete action
 * - Workflow bot attribution
 *
 * This follows Atomic Chat's pattern of small, focused card components
 * rather than giant inline render blocks.
 */

import { useState, type FormEvent } from "react";
import type { LibraryItem } from "../lib/types";

type WorkflowBotDisplay = {
  key: string;
  name: string;
  avatar: string;
};

type FeedItemCardProps = {
  item: LibraryItem;
  workflowBot: WorkflowBotDisplay | null;
  inlineText: string;
  isDraftLoading: boolean;
  isPosted: boolean;
  isPosting: boolean;
  postProgress: { percent: number; label: string } | null;
  onDraftChange: (value: string) => void;
  onPost: () => void;
  onDelete: () => void;
  onOpenBotSettings: (bot: WorkflowBotDisplay) => void;
  onComment: (comment: string) => void;
  commentStatus: string;
  isCommentSubmitting: boolean;
  formatTimestamp: (value?: number | string) => string;
};

export function FeedItemCard({
  item,
  workflowBot,
  inlineText,
  isDraftLoading,
  isPosted,
  isPosting,
  postProgress,
  onDraftChange,
  onPost,
  onDelete,
  onOpenBotSettings,
  onComment,
  commentStatus,
  isCommentSubmitting,
  formatTimestamp,
}: FeedItemCardProps) {
  const [commentOpen, setCommentOpen] = useState(false);
  const [commentDraft, setCommentDraft] = useState("");
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const canEditInline = item.kind === "text" || item.kind === "audio" || item.kind === "video";

  function handleCommentSubmit(e: FormEvent) {
    e.preventDefault();
    if (!commentDraft.trim()) return;
    onComment(commentDraft);
    setCommentDraft("");
  }

  function autoResize(node: HTMLTextAreaElement | null) {
    if (!node) return;
    node.style.height = "0px";
    node.style.height = `${node.scrollHeight}px`;
  }

  return (
    <div className="feed-item feed-item-card view-enter">
      <div className="feed-header">
        <div className="feed-title stack-sm">
          {workflowBot && (
            <button
              type="button"
              className="feed-bot-chip"
              onClick={() => onOpenBotSettings(workflowBot)}
              title={`Open ${workflowBot.name} settings`}
            >
              <span className="feed-bot-avatar">{workflowBot.avatar}</span>
              <span>{workflowBot.name}</span>
            </button>
          )}
          <span>{item.title}</span>
        </div>
        <div className="feed-time">{formatTimestamp(item.modifiedAt)}</div>
      </div>

      {canEditInline ? (
        <textarea
          rows={1}
          className="feed-inline-editor"
          value={inlineText}
          ref={(node) => autoResize(node)}
          onChange={(e) => {
            autoResize(e.target);
            onDraftChange(e.target.value);
          }}
          placeholder={isDraftLoading ? "Loading post..." : "Write your post"}
          disabled={isDraftLoading}
        />
      ) : (
        <div className="feed-body">
          {item.previewText || <span className="muted">[{item.kind.toUpperCase()} File attached]</span>}
        </div>
      )}

      <div className="feed-actions">
        {(item.kind === "text" || item.kind === "video") && (
          <button
            type="button"
            className="primary text-sm"
            style={{ padding: "0.4rem 0.8rem", borderRadius: "8px" }}
            onClick={onPost}
            disabled={isPosting || isPosted}
          >
            {isPosted ? "Posted" : isPosting ? "Posting..." : "Like & Post"}
          </button>
        )}
        {workflowBot && (
          <button
            type="button"
            className="ghost text-sm"
            style={{ padding: "0.4rem 0.8rem", borderRadius: "8px" }}
            onClick={() => setCommentOpen(!commentOpen)}
          >
            {commentOpen ? "Hide Comment" : "Comment"}
          </button>
        )}
        <button
          type="button"
          className="ghost text-sm"
          style={{ padding: "0.4rem 0.8rem", borderRadius: "8px", color: "var(--error)" }}
          onClick={onDelete}
        >
          Delete
        </button>
      </div>

      {commentOpen && (
        <form className="feed-comment-panel open" onSubmit={handleCommentSubmit}>
          <textarea
            rows={3}
            className="feed-comment-input"
            placeholder={`Comment to modify ${workflowBot?.name || "workflow"}...`}
            value={commentDraft}
            onChange={(e) => setCommentDraft(e.target.value)}
          />
          <div className="feed-comment-actions">
            <button
              type="submit"
              className="primary text-sm"
              style={{ padding: "0.35rem 0.75rem", borderRadius: "8px" }}
              disabled={isCommentSubmitting || !commentDraft.trim()}
            >
              {isCommentSubmitting ? "Sending..." : "Send Comment"}
            </button>
            <button
              type="button"
              className="ghost text-sm"
              style={{ padding: "0.35rem 0.75rem", borderRadius: "8px" }}
              onClick={() => setCommentOpen(false)}
              disabled={isCommentSubmitting}
            >
              Cancel
            </button>
          </div>
          {commentStatus && <div className="feed-comment-status">{commentStatus}</div>}
        </form>
      )}

      {postProgress && (
        <div className="post-progress-wrap">
          <div className="post-progress-text">{postProgress.label}</div>
          <div className="post-progress-track">
            <div
              className="post-progress-fill"
              style={{ width: `${Math.max(0, Math.min(100, postProgress.percent))}%` }}
            />
          </div>
        </div>
      )}
    </div>
  );
}
