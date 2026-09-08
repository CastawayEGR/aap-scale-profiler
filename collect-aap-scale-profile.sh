#!/usr/bin/env bash
# collect-aap-scale-profile.sh — Generate an AAP scale profile for analysis and capacity planning
# Usage: ./collect-aap-scale-profile.sh <namespace>

set -uo pipefail

NAMESPACE="${1:?Usage: $0 <namespace>}"
WORKDIR=$(mktemp -d)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_FILE="aap-scale-profile-${TIMESTAMP}.tar.gz"
SCRIPT_VERSION="1.0.0"
AAP_VERSION_BRANCH=""
AAP_INSTANCE=""
CONTROLLER_NAME=""
CONTROLLER_POD=""
CONTROLLER_CONTAINER=""
GATEWAY_POD=""
GATEWAY_CONTAINER=""
ERRORS=0

trap 'rm -rf "$WORKDIR"' EXIT

# ── output helpers ─────────────────────────────────────────────────────────────

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*"; ERRORS=$((ERRORS + 1)); }
die()     { echo "[ERROR] $*" >&2; exit 1; }

query_text_has_error() {
    local content="${1:-}"
    [[ -n "$content" ]] && grep -qiE '(^ERROR:|^FATAL:|syntax error|does not exist|permission denied)' <<< "$content"
}

query_file_has_error() {
    local file="$1"
    [[ -s "$file" ]] && grep -qiE '(^ERROR:|^FATAL:|syntax error|does not exist|permission denied)' "$file"
}

finalize_query_output() {
    local label="$1" outfile="$2" errtmp="$3"

    if [[ -s "$errtmp" ]]; then
        if [[ ! -s "$outfile" ]]; then
            cat "$errtmp" > "$outfile"
        elif grep -qiE 'error|fatal|denied|not found|terminated' "$errtmp"; then
            warn "$label stderr: $(grep -v '^$' "$errtmp" | tail -3 | tr '\n' ' ')"
        fi
    fi

    if [[ ! -s "$outfile" ]]; then
        warn "$label produced no output — file will be empty in the bundle."
        echo "ERROR: query produced no output" > "$outfile"
        return 1
    fi

    if query_file_has_error "$outfile"; then
        warn "$label output contains SQL errors."
        warn "  Detail: $(grep -iE 'ERROR:|FATAL:|syntax error|does not exist' "$outfile" | head -3 | tr '\n' ' ')"
        return 1
    fi

    success "$label"
    return 0
}

# ── preflight ─────────────────────────────────────────────────────────────────

preflight() {
    command -v oc  &>/dev/null     || die "'oc' not found. Install the OpenShift CLI and try again."
    command -v jq  &>/dev/null     || die "'jq' not found. Install jq and try again."
    oc whoami &>/dev/null          || die "Not logged in to an OpenShift cluster. Run 'oc login' first."
    oc get namespace "$NAMESPACE" &>/dev/null || die "Namespace '$NAMESPACE' not found on this cluster."
    discover_aap_instance
    oc auth can-i create pods/exec -n "$NAMESPACE" 2>/dev/null | grep -qx 'yes' \
        || warn "Permission check inconclusive — exec may still work. Proceeding."
}

verify_dbshell() {
    local pod="$1" container="$2" manage_cmd="$3" label="$4"
    local errtmp result
    errtmp=$(mktemp)
    info "Preflight: verifying ${label} database connectivity..."
    if ! result=$(oc exec -i "$pod" -n "$NAMESPACE" -c "$container" -- \
            "$manage_cmd" dbshell <<< "SELECT 1;" 2>"$errtmp"); then
        die "${label} database connectivity check failed: $(grep -v '^$' "$errtmp" | tail -3 | tr '\n' ' ')"
    fi
    if query_text_has_error "$result" || ! grep -qE '(^|[[:space:]])1([[:space:]]|$|\|)' <<< "$result"; then
        die "${label} database connectivity check returned unexpected output."
    fi
    rm -f "$errtmp"
    success "${label} database connectivity OK"
}

