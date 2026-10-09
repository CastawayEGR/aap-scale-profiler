# AAP Scale Profiler — Manual Profile Collection Kit

## Overview

This kit allows you to generate a detailed scale profile of your AAP environment by running read-only queries. Use the results to understand your deployment's scale characteristics, plan capacity, or share with Red Hat Support when needed.

**What you'll do:**
1. Detect your AAP version (one command)
2. Run Controller queries from your local machine — output saves directly to your computer
3. If AAP 2.5 or later: Run Gateway queries the same way
4. Add metadata and bundle results

**Time required:** ~20 minutes (read-only queries + file transfer)

All queries run from your **local machine** using `oc exec`. You never need to enter the pod interactively, and no files are written to the pod. If the pod restarts between queries, just re-run the one that failed.

---

## Supported AAP Versions

This kit supports **AAP 2.4, 2.5, 2.6, and 2.7**.

The version detection command in Step 3 tells you which query variants to run. The kit branches in two places:
- **Controller Command 7 (RBAC):** different table names in 2.4 vs 2.5+
- **Controller Command 9:** AAP 2.4 only — captures user/org/team data that lives in the Gateway database on 2.5+

---

## Prerequisites

### Access to AAP Pods

You need access to your OpenShift cluster and the ability to run `oc exec` commands from your local machine.

### Permissions

- Execute into AAP pods via `oc exec`
- Read database tables (standard for AAP admins)
- Required CLI tools: `oc`, `tar`, `jq` (optional but recommended)

---

## Step 1: Find Your AAP Namespace and Controller Pod

### Find Your AAP Namespace

```bash
oc get aap -A
```

Note the NAMESPACE column.

If the above returns no results, try:
```bash
oc get pods -A | grep aap-controller
```
Note the value in the left-side column.

### Find a Controller Pod

```bash
oc get pods -n <your-namespace> | grep aap-controller-task
```

Example output:
```
aap-controller-task-69c8469c8-m567c    4/4     Running
aap-controller-task-69c8469c8-xbhtv    4/4     Running
```

Pick one pod.

The container name matches the pod name prefix:
- Pod starts with `aap-controller-task-` → container is `aap-controller-task`
- Pod starts with `aap-controller-web-` → container is `aap-controller-web`

### Set Your Variables

Once you have the namespace, pod name, and container name, set these in your terminal. All commands in this guide use these variables — you only need to set them once per session.

```bash
NAMESPACE=aap                                          # replace with your namespace
CONTROLLER_POD=aap-controller-task-69c8469c8-m567c    # replace with your pod name
CONTROLLER_CONTAINER=aap-controller-task               # replace with your container name
```

---

## Step 2: Prepare Output Directory

```bash
mkdir -p ~/aap-collection
cd ~/aap-collection
```

---

## Step 3: Detect Your AAP Version

Run this from your local machine. The result determines which query variants to use.

```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT CASE WHEN COUNT(*) > 0 THEN 'AAP 2.5+' ELSE 'AAP 2.4' END AS aap_version FROM django_migrations WHERE app = 'dab_rbac';" \
  2>/dev/null
```

Expected output:
```
 aap_version
-------------
 AAP 2.5+
(1 row)
```

Note whether you see `AAP 2.5+` or `AAP 2.4`. You will use the matching variant for Command 7 and run Command 9 only on AAP 2.4.

---

## Step 4: Run Controller Queries

All commands below run from your **local machine**. Each one saves output directly to `~/aap-collection/`. If a command fails because the pod restarted, find the new pod name with `oc get pods -n $NAMESPACE | grep aap-controller-task`, update `CONTROLLER_POD`, and re-run just that command.

```bash
cd ~/aap-collection
```

#### Command 1: Bloat Metrics

```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT schemaname, relname, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum, last_analyze, last_autoanalyze FROM pg_stat_user_tables WHERE schemaname = 'public' ORDER BY n_dead_tup DESC;" \
  > ./bloat-controller.txt 2>/dev/null
```

