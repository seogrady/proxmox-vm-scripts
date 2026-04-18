use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde_json::{json, Map, Value};
use vmctl_backend::{
    ApplyResult, BackendPlan, BackendValidation, EngineBackend, PlanMode, RenderResult,
    TargetSelector,
};
use vmctl_domain::{DesiredState, NormalizedResource, Resource, Workspace};
use vmctl_packs::PackRegistry;

#[derive(Debug, Default)]
pub struct TerraformBackend;

impl TerraformBackend {
    pub fn render_for_plan(
        &self,
        workspace: &Workspace,
        desired: &DesiredState,
        registry: &PackRegistry,
        mode: PlanMode,
    ) -> Result<RenderResult> {
        render_workspace(workspace, desired, registry, mode == PlanMode::Online)
    }
}

impl EngineBackend for TerraformBackend {
    fn validate_backend(&self, _workspace: &Workspace) -> Result<()> {
        if vmctl_util::command_exists("tofu") || vmctl_util::command_exists("terraform") {
            println!("backend: terraform");
            println!("binary: found tofu/terraform");
        } else {
            println!("backend: terraform");
            println!("binary: missing tofu/terraform");
        }
        Ok(())
    }

    fn render(
        &self,
        workspace: &Workspace,
        desired: &DesiredState,
        registry: &PackRegistry,
    ) -> Result<RenderResult> {
        render_workspace(workspace, desired, registry, true)
    }

    fn plan(
        &self,
        workspace: &Workspace,
        _desired: &DesiredState,
        mode: PlanMode,
    ) -> Result<BackendPlan> {
        run_terraform(workspace, &["init", "-input=false"])?;
        if mode == PlanMode::DryRun {
            run_terraform(workspace, &["validate", "-no-color"])?;
        }
        let output = match mode {
            PlanMode::Online => run_terraform(workspace, &["plan", "-input=false", "-no-color"])?,
            PlanMode::DryRun => run_terraform(
                workspace,
                &["plan", "-refresh=false", "-input=false", "-no-color"],
            )?,
        };
        Ok(BackendPlan {
            summary: output_summary(
                match mode {
                    PlanMode::Online => "terraform plan",
                    PlanMode::DryRun => "terraform dry-run plan",
                },
                &output,
            ),
        })
    }

    fn validate_rendered(&self, workspace: &Workspace) -> Result<BackendValidation> {
        run_terraform(workspace, &["init", "-input=false"])?;
        let output = run_terraform(workspace, &["validate", "-no-color"])?;
        Ok(BackendValidation {
            summary: output_summary("terraform validate", &output),
        })
    }

    fn apply(
        &self,
        workspace: &Workspace,
        desired: &DesiredState,
        registry: &PackRegistry,
    ) -> Result<ApplyResult> {
        self.render(workspace, desired, registry)?;
        run_terraform(workspace, &["init", "-input=false"])?;
        let output = run_terraform(
            workspace,
            &["apply", "-auto-approve", "-input=false", "-no-color"],
        )?;
        Ok(ApplyResult {
            summary: output_summary("terraform apply", &output),
        })
    }

    fn destroy(&self, workspace: &Workspace, target: &TargetSelector) -> Result<ApplyResult> {
        run_terraform(workspace, &["init", "-input=false"])?;
        let target_arg = format!("-target=module.{}", target.name.replace('-', "_"));
        let output = run_terraform(
            workspace,
            &[
                "destroy",
                "-auto-approve",
                "-input=false",
                "-no-color",
                &target_arg,
            ],
        )?;
        Ok(ApplyResult {
            summary: output_summary("terraform destroy", &output),
        })
    }
}

