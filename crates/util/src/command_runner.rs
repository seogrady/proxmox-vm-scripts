use std::collections::BTreeMap;
use std::fmt;
use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VmctlError {
    ProxmoxTaskError(String),
    QemuError(String),
    CloudInitError(String),
    CommandFailed {
        command: String,
        code: i32,
        stderr: String,
    },
    CommandTimedOut {
        command: String,
        timeout: Duration,
    },
    RetryLimitExceeded {
        command: String,
        attempts: u32,
    },
    RepeatedFailure {
        command: String,
        error: String,
    },
    SpawnFailed {
        command: String,
        error: String,
    },
}

impl fmt::Display for VmctlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            VmctlError::ProxmoxTaskError(message) => write!(f, "Proxmox task failed: {message}"),
            VmctlError::QemuError(message) => write!(f, "QEMU failed: {message}"),
            VmctlError::CloudInitError(message) => write!(f, "cloud-init failed: {message}"),
            VmctlError::CommandFailed {
                command,
                code,
                stderr,
            } => {
                write!(f, "`{command}` failed with exit code {code}")?;
                if !stderr.trim().is_empty() {
                    write!(f, ":\n{}", stderr.trim())?;
                }
                Ok(())
            }
            VmctlError::CommandTimedOut { command, timeout } => {
                write!(f, "`{command}` timed out after {}s", timeout.as_secs())
            }
            VmctlError::RetryLimitExceeded { command, attempts } => {
                write!(
                    f,
                    "`{command}` exceeded retry limit after {attempts} attempts"
                )
            }
            VmctlError::RepeatedFailure { command, error } => {
                write!(f, "`{command}` repeated the same failure: {error}")
            }
            VmctlError::SpawnFailed { command, error } => {
                write!(f, "failed to run `{command}`: {error}")
            }
        }
    }
}

impl std::error::Error for VmctlError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogPrefix {
    Vmctl,
    Proxmox,
    Terraform,
    Ssh,
}

impl LogPrefix {
    fn as_str(self) -> &'static str {
        match self {
            LogPrefix::Vmctl => "vmctl",
            LogPrefix::Proxmox => "proxmox",
            LogPrefix::Terraform => "terraform",
            LogPrefix::Ssh => "ssh",
        }
    }
}

#[derive(Debug, Clone)]
pub struct CommandOptions {
    pub command: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub envs: BTreeMap<String, String>,
    pub timeout: Duration,
    pub prefix: LogPrefix,
    pub stream: bool,
    pub fail_on_proxmox_patterns: bool,
}

impl CommandOptions {
    pub fn new(
        command: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
    ) -> Self {
        Self {
            command: command.into(),
            args: args.into_iter().map(Into::into).collect(),
            cwd: None,
            envs: BTreeMap::new(),
            timeout: Duration::from_secs(600),
            prefix: LogPrefix::Vmctl,
            stream: true,
            fail_on_proxmox_patterns: true,
        }
    }

    pub fn cwd(mut self, cwd: impl Into<PathBuf>) -> Self {
        self.cwd = Some(cwd.into());
        self
    }

    pub fn envs<K, V, I>(mut self, envs: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        self.envs = envs
            .into_iter()
            .map(|(key, value)| (key.into(), value.into()))
            .collect();
        self
    }

    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn prefix(mut self, prefix: LogPrefix) -> Self {
        self.prefix = prefix;
        self
    }

    pub fn stream(mut self, stream: bool) -> Self {
        self.stream = stream;
        self
    }

    pub fn fail_on_proxmox_patterns(mut self, fail: bool) -> Self {
        self.fail_on_proxmox_patterns = fail;
        self
    }

