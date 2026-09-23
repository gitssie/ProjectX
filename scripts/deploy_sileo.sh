#!/bin/sh

set -eu

umask 077

script_name=$(basename -- "$0")
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
script_path="$project_root/scripts/$script_name"
deploy_root="$project_root/.deploy"
config_file="$deploy_root/deploy.env"
command_name=""
dry_run=0
config_keys_seen=""
lock_owned=0
temporary_path=""
cleanup_on_failure=0
started_supervisor=0
current_stage="initialization"
selected_package=""
build_marker=""

usage() {
    cat <<'EOF'
Usage: scripts/deploy_sileo.sh [--dry-run] COMMAND

Commands:
  deploy   Validate config, build/audit, publish, start, and verify.
  build-publish
           Build/audit and publish locally without starting HTTP or SSH services.
  publish  Audit one fresh ProjectX deb and atomically publish APT metadata.
  start    Start or reuse one detached supervisor for owned HTTP/tunnel children.
  verify   Verify repository metadata and every path through the device tunnel.
  status   Report repository, owned-process, and device-endpoint health.
  stop     Stop only the verified owned supervisor and its children.

Options:
  --dry-run        Validate inputs and print stages without changing state.
  -h, --help       Show this help.

Project-local untracked config:
  .deploy/deploy.env
  Copy scripts/deploy.env.example there, fill it once, and chmod it 600.

Required config keys for deploy/start/verify/status:
  PROJECTX_SILEO_SOURCE_URL      Stable URL, exactly http://127.0.0.1:<device-port>.
  PROJECTX_SILEO_HTTP_PORT       Mac loopback HTTP port.
  PROJECTX_SILEO_DEVICE_PORT     Device loopback reverse-forward port.
  PROJECTX_SILEO_SSH_HOST        Existing iproxy SSH host.
  PROJECTX_SILEO_SSH_PORT        Existing iproxy SSH port.
  PROJECTX_SILEO_SSH_USER        Must be mobile.
  PROJECTX_SILEO_SSH_IDENTITY    Absolute path to the authorized private key.

Additionally required for deploy/build-publish/publish:
  THEOS                           Absolute RootHide Theos directory.

publish may use PROJECTX_SILEO_PACKAGE to name the one fresh package explicitly;
otherwise the current control version determines the expected package in packages/.

This script never opens/adds a Sileo source and never installs a package.
Existing environment values override matching values from the config file.
All deployment writes are confined to ProjectX/.deploy plus normal build outputs.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

for argument in "$@"; do
    case "$argument" in
        *'
'*)
            fail "arguments must not contain newlines"
            ;;
    esac
done

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        deploy|build-publish|publish|start|verify|status|stop|__supervise)
            command_name=$1
            shift
            break
            ;;
        *)
            fail "unknown option or command: $1 (use --help)"
            ;;
    esac
done

[ -n "$command_name" ] || fail "a command is required (use --help)"
[ "$#" -eq 0 ] || fail "unexpected argument after $command_name: $1"

config_fail() {
    echo "error: $*" >&2
    echo "setup: copy $project_root/scripts/deploy.env.example to $config_file, fill it once, and chmod it 600" >&2
    exit 2
}

file_owner_id() {
    stat -f '%u' "$1" 2>/dev/null || stat -c '%u' "$1" 2>/dev/null
}

file_permission_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
}

parse_config_value() {
    config_raw_value=$1
    case "$config_raw_value" in
        \'*\')
            parsed_config_value=${config_raw_value#\'}
            parsed_config_value=${parsed_config_value%\'}
            case "$parsed_config_value" in
                *\'*) config_fail "malformed quoted value on config line $config_line_number" ;;
            esac
            ;;
        \"*\")
            parsed_config_value=${config_raw_value#\"}
            parsed_config_value=${parsed_config_value%\"}
            case "$parsed_config_value" in
                *\"*) config_fail "malformed quoted value on config line $config_line_number" ;;
            esac
            ;;
        \'*|*\'|\"*|*\")
            config_fail "unmatched quote on config line $config_line_number"
            ;;
        *[[:space:]]*)
            config_fail "unquoted whitespace on config line $config_line_number"
            ;;
        *)
            parsed_config_value=$config_raw_value
            ;;
    esac
}

assign_config_value() {
    config_key=$1
    config_value=$2
    case " $config_keys_seen " in
        *" $config_key "*) config_fail "duplicate config key on line $config_line_number: $config_key" ;;
    esac
    config_keys_seen="$config_keys_seen $config_key"

    case "$config_key" in
        THEOS)
            [ "${THEOS+x}" = x ] || THEOS=$config_value
            ;;
        PROJECTX_SILEO_SOURCE_URL)
            [ "${PROJECTX_SILEO_SOURCE_URL+x}" = x ] || PROJECTX_SILEO_SOURCE_URL=$config_value
            ;;
        PROJECTX_SILEO_HTTP_PORT)
            [ "${PROJECTX_SILEO_HTTP_PORT+x}" = x ] || PROJECTX_SILEO_HTTP_PORT=$config_value
            ;;
        PROJECTX_SILEO_DEVICE_PORT)
            [ "${PROJECTX_SILEO_DEVICE_PORT+x}" = x ] || PROJECTX_SILEO_DEVICE_PORT=$config_value
            ;;
        PROJECTX_SILEO_SSH_HOST)
            [ "${PROJECTX_SILEO_SSH_HOST+x}" = x ] || PROJECTX_SILEO_SSH_HOST=$config_value
            ;;
        PROJECTX_SILEO_SSH_PORT)
            [ "${PROJECTX_SILEO_SSH_PORT+x}" = x ] || PROJECTX_SILEO_SSH_PORT=$config_value
            ;;
        PROJECTX_SILEO_SSH_USER)
            [ "${PROJECTX_SILEO_SSH_USER+x}" = x ] || PROJECTX_SILEO_SSH_USER=$config_value
            ;;
        PROJECTX_SILEO_SSH_IDENTITY)
            [ "${PROJECTX_SILEO_SSH_IDENTITY+x}" = x ] || PROJECTX_SILEO_SSH_IDENTITY=$config_value
            ;;
        PROJECTX_SILEO_PACKAGE)
            [ "${PROJECTX_SILEO_PACKAGE+x}" = x ] || PROJECTX_SILEO_PACKAGE=$config_value
            ;;
        *)
            config_fail "unknown config key on line $config_line_number: $config_key"
            ;;
    esac
}

load_config_file() {
    [ ! -L "$deploy_root" ] || config_fail "ProjectX .deploy must not be a symbolic link"
    [ -d "$deploy_root" ] || config_fail "project-local deployment directory is missing: $deploy_root"
    [ ! -L "$config_file" ] || config_fail "deployment config must not be a symbolic link: $config_file"
    [ -f "$config_file" ] && [ -r "$config_file" ] || config_fail "deployment config is missing or unreadable: $config_file"

    config_parent=$(CDPATH= cd -- "$deploy_root" && pwd -P) || config_fail "ProjectX .deploy is unavailable"
    [ "$config_parent" = "$deploy_root" ] || config_fail "ProjectX .deploy must resolve inside the project root"

    deploy_owner=$(file_owner_id "$deploy_root") || config_fail "could not inspect ProjectX .deploy owner"
    [ "$deploy_owner" = "$(id -u)" ] || config_fail "ProjectX .deploy must be owned by the current user"
    deploy_mode=$(file_permission_mode "$deploy_root") || config_fail "could not inspect ProjectX .deploy permissions"
    case "$deploy_mode" in
        ''|*[!0-7]*) config_fail "ProjectX .deploy has an unreadable permission mode" ;;
        *[1-7][0-7]|*[0-7][1-7]) config_fail "ProjectX .deploy must not grant group or other access; run chmod 700 on it" ;;
    esac
    config_owner=$(file_owner_id "$config_file") || config_fail "could not inspect deployment config owner"
    [ "$config_owner" = "$(id -u)" ] || config_fail "deployment config must be owned by the current user"
    config_mode=$(file_permission_mode "$config_file") || config_fail "could not inspect deployment config permissions"
    case "$config_mode" in
        ''|*[!0-7]*) config_fail "deployment config has an unreadable permission mode" ;;
        *[1-7][0-7]|*[0-7][1-7]) config_fail "deployment config must not grant group or other access; run chmod 600 on it" ;;
    esac

    config_line_number=0
    while IFS= read -r config_line || [ -n "$config_line" ]; do
        config_line_number=$((config_line_number + 1))
        case "$config_line" in
            ''|'#'*) continue ;;
            'export '*) config_assignment=${config_line#export } ;;
            *) config_assignment=$config_line ;;
        esac
        case "$config_assignment" in
            *=*) ;;
            *) config_fail "expected NAME=value on config line $config_line_number" ;;
        esac
        config_key=${config_assignment%%=*}
        config_raw_value=${config_assignment#*=}
        parse_config_value "$config_raw_value"
        assign_config_value "$config_key" "$parsed_config_value"
    done < "$config_file"
}

