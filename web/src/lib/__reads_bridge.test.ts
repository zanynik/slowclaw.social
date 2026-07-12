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
import { toUnifiedFromWorldFeed } from "./socialFeed";
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
