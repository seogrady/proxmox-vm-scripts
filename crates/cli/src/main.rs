use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use vmctl_backend::{EngineBackend, PlanMode, TargetSelector};
use vmctl_backend_terraform::TerraformBackend;
use vmctl_config::{resolve_config_path, Config};
use vmctl_dependencies::{backend_kind, CommandScope, DependencyPlan};
use vmctl_domain::{DesiredState, ImageKind, ImageSource, ResolvedImage, Workspace};
use vmctl_lockfile::Lockfile;
use vmctl_packs::PackRegistry;

#[derive(Debug, Parser)]
#[command(name = "vmctl", version, about = "Declarative Proxmox homelab manager")]
struct Cli {
    #[arg(short, long)]
    config: Option<PathBuf>,

    #[arg(long, default_value = "packs")]
    packs: PathBuf,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Init,
    Validate,
    Plan {
        target: Option<String>,
    },
    Apply {
        #[arg(long)]
        auto_approve: bool,
        #[arg(long)]
        skip_provision: bool,
        #[arg(long)]
        no_image_ensure: bool,
        target: Option<String>,
    },
    Up {
        #[arg(long)]
        auto_approve: bool,
        #[arg(long)]
        skip_provision: bool,
        #[arg(long)]
        no_image_ensure: bool,
        target: Option<String>,
    },
    Destroy {
        #[arg(long)]
        auto_approve: bool,
        target: String,
    },
    Import,
    Sync,
    Provision {
        target: Option<String>,
    },
    Backend {
        #[command(subcommand)]
        command: BackendCommand,
    },
    Images {
        #[command(subcommand)]
        command: ImagesCommand,
    },
}

#[derive(Debug, Subcommand)]
enum BackendCommand {
    Doctor,
    Plan {
        #[arg(long)]
        dry_run: bool,
        target: Option<String>,
    },
    Render,
    ShowState,
    Validate {
        #[arg(long)]
        live: bool,
    },
}