fn render_workspace(
    workspace: &Workspace,
    desired: &DesiredState,
    registry: &PackRegistry,
    include_proxmox_resources: bool,
) -> Result<RenderResult> {
    let generated = workspace.root.join(&workspace.generated_dir);
    if generated.exists() {
        std::fs::remove_dir_all(&generated)?;
    }
    std::fs::create_dir_all(&generated)?;

    let mut files = Vec::new();
    write_json(
        &generated.join("desired-state.json"),
        &redacted_value(json!(desired)),
        &mut files,
    )?;
    write_json(
        &generated.join("terraform.tfvars.json"),
        &redacted_value(json!({
            "backend": desired.backend,
            "resources": desired.resources,
            "normalized_resources": desired.normalized_resources,
            "expansions": desired.expansions,
        })),
        &mut files,
    )?;
    write_json(
        &generated.join("variables.tf.json"),
        &variables_json(),
        &mut files,
    )?;
    if include_proxmox_resources {
        write_json(
            &generated.join("provider.tf.json"),
            &provider_json(desired),
            &mut files,
        )?;
    } else {
        let marker = generated.join("DRY_RUN_VALIDATION_ONLY.txt");
        std::fs::write(
            &marker,
            "This workspace was rendered for vmctl backend plan --dry-run.\nIt intentionally omits live Proxmox provider resources and must not be applied.\n",
        )?;
        files.push(marker);
    }
    write_json(
        &generated.join("main.tf.json"),
        &main_json(desired),
        &mut files,
    )?;
    write_json(
        &generated.join("outputs.tf.json"),
        &outputs_json(),
        &mut files,
    )?;
    files.extend(write_base_modules(&generated, include_proxmox_resources)?);

    files.extend(registry.render_artifacts(&generated, &desired.resources, &desired.expansions)?);

    Ok(RenderResult {
        summary: format!("rendered {} files to {}", files.len(), generated.display()),
        files,
    })
}

fn write_json<T: serde::Serialize>(
    path: &PathBuf,
    value: &T,
    files: &mut Vec<PathBuf>,
) -> Result<()> {
    std::fs::write(path, serde_json::to_string_pretty(value)?)?;
    files.push(path.clone());
    Ok(())
}

fn variables_json() -> serde_json::Value {
    json!({
        "variable": {
            "backend": {
                "type": "any",
                "description": "Resolved vmctl backend configuration."
            },
            "resources": {
                "type": "any",
                "description": "Normalized vmctl resources."
            },
            "expansions": {
                "type": "any",
                "description": "Expanded pack outputs keyed by resource name."
            },
            "normalized_resources": {
                "type": "any",
                "description": "Normalized vmctl resources keyed by resource name."
            },
            "proxmox_api_token": {
                "type": "string",
                "description": "Proxmox API token in USER@REALM!TOKENID=SECRET format. Prefer TF_VAR_proxmox_api_token.",
                "sensitive": true,
                "nullable": true,
                "default": null
            }
        }
    })
}

fn provider_json(desired: &DesiredState) -> serde_json::Value {
    let proxmox = desired
        .backend
        .settings
        .get("proxmox")
        .and_then(toml::Value::as_table);
    let endpoint = proxmox
        .and_then(|settings| settings.get("endpoint"))
        .and_then(toml::Value::as_str)
        .unwrap_or("");
    let tls_insecure = proxmox
        .and_then(|settings| settings.get("tls_insecure"))
        .and_then(toml::Value::as_bool)
        .unwrap_or(false);

    json!({
        "terraform": {
            "required_providers": {
                "proxmox": {
                    "source": "bpg/proxmox",
                    "version": ">= 0.70.0"
                }
            }
        },
        "provider": {
            "proxmox": {
                "endpoint": endpoint,
                "api_token": "${var.proxmox_api_token}",
                "insecure": tls_insecure
            }
        }
    })
}

fn main_json(desired: &DesiredState) -> serde_json::Value {
    let mut modules = Map::new();
    for resource in &desired.resources {
        modules.insert(module_name(resource), module_json(resource, desired));
    }

    json!({
        "terraform": {
            "required_version": ">= 1.6.0"
        },
        "locals": {
            "vmctl_resource_names": "${[for resource in var.resources : resource.name]}",
            "vmctl_resource_count": "${length(var.resources)}"
        },
        "module": modules
    })
}

fn outputs_json() -> serde_json::Value {
    json!({
        "output": {
            "vmctl_resource_names": {
                "description": "Resource names compiled by vmctl.",
                "value": "${local.vmctl_resource_names}"
            },
            "vmctl_resource_count": {
                "description": "Number of resources compiled by vmctl.",
                "value": "${local.vmctl_resource_count}"
            }
        }
    })
}

