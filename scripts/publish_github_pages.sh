#!/bin/sh

set -eu

umask 077

export GIT_TERMINAL_PROMPT=0
export GCM_INTERACTIVE=Never
export GIT_ASKPASS=true
export SSH_ASKPASS=true
GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o StrictHostKeyChecking=yes"
export GIT_SSH_COMMAND

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
pages_branch=gh-pages
pages_url=https://gitssie.github.io/ProjectX
remote_name=origin
dry_run=0
package_override=""
command_name=""
temporary_root=""

usage() {
    cat <<'EOF'
Usage: scripts/publish_github_pages.sh [OPTIONS] publish

Build and audit XenSpace locally, render a complete Sileo repository into a
temporary directory, commit it on top of the remote gh-pages branch, and push
without force. The current main worktree is never switched to gh-pages.

Options:
  --dry-run             Validate configuration and report the publication plan.
  --package ABSOLUTE    Publish an already-built current package from packages/.
  -h, --help            Show this help.

Default behavior runs the complete warning-gated RootHide build first. The
optional package must still match control metadata, pass package audit, live in
ProjectX/packages, and be newer than the current source.

One-time GitHub setup after the first push:
  Settings -> Pages -> Deploy from a branch -> gh-pages -> /(root)
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

cleanup() {
    [ -n "$temporary_root" ] || return 0
    case "$temporary_root" in
        "$project_root/.deploy/tmp/github-pages."*)
            rm -rf -- "$temporary_root"
            ;;
        *)
            echo "error: refusing cleanup outside ProjectX/.deploy/tmp" >&2
            ;;
    esac
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for argument in "$@"; do
    case "$argument" in
        *'
'*) fail "arguments must not contain newlines" ;;
    esac
done

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            dry_run=1
            shift
            ;;
        --package)
            [ "$#" -ge 2 ] || fail "--package requires an absolute path"
            package_override=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        publish)
            command_name=publish
            shift
            break
            ;;
        *)
            fail "unknown option or command: $1 (use --help)"
            ;;
    esac
done

[ "$command_name" = publish ] || fail "the publish command is required (use --help)"
[ "$#" -eq 0 ] || fail "unexpected argument after publish: $1"