#[derive(Debug, Subcommand)]
enum ImagesCommand {
    List,
    Plan,
    Ensure {
        #[arg(long)]
        dry_run: bool,
        image: Option<String>,
    },
    Doctor,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Init => init_workspace(cli.config.as_deref(), &cli.packs),
        Command::Validate => {
            let (_workspace, desired, _registry) =
                load_workspace(cli.config.as_deref(), &cli.packs, None)?;
            check_dependencies(&desired, CommandScope::ValidateConfig)?;
            println!(
                "valid: {} resources, {} expanded roles",
                desired.resources.len(),
                desired.expansions.len()
            );
            Ok(())
        }
        Command::Plan { target } => {
            let (_workspace, desired, _registry) =
                load_workspace(cli.config.as_deref(), &cli.packs, target.as_deref())?;
            check_dependencies(&desired, CommandScope::ValidateConfig)?;
            print!("{}", vmctl_render::render_plan(&desired));
            Ok(())
        }
        Command::Apply {
            auto_approve,
            skip_provision,
            no_image_ensure,
            target,
        } => apply_command(
            cli.config.as_deref(),
            &cli.packs,
            auto_approve,
            skip_provision,
            no_image_ensure,
            target.as_deref(),
            "apply",
        ),
        Command::Up {
            auto_approve,
            skip_provision,
            no_image_ensure,
            target,
        } => apply_command(
            cli.config.as_deref(),
            &cli.packs,
            auto_approve,
            skip_provision,
            no_image_ensure,
            target.as_deref(),
            "up",
        ),
        Command::Destroy {
            auto_approve,
            target,
        } => {
            require_auto_approve(auto_approve, "destroy")?;
            let (workspace, desired, _registry) =
                load_workspace(cli.config.as_deref(), &cli.packs, None)?;
            check_dependencies(&desired, CommandScope::Destroy)?;
            let result = TerraformBackend.destroy(&workspace, &TargetSelector { name: target })?;
            println!("{}", result.summary);
            Ok(())
        }
        Command::Import => {
            let (workspace, desired, _registry) =
                load_workspace(cli.config.as_deref(), &cli.packs, None)?;
            let lockfile_path = workspace.root.join("vmctl.lock");
            let lockfile = ensure_lockfile(&workspace, &desired)?;
            print!("{}", vmctl_import::summarize_lockfile(&lockfile_path)?);
            let state_path = workspace
                .root
                .join(&workspace.generated_dir)
                .join("terraform.tfstate");
            if state_path.exists() {
                print!(
                    "{}",
                    vmctl_import::summarize_terraform_state_with_lockfile(
                        &state_path,
                        Some(&lockfile)
                    )?
                );
            }
            Ok(())
        }
        Command::Sync => {
            let (workspace, desired, _registry) =
                load_workspace(cli.config.as_deref(), &cli.packs, None)?;
            let lockfile = ensure_lockfile(&workspace, &desired)?;
            let summary = vmctl_import::compare_desired_to_lockfile(&desired, &lockfile);
            print!("{}", vmctl_import::render_sync_summary(&summary));
            Ok(())
        }
        Command::Provision { target } => {
            let (workspace, desired, registry) =
                load_workspace(cli.config.as_deref(), &cli.packs, target.as_deref())?;
            check_dependencies(&desired, CommandScope::Provision)?;
            TerraformBackend.render(&workspace, &desired, &registry)?;
            let result = run_provision(&workspace, &desired)?;
            println!("{}", result.summary);
            Ok(())
        }
        Command::Backend { command } => match command {
            BackendCommand::Doctor => {
                let (workspace, desired, _registry) =
                    load_workspace(cli.config.as_deref(), &cli.packs, None)?;
                check_dependencies(&desired, CommandScope::Doctor)?;
                TerraformBackend.validate_backend(&workspace)
            }
            BackendCommand::Plan { dry_run, target } => {
                let (workspace, desired, registry) =
                    load_workspace(cli.config.as_deref(), &cli.packs, target.as_deref())?;
                check_dependencies(&desired, CommandScope::Plan { dry_run })?;
                TerraformBackend.render_for_plan(
                    &workspace,
                    &desired,
                    &registry,
                    if dry_run {
                        PlanMode::DryRun
                    } else {
                        PlanMode::Online
                    },
                )?;
                let result = TerraformBackend.plan(
                    &workspace,
                    &desired,
                    if dry_run {
                        PlanMode::DryRun
                    } else {
                        PlanMode::Online
                    },
                )?;
                println!("{}", result.summary);
                Ok(())
            }
            BackendCommand::Render => {
                let (workspace, desired, registry) =
                    load_workspace(cli.config.as_deref(), &cli.packs, None)?;
                check_dependencies(&desired, CommandScope::Render)?;
                let result = TerraformBackend.render(&workspace, &desired, &registry)?;
                let lockfile = Lockfile::from_desired_with_artifacts(
                    &desired,
                    &workspace.root.join(&workspace.generated_dir),
                    &result.files,
                )?;
                lockfile.write_to_path(&workspace.root.join("vmctl.lock"))?;
                println!("{}; wrote vmctl.lock", result.summary);
                Ok(())
            }
            BackendCommand::ShowState => show_backend_state(&default_workspace()?),
            BackendCommand::Validate { live } => {
                let (workspace, desired, registry) =
                    load_workspace(cli.config.as_deref(), &cli.packs, None)?;
                check_dependencies(&desired, CommandScope::ValidateRendered { live })?;
                TerraformBackend.render_for_plan(
                    &workspace,
                    &desired,
                    &registry,
                    if live {
                        PlanMode::Online
                    } else {
                        PlanMode::DryRun
                    },
                )?;
                let result = TerraformBackend.validate_rendered(&workspace)?;
                println!("{}", result.summary);
                Ok(())
            }
        },
        Command::Images { command } => {
            let (_workspace, desired, _registry) =
                load_workspace(cli.config.as_deref(), &cli.packs, None)?;
            match command {
                ImagesCommand::List => {
                    print!("{}", render_images_list(&desired));
                    Ok(())
                }
                ImagesCommand::Plan => {
                    print!("{}", render_images_plan(&desired));
                    Ok(())
                }
                ImagesCommand::Ensure { dry_run, image } => {
                    ensure_images(&desired, image.as_deref(), dry_run)
                }
                ImagesCommand::Doctor => {
                    print!("{}", render_images_plan(&desired));
                    Ok(())
                }
            }
        }
    }
}