#### Command 2: Inventory Distribution

```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT (SELECT COUNT(*) FROM main_organization) AS org_count, (SELECT COUNT(*) FROM main_inventory) AS inventory_count, (SELECT COUNT(*) FROM main_host) AS host_count, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY inv_count) FROM (SELECT COUNT(i.id) AS inv_count FROM main_organization o LEFT JOIN main_inventory i ON i.organization_id = o.id GROUP BY o.id) t) AS median_inventories_per_org, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY inv_count) FROM (SELECT COUNT(i.id) AS inv_count FROM main_organization o LEFT JOIN main_inventory i ON i.organization_id = o.id GROUP BY o.id) t) AS p90_inventories_per_org, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY host_count) FROM (SELECT COUNT(h.id) AS host_count FROM main_inventory i LEFT JOIN main_host h ON h.inventory_id = i.id GROUP BY i.id) t) AS median_hosts_per_inventory, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY host_count) FROM (SELECT COUNT(h.id) AS host_count FROM main_inventory i LEFT JOIN main_host h ON h.inventory_id = i.id GROUP BY i.id) t) AS p90_hosts_per_inventory;" \
  > ./inventory-distribution.txt 2>/dev/null
```

#### Command 3: Project Distribution

```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT (SELECT COUNT(*) FROM main_unifiedjobtemplate WHERE polymorphic_ctype_id IN (SELECT id FROM django_content_type WHERE app_label='main' AND model='project')) AS project_count, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY proj_count) FROM (SELECT COUNT(ujt.id) AS proj_count FROM main_organization o LEFT JOIN main_unifiedjobtemplate ujt ON ujt.organization_id = o.id AND ujt.polymorphic_ctype_id IN (SELECT id FROM django_content_type WHERE app_label='main' AND model='project') GROUP BY o.id) t) AS median_projects_per_org, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY proj_count) FROM (SELECT COUNT(ujt.id) AS proj_count FROM main_organization o LEFT JOIN main_unifiedjobtemplate ujt ON ujt.organization_id = o.id AND ujt.polymorphic_ctype_id IN (SELECT id FROM django_content_type WHERE app_label='main' AND model='project') GROUP BY o.id) t) AS p90_projects_per_org;" \
  > ./project-distribution.txt 2>/dev/null
```

#### Command 4: Job Template Distribution

```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT (SELECT COUNT(*) FROM main_jobtemplate) AS total_job_templates, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY jt_count) FROM (SELECT COUNT(jt.unifiedjobtemplate_ptr_id) AS jt_count FROM main_project p LEFT JOIN main_jobtemplate jt ON jt.project_id = p.unifiedjobtemplate_ptr_id GROUP BY p.unifiedjobtemplate_ptr_id) t) AS median_job_templates_per_project, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY jt_count) FROM (SELECT COUNT(jt.unifiedjobtemplate_ptr_id) AS jt_count FROM main_project p LEFT JOIN main_jobtemplate jt ON jt.project_id = p.unifiedjobtemplate_ptr_id GROUP BY p.unifiedjobtemplate_ptr_id) t) AS p90_job_templates_per_project, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY job_count) FROM (SELECT jt.unifiedjobtemplate_ptr_id, COALESCE(jc.job_count, 0) AS job_count FROM main_jobtemplate jt LEFT JOIN (SELECT j.job_template_id, COUNT(*) AS job_count FROM main_job j JOIN main_unifiedjob uj ON uj.id = j.unifiedjob_ptr_id WHERE uj.started >= CURRENT_DATE - INTERVAL '30 days' GROUP BY j.job_template_id) jc ON jc.job_template_id = jt.unifiedjobtemplate_ptr_id) t) AS median_jobs_per_template_30d, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY job_count) FROM (SELECT jt.unifiedjobtemplate_ptr_id, COALESCE(jc.job_count, 0) AS job_count FROM main_jobtemplate jt LEFT JOIN (SELECT j.job_template_id, COUNT(*) AS job_count FROM main_job j JOIN main_unifiedjob uj ON uj.id = j.unifiedjob_ptr_id WHERE uj.started >= CURRENT_DATE - INTERVAL '30 days' GROUP BY j.job_template_id) jc ON jc.job_template_id = jt.unifiedjobtemplate_ptr_id) t) AS p90_jobs_per_template_30d;" \
  > ./job-template-distribution.txt 2>/dev/null
```

