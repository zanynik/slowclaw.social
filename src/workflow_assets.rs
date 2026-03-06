use anyhow::{Context, Result};
use std::path::Path;

#[derive(Debug, Clone, Copy, Default)]
pub struct WorkflowAssetSyncReport {
    pub created: usize,
    pub existing: usize,
}

#[derive(Debug, Clone, Copy)]
struct BundledWorkflowAsset {
    rel_path: &'static str,
    content: &'static str,
}

const BUNDLED_WORKFLOW_ASSETS: &[BundledWorkflowAsset] = &[BundledWorkflowAsset {
    rel_path: "skills/workflow_bot_creation/SKILL.md",
    content: include_str!("../skills/workflow_bot_creation/SKILL.md"),
}];

/// Seed baseline workflow assets into a workspace without overwriting user edits.
pub fn ensure_workspace_workflow_assets(workspace_dir: &Path) -> Result<WorkflowAssetSyncReport> {
    let mut report = WorkflowAssetSyncReport::default();

    for asset in BUNDLED_WORKFLOW_ASSETS {
        let target = workspace_dir.join(asset.rel_path);
        if target.exists() {
            report.existing += 1;
            continue;
        }

        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!(
                    "Failed to create workflow asset parent directory {}",
                    parent.display()
                )
            })?;
        }

        std::fs::write(&target, asset.content).with_context(|| {
            format!("Failed to write bundled workflow asset {}", target.display())
        })?;
        report.created += 1;
    }

    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ensure_assets_creates_creation_skill_without_overwriting_existing() {
        let tmp = tempfile::tempdir().unwrap();
        let workspace = tmp.path();

        let preset_path = workspace.join("skills/workflow_bot_creation/SKILL.md");
        std::fs::create_dir_all(preset_path.parent().unwrap()).unwrap();
        std::fs::write(&preset_path, "custom-skill-body").unwrap();

        let report = ensure_workspace_workflow_assets(workspace).unwrap();
        assert_eq!(report.created, 0);
        assert_eq!(report.existing, 1);

        let preserved = std::fs::read_to_string(preset_path).unwrap();
        assert_eq!(preserved, "custom-skill-body");
    }

    #[test]
    fn ensure_assets_writes_creation_skill_when_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let workspace = tmp.path();

        let report = ensure_workspace_workflow_assets(workspace).unwrap();
        assert_eq!(report.created, 1);
        assert_eq!(report.existing, 0);
        assert!(workspace
            .join("skills/workflow_bot_creation/SKILL.md")
            .exists());
    }
}