fn apply_command(
    config_path: Option<&Path>,
    packs_path: &Path,
    _auto_approve: bool,
    skip_provision: bool,
    no_image_ensure: bool,
    target: Option<&str>,
    _command: &str,
) -> Result<()> {
    let (workspace, desired, registry) = load_workspace(config_path, packs_path, target)?;
    check_dependencies(&desired, CommandScope::Apply)?;
    if !skip_provision {
        check_dependencies(&desired, CommandScope::Provision)?;
    }

    println!("config: valid");
    if no_image_ensure {
        eprintln!("warning: skipping image ensure; missing images may fail during apply");
    } else {
        ensure_images(&desired, None, false)?;
    }

    let validation = validate_live_backend(&workspace, &desired, &registry)?;
    println!("{}", validation.summary);

    let result = TerraformBackend.apply(&workspace, &desired, &registry)?;
    write_lockfile(&workspace, &desired)?;
    println!("{}; wrote vmctl.lock", result.summary);
    if !skip_provision {
        let result = run_provision(&workspace, &desired)?;
        println!("{}", result.summary);
    }
    Ok(())
}

fn validate_live_backend(
    workspace: &Workspace,
    desired: &DesiredState,
    registry: &PackRegistry,
) -> Result<vmctl_backend::BackendValidation> {
    TerraformBackend.render_for_plan(workspace, desired, registry, PlanMode::Online)?;
    TerraformBackend.validate_rendered(workspace)
}

fn render_images_list(desired: &DesiredState) -> String {
    let mut output = String::new();
    for image in desired.images.values() {
        output.push_str(&format!(
            "{}\tkind={:?}\tsource={:?}\tnode={}\tstorage={}\tcontent_type={}\tvolume_id={}\tstatus={}\n",
            image.name,
            image.kind,
            image.source,
            image.node,
            image.storage,
            image.content_type,
            image.volume_id,
            image_status_label(image)
        ));
    }
    if output.is_empty() {
        output.push_str("no images configured\n");
    }
    output
}

fn render_images_plan(desired: &DesiredState) -> String {
    let mut output = String::new();
    let required = required_image_names(desired);
    for image in desired.images.values() {
        let required_label = if required.contains(&image.name) {
            "required"
        } else {
            "unused"
        };
        let action = match (image.source, image.kind) {
            (ImageSource::Pveam, _) => format!(
                "ensure pveam template with `pveam download {} {}` if missing",
                image.storage, image.file_name
            ),
            (ImageSource::Url, _) => {
                "render provider download resource during backend render/apply".to_string()
            }
            (ImageSource::Existing, ImageKind::Vm) => image
                .vmid
                .map(|vmid| format!("validate existing VM/template with `qm status {vmid}`"))
                .unwrap_or_else(|| "validate existing VM/template before apply".to_string()),
            (ImageSource::Existing, ImageKind::Lxc) => {
                "validate existing Proxmox volume before apply".to_string()
            }
        };
        output.push_str(&format!(
            "{}\t{}\tstatus={}\taction={}\n",
            image.name,
            required_label,
            image_status_label(image),
            action
        ));
    }
    if output.is_empty() {
        output.push_str("no images configured\n");
    }
    output
}

fn ensure_images(desired: &DesiredState, selected: Option<&str>, dry_run: bool) -> Result<()> {
    let required = required_image_names(desired);
    for image in desired.images.values() {
        if let Some(selected) = selected {
            if image.name != selected {
                continue;
            }
        } else if !required.contains(&image.name) {
            continue;
        }
        ensure_image(image, dry_run)?;
    }
    if let Some(selected) = selected {
        if !desired.images.contains_key(selected) {
            bail!("image `{selected}` is not configured");
        }
    }
    Ok(())
}

