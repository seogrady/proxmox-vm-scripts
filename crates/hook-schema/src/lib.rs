use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HookSection {
    #[serde(default)]
    pub bootstrap: HookRefs,
    #[serde(default)]
    pub validate: HookRefs,
    #[serde(default)]
    #[serde(flatten)]
    pub commands: BTreeMap<String, HookRefs>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(untagged)]
pub enum HookRefs {
    One(String),
    Many(Vec<String>),
    #[default]
    None,
}

impl HookRefs {
    pub fn resolve(&self, root: &Path) -> Result<Vec<String>> {
        let patterns = match self {
            HookRefs::One(pattern) => vec![pattern.as_str()],
            HookRefs::Many(patterns) => patterns.iter().map(String::as_str).collect(),
            HookRefs::None => Vec::new(),
        };
        let mut resolved = Vec::new();
        for pattern in patterns {
            let full_pattern = root.join(pattern);
            let pattern_text = full_pattern.to_string_lossy().to_string();
            let mut matches = glob::glob(&pattern_text)
                .with_context(|| format!("invalid hook glob `{pattern}`"))?
                .collect::<Result<Vec<_>, _>>()
                .with_context(|| format!("failed to resolve hook glob `{pattern}`"))?;
            matches.sort();
            if matches.is_empty() && !has_glob_meta(pattern) {
                matches.push(root.join(pattern));
            }
            if matches.is_empty() {
                bail!("hook glob `{pattern}` matched no files");
            }
            for path in matches {
                let relative = path.strip_prefix(root).with_context(|| {
                    format!("hook {} is outside {}", path.display(), root.display())
                })?;
                resolved.push(relative.to_string_lossy().to_string());
            }
        }
        resolved.dedup();
        Ok(resolved)
    }
}

impl HookSection {
    pub fn hook_refs(&self, command: &str) -> Option<&HookRefs> {
        match command {
            "bootstrap" => Some(&self.bootstrap),
            "validate" => Some(&self.validate),
            other => self.commands.get(other),
        }
    }

    pub fn command_names(&self) -> BTreeSet<String> {
        let mut names = BTreeSet::new();
        if !matches!(self.bootstrap, HookRefs::None) {
            names.insert("bootstrap".to_string());
        }
        if !matches!(self.validate, HookRefs::None) {
            names.insert("validate".to_string());
        }
        names.extend(self.commands.keys().cloned());
        names
    }
}

fn has_glob_meta(pattern: &str) -> bool {
    pattern.contains('*') || pattern.contains('?') || pattern.contains('[')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hook_refs_support_single_and_many_entries() {
        let root = temp_root();
        std::fs::create_dir_all(root.join("hooks")).unwrap();
        std::fs::write(root.join("hooks/01.sh"), "").unwrap();
        std::fs::write(root.join("hooks/02.sh"), "").unwrap();

        let hooks: HookRefs = toml::Value::Array(vec![
            toml::Value::String("hooks/01.sh".to_string()),
            toml::Value::String("hooks/02.sh".to_string()),
        ])
        .try_into()
        .unwrap();
        assert_eq!(
            hooks.resolve(&root).unwrap(),
            vec!["hooks/01.sh".to_string(), "hooks/02.sh".to_string()]
        );
    }

    #[test]
    fn hook_section_exposes_named_commands() {
        let hooks: HookSection = toml::from_str(
            r#"
            bootstrap = "hooks/bootstrap.sh"
            validate = "hooks/validate.sh"
            cleanup = "hooks/cleanup.sh"
            "#,
        )
        .unwrap();

        assert!(hooks.command_names().contains("bootstrap"));
        assert!(hooks.command_names().contains("validate"));
        assert!(hooks.command_names().contains("cleanup"));
    }

    fn temp_root() -> std::path::PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!(
            "vmctl-hook-schema-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        dir
    }
}