# ── pod discovery ─────────────────────────────────────────────────────────────

discover_aap_instance() {
    [[ -n "$AAP_INSTANCE" ]] && return
    AAP_INSTANCE=$(oc get aap -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -n "$AAP_INSTANCE" ]] \
        || die "No AnsibleAutomationPlatform resource found in namespace '$NAMESPACE'."
    info "AAP instance:    $AAP_INSTANCE"
}

discover_controller_name() {
    [[ -n "$CONTROLLER_NAME" ]] && return
    discover_aap_instance
    CONTROLLER_NAME=$(oc get aap "$AAP_INSTANCE" -n "$NAMESPACE" \
        -o jsonpath='{.spec.controller.name}' 2>/dev/null)
    [[ -n "$CONTROLLER_NAME" ]] || \
        CONTROLLER_NAME=$(oc get aap "$AAP_INSTANCE" -n "$NAMESPACE" \
            -o jsonpath='{.status.controller}' 2>/dev/null)
    CONTROLLER_NAME="${CONTROLLER_NAME:-$AAP_INSTANCE}"
    info "Controller name: $CONTROLLER_NAME"
}

discover_controller() {
    discover_controller_name
    local label
    for label in "${CONTROLLER_NAME}-controller-task" "${CONTROLLER_NAME}-task"; do
        CONTROLLER_POD=$(oc get pods -n "$NAMESPACE" \
            -l "app.kubernetes.io/name=${label}" \
            --field-selector=status.phase=Running \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        [[ -n "$CONTROLLER_POD" ]] && break
    done
    [[ -n "$CONTROLLER_POD" ]] \
        || die "No running controller task pod found in namespace '$NAMESPACE' (instance: ${AAP_INSTANCE}, controller: ${CONTROLLER_NAME})."

    for container in $(oc get pod "$CONTROLLER_POD" -n "$NAMESPACE" \
            -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | tr ' ' '\n'); do
        if oc exec "$CONTROLLER_POD" -n "$NAMESPACE" -c "$container" -- \
                sh -c 'command -v awx-manage' &>/dev/null 2>&1; then
            CONTROLLER_CONTAINER="$container"
            break
        fi
    done
    [[ -n "$CONTROLLER_CONTAINER" ]] \
        || die "Could not find a container with awx-manage in pod '$CONTROLLER_POD'."
    info "Controller pod:  $CONTROLLER_POD (container: $CONTROLLER_CONTAINER)"
}

discover_gateway() {
    discover_aap_instance
    GATEWAY_POD=$(oc get pods -n "$NAMESPACE" \
        -l "app.kubernetes.io/component=aap-gateway,app.kubernetes.io/part-of=${AAP_INSTANCE}" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -n "$GATEWAY_POD" ]] \
        || die "No running gateway pod found in namespace '$NAMESPACE' (instance: ${AAP_INSTANCE})."

    for container in $(oc get pod "$GATEWAY_POD" -n "$NAMESPACE" \
            -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | tr ' ' '\n'); do
        if oc exec "$GATEWAY_POD" -n "$NAMESPACE" -c "$container" -- \
                sh -c 'command -v aap-gateway-manage' &>/dev/null 2>&1; then
            GATEWAY_CONTAINER="$container"
            break
        fi
    done
    [[ -n "$GATEWAY_CONTAINER" ]] \
        || die "Could not find a container with aap-gateway-manage in pod '$GATEWAY_POD'."
    info "Gateway pod:     $GATEWAY_POD (container: $GATEWAY_CONTAINER)"
}

# ── query runners ─────────────────────────────────────────────────────────────