load_config_file

state_dir="$deploy_root/state"
source_url=${PROJECTX_SILEO_SOURCE_URL:-}
source_url=${source_url%/}
http_port=${PROJECTX_SILEO_HTTP_PORT:-}
device_port=${PROJECTX_SILEO_DEVICE_PORT:-}
ssh_host=${PROJECTX_SILEO_SSH_HOST:-}
ssh_port=${PROJECTX_SILEO_SSH_PORT:-}
ssh_user=${PROJECTX_SILEO_SSH_USER:-}
ssh_identity=${PROJECTX_SILEO_SSH_IDENTITY:-}
package_override=${PROJECTX_SILEO_PACKAGE:-}
theos_dir=${THEOS:-}

if [ -n "$theos_dir" ]; then
    PATH="$theos_dir/bin:$PATH"
    export PATH
fi

generations_dir="$state_dir/generations"
repository_link="$deploy_root/repo"
run_dir="$state_dir/run"
logs_dir="$deploy_root/logs"
temporary_dir="$deploy_root/tmp"
lock_dir="$state_dir/lock"
ssh_client_config="$run_dir/ssh-client.conf"
ssh_tunnel_config="$run_dir/ssh-tunnel.conf"
ssh_sanitizer="$run_dir/ssh-sanitize.sed"
supervisor_pid_file="$run_dir/supervisor.pid"
supervisor_start_file="$run_dir/supervisor.start"
supervisor_fingerprint_file="$run_dir/supervisor.fingerprint"
supervisor_status_file="$run_dir/supervisor.status"

append_missing() {
    if [ -z "${missing_configuration:-}" ]; then
        missing_configuration=$1
    else
        missing_configuration="$missing_configuration $1"
    fi
}

report_missing_configuration() {
    if [ -n "$missing_configuration" ]; then
        for missing_name in $missing_configuration; do
            echo "error: missing required configuration: $missing_name" >&2
        done
        exit 2
    fi
}