#### Command 5: Job Distribution

```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT (SELECT COUNT(*) FROM main_job) AS total_jobs, (SELECT COUNT(*) FROM main_job j JOIN main_unifiedjob uj ON uj.id = j.unifiedjob_ptr_id WHERE uj.started >= CURRENT_DATE - INTERVAL '1 day') AS jobs_24h, (SELECT COUNT(*) FROM main_job j JOIN main_unifiedjob uj ON uj.id = j.unifiedjob_ptr_id WHERE uj.started >= CURRENT_DATE - INTERVAL '7 days') AS jobs_7d, (SELECT COUNT(*) FROM main_job j JOIN main_unifiedjob uj ON uj.id = j.unifiedjob_ptr_id WHERE uj.started >= CURRENT_DATE - INTERVAL '30 days') AS jobs_30d;" \
  > ./job-distribution.txt 2>/dev/null
```

#### Command 6: Job Events

> This query samples the 500 most recent jobs.

```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT COALESCE(percentile_cont(0.5) WITHIN GROUP (ORDER BY event_count), 0) AS median_job_events_per_job, COALESCE(percentile_cont(0.9) WITHIN GROUP (ORDER BY event_count), 0) AS p90_job_events_per_job FROM (SELECT uj.id, uj.created FROM main_unifiedjob uj JOIN main_job j ON j.unifiedjob_ptr_id = uj.id ORDER BY uj.id DESC LIMIT 500) j CROSS JOIN LATERAL (SELECT COUNT(*) AS event_count FROM main_jobevent je WHERE je.job_id = j.id AND je.job_created = j.created) c;" \
  > ./job-events.txt 2>/dev/null
```

#### Command 7: Controller RBAC Distribution

Use the variant that matches your version detection result from Step 3.

**If AAP 2.4:**
```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT COUNT(DISTINCT cr.id) AS role_definition_count, COUNT(DISTINCT cur.id) AS role_user_assignment_count, COUNT(DISTINCT ctr.id) AS role_team_assignment_count FROM controller_role cr FULL OUTER JOIN controller_user_role cur ON TRUE FULL OUTER JOIN controller_team_role ctr ON TRUE;" \
  > ./controller-rbac-distribution.txt 2>/dev/null
```

**If AAP 2.5, 2.6, or 2.7:**
```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT COUNT(DISTINCT re.id) AS role_evaluation_count, COUNT(DISTINCT rua.id) AS role_user_assignment_count, COUNT(DISTINCT rta.id) AS role_team_assignment_count FROM dab_rbac_roleevaluation re FULL OUTER JOIN dab_rbac_roleuserassignment rua ON TRUE FULL OUTER JOIN dab_rbac_roleteamassignment rta ON TRUE;" \
  > ./controller-rbac-distribution.txt 2>/dev/null
```

#### Command 8: Database Config