run_controller_query() {
    local label="$1" sql="$2" outfile="$3" hint="${4:-}"
    local errtmp
    errtmp=$(mktemp)
    info "Collecting: $label${hint:+ ($hint)}"

    if ! oc exec -i "$CONTROLLER_POD" -n "$NAMESPACE" -c "$CONTROLLER_CONTAINER" -- \
            awx-manage dbshell <<< "$sql" > "$WORKDIR/$outfile" 2>"$errtmp"; then
        warn "$label failed — pod may have restarted. Retrying with fresh pod discovery."
        discover_controller
        : > "$errtmp"
        oc exec -i "$CONTROLLER_POD" -n "$NAMESPACE" -c "$CONTROLLER_CONTAINER" -- \
            awx-manage dbshell <<< "$sql" > "$WORKDIR/$outfile" 2>"$errtmp" || true
    fi

    finalize_query_output "$label" "$WORKDIR/$outfile" "$errtmp" || true
    rm -f "$errtmp"
}

run_gateway_query() {
    local label="$1" sql="$2" outfile="$3"
    local errtmp
    errtmp=$(mktemp)
    info "Collecting: $label"

    if ! oc exec -i "$GATEWAY_POD" -n "$NAMESPACE" -c "$GATEWAY_CONTAINER" -- \
            aap-gateway-manage dbshell <<< "$sql" > "$WORKDIR/$outfile" 2>"$errtmp"; then
        warn "$label failed — pod may have restarted. Retrying with fresh pod discovery."
        discover_gateway
        : > "$errtmp"
        oc exec -i "$GATEWAY_POD" -n "$NAMESPACE" -c "$GATEWAY_CONTAINER" -- \
            aap-gateway-manage dbshell <<< "$sql" > "$WORKDIR/$outfile" 2>"$errtmp" || true
    fi

    finalize_query_output "$label" "$WORKDIR/$outfile" "$errtmp" || true
    rm -f "$errtmp"
}

# ── version detection ─────────────────────────────────────────────────────────

detect_version() {
    info "Detecting AAP version..."
    local result
    result=$(oc exec -i "$CONTROLLER_POD" -n "$NAMESPACE" -c "$CONTROLLER_CONTAINER" -- \
        awx-manage dbshell \
        <<< "SELECT CASE WHEN COUNT(*) > 0 THEN 'AAP 2.5+' ELSE 'AAP 2.4' END AS aap_version FROM django_migrations WHERE app = 'dab_rbac';" \
        2>/dev/null)

    if echo "$result" | grep -qF "AAP 2.5+"; then
        AAP_VERSION_BRANCH="2.5+"
    else
        AAP_VERSION_BRANCH="2.4"
    fi
    info "AAP version branch: $AAP_VERSION_BRANCH"
}

# ── controller queries ────────────────────────────────────────────────────────

