export type BlueskyCredentials = {
  serviceUrl: string;
  handle: string;
  appPassword: string;
};

export type StoredDraft = {
  id?: string;
  text: string;
  videoName?: string;
  created: string;
  updated?: string;
};

export type PostHistoryItem = {
  id?: string;
  provider: "bluesky";
  text: string;
  videoName?: string;
  sourcePath?: string;
  uri?: string;
  cid?: string;
  created: string;
  status: "success" | "error";
  error?: string;
};

export type ApiRequestState = {
  method: "GET" | "POST";
  url: string;
  headersJson: string;
  bodyJson: string;
  includeBlueskyAuth: boolean;
};

export type ClawChatMessage = {
  id: string;
  threadId: string;
  role: "user" | "assistant" | "system";
  content: string;
  status: "pending" | "processing" | "done" | "error" | string;
  error?: string;
  source?: string;
  created: string;
  updated?: string;
  replyToId?: string;
};

export type LibraryItem = {
  id: string;
  path: string;
  title: string;
  kind: "text" | "audio" | "video" | "image" | string;
  sizeBytes: number;
  modifiedAt: number;
  previewText?: string;
  mediaUrl?: string | null;
  editableText?: boolean;
  scope?: "journal" | "feed" | string;
};
