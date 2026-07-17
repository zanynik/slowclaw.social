use crate::memory::{self, vector::cosine_similarity};
use crate::util::truncate_with_ellipsis;
use anyhow::Result;
use chrono::Utc;
use rust_stemmers::{Algorithm as StemAlgorithm, Stemmer};
use std::cmp::Ordering;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::sync::{Arc, OnceLock};

use super::types::{FeedCandidate, FeedProfile, InterestVector, PersonalizedFeedItem};

const FEED_PROFILE_MAX_CHARS: usize = 2_400;
const FEED_EMBED_BATCH_SIZE: usize = 16;
const FEED_MATCH_THRESHOLD: f32 = 0.62;
const STAGE1_SOURCE_WEIGHT: f32 = 0.28;
const STAGE2_ITEM_WEIGHT: f32 = 0.72;
const STAGE1_KEYWORD_LIMIT: usize = 15;
const KEYWORD_PROFILE_FRESHNESS_BONUS_MAX: f32 = 0.18;
const KEYWORD_PROFILE_SOURCE_BONUS: f32 = 0.15;
// Negative-lens penalty (mirrors the TS `journalTopicPenalty` in
// readsRanking.ts): down-rank disliked-topic matches, never hide. A single
// dislike can't outweigh a strong positive match.
const NEG_MATCH_TOP: f32 = 0.7;
const NEG_MATCH_EACH: f32 = 0.25;
const NEG_MATCH_CAP: f32 = 0.9;

#[derive(Debug, Clone)]
pub struct RankedCandidate {
    pub dedupe_key: String,
    pub item: PersonalizedFeedItem,
    pub original_index: usize,
    pub score: f32,
}

pub type SharedEmbedder = Arc<dyn memory::embeddings::EmbeddingProvider>;

pub struct FeedRanker;

impl FeedRanker {
    pub async fn rank_candidates(
        embedder: SharedEmbedder,
        profile: &FeedProfile,
        candidates: Vec<FeedCandidate>,
        limit: usize,
    ) -> Result<Vec<PersonalizedFeedItem>> {
        if profile.interests.is_empty() || candidates.is_empty() {
            return Ok(Vec::new());
        }

        let lexical_terms = top_interest_terms(profile);
        let mut candidates_to_embed = Vec::new();
        let mut texts = Vec::new();

        for candidate in candidates {
            let trimmed = candidate.rank_text.trim();
            if trimmed.is_empty() {
                continue;
            }
            if !passes_lexical_gate(trimmed, &lexical_terms, candidate.stage1_score) {
                continue;
            }
            texts.push(truncate_with_ellipsis(trimmed, FEED_PROFILE_MAX_CHARS));
            candidates_to_embed.push(candidate);
        }

        if candidates_to_embed.is_empty() {
            return Ok(Vec::new());
        }

        let embeddings = embed_text_batch(embedder, &texts).await?;
        let negatives = &profile.negative_interests;
        let mut ranked = Vec::new();
        let mut has_strong_match = false;
        for (candidate, embedding) in candidates_to_embed.into_iter().zip(embeddings) {
            let (weighted_score, similarity, matched_label) =
                best_interest_match(&embedding, &profile.interests);
            let penalty = negative_keyword_penalty(&candidate.rank_text, negatives);
            let final_score = STAGE1_SOURCE_WEIGHT * candidate.stage1_score
                + STAGE2_ITEM_WEIGHT * weighted_score
                - penalty;
            let mut item = candidate.item;
            item.score = Some(final_score);
            item.matched_interest_label = matched_label;
            item.matched_interest_score = if similarity > 0.0 {
                Some(similarity)
            } else {
                None
            };
            item.passed_threshold = final_score >= FEED_MATCH_THRESHOLD;
            has_strong_match |= item.passed_threshold;

            ranked.push(RankedCandidate {
                dedupe_key: candidate.dedupe_key,
                item,
                original_index: candidate.original_index,
                score: final_score,
            });
        }

        let mut deduped: HashMap<String, RankedCandidate> = HashMap::new();
        for candidate in ranked {
            if let Some(existing) = deduped.get(&candidate.dedupe_key) {
                if rank_candidate_cmp(&candidate, existing) != Ordering::Less {
                    continue;
                }
            }
            deduped.insert(candidate.dedupe_key.clone(), candidate);
        }

        let mut ranked_items: Vec<RankedCandidate> = deduped.into_values().collect();
        ranked_items.sort_by(rank_candidate_cmp);
        if has_strong_match {
            ranked_items.retain(|candidate| candidate.item.passed_threshold);
        }
        ranked_items = interleave_ranked_candidates_by_source(ranked_items, limit);
        Ok(ranked_items
            .into_iter()
            .map(|candidate| candidate.item)
            .collect())
    }
}

