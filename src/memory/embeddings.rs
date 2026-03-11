use anyhow::{anyhow, Context, Result};
use async_trait::async_trait;
use directories::ProjectDirs;
use parking_lot::Mutex;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock as StdOnceLock};
use std::time::Duration;
use tokenizers::Tokenizer;
use tokio::sync::OnceCell;
use tract_onnx::prelude::*;

/// Trait for embedding providers — convert text to vectors
#[async_trait]
pub trait EmbeddingProvider: Send + Sync {
    /// Provider name
    fn name(&self) -> &str;

    /// Embedding dimensions
    fn dimensions(&self) -> usize;

    /// Embed a batch of texts into vectors
    async fn embed(&self, texts: &[&str]) -> anyhow::Result<Vec<Vec<f32>>>;

    /// Embed a single text
    async fn embed_one(&self, text: &str) -> anyhow::Result<Vec<f32>> {
        let mut results = self.embed(&[text]).await?;
        results
            .pop()
            .ok_or_else(|| anyhow::anyhow!("Empty embedding result"))
    }
}

const ALL_MINILM_MODEL_REPO: &str = "Xenova/all-MiniLM-L6-v2";
const ALL_MINILM_EMBEDDING_DIMS: usize = 384;
const ALL_MINILM_MAX_TOKENS: usize = 256;
const ALL_MINILM_TOKENIZER_URL: &str =
    "https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/tokenizer.json";
const ALL_MINILM_MODEL_URL: &str =
    "https://huggingface.co/Xenova/all-MiniLM-L6-v2/resolve/main/onnx/model_quantized.onnx";
const ALL_MINILM_DOWNLOAD_TIMEOUT_SECS: u64 = 180;

// ── Hash fallback provider (used only when local model init fails) ───────

struct HashEmbedding {
    model: String,
    dims: usize,
}

impl HashEmbedding {
    pub fn new(model: &str, dims: usize) -> Self {
        Self {
            model: model.to_string(),
            dims: dims.max(1),
        }
    }

    fn normalize_text(raw: &str) -> String {
        let mut normalized = String::with_capacity(raw.len());
        let mut last_was_space = true;
        for ch in raw.chars() {
            if ch.is_alphanumeric() {
                for lower in ch.to_lowercase() {
                    normalized.push(lower);
                }
                last_was_space = false;
            } else if !last_was_space {
                normalized.push(' ');
                last_was_space = true;
            }
        }
        normalized.trim().to_string()
    }

    fn stable_hash64(input: &str) -> u64 {
        const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
        const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

        let mut hash = FNV_OFFSET;
        for byte in input.as_bytes() {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(FNV_PRIME);
        }
        hash
    }

    fn add_hashed_feature(vector: &mut [f32], feature: &str, weight: f32) {
        if vector.is_empty() {
            return;
        }

        let hash = Self::stable_hash64(feature);
        let index = (hash as usize) % vector.len();
        let sign = if hash & 1 == 0 { 1.0 } else { -1.0 };
        vector[index] += sign * weight;
    }

    fn token_char_trigrams(token: &str) -> Vec<String> {
        let chars: Vec<char> = token.chars().collect();
        if chars.len() < 3 {
            return Vec::new();
        }

        chars
            .windows(3)
            .map(|window| window.iter().collect::<String>())
            .collect()
    }

    fn embed_text(&self, text: &str) -> Vec<f32> {
        let mut vector = vec![0.0; self.dims];
        let normalized = Self::normalize_text(text);
        if normalized.is_empty() {
            return vector;
        }

        let tokens: Vec<&str> = normalized.split_whitespace().collect();
        for token in &tokens {
            let token_len = token.chars().count() as f32;
            let token_weight = 1.0 + (token_len.min(12.0) / 24.0);
            Self::add_hashed_feature(&mut vector, &format!("tok:{token}"), token_weight);

            for trigram in Self::token_char_trigrams(token) {
                Self::add_hashed_feature(&mut vector, &format!("tri:{trigram}"), 0.35);
            }
        }

        for pair in tokens.windows(2) {
            Self::add_hashed_feature(&mut vector, &format!("bi:{}_{}", pair[0], pair[1]), 1.2);
        }

        let token_count = tokens.len();
        Self::add_hashed_feature(
            &mut vector,
            &format!("meta:model={}", self.model),
            0.1,
        );
        Self::add_hashed_feature(
            &mut vector,
            &format!("meta:tokens={}", token_count / 8),
            0.15,
        );

        let norm = vector.iter().map(|value| value * value).sum::<f32>().sqrt();
        if norm > 0.0 {
            for value in &mut vector {
                *value /= norm;
            }
        }

        vector
    }
}

