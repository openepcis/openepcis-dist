#!/usr/bin/env bash
set -euo pipefail

################################################################################
# OpenEPCIS Distribution Release Script
#
# Usage: ./release.sh <version> [--dry-run] [--dry-run-deploy] [--gpg-passphrase <pass>]
# Example: ./release.sh 0.9.4
#
# --dry-run         validates everything (pre-flight) and prints what would happen, touches
#                   nothing
# --dry-run-deploy  sets the release version in every module, runs the full deploy build with
#                   signing but without the upload (-DskipNexusStagingDeployMojo=true), then
#                   restores the working trees. Run it once before the real release: it finds
#                   missing source jars, missing <name> elements, a deploy-skipped last reactor
#                   project and anything else Central would reject. No commit, no tag, no push.
#
# Release flow per module (nothing is ever pushed to main, which is protected in most of the
# module repositories; only tags are pushed):
#   1. detach HEAD at origin/main
#   2. set the release version in the io.openepcis coordinates of every pom
#   3. commit "Release version X" on the detached HEAD and create the annotated tag vX
#   4. push ONLY the tag
#   5. deploy to Central from that commit (irreversible)
#   6. create the GitHub release for the tag
#   7. check out main again; main never changes, so there is no "Back to 999-SNAPSHOT" commit
#
# The tag is pushed before the deploy on purpose: a tag without artifacts can be deleted
# (git push origin :refs/tags/vX), artifacts on Central cannot. Pushing first means released
# artifacts never exist without their source tag, and a push problem stops the run before the
# irreversible step instead of after it.
#
# The dist repository itself is released the same way: a detached commit that records every
# submodule at its release tag commit and the dist pom at the release version, tagged and
# pushed as a tag only.
#
# Portability: in-place edits use perl (-pi), which behaves the same on macOS and Linux.
# Maven runs through the repository's wrapper (./mvnw, Maven 3.9.15), not the system mvn.
################################################################################

RELEASE_VERSION=""
DRY_RUN=false
DRY_RUN_DEPLOY=false
FROM_MODULE=""
# how long to wait for a released module to appear on Maven Central before the next one
CENTRAL_WAIT_MINUTES=${CENTRAL_WAIT_MINUTES:-90}
GPG_PASSPHRASE=""
DEV_VERSION="999-SNAPSHOT"
DIST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MVNW="$DIST_ROOT/mvnw"
# Absolute path so log writes don't land inside submodule dirs when we cd around
LOG_FILE="$DIST_ROOT/release-$(date +%Y%m%d-%H%M%S).log"

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
# the full list; MODULES may be cut down by --from
ALL_MODULES=("${MODULES[@]}")