pub fn rank_candidates_stage2(
    profile: &FeedProfile,
    candidates: Vec<FeedCandidate>,
    limit: usize,
) -> Vec<PersonalizedFeedItem> {
    let keyword_weights = weighted_interest_keywords(profile);
    let negatives = &profile.negative_interests;
    let mut ranked = Vec::new();
    for candidate in candidates {
        let (keyword_score, matched_keyword) =
            keyword_weight_sum(&candidate.rank_text, &keyword_weights);
        let freshness_bonus = candidate_freshness_bonus(&candidate.item);
        let penalty = negative_keyword_penalty(&candidate.rank_text, negatives);
        let final_score = keyword_score
            + freshness_bonus
            + (candidate.stage1_score * KEYWORD_PROFILE_SOURCE_BONUS)
            - penalty;
        let mut item = candidate.item;
        item.score = Some(final_score);
        item.matched_interest_label = matched_keyword;
        item.matched_interest_score = if keyword_score > 0.0 {
            Some(keyword_score)
        } else {
            None
        };
        item.passed_threshold = final_score > 0.0;
        ranked.push(RankedCandidate {
            dedupe_key: candidate.dedupe_key,
            item,
            original_index: candidate.original_index,
            score: final_score,
        });
    }

    let mut deduped: HashMap<String, RankedCandidate> = HashMap::new();
    for candidate in ranked {
        if let Some(existing) = deduped.get(&candidate.dedupe_key) {
            if rank_candidate_cmp(&candidate, existing) != Ordering::Less {
                continue;
            }
        }
        deduped.insert(candidate.dedupe_key.clone(), candidate);
    }

    let mut ranked_items: Vec<RankedCandidate> = deduped.into_values().collect();
    ranked_items.sort_by(rank_candidate_cmp);
    ranked_items = interleave_ranked_candidates_by_source(ranked_items, limit);
    ranked_items
        .into_iter()
        .map(|candidate| candidate.item)
        .collect()
}

pub fn best_interest_match(
    embedding: &[f32],
    interests: &[InterestVector],
) -> (f32, f32, Option<String>) {
    let mut best_weighted = 0.0_f32;
    let mut best_similarity = 0.0_f32;
    let mut best_label: Option<String> = None;
    for interest in interests {
        let similarity = cosine_similarity(embedding, &interest.embedding);
        let weighted = similarity * interest.health_score;
        if weighted > best_weighted {
            best_weighted = weighted;
            best_similarity = similarity;
            best_label = Some(interest.label.clone());
        }
    }
    (best_weighted, best_similarity, best_label)
}

pub fn top_interest_terms(profile: &FeedProfile) -> BTreeSet<String> {
    let mut interests = profile.interests.clone();
    interests.sort_by(|left, right| {
        right
            .health_score
            .partial_cmp(&left.health_score)
            .unwrap_or(Ordering::Equal)
    });
    interests
        .into_iter()
        .take(6)
        .flat_map(|interest| {
            if interest.keywords.is_empty() {
                tokenize_terms(&interest.label)
            } else {
                interest.keywords.clone()
            }
        })
        .collect()
}

pub fn weighted_interest_keywords(profile: &FeedProfile) -> Vec<(String, f32)> {
    let mut scores: HashMap<String, f32> = HashMap::new();
    for interest in &profile.interests {
        let keywords = if interest.keywords.is_empty() {
            vec![interest.label.clone()]
        } else {
            interest.keywords.clone()
        };
        for keyword in keywords {
            if keyword.len() < 3 || stage1_stopwords().contains(keyword.as_str()) {
                continue;
            }
            *scores.entry(keyword).or_insert(0.0) += interest.health_score.max(0.05);
        }
    }
    let mut ranked: Vec<(String, f32)> = scores.into_iter().collect();
    ranked.sort_by(|left, right| {
        right
            .1
            .partial_cmp(&left.1)
            .unwrap_or(Ordering::Equal)
            .then_with(|| left.0.cmp(&right.0))
    });
    ranked.truncate(STAGE1_KEYWORD_LIMIT);
    ranked
}