#[async_trait]
impl EmbeddingProvider for HashEmbedding {
    fn name(&self) -> &str {
        "builtin-fallback"
    }

    fn dimensions(&self) -> usize {
        self.dims
    }

    async fn embed(&self, texts: &[&str]) -> anyhow::Result<Vec<Vec<f32>>> {
        Ok(texts.iter().map(|text| self.embed_text(text)).collect())
    }
}

type AllMiniLmModel = TypedRunnableModel<TypedModel>;

#[derive(Debug, Clone)]
struct AllMiniLmAssets {
    tokenizer_path: PathBuf,
    model_path: PathBuf,
}

struct LocalMiniLmEmbedder {
    tokenizer: Tokenizer,
    model: AllMiniLmModel,
    input_count: usize,
}

impl LocalMiniLmEmbedder {
    fn load_or_download(_model: &str) -> Result<Self> {
        let assets = ensure_all_minilm_assets()?;
        let tokenizer = Tokenizer::from_file(&assets.tokenizer_path)
            .map_err(|err| anyhow!("failed to load tokenizer: {err}"))?;

        let inference_model = tract_onnx::onnx()
            .model_for_path(&assets.model_path)
            .with_context(|| format!("failed to load ONNX model from {}", assets.model_path.display()))?;
        let input_count = inference_model.inputs.len();
        let model = inference_model
            .into_optimized()?
            .into_runnable()
            .context("failed to prepare ONNX embedding model")?;

        Ok(Self {
            tokenizer,
            model,
            input_count,
        })
    }

    fn embed_batch(&mut self, texts: &[String]) -> Result<Vec<Vec<f32>>> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }

        let encodings = texts
            .iter()
            .map(|text| {
                self.tokenizer
                    .encode(text.as_str(), true)
                    .map_err(|err| anyhow!("failed to tokenize input: {err}"))
            })
            .collect::<Result<Vec<_>>>()?;

        let batch_size = encodings.len();
        let sequence_len = encodings
            .iter()
            .map(tokenizers::Encoding::len)
            .max()
            .unwrap_or(1)
            .min(ALL_MINILM_MAX_TOKENS)
            .max(1);

        let mut input_ids = vec![0i64; batch_size * sequence_len];
        let mut attention_mask = vec![0i64; batch_size * sequence_len];
        let mut token_type_ids = vec![0i64; batch_size * sequence_len];

        for (row, encoding) in encodings.iter().enumerate() {
            let ids = encoding.get_ids();
            let mask = encoding.get_attention_mask();
            let type_ids = encoding.get_type_ids();
            let length = ids.len().min(sequence_len);

            for column in 0..length {
                let offset = row * sequence_len + column;
                input_ids[offset] = i64::from(ids[column]);
                attention_mask[offset] = i64::from(mask[column]);
                token_type_ids[offset] = i64::from(type_ids.get(column).copied().unwrap_or(0));
            }
        }

        let input_ids_tensor =
            Tensor::from_shape(&[batch_size, sequence_len], &input_ids).context("input_ids tensor")?;
        let attention_mask_tensor = Tensor::from_shape(&[batch_size, sequence_len], &attention_mask)
            .context("attention_mask tensor")?;
        let token_type_ids_tensor =
            Tensor::from_shape(&[batch_size, sequence_len], &token_type_ids)
                .context("token_type_ids tensor")?;

        let mut inputs = tvec!(input_ids_tensor.into(), attention_mask_tensor.into());
        if self.input_count >= 3 {
            inputs.push(token_type_ids_tensor.into());
        }

        let outputs = self
            .model
            .run(inputs)
            .context("all-MiniLM inference failed")?;
        let sequence_output = outputs
            .first()
            .ok_or_else(|| anyhow!("embedding model returned no output tensor"))?;
        let view = sequence_output
            .to_array_view::<f32>()
            .context("embedding output tensor type mismatch")?;

        let shape = view.shape();
        if shape.len() != 3 || shape[0] != batch_size || shape[1] != sequence_len {
            anyhow::bail!("unexpected embedding output shape: {:?}", shape);
        }

        let hidden_size = shape[2];
        if hidden_size != ALL_MINILM_EMBEDDING_DIMS {
            tracing::warn!(
                expected = ALL_MINILM_EMBEDDING_DIMS,
                actual = hidden_size,
                "all-MiniLM output dimension differs from expected size"
            );
        }

        let mut embeddings = Vec::with_capacity(batch_size);
        for row in 0..batch_size {
            let mut pooled = vec![0.0f32; hidden_size];
            let mut token_count = 0.0f32;

            for column in 0..sequence_len {
                if attention_mask[row * sequence_len + column] == 0 {
                    continue;
                }
                token_count += 1.0;
                for hidden in 0..hidden_size {
                    pooled[hidden] += view[[row, column, hidden]];
                }
            }

            if token_count > 0.0 {
                for value in &mut pooled {
                    *value /= token_count;
                }
            }

            l2_normalize(&mut pooled);
            embeddings.push(pooled);
        }

        Ok(embeddings)
    }
}