collect_controller() {
    echo ""
    echo "=== Controller Queries ==="

    run_controller_query "Bloat Metrics" \
        "SELECT schemaname, relname, n_live_tup, n_dead_tup, last_vacuum, last_analyze FROM pg_stat_user_tables WHERE schemaname = 'public' ORDER BY n_dead_tup DESC;" \
        "bloat-controller.txt"

    run_controller_query "Inventory Distribution" \
        "SELECT (SELECT COUNT(*) FROM main_organization) AS org_count, (SELECT COUNT(*) FROM main_inventory) AS inventory_count, (SELECT COUNT(*) FROM main_host) AS host_count, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY inv_count) FROM (SELECT COUNT(i.id) AS inv_count FROM main_organization o LEFT JOIN main_inventory i ON i.organization_id = o.id GROUP BY o.id) t) AS median_inventories_per_org, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY inv_count) FROM (SELECT COUNT(i.id) AS inv_count FROM main_organization o LEFT JOIN main_inventory i ON i.organization_id = o.id GROUP BY o.id) t) AS p90_inventories_per_org, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY host_count) FROM (SELECT COUNT(h.id) AS host_count FROM main_inventory i LEFT JOIN main_host h ON h.inventory_id = i.id GROUP BY i.id) t) AS median_hosts_per_inventory, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY host_count) FROM (SELECT COUNT(h.id) AS host_count FROM main_inventory i LEFT JOIN main_host h ON h.inventory_id = i.id GROUP BY i.id) t) AS p90_hosts_per_inventory;" \
        "inventory-distribution.txt"

    run_controller_query "Project Distribution" \
        "SELECT (SELECT COUNT(*) FROM main_unifiedjobtemplate WHERE polymorphic_ctype_id IN (SELECT id FROM django_content_type WHERE app_label='main' AND model='project')) AS project_count, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY proj_count) FROM (SELECT COUNT(ujt.id) AS proj_count FROM main_organization o LEFT JOIN main_unifiedjobtemplate ujt ON ujt.organization_id = o.id AND ujt.polymorphic_ctype_id IN (SELECT id FROM django_content_type WHERE app_label='main' AND model='project') GROUP BY o.id) t) AS median_projects_per_org, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY proj_count) FROM (SELECT COUNT(ujt.id) AS proj_count FROM main_organization o LEFT JOIN main_unifiedjobtemplate ujt ON ujt.organization_id = o.id AND ujt.polymorphic_ctype_id IN (SELECT id FROM django_content_type WHERE app_label='main' AND model='project') GROUP BY o.id) t) AS p90_projects_per_org;" \
        "project-distribution.txt"

    run_controller_query "Job Template Distribution" \
        "SELECT (SELECT COUNT(*) FROM main_jobtemplate) AS total_job_templates, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY jt_count) FROM (SELECT COUNT(jt.unifiedjobtemplate_ptr_id) AS jt_count FROM main_project p LEFT JOIN main_jobtemplate jt ON jt.project_id = p.unifiedjobtemplate_ptr_id GROUP BY p.unifiedjobtemplate_ptr_id) t) AS median_job_templates_per_project, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY jt_count) FROM (SELECT COUNT(jt.unifiedjobtemplate_ptr_id) AS jt_count FROM main_project p LEFT JOIN main_jobtemplate jt ON jt.project_id = p.unifiedjobtemplate_ptr_id GROUP BY p.unifiedjobtemplate_ptr_id) t) AS p90_job_templates_per_project, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY job_count) FROM (SELECT jt.unifiedjobtemplate_ptr_id, COALESCE(jc.job_count, 0) AS job_count FROM main_jobtemplate jt LEFT JOIN (SELECT j.job_template_id, COUNT(*) AS job_count FROM main_job j JOIN main_unifiedjob uj ON uj.id = j.unifiedjob_ptr_id WHERE uj.started >= CURRENT_DATE - INTERVAL '30 days' GROUP BY j.job_template_id) jc ON jc.job_template_id = jt.unifiedjobtemplate_ptr_id) t) AS median_jobs_per_template_30d, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY job_count) FROM (SELECT jt.unifiedjobtemplate_ptr_id, COALESCE(jc.job_count, 0) AS job_count FROM main_jobtemplate jt LEFT JOIN (SELECT j.job_template_id, COUNT(*) AS job_count FROM main_job j JOIN main_unifiedjob uj ON uj.id = j.unifiedjob_ptr_id WHERE uj.started >= CURRENT_DATE - INTERVAL '30 days' GROUP BY j.job_template_id) jc ON jc.job_template_id = jt.unifiedjobtemplate_ptr_id) t) AS p90_jobs_per_template_30d;" \
        "job-template-distribution.txt"

    run_controller_query "Job Distribution" \
        "SELECT (SELECT COUNT(*) FROM main_job) AS total_jobs, (SELECT COUNT(*) FROM main_job j JOIN main_unifiedjob uj ON uj.id = j.unifiedjob_ptr_id WHERE uj.started >= CURRENT_DATE - INTERVAL '1 day') AS jobs_24h, (SELECT COUNT(*) FROM main_job j JOIN main_unifiedjob uj ON uj.id = j.unifiedjob_ptr_id WHERE uj.started >= CURRENT_DATE - INTERVAL '7 days') AS jobs_7d, (SELECT COUNT(*) FROM main_job j JOIN main_unifiedjob uj ON uj.id = j.unifiedjob_ptr_id WHERE uj.started >= CURRENT_DATE - INTERVAL '30 days') AS jobs_30d;" \
        "job-distribution.txt"

    run_controller_query "Job Events" \
        "SELECT COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY event_count), 0) AS median_job_events_per_job, COALESCE(percentile_cont(0.9) WITHIN GROUP (ORDER BY event_count), 0) AS p90_job_events_per_job FROM (SELECT COUNT(je.id) AS event_count FROM (SELECT unifiedjob_ptr_id FROM main_job ORDER BY unifiedjob_ptr_id DESC LIMIT 500) j LEFT JOIN main_jobevent je ON je.job_id = j.unifiedjob_ptr_id GROUP BY j.unifiedjob_ptr_id) t;" \
        "job-events.txt" \
        "sampling 500 most recent jobs"

    if [[ "$AAP_VERSION_BRANCH" == "2.4" ]]; then
        run_controller_query "Controller RBAC Distribution" \
            "SELECT COUNT(DISTINCT cr.id) AS role_definition_count, COUNT(DISTINCT cur.id) AS role_user_assignment_count, COUNT(DISTINCT ctr.id) AS role_team_assignment_count FROM controller_role cr FULL OUTER JOIN controller_user_role cur ON TRUE FULL OUTER JOIN controller_team_role ctr ON TRUE;" \
            "controller-rbac-distribution.txt"
    else
        run_controller_query "Controller RBAC Distribution" \
            "SELECT COUNT(DISTINCT re.id) AS role_evaluation_count, COUNT(DISTINCT rua.id) AS role_user_assignment_count, COUNT(DISTINCT rta.id) AS role_team_assignment_count FROM dab_rbac_roleevaluation re FULL OUTER JOIN dab_rbac_roleuserassignment rua ON TRUE FULL OUTER JOIN dab_rbac_roleteamassignment rta ON TRUE;" \
            "controller-rbac-distribution.txt"
    fi

    run_controller_query "Database Config" \
        "SELECT version() AS pg_version, (SELECT setting FROM pg_settings WHERE name = 'max_connections') AS max_connections, (SELECT setting FROM pg_settings WHERE name = 'work_mem') AS work_mem, (SELECT setting FROM pg_settings WHERE name = 'shared_buffers') AS shared_buffers, (SELECT setting FROM pg_settings WHERE name = 'effective_cache_size') AS effective_cache_size, (SELECT setting FROM pg_settings WHERE name = 'checkpoint_completion_target') AS checkpoint_completion_target, (SELECT setting FROM pg_settings WHERE name = 'wal_buffers') AS wal_buffers, (SELECT setting FROM pg_settings WHERE name = 'maintenance_work_mem') AS maintenance_work_mem, (SELECT setting FROM pg_settings WHERE name = 'random_page_cost') AS random_page_cost, (SELECT setting FROM pg_settings WHERE name = 'effective_io_concurrency') AS effective_io_concurrency;" \
        "infrastructure-config.txt"

    if [[ "$AAP_VERSION_BRANCH" == "2.4" ]]; then
        run_controller_query "User/Team/Org Distribution" \
            "SELECT (SELECT COUNT(*) FROM main_user) AS total_users, (SELECT COUNT(*) FROM main_team) AS total_teams, (SELECT COUNT(*) FROM main_organization) AS total_organizations, (SELECT COUNT(*) FROM controller_user_role) AS role_user_assignment_count, (SELECT COUNT(*) FROM controller_team_role) AS role_team_assignment_count, (SELECT COUNT(*) FROM controller_role) AS total_roles;" \
            "user-org-distribution.txt"
    fi
}

