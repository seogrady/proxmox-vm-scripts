use std::collections::BTreeSet;
use std::path::Path;

use anyhow::Result;
use serde_json::Value;
use vmctl_domain::DesiredState;
use vmctl_lockfile::Lockfile;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncSummary {
    pub desired_only: Vec<String>,
    pub lockfile_only: Vec<String>,
    pub changed: Vec<String>,
}

pub fn summarize_lockfile(path: &Path) -> Result<String> {
    let lockfile = Lockfile::read_from_path(path)?;
    let mut output = format!(
        "lockfile: backend={}, resources={}\n",
        lockfile.backend,
        lockfile.resources.len()
    );
    for resource in lockfile.resources {
        output.push_str(&format!(
            "- {} {} vmid={:?} exists={}\n",
            resource.kind, resource.name, resource.vmid, resource.exists
        ));
    }
    Ok(output)
}

pub fn summarize_terraform_state(path: &Path) -> Result<String> {
    let state: Value = serde_json::from_str(&std::fs::read_to_string(path)?)?;
    let resources = state
        .get("resources")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut output = format!("terraform state: resources={}\n", resources.len());
    for resource in resources {
        let module = resource
            .get("module")
            .and_then(Value::as_str)
            .unwrap_or("root");
        let resource_type = resource
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let name = resource
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        output.push_str(&format!("- {module}.{resource_type}.{name}\n"));
    }
    Ok(output)
}

pub fn compare_desired_to_lockfile(desired: &DesiredState, lockfile: &Lockfile) -> SyncSummary {
    let desired_names = desired
        .resources
        .iter()
        .map(|resource| resource.name.clone())
        .collect::<BTreeSet<_>>();
    let lockfile_names = lockfile
        .resources
        .iter()
        .map(|resource| resource.name.clone())
        .collect::<BTreeSet<_>>();
    let changed = lockfile
        .resources
        .iter()
        .filter(|locked| {
            desired
                .resources
                .iter()
                .find(|resource| resource.name == locked.name)
                .and_then(|resource| serde_json::to_vec(resource).ok())
                .map(|bytes| digest_bytes(&bytes) != locked.digest)
                .unwrap_or(false)
        })
        .map(|resource| resource.name.clone())
        .collect();

    SyncSummary {
        desired_only: desired_names.difference(&lockfile_names).cloned().collect(),
        lockfile_only: lockfile_names.difference(&desired_names).cloned().collect(),
        changed,
    }
}

pub fn render_sync_summary(summary: &SyncSummary) -> String {
    format!(
        "sync summary\n- desired only: {}\n- lockfile only: {}\n- changed: {}\n",
        render_names(&summary.desired_only),
        render_names(&summary.lockfile_only),
        render_names(&summary.changed)
    )
}

fn render_names(names: &[String]) -> String {
    if names.is_empty() {
        "none".to_string()
    } else {
        names.join(", ")
    }
}

fn digest_bytes(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    format!("sha256:{digest:x}")
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use vmctl_domain::{BackendConfig, Resource};
    use vmctl_lockfile::{LockedResource, Lockfile};

    #[test]
    fn compares_desired_resources_to_lockfile() {
        let desired = DesiredState {
            backend: BackendConfig::default(),
            resources: vec![Resource {
                name: "media-stack".to_string(),
                kind: "vm".to_string(),
                role: None,
                vmid: Some(210),
                depends_on: Vec::new(),
                features: BTreeMap::new(),
                settings: BTreeMap::new(),
            }],
            normalized_resources: BTreeMap::new(),
            expansions: BTreeMap::new(),
        };
        let lockfile = Lockfile {
            version: 1,
            backend: "terraform".to_string(),
            generated_at: "test".to_string(),
            artifacts: Vec::new(),
            resources: vec![LockedResource {
                name: "old".to_string(),
                kind: "vm".to_string(),
                vmid: Some(100),
                backend_address: "module.old.x".to_string(),
                digest: "sha256:old".to_string(),
                exists: true,
            }],
        };

        let summary = compare_desired_to_lockfile(&desired, &lockfile);

        assert_eq!(summary.desired_only, vec!["media-stack".to_string()]);
        assert_eq!(summary.lockfile_only, vec!["old".to_string()]);
    }
}