################################################################################
# Utility Functions
################################################################################

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
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
        if [ -n "$GPG_PASSPHRASE" ]; then
            command=${command//"$GPG_PASSPHRASE"/***}
        fi
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

# All poms of the current directory tree, without build output
list_poms() {
    find . -name pom.xml -type f -not -path '*/target/*' -not -path '*/node_modules/*'
}

# Checks pom versions with an XML parser (comments are ignored).
#   pre  <version> <files...>: every element whose <version> is <version> must have an
#        io.openepcis groupId (inherited from the parent for the project itself); the literal
#        replace in set_release_version would otherwise also rewrite a third-party coordinate.
#        <version> may also not appear in any other element (a property, say), where the
#        literal replace would miss it.
#   post <version> <files...>: <version> must not appear in any element text anymore.
check_pom_versions() {
    python3 - "$@" <<'PY'
import sys
import xml.etree.ElementTree as ET

mode, version, files = sys.argv[1], sys.argv[2], sys.argv[3:]
problems = []
for path in files:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        problems.append(f"{path}: cannot parse ({e})")
        continue
    ns = root.tag[: root.tag.index("}") + 1] if root.tag.startswith("{") else ""
    strip = lambda tag: tag.replace(ns, "")
    project_gid = root.findtext(ns + "groupId") or root.findtext(ns + "parent/" + ns + "groupId")
    version_elements = set()
    for el in root.iter():
        v = el.find(ns + "version")
        if v is None or (v.text or "").strip() != version:
            continue
        version_elements.add(v)
        if mode != "pre":
            continue
        gid = el.findtext(ns + "groupId")
        if gid is None and el is root:
            gid = project_gid
        if gid is not None:
            gid = gid.strip()
            if gid in ("${project.groupId}", "${project.parent.groupId}"):
                gid = (project_gid or "").strip()
        if not gid or not (gid == "io.openepcis" or gid.startswith("io.openepcis.")):
            art = (el.findtext(ns + "artifactId") or "?").strip()
            problems.append(f"{path}: <{strip(el.tag)}> {gid or '(no groupId)'}:{art} has version {version}")
    for el in root.iter():
        if not isinstance(el.tag, str):
            continue
        if version in (el.text or "") and (mode == "post" or el not in version_elements):
            problems.append(f"{path}: <{strip(el.tag)}> contains {version}")
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
PY
}

# Replaces the dev version with the release version in <version> elements of the given poms
# (default: all poms below the current directory) and verifies the result. Only the literal
# <version>999-SNAPSHOT</version> is touched, and check_pom_versions pre has made sure every
# such element belongs to an io.openepcis coordinate. `mvn versions:set` is no option: every
# module inherits its version from the openepcis-bom parent.
set_release_version() {
    local poms=("$@")
    if [ ${#poms[@]} -eq 0 ]; then
        while IFS= read -r p; do poms+=("$p"); done < <(list_poms)
    fi
    FROM="$DEV_VERSION" TO="$RELEASE_VERSION" perl -pi -e \
        's|<version>\Q$ENV{FROM}\E</version>|<version>$ENV{TO}</version>|g' "${poms[@]}"
    if ! check_pom_versions post "$DEV_VERSION" "${poms[@]}"; then
        echo "ERROR: $DEV_VERSION left in poms after the version update"
        return 1
    fi
}

# owner/repo of the origin remote of the current repository
github_slug() {
    git remote get-url origin | sed -E 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)##; s#\.git$##'
}

# A pushed tag must be accepted: push permission, and no active tag ruleset (repository or
# organization level, includes_parents) that could block it. Branch protection applies to
# branches only; the legacy tag protection API was retired by GitHub in 2024.
check_tag_push_allowed() {
    local slug=$1
    local can_push
    if ! can_push=$(gh api "repos/$slug" --jq '.permissions.push' 2>/dev/null); then
        log "WARNING: cannot read repository $slug through the GitHub API"
        return 1
    fi
    if [ "$can_push" != "true" ]; then
        log "WARNING: no push permission on $slug"
        return 1
    fi
    local tag_rulesets
    if ! tag_rulesets=$(gh api "repos/$slug/rulesets?includes_parents=true" \
        --jq '[.[] | select(.target == "tag" and .enforcement == "active") | .name] | join(", ")' 2>/dev/null); then
        log "WARNING: cannot read the rulesets of $slug"
        return 1
    fi
    if [ -n "$tag_rulesets" ]; then
        log "WARNING: $slug has active tag rulesets ($tag_rulesets); verify v$RELEASE_VERSION can be pushed, then adjust this check"
        return 1
    fi
    return 0
}

################################################################################
# Validation Functions
################################################################################

validate_prerequisites() {
    log "Validating prerequisites..."

    if [ ! -f "pom.xml" ] || [ ! -d "modules" ] || [ "$(pwd)" != "$DIST_ROOT" ]; then
        log "ERROR: Must be run from openepcis-dist root directory"
        exit 1
    fi

    if [ ! -x "$MVNW" ]; then
        log "ERROR: Maven wrapper not found: $MVNW"
        exit 1
    fi
    log "Maven: $("$MVNW" -version 2>/dev/null | head -1)"

    for tool in git gpg gh python3 perl; do
        if ! command -v "$tool" &> /dev/null; then
            log "ERROR: $tool not found"
            exit 1
        fi
    done
    log "Git: $(git --version)"

    if ! gh auth status &> /dev/null; then
        log "ERROR: gh is not authenticated (needed for the tag pre-flight and the GitHub releases)"
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

# The dist repository: on main, equal to origin/main, clean (the submodule pointers may differ,
# the release records them at the tag commits), tag free, tag push allowed, pom versions sane.
validate_dist_state() {
    log "Validating openepcis-dist..."
    local ok=0

    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$current_branch" != "main" ]; then
        log "WARNING: openepcis-dist is on branch '$current_branch', not 'main'"
        ok=1
    fi
    if [ -n "$(git status --porcelain --ignore-submodules=all)" ]; then
        log "WARNING: openepcis-dist has uncommitted changes"
        git status --short --ignore-submodules=all | tee -a "$LOG_FILE"
        ok=1
    fi
    git fetch --tags --force --prune origin > /dev/null 2>&1 || true
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
        log "WARNING: openepcis-dist HEAD is not origin/main (pull or push first)"
        ok=1
    fi
    if [ -n "$(git ls-remote --tags origin "refs/tags/v$RELEASE_VERSION")" ]; then
        log "WARNING: Tag v$RELEASE_VERSION already exists on origin of openepcis-dist"
        ok=1
    elif git rev-parse -q --verify "refs/tags/v$RELEASE_VERSION" > /dev/null; then
        log "Deleting stale local tag v$RELEASE_VERSION in openepcis-dist (not on origin)"
        git tag -d "v$RELEASE_VERSION" > /dev/null
    fi
    if ! check_tag_push_allowed "$(github_slug)"; then
        ok=1
    fi
    local out
    if ! out=$(check_pom_versions pre "$DEV_VERSION" pom.xml); then
        log "WARNING: openepcis-dist pom.xml: $out"
        ok=1
    fi

    [ $ok -eq 0 ] && log "openepcis-dist validated"
    return $ok
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

    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$current_branch" != "main" ]; then
        log "WARNING: $module is on branch '$current_branch', not 'main'"
        cd "$DIST_ROOT"
        return 1
    fi

    if [ -n "$(git status --porcelain)" ]; then
        log "WARNING: $module has uncommitted changes"
        git status --short | tee -a "$LOG_FILE"
        cd "$DIST_ROOT"
        return 1
    fi

    git fetch --tags --force --prune origin > /dev/null 2>&1 || true

    if [ -n "$(git ls-remote --tags origin "refs/tags/v$RELEASE_VERSION")" ]; then
        log "WARNING: Tag v$RELEASE_VERSION already exists on origin of $module"
        cd "$DIST_ROOT"
        return 1
    fi
    if git rev-parse -q --verify "refs/tags/v$RELEASE_VERSION" > /dev/null; then
        # local only, a leftover of an earlier attempt (the 2023 hash-generator tags, for one)
        log "Deleting stale local tag v$RELEASE_VERSION in $module (not on origin)"
        git tag -d "v$RELEASE_VERSION" > /dev/null
    fi

    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
        log "WARNING: $module HEAD is not origin/main (pull or push first)"
        cd "$DIST_ROOT"
        return 1
    fi

    # Only the tag is pushed; it must be accepted, or the run would stop half way
    if ! check_tag_push_allowed "$(github_slug)"; then
        cd "$DIST_ROOT"
        return 1
    fi

    # The version replace may only touch io.openepcis coordinates
    local poms=() out
    while IFS= read -r p; do poms+=("$p"); done < <(list_poms)
    if ! out=$(check_pom_versions pre "$DEV_VERSION" "${poms[@]}"); then
        log "WARNING: $module: $DEV_VERSION outside io.openepcis <version> coordinates:"
        echo "$out" | tee -a "$LOG_FILE"
        cd "$DIST_ROOT"
        return 1
    fi

    # Central rejects an artifact without a sources jar; a pom that switches it off was the
    # June 2026 converter failure
    # Central rejects a published artifact whose pom has no <name> ('Project name is missing'),
    # and Maven does not inherit <name> from the parent: the 0.9.4 failure of openepcis-core
    local unnamed
    unnamed=$(python3 - "${poms[@]}" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = {"m": "http://maven.apache.org/POM/4.0.0"}
for path in sys.argv[1:]:
    root = ET.parse(path).getroot()
    props = root.find("m:properties", ns)
    skipped = props is not None and any(
        (props.findtext("m:" + key, default="", namespaces=ns) or "").strip() == "true"
        for key in ("skipNexusStagingDeployMojo", "maven.deploy.skip"))
    if not skipped and root.find("m:name", ns) is None:
        print(path)
PY
)
    if [ -n "$unnamed" ]; then
        log "WARNING: $module has published poms without <name>, which Central rejects:"
        echo "$unnamed" | while read -r pom; do log "  $pom"; done
        cd "$DIST_ROOT"
        return 1
    fi

    if grep -rq --include=pom.xml '<attach>false</attach>' . 2>/dev/null; then
        log "WARNING: $module has a pom with <attach>false</attach> (sources jar switched off)"
        cd "$DIST_ROOT"
        return 1
    fi

    # nexus-staging uploads when the LAST project of the reactor runs; a deploy-skipped last
    # project uploads nothing (the other June 2026 converter failure). This quick check follows
    # the last <module> of the default module list (opt-in profile modules are ignored) down
    # through nested aggregators, i.e. DECLARATION order. That matches the reactor order only
    # when no later-declared module is sorted before an earlier one by a dependency. The
    # authoritative check against the real reactor order is check_last_reactor_project in
    # --dry-run-deploy, and the real deploy is checked for the "Remote staged" line afterwards.
    local last_dir="." next_module
    while :; do
        next_module=$(sed -n '/<modules>/,/<\/modules>/{p;/<\/modules>/q;}' "$last_dir/pom.xml" | sed '/<!--/,/-->/d' | grep -o '<module>[^<]*</module>' | tail -1 | sed 's/<[^>]*>//g' || true)
        if [ -z "$next_module" ] || [ ! -f "$last_dir/$next_module/pom.xml" ]; then
            break
        fi
        last_dir="$last_dir/$next_module"
    done
    if [ "$last_dir" != "." ] && grep -q '<maven.deploy.skip>[[:space:]]*true\|<skipNexusStagingDeployMojo>[[:space:]]*true' "$last_dir/pom.xml"; then
        log "WARNING: $module's last declared project (${last_dir#./}) skips deploy; nexus-staging would upload nothing"
        cd "$DIST_ROOT"
        return 1
    fi

    if [ -f CHANGELOG.md ] && ! grep -q "^## \[$RELEASE_VERSION\]" CHANGELOG.md; then
        log "WARNING: $module/CHANGELOG.md has no section ## [$RELEASE_VERSION]"
    fi

    cd "$DIST_ROOT"
    log "$module validated"
    return 0
}

# From the output of a reactor build: the last project of the Reactor Summary (the project
# nexus-staging uploads at) must not skip the deploy. Run inside the module directory.
check_last_reactor_project() {
    local build_log=$1
    local last_name
    last_name=$(awk '/Reactor Summary for/{flag=1;last="";next} flag && /SUCCESS \[|FAILURE \[|SKIPPED/{last=$0} flag && /BUILD (SUCCESS|FAILURE)/{flag=0} END{print last}' "$build_log" \
        | sed -E 's/^\[INFO\] //; s/ \.+ *(SUCCESS|FAILURE|SKIPPED).*$//; s/ +$//')
    if [ -z "$last_name" ]; then
        # a single-project build has no reactor summary; its one project is the last
        return 0
    fi
    local poms=()
    while IFS= read -r p; do poms+=("$p"); done < <(list_poms)
    python3 - "$last_name" "${poms[@]}" <<'PY'
import sys, re
import xml.etree.ElementTree as ET
name, files = sys.argv[1], sys.argv[2:]
for path in files:
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError:
        continue
    ns = root.tag[: root.tag.index("}") + 1] if root.tag.startswith("{") else ""
    pname = (root.findtext(ns + "name") or root.findtext(ns + "artifactId") or "").strip()
    if pname != name:
        continue
    text = open(path, encoding="utf-8").read()
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    if re.search(r"<(maven\.deploy\.skip|skipNexusStagingDeployMojo)>\s*true", text):
        print(f"last reactor project '{name}' ({path}) skips deploy; nothing would be uploaded")
        sys.exit(1)
    sys.exit(0)
print(f"last reactor project '{name}' not found among the poms, check by hand that it deploys")
sys.exit(2)
PY
}

# The deploy build of every module at the release version, signed but not uploaded, then
# everything restored. Finds what Central would reject before a tag or commit exists.
# Creates no commit and no tag and pushes nothing.
dry_run_deploy_all_modules() {
    log "Dry-run deploy of ${#MODULES[@]} modules at $RELEASE_VERSION (no upload, no commit, no tag)..."
    local failed=()
    local module_log
    module_log=$(mktemp)
    for module in "${MODULES[@]}"; do
        cd "$DIST_ROOT/modules/$module"
        local cmd=("$MVNW" clean deploy -Popenepcis-ossrh -DskipTests -DskipNexusStagingDeployMojo=true)
        if [ -n "$GPG_PASSPHRASE" ]; then
            cmd+=("-Dgpg.passphrase=$GPG_PASSPHRASE")
        fi
        log "Dry-run deploy: $module"
        if ! set_release_version >> "$LOG_FILE" 2>&1; then
            log "ERROR: $module: version update failed (see $LOG_FILE)"
            failed+=("$module")
        elif "${cmd[@]}" > "$module_log" 2>&1; then
            cat "$module_log" >> "$LOG_FILE"
            local out rc=0
            out=$(check_last_reactor_project "$module_log") || rc=$?
            if [ $rc -eq 0 ]; then
                log "SUCCESS: $module would deploy"
            elif [ $rc -eq 2 ]; then
                log "WARNING: $module: $out"
                log "SUCCESS: $module would deploy"
            else
                log "ERROR: $module: $out"
                failed+=("$module")
            fi
        else
            cat "$module_log" >> "$LOG_FILE"
            log "ERROR: $module would NOT deploy (see $LOG_FILE)"
            failed+=("$module")
        fi
        git checkout -- . >> "$LOG_FILE" 2>&1
        cd "$DIST_ROOT"
    done
    rm -f "$module_log"
    if [ ${#failed[@]} -gt 0 ]; then
        log "ERROR: dry-run deploy failed for: ${failed[*]}"
        return 1
    fi
    log "Dry-run deploy passed for all modules"
    return 0
}

# --from MODULE: resume a release at MODULE. Every module before it must already be on Maven
# Central at the release version; only MODULE and the ones after it are validated and released.
select_from_module() {
    local start=-1 i
    for i in "${!MODULES[@]}"; do
        [ "${MODULES[$i]}" = "$FROM_MODULE" ] && start=$i
    done
    if [ "$start" -lt 0 ]; then
        log "ERROR: --from $FROM_MODULE is not one of: ${MODULES[*]}"
        exit 1
    fi
    for i in $(seq 0 $((start - 1))); do
        local module=${MODULES[$i]} artifact
        artifact=$(root_artifact_id "$DIST_ROOT/modules/$module")
        if [ "$(curl -s -o /dev/null -w '%{http_code}' "$(central_pom_url "$artifact")")" != "200" ]; then
            log "ERROR: --from $FROM_MODULE, but $module ($artifact $RELEASE_VERSION) is not on Maven Central yet"
            exit 1
        fi
        log "$module $RELEASE_VERSION already on Maven Central, skipped"
    done
    # release_dist records every module at its tag, the skipped ones included
    MODULES=("${MODULES[@]:$start}")
}

validate_all_modules() {
    log "Validating all modules..."

    local failed_modules=()

    if ! validate_dist_state; then
        failed_modules+=("openepcis-dist")
    fi

    for module in "${MODULES[@]}"; do
        if ! validate_module_state "$module"; then
            failed_modules+=("$module")
        fi
    done

    if [ ${#failed_modules[@]} -gt 0 ]; then
        log "ERROR: The following repositories failed validation:"
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

# Back to main after a release attempt; main itself was never changed
return_to_main() {
    git checkout -- . > /dev/null 2>&1 || true
    git checkout -q main >> "$LOG_FILE" 2>&1 || log "WARNING: could not check out main in $(pwd)"
}

# The artifactId of a module's root pom: the first thing of the module Central publishes.
root_artifact_id() {
    python3 - "$1/pom.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {"m": "http://maven.apache.org/POM/4.0.0"}
print(ET.parse(sys.argv[1]).getroot().find("m:artifactId", ns).text.strip())
PY
}

central_pom_url() {
    local artifact=$1
    echo "https://repo1.maven.org/maven2/io/openepcis/$artifact/$RELEASE_VERSION/$artifact-$RELEASE_VERSION.pom"
}

# Central validates a deployment against what is already published: a module whose parent or
# managed dependencies come from an earlier module (the bom, models, ...) is rejected ("Dependency
# version information is missing") while that earlier module is still PUBLISHING. So the next
# module waits until this one can be downloaded from Maven Central.
wait_for_central() {
    local module=$1
    local artifact
    artifact=$(root_artifact_id "$DIST_ROOT/modules/$module")
    local url
    url=$(central_pom_url "$artifact")
    local deadline=$(( $(date +%s) + CENTRAL_WAIT_MINUTES * 60 ))
    log "Waiting for $artifact $RELEASE_VERSION on Maven Central ($url)..."
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' "$url")" = "200" ]; then
            log "SUCCESS: $artifact $RELEASE_VERSION is on Maven Central"
            return 0
        fi
        sleep 30
    done
    log "ERROR: $artifact $RELEASE_VERSION did not appear on Maven Central within $CENTRAL_WAIT_MINUTES minutes"
    return 1
}

release_module() {
    local module=$1
    local module_path="$DIST_ROOT/modules/$module"
    local tag="v$RELEASE_VERSION"

    log ""
    log "Releasing $module..."
    log "-------------------------------------------------------------------"

    cd "$module_path"

    # 1-3: release commit and tag on a detached HEAD; main is not touched
    if ! execute_command "Detach HEAD at origin/main" "git checkout -q --detach origin/main" \
        || ! execute_command "Update version to $RELEASE_VERSION" "set_release_version" \
        || ! execute_command "Commit release version on detached HEAD" \
            "git commit -q -a -m 'Release version $RELEASE_VERSION'" \
        || ! execute_command "Create tag $tag" \
            "git tag -a $tag -m 'Release version $RELEASE_VERSION'"; then
        [ "$DRY_RUN" = true ] || return_to_main
        cd "$DIST_ROOT"
        return 1
    fi

    # 4: push the tag only, before the irreversible deploy (see the header)
    if ! execute_command "Push tag $tag (tag only, main is not pushed)" \
        "git push origin refs/tags/$tag"; then
        log "ERROR: $module: tag push rejected, nothing deployed. The local tag is kept; fix and push it, or delete it with: git -C $module_path tag -d $tag"
        [ "$DRY_RUN" = true ] || return_to_main
        cd "$DIST_ROOT"
        return 1
    fi

    # 5: deploy from the tagged commit
    log "Building and deploying to Maven Central (this may take several minutes)..."
    local deploy_cmd="'$MVNW' clean deploy -Popenepcis-ossrh"
    if [ -n "$GPG_PASSPHRASE" ]; then
        deploy_cmd="$deploy_cmd '-Dgpg.passphrase=$GPG_PASSPHRASE'"
    fi
    local module_log
    module_log=$(mktemp)
    if ! execute_command "Deploy to Maven Central" "$deploy_cmd 2>&1 | tee '$module_log'"; then
        log "ERROR: Deployment failed for $module; tag $tag is on origin, check Central for a partial upload."
        log "  retry:  cd $module_path && git checkout $tag && $MVNW clean deploy -Popenepcis-ossrh"
        log "  or, if nothing reached Central, drop the tag: git -C $module_path push origin :refs/tags/$tag"
        rm -f "$module_log"
        [ "$DRY_RUN" = true ] || return_to_main
        cd "$DIST_ROOT"
        return 1
    fi
    if [ "$DRY_RUN" = false ] && ! grep -q 'Remote staged [0-9]* repositor' "$module_log"; then
        # nexus-staging logs "Remote staged N repositories, finished with success." when it
        # uploaded; without it a deploy-skipped last reactor project swallowed the upload
        log "ERROR: $module: the build passed but nexus-staging reported no remote staging; nothing reached Central."
        log "  fix the reactor, then deploy from the tag, or drop it: git -C $module_path push origin :refs/tags/$tag"
        rm -f "$module_log"
        return_to_main
        cd "$DIST_ROOT"
        return 1
    fi
    rm -f "$module_log"

    # 6: a GitHub release with real notes: the module's CHANGELOG section when it has one,
    # generated notes otherwise.
    local notes_file=""
    local notes_cmd="--generate-notes"
    if [ -f CHANGELOG.md ] && grep -q "^## \[$RELEASE_VERSION\]" CHANGELOG.md; then
        notes_file=$(mktemp)
        awk "/^## \\[$RELEASE_VERSION\\]/{flag=1;next} /^## \\[/{flag=0} flag" CHANGELOG.md > "$notes_file"
        notes_cmd="--notes-file '$notes_file'"
    fi
    # the tag push may already have made a release (the converter's and the hash generator's
    # tag workflows create one); then its notes are replaced instead
    if [ "$DRY_RUN" = false ] && gh release view "$tag" > /dev/null 2>&1; then
        execute_command "Update GitHub release" \
            "gh release edit $tag --title '$module $RELEASE_VERSION' $([ -n "$notes_file" ] && echo "--notes-file '$notes_file'")" \
            || log "WARNING: GitHub release for $module not updated"
    else
        execute_command "Create GitHub release" \
            "gh release create $tag --verify-tag --title '$module $RELEASE_VERSION' $notes_cmd" \
            || log "WARNING: GitHub release for $module not created"
    fi
    [ -n "$notes_file" ] && rm -f "$notes_file"

    # 7: back to main; the release commit stays reachable through the tag
    if [ "$DRY_RUN" = false ]; then
        return_to_main
    else
        log "[DRY-RUN] Would check out main again (no 'Back to $DEV_VERSION' commit needed)"
    fi

    cd "$DIST_ROOT"
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
        log "[DRY-RUN] Would install openepcis-bom and model-core $RELEASE_VERSION to the local repository"
        return 0
    fi

    # model-core's parent is openepcis-bom at the release version, which exists nowhere yet:
    # the bom is released as the first module, after this bootstrap. Install it locally first.
    cd "$DIST_ROOT/modules/openepcis-bom"
    local bom_rc=0
    { set_release_version && "$MVNW" clean install -DskipTests; } >> "$LOG_FILE" 2>&1 || bom_rc=1
    git checkout -- . >> "$LOG_FILE" 2>&1
    cd "$DIST_ROOT"
    if [ $bom_rc -ne 0 ]; then
        log "ERROR: openepcis-bom $RELEASE_VERSION could not be installed locally (see $LOG_FILE)"
        return 1
    fi

    cd "$DIST_ROOT/modules/openepcis-models"
    local rc=0
    if { set_release_version && "$MVNW" clean install -pl core -am -DskipTests; } >> "$LOG_FILE" 2>&1; then
        log "SUCCESS: model-core $RELEASE_VERSION installed to local repository"
    else
        log "ERROR: model-core bootstrap build failed (see $LOG_FILE)"
        rc=1
    fi

    # Restore working tree regardless; openepcis-models is released normally later.
    git checkout -- . >> "$LOG_FILE" 2>&1
    cd "$DIST_ROOT"
    return $rc
}

release_all_modules() {
    log "Starting release process..."
    log "Release version: $RELEASE_VERSION"
    log "Total modules: ${#MODULES[@]}"

    prompt_continue "About to release ${#MODULES[@]} modules (will take 30-45 minutes)"

    local failed_modules=()
    local released_modules=()
    local i

    for i in "${!MODULES[@]}"; do
        local module=${MODULES[$i]}
        if release_module "$module" && { [ "$DRY_RUN" = true ] || wait_for_central "$module"; }; then
            released_modules+=("$module")
        else
            failed_modules+=("$module")
            log "ERROR: $module failed"
            log "Released so far: ${released_modules[*]:-none}"
            log "Failed so far: ${failed_modules[*]}"
            log "Remaining: ${MODULES[*]:$((i + 1))}"
            prompt_continue "Continue with the remaining modules? Those depending on $module would be released against an unpublished $module $RELEASE_VERSION."
        fi
    done

    if [ ${#failed_modules[@]} -gt 0 ]; then
        log "ERROR: Failed modules: ${failed_modules[*]}"
        return 1
    fi

    log "All modules released successfully"
    return 0
}

# The dist repository, tag only like the modules: a detached commit with every submodule
# recorded at its release tag commit and the dist pom at the release version.
release_dist() {
    local tag="v$RELEASE_VERSION"
    log ""
    log "Releasing openepcis-dist..."

    cd "$DIST_ROOT"
    if ! execute_command "Detach openepcis-dist HEAD at origin/main" \
        "git -c submodule.recurse=false checkout -q --detach origin/main"; then
        return 1
    fi

    local module
    for module in "${ALL_MODULES[@]}"; do
        if ! execute_command "Record modules/$module at $tag" \
            "git -C modules/$module checkout -q --detach $tag && git add modules/$module"; then
            return 1
        fi
    done

    if ! execute_command "Update dist pom to $RELEASE_VERSION" "set_release_version pom.xml && git add pom.xml" \
        || ! execute_command "Commit dist release" "git commit -q -m 'Release version $RELEASE_VERSION'" \
        || ! execute_command "Create tag $tag" "git tag -a $tag -m 'Release version $RELEASE_VERSION'" \
        || ! execute_command "Push tag $tag (tag only, main is not pushed)" "git push origin refs/tags/$tag"; then
        return 1
    fi

    if [ "$DRY_RUN" = false ]; then
        git -c submodule.recurse=false checkout -q main >> "$LOG_FILE" 2>&1 || log "WARNING: could not check out main in openepcis-dist"
        for module in "${ALL_MODULES[@]}"; do
            git -C "modules/$module" checkout -q main >> "$LOG_FILE" 2>&1 || log "WARNING: could not check out main in modules/$module"
        done
    else
        log "[DRY-RUN] Would check out main again in openepcis-dist and every module"
    fi

    log "openepcis-dist released as $tag"
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
  --dry-run         Validate everything and print what would happen, change nothing
  --dry-run-deploy  Build and sign every module at the release version, upload nothing,
                    no commit, no tag
  --from MODULE     Resume at MODULE after an interrupted release; the modules before it must
                    already be on Maven Central at the release version
  --gpg-passphrase  GPG passphrase for signing
  --help            Show this help

Examples:
  $0 0.9.4 --dry-run
  $0 0.9.4 --dry-run-deploy
  $0 0.9.4 --gpg-passphrase "pass"

This script releases all OpenEPCIS modules to Maven Central in dependency order. Each module
is released from a detached commit that carries the release version; only its tag v<version>
is pushed (before the deploy), main is never pushed and stays at $DEV_VERSION. The dist
repository is tagged the same way, recording every submodule at its release tag.

Prerequisites:
  - Sonatype credentials in ~/.m2/settings.xml
  - GPG key 759F1D2BF6B65D135FAD2716A355F274126C92B8
  - Java 25, gh (authenticated, push rights), python3, perl
  - openepcis-dist and all modules on 'main', equal to origin/main, clean
  - Estimated time: 30-45 minutes

EOF
}

main() {
    if [ $# -eq 0 ]; then
        show_usage
        exit 1
    fi

    log "OpenEPCIS Distribution Release Script"
    log "Start: $(date)"
    log "Log file: $LOG_FILE"

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
            --from)
                FROM_MODULE=$2
                shift 2
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

    if [ "$DRY_RUN" = true ] && [ "$DRY_RUN_DEPLOY" = true ]; then
        log "ERROR: --dry-run and --dry-run-deploy are mutually exclusive"
        exit 1
    fi

    validate_prerequisites
    if [ -n "$FROM_MODULE" ]; then
        select_from_module
    fi
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

    if ! release_dist; then
        log "ERROR: Failed to tag openepcis-dist (modules released and tagged; tag the dist repo manually)"
        exit 1
    fi

    log ""
    log "RELEASE COMPLETE"
    log "Version $RELEASE_VERSION released to Maven Central, tags v$RELEASE_VERSION pushed"
    log "main was not changed in any repository"
    log "End: $(date)"
    log "Full log: $LOG_FILE"
}

main "$@"