    pub fn display_command(&self) -> String {
        display_command(&self.command, &self.args)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutput {
    pub stdout: String,
    pub stderr: String,
    pub combined: String,
    pub warnings: Vec<String>,
}

pub fn run_command(command: &str, args: &[&str]) -> Result<CommandOutput, VmctlError> {
    run(CommandOptions::new(command, args.iter().copied()))
}

pub fn run(options: CommandOptions) -> Result<CommandOutput, VmctlError> {
    eprintln!("[vmctl] command: {}", options.display_command());

    let mut command = Command::new(&options.command);
    command.args(&options.args);
    if let Some(cwd) = &options.cwd {
        command.current_dir(cwd);
    }
    command.envs(&options.envs);
    command.stdout(Stdio::piped()).stderr(Stdio::piped());

    let mut child = command.spawn().map_err(|error| VmctlError::SpawnFailed {
        command: options.display_command(),
        error: error.to_string(),
    })?;

    let warnings = Arc::new(Mutex::new(Vec::new()));
    let fatal = Arc::new(Mutex::new(None));
    let stdout = child.stdout.take().expect("stdout was piped");
    let stderr = child.stderr.take().expect("stderr was piped");
    let stdout_reader = spawn_reader(
        stdout,
        options.prefix,
        options.stream,
        options.fail_on_proxmox_patterns,
        Arc::clone(&warnings),
        Arc::clone(&fatal),
    );
    let stderr_reader = spawn_reader(
        stderr,
        options.prefix,
        options.stream,
        options.fail_on_proxmox_patterns,
        Arc::clone(&warnings),
        Arc::clone(&fatal),
    );

    let started = Instant::now();
    let status = loop {
        if let Some(error) = fatal.lock().ok().and_then(|guard| guard.clone()) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            return Err(error);
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = stdout_reader.join();
                let _ = stderr_reader.join();
                return Err(VmctlError::SpawnFailed {
                    command: options.display_command(),
                    error: error.to_string(),
                });
            }
        }
        if started.elapsed() >= options.timeout {
            let _ = child.kill();
            let _ = child.wait();
            let _ = stdout_reader.join();
            let _ = stderr_reader.join();
            return Err(VmctlError::CommandTimedOut {
                command: options.display_command(),
                timeout: options.timeout,
            });
        }
        std::thread::sleep(Duration::from_millis(50));
    };

    let stdout = stdout_reader.join().unwrap_or_default();
    let stderr = stderr_reader.join().unwrap_or_default();
    let combined = if stderr.trim().is_empty() {
        stdout.clone()
    } else {
        format!("{stdout}\n{stderr}")
    };

    if options.fail_on_proxmox_patterns {
        if let Some(error) = parse_proxmox_error(&combined) {
            return Err(error);
        }
    }

    if !status.success() {
        return Err(VmctlError::CommandFailed {
            command: options.display_command(),
            code: status.code().unwrap_or(-1),
            stderr: combined,
        });
    }

    let warnings = warnings
        .lock()
        .map(|warnings| warnings.clone())
        .unwrap_or_default();
    Ok(CommandOutput {
        stdout,
        stderr,
        combined,
        warnings,
    })
}

pub fn run_with_retries(
    options: CommandOptions,
    max_attempts: u32,
) -> Result<CommandOutput, VmctlError> {
    let max_attempts = max_attempts.max(1);
    let mut previous_error = None;
    for attempt in 1..=max_attempts {
        match run(options.clone()) {
            Ok(output) => return Ok(output),
            Err(error) => {
                let current = error.to_string();
                if previous_error.as_deref() == Some(current.as_str()) {
                    return Err(VmctlError::RepeatedFailure {
                        command: options.display_command(),
                        error: current,
                    });
                }
                previous_error = Some(current);
                if attempt == max_attempts {
                    return Err(VmctlError::RetryLimitExceeded {
                        command: options.display_command(),
                        attempts: max_attempts,
                    });
                }
            }
        }
    }
    unreachable!("max_attempts is at least one")
}

pub fn parse_proxmox_error(output: &str) -> Option<VmctlError> {
    output.lines().find_map(parse_proxmox_line)
}