# ── gateway queries ───────────────────────────────────────────────────────────

collect_gateway() {
    echo ""
    echo "=== Gateway Queries ==="

    run_gateway_query "Gateway Bloat Metrics" \
        "SELECT schemaname, relname, n_live_tup, n_dead_tup, last_vacuum, last_analyze FROM pg_stat_user_tables WHERE schemaname = 'public' ORDER BY n_dead_tup DESC;" \
        "bloat-gateway.txt"

    run_gateway_query "Gateway RBAC Distribution" \
        "SELECT (SELECT COUNT(*) FROM aap_gateway_api_user) AS total_users, (SELECT COUNT(*) FROM aap_gateway_api_team) AS total_teams, (SELECT COUNT(*) FROM dab_rbac_roledefinition) AS total_roles, (SELECT COUNT(*) FROM aap_gateway_api_organization) AS total_organizations;" \
        "gateway-rbac-distribution.txt"

    run_gateway_query "Gateway Organization/Team Distribution" \
        "SELECT COALESCE((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY role_count) FROM (SELECT COUNT(DISTINCT rua.role_definition_id) AS role_count FROM aap_gateway_api_organization o LEFT JOIN dab_rbac_roleuserassignment rua ON ((rua.object_id = o.id::text AND rua.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='organization')) OR EXISTS (SELECT 1 FROM dab_rbac_objectrole orole WHERE orole.id = rua.object_role_id AND orole.object_id = o.id::text AND orole.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='organization'))) GROUP BY o.id) t), 0) AS median_roles_per_org, COALESCE((SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY role_count) FROM (SELECT COUNT(DISTINCT rua.role_definition_id) AS role_count FROM aap_gateway_api_organization o LEFT JOIN dab_rbac_roleuserassignment rua ON ((rua.object_id = o.id::text AND rua.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='organization')) OR EXISTS (SELECT 1 FROM dab_rbac_objectrole orole WHERE orole.id = rua.object_role_id AND orole.object_id = o.id::text AND orole.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='organization'))) GROUP BY o.id) t), 0) AS p90_roles_per_org, COALESCE((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY user_count) FROM (SELECT COUNT(DISTINCT rua.user_id) AS user_count FROM aap_gateway_api_organization o LEFT JOIN dab_rbac_roleuserassignment rua ON ((rua.object_id = o.id::text AND rua.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='organization')) OR EXISTS (SELECT 1 FROM dab_rbac_objectrole orole WHERE orole.id = rua.object_role_id AND orole.object_id = o.id::text AND orole.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='organization'))) GROUP BY o.id) t), 0) AS median_users_per_org, COALESCE((SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY user_count) FROM (SELECT COUNT(DISTINCT rua.user_id) AS user_count FROM aap_gateway_api_organization o LEFT JOIN dab_rbac_roleuserassignment rua ON ((rua.object_id = o.id::text AND rua.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='organization')) OR EXISTS (SELECT 1 FROM dab_rbac_objectrole orole WHERE orole.id = rua.object_role_id AND orole.object_id = o.id::text AND orole.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='organization'))) GROUP BY o.id) t), 0) AS p90_users_per_org, COALESCE((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY team_count) FROM (SELECT COUNT(DISTINCT t.id) AS team_count FROM aap_gateway_api_organization o LEFT JOIN aap_gateway_api_team t ON t.organization_id = o.id GROUP BY o.id) t), 0) AS median_teams_per_org, COALESCE((SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY team_count) FROM (SELECT COUNT(DISTINCT t.id) AS team_count FROM aap_gateway_api_organization o LEFT JOIN aap_gateway_api_team t ON t.organization_id = o.id GROUP BY o.id) t), 0) AS p90_teams_per_org, COALESCE((SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY user_count) FROM (SELECT COUNT(DISTINCT rua.user_id) AS user_count FROM aap_gateway_api_team t LEFT JOIN dab_rbac_roleuserassignment rua ON ((rua.object_id = t.id::text AND rua.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='team')) OR EXISTS (SELECT 1 FROM dab_rbac_objectrole orole WHERE orole.id = rua.object_role_id AND orole.object_id = t.id::text AND orole.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='team'))) GROUP BY t.id) t2), 0) AS median_users_per_team, COALESCE((SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY user_count) FROM (SELECT COUNT(DISTINCT rua.user_id) AS user_count FROM aap_gateway_api_team t LEFT JOIN dab_rbac_roleuserassignment rua ON ((rua.object_id = t.id::text AND rua.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='team')) OR EXISTS (SELECT 1 FROM dab_rbac_objectrole orole WHERE orole.id = rua.object_role_id AND orole.object_id = t.id::text AND orole.content_type_id = (SELECT id FROM dab_rbac_dabcontenttype WHERE app_label='aap_gateway_api' AND model='team'))) GROUP BY t.id) t2), 0) AS p90_users_per_team;" \
        "gateway-distribution.txt"
}