fn module_json(resource: &Resource, desired: &DesiredState) -> Value {
    let normalized = desired.normalized_resources.get(&resource.name);
    let module_resource = normalized
        .cloned()
        .unwrap_or_else(|| normalize_fallback(resource));
    let mut module = Map::new();
    module.insert(
        "source".to_string(),
        Value::String(format!("./modules/{}", resource.kind)),
    );
    module.insert(
        "resource".to_string(),
        redacted_value(json!(module_resource)),
    );
    module.insert(
        "node_name".to_string(),
        normalized
            .and_then(|resource| resource.node.clone())
            .map(Value::String)
            .or_else(|| backend_proxmox_string(desired, "node"))
            .unwrap_or_else(|| Value::String(String::new())),
    );
    module.insert(
        "bridge".to_string(),
        normalized
            .and_then(|resource| resource.bridge.clone())
            .map(Value::String)
            .unwrap_or_else(|| Value::String(String::new())),
    );
    module.insert(
        "storage".to_string(),
        normalized
            .and_then(|resource| resource.storage.clone())
            .map(Value::String)
            .unwrap_or_else(|| Value::String(String::new())),
    );
    module.insert(
        "template".to_string(),
        normalized
            .and_then(|resource| resource.template.clone())
            .map(Value::String)
            .unwrap_or_else(|| Value::String(String::new())),
    );

    let depends_on = resource
        .depends_on
        .iter()
        .map(|dependency| format!("module.{}", sanitize_module_name(dependency)))
        .collect::<Vec<_>>();
    if !depends_on.is_empty() {
        module.insert("depends_on".to_string(), json!(depends_on));
    }

    Value::Object(module)
}

fn write_base_modules(generated: &Path, include_proxmox_resources: bool) -> Result<Vec<PathBuf>> {
    let modules_dir = generated.join("modules");
    let mut files = Vec::new();
    for kind in ["vm", "lxc"] {
        let module_dir = modules_dir.join(kind);
        std::fs::create_dir_all(&module_dir)?;
        write_json(
            &module_dir.join("variables.tf.json"),
            &base_module_variables_json(kind),
            &mut files,
        )?;
        write_json(
            &module_dir.join("main.tf.json"),
            &base_module_main_json(kind, include_proxmox_resources),
            &mut files,
        )?;
        write_json(
            &module_dir.join("outputs.tf.json"),
            &base_module_outputs_json(kind),
            &mut files,
        )?;
    }
    Ok(files)
}

fn base_module_variables_json(kind: &str) -> Value {
    json!({
        "variable": {
            "resource": {
                "type": "any",
                "description": format!("Normalized vmctl {kind} resource.")
            },
            "node_name": {
                "type": "string",
                "description": "Resolved Proxmox node name for this resource."
            },
            "bridge": {
                "type": "string",
                "description": "Resolved Proxmox bridge for this resource."
            },
            "storage": {
                "type": "string",
                "description": "Resolved Proxmox storage for this resource."
            },
            "template": {
                "type": "string",
                "description": "Resolved template or image identifier for this resource."
            },
            "proxmox_resource_enabled": {
                "type": "bool",
                "description": "Whether this generated module should create Proxmox provider resources.",
                "default": true
            }
        }
    })
}

fn base_module_main_json(kind: &str, include_proxmox_resources: bool) -> Value {
    let proxmox_resource = if include_proxmox_resources {
        match kind {
            "vm" => Some(vm_resource_json()),
            "lxc" => Some(lxc_resource_json()),
            _ => None,
        }
    } else {
        None
    };

    let mut resources = Map::new();
    if let Some((resource_type, resource_body)) = proxmox_resource {
        resources.insert(resource_type, resource_body);
    }
    resources.insert(
        "terraform_data".to_string(),
        json!({
            "this": {
                "input": {
                    "kind": kind,
                    "name": "${var.resource.name}",
                    "vmid": "${try(var.resource.vmid, null)}",
                    "node_name": "${var.node_name}",
                    "bridge": "${var.bridge}",
                    "storage": "${var.storage}",
                    "template": "${var.template}",
                    "resource": "${var.resource}"
                }
            }
        }),
    );

    json!({
        "terraform": {
            "required_providers": {
                "proxmox": {
                    "source": "bpg/proxmox",
                    "version": ">= 0.70.0"
                }
            }
        },
        "resource": resources
    })
}