pub fn keyword_weight_sum(text: &str, keyword_weights: &[(String, f32)]) -> (f32, Option<String>) {
    if keyword_weights.is_empty() {
        return (0.0, None);
    }
    let lower = text.to_ascii_lowercase();
    let stemmed_tokens: Vec<String> = tokenize_and_stem(&lower);
    let mut matched_weight = 0.0_f32;
    let mut best_match: Option<(String, f32)> = None;
    for (keyword, weight) in keyword_weights {
        let matched = lower.contains(keyword.as_str())
            || stemmed_tokens.iter().any(|token| token == keyword.as_str());
        if !matched {
            continue;
        }
        matched_weight += *weight;
        if best_match
            .as_ref()
            .map(|(_, best)| *weight > *best)
            .unwrap_or(true)
        {
            best_match = Some((keyword.clone(), *weight));
        }
    }
    (matched_weight, best_match.map(|(keyword, _)| keyword))
}

/// Negative-lens penalty for disliked keywords. Returns a positive penalty
/// magnitude to subtract from a candidate's score (0 when no negatives match).
/// Matches the TS `journalTopicPenalty` policy: strongest match contributes
/// most, additional matches stack, capped — so the item sinks but stays.
pub fn negative_keyword_penalty(text: &str, negatives: &[InterestVector]) -> f32 {
    if negatives.is_empty() {
        return 0.0;
    }
    let lower = text.to_ascii_lowercase();
    let stemmed_tokens: Vec<String> = tokenize_and_stem(&lower);
    let mut penalty = 0.0_f32;
    let mut first = true;
    for interest in negatives {
        let keyword = interest
            .keywords
            .first()
            .cloned()
            .unwrap_or_else(|| interest.label.clone());
        let matched = lower.contains(keyword.as_str())
            || stemmed_tokens.iter().any(|token| token == keyword.as_str());
        if !matched {
            continue;
        }
        penalty += if first { NEG_MATCH_TOP } else { NEG_MATCH_EACH };
        first = false;
        if penalty >= NEG_MATCH_CAP {
            return NEG_MATCH_CAP;
        }
    }
    penalty
}

pub fn candidate_freshness_bonus(item: &PersonalizedFeedItem) -> f32 {
    let timestamp = item_sort_timestamp(item);
    let Ok(parsed) = chrono::DateTime::parse_from_rfc3339(timestamp) else {
        return 0.0;
    };
    let age_hours = (Utc::now() - parsed.with_timezone(&Utc)).num_hours().max(0) as f32;
    if age_hours <= 24.0 {
        KEYWORD_PROFILE_FRESHNESS_BONUS_MAX
    } else if age_hours <= 72.0 {
        KEYWORD_PROFILE_FRESHNESS_BONUS_MAX * 0.5
    } else if age_hours <= 168.0 {
        KEYWORD_PROFILE_FRESHNESS_BONUS_MAX * 0.2
    } else {
        0.0
    }
}

pub fn passes_lexical_gate(_text: &str, _terms: &BTreeSet<String>, _stage1_score: f32) -> bool {
    true
}

pub async fn embed_text_batch(embedder: SharedEmbedder, texts: &[String]) -> Result<Vec<Vec<f32>>> {
    let mut out = Vec::new();
    for chunk in texts.chunks(FEED_EMBED_BATCH_SIZE) {
        let refs: Vec<&str> = chunk.iter().map(String::as_str).collect();
        let mut batch = embedder.embed(&refs).await?;
        out.append(&mut batch);
    }
    Ok(out)
}

pub fn rank_candidate_cmp(left: &RankedCandidate, right: &RankedCandidate) -> Ordering {
    let score_order = right
        .score
        .partial_cmp(&left.score)
        .unwrap_or(Ordering::Equal);
    if score_order != Ordering::Equal {
        return score_order;
    }
    let timestamp_order = item_sort_timestamp(&right.item).cmp(item_sort_timestamp(&left.item));
    if timestamp_order != Ordering::Equal {
        return timestamp_order;
    }
    left.original_index.cmp(&right.original_index)
}

pub fn candidate_source_mix_key(item: &PersonalizedFeedItem) -> String {
    if let Some(label) = item
        .feed_source
        .as_ref()
        .map(|source| source.label.trim())
        .filter(|label| !label.is_empty())
    {
        return label.to_ascii_lowercase();
    }
    item.source_type.trim().to_ascii_lowercase()
}

