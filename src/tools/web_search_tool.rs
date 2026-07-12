use super::traits::{Tool, ToolResult};
use async_trait::async_trait;
use regex::Regex;
use serde_json::json;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WebSearchResultItem {
    pub title: String,
    pub url: String,
    pub description: String,
    pub provider: String,
}

/// Open-web search tool backed by DuckDuckGo's free HTML endpoint.
///
/// No API key, no paid plan, no proprietary credential — this stays aligned
/// with the journal-first, open-protocol philosophy: discovery of web content
/// is driven by the user's own interest keywords, not a third-party key.
pub struct WebSearchTool {
    max_results: usize,
    timeout_secs: u64,
}

impl WebSearchTool {
    pub fn new(max_results: usize, timeout_secs: u64) -> Self {
        Self {
            max_results: max_results.clamp(1, 10),
            timeout_secs: timeout_secs.max(1),
        }
    }

    pub async fn search_structured(&self, query: &str) -> anyhow::Result<Vec<WebSearchResultItem>> {
        if query.trim().is_empty() {
            anyhow::bail!("Search query cannot be empty");
        }
        self.search_duckduckgo_structured(query).await
    }

    async fn search_duckduckgo(&self, query: &str) -> anyhow::Result<String> {
        let results = self.search_duckduckgo_structured(query).await?;
        Ok(format_search_results(query, "DuckDuckGo", &results))
    }

    async fn search_duckduckgo_structured(&self, query: &str) -> anyhow::Result<Vec<WebSearchResultItem>> {
        let encoded_query = urlencoding::encode(query);
        let search_url = format!("https://html.duckduckgo.com/html/?q={}", encoded_query);

        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(self.timeout_secs))
            .user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
            .build()?;

        let response = client.get(&search_url).send().await?;

        if !response.status().is_success() {
            anyhow::bail!(
                "DuckDuckGo search failed with status: {}",
                response.status()
            );
        }

        let html = response.text().await?;
        self.parse_duckduckgo_results(&html)
    }

    fn parse_duckduckgo_results(&self, html: &str) -> anyhow::Result<Vec<WebSearchResultItem>> {
        // Extract result links: <a class="result__a" href="...">Title</a>
        let link_regex = Regex::new(
            r#"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#,
        )?;

        // Extract snippets: <a class="result__snippet">...</a>
        let snippet_regex = Regex::new(r#"<a class="result__snippet[^"]*"[^>]*>([\s\S]*?)</a>"#)?;

        let link_matches: Vec<_> = link_regex
            .captures_iter(html)
            .take(self.max_results + 2)
            .collect();

        let snippet_matches: Vec<_> = snippet_regex
            .captures_iter(html)
            .take(self.max_results + 2)
            .collect();

        if link_matches.is_empty() {
            return Ok(Vec::new());
        }

        let count = link_matches.len().min(self.max_results);
        let mut results = Vec::with_capacity(count);

        for i in 0..count {
            let caps = &link_matches[i];
            let url_str = decode_ddg_redirect_url(&caps[1]);
            let title = strip_tags(&caps[2]);
            let description = if i < snippet_matches.len() {
                strip_tags(&snippet_matches[i][1]).trim().to_string()
            } else {
                String::new()
            };

            results.push(WebSearchResultItem {
                title: title.trim().to_string(),
                url: url_str.trim().to_string(),
                description,
                provider: "duckduckgo".to_string(),
            });
        }

        Ok(results)
    }
}

fn format_search_results(query: &str, provider_label: &str, items: &[WebSearchResultItem]) -> String {
    if items.is_empty() {
        return format!("No results found for: {}", query);
    }

    let mut lines = vec![format!("Search results for: {} (via {})", query, provider_label)];
    for (index, item) in items.iter().enumerate() {
        lines.push(format!("{}. {}", index + 1, item.title));
        lines.push(format!("   {}", item.url));
        if !item.description.trim().is_empty() {
            lines.push(format!("   {}", item.description.trim()));
        }
    }
    lines.join("\n")
}

