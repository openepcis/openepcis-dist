#!/usr/bin/env bash
set -euo pipefail

################################################################################
# OpenEPCIS Distribution Release Script
#
# Usage: ./release.sh <version> [--dry-run] [--dry-run-deploy] [--gpg-passphrase <pass>]
# Example: ./release.sh 0.9.4
#
# --dry-run         prints what would happen, touches nothing
# --dry-run-deploy  sets the release version in every module, runs the full deploy build with
#                   signing but without the upload (-DskipNexusStagingDeployMojo=true), then
#                   restores the working trees. Run it once before the real release: it finds
#                   missing source jars, missing <name> elements and anything else Central
#                   would reject, without a tag or a commit.
################################################################################

RELEASE_VERSION=""
DRY_RUN=false
DRY_RUN_DEPLOY=false
GPG_PASSPHRASE=""
DEV_VERSION="999-SNAPSHOT"
# Absolute path so log writes don't land inside submodule dirs when we cd around
LOG_FILE="$(pwd)/release-$(date +%Y%m%d-%H%M%S).log"

# Module release order (dependencies first).
# The repo-level models<->digitallink cycle (models/epcis -> digital-link-converter-core,
# digitallink/utils -> model-core) is broken by bootstrap_model_core() below: model-core
# is a leaf w.r.t. digitallink, so it is installed locally first, then digitallink is
# released BEFORE models. Keep digitallink ahead of models in this list.
MODULES=(
    "openepcis-bom"
    "openepcis-epcis-constants"
    "openepcis-test-resources"
    "openepcis-s3"
    "openepcis-reactive-event-publisher"
    "openepcis-epc-digitallink-translator"
    "openepcis-models"
    "openepcis-document-validation-service"
    "openepcis-document-converter"
    "openepcis-event-hash-generator"
    # the Community Edition of the EPCIS repository: core needs models, converter, hash
    # generator and validation; rest-quarkus needs core
    "openepcis-core"
    "openepcis-rest-quarkus"
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

    local java_major
    java_major=$(java -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/')
    if [ "$java_major" != "25" ]; then
        log "ERROR: Java 25 required (openepcis-bom builds with release 25), found: $(java -version 2>&1 | head -1)"
        exit 1
    fi
    log "Java: $(java -version 2>&1 | head -1)"

    if [ -n "$GPG_PASSPHRASE" ]; then
        if ! echo release | gpg --batch --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" -u "$gpg_key" --sign > /dev/null 2>&1; then
            log "ERROR: GPG signing test failed for $gpg_key (wrong passphrase?)"
            exit 1
        fi
        log "GPG signing test passed"
    fi

    if ! command -v gh &> /dev/null; then
        log "WARNING: gh not found - GitHub releases will not be created"
    fi

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

    git fetch --tags --force --prune origin > /dev/null 2>&1 || true

    if [ -n "$(git ls-remote --tags origin "refs/tags/v$RELEASE_VERSION")" ]; then
        log "WARNING: Tag v$RELEASE_VERSION already exists on origin of $module"
        cd ../..
        return 1
    fi
    if git rev-parse "v$RELEASE_VERSION" &> /dev/null; then
        # local only, a leftover of an earlier attempt (the 2023 hash-generator tags, for one)
        log "Deleting stale local tag v$RELEASE_VERSION in $module (not on origin)"
        git tag -d "v$RELEASE_VERSION" > /dev/null
    fi

    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
        log "WARNING: $module HEAD is not origin/main (pull or push first)"
        cd ../..
        return 1
    fi

    # Central rejects an artifact without a sources jar; a pom that switches it off was the
    # June 2026 converter failure
    if grep -rq --include=pom.xml '<attach>false</attach>' . 2>/dev/null; then
        log "WARNING: $module has a pom with <attach>false</attach> (sources jar switched off)"
        cd ../..
        return 1
    fi

    # nexus-staging uploads when the LAST module of the reactor runs; a deploy-skipped last
    # module uploads nothing (the other June 2026 converter failure)
    local last_module
    last_module=$(grep -o '<module>[^<]*</module>' pom.xml | tail -1 | sed 's/<[^>]*>//g')
    if [ -n "$last_module" ] && [ -f "$last_module/pom.xml" ] && grep -q 'maven.deploy.skip\|skipNexusStagingDeployMojo' "$last_module/pom.xml"; then
        log "WARNING: $module's last reactor module ($last_module) skips deploy; nothing would be uploaded"
        cd ../..
        return 1
    fi

    if [ -f CHANGELOG.md ] && ! grep -q "^## \[$RELEASE_VERSION\]" CHANGELOG.md; then
        log "WARNING: $module/CHANGELOG.md has no section ## [$RELEASE_VERSION]"
    fi

    cd ../..
    log "$module validated"
    return 0
}

# The deploy build of every module at the release version, signed but not uploaded, then
# everything restored. Finds what Central would reject before a tag or commit exists.
dry_run_deploy_all_modules() {
    log "Dry-run deploy of ${#MODULES[@]} modules at $RELEASE_VERSION (no upload, no commit, no tag)..."
    local failed=()
    for module in "${MODULES[@]}"; do
        local module_path="modules/$module"
        cd "$module_path"
        find . -name pom.xml -type f -exec sed -i '' "s|<version>$DEV_VERSION</version>|<version>$RELEASE_VERSION</version>|g" {} +
        local cmd="mvn clean deploy -Popenepcis-ossrh -DskipTests -DskipNexusStagingDeployMojo=true"
        if [ -n "$GPG_PASSPHRASE" ]; then
            cmd="$cmd -Dgpg.passphrase=$GPG_PASSPHRASE"
        fi
        log "Dry-run deploy: $module"
        if $cmd >> "$LOG_FILE" 2>&1; then
            log "SUCCESS: $module would deploy"
        else
            log "ERROR: $module would NOT deploy (see $LOG_FILE)"
            failed+=("$module")
        fi
        git checkout -- . >> "$LOG_FILE" 2>&1
        cd ../..
    done
    if [ ${#failed[@]} -gt 0 ]; then
        log "ERROR: dry-run deploy failed for: ${failed[*]}"
        return 1
    fi
    log "Dry-run deploy passed for all modules"
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

    # Update to release version.
    # NOTE: `mvn versions:set` cannot be used here — every module inherits its
    # version from the openepcis-bom parent ("Project version is inherited from
    # parent"). The project uses $DEV_VERSION uniformly as the dev placeholder,
    # so a literal replace of the version element across all poms reliably bumps
    # project, parent, and intra-reactor sibling versions. (BSD sed: -i '')
    if ! execute_command "Update version to $RELEASE_VERSION" \
        "find . -name pom.xml -type f -exec sed -i '' 's|<version>$DEV_VERSION</version>|<version>$RELEASE_VERSION</version>|g' {} +"; then
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

    # A GitHub release with real notes: the module's CHANGELOG section when it has one,
    # generated notes otherwise. The tag workflows of converter and hash generator attach
    # their assets to this release instead of creating a second one.
    if command -v gh &> /dev/null; then
        local notes_cmd="--generate-notes"
        if [ -f CHANGELOG.md ] && grep -q "^## \[$RELEASE_VERSION\]" CHANGELOG.md; then
            awk "/^## \\[$RELEASE_VERSION\\]/{flag=1;next} /^## \\[/{flag=0} flag" CHANGELOG.md > "/tmp/release-notes-$module.md"
            notes_cmd="--notes-file /tmp/release-notes-$module.md"
        fi
        execute_command "Create GitHub release" \
            "gh release create v$RELEASE_VERSION --title '$module $RELEASE_VERSION' $notes_cmd" || log "WARNING: GitHub release for $module not created"
    fi

    # Revert to dev version (inverse literal replace; see note above)
    if ! execute_command "Revert to $DEV_VERSION" \
        "find . -name pom.xml -type f -exec sed -i '' 's|<version>$RELEASE_VERSION</version>|<version>$DEV_VERSION</version>|g' {} + && git add -A && git commit -m 'Back to $DEV_VERSION for development' && git push origin main"; then
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

# Break the repo-level models<->digitallink cycle: install model-core (which has no
# digitallink dependency) at the release version so the digitallink release build can
# resolve it. model-core is properly rebuilt and deployed during the openepcis-models
# release that follows. Local install only — nothing is deployed here.
bootstrap_model_core() {
    log ""
    log "Bootstrapping openepcis-model-core $RELEASE_VERSION (breaks models<->digitallink cycle)..."

    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Would install model-core $RELEASE_VERSION to local repository"
        return 0
    fi

    cd "modules/openepcis-models"
    find . -name pom.xml -type f -exec sed -i '' "s|<version>$DEV_VERSION</version>|<version>$RELEASE_VERSION</version>|g" {} +

    local rc=0
    if mvn clean install -pl core -am -DskipTests >> "$LOG_FILE" 2>&1; then
        log "SUCCESS: model-core $RELEASE_VERSION installed to local repository"
    else
        log "ERROR: model-core bootstrap build failed (see $LOG_FILE)"
        rc=1
    fi

    # Restore working tree regardless; openepcis-models is released normally later.
    git checkout -- . >> "$LOG_FILE" 2>&1
    cd ../..
    return $rc
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
        "sed -i '' 's|<version>$DEV_VERSION</version>|<version>$RELEASE_VERSION</version>|g' pom.xml && git add pom.xml && git commit -m 'Release version $RELEASE_VERSION' && git tag -a v$RELEASE_VERSION -m 'Release version $RELEASE_VERSION' && git push origin main && git push origin v$RELEASE_VERSION"; then
        return 1
    fi

    if ! execute_command "Revert parent to dev version" \
        "sed -i '' 's|<version>$RELEASE_VERSION</version>|<version>$DEV_VERSION</version>|g' pom.xml && git add pom.xml && git commit -m 'Back to $DEV_VERSION for development' && git push origin main"; then
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
  --dry-run-deploy  Build and sign every module at the release version, upload nothing
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
            --dry-run-deploy)
                DRY_RUN_DEPLOY=true
                log "DRY-RUN DEPLOY - builds and signs every module at the release version, uploads nothing"
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

    if [ "$DRY_RUN_DEPLOY" = true ]; then
        if ! bootstrap_model_core; then
            log "ERROR: model-core bootstrap failed"
            exit 1
        fi
        dry_run_deploy_all_modules
        exit $?
    fi

    if [ "$DRY_RUN" = false ]; then
        prompt_continue "All validations passed. Ready to start release."
    fi

    if ! bootstrap_model_core; then
        log "ERROR: Release aborted during model-core bootstrap"
        exit 1
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