if [ -n "$package_override" ]; then
    case "$package_override" in
        /*) ;;
        *) fail "--package must be an absolute path" ;;
    esac
fi

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

for required_command in git python3 awk cp mktemp; do
    require_command "$required_command"
done

[ -f "$project_root/pages/index.html" ] || fail "pages/index.html is missing"
[ -f "$project_root/pages/depiction.json" ] || fail "pages/depiction.json is missing"
[ -x "$project_root/scripts/deploy_sileo.sh" ] || fail "scripts/deploy_sileo.sh is not executable"
[ -x "$project_root/scripts/render_github_pages.py" ] || fail "scripts/render_github_pages.py is not executable"

remote_url=$(git -C "$project_root" remote get-url "$remote_name" 2>/dev/null || true)
[ -n "$remote_url" ] || fail "Git remote '$remote_name' is missing"

assert_source_state() {
    [ "$(git -C "$project_root" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] ||
        fail "ProjectX is not a Git worktree"
    current_branch=$(git -C "$project_root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    [ "$current_branch" = main ] || fail "public releases must be published from the main branch"
    [ -z "$(git -C "$project_root" status --porcelain --untracked-files=normal)" ] ||
        fail "main worktree must be clean before public publication"

    verified_head_sha=$(git -C "$project_root" rev-parse HEAD)
    remote_main_line=$(git ls-remote --heads "$remote_url" refs/heads/main) ||
        fail "could not read remote main from $remote_name"
    remote_main_sha=$(printf '%s\n' "$remote_main_line" | awk 'NR == 1 { print $1 }')
    [ -n "$remote_main_sha" ] || fail "remote main branch is missing"
    [ "$verified_head_sha" = "$remote_main_sha" ] ||
        fail "local main must exactly match origin/main before public publication"
}

assert_source_state
release_head_sha=$verified_head_sha

if [ "$dry_run" -eq 1 ]; then
    if [ -n "$package_override" ]; then
        PROJECTX_SILEO_PACKAGE=$package_override \
            "$project_root/scripts/deploy_sileo.sh" --dry-run publish
    else
        "$project_root/scripts/deploy_sileo.sh" --dry-run build-publish
    fi
    echo "dry-run: render and validate $pages_url in ProjectX/.deploy/tmp"
    echo "dry-run: create a temporary Git repository from origin/$pages_branch"
    echo "dry-run: commit and non-force push HEAD:refs/heads/$pages_branch"
    exit 0
fi

if [ -n "$package_override" ]; then
    PROJECTX_SILEO_PACKAGE=$package_override \
        "$project_root/scripts/deploy_sileo.sh" publish
else
    "$project_root/scripts/deploy_sileo.sh" build-publish
fi

[ -d "$project_root/.deploy/tmp" ] || fail "deployment temporary directory was not initialized"
temporary_root=$(mktemp -d "$project_root/.deploy/tmp/github-pages.XXXXXX")
site_dir="$temporary_root/site"
git_dir="$temporary_root/git"
metadata_file="$temporary_root/metadata"
mkdir -p "$site_dir" "$git_dir"

"$project_root/scripts/render_github_pages.py" \
    --repository "$project_root/.deploy/repo" \
    --output "$site_dir" \
    --base-url "$pages_url" > "$metadata_file"

published_version=$(awk -F= '$1 == "version" { print substr($0, index($0, "=") + 1) }' "$metadata_file")
published_sha256=$(awk -F= '$1 == "sha256" { print substr($0, index($0, "=") + 1) }' "$metadata_file")
[ -n "$published_version" ] || fail "renderer did not report a package version"
[ -n "$published_sha256" ] || fail "renderer did not report a package SHA-256"

git -C "$git_dir" init --quiet
git -C "$git_dir" remote add "$remote_name" "$remote_url"
remote_pages_line=$(git ls-remote --heads "$remote_url" "refs/heads/$pages_branch") ||
    fail "could not inspect remote $pages_branch branch"
if [ -n "$remote_pages_line" ]; then
    git -C "$git_dir" fetch --quiet --depth=1 "$remote_name" "$pages_branch"
    git -C "$git_dir" checkout --quiet -B "$pages_branch" FETCH_HEAD
    git -C "$git_dir" rm -r -f --ignore-unmatch . >/dev/null
else
    git -C "$git_dir" checkout --quiet --orphan "$pages_branch"
fi

cp -Rf "$site_dir/." "$git_dir/"
git -C "$git_dir" add --all

# The local build can take minutes. Re-check source and remote main immediately
# before deciding whether this exact snapshot may update the public branch.
assert_source_state
[ "$verified_head_sha" = "$release_head_sha" ] ||
    fail "main HEAD changed while the public release was being prepared"

if git -C "$git_dir" diff --cached --quiet; then
    echo "already_published_version=$published_version"
    echo "already_published_sha256=$published_sha256"
    echo "source_url=$pages_url"
    exit 0
fi

git_user_name=$(git -C "$project_root" config user.name || true)
git_user_email=$(git -C "$project_root" config user.email || true)
[ -n "$git_user_name" ] || fail "git user.name must be configured before publishing"
[ -n "$git_user_email" ] || fail "git user.email must be configured before publishing"

git -C "$git_dir" \
    -c "user.name=$git_user_name" \
    -c "user.email=$git_user_email" \
    commit --quiet -m "repo: publish XenSpace $published_version"

# Keep the release authorization adjacent to the only external mutation. A
# hook or concurrent checkout may run while the temporary commit is created.
assert_source_state
[ "$verified_head_sha" = "$release_head_sha" ] ||
    fail "main HEAD changed while the public release was being prepared"
git -C "$git_dir" push "$remote_name" "HEAD:refs/heads/$pages_branch"

echo "published_version=$published_version"
echo "published_sha256=$published_sha256"
echo "published_branch=$pages_branch"
echo "source_url=$pages_url"
echo "sileo_url=sileo://source/$pages_url"