fn decode_ddg_redirect_url(raw_url: &str) -> String {
    if let Some(index) = raw_url.find("uddg=") {
        let encoded = &raw_url[index + 5..];
        let encoded = encoded.split('&').next().unwrap_or(encoded);
        if let Ok(decoded) = urlencoding::decode(encoded) {
            return decoded.into_owned();
        }
    }

    raw_url.to_string()
}

fn strip_tags(content: &str) -> String {
    let re = Regex::new(r"<[^>]+>").unwrap();
    re.replace_all(content, "").to_string()
}

#[async_trait]
impl Tool for WebSearchTool {
    fn name(&self) -> &str {
        "web_search_tool"
    }

    fn description(&self) -> &str {
        "Search the open web via DuckDuckGo. Returns relevant search results with titles, URLs, and descriptions. Use this to find current information, news, or research topics."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The search query. Be specific for better results."
                }
            },
            "required": ["query"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let query = args
            .get("query")
            .and_then(|q| q.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing required parameter: query"))?;

        if query.trim().is_empty() {
            anyhow::bail!("Search query cannot be empty");
        }

        tracing::info!("Searching open web (DuckDuckGo) for: {}", query);

        let result = self.search_duckduckgo(query).await?;

        Ok(ToolResult {
            success: true,
            output: result,
            error: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tool_name() {
        let tool = WebSearchTool::new(5, 15);
        assert_eq!(tool.name(), "web_search_tool");
    }

    #[test]
    fn test_tool_description() {
        let tool = WebSearchTool::new(5, 15);
        assert!(tool.description().contains("Search the open web"));
    }

    #[test]
    fn test_parameters_schema() {
        let tool = WebSearchTool::new(5, 15);
        let schema = tool.parameters_schema();
        assert_eq!(schema["type"], "object");
        assert!(schema["properties"]["query"].is_object());
    }

    #[test]
    fn test_strip_tags() {
        let html = "<b>Hello</b> <i>World</i>";
        assert_eq!(strip_tags(html), "Hello World");
    }

    #[test]
    fn test_parse_duckduckgo_results_empty() {
        let tool = WebSearchTool::new(5, 15);
        let result = tool.parse_duckduckgo_results("<html>No results here</html>").unwrap();
        assert!(result.is_empty());
    }

    #[test]
    fn test_parse_duckduckgo_results_with_data() {
        let tool = WebSearchTool::new(5, 15);
        let html = r#"
            <a class="result__a" href="https://example.com">Example Title</a>
            <a class="result__snippet">This is a description</a>
        "#;
        let result = tool.parse_duckduckgo_results(html).unwrap();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].title, "Example Title");
        assert_eq!(result[0].url, "https://example.com");
    }

    #[test]
    fn test_parse_duckduckgo_results_decodes_redirect_url() {
        let tool = WebSearchTool::new(5, 15);
        let html = r#"
            <a class="result__a" href="https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpath%3Fa%3D1&amp;rut=test">Example Title</a>
            <a class="result__snippet">This is a description</a>
        "#;
        let result = tool.parse_duckduckgo_results(html).unwrap();
        assert_eq!(result[0].url, "https://example.com/path?a=1");
    }

    #[test]
    fn test_constructor_clamps_web_search_limits() {
        let tool = WebSearchTool::new(0, 0);
        let html = r#"
            <a class="result__a" href="https://example.com">Example Title</a>
            <a class="result__snippet">This is a description</a>
        "#;
        let result = tool.parse_duckduckgo_results(html).unwrap();
        assert_eq!(result[0].title, "Example Title");
    }

    #[tokio::test]
    async fn test_execute_missing_query() {
        let tool = WebSearchTool::new(5, 15);
        let result = tool.execute(json!({})).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn test_execute_empty_query() {
        let tool = WebSearchTool::new(5, 15);
        let result = tool.execute(json!({"query": ""})).await;
        assert!(result.is_err());
    }
}
