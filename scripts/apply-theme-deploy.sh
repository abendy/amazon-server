#!/usr/bin/env bash

set -euo pipefail

REMOTE='origin'
LIVE_REF_PREFIX='deploy/live'
APPLY_STAGING_ROOT=''

usage() {
    cat <<'EOF'
Usage:
  scripts/apply-theme-deploy.sh <ampas|guilds> <staging|production> <deploy/branch>

The optional THEME_DEPLOY_REPO_DIR environment variable overrides the deployed
theme repository path for a scratch or non-standard server layout.
EOF
}

validate_environment() {
    case "$1" in
        staging|production) return 0 ;;
        *)
            printf 'Environment must be staging or production: %s\n' "$1" >&2
            exit 1
            ;;
    esac
}

theme_config() {
    case "$1" in
        ampas)
            THEME_ROOT_REL='web/app/themes/cia-amazon-fyc-ampas-2026.1'
            DEFAULT_REPO_DIR='/var/www/html/amazon-studios-ampas'
            ;;
        guilds)
            THEME_ROOT_REL='web/app/themes/cia-amazon-fyc-guilds-2026.1'
            DEFAULT_REPO_DIR='/var/www/html/amazon-studios-guilds'
            ;;
        *)
            printf 'Theme must be ampas or guilds: %s\n' "$1" >&2
            exit 1
            ;;
    esac
}

fail_if_unexpected_files() {
    local deploy_commit="$1"
    local repo_dir="$2"
    local prefix="${THEME_ROOT_REL}/dist/"
    local deploy_files
    local unexpected_files

    deploy_files="$(git -C "$repo_dir" ls-tree -r --name-only "$deploy_commit")"
    if [ -z "$deploy_files" ]; then
        printf 'Deploy commit has no files: %s\n' "$deploy_commit" >&2
        exit 1
    fi

    unexpected_files="$(printf '%s\n' "$deploy_files" | awk -v prefix="$prefix" 'NF && index($0, prefix) != 1 { print }')"
    if [ -n "$unexpected_files" ]; then
        printf 'Deploy commit contains files outside %s/dist:\n%s\n' "$THEME_ROOT_REL" "$unexpected_files" >&2
        exit 1
    fi
}

sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        printf 'No SHA-256 command is available.\n' >&2
        return 1
    fi
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        printf 'No SHA-256 command is available.\n' >&2
        return 1
    fi
}

verify_dist_tree() {
    local deploy_commit="$1"
    local repo_dir="$2"
    local deploy_file
    local expected_hash
    local actual_hash
    local file_count=0

    while IFS= read -r deploy_file; do
        [ -n "$deploy_file" ] || continue
        [ -f "$repo_dir/$deploy_file" ] || {
            printf 'Applied file is missing: %s\n' "$deploy_file" >&2
            exit 1
        }
        expected_hash="$(git -C "$repo_dir" show "${deploy_commit}:${deploy_file}" | sha256_stream)"
        actual_hash="$(sha256_file "$repo_dir/$deploy_file")"
        if [ "$expected_hash" != "$actual_hash" ]; then
            printf 'Applied file hash mismatch: %s\n' "$deploy_file" >&2
            exit 1
        fi
        file_count=$((file_count + 1))
    done <<EOF
$(git -C "$repo_dir" ls-tree -r --name-only "$deploy_commit" -- "${THEME_ROOT_REL}/dist")
EOF

    [ "$file_count" -gt 0 ] || {
        printf 'Deploy commit has no dist files: %s\n' "$deploy_commit" >&2
        exit 1
    }
    printf 'Verified files: %s\n' "$file_count"
}

cleanup_staging() {
    if [ -n "$APPLY_STAGING_ROOT" ] && [ -d "$APPLY_STAGING_ROOT" ]; then
        rm -rf "$APPLY_STAGING_ROOT"
    fi
}

apply_deploy() {
    local theme="$1"
    local environment="$2"
    local deploy_branch="$3"
    local repo_dir
    local theme_dir
    local dist_dir
    local live_ref="${LIVE_REF_PREFIX}/${environment}"
    local deploy_commit
    local purge_script

    theme_config "$theme"
    validate_environment "$environment"
    case "$deploy_branch" in
        "deploy/${environment}-"*) ;;
        *)
            printf 'Deploy branch does not match %s: %s\n' "$environment" "$deploy_branch" >&2
            exit 1
            ;;
    esac

    repo_dir="${THEME_DEPLOY_REPO_DIR:-$DEFAULT_REPO_DIR}"
    theme_dir="$repo_dir/$THEME_ROOT_REL"
    dist_dir="$theme_dir/dist"
    purge_script="${THEME_DEPLOY_PURGE_SCRIPT:-$theme_dir/scripts/purge-titles-cache.sh}"

    [ -d "$repo_dir/.git" ] || {
        printf 'Theme repository is not a Git checkout: %s\n' "$repo_dir" >&2
        exit 1
    }
    [ -d "$theme_dir" ] || {
        printf 'Theme directory is missing: %s\n' "$theme_dir" >&2
        exit 1
    }
    [ -f "$purge_script" ] || {
        printf 'Cache purge script is missing: %s\n' "$purge_script" >&2
        exit 1
    }

    git -C "$repo_dir" fetch --prune "$REMOTE" \
        "refs/heads/${deploy_branch}:refs/remotes/${REMOTE}/${deploy_branch}"
    deploy_commit="$(git -C "$repo_dir" rev-parse "refs/remotes/${REMOTE}/${deploy_branch}")"
    printf 'Fetched: %s (%s)\n' "$deploy_branch" "$deploy_commit"
    fail_if_unexpected_files "$deploy_commit" "$repo_dir"

    APPLY_STAGING_ROOT="$(mktemp -d "$repo_dir/theme-deploy.XXXXXX")"
    trap cleanup_staging EXIT INT TERM
    git -C "$repo_dir" archive --format=tar "$deploy_commit" "$THEME_ROOT_REL/dist" | tar -x -C "$APPLY_STAGING_ROOT"
    [ -d "$APPLY_STAGING_ROOT/$THEME_ROOT_REL/dist" ] || {
        printf 'Fetched deploy branch did not produce a dist directory.\n' >&2
        exit 1
    }

    if [ -e "$dist_dir" ]; then
        mv "$dist_dir" "$APPLY_STAGING_ROOT/previous-dist"
    fi
    mv "$APPLY_STAGING_ROOT/$THEME_ROOT_REL/dist" "$dist_dir"
    verify_dist_tree "$deploy_commit" "$repo_dir"
    printf 'Applied: %s\n' "$dist_dir"

    printf 'Running cache purge: %s\n' "$purge_script"
    sh "$purge_script"

    # The live marker is a mutable ref, so moving it is always a force
    # push — and instance deploy keys are read-only by design, so this
    # step routinely fails on the box. The apply above already succeeded;
    # print the operator command instead of dying (#205).
    if git -C "$repo_dir" push --force "$REMOTE" \
        "${deploy_commit}:refs/heads/${live_ref}" 2>/dev/null; then
        printf 'Live marker: %s -> %s\n' "$live_ref" "$deploy_branch"
    else
        printf 'Live marker push failed (read-only deploy key?). Apply is complete.\n'
        printf 'Push the marker from a write-capable operator clone:\n'
        printf '  git push --force origin %s:refs/heads/%s\n' "$deploy_commit" "$live_ref"
    fi
}

main() {
    if [ "$#" -ne 3 ]; then
        usage >&2
        exit 1
    fi
    apply_deploy "$1" "$2" "$3"
}

main "$@"