validate_state_path() {
    [ "$state_dir" = "$project_root/.deploy/state" ] || fail "deployment state must remain under ProjectX/.deploy"
    [ "$repository_link" = "$project_root/.deploy/repo" ] || fail "deployment repository must remain under ProjectX/.deploy"
    [ "$logs_dir" = "$project_root/.deploy/logs" ] || fail "deployment logs must remain under ProjectX/.deploy"
    for managed_directory in "$deploy_root" "$state_dir" "$generations_dir" "$run_dir" "$logs_dir" "$temporary_dir"; do
        [ ! -L "$managed_directory" ] || fail "deployment-managed directories must not be symbolic links"
    done
    if [ -e "$repository_link" ] || [ -L "$repository_link" ]; then
        [ -L "$repository_link" ] || fail "ProjectX .deploy/repo must be the script-owned repository symlink"
        repository_target=$(readlink "$repository_link") || fail "could not inspect ProjectX .deploy/repo"
        case "$repository_target" in
            state/generations/?*)
                repository_generation=${repository_target#state/generations/}
                case "$repository_generation" in
                    */*) fail "ProjectX .deploy/repo has an invalid generation target" ;;
                esac
                ;;
            *) fail "ProjectX .deploy/repo points outside the managed generation tree" ;;
        esac
        if [ -d "$repository_link" ]; then
            repository_resolved=$(CDPATH= cd -- "$repository_link" && pwd -P) ||
                fail "could not resolve ProjectX .deploy/repo"
            case "$repository_resolved" in
                "$generations_dir"/*) ;;
                *) fail "ProjectX .deploy/repo resolves outside the managed generation tree" ;;
            esac
        fi
    fi
}

validate_state_configuration() {
    validate_state_path
}

validate_port() {
    port_name=$1
    port_value=$2
    case "$port_value" in
        ''|*[!0-9]*) fail "$port_name must be an integer from 1 through 65535" ;;
    esac
    [ "$port_value" -ge 1 ] && [ "$port_value" -le 65535 ] ||
        fail "$port_name must be an integer from 1 through 65535"
}

validate_connection_values() {
    validate_state_path
    validate_port PROJECTX_SILEO_HTTP_PORT "$http_port"
    validate_port PROJECTX_SILEO_DEVICE_PORT "$device_port"
    validate_port PROJECTX_SILEO_SSH_PORT "$ssh_port"
    [ "$ssh_user" = "mobile" ] || fail "PROJECTX_SILEO_SSH_USER must be mobile"
    case "$ssh_host$ssh_user" in
        *[!A-Za-z0-9._:@-]*) fail "SSH host and user contain unsupported characters" ;;
    esac
    case "$ssh_identity" in
        /*) ;;
        *) fail "PROJECTX_SILEO_SSH_IDENTITY must be an absolute path" ;;
    esac
    case "$ssh_identity" in
        *'"'*|*'
'*) fail "PROJECTX_SILEO_SSH_IDENTITY contains unsupported characters" ;;
    esac
    [ -f "$ssh_identity" ] && [ -r "$ssh_identity" ] ||
        fail "PROJECTX_SILEO_SSH_IDENTITY is not a readable file"

    expected_source_url="http://127.0.0.1:$device_port"
    [ "$source_url" = "$expected_source_url" ] ||
        fail "PROJECTX_SILEO_SOURCE_URL must equal http://127.0.0.1:<PROJECTX_SILEO_DEVICE_PORT>"
}

validate_connection_configuration() {
    missing_configuration=""
    [ -n "$source_url" ] || append_missing PROJECTX_SILEO_SOURCE_URL
    [ -n "$http_port" ] || append_missing PROJECTX_SILEO_HTTP_PORT
    [ -n "$device_port" ] || append_missing PROJECTX_SILEO_DEVICE_PORT
    [ -n "$ssh_host" ] || append_missing PROJECTX_SILEO_SSH_HOST
    [ -n "$ssh_port" ] || append_missing PROJECTX_SILEO_SSH_PORT
    [ -n "$ssh_user" ] || append_missing PROJECTX_SILEO_SSH_USER
    [ -n "$ssh_identity" ] || append_missing PROJECTX_SILEO_SSH_IDENTITY
    report_missing_configuration
    validate_connection_values
}

validate_build_configuration() {
    missing_configuration=""
    [ -n "$source_url" ] || append_missing PROJECTX_SILEO_SOURCE_URL
    [ -n "$http_port" ] || append_missing PROJECTX_SILEO_HTTP_PORT
    [ -n "$device_port" ] || append_missing PROJECTX_SILEO_DEVICE_PORT
    [ -n "$ssh_host" ] || append_missing PROJECTX_SILEO_SSH_HOST
    [ -n "$ssh_port" ] || append_missing PROJECTX_SILEO_SSH_PORT
    [ -n "$ssh_user" ] || append_missing PROJECTX_SILEO_SSH_USER
    [ -n "$ssh_identity" ] || append_missing PROJECTX_SILEO_SSH_IDENTITY
    [ -n "$theos_dir" ] || append_missing THEOS
    report_missing_configuration
    validate_connection_values
    case "$theos_dir" in
        /*) ;;
        *) fail "THEOS must be an absolute path" ;;
    esac
    [ -d "$theos_dir" ] || fail "THEOS does not name an existing directory"
}

validate_publish_configuration() {
    missing_configuration=""
    [ -n "$theos_dir" ] || append_missing THEOS
    report_missing_configuration
    validate_state_path
    case "$theos_dir" in
        /*) ;;
        *) fail "THEOS must be an absolute path" ;;
    esac
    [ -d "$theos_dir" ] || fail "THEOS does not name an existing directory"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

require_publish_commands() {
    require_command ar
    require_command awk
    require_command cmp
    require_command gzip
    require_command md5
    require_command python3
    require_command shasum
    require_command tar
    require_command xz
    require_command zstd
}

require_connection_commands() {
    require_command curl
    require_command lsof
    require_command nohup
    require_command ps
    require_command sed
    require_command ssh
}

initialize_state() {
    [ "$dry_run" -eq 0 ] || return 0
    mkdir -p "$state_dir" "$generations_dir" "$run_dir" "$logs_dir" "$temporary_dir"
    chmod 700 "$deploy_root" "$state_dir" "$generations_dir" "$run_dir" "$logs_dir" "$temporary_dir"
    state_resolved=$(CDPATH= cd -- "$state_dir" && pwd -P)
    [ "$state_resolved" = "$state_dir" ] || fail "deployment state resolved outside ProjectX/.deploy"
    TMPDIR=$temporary_dir
    export TMPDIR
}

assert_deploy_cleanup_path() {
    cleanup_target=$1
    case "$cleanup_target" in
        "$deploy_root"/*) ;;
        *) fail "refusing cleanup outside ProjectX/.deploy" ;;
    esac
    cleanup_parent=$(dirname -- "$cleanup_target")
    if [ -d "$cleanup_parent" ]; then
        cleanup_parent_resolved=$(CDPATH= cd -- "$cleanup_parent" && pwd -P) ||
            fail "could not resolve deployment cleanup parent"
        case "$cleanup_parent_resolved/$(basename -- "$cleanup_target")" in
            "$deploy_root"/*) ;;
            *) fail "refusing cleanup whose canonical parent is outside ProjectX/.deploy" ;;
        esac
    fi
}

remove_deploy_paths() {
    for cleanup_path do
        assert_deploy_cleanup_path "$cleanup_path"
    done
    rm -rf -- "$@"
}

process_start_identity() {
    LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null | awk '{$1=$1; print}'
}

lock_is_live() {
    [ -f "$lock_dir/pid" ] && [ -f "$lock_dir/start" ] || return 1
    lock_pid=$(awk 'NR == 1 { print; exit }' "$lock_dir/pid")
    case "$lock_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$lock_pid" 2>/dev/null || return 1
    lock_expected=$(awk 'NR == 1 { print; exit }' "$lock_dir/start")
    lock_actual=$(process_start_identity "$lock_pid")
    [ -n "$lock_actual" ] && [ "$lock_actual" = "$lock_expected" ]
}

acquire_lock() {
    if mkdir "$lock_dir" 2>/dev/null; then
        :
    elif lock_is_live; then
        fail "another deploy_sileo.sh operation owns the state lock"
    else
        remove_deploy_paths "$lock_dir"
        mkdir "$lock_dir" || fail "could not reclaim stale state lock"
    fi
    printf '%s\n' "$$" > "$lock_dir/pid"
    process_start_identity "$$" > "$lock_dir/start"
    lock_owned=1
}

release_lock() {
    [ "$lock_owned" -eq 1 ] || return 0
    if [ -f "$lock_dir/pid" ] && [ "$(awk 'NR == 1 { print; exit }' "$lock_dir/pid")" = "$$" ]; then
        remove_deploy_paths "$lock_dir"
    fi
    lock_owned=0
}

supervisor_process_fingerprint() {
    fingerprint_pid=$1
    fingerprint_start=$(process_start_identity "$fingerprint_pid")
    [ -n "$fingerprint_start" ] || return 1
    fingerprint_command=$(ps -p "$fingerprint_pid" -o command= 2>/dev/null || true)
    case "$fingerprint_command" in
        *"$script_path __supervise"*) ;;
        *) return 1 ;;
    esac
    printf '%s\n%s\n%s\n' "$fingerprint_pid" "$fingerprint_start" "$fingerprint_command" |
        hash_text_sha256
}

owned_supervisor_pid() {
    [ -f "$supervisor_pid_file" ] &&
        [ -f "$supervisor_start_file" ] &&
        [ -f "$supervisor_fingerprint_file" ] || return 1
    owned_supervisor_value=$(awk 'NR == 1 { print; exit }' "$supervisor_pid_file")
    case "$owned_supervisor_value" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$owned_supervisor_value" 2>/dev/null || return 1
    owned_supervisor_expected_start=$(awk 'NR == 1 { print; exit }' "$supervisor_start_file")
    owned_supervisor_actual_start=$(process_start_identity "$owned_supervisor_value")
    [ -n "$owned_supervisor_actual_start" ] &&
        [ "$owned_supervisor_actual_start" = "$owned_supervisor_expected_start" ] || return 1
    owned_supervisor_expected_fingerprint=$(awk 'NR == 1 { print; exit }' "$supervisor_fingerprint_file")
    owned_supervisor_actual_fingerprint=$(supervisor_process_fingerprint "$owned_supervisor_value") || return 1
    [ "$owned_supervisor_actual_fingerprint" = "$owned_supervisor_expected_fingerprint" ] || return 1
    printf '%s\n' "$owned_supervisor_value"
}

record_supervisor() {
    record_supervisor_pid=$1
    record_supervisor_attempt=0
    record_supervisor_start=""
    record_supervisor_fingerprint=""
    while [ "$record_supervisor_attempt" -lt 50 ]; do
        record_supervisor_start=$(process_start_identity "$record_supervisor_pid")
        record_supervisor_fingerprint=$(supervisor_process_fingerprint "$record_supervisor_pid" 2>/dev/null || true)
        if [ -n "$record_supervisor_start" ] && [ -n "$record_supervisor_fingerprint" ]; then
            break
        fi
        kill -0 "$record_supervisor_pid" 2>/dev/null || return 1
        sleep 0.1
        record_supervisor_attempt=$((record_supervisor_attempt + 1))
    done
    [ -n "$record_supervisor_start" ] && [ -n "$record_supervisor_fingerprint" ] || return 1
    record_suffix=".$$"
    printf '%s\n' "$record_supervisor_start" > "$supervisor_start_file$record_suffix"
    printf '%s\n' "$record_supervisor_fingerprint" > "$supervisor_fingerprint_file$record_suffix"
    printf '%s\n' "$record_supervisor_pid" > "$supervisor_pid_file$record_suffix"
    mv -f "$supervisor_start_file$record_suffix" "$supervisor_start_file"
    mv -f "$supervisor_fingerprint_file$record_suffix" "$supervisor_fingerprint_file"
    mv -f "$supervisor_pid_file$record_suffix" "$supervisor_pid_file"
    return 0
}

supervisor_state_is_stale() {
    if owned_supervisor_pid >/dev/null 2>&1; then
        return 1
    fi
    [ -e "$supervisor_pid_file" ] ||
        [ -e "$supervisor_start_file" ] ||
        [ -e "$supervisor_fingerprint_file" ]
}

supervisor_child_pid() {
    child_parent_pid=$1
    child_marker=$2
    ps -axo pid=,ppid=,command= 2>/dev/null | awk -v parent="$child_parent_pid" -v marker="$child_marker" '
        $2 == parent && index($0, marker) {
            if (found) exit 2
            found = $1
        }
        END {
            if (found) print found
            else exit 1
        }
    '
}

stop_verified_supervisor() {
    stop_supervisor_quiet=${1:-0}
    if stop_supervisor_pid=$(owned_supervisor_pid 2>/dev/null); then
        kill -TERM "$stop_supervisor_pid" 2>/dev/null || return 1
        stop_supervisor_attempt=0
        while owned_supervisor_pid >/dev/null 2>&1 && [ "$stop_supervisor_attempt" -lt 150 ]; do
            sleep 0.1
            stop_supervisor_attempt=$((stop_supervisor_attempt + 1))
        done
        owned_supervisor_pid >/dev/null 2>&1 && return 1
        [ "$stop_supervisor_quiet" -eq 1 ] || echo "supervisor=stopped"
    elif supervisor_state_is_stale; then
        [ "$stop_supervisor_quiet" -eq 1 ] || echo "supervisor=stale-state-cleared"
    else
        [ "$stop_supervisor_quiet" -eq 1 ] || echo "supervisor=not-owned"
    fi
    remove_deploy_paths "$supervisor_pid_file" "$supervisor_start_file" "$supervisor_fingerprint_file"
}

cleanup_started_services() {
    [ "$started_supervisor" -eq 0 ] || stop_verified_supervisor 1 >/dev/null 2>&1 || true
}

on_exit() {
    exit_status=$?
    trap - 0 HUP INT TERM
    if [ "$exit_status" -ne 0 ] && [ "$cleanup_on_failure" -eq 1 ]; then
        cleanup_started_services
    fi
    if [ -n "$temporary_path" ] && [ -e "$temporary_path" ]; then
        remove_deploy_paths "$temporary_path"
    fi
    release_lock
    if [ "$exit_status" -ne 0 ]; then
        echo "error: first failed stage: $current_stage" >&2
    fi
    exit "$exit_status"
}

trap 'current_stage="signal-hup"; exit 129' HUP
trap 'current_stage="signal-int"; exit 130' INT
trap 'current_stage="signal-term"; exit 143' TERM
trap on_exit 0

hash_file() {
    hash_algorithm=$1
    hash_path=$2
    case "$hash_algorithm" in
        md5) md5 -q "$hash_path" ;;
        sha1) shasum -a 1 "$hash_path" | awk '{print $1}' ;;
        sha256) shasum -a 256 "$hash_path" | awk '{print $1}' ;;
        *) fail "unsupported hash algorithm: $hash_algorithm" ;;
    esac
}

hash_text_sha256() {
    shasum -a 256 | awk '{print $1}'
}

file_size() {
    wc -c < "$1" | awk '{$1=$1; print}'
}

control_field() {
    field_name=$1
    field_file=$2
    awk -v requested="$field_name" '
        index($0, requested ":") == 1 {
            value = substr($0, length(requested) + 2)
            sub(/^[[:space:]]*/, "", value)
            count++
        }
        END {
            if (count != 1 || value == "") exit 1
            print value
        }
    ' "$field_file"
}