pub fn parse_proxmox_line(line: &str) -> Option<VmctlError> {
    let trimmed = line.trim();
    if trimmed.contains("TASK ERROR") {
        return Some(VmctlError::ProxmoxTaskError(trimmed.to_string()));
    }
    if trimmed.contains("QEMU exited with code") {
        return Some(VmctlError::QemuError(trimmed.to_string()));
    }
    let lower = trimmed.to_ascii_lowercase();
    if lower.contains("cloud-init")
        && (lower.contains("error") || lower.contains("failed") || lower.contains("failure"))
    {
        return Some(VmctlError::CloudInitError(trimmed.to_string()));
    }
    None
}

pub fn parse_proxmox_warning(line: &str) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.starts_with("WARN:") || trimmed.contains(" WARN:") {
        Some(trimmed.to_string())
    } else {
        None
    }
}

fn spawn_reader<R: Read + Send + 'static>(
    reader: R,
    prefix: LogPrefix,
    stream: bool,
    fail_on_proxmox_patterns: bool,
    warnings: Arc<Mutex<Vec<String>>>,
    fatal: Arc<Mutex<Option<VmctlError>>>,
) -> JoinHandle<String> {
    std::thread::spawn(move || {
        let mut captured = String::new();
        for line in BufReader::new(reader).lines() {
            let line =
                line.unwrap_or_else(|error| format!("failed to read command output: {error}"));
            if stream {
                eprintln!("[{}] {line}", prefix.as_str());
            }
            if let Some(warning) = parse_proxmox_warning(&line) {
                if let Ok(mut warnings) = warnings.lock() {
                    warnings.push(warning);
                }
            }
            if fail_on_proxmox_patterns {
                if let Some(error) = parse_proxmox_line(&line) {
                    if let Ok(mut fatal) = fatal.lock() {
                        if fatal.is_none() {
                            *fatal = Some(error);
                        }
                    }
                }
            }
            captured.push_str(&line);
            captured.push('\n');
        }
        captured
    })
}

fn display_command(command: &str, args: &[String]) -> String {
    if args.is_empty() {
        command.to_string()
    } else {
        format!("{command} {}", args.join(" "))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_proxmox_task_error() {
        let error =
            parse_proxmox_line("TASK ERROR: start failed: QEMU exited with code 1").unwrap();
        assert!(matches!(error, VmctlError::ProxmoxTaskError(_)));
    }

    #[test]
    fn detects_qemu_error() {
        let error =
            parse_proxmox_line("TASK ERROR: start failed: QEMU exited with code 1").unwrap();
        assert!(error.to_string().contains("Proxmox task failed"));
        let error = parse_proxmox_line("start failed: QEMU exited with code 1").unwrap();
        assert!(matches!(error, VmctlError::QemuError(_)));
    }

    #[test]
    fn detects_warning_without_failing() {
        assert_eq!(
            parse_proxmox_warning("WARN: iothread is only valid with virtio disk"),
            Some("WARN: iothread is only valid with virtio disk".to_string())
        );
        assert!(parse_proxmox_line("WARN: iothread is only valid with virtio disk").is_none());
    }

    #[test]
    fn fails_fast_on_known_pattern() {
        let result = run(
            CommandOptions::new(
                "sh",
                [
                    "-c",
                    "printf 'generating cloud-init ISO\\nTASK ERROR: q35 machine model is not enabled\\n'; sleep 2",
                ],
            )
            .timeout(Duration::from_secs(5))
            .stream(false),
        );

        assert!(matches!(result, Err(VmctlError::ProxmoxTaskError(_))));
    }

    #[test]
    fn times_out_hanging_process() {
        let result = run(CommandOptions::new("sh", ["-c", "sleep 2"])
            .timeout(Duration::from_millis(100))
            .stream(false));

        assert!(matches!(result, Err(VmctlError::CommandTimedOut { .. })));
    }

    #[test]
    fn stops_repeated_identical_failures() {
        let result = run_with_retries(
            CommandOptions::new("sh", ["-c", "echo same failure >&2; exit 7"]).stream(false),
            3,
        );

        assert!(matches!(result, Err(VmctlError::RepeatedFailure { .. })));
    }
}