fn ensure_image(image: &ResolvedImage, dry_run: bool) -> Result<()> {
    match image.source {
        ImageSource::Pveam => ensure_pveam_image(image, dry_run),
        ImageSource::Existing => ensure_existing_image(image, dry_run),
        ImageSource::Url => {
            println!(
                "image `{}` is provider-managed; backend apply will download {}",
                image.name, image.volume_id
            );
            Ok(())
        }
    }
}

fn ensure_pveam_image(image: &ResolvedImage, dry_run: bool) -> Result<()> {
    if image_is_present_with("pveam", &["list", &image.storage], &image.file_name) {
        println!("image `{}` present: {}", image.name, image.volume_id);
        return Ok(());
    }

    if dry_run {
        println!("pveam update");
        println!("pveam download {} {}", image.storage, image.file_name);
        return Ok(());
    }

    run_command("pveam", &["update"])?;
    run_command_with_context(
        "pveam",
        &["download", &image.storage, &image.file_name],
        &format!(
            "template `{}` is not available from pveam. Run `pveam available --section system | grep {}` on the Proxmox host and update vmctl.toml with the listed template name.",
            image.file_name,
            pveam_template_family(&image.file_name)
        ),
    )?;
    println!("image `{}` ensured: {}", image.name, image.volume_id);
    Ok(())
}

fn ensure_existing_image(image: &ResolvedImage, dry_run: bool) -> Result<()> {
    if image.kind == ImageKind::Vm {
        let vmid = image.vmid.with_context(|| {
            format!(
                "image `{}` is an existing VM image and requires vmid",
                image.name
            )
        })?;
        let vmid = vmid.to_string();
        if dry_run {
            println!("qm status {vmid}");
            return Ok(());
        }
        if command_succeeds("qm", &["status", &vmid]) {
            println!("image `{}` present: VMID {}", image.name, vmid);
            return Ok(());
        }
        bail!(
            "missing image `{}`: expected VM/template with VMID {}. Create the template or configure a different image.",
            image.name,
            vmid
        );
    }

    if dry_run {
        println!(
            "pvesm list {} --content {} | grep {}",
            image.storage, image.content_type, image.file_name
        );
        return Ok(());
    }

    if image_is_present_with(
        "pvesm",
        &["list", &image.storage, "--content", &image.content_type],
        &image.file_name,
    ) {
        println!("image `{}` present: {}", image.name, image.volume_id);
        Ok(())
    } else {
        bail!(
            "missing image `{}`: expected {}. Run `vmctl images ensure {}` or configure a different image.",
            image.name,
            image.volume_id,
            image.name
        );
    }
}

fn image_status_label(image: &ResolvedImage) -> &'static str {
    match image.source {
        ImageSource::Url => "provider-managed",
        ImageSource::Pveam => {
            if image_is_present_with("pveam", &["list", &image.storage], &image.file_name) {
                "present"
            } else {
                "missing"
            }
        }
        ImageSource::Existing => {
            if image.kind == ImageKind::Vm {
                let Some(vmid) = image.vmid else {
                    return "missing-vmid";
                };
                let vmid = vmid.to_string();
                return if command_succeeds("qm", &["status", &vmid]) {
                    "present"
                } else {
                    "missing"
                };
            }
            if image_is_present_with(
                "pvesm",
                &["list", &image.storage, "--content", &image.content_type],
                &image.file_name,
            ) {
                "present"
            } else {
                "missing"
            }
        }
    }
}

fn command_succeeds(command: &str, args: &[&str]) -> bool {
    std::process::Command::new(command)
        .args(args)
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn image_is_present_with(command: &str, args: &[&str], file_name: &str) -> bool {
    std::process::Command::new(command)
        .args(args)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).contains(file_name))
        .unwrap_or(false)
}

fn run_command(command: &str, args: &[&str]) -> Result<()> {
    let status = std::process::Command::new(command)
        .args(args)
        .status()
        .with_context(|| format!("failed to run `{command} {}`", args.join(" ")))?;
    if !status.success() {
        bail!("`{command} {}` failed", args.join(" "));
    }
    Ok(())
}

