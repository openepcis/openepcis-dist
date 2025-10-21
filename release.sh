#!/usr/bin/env bash
set -euo pipefail

################################################################################
# OpenEPCIS Distribution Release Script
#
# Usage: ./release.sh <version> [--dry-run] [--gpg-passphrase <pass>]
# Example: ./release.sh 0.9.4
################################################################################

RELEASE_VERSION=""
DRY_RUN=false
GPG_PASSPHRASE=""
DEV_VERSION="999-SNAPSHOT"
LOG_FILE="release-$(date +%Y%m%d-%H%M%S).log"

# Module release order (dependencies first)
MODULES=(
    "openepcis-bom"
    "openepcis-epcis-constants"
    "openepcis-test-resources"
    "openepcis-s3"
    "openepcis-models"
    "openepcis-epc-digitallink-translator"
    "openepcis-document-converter"
    "openepcis-document-validation-service"
    "openepcis-reactive-event-publisher"
    "openepcis-event-hash-generator"
)

################################################################################
# Utility Functions
################################################################################

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} $*" | tee -a "$LOG_FILE"
}

prompt_continue() {
    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would prompt: $1"
        return 0
    fi

    echo ""
    echo "$1"
    read -p "Continue? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "ERROR: Operation cancelled by user"
        exit 1
    fi
}

execute_command() {
    local description=$1
    shift
    local command="$*"

    log "Executing: $description"

    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would execute: $command"
        return 0
    fi

    if eval "$command" >> "$LOG_FILE" 2>&1; then
        log "SUCCESS: $description"
        return 0
    else
        log "ERROR: $description failed (see $LOG_FILE)"
        return 1
    fi
}

################################################################################
# Validation Functions
################################################################################