pub fn item_sort_timestamp(item: &PersonalizedFeedItem) -> &str {
    if let Some(discovered_at) = item
        .web_preview
        .as_ref()
        .map(|preview| preview.discovered_at.as_str())
        .filter(|value| !value.is_empty())
    {
        return discovered_at;
    }
    item.feed_item
        .get("post")
        .and_then(|post| post.get("indexedAt"))
        .and_then(serde_json::Value::as_str)
        .or_else(|| {
            item.feed_item
                .get("publishedAt")
                .and_then(serde_json::Value::as_str)
        })
        .unwrap_or("")
}

pub fn interleave_ranked_candidates_by_source(
    ranked_items: Vec<RankedCandidate>,
    limit: usize,
) -> Vec<RankedCandidate> {
    if ranked_items.len() <= 2 {
        return ranked_items.into_iter().take(limit).collect();
    }

    let mut buckets: Vec<(String, Vec<RankedCandidate>)> = Vec::new();
    for candidate in ranked_items {
        let source_key = candidate_source_mix_key(&candidate.item);
        if let Some((_, bucket)) = buckets.iter_mut().find(|(key, _)| key == &source_key) {
            bucket.push(candidate);
        } else {
            buckets.push((source_key, vec![candidate]));
        }
    }

    if buckets.len() <= 1 {
        return buckets
            .into_iter()
            .flat_map(|(_, bucket)| bucket)
            .take(limit)
            .collect();
    }

    let mut interleaved = Vec::new();
    loop {
        let mut advanced = false;
        for (_, bucket) in &mut buckets {
            if bucket.is_empty() {
                continue;
            }
            interleaved.push(bucket.remove(0));
            advanced = true;
            if interleaved.len() >= limit {
                return interleaved;
            }
        }
        if !advanced {
            break;
        }
    }
    interleaved
}

pub fn stage1_stopwords() -> &'static HashSet<&'static str> {
    static WORDS: OnceLock<HashSet<&'static str>> = OnceLock::new();
    WORDS.get_or_init(|| {
        HashSet::from([
            "about",
            "after",
            "also",
            "been",
            "being",
            "because",
            "before",
            "between",
            "could",
            "from",
            "have",
            "into",
            "just",
            "like",
            "more",
            "most",
            "only",
            "other",
            "over",
            "really",
            "some",
            "than",
            "that",
            "their",
            "there",
            "these",
            "they",
            "this",
            "those",
            "through",
            "very",
            "what",
            "when",
            "where",
            "which",
            "with",
            "would",
            "your",
            "ours",
            "ourselves",
            "the",
            "and",
            "for",
            "are",
            "was",
            "were",
            "you",
            "has",
            "had",
            "but",
            "not",
            "too",
            "out",
            "off",
            "its",
            "why",
            "how",
            "who",
            "insight",
            "post",
            "notes",
            "note",
            "journal",
            "entry",
            "entries",
            "work",
            "thing",
            "things",
            "stuff",
            "really",
            "just",
            "dont",
            "didnt",
            "doesnt",
            "cant",
            "wont",
            "ive",
            "im",
            "youre",
            "thats",
            "maybe",
            "also",
            "still",
            "feel",
            "kind",
            "lot",
            "can",
            "should",
            "did",
            "done",
            "her",
            "his",
            "our",
            "lack",
            "start",
            "write",
            "need",
            "needs",
            "want",
            "wants",
            "think",
            "thinking",
            "good",
            "bad",
            "better",
            "best",
            "worse",
            "life",
            "people",
            "person",
            "someone",
            "something",
        ])
    })
}

pub fn tokenize_terms(raw: &str) -> Vec<String> {
    raw.split(|char: char| !char.is_alphanumeric())
        .map(|part| part.trim().to_ascii_lowercase())
        .filter(|part| part.len() >= 3)
        .collect()
}

pub fn tokenize_and_stem(raw: &str) -> Vec<String> {
    let stemmer = english_stemmer();
    let mut seen = HashSet::new();
    raw.split(|char: char| !char.is_alphanumeric())
        .map(|part| part.trim().to_ascii_lowercase())
        .filter(|part| part.len() >= 3)
        .map(|part| {
            let stemmed = stemmer.stem(&part).into_owned();
            if stemmed.len() >= 3 {
                stemmed
            } else {
                part
            }
        })
        .filter(|term| seen.insert(term.clone()))
        .collect()
}