fn vm_resource_json() -> (String, Value) {
    (
        "proxmox_virtual_environment_vm".to_string(),
        json!({
            "this": {
                "count": "${var.proxmox_resource_enabled ? 1 : 0}",
                "name": "${var.resource.name}",
                "node_name": "${var.node_name}",
                "vm_id": "${try(var.resource.vmid, null)}",
                "started": "${try(var.resource.start_on_boot, true)}",
                "agent": [{
                    "enabled": "${try(var.resource.agent, true)}"
                }],
                "cpu": [{
                    "cores": "${try(var.resource.cores, 1)}",
                    "type": "host"
                }],
                "memory": [{
                    "dedicated": "${try(var.resource.memory, 1024)}"
                }],
                "disk": [{
                    "datastore_id": "${var.storage}",
                    "interface": "scsi0",
                    "size": "${try(var.resource.disk_gb, 8)}"
                }],
                "network_device": [{
                    "bridge": "${var.bridge}",
                    "disconnected": false,
                    "enabled": true,
                    "firewall": false,
                    "mac_address": "${try(var.resource.network.mac, null)}",
                    "model": "virtio",
                    "mtu": 0,
                    "queues": 0,
                    "rate_limit": 0,
                    "trunks": "",
                    "vlan_id": null
                }],
                "dynamic": {
                    "clone": {
                        "for_each": "${can(tonumber(var.template)) ? [tonumber(var.template)] : []}",
                        "content": {
                            "vm_id": "${clone.value}",
                            "full": true
                        }
                    },
                    "initialization": {
                        "for_each": "${try(var.resource.cloud_init, null) == null && try(var.resource.network, null) == null ? [] : [1]}",
                        "content": {
                            "user_account": [{
                                "username": "${try(var.resource.cloud_init.user, null)}",
                                "keys": "${try(var.resource.cloud_init.ssh_key_file, null) == null ? [] : [file(var.resource.cloud_init.ssh_key_file)]}"
                            }],
                            "ip_config": [{
                                "ipv4": [{
                                    "address": "${try(var.resource.network.mode, \"dhcp\") == \"dhcp\" ? \"dhcp\" : try(var.resource.network.address, \"dhcp\")}"
                                }]
                            }]
                        }
                    }
                }
            }
        }),
    )
}

fn lxc_resource_json() -> (String, Value) {
    (
        "proxmox_virtual_environment_container".to_string(),
        json!({
            "this": {
                "count": "${var.proxmox_resource_enabled ? 1 : 0}",
                "description": "managed by vmctl",
                "node_name": "${var.node_name}",
                "vm_id": "${try(var.resource.vmid, null)}",
                "started": "${try(var.resource.start_on_boot, true)}",
                "unprivileged": true,
                "initialization": [{
                    "hostname": "${var.resource.name}",
                    "ip_config": [{
                        "ipv4": [{
                            "address": "${try(var.resource.network.mode, \"dhcp\") == \"dhcp\" ? \"dhcp\" : try(var.resource.network.address, \"dhcp\")}"
                        }]
                    }]
                }],
                "network_interface": [{
                    "name": "veth0",
                    "bridge": "${var.bridge}",
                    "mac_address": "${try(var.resource.network.mac, null)}"
                }],
                "disk": [{
                    "datastore_id": "${var.storage}",
                    "size": "${try(var.resource.rootfs_gb, 8)}"
                }],
                "operating_system": [{
                    "template_file_id": "${var.template}",
                    "type": "debian"
                }]
            }
        }),
    )
}

fn base_module_outputs_json(kind: &str) -> Value {
    json!({
        "output": {
            "name": {
                "description": format!("Rendered vmctl {kind} resource name."),
                "value": "${var.resource.name}"
            },
            "vmid": {
                "description": format!("Rendered vmctl {kind} resource VMID."),
                "value": "${try(var.resource.vmid, null)}"
            }
        }
    })
}

fn module_name(resource: &Resource) -> String {
    sanitize_module_name(&resource.name)
}

fn backend_proxmox_string(desired: &DesiredState, key: &str) -> Option<Value> {
    desired
        .backend
        .settings
        .get("proxmox")
        .and_then(toml::Value::as_table)
        .and_then(|settings| settings.get(key))
        .and_then(toml::Value::as_str)
        .map(|value| Value::String(value.to_string()))
}

fn normalize_fallback(resource: &Resource) -> NormalizedResource {
    NormalizedResource {
        name: resource.name.clone(),
        kind: resource.kind.clone(),
        role: resource.role.clone(),
        vmid: resource.vmid,
        depends_on: resource.depends_on.clone(),
        features: resource.features.clone(),
        ..NormalizedResource::default()
    }
}