```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT version() AS pg_version, (SELECT setting FROM pg_settings WHERE name = 'max_connections') AS max_connections, (SELECT setting FROM pg_settings WHERE name = 'work_mem') AS work_mem, (SELECT setting FROM pg_settings WHERE name = 'shared_buffers') AS shared_buffers, (SELECT setting FROM pg_settings WHERE name = 'effective_cache_size') AS effective_cache_size, (SELECT setting FROM pg_settings WHERE name = 'checkpoint_completion_target') AS checkpoint_completion_target, (SELECT setting FROM pg_settings WHERE name = 'wal_buffers') AS wal_buffers, (SELECT setting FROM pg_settings WHERE name = 'maintenance_work_mem') AS maintenance_work_mem, (SELECT setting FROM pg_settings WHERE name = 'random_page_cost') AS random_page_cost, (SELECT setting FROM pg_settings WHERE name = 'effective_io_concurrency') AS effective_io_concurrency;" \
  > ./infrastructure-config.txt 2>/dev/null
```

#### Command 9: User, Team, and Organization Counts (AAP 2.4 only)

If you are on AAP 2.5 or later, skip this command — that data comes from the Gateway in Step 5.

```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT (SELECT COUNT(*) FROM main_user) AS total_users, (SELECT COUNT(*) FROM main_team) AS total_teams, (SELECT COUNT(*) FROM main_organization) AS total_organizations, (SELECT COUNT(*) FROM controller_user_role) AS role_user_assignment_count, (SELECT COUNT(*) FROM controller_team_role) AS role_team_assignment_count, (SELECT COUNT(*) FROM controller_role) AS total_roles;" \
  > ./user-org-distribution.txt 2>/dev/null
```

### Verify Controller Files

```bash
ls -lah ~/aap-collection/*.txt
```

- **AAP 2.4:** You should see 9 files, all non-zero size
- **AAP 2.5+:** You should see 8 files, all non-zero size

If any file is missing or empty, re-run just that command. You do not need to re-run the others.

---

## Step 5: Run Gateway Queries (AAP 2.5+ only)

**If you are on AAP 2.4, skip to Step 6.**

### Find a Gateway Pod

```bash
oc get pods -n $NAMESPACE | grep aap-gateway
```

Example output:
```
aap-gateway-798f669699-42mbv    2/2     Running
aap-gateway-798f669699-npmjx    2/2     Running
```

Pick one pod and set it as a variable:

```bash
GATEWAY_POD=aap-gateway-798f669699-42mbv    # replace with your pod name
```

Find the gateway container name:

```bash
oc get pod $GATEWAY_POD -n $NAMESPACE -o jsonpath='{.spec.containers[*].name}'; echo
```

The output is a space-separated list. Look for `api` or `aap-gateway` — ignore others such as `proxy` or `redis`. Set it:

```bash
GATEWAY_CONTAINER=api    # replace with your container name
```

### Run Gateway Queries

All commands run from your **local machine**.

#### Command 1: Bloat Metrics (Gateway)

```bash
oc exec $GATEWAY_POD -n $NAMESPACE -c $GATEWAY_CONTAINER -- \
  aap-gateway-manage dbshell \
  <<< "SELECT schemaname, relname, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum, last_analyze, last_autoanalyze FROM pg_stat_user_tables WHERE schemaname = 'public' ORDER BY n_dead_tup DESC;" \
  > ~/aap-collection/bloat-gateway.txt 2>/dev/null
```

#### Command 2: Gateway RBAC Distribution

```bash
oc exec $GATEWAY_POD -n $NAMESPACE -c $GATEWAY_CONTAINER -- \
  aap-gateway-manage dbshell \
  <<< "SELECT (SELECT COUNT(*) FROM aap_gateway_api_user) AS total_users, (SELECT COUNT(*) FROM aap_gateway_api_team) AS total_teams, (SELECT COUNT(*) FROM dab_rbac_roledefinition) AS total_roles, (SELECT COUNT(*) FROM aap_gateway_api_organization) AS total_organizations;" \
  > ~/aap-collection/gateway-rbac-distribution.txt 2>/dev/null
```

#### Command 3: Gateway Organization/Team Distribution