pub fn english_stemmer() -> &'static Stemmer {
    static STEMMER: OnceLock<Stemmer> = OnceLock::new();
    STEMMER.get_or_init(|| Stemmer::create(StemAlgorithm::English))
}

pub fn stem_term(term: &str) -> String {
    english_stemmer().stem(term).into_owned()
}

pub fn broad_interest_keywords(profile: &FeedProfile) -> Vec<String> {
    let mut scores: HashMap<String, f32> = HashMap::new();
    for interest in &profile.interests {
        let keywords = if interest.keywords.is_empty() {
            tokenize_terms(&interest.label)
        } else {
            interest.keywords.clone()
        };
        for keyword in keywords {
            if keyword.len() < 3 || stage1_stopwords().contains(keyword.as_str()) {
                continue;
            }
            *scores.entry(keyword).or_insert(0.0) += interest.health_score.max(0.1);
        }
    }
    let mut ranked: Vec<(String, f32)> = scores.into_iter().collect();
    ranked.sort_by(|left, right| {
        right
            .1
            .partial_cmp(&left.1)
            .unwrap_or(Ordering::Equal)
            .then_with(|| left.0.cmp(&right.0))
    });
    let result: Vec<String> = ranked
        .into_iter()
        .map(|(keyword, _)| keyword)
        .take(STAGE1_KEYWORD_LIMIT)
        .collect();
    tracing::debug!(
        keyword_count = result.len(),
        keywords = %result.join(", "),
        interest_count = profile.interests.len(),
        "World feed: broad interest keywords for source matching"
    );
    result
}

pub fn keyword_match_score(text: &str, keywords: &[String]) -> f32 {
    if keywords.is_empty() {
        return 0.0;
    }
    let lower = text.to_ascii_lowercase();
    let stemmed_tokens: Vec<String> = tokenize_and_stem(&lower);
    let matched = keywords
        .iter()
        .filter(|keyword| {
            lower.contains(keyword.as_str())
                || stemmed_tokens.iter().any(|token| token == keyword.as_str())
        })
        .count();
    if matched == 0 {
        return 0.0;
    }
    (0.65 + (matched as f32 - 1.0) * 0.15).min(1.0)
}

pub fn first_matched_keyword<'a>(text: &str, keywords: &'a [String]) -> Option<&'a str> {
    let lower = text.to_ascii_lowercase();
    let stemmed_tokens: Vec<String> = tokenize_and_stem(&lower);
    keywords
        .iter()
        .find(|keyword| {
            lower.contains(keyword.as_str())
                || stemmed_tokens.iter().any(|token| token == keyword.as_str())
        })
        .map(|keyword| keyword.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::feed::types::InterestVector;

    fn neg(label: &str) -> InterestVector {
        InterestVector {
            id: String::new(),
            label: label.into(),
            embedding: Vec::new(),
            health_score: 1.0,
            source_path: String::new(),
            keywords: vec![label.into()],
        }
    }

    #[test]
    fn negative_keyword_penalty_zero_when_no_negatives_or_no_match() {
        assert_eq!(negative_keyword_penalty("a post about rust", &[]), 0.0);
        assert_eq!(
            negative_keyword_penalty(
                "a post about rust",
                &[neg("celebrity gossip"), neg("sports")]
            ),
            0.0
        );
    }

    #[test]
    fn negative_keyword_penalty_stacked_and_capped() {
        // Single match → top penalty (0.7).
        let p1 = negative_keyword_penalty("celebrity gossip drama", &[neg("celebrity gossip")]);
        assert!((p1 - 0.7).abs() < 1e-6);

        // Two matches → top + each (0.7 + 0.25 = 0.95) → capped at 0.9.
        let p2 = negative_keyword_penalty(
            "celebrity gossip and sports news",
            &[neg("celebrity gossip"), neg("sports")],
        );
        assert!((p2 - 0.9).abs() < 1e-6);

        // Three matches still capped at 0.9 (down-rank, never hide).
        let p3 = negative_keyword_penalty(
            "celebrity gossip, sports, and reality tv",
            &[neg("celebrity gossip"), neg("sports"), neg("reality tv")],
        );
        assert!((p3 - 0.9).abs() < 1e-6);
    }

    #[test]
    fn negative_keyword_penalty_case_insensitive_substring() {
        // Uppercase in the candidate text still matches the lowercase keyword.
        let p = negative_keyword_penalty("CELEBRITY GOSSIP overload", &[neg("celebrity gossip")]);
        assert!((p - 0.7).abs() < 1e-6);
    }
}