fn redacted_value(value: Value) -> Value {
    match value {
        Value::Object(object) => Value::Object(
            object
                .into_iter()
                .map(|(key, value)| {
                    if is_secret_key(&key) {
                        (key, Value::String("<redacted>".to_string()))
                    } else {
                        (key, redacted_value(value))
                    }
                })
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.into_iter().map(redacted_value).collect()),
        other => other,
    }
}

fn is_secret_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    key.contains("secret") || key.contains("token") || key.contains("auth_key")
}

fn sanitize_module_name(name: &str) -> String {
    name.chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == '_' {
                ch
            } else {
                '_'
            }
        })
        .collect()
}

#[allow(dead_code)]
fn module_names_by_resource(resources: &[Resource]) -> BTreeMap<String, String> {
    resources
        .iter()
        .map(|resource| (resource.name.clone(), module_name(resource)))
        .collect()
}

fn terraform_binary() -> Result<&'static str> {
    if vmctl_util::command_exists("tofu") {
        Ok("tofu")
    } else if vmctl_util::command_exists("terraform") {
        Ok("terraform")
    } else {
        bail!("missing Terraform backend binary; install `tofu` or `terraform`")
    }
}

fn run_terraform(workspace: &Workspace, args: &[&str]) -> Result<String> {
    let binary = terraform_binary()?;
    let generated = workspace.root.join(&workspace.generated_dir);
    let output = std::process::Command::new(binary)
        .args(args)
        .current_dir(&generated)
        .output()
        .with_context(|| format!("failed to run `{binary} {}`", args.join(" ")))?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = if stderr.trim().is_empty() {
        stdout.to_string()
    } else {
        format!("{stdout}\n{stderr}")
    };

    if !output.status.success() {
        bail!("`{binary} {}` failed:\n{combined}", args.join(" "));
    }

    Ok(combined)
}

