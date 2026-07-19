/**
 * Reads bridge transform — behavioral contract test.
 *
 * This verifies the bridge that carries backend world-feed items into the Reads
 * stream: a PersonalizedFeedItem with Nostr-article fields (title, summary,
 * image, habla.news URL) must pass through toUnifiedFromWorldFeed and land in
 * the ranked output. This is the "cached content reaches Reads" contract.
 *
 * There is currently no vitest/jest runner wired in this repo (see package.json).
 * To run manually once a runner is added:
 *   npm install -D vitest && npx vitest run src/lib/__reads_bridge.test.ts
 *
 * The backend side of this contract (candidate → PersonalizedFeedItem field
 * mapping) is covered by the Rust test `nostr_article_candidate_carries_nip23_
 * fields_to_personalized_item` in src/feed/mod.rs.
 */
import { describe, it, expect } from "vitest";
import {
  toUnifiedFromWorldFeed,
  extractYouTubeId,
  youTubeThumbnailUrl,
} from "./socialFeed";
import { rankReads } from "./readsRanking";
import type { PersonalizedFeedItem } from "./gatewayApi";

describe("Reads bridge: backend world-feed items reach the ranked stream", () => {
  it("converts a Nostr article PersonalizedFeedItem to a unified item", () => {
    const article: PersonalizedFeedItem = {
      sourceType: "web",
      feedItem: {
        url: "https://habla.news/a/naddr1test",
        title: "On Local-First Computing",
        description: "Why your data should live on your device",
        domain: "relay.example.com",
      },
      webPreview: {
        url: "https://habla.news/a/naddr1test",
        title: "On Local-First Computing",
        description: "Why your data should live on your device",
        contentText: "",
        imageUrl: "https://example.com/cover.png",
        domain: "relay.example.com",
        provider: "Nostr",
        discoveredAt: "2026-01-15T10:00:00Z",
      },
      feedSource: { label: "Nostr relay" },
      passedThreshold: true,
    };

    const unified = toUnifiedFromWorldFeed(article);
    expect(unified.sourcePlatform).toBe("rss");
    expect(unified.content.title).toBe("On Local-First Computing");
    expect(unified.content.body).toContain("Why your data should live on your device");
    expect(unified.content.linkUrl).toBe("https://habla.news/a/naddr1test");
    expect(unified.media.type).toBe("image");
    expect(unified.media.thumbnailUrl).toBe("https://example.com/cover.png");
  });

  it("lands backend items in the ranked Reads output", () => {
    const article: PersonalizedFeedItem = {
      sourceType: "web",
      feedItem: { url: "https://example.com/post", title: "Rust ownership", domain: "example.com" },
      webPreview: {
        url: "https://example.com/post",
        title: "Rust ownership",
        description: "Borrowing and lifetimes",
        contentText: "",
        domain: "example.com",
        provider: "RSS/Atom",
        discoveredAt: new Date().toISOString(),
      },
      passedThreshold: true,
    };

    const unified = toUnifiedFromWorldFeed(article);
    const ranked = rankReads([unified], [{ label: "rust", weight: 1 }], []);
    expect(ranked).toHaveLength(1);
    expect(ranked[0].item.content.title).toBe("Rust ownership");
  });
});

describe("YouTube thumbnails on Reads cards", () => {
  // Regression: YouTube items arrived via the world feed with no thumbnail
  // because the app relied entirely on the backend's webPreview.imageUrl.
  // When that was empty the card had no cover AND was mistagged "rss" so the
  // "▶ Video" badge never showed. The fix builds the thumbnail from the video
  // id client-side and tags the item "youtube".
  it("builds a thumbnail from the video id when the backend sent no image", () => {
    const video: PersonalizedFeedItem = {
      sourceType: "web",
      feedItem: { url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", title: "A Talk", domain: "youtube.com" },
      webPreview: {
        url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        title: "A Talk",
        description: "",
        contentText: "",
        imageUrl: "", // backend sent no image — the bug condition
        domain: "youtube.com",
        provider: "YouTube",
        discoveredAt: "2026-01-15T10:00:00Z",
      },
      passedThreshold: true,
    };

    const unified = toUnifiedFromWorldFeed(video);
    expect(unified.sourcePlatform).toBe("youtube");
    expect(unified.media.type).toBe("video");
    expect(unified.media.thumbnailUrl).toBe(
      "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
    );
  });

  it("prefers the backend-supplied image when present (higher-res maxres)", () => {
    const video: PersonalizedFeedItem = {
      sourceType: "web",
      feedItem: { url: "https://youtu.be/dQw4w9WgXcQ" },
      webPreview: {
        url: "https://youtu.be/dQw4w9WgXcQ",
        title: "A Talk",
        imageUrl: "https://example.com/maxres.jpg",
        discoveredAt: "2026-01-15T10:00:00Z",
      },
      passedThreshold: true,
    };

    const unified = toUnifiedFromWorldFeed(video);
    expect(unified.sourcePlatform).toBe("youtube");
    expect(unified.media.thumbnailUrl).toBe("https://example.com/maxres.jpg");
  });

  it("extracts ids from the common YouTube URL shapes", () => {
    expect(extractYouTubeId("https://www.youtube.com/watch?v=dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ");
    expect(extractYouTubeId("https://youtu.be/dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ");
    expect(extractYouTubeId("https://www.youtube.com/embed/dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ");
    expect(extractYouTubeId("https://www.youtube.com/shorts/dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ");
    expect(extractYouTubeId("https://www.youtube.com/live/dQw4w9WgXcQ")).toBe("dQw4w9WgXcQ");
    // Non-YouTube / malformed → null (no false positives that would mistag items).
    expect(extractYouTubeId("https://example.com/watch?v=dQw4w9WgXcQ")).toBeNull();
    expect(extractYouTubeId("https://www.youtube.com/")).toBeNull();
    expect(extractYouTubeId("not a url")).toBeNull();
    expect(extractYouTubeId("")).toBeNull();
  });

  it("does not mistag non-YouTube items as youtube", () => {
    const article: PersonalizedFeedItem = {
      sourceType: "web",
      feedItem: { url: "https://example.com/article", title: "Plain article" },
      webPreview: { url: "https://example.com/article", title: "Plain article", discoveredAt: "2026-01-15T10:00:00Z" },
      passedThreshold: true,
    };
    expect(toUnifiedFromWorldFeed(article).sourcePlatform).toBe("rss");
  });

  it("youTubeThumbnailUrl produces the canonical hqdefault URL", () => {
    expect(youTubeThumbnailUrl("dQw4w9WgXcQ")).toBe(
      "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
    );
  });
});