fn l2_normalize(vector: &mut [f32]) {
    let norm = vector.iter().map(|value| value * value).sum::<f32>().sqrt();
    if norm > 0.0 {
        for value in vector {
            *value /= norm;
        }
    }
}

fn builtin_embedding_cache_dir() -> PathBuf {
    ProjectDirs::from("social", "slowclaw", "zeroclaw")
        .map(|dirs| dirs.cache_dir().join("embeddings").join("all-minilm-l6-v2"))
        .unwrap_or_else(|| {
            std::env::temp_dir()
                .join("zeroclaw")
                .join("embeddings")
                .join("all-minilm-l6-v2")
        })
}

fn asset_download_lock() -> &'static Mutex<()> {
    static LOCK: StdOnceLock<Mutex<()>> = StdOnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

fn download_if_missing(url: &str, destination: &Path) -> Result<()> {
    if destination.exists() {
        return Ok(());
    }

    let parent = destination
        .parent()
        .ok_or_else(|| anyhow!("destination has no parent: {}", destination.display()))?;
    fs::create_dir_all(parent)
        .with_context(|| format!("failed to create cache directory {}", parent.display()))?;

    let temp_path = destination.with_extension("download");
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(ALL_MINILM_DOWNLOAD_TIMEOUT_SECS))
        .build()
        .context("failed to build blocking download client")?;
    let response = client
        .get(url)
        .send()
        .with_context(|| format!("failed to download {url}"))?
        .error_for_status()
        .with_context(|| format!("download returned an error for {url}"))?;
    let bytes = response
        .bytes()
        .with_context(|| format!("failed to read model payload from {url}"))?;

    fs::write(&temp_path, &bytes)
        .with_context(|| format!("failed to write temporary asset {}", temp_path.display()))?;
    fs::rename(&temp_path, destination).with_context(|| {
        format!(
            "failed to move downloaded asset into place: {}",
            destination.display()
        )
    })?;
    Ok(())
}

fn ensure_all_minilm_assets() -> Result<AllMiniLmAssets> {
    let _guard = asset_download_lock().lock();
    let base_dir = builtin_embedding_cache_dir();
    let tokenizer_path = base_dir.join("tokenizer.json");
    let model_path = base_dir.join("model_quantized.onnx");

    download_if_missing(ALL_MINILM_TOKENIZER_URL, &tokenizer_path)?;
    download_if_missing(ALL_MINILM_MODEL_URL, &model_path)?;

    Ok(AllMiniLmAssets {
        tokenizer_path,
        model_path,
    })
}

pub async fn prewarm_builtin_embedding_assets(provider: &str, model: &str) -> Result<bool> {
    if !provider.trim().eq_ignore_ascii_case("builtin") {
        return Ok(false);
    }

    let model_name = model.to_string();
    tokio::task::spawn_blocking(move || {
        ensure_all_minilm_assets().with_context(|| {
            format!(
                "failed to prepare local all-MiniLM assets for builtin model '{model_name}' from {ALL_MINILM_MODEL_REPO}"
            )
        })
    })
    .await
    .map_err(|err| anyhow!("builtin embedding prewarm task failed: {err}"))??;
    Ok(true)
}