extract_package_control() {
    extract_package=$1
    extract_destination=$2
    mkdir -p "$extract_destination/archive" "$extract_destination/control"
    (
        cd "$extract_destination/archive"
        ar -x "$extract_package"
    )
    set -- "$extract_destination"/archive/control.tar.*
    [ "$#" -eq 1 ] && [ -f "$1" ] || fail "package control archive is missing or ambiguous"
    tar -xf "$1" -C "$extract_destination/control"
    [ -f "$extract_destination/control/control" ] || fail "package control metadata is missing"
    printf '%s\n' "$extract_destination/control/control"
}

validate_package_identity() {
    identity_package=$1
    identity_work=$2
    identity_control=$(extract_package_control "$identity_package" "$identity_work")
    identity_name=$(control_field Package "$identity_control") || fail "package has invalid Package metadata"
    identity_version=$(control_field Version "$identity_control") || fail "package has invalid Version metadata"
    identity_architecture=$(control_field Architecture "$identity_control") || fail "package has invalid Architecture metadata"
    source_name=$(control_field Package "$project_root/control") || fail "source control has invalid Package metadata"
    source_version=$(control_field Version "$project_root/control") || fail "source control has invalid Version metadata"
    source_architecture=$(control_field Architecture "$project_root/control") || fail "source control has invalid Architecture metadata"
    [ "$identity_name" = "$source_name" ] || fail "package identifier does not match source control"
    [ "$identity_version" = "$source_version" ] || fail "package version does not match source control"
    [ "$identity_architecture" = "iphoneos-arm64e" ] || fail "package architecture is not iphoneos-arm64e"
    [ "$identity_architecture" = "$source_architecture" ] || fail "package architecture does not match source control"
    expected_basename="${identity_name}_${identity_version}_${identity_architecture}.deb"
    [ "$(basename -- "$identity_package")" = "$expected_basename" ] ||
        fail "package filename does not match its control metadata"
    package_identity_name=$identity_name
    package_identity_version=$identity_version
    package_identity_architecture=$identity_architecture
    package_control_path=$identity_control
}

package_is_fresh_for_source() {
    freshness_package=$1
    if [ -n "$build_marker" ]; then
        [ -n "$(find "$freshness_package" -newer "$build_marker" -print)" ] || return 1
        return 0
    fi
    newer_source=$(find "$project_root" \
        \( -path "$project_root/.git" -o \
           -path "$project_root/.beads" -o \
           -path "$project_root/.codegraph" -o \
           -path "$project_root/.deploy" -o \
           -path "$project_root/.theos" -o \
           -path "$project_root/build_check" -o \
           -path "$project_root/packages" -o \
           -path "$project_root/_deb_extract" \) -prune -o \
        -type f -newer "$freshness_package" -print | awk 'NR == 1 { print; exit }')
    [ -z "$newer_source" ]
}