fn output_summary(prefix: &str, output: &str) -> String {
    let tail = output
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("completed");
    format!("{prefix}: {tail}")
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use vmctl_domain::{BackendConfig, DesiredState};

    #[test]
    fn renders_module_blocks_for_resources_and_dependencies() {
        let desired = DesiredState {
            backend: BackendConfig::default(),
            resources: vec![
                Resource {
                    name: "gateway".to_string(),
                    kind: "lxc".to_string(),
                    role: None,
                    vmid: Some(101),
                    depends_on: Vec::new(),
                    features: BTreeMap::new(),
                    settings: BTreeMap::new(),
                },
                Resource {
                    name: "media-stack".to_string(),
                    kind: "vm".to_string(),
                    role: None,
                    vmid: Some(210),
                    depends_on: vec!["gateway".to_string()],
                    features: BTreeMap::new(),
                    settings: BTreeMap::new(),
                },
            ],
            normalized_resources: BTreeMap::new(),
            expansions: BTreeMap::new(),
        };

        let rendered = main_json(&desired);
        let modules = rendered.get("module").and_then(Value::as_object).unwrap();

        assert_eq!(modules["gateway"]["source"], "./modules/lxc");
        assert_eq!(modules["media_stack"]["source"], "./modules/vm");
        assert_eq!(modules["media_stack"]["depends_on"][0], "module.gateway");
    }

    #[test]
    fn renders_provider_and_module_inputs() {
        let desired = DesiredState {
            backend: BackendConfig {
                kind: "terraform".to_string(),
                settings: BTreeMap::from([(
                    "proxmox".to_string(),
                    toml::Value::Table(toml::map::Map::from_iter([
                        (
                            "endpoint".to_string(),
                            toml::Value::String("https://mini:8006/api2/json".to_string()),
                        ),
                        ("node".to_string(), toml::Value::String("mini".to_string())),
                        (
                            "token_id".to_string(),
                            toml::Value::String("root@pam!vmctl".to_string()),
                        ),
                        (
                            "token_secret".to_string(),
                            toml::Value::String("secret".to_string()),
                        ),
                        ("tls_insecure".to_string(), toml::Value::Boolean(true)),
                    ])),
                )]),
            },
            resources: vec![Resource {
                name: "media-stack".to_string(),
                kind: "vm".to_string(),
                role: None,
                vmid: Some(210),
                depends_on: Vec::new(),
                features: BTreeMap::new(),
                settings: BTreeMap::from([
                    (
                        "bridge".to_string(),
                        toml::Value::String("vmbr0".to_string()),
                    ),
                    (
                        "storage".to_string(),
                        toml::Value::String("local-lvm".to_string()),
                    ),
                    (
                        "template".to_string(),
                        toml::Value::String("ubuntu-template".to_string()),
                    ),
                ]),
            }],
            normalized_resources: BTreeMap::from([(
                "media-stack".to_string(),
                NormalizedResource {
                    name: "media-stack".to_string(),
                    kind: "vm".to_string(),
                    vmid: Some(210),
                    node: Some("mini".to_string()),
                    bridge: Some("vmbr0".to_string()),
                    storage: Some("local-lvm".to_string()),
                    template: Some("ubuntu-template".to_string()),
                    ..NormalizedResource::default()
                },
            )]),
            expansions: BTreeMap::new(),
        };

        let provider = provider_json(&desired);
        let rendered = main_json(&desired);
        let module = &rendered["module"]["media_stack"];

        assert_eq!(
            provider["provider"]["proxmox"]["endpoint"],
            "https://mini:8006/api2/json"
        );
        assert_eq!(
            provider["provider"]["proxmox"]["api_token"],
            "${var.proxmox_api_token}"
        );
        assert_eq!(module["node_name"], "mini");
        assert_eq!(module["bridge"], "vmbr0");
        assert_eq!(module["storage"], "local-lvm");
        assert_eq!(module["template"], "ubuntu-template");
    }

    #[test]
    fn render_writes_redacted_snapshot_artifacts() {
        let root = unique_temp_dir();
        std::fs::create_dir_all(&root).unwrap();
        let workspace = Workspace {
            root: root.clone(),
            generated_dir: PathBuf::from("generated"),
        };
        let desired = DesiredState {
            backend: BackendConfig {
                kind: "terraform".to_string(),
                settings: BTreeMap::from([(
                    "proxmox".to_string(),
                    toml::Value::Table(toml::map::Map::from_iter([
                        (
                            "endpoint".to_string(),
                            toml::Value::String("https://mini:8006/api2/json".to_string()),
                        ),
                        ("node".to_string(), toml::Value::String("mini".to_string())),
                        (
                            "token_secret".to_string(),
                            toml::Value::String("super-secret".to_string()),
                        ),
                    ])),
                )]),
            },
            resources: vec![Resource {
                name: "media-stack".to_string(),
                kind: "vm".to_string(),
                role: None,
                vmid: Some(210),
                depends_on: Vec::new(),
                features: BTreeMap::from([(
                    "tailscale".to_string(),
                    toml::Value::Table(toml::map::Map::from_iter([(
                        "auth_key".to_string(),
                        toml::Value::String("tskey-secret".to_string()),
                    )])),
                )]),
                settings: BTreeMap::new(),
            }],
            normalized_resources: BTreeMap::from([(
                "media-stack".to_string(),
                NormalizedResource {
                    name: "media-stack".to_string(),
                    kind: "vm".to_string(),
                    vmid: Some(210),
                    node: Some("mini".to_string()),
                    bridge: Some("vmbr0".to_string()),
                    storage: Some("local-lvm".to_string()),
                    template: Some("9000".to_string()),
                    ..NormalizedResource::default()
                },
            )]),
            expansions: BTreeMap::new(),
        };

        TerraformBackend
            .render(&workspace, &desired, &PackRegistry::default())
            .unwrap();

        let main = std::fs::read_to_string(root.join("generated/modules/vm/main.tf.json")).unwrap();
        let provider = std::fs::read_to_string(root.join("generated/provider.tf.json")).unwrap();
        let state = std::fs::read_to_string(root.join("generated/desired-state.json")).unwrap();

        assert!(main.contains("proxmox_virtual_environment_vm"));
        assert!(provider.contains("${var.proxmox_api_token}"));
        assert!(!provider.contains("super-secret"));
        assert!(!state.contains("tskey-secret"));

        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn vm_module_matches_fixture() {
        let expected: Value =
            serde_json::from_str(include_str!("../tests/fixtures/vm-module-main.tf.json")).unwrap();
        assert_eq!(base_module_main_json("vm", true), expected);
    }

    #[test]
    fn lxc_module_matches_fixture() {
        let expected: Value =
            serde_json::from_str(include_str!("../tests/fixtures/lxc-module-main.tf.json"))
                .unwrap();
        assert_eq!(base_module_main_json("lxc", true), expected);
    }

    fn unique_temp_dir() -> PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!(
            "vmctl-backend-terraform-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        dir
    }
}