// ── Built-in local provider (all-MiniLM with hash fallback) ──────────────

pub struct BuiltinEmbedding {
    model: String,
    dims: usize,
    runtime: OnceCell<Arc<Mutex<LocalMiniLmEmbedder>>>,
    hash_fallback: HashEmbedding,
}

impl BuiltinEmbedding {
    pub fn new(model: &str, _dims: usize) -> Self {
        Self {
            model: model.to_string(),
            dims: ALL_MINILM_EMBEDDING_DIMS,
            runtime: OnceCell::new(),
            hash_fallback: HashEmbedding::new(model, ALL_MINILM_EMBEDDING_DIMS),
        }
    }

    async fn local_runtime(&self) -> Result<Arc<Mutex<LocalMiniLmEmbedder>>> {
        let model = self.model.clone();
        let runtime = self
            .runtime
            .get_or_try_init(|| async move {
                tokio::task::spawn_blocking(move || LocalMiniLmEmbedder::load_or_download(&model))
                    .await
                    .map_err(|err| anyhow!("all-MiniLM init task failed: {err}"))?
                    .map(|embedder| Arc::new(Mutex::new(embedder)))
            })
            .await?;
        Ok(runtime.clone())
    }
}

#[async_trait]
impl EmbeddingProvider for BuiltinEmbedding {
    fn name(&self) -> &str {
        "builtin"
    }

    fn dimensions(&self) -> usize {
        self.dims
    }

    async fn embed(&self, texts: &[&str]) -> anyhow::Result<Vec<Vec<f32>>> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }

        let owned_texts: Vec<String> = texts.iter().map(|text| (*text).to_string()).collect();
        match self.local_runtime().await {
            Ok(runtime) => {
                let result = tokio::task::spawn_blocking(move || runtime.lock().embed_batch(&owned_texts))
                    .await
                    .map_err(|err| anyhow!("all-MiniLM inference task failed: {err}"))?;
                match result {
                    Ok(embeddings) => return Ok(embeddings),
                    Err(err) => {
                        tracing::warn!(
                            error = %err,
                            "builtin embeddings fell back to hash mode after local all-MiniLM inference failure"
                        );
                    }
                }
            }
            Err(err) => {
                tracing::warn!(
                    error = %err,
                    "builtin embeddings fell back to hash mode because local all-MiniLM is unavailable"
                );
            }
        }

        self.hash_fallback.embed(texts).await
    }
}

// ── Noop provider (keyword-only fallback) ────────────────────

pub struct NoopEmbedding;

#[async_trait]
impl EmbeddingProvider for NoopEmbedding {
    fn name(&self) -> &str {
        "none"
    }

    fn dimensions(&self) -> usize {
        0
    }

    async fn embed(&self, _texts: &[&str]) -> anyhow::Result<Vec<Vec<f32>>> {
        Ok(Vec::new())
    }
}

// ── OpenAI-compatible embedding provider ─────────────────────

pub struct OpenAiEmbedding {
    base_url: String,
    api_key: String,
    model: String,
    dims: usize,
}

impl OpenAiEmbedding {
    pub fn new(base_url: &str, api_key: &str, model: &str, dims: usize) -> Self {
        Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            api_key: api_key.to_string(),
            model: model.to_string(),
            dims,
        }
    }

    fn http_client(&self) -> reqwest::Client {
        crate::config::build_runtime_proxy_client("memory.embeddings")
    }

    fn has_explicit_api_path(&self) -> bool {
        let Ok(url) = reqwest::Url::parse(&self.base_url) else {
            return false;
        };

        let path = url.path().trim_end_matches('/');
        !path.is_empty() && path != "/"
    }

    fn has_embeddings_endpoint(&self) -> bool {
        let Ok(url) = reqwest::Url::parse(&self.base_url) else {
            return false;
        };

        url.path().trim_end_matches('/').ends_with("/embeddings")
    }

    fn embeddings_url(&self) -> String {
        if self.has_embeddings_endpoint() {
            return self.base_url.clone();
        }

        if self.has_explicit_api_path() {
            format!("{}/embeddings", self.base_url)
        } else {
            format!("{}/v1/embeddings", self.base_url)
        }
    }
}

#[async_trait]
impl EmbeddingProvider for OpenAiEmbedding {
    fn name(&self) -> &str {
        "openai"
    }