validate_prerequisites() {
    log "Validating prerequisites..."

    if [ ! -f "pom.xml" ] || [ ! -d "modules" ]; then
        log "ERROR: Must be run from openepcis-dist root directory"
        exit 1
    fi

    if ! command -v mvn &> /dev/null; then
        log "ERROR: Maven not found"
        exit 1
    fi
    log "Maven: $(mvn -version | head -1)"

    if ! command -v git &> /dev/null; then
        log "ERROR: Git not found"
        exit 1
    fi
    log "Git: $(git --version)"

    if ! command -v gpg &> /dev/null; then
        log "ERROR: GPG not found"
        exit 1
    fi

    local gpg_key="759F1D2BF6B65D135FAD2716A355F274126C92B8"
    if ! gpg --list-secret-keys "$gpg_key" &> /dev/null; then
        log "ERROR: Required GPG key not found: $gpg_key"
        exit 1
    fi
    log "GPG key: $gpg_key"

    if [ ! -f "$HOME/.m2/settings.xml" ]; then
        log "WARNING: Maven settings.xml not found - make sure Sonatype credentials are configured"
    fi

    if [[ ! $RELEASE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
        log "ERROR: Invalid version format: $RELEASE_VERSION"
        log "Expected: X.Y.Z or X.Y.Z-qualifier (e.g., 0.9.4)"
        exit 1
    fi

    log "Prerequisites validated"
}

validate_module_state() {
    local module=$1
    local module_path="modules/$module"

    log "Validating $module..."

    if [ ! -d "$module_path" ]; then
        log "ERROR: Module directory not found: $module_path"
        return 1
    fi

    cd "$module_path"

    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$current_branch" != "main" ]; then
        log "WARNING: $module is on branch '$current_branch', not 'main'"
        cd ../..
        return 1
    fi

    if [ -n "$(git status --porcelain)" ]; then
        log "WARNING: $module has uncommitted changes"
        git status --short
        cd ../..
        return 1
    fi

    if git rev-parse "v$RELEASE_VERSION" &> /dev/null; then
        log "WARNING: Tag v$RELEASE_VERSION already exists in $module"
        cd ../..
        return 1
    fi

    cd ../..
    log "$module validated"
    return 0
}

validate_all_modules() {
    log "Validating all modules..."

    local failed_modules=()

    for module in "${MODULES[@]}"; do
        if ! validate_module_state "$module"; then
            failed_modules+=("$module")
        fi
    done

    if [ ${#failed_modules[@]} -gt 0 ]; then
        log "ERROR: The following modules failed validation:"
        for module in "${failed_modules[@]}"; do
            log "  - $module"
        done
        exit 1
    fi

    log "All modules validated"
}

################################################################################
# Release Functions
################################################################################

release_module() {
    local module=$1
    local module_path="modules/$module"

    log ""
    log "Releasing $module..."
    log "-------------------------------------------------------------------"

    cd "$module_path"

    # Update to release version
    if ! execute_command "Update version to $RELEASE_VERSION" \
        "mvn versions:set -DnewVersion=$RELEASE_VERSION -DgenerateBackupPoms=false"; then
        cd ../..
        return 1
    fi

    if ! execute_command "Commit release version" \
        "git add -A && git commit -m 'Release version $RELEASE_VERSION'"; then
        cd ../..
        return 1
    fi

    # Build and deploy
    log "Building and deploying to Maven Central (this may take several minutes)..."
    local deploy_cmd="mvn clean deploy -Popenepcis-ossrh"
    if [ -n "$GPG_PASSPHRASE" ]; then
        deploy_cmd="$deploy_cmd -Dgpg.passphrase=$GPG_PASSPHRASE"
    fi

    if ! execute_command "Deploy to Maven Central" "$deploy_cmd"; then
        log "ERROR: Deployment failed for $module"
        cd ../..
        return 1
    fi

    # Tag and push
    if ! execute_command "Create and push tag" \
        "git tag -a v$RELEASE_VERSION -m 'Release version $RELEASE_VERSION' && git push origin main && git push origin v$RELEASE_VERSION"; then
        cd ../..
        return 1
    fi

    # Revert to dev version
    if ! execute_command "Revert to $DEV_VERSION" \
        "mvn versions:set -DnewVersion=$DEV_VERSION -DgenerateBackupPoms=false && git add -A && git commit -m 'Back to $DEV_VERSION for development' && git push origin main"; then
        cd ../..
        return 1
    fi

    # Update submodule reference in parent
    cd ../..
    if ! execute_command "Update submodule reference" \
        "git add $module_path && git commit -m 'Update $module submodule to v$RELEASE_VERSION'"; then
        return 1
    fi

    log "SUCCESS: $module released"
    return 0
}

release_all_modules() {
    log "Starting release process..."
    log "Release version: $RELEASE_VERSION"
    log "Development version: $DEV_VERSION"
    log "Total modules: ${#MODULES[@]}"

    prompt_continue "About to release ${#MODULES[@]} modules (will take 30-45 minutes)"

    local failed_modules=()
    local released_modules=()

    for module in "${MODULES[@]}"; do
        if release_module "$module"; then
            released_modules+=("$module")
        else
            failed_modules+=("$module")
            log "ERROR: $module failed"
            log "Released so far: ${released_modules[*]}"
            log "Remaining: ${MODULES[@]:$((${#released_modules[@]} + 1))}"
            prompt_continue "Continue with remaining modules?"
        fi
    done

    if [ ${#failed_modules[@]} -gt 0 ]; then
        log "ERROR: Failed modules: ${failed_modules[*]}"
        return 1
    fi

    log "All modules released successfully"
    return 0
}

update_parent_repository() {
    log ""
    log "Updating parent repository..."

    if ! execute_command "Release parent version" \
        "mvn versions:set -DnewVersion=$RELEASE_VERSION -DgenerateBackupPoms=false && git add pom.xml && git commit -m 'Release version $RELEASE_VERSION' && git tag -a v$RELEASE_VERSION -m 'Release version $RELEASE_VERSION' && git push origin main && git push origin v$RELEASE_VERSION"; then
        return 1
    fi

    if ! execute_command "Revert parent to dev version" \
        "mvn versions:set -DnewVersion=$DEV_VERSION -DgenerateBackupPoms=false && git add pom.xml && git commit -m 'Back to $DEV_VERSION for development' && git push origin main"; then
        return 1
    fi

    log "Parent repository updated"
    return 0
}

################################################################################
# Main Script
################################################################################

show_usage() {
    cat << EOF
Usage: $0 <version> [OPTIONS]

Arguments:
  version           Release version (e.g., 0.9.4)

Options:
  --dry-run         Simulate without making changes
  --gpg-passphrase  GPG passphrase for signing
  --help            Show this help

Examples:
  $0 0.9.4
  $0 0.9.4 --dry-run
  $0 0.9.4 --gpg-passphrase "pass"

This script releases all OpenEPCIS modules to Maven Central in dependency order,
then reverts everything back to $DEV_VERSION for development.

Prerequisites:
  - Sonatype credentials in ~/.m2/settings.xml
  - GPG key 759F1D2BF6B65D135FAD2716A355F274126C92B8
  - All modules on 'main' branch with clean state
  - Estimated time: 30-45 minutes

EOF
}

main() {
    log "OpenEPCIS Distribution Release Script"
    log "Start: $(date)"
    log "Log file: $LOG_FILE"

    if [ $# -eq 0 ]; then
        show_usage
        exit 1
    fi

    RELEASE_VERSION=$1
    shift

    while [ $# -gt 0 ]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                log "DRY-RUN MODE - No changes will be made"
                shift
                ;;
            --gpg-passphrase)
                GPG_PASSPHRASE=$2
                shift 2
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                log "ERROR: Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    validate_prerequisites
    validate_all_modules

    if [ "$DRY_RUN" = false ]; then
        prompt_continue "All validations passed. Ready to start release."
    fi

    if ! release_all_modules; then
        log "ERROR: Release process failed (see $LOG_FILE)"
        exit 1
    fi

    if ! update_parent_repository; then
        log "ERROR: Failed to update parent (modules released, parent needs manual update)"
        exit 1
    fi

    log ""
    log "RELEASE COMPLETE"
    log "Version $RELEASE_VERSION released to Maven Central"
    log "All repositories reverted to $DEV_VERSION"
    log "End: $(date)"
    log "Full log: $LOG_FILE"
}

main "$@"