fn run_command_with_context(command: &str, args: &[&str], help: &str) -> Result<()> {
    let status = std::process::Command::new(command)
        .args(args)
        .status()
        .with_context(|| format!("failed to run `{command} {}`", args.join(" ")))?;
    if !status.success() {
        bail!("`{command} {}` failed: {help}", args.join(" "));
    }
    Ok(())
}

fn pveam_template_family(file_name: &str) -> &str {
    file_name.split('_').next().unwrap_or(file_name)
}

fn required_image_names(desired: &DesiredState) -> BTreeSet<String> {
    desired
        .resources
        .iter()
        .filter_map(|resource| resource.image.clone())
        .collect()
}

fn load_workspace(
    config_path: Option<&Path>,
    packs_path: &Path,
    target: Option<&str>,
) -> Result<(Workspace, DesiredState, PackRegistry)> {
    let workspace = default_workspace()?;
    let config_path = resolve_config_path(config_path)?.path;
    let raw = std::fs::read_to_string(&config_path)
        .with_context(|| format!("failed to read {}", config_path.display()))?;
    let process_env = std::env::vars().collect();
    let config = Config::from_toml(&raw, &process_env)?;
    let registry = PackRegistry::load(packs_path)?;
    let desired = vmctl_planner::build_desired_state(config, &registry, target)?;
    Ok((workspace, desired, registry))
}

fn default_workspace() -> Result<Workspace> {
    Ok(Workspace {
        root: std::env::current_dir().context("failed to read current directory")?,
        generated_dir: PathBuf::from("backend/generated/workspace"),
    })
}

fn init_workspace(config_path: Option<&Path>, packs_path: &Path) -> Result<()> {
    let config_path = config_path.unwrap_or_else(|| Path::new("vmctl.toml"));
    if !config_path.exists() {
        std::fs::write(config_path, include_str!("../../../vmctl.example.toml"))
            .with_context(|| format!("failed to write {}", config_path.display()))?;
    }

    std::fs::create_dir_all(packs_path.join("roles"))?;
    std::fs::create_dir_all(packs_path.join("services"))?;
    std::fs::create_dir_all(packs_path.join("templates"))?;
    std::fs::create_dir_all(packs_path.join("scripts"))?;
    println!("initialized vmctl workspace");
    Ok(())
}

fn check_dependencies(desired: &DesiredState, scope: CommandScope) -> Result<()> {
    DependencyPlan::for_command(backend_kind(&desired.backend.kind), scope).verify(None)
}

fn run_provision(
    workspace: &Workspace,
    desired: &DesiredState,
) -> Result<vmctl_provision::ProvisionResult> {
    let plan = vmctl_provision::build_provision_plan(workspace, desired)?;
    vmctl_provision::run_provision_plan(&plan, &vmctl_provision::SystemSshExecutor)
}

fn ensure_lockfile(workspace: &Workspace, desired: &DesiredState) -> Result<Lockfile> {
    let path = workspace.root.join("vmctl.lock");
    match Lockfile::read_optional_from_path(&path)? {
        Some(lockfile) => Ok(lockfile),
        None => {
            let lockfile = write_lockfile(workspace, desired)?;
            eprintln!("vmctl.lock was missing; regenerated {}", path.display());
            Ok(lockfile)
        }
    }
}

fn write_lockfile(workspace: &Workspace, desired: &DesiredState) -> Result<Lockfile> {
    let generated = workspace.root.join(&workspace.generated_dir);
    let artifacts = if generated.exists() {
        list_absolute_files(&generated)?
    } else {
        Vec::new()
    };
    let mut lockfile = Lockfile::from_desired_with_artifacts(desired, &generated, &artifacts)?;
    let state_path = generated.join("terraform.tfstate");
    if state_path.exists() {
        let reconciliation = vmctl_import::reconcile_terraform_state(&state_path, &lockfile)?;
        let existing = reconciliation
            .matched
            .into_iter()
            .map(|matched| matched.name)
            .collect::<BTreeSet<_>>();
        for resource in &mut lockfile.resources {
            resource.exists = existing.contains(&resource.name);
        }
    }
    lockfile.write_to_path(&workspace.root.join("vmctl.lock"))?;
    Ok(lockfile)
}