```bash
oc exec $GATEWAY_POD -n $NAMESPACE -c $GATEWAY_CONTAINER -- \
  aap-gateway-manage dbshell \
  <<< "SELECT (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY role_count) FROM (SELECT COUNT(DISTINCT rua.role_definition_id) as role_count FROM aap_gateway_api_organization o LEFT JOIN dab_rbac_roleuserassignment rua ON rua.object_id = o.id::text AND rua.content_type_id = (SELECT id FROM django_content_type WHERE app_label='aap_gateway_api' AND model='organization') GROUP BY o.id) t) AS median_roles_per_org, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY role_count) FROM (SELECT COUNT(DISTINCT rua.role_definition_id) as role_count FROM aap_gateway_api_organization o LEFT JOIN dab_rbac_roleuserassignment rua ON rua.object_id = o.id::text AND rua.content_type_id = (SELECT id FROM django_content_type WHERE app_label='aap_gateway_api' AND model='organization') GROUP BY o.id) t) AS p90_roles_per_org, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY user_count) FROM (SELECT COUNT(DISTINCT rua.user_id) as user_count FROM aap_gateway_api_organization o LEFT JOIN dab_rbac_roleuserassignment rua ON rua.object_id = o.id::text AND rua.content_type_id = (SELECT id FROM django_content_type WHERE app_label='aap_gateway_api' AND model='organization') GROUP BY o.id) t) AS median_users_per_org, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY user_count) FROM (SELECT COUNT(DISTINCT rua.user_id) as user_count FROM aap_gateway_api_organization o LEFT JOIN dab_rbac_roleuserassignment rua ON rua.object_id = o.id::text AND rua.content_type_id = (SELECT id FROM django_content_type WHERE app_label='aap_gateway_api' AND model='organization') GROUP BY o.id) t) AS p90_users_per_org, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY team_count) FROM (SELECT COUNT(DISTINCT t.id) as team_count FROM aap_gateway_api_organization o LEFT JOIN aap_gateway_api_team t ON t.organization_id = o.id GROUP BY o.id) t) AS median_teams_per_org, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY team_count) FROM (SELECT COUNT(DISTINCT t.id) as team_count FROM aap_gateway_api_organization o LEFT JOIN aap_gateway_api_team t ON t.organization_id = o.id GROUP BY o.id) t) AS p90_teams_per_org, (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY user_count) FROM (SELECT COUNT(DISTINCT rua.user_id) as user_count FROM aap_gateway_api_team t LEFT JOIN dab_rbac_roleuserassignment rua ON rua.object_id = t.id::text AND rua.content_type_id = (SELECT id FROM django_content_type WHERE app_label='aap_gateway_api' AND model='team') GROUP BY t.id) t2) AS median_users_per_team, (SELECT percentile_cont(0.9) WITHIN GROUP (ORDER BY user_count) FROM (SELECT COUNT(DISTINCT rua.user_id) as user_count FROM aap_gateway_api_team t LEFT JOIN dab_rbac_roleuserassignment rua ON rua.object_id = t.id::text AND rua.content_type_id = (SELECT id FROM django_content_type WHERE app_label='aap_gateway_api' AND model='team') GROUP BY t.id) t2) AS p90_users_per_team;" \
  > ~/aap-collection/gateway-distribution.txt 2>/dev/null
```

### Verify Gateway Files

```bash
ls -lah ~/aap-collection/*.txt
```

You should now see 11 files (8 controller + 3 gateway), all non-zero size. If any gateway file is missing or empty, re-run just that command.

---

## Step 6: Create Metadata and Bundle

### Create Metadata File

```bash
cd ~/aap-collection

cat > metadata.txt <<EOF
=== AAP Scale Profile Metadata ===
Collection Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Cluster Name: $(oc config current-context)
OpenShift Version: $(oc version -o json | jq -r '.openshiftVersion')
Node Count: $(oc get nodes --no-headers | wc -l)
AAP Version: $(oc get aap -n $NAMESPACE -o jsonpath='{.items[0].status.version}')
Controller Task Replicas: $(oc get aap -n $NAMESPACE -o jsonpath='{.items[0].spec.controller.task_replicas}')
Controller Web Replicas: $(oc get aap -n $NAMESPACE -o jsonpath='{.items[0].spec.controller.web_replicas}')
Gateway Replicas: $(oc get aap -n $NAMESPACE -o jsonpath='{.items[0].spec.api.replicas}')
AAP Namespace: $NAMESPACE
EOF

cat metadata.txt
```