select_package_for_publish() {
    source_package_name=$(control_field Package "$project_root/control") || fail "source control has invalid Package metadata"
    source_package_version=$(control_field Version "$project_root/control") || fail "source control has invalid Version metadata"
    source_package_architecture=$(control_field Architecture "$project_root/control") || fail "source control has invalid Architecture metadata"
    [ "$source_package_architecture" = "iphoneos-arm64e" ] || fail "source control architecture is not iphoneos-arm64e"
    expected_package="$project_root/packages/${source_package_name}_${source_package_version}_${source_package_architecture}.deb"
    if [ -n "$package_override" ]; then
        case "$package_override" in
            /*) candidate_package=$package_override ;;
            *) fail "PROJECTX_SILEO_PACKAGE must be an absolute path" ;;
        esac
        candidate_parent=$(CDPATH= cd -- "$(dirname -- "$candidate_package")" 2>/dev/null && pwd -P) ||
            fail "PROJECTX_SILEO_PACKAGE parent directory does not exist"
        [ "$candidate_parent" = "$project_root/packages" ] ||
            fail "PROJECTX_SILEO_PACKAGE must be inside the ProjectX packages directory"
    else
        candidate_package=$expected_package
    fi
    [ -f "$candidate_package" ] || fail "expected fresh package is missing: $(basename -- "$candidate_package")"
    [ "$candidate_package" = "$expected_package" ] || fail "PROJECTX_SILEO_PACKAGE is not the current control-version artifact"
    package_is_fresh_for_source "$candidate_package" ||
        fail "package is stale relative to ProjectX source; run deploy to rebuild it"
    selected_package=$candidate_package
}

build_project() {
    current_stage="build-audit"
    build_marker="$state_dir/build-start"
    : > "$build_marker"
    (
        umask 022
        /bin/sh "$project_root/scripts/check_build_warnings.sh"
    )

    fresh_list="$state_dir/fresh-packages.$$"
    find "$project_root/packages" -maxdepth 1 -type f \
        -name 'com.hydra.projectx_*_iphoneos-arm64e.deb' \
        -newer "$build_marker" -print > "$fresh_list"
    fresh_count=$(awk 'END { print NR + 0 }' "$fresh_list")
    if [ "$fresh_count" -ne 1 ]; then
        remove_deploy_paths "$fresh_list"
        fail "build must produce exactly one fresh iphoneos-arm64e ProjectX package; found $fresh_count"
    fi
    selected_package=$(awk 'NR == 1 { print; exit }' "$fresh_list")
    remove_deploy_paths "$fresh_list"
    select_package_for_publish
}

release_has_entry() {
    release_path=$1
    release_section=$2
    release_hash=$3
    release_size=$4
    release_name=$5
    awk -v section="$release_section" -v hash="$release_hash" -v size="$release_size" -v name="$release_name" '
        $0 == section ":" { active = 1; next }
        /^[A-Za-z0-9-]+:/ { active = 0 }
        active && $1 == hash && $2 == size && $3 == name { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$release_path"
}

validate_repository_dir() {
    validation_repo=$1
    [ -d "$validation_repo" ] || return 1
    for validation_name in Packages Packages.gz Packages.xz Packages.zst Release; do
        [ -f "$validation_repo/$validation_name" ] || return 1
    done
    validation_package_field=$(control_field Package "$validation_repo/Packages") || return 1
    validation_version=$(control_field Version "$validation_repo/Packages") || return 1
    validation_architecture=$(control_field Architecture "$validation_repo/Packages") || return 1
    validation_filename=$(control_field Filename "$validation_repo/Packages") || return 1
    validation_size=$(control_field Size "$validation_repo/Packages") || return 1
    validation_md5=$(control_field MD5sum "$validation_repo/Packages") || return 1
    validation_sha1=$(control_field SHA1 "$validation_repo/Packages") || return 1
    validation_sha256=$(control_field SHA256 "$validation_repo/Packages") || return 1
    [ "$validation_package_field" = "com.hydra.projectx" ] || return 1
    [ "$validation_architecture" = "iphoneos-arm64e" ] || return 1
    case "$validation_filename" in
        pool/com.hydra.projectx_*_iphoneos-arm64e.deb) ;;
        *) return 1 ;;
    esac
    case "$validation_filename" in
        *..*|*//*|*' '*|*'
'*) return 1 ;;
    esac
    validation_package="$validation_repo/$validation_filename"
    [ -f "$validation_package" ] || return 1
    set -- "$validation_repo"/pool/*.deb
    [ "$#" -eq 1 ] && [ "$1" = "$validation_package" ] || return 1
    [ "$(file_size "$validation_package")" = "$validation_size" ] || return 1
    [ "$(hash_file md5 "$validation_package")" = "$validation_md5" ] || return 1
    [ "$(hash_file sha1 "$validation_package")" = "$validation_sha1" ] || return 1
    [ "$(hash_file sha256 "$validation_package")" = "$validation_sha256" ] || return 1

    validation_work=$(mktemp -d "$state_dir/.validate.XXXXXX")
    validation_compression_ok=1
    gzip -dc "$validation_repo/Packages.gz" > "$validation_work/Packages.gz.out" || validation_compression_ok=0
    xz -dc "$validation_repo/Packages.xz" > "$validation_work/Packages.xz.out" || validation_compression_ok=0
    zstd -q -d -c "$validation_repo/Packages.zst" > "$validation_work/Packages.zst.out" || validation_compression_ok=0
    cmp -s "$validation_repo/Packages" "$validation_work/Packages.gz.out" || validation_compression_ok=0
    cmp -s "$validation_repo/Packages" "$validation_work/Packages.xz.out" || validation_compression_ok=0
    cmp -s "$validation_repo/Packages" "$validation_work/Packages.zst.out" || validation_compression_ok=0
    remove_deploy_paths "$validation_work"
    [ "$validation_compression_ok" -eq 1 ] || return 1

    grep -Eq '^Architectures:[[:space:]]*iphoneos-arm64e[[:space:]]*$' "$validation_repo/Release" || return 1
    for validation_index in Packages Packages.gz Packages.xz Packages.zst; do
        validation_index_size=$(file_size "$validation_repo/$validation_index")
        release_has_entry "$validation_repo/Release" MD5Sum \
            "$(hash_file md5 "$validation_repo/$validation_index")" "$validation_index_size" "$validation_index" || return 1
        release_has_entry "$validation_repo/Release" SHA1 \
            "$(hash_file sha1 "$validation_repo/$validation_index")" "$validation_index_size" "$validation_index" || return 1
        release_has_entry "$validation_repo/Release" SHA256 \
            "$(hash_file sha256 "$validation_repo/$validation_index")" "$validation_index_size" "$validation_index" || return 1
    done
    repository_version=$validation_version
    repository_architecture=$validation_architecture
    repository_filename=$validation_filename
    repository_size=$validation_size
    repository_sha256=$validation_sha256
}

atomic_repository_link() {
    atomic_target=$1
    atomic_link=$2
    python3 - "$atomic_target" "$atomic_link" <<'PY'
import os
import sys

target, link = sys.argv[1:]
temporary = f"{link}.tmp-{os.getpid()}"
try:
    os.unlink(temporary)
except FileNotFoundError:
    pass
os.symlink(target, temporary)
os.replace(temporary, link)
PY
}

publish_repository() {
    current_stage="package-selection"
    if [ -z "$selected_package" ]; then
        select_package_for_publish
    fi
    if [ "$dry_run" -eq 1 ]; then
        echo "dry-run: audit $(basename -- "$selected_package")"
        echo "dry-run: atomically publish repository at ProjectX/.deploy/repo"
        return 0
    fi

    current_stage="package-audit"
    /bin/sh "$project_root/scripts/check_roothide.sh" --check-package "$selected_package"

    current_stage="apt-publication"
    temporary_path=$(mktemp -d "$state_dir/.publish.XXXXXX")
    publish_repo="$temporary_path/repository"
    mkdir -p "$publish_repo/pool" "$temporary_path/package"
    validate_package_identity "$selected_package" "$temporary_path/package"
    for forbidden_field in Filename Size MD5sum SHA1 SHA256; do
        if grep -Eq "^${forbidden_field}:" "$package_control_path"; then
            fail "package control unexpectedly contains repository field: $forbidden_field"
        fi
    done
    publish_basename=$(basename -- "$selected_package")
    cp -f "$selected_package" "$publish_repo/pool/$publish_basename"
    publish_package="$publish_repo/pool/$publish_basename"
    publish_size=$(file_size "$publish_package")
    publish_md5=$(hash_file md5 "$publish_package")
    publish_sha1=$(hash_file sha1 "$publish_package")
    publish_sha256=$(hash_file sha256 "$publish_package")
    {
        cat "$package_control_path"
        printf 'Filename: pool/%s\n' "$publish_basename"
        printf 'Size: %s\n' "$publish_size"
        printf 'MD5sum: %s\n' "$publish_md5"
        printf 'SHA1: %s\n' "$publish_sha1"
        printf 'SHA256: %s\n' "$publish_sha256"
    } > "$publish_repo/Packages"
    gzip -9 -n -c "$publish_repo/Packages" > "$publish_repo/Packages.gz"
    xz -9 -c "$publish_repo/Packages" > "$publish_repo/Packages.xz"
    zstd -q -19 -T1 -f "$publish_repo/Packages" -o "$publish_repo/Packages.zst"

    {
        echo "Origin: XenSpace Local Repository"
        echo "Label: XenSpace Local Repository"
        echo "Suite: stable"
        echo "Codename: projectx-local"
        echo "Version: 1.0"
        echo "Architectures: iphoneos-arm64e"
        echo "Components: main"
        echo "Description: Local RootHide development packages for XenSpace"
        LC_ALL=C date -u '+Date: %a, %d %b %Y %H:%M:%S GMT'
        echo "Acquire-By-Hash: no"
        for publish_section in MD5Sum SHA1 SHA256; do
            echo "$publish_section:"
            case "$publish_section" in
                MD5Sum) publish_algorithm=md5 ;;
                SHA1) publish_algorithm=sha1 ;;
                SHA256) publish_algorithm=sha256 ;;
            esac
            for publish_index in Packages Packages.gz Packages.xz Packages.zst; do
                printf ' %s %16s %s\n' \
                    "$(hash_file "$publish_algorithm" "$publish_repo/$publish_index")" \
                    "$(file_size "$publish_repo/$publish_index")" \
                    "$publish_index"
            done
        done
    } > "$publish_repo/Release"

    validate_repository_dir "$publish_repo" || fail "generated APT repository failed local validation"
    generation_name="${package_identity_version}-${publish_sha256}"
    generation_destination="$generations_dir/$generation_name"
    if [ -e "$generation_destination" ]; then
        validate_repository_dir "$generation_destination" || fail "existing matching repository generation is invalid"
        remove_deploy_paths "$publish_repo"
    else
        mv -f "$publish_repo" "$generation_destination"
    fi
    atomic_repository_link "state/generations/$generation_name" "$repository_link"
    for old_generation in "$generations_dir"/*; do
        [ -e "$old_generation" ] || continue
        [ "$old_generation" = "$generation_destination" ] || remove_deploy_paths "$old_generation"
    done
    remove_deploy_paths "$temporary_path"
    temporary_path=""
    validate_repository_dir "$repository_link" || fail "published APT repository failed validation"
    echo "published_version=$repository_version"
    echo "published_architecture=$repository_architecture"
    echo "published_filename=$repository_filename"
    echo "published_size=$repository_size"
    echo "published_sha256=$repository_sha256"
}

configuration_signature() {
    {
        printf '%s\n' "$state_dir"
        printf '%s\n' "$source_url"
        printf '%s\n' "$http_port"
        printf '%s\n' "$device_port"
        printf '%s\n' "$ssh_host"
        printf '%s\n' "$ssh_port"
        printf '%s\n' "$ssh_user"
        printf '%s\n' "$ssh_identity"
    } | hash_text_sha256
}

write_ssh_configs() {
    client_temp="$ssh_client_config.tmp.$$"
    tunnel_temp="$ssh_tunnel_config.tmp.$$"
    sanitizer_temp="$ssh_sanitizer.tmp.$$"
    cat > "$client_temp" <<EOF
Host projectx-sileo-client
    HostName $ssh_host
    User $ssh_user
    Port $ssh_port
    IdentityFile "$ssh_identity"
    IdentitiesOnly yes
    BatchMode yes
    NumberOfPasswordPrompts 0
    StrictHostKeyChecking yes
    UpdateHostKeys no
    ConnectTimeout 10
    LogLevel ERROR
EOF
    cat > "$tunnel_temp" <<EOF
Host projectx-sileo-tunnel
    HostName $ssh_host
    User $ssh_user
    Port $ssh_port
    IdentityFile "$ssh_identity"
    IdentitiesOnly yes
    BatchMode yes
    NumberOfPasswordPrompts 0
    StrictHostKeyChecking yes
    UpdateHostKeys no
    ExitOnForwardFailure yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
    LogLevel ERROR
    RemoteForward 127.0.0.1:$device_port 127.0.0.1:$http_port
EOF
    cat > "$sanitizer_temp" <<'EOF'
s/connect to host [^ ]+ port [0-9]+/connect to [ssh-endpoint]/g
s/Connection to [^ ]+/Connection to [ssh-endpoint]/g
s/([Hh]ostname|[Hh]ost|to) [A-Za-z0-9._:-]+/\1 [ssh-endpoint]/g
s/[A-Za-z0-9._-]+@[A-Za-z0-9._-]+/[ssh-endpoint]/g
s/([Pp]ort) [0-9]+/\1 [redacted]/g
s#([Ii]dentity file) [^ ]+#\1 [ssh-identity]#g
s#Load key "[^"]+"#Load key "[ssh-identity]"#g
s/([0-9]{1,3}\.){3}[0-9]{1,3}/[ssh-address]/g
EOF
    chmod 600 "$client_temp" "$tunnel_temp" "$sanitizer_temp"
    mv -f "$client_temp" "$ssh_client_config"
    mv -f "$tunnel_temp" "$ssh_tunnel_config"
    mv -f "$sanitizer_temp" "$ssh_sanitizer"
}

sanitize_ssh_diagnostics() {
    sed -E -f "$ssh_sanitizer" "$1"
}

remote_fetch() {
    remote_path=$1
    remote_destination=$2
    remote_quiet=${3:-0}
    case "$remote_path" in
        /*) ;;
        *) fail "remote repository path must be absolute" ;;
    esac
    case "$remote_path" in
        *..*|*//*|*' '*|*'
'*) fail "remote repository path contains unsafe characters" ;;
    esac
    remote_error=$(mktemp "$state_dir/.ssh-error.XXXXXX")
    if ssh -F "$ssh_client_config" projectx-sileo-client \
        /usr/bin/zsh -s -- "$device_port" "$remote_path" \
        > "$remote_destination" 2> "$remote_error" <<'REMOTE_ZSH'
set -eu
zmodload zsh/net/tcp
port=$1
request_path=$2
ztcp 127.0.0.1 "$port"
socket_fd=$REPLY
printf 'GET %s HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n' "$request_path" >&$socket_fd
IFS= read -r response_line <&$socket_fd
response_line=${response_line%$'\r'}
case "$response_line" in
    'HTTP/'*' 200 '*) ;;
    *) print -u2 -r -- "repository request failed: $request_path ($response_line)"; exit 22 ;;
esac
while IFS= read -r header_line <&$socket_fd; do
    header_line=${header_line%$'\r'}
    [ -n "$header_line" ] || break
done
command dd bs=65536 <&$socket_fd 2>/dev/null
ztcp -c "$socket_fd"
REMOTE_ZSH
    then
        remove_deploy_paths "$remote_error"
        return 0
    else
        remote_status=$?
    fi
    if [ "$remote_quiet" -eq 0 ]; then
        sanitize_ssh_diagnostics "$remote_error" >&2
    fi
    remove_deploy_paths "$remote_error" "$remote_destination"
    return "$remote_status"
}

remote_port_open() {
    remote_port_error=$(mktemp "$state_dir/.ssh-port-error.XXXXXX")
    if ssh -F "$ssh_client_config" projectx-sileo-client \
        /usr/bin/zsh -s -- "$device_port" >/dev/null 2> "$remote_port_error" <<'REMOTE_PORT_ZSH'
set -eu
zmodload zsh/net/tcp
ztcp 127.0.0.1 "$1"
socket_fd=$REPLY
ztcp -c "$socket_fd"
REMOTE_PORT_ZSH
    then
        remove_deploy_paths "$remote_port_error"
        return 0
    fi
    remove_deploy_paths "$remote_port_error"
    return 1
}

http_listener_pids() {
    lsof -nP -tiTCP:"$http_port" -sTCP:LISTEN 2>/dev/null | awk '!seen[$0]++'
}

write_supervisor_status() {
    supervisor_status_state=$1
    supervisor_status_component=$2
    supervisor_status_code=$3
    supervisor_status_temp="$supervisor_status_file.tmp.$$"
    {
        printf 'state=%s\n' "$supervisor_status_state"
        printf 'component=%s\n' "$supervisor_status_component"
        printf 'exit_code=%s\n' "$supervisor_status_code"
    } > "$supervisor_status_temp"
    mv -f "$supervisor_status_temp" "$supervisor_status_file"
}

supervisor_cleanup() {
    supervisor_cleanup_code=$?
    trap - EXIT HUP INT TERM
    for supervisor_cleanup_pid in "$supervised_tunnel_pid" "$supervised_http_pid" "$supervised_sanitizer_pid"; do
        case "$supervisor_cleanup_pid" in
            ''|*[!0-9]*) ;;
            *) kill -TERM "$supervisor_cleanup_pid" 2>/dev/null || true ;;
        esac
    done
    for supervisor_cleanup_pid in "$supervised_tunnel_pid" "$supervised_http_pid" "$supervised_sanitizer_pid"; do
        case "$supervisor_cleanup_pid" in
            ''|*[!0-9]*) ;;
            *) wait "$supervisor_cleanup_pid" 2>/dev/null || true ;;
        esac
    done
    remove_deploy_paths "$run_dir/tunnel.stderr.pipe"
    if [ "$supervisor_exit_component" = stop-request ]; then
        write_supervisor_status stopped supervisor 0
    else
        write_supervisor_status failed "$supervisor_exit_component" "$supervisor_cleanup_code"
    fi
    exit "$supervisor_cleanup_code"
}

run_supervisor() {
    current_stage="supervisor"
    validate_repository_dir "$repository_link" || fail "published repository is invalid"
    [ -f "$ssh_tunnel_config" ] && [ -f "$ssh_sanitizer" ] ||
        fail "supervisor SSH state is missing; run start"
    supervised_http_pid=""
    supervised_tunnel_pid=""
    supervised_sanitizer_pid=""
    supervisor_exit_component=supervisor-exit
    trap '' HUP
    trap 'supervisor_exit_component=stop-request; exit 0' TERM
    trap 'supervisor_exit_component=interrupt; exit 130' INT
    trap supervisor_cleanup EXIT

    supervisor_pipe="$run_dir/tunnel.stderr.pipe"
    remove_deploy_paths "$supervisor_pipe"
    mkfifo "$supervisor_pipe"
    chmod 600 "$supervisor_pipe"
    : >> "$logs_dir/http.log"
    : >> "$logs_dir/tunnel.log"

    sed -E -f "$ssh_sanitizer" < "$supervisor_pipe" >> "$logs_dir/tunnel.log" 2>&1 &
    supervised_sanitizer_pid=$!
    python3 -m http.server "$http_port" --bind 127.0.0.1 \
        --directory "$repository_link" >> "$logs_dir/http.log" 2>&1 &
    supervised_http_pid=$!
    ssh -F "$ssh_tunnel_config" projectx-sileo-tunnel -N -T \
        > "$supervisor_pipe" 2>&1 &
    supervised_tunnel_pid=$!
    write_supervisor_status running all 0

    while :; do
        if ! kill -0 "$supervised_http_pid" 2>/dev/null; then
            supervisor_exit_component=http
            wait "$supervised_http_pid" 2>/dev/null || true
            supervised_http_pid=""
            return 1
        fi
        if ! kill -0 "$supervised_tunnel_pid" 2>/dev/null; then
            supervisor_exit_component=tunnel
            wait "$supervised_tunnel_pid" 2>/dev/null || true
            supervised_tunnel_pid=""
            return 1
        fi
        if ! kill -0 "$supervised_sanitizer_pid" 2>/dev/null; then
            supervisor_exit_component=log-sanitizer
            wait "$supervised_sanitizer_pid" 2>/dev/null || true
            supervised_sanitizer_pid=""
            return 1
        fi
        sleep 0.2
    done
}

owned_http_child_pid() {
    owned_http_supervisor=$1
    owned_http_child=$(supervisor_child_pid "$owned_http_supervisor" 'http.server') || return 1
    owned_http_listeners=$(http_listener_pids || true)
    [ -n "$owned_http_listeners" ] || return 1
    for owned_http_listener in $owned_http_listeners; do
        [ "$owned_http_listener" = "$owned_http_child" ] || return 1
    done
    printf '%s\n' "$owned_http_child"
}

http_service_is_healthy() {
    healthy_http_supervisor=$1
    owned_http_child_pid "$healthy_http_supervisor" >/dev/null 2>&1 || return 1
    healthy_http_probe=$(mktemp "$state_dir/.http-probe.XXXXXX")
    if curl -fsS "http://127.0.0.1:$http_port/Release" > "$healthy_http_probe" 2>/dev/null &&
        cmp -s "$repository_link/Release" "$healthy_http_probe"; then
        healthy_http_result=0
    else
        healthy_http_result=1
    fi
    remove_deploy_paths "$healthy_http_probe"
    return "$healthy_http_result"
}

tunnel_endpoint_state() {
    tunnel_state_probe=$(mktemp "$state_dir/.tunnel-state.XXXXXX")
    if remote_fetch /Release "$tunnel_state_probe" 1; then
        if cmp -s "$repository_link/Release" "$tunnel_state_probe"; then
            tunnel_state_result=healthy
        else
            tunnel_state_result=mismatch
        fi
    else
        tunnel_state_result=unreachable
    fi
    remove_deploy_paths "$tunnel_state_probe"
    printf '%s\n' "$tunnel_state_result"
}

tunnel_service_is_healthy() {
    healthy_tunnel_supervisor=$1
    supervisor_child_pid "$healthy_tunnel_supervisor" 'projectx-sileo-tunnel -N -T' >/dev/null 2>&1 || return 1
    [ "$(tunnel_endpoint_state)" = healthy ]
}

supervisor_services_are_healthy() {
    healthy_supervisor_pid=$1
    http_service_is_healthy "$healthy_supervisor_pid" &&
        tunnel_service_is_healthy "$healthy_supervisor_pid"
}

wait_for_supervisor_services() {
    wait_supervisor_attempt=0
    while [ "$wait_supervisor_attempt" -lt 50 ]; do
        if wait_supervisor_pid=$(owned_supervisor_pid 2>/dev/null) &&
            supervisor_services_are_healthy "$wait_supervisor_pid"; then
            return 0
        fi
        sleep 0.2
        wait_supervisor_attempt=$((wait_supervisor_attempt + 1))
    done
    return 1
}

launch_supervisor() {
    listener_pids=$(http_listener_pids || true)
    [ -z "$listener_pids" ] || fail "PROJECTX_SILEO_HTTP_PORT is owned by a foreign process"
    remote_port_open && fail "device source port is reachable through a foreign reverse tunnel"
    : >> "$logs_dir/supervisor.log"
    PROJECTX_DEPLOY_SUPERVISOR=1 nohup "$script_path" __supervise \
        </dev/null >> "$logs_dir/supervisor.log" 2>&1 &
    launched_supervisor_pid=$!
    if ! record_supervisor "$launched_supervisor_pid"; then
        kill -TERM "$launched_supervisor_pid" 2>/dev/null || true
        wait "$launched_supervisor_pid" 2>/dev/null || true
        fail "supervisor exited before ownership could be recorded"
    fi
    started_supervisor=1
    wait_for_supervisor_services ||
        fail "owned supervisor did not establish healthy HTTP and tunnel children; inspect ProjectX/.deploy/logs"
    echo "supervisor=started pid=$launched_supervisor_pid"
}

start_services() {
    current_stage="service-start"
    validate_repository_dir "$repository_link" || fail "publish a valid repository before start"
    write_ssh_configs
    new_signature=$(configuration_signature)
    if current_supervisor_pid=$(owned_supervisor_pid 2>/dev/null); then
        [ -f "$run_dir/config.signature" ] || fail "owned supervisor configuration state is missing; run stop"
        existing_signature=$(awk 'NR == 1 { print; exit }' "$run_dir/config.signature")
        [ "$new_signature" = "$existing_signature" ] || fail "owned services use different configuration; run stop first"
        if supervisor_services_are_healthy "$current_supervisor_pid"; then
            echo "supervisor=reused pid=$current_supervisor_pid"
            return 0
        fi
        stop_verified_supervisor 1 || fail "unhealthy owned supervisor could not be stopped safely"
    elif supervisor_state_is_stale; then
        remove_deploy_paths "$supervisor_pid_file" "$supervisor_start_file" "$supervisor_fingerprint_file"
    fi
    printf '%s\n' "$new_signature" > "$run_dir/config.signature"
    cleanup_on_failure=1
    launch_supervisor
}

verify_services() {
    current_stage="device-verification"
    validate_repository_dir "$repository_link" || fail "published repository is invalid"
    write_ssh_configs
    verify_supervisor_pid=$(owned_supervisor_pid 2>/dev/null) ||
        fail "detached supervisor is not owned and healthy; run start"
    http_service_is_healthy "$verify_supervisor_pid" ||
        fail "supervised HTTP service is not owned and healthy; run start"
    tunnel_service_is_healthy "$verify_supervisor_pid" ||
        fail "supervised reverse tunnel is not owned and healthy; run start"
    expected_signature=$(configuration_signature)
    [ -f "$run_dir/config.signature" ] &&
        [ "$(awk 'NR == 1 { print; exit }' "$run_dir/config.signature")" = "$expected_signature" ] ||
        fail "owned service configuration does not match current configuration"
    verify_work=$(mktemp -d "$state_dir/.verify-device.XXXXXX")
    temporary_path=$verify_work
    remote_fetch / "$verify_work/root"
    [ -s "$verify_work/root" ] || fail "device repository root returned an empty response"
    for verify_name in Release Packages Packages.gz Packages.xz Packages.zst; do
        remote_fetch "/$verify_name" "$verify_work/$verify_name"
        cmp -s "$repository_link/$verify_name" "$verify_work/$verify_name" ||
            fail "device response does not match published $verify_name"
    done
    remote_fetch "/$repository_filename" "$verify_work/package.deb"
    cmp -s "$repository_link/$repository_filename" "$verify_work/package.deb" ||
        fail "device package response does not match the published deb"
    [ "$(file_size "$verify_work/package.deb")" = "$repository_size" ] ||
        fail "device package size does not match Packages metadata"
    [ "$(hash_file sha256 "$verify_work/package.deb")" = "$repository_sha256" ] ||
        fail "device package SHA256 does not match Packages metadata"
    remove_deploy_paths "$verify_work"
    temporary_path=""
    echo "verified_source=stable-loopback"
    echo "verified_version=$repository_version"
    echo "verified_architecture=$repository_architecture"
    echo "verified_filename=$repository_filename"
    echo "verified_size=$repository_size"
    echo "verified_sha256=$repository_sha256"
}

show_status() {
    current_stage="status"
    status_ok=1
    write_ssh_configs
    if validate_repository_dir "$repository_link"; then
        repository_status=healthy
    else
        repository_status=missing-or-invalid
        status_ok=0
    fi
    if status_supervisor_pid=$(owned_supervisor_pid 2>/dev/null); then
        supervisor_status=owned
        if [ ! -f "$run_dir/config.signature" ] ||
            [ "$(awk 'NR == 1 { print; exit }' "$run_dir/config.signature")" != "$(configuration_signature)" ]; then
            supervisor_status=stale-config
            http_status=unhealthy-owned
            tunnel_status=unhealthy-owned
        else
            if http_service_is_healthy "$status_supervisor_pid"; then
                http_status=healthy-owned
            else
                http_status=unhealthy-owned
            fi
            if tunnel_service_is_healthy "$status_supervisor_pid"; then
                tunnel_status=healthy-owned
            else
                tunnel_status=unhealthy-owned
            fi
        fi
    elif supervisor_state_is_stale; then
        supervisor_status=stale
        if [ -n "$(http_listener_pids || true)" ]; then
            http_status=foreign-process
        else
            http_status=down
        fi
        if remote_port_open; then
            tunnel_status=foreign
        else
            tunnel_status=down
        fi
    else
        supervisor_status=down
        if [ -n "$(http_listener_pids || true)" ]; then
            http_status=foreign-process
        else
            http_status=down
        fi
        if remote_port_open; then
            tunnel_status=foreign
        else
            tunnel_status=down
        fi
    fi

    endpoint_status=$(tunnel_endpoint_state)
    if [ "$repository_status" != healthy ] && [ "$endpoint_status" = healthy ]; then
        endpoint_status=mismatch
    fi
    [ "$supervisor_status" = owned ] || status_ok=0
    [ "$http_status" = healthy-owned ] || status_ok=0
    [ "$tunnel_status" = healthy-owned ] || status_ok=0
    [ "$endpoint_status" = healthy ] || status_ok=0

    echo "repository=$repository_status"
    if [ "$repository_status" = healthy ]; then
        echo "package_version=$repository_version"
        echo "package_architecture=$repository_architecture"
        echo "package_filename=$repository_filename"
        echo "package_sha256=$repository_sha256"
    fi
    echo "supervisor=$supervisor_status"
    echo "http=$http_status"
    echo "tunnel=$tunnel_status"
    echo "device_endpoint=$endpoint_status"
    echo "supervisor_log=$logs_dir/supervisor.log"
    echo "http_log=$logs_dir/http.log"
    echo "tunnel_log=$logs_dir/tunnel.log"
    [ "$status_ok" -eq 1 ]
}

stop_services() {
    current_stage="service-stop"
    if [ "$dry_run" -eq 1 ]; then
        echo "dry-run: signal only the PID/start/fingerprint-verified detached supervisor"
        return 0
    fi
    stop_verified_supervisor || fail "could not stop the verified owned supervisor"
    remove_deploy_paths "$run_dir/http.pid" "$run_dir/http.start" \
        "$run_dir/tunnel.pid" "$run_dir/tunnel.start" \
        "$run_dir/sanitizer.pid" "$run_dir/sanitizer.start" \
        "$run_dir/tunnel.stderr.pipe" "$run_dir/config.signature" \
        "$run_dir/tunnel-sanitize.sed" "$ssh_sanitizer" \
        "$ssh_client_config" "$ssh_tunnel_config" "$run_dir/services"
    echo "logs_preserved=$logs_dir"
}

case "$command_name" in
    deploy)
        validate_build_configuration
        require_publish_commands
        require_connection_commands
        if [ "$dry_run" -eq 1 ]; then
            echo "dry-run: build-audit -> publish -> start -> verify"
            echo "dry-run: no Sileo source or package installation action"
            exit 0
        fi
        initialize_state
        acquire_lock
        build_project
        publish_repository
        start_services
        verify_services
        ;;
    build-publish)
        validate_publish_configuration
        require_publish_commands
        if [ "$dry_run" -eq 1 ]; then
            echo "dry-run: build-audit -> publish to ProjectX/.deploy/repo"
            echo "dry-run: do not start local HTTP or SSH services"
            exit 0
        fi
        initialize_state
        acquire_lock
        build_project
        publish_repository
        ;;
    publish)
        validate_publish_configuration
        require_publish_commands
        if [ "$dry_run" -eq 1 ]; then
            source_version=$(control_field Version "$project_root/control") || fail "source control has invalid Version metadata"
            echo "dry-run: select and audit current ProjectX package version $source_version"
            echo "dry-run: atomically publish repository at ProjectX/.deploy/repo"
            exit 0
        fi
        initialize_state
        acquire_lock
        publish_repository
        ;;
    start)
        validate_connection_configuration
        require_publish_commands
        require_connection_commands
        if [ "$dry_run" -eq 1 ]; then
            echo "dry-run: start one detached nohup supervisor for owned loopback HTTP and reverse-tunnel children"
            exit 0
        fi
        initialize_state
        acquire_lock
        start_services
        ;;
    verify)
        validate_connection_configuration
        require_publish_commands
        require_connection_commands
        if [ "$dry_run" -eq 1 ]; then
            echo "dry-run: verify root, Release, Packages, Packages.gz, Packages.xz, Packages.zst, and exact deb through device loopback"
            exit 0
        fi
        initialize_state
        verify_services
        ;;
    status)
        validate_connection_configuration
        require_publish_commands
        require_connection_commands
        initialize_state
        show_status
        ;;
    stop)
        validate_state_configuration
        require_command ps
        require_command shasum
        if [ "$dry_run" -eq 1 ]; then
            stop_services
            exit 0
        fi
        initialize_state
        acquire_lock
        stop_services
        ;;
    __supervise)
        [ "${PROJECTX_DEPLOY_SUPERVISOR:-}" = 1 ] || fail "internal supervisor mode is not a public command"
        validate_connection_configuration
        require_publish_commands
        require_connection_commands
        initialize_state
        run_supervisor
        ;;
esac