fn require_auto_approve(auto_approve: bool, command: &str) -> Result<()> {
    if !auto_approve {
        anyhow::bail!("`vmctl {command}` requires --auto-approve");
    }
    Ok(())
}

fn show_backend_state(workspace: &Workspace) -> Result<()> {
    let generated = workspace.root.join(&workspace.generated_dir);
    if !generated.exists() {
        anyhow::bail!(
            "no generated backend state found at {}; run `vmctl backend render` first",
            generated.display()
        );
    }

    println!("backend generated directory: {}", generated.display());
    for entry in list_files(&generated)? {
        println!("- {}", entry.display());
    }
    Ok(())
}

fn list_files(root: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    collect_files(root, root, &mut files)?;
    files.sort();
    Ok(files)
}

fn list_absolute_files(root: &Path) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    collect_absolute_files(root, &mut files)?;
    files.sort();
    Ok(files)
}

fn collect_absolute_files(dir: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    for entry in
        std::fs::read_dir(dir).with_context(|| format!("failed to read {}", dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if entry.file_type()?.is_dir() {
            collect_absolute_files(&path, files)?;
        } else {
            files.push(path);
        }
    }
    Ok(())
}

fn collect_files(root: &Path, dir: &Path, files: &mut Vec<PathBuf>) -> Result<()> {
    for entry in
        std::fs::read_dir(dir).with_context(|| format!("failed to read {}", dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if entry.file_type()?.is_dir() {
            collect_files(root, &path, files)?;
        } else {
            files.push(path.strip_prefix(root).unwrap_or(&path).to_path_buf());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::*;
    use clap::CommandFactory;
    use vmctl_domain::{BackendConfig, Resource};

    #[test]
    fn backend_validate_accepts_live_flag() {
        Cli::command().debug_assert();
        let cli = Cli::try_parse_from([
            "vmctl",
            "--config",
            "vmctl.example.toml",
            "backend",
            "validate",
            "--live",
        ])
        .unwrap();

        match cli.command {
            Command::Backend {
                command: BackendCommand::Validate { live },
            } => assert!(live),
            other => panic!("unexpected command: {other:?}"),
        }
    }

    #[test]
    fn destroy_requires_auto_approve() {
        let err = require_auto_approve(false, "destroy").unwrap_err();

        assert!(err.to_string().contains("requires --auto-approve"));
        assert!(require_auto_approve(true, "destroy").is_ok());
    }

    #[test]
    fn apply_and_up_accept_default_approval_behavior() {
        Cli::command().debug_assert();
        let apply = Cli::try_parse_from(["vmctl", "apply"]).unwrap();
        let up = Cli::try_parse_from(["vmctl", "up"]).unwrap();

        assert!(matches!(apply.command, Command::Apply { .. }));
        assert!(matches!(up.command, Command::Up { .. }));
    }

    #[test]
    fn write_lockfile_marks_missing_state_resources_absent() {
        let root = unique_temp_dir();
        let generated_dir = PathBuf::from("generated");
        std::fs::create_dir_all(root.join(&generated_dir)).unwrap();
        std::fs::write(
            root.join(&generated_dir).join("terraform.tfstate"),
            r#"{"resources":[]}"#,
        )
        .unwrap();
        let workspace = Workspace {
            root: root.clone(),
            generated_dir,
        };
        let desired = DesiredState {
            backend: BackendConfig::default(),
            images: BTreeMap::new(),
            resources: vec![Resource {
                name: "media-stack".to_string(),
                kind: "vm".to_string(),
                image: None,
                role: None,
                vmid: Some(210),
                depends_on: Vec::new(),
                features: BTreeMap::new(),
                settings: BTreeMap::new(),
            }],
            normalized_resources: BTreeMap::new(),
            expansions: BTreeMap::new(),
        };

        let lockfile = write_lockfile(&workspace, &desired).unwrap();

        assert!(!lockfile.resources[0].exists);

        std::fs::remove_dir_all(root).unwrap();
    }

    fn unique_temp_dir() -> PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!(
            "vmctl-cli-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        dir
    }
}