# ── metadata ──────────────────────────────────────────────────────────────────

replica_count() {
    local deployment count
    for deployment in "$@"; do
        count=$(oc get deployment "$deployment" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)
        [[ -n "$count" ]] && { echo "$count"; return; }
    done
    echo "unknown"
}

collect_metadata() {
    info "Collecting metadata..."
    local aap_version ocp_version node_count cluster_name
    discover_aap_instance
    discover_controller_name
    aap_version=$(oc get aap -n "$NAMESPACE" -o jsonpath='{.items[0].status.version}' 2>/dev/null || echo "unknown")
    ocp_version=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion' 2>/dev/null || echo "unknown")
    node_count=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    cluster_name=$(oc config current-context 2>/dev/null || echo "unknown")
    task_replicas=$(replica_count \
        "${CONTROLLER_NAME}-controller-task" "${CONTROLLER_NAME}-task")
    web_replicas=$(replica_count \
        "${CONTROLLER_NAME}-controller-web" "${CONTROLLER_NAME}-web")
    gateway_replicas=$(replica_count "${AAP_INSTANCE}-gateway")

    cat > "$WORKDIR/metadata.txt" <<EOF
=== AAP Scale Profile Metadata ===
Collection Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Cluster Name: ${cluster_name}
OpenShift Version: ${ocp_version}
Node Count: ${node_count}
AAP Version: ${aap_version}
Controller Task Replicas: ${task_replicas}
Controller Web Replicas: ${web_replicas}
Gateway Replicas: ${gateway_replicas}
AAP Namespace: ${NAMESPACE}
AAP Instance: ${AAP_INSTANCE}
Controller Name: ${CONTROLLER_NAME}
AAP Version Branch: ${AAP_VERSION_BRANCH}
Script Version: ${SCRIPT_VERSION}
EOF
    success "Metadata collected"
}