### Bundle Results

```bash
tar -czf aap-scale-profile-$(date +%Y%m%d-%H%M%S).tar.gz *.txt

ls -lah aap-scale-profile-*.tar.gz
tar -tzf aap-scale-profile-*.tar.gz
```

Expected file counts in the tar:
- **AAP 2.4:** 10 files (9 controller + 1 metadata)
- **AAP 2.5+:** 12 files (8 controller + 3 gateway + 1 metadata)

**Optional:** If working with Red Hat Support, attach this `.tar.gz` file to your support case.

---

## Troubleshooting

### "Pod not found"
The pod may have restarted. Find the new pod name and update your variable:
```bash
oc get pods -n $NAMESPACE | grep aap-controller-task
CONTROLLER_POD=<new-pod-name>
```
Then re-run the failed command.

### Output file is empty
The query ran but produced no output, or the pod restarted mid-query. Check:
```bash
ls -lah ~/aap-collection/*.txt
```
For any zero-size file, re-run just that command.

### "oc: command not found"
Install OpenShift CLI: https://docs.openshift.com/container-platform/latest/cli_tools/openshift_cli/getting-started-cli.html

### "awx-manage: command not found"
Verify you are using a controller pod, not a gateway, hub, or eda pod:
```bash
oc get pods -n $NAMESPACE | grep aap-controller-task
```

### "aap-gateway-manage: command not found"
Verify you are using a gateway pod and the correct container:
```bash
oc get pods -n $NAMESPACE | grep aap-gateway
oc get pod $GATEWAY_POD -n $NAMESPACE -o jsonpath='{.spec.containers[*].name}'; echo
```

### "column ... does not exist" or "relation ... does not exist"

First confirm you used the correct Command 7 variant. Re-run the version detection if needed:

```bash
oc exec $CONTROLLER_POD -n $NAMESPACE -c $CONTROLLER_CONTAINER -- \
  awx-manage dbshell \
  <<< "SELECT CASE WHEN COUNT(*) > 0 THEN 'AAP 2.5+' ELSE 'AAP 2.4' END AS aap_version FROM django_migrations WHERE app = 'dab_rbac';" \
  2>/dev/null
```

If you used the correct variant and still see the error, contact your Red Hat support representative with:
- Your AAP version: `oc get aap -n $NAMESPACE -o jsonpath='{.items[0].status.version}'`
- The full error message
- Which command number failed (Command 1-9 for Controller, 1-3 for Gateway)

### "Permission denied"
Verify you have permissions to exec into pods:
```bash
oc auth can-i create pods/exec
```

---

## What Data Is Collected

✅ **Safe to share** — Aggregate metrics and counts only
- Table bloat (dead tuple counts)
- Organization, inventory, host, and project counts
- Distribution statistics (median and p90) for inventories per organization, hosts per inventory, projects per organization, job templates per project, and jobs per job template (last 30 days)
- Job time distribution and event counts
- RBAC counts (roles, users, teams, assignments)
- PostgreSQL configuration

❌ **NOT collected**
- No organization names or inventory names
- No individual hostnames or IP addresses
- No user names, passwords, or API tokens
- No job output, playbook content, or automation payloads
- No credentials or secrets

---

## Support

If you encounter issues or are working with Red Hat Support, provide:
1. The `.tar.gz` file
2. Your support case number
3. Any errors encountered

---

**Project:** aap-scale-profiler  
**Version:** 1.5.0  
**Last Updated:** 2026-09-03