    fn dimensions(&self) -> usize {
        self.dims
    }

    async fn embed(&self, texts: &[&str]) -> anyhow::Result<Vec<Vec<f32>>> {
        if texts.is_empty() {
            return Ok(Vec::new());
        }

        let body = serde_json::json!({
            "model": self.model,
            "input": texts,
        });

        let resp = self
            .http_client()
            .post(self.embeddings_url())
            .header("Authorization", format!("Bearer {}", self.api_key))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await?;

        if !resp.status().is_success() {
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            anyhow::bail!("Embedding API error {status}: {text}");
        }

        let json: serde_json::Value = resp.json().await?;
        let data = json
            .get("data")
            .and_then(|d| d.as_array())
            .ok_or_else(|| anyhow::anyhow!("Invalid embedding response: missing 'data'"))?;

        let mut embeddings = Vec::with_capacity(data.len());
        for item in data {
            let embedding = item
                .get("embedding")
                .and_then(|e| e.as_array())
                .ok_or_else(|| anyhow::anyhow!("Invalid embedding item"))?;

            #[allow(clippy::cast_possible_truncation)]
            let vec: Vec<f32> = embedding
                .iter()
                .filter_map(|v| v.as_f64().map(|f| f as f32))
                .collect();

            embeddings.push(vec);
        }

        Ok(embeddings)
    }
}

// ── Factory ──────────────────────────────────────────────────

