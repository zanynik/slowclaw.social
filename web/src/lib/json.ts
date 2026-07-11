/**
 * json.ts — defensive JSON parsing for on-device model output.
 *
 * Local GGUF models (especially smaller ones on iPhone) frequently wrap JSON in
 * markdown fences, prepend prose, or emit one object per line. This recovers a
 * typed array from those common malformations. Extracted from App.tsx so the
 * background AI re-rank and the existing TweetClaw / interest-extraction paths
 * share one well-tested recovery path (rule-of-three extraction).
 */

/**
 * Best-effort parse of a model response into a typed array. Tries, in order:
 *   1. strip markdown fences → direct JSON.parse
 *   2. extract the first `[{ ... }]` block and parse it
 *   3. parse line-by-line `{ ... }` objects and collect the ones that parse
 * Returns null if nothing usable was found. Never throws.
 */
export function tryParseJsonArray<T>(raw: string): T[] | null {
  // Strip markdown fences
  let cleaned = raw.replace(/^```(?:json)?\s*\n?/i, "").replace(/\n?```\s*$/m, "").trim();
  // Try direct parse
  try { const r = JSON.parse(cleaned); if (Array.isArray(r)) return r; } catch {}
  // Try extracting first [...] block
  const bracketMatch = cleaned.match(/\[\s*\{[\s\S]*\}\s*\]/);
  if (bracketMatch) {
    try { const r = JSON.parse(bracketMatch[0]); if (Array.isArray(r)) return r; } catch {}
  }
  // Try line-by-line JSON objects  {"title":...}
  const objLines = cleaned.split('\n').filter((l) => l.trim().startsWith('{'));
  if (objLines.length > 0) {
    const arr: T[] = [];
    for (const line of objLines) {
      try { arr.push(JSON.parse(line.replace(/,\s*$/, ''))); } catch {}
    }
    if (arr.length > 0) return arr;
  }
  return null;
}