# ── bundle ────────────────────────────────────────────────────────────────────

bundle() {
    echo ""
    info "Bundling results..."
    tar -czf "$OUTPUT_FILE" -C "$WORKDIR" .
    success "Bundle created: $OUTPUT_FILE"
    echo ""
    echo "Files included:"
    tar -tzf "$OUTPUT_FILE" | sed 's|^\./||' | grep '\.txt$' | sort
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    echo ""
    echo "AAP Scale Profile Collection"
    echo "Namespace: $NAMESPACE"
    echo "========================================"

    preflight
    discover_controller
    verify_dbshell "$CONTROLLER_POD" "$CONTROLLER_CONTAINER" awx-manage "Controller"
    detect_version
    collect_controller

    if [[ "$AAP_VERSION_BRANCH" == "2.5+" ]]; then
        discover_gateway
        verify_dbshell "$GATEWAY_POD" "$GATEWAY_CONTAINER" aap-gateway-manage "Gateway"
        collect_gateway
    fi

    collect_metadata
    bundle

    echo ""
    if [[ $ERRORS -gt 0 ]]; then
        echo "[WARN]  $ERRORS item(s) had warnings. Send the bundle to Red Hat anyway. The metadata will help diagnose."
    else
        echo "All queries succeeded."
    fi
    echo ""
    echo -e "\033[1mOptional:\033[0m review what's included before sending."
    echo "  List files:         tar -tzf $OUTPUT_FILE"
    echo "  Print all files:       tar -xOzf $OUTPUT_FILE | less"
    echo "  Print a single file:       tar -xOzf $OUTPUT_FILE ./<filename>.txt"
    echo ""
    echo -e "\033[1mNext step:\033[0m attach $OUTPUT_FILE to your Red Hat support case."
    echo ""
}

main