pub fn create_embedding_provider(
    provider: &str,
    api_key: Option<&str>,
    model: &str,
    dims: usize,
) -> Box<dyn EmbeddingProvider> {
    match provider {
        "builtin" => Box::new(BuiltinEmbedding::new(model, dims)),
        "openai" => {
            let key = api_key.unwrap_or("");
            Box::new(OpenAiEmbedding::new(
                "https://api.openai.com",
                key,
                model,
                dims,
            ))
        }
        "openrouter" => {
            let key = api_key.unwrap_or("");
            Box::new(OpenAiEmbedding::new(
                "https://openrouter.ai/api/v1",
                key,
                model,
                dims,
            ))
        }
        name if name.starts_with("custom:") => {
            let base_url = name.strip_prefix("custom:").unwrap_or("");
            let key = api_key.unwrap_or("");
            Box::new(OpenAiEmbedding::new(base_url, key, model, dims))
        }
        _ => Box::new(NoopEmbedding),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cosine_similarity(left: &[f32], right: &[f32]) -> f32 {
        left.iter()
            .zip(right.iter())
            .map(|(l, r)| l * r)
            .sum::<f32>()
    }

    #[test]
    fn factory_builtin() {
        let p = create_embedding_provider("builtin", None, "builtin-384-v1", 384);
        assert_eq!(p.name(), "builtin");
        assert_eq!(p.dimensions(), 384);
    }

    #[tokio::test]
    async fn builtin_embedding_is_deterministic() {
        let p = BuiltinEmbedding::new("builtin-384-v1", 384);
        let first = p.embed_one("Camera journal about autumn street photos").await.unwrap();
        let second = p.embed_one("Camera journal about autumn street photos").await.unwrap();
        assert_eq!(first, second);
    }

    #[tokio::test]
    async fn builtin_embedding_prefers_related_text() {
        let p = BuiltinEmbedding::new("builtin-384-v1", 384);
        let anchor = p
            .embed_one("daily journal note about photography and camera settings")
            .await
            .unwrap();
        let related = p
            .embed_one("camera settings and photography practice notes")
            .await
            .unwrap();
        let unrelated = p
            .embed_one("bread recipe with yeast and sourdough starter")
            .await
            .unwrap();

        assert!(
            cosine_similarity(&anchor, &related) > cosine_similarity(&anchor, &unrelated),
            "builtin embeddings should rank related text above unrelated text"
        );
    }

    #[test]
    fn noop_name() {
        let p = NoopEmbedding;
        assert_eq!(p.name(), "none");
        assert_eq!(p.dimensions(), 0);
    }

    #[tokio::test]
    async fn noop_embed_returns_empty() {
        let p = NoopEmbedding;
        let result = p.embed(&["hello"]).await.unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn factory_none() {
        let p = create_embedding_provider("none", None, "model", 1536);
        assert_eq!(p.name(), "none");
    }

    #[test]
    fn factory_openai() {
        let p = create_embedding_provider("openai", Some("key"), "text-embedding-3-small", 1536);
        assert_eq!(p.name(), "openai");
        assert_eq!(p.dimensions(), 1536);
    }

    #[test]
    fn factory_openrouter() {
        let p = create_embedding_provider(
            "openrouter",
            Some("sk-or-test"),
            "openai/text-embedding-3-small",
            1536,
        );
        assert_eq!(p.name(), "openai"); // uses OpenAiEmbedding internally
        assert_eq!(p.dimensions(), 1536);
    }

    #[test]
    fn factory_custom_url() {
        let p = create_embedding_provider("custom:http://localhost:1234", None, "model", 768);
        assert_eq!(p.name(), "openai"); // uses OpenAiEmbedding internally
        assert_eq!(p.dimensions(), 768);
    }

    // ── Edge cases ───────────────────────────────────────────────

    #[tokio::test]
    async fn noop_embed_one_returns_error() {
        let p = NoopEmbedding;
        // embed returns empty vec → pop() returns None → error
        let result = p.embed_one("hello").await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn noop_embed_empty_batch() {
        let p = NoopEmbedding;
        let result = p.embed(&[]).await.unwrap();
        assert!(result.is_empty());
    }

    #[tokio::test]
    async fn noop_embed_multiple_texts() {
        let p = NoopEmbedding;
        let result = p.embed(&["a", "b", "c"]).await.unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn factory_empty_string_returns_noop() {
        let p = create_embedding_provider("", None, "model", 1536);
        assert_eq!(p.name(), "none");
    }

    #[test]
    fn factory_unknown_provider_returns_noop() {
        let p = create_embedding_provider("cohere", None, "model", 1536);
        assert_eq!(p.name(), "none");
    }

    #[test]
    fn factory_custom_empty_url() {
        // "custom:" with no URL — should still construct without panic
        let p = create_embedding_provider("custom:", None, "model", 768);
        assert_eq!(p.name(), "openai");
    }

    #[test]
    fn factory_openai_no_api_key() {
        let p = create_embedding_provider("openai", None, "text-embedding-3-small", 1536);
        assert_eq!(p.name(), "openai");
        assert_eq!(p.dimensions(), 1536);
    }

    #[test]
    fn openai_trailing_slash_stripped() {
        let p = OpenAiEmbedding::new("https://api.openai.com/", "key", "model", 1536);
        assert_eq!(p.base_url, "https://api.openai.com");
    }

    #[test]
    fn openai_dimensions_custom() {
        let p = OpenAiEmbedding::new("http://localhost", "k", "m", 384);
        assert_eq!(p.dimensions(), 384);
    }

    #[test]
    fn embeddings_url_openrouter() {
        let p = OpenAiEmbedding::new(
            "https://openrouter.ai/api/v1",
            "key",
            "openai/text-embedding-3-small",
            1536,
        );
        assert_eq!(
            p.embeddings_url(),
            "https://openrouter.ai/api/v1/embeddings"
        );
    }

    #[test]
    fn embeddings_url_standard_openai() {
        let p = OpenAiEmbedding::new("https://api.openai.com", "key", "model", 1536);
        assert_eq!(p.embeddings_url(), "https://api.openai.com/v1/embeddings");
    }

    #[test]
    fn embeddings_url_base_with_v1_no_duplicate() {
        let p = OpenAiEmbedding::new("https://api.example.com/v1", "key", "model", 1536);
        assert_eq!(p.embeddings_url(), "https://api.example.com/v1/embeddings");
    }

    #[test]
    fn embeddings_url_non_v1_api_path_uses_raw_suffix() {
        let p = OpenAiEmbedding::new(
            "https://api.example.com/api/coding/v3",
            "key",
            "model",
            1536,
        );
        assert_eq!(
            p.embeddings_url(),
            "https://api.example.com/api/coding/v3/embeddings"
        );
    }

    #[test]
    fn embeddings_url_custom_full_endpoint() {
        let p = OpenAiEmbedding::new(
            "https://my-api.example.com/api/v2/embeddings",
            "key",
            "model",
            1536,
        );
        assert_eq!(
            p.embeddings_url(),
            "https://my-api.example.com/api/v2/embeddings"
        );
    }
}
