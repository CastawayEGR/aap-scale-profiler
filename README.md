# AAP Scale Profiler

This script profiles your AAP environment by collecting read-only aggregate metrics. It takes about 5 minutes to run and can help with capacity planning, workload analysis, and understanding your environment's scale. Results can also be shared with Red Hat Support if needed.

---

## Prerequisites

- `oc` CLI installed and logged in to your OpenShift cluster
- Permission to exec into AAP pods (`oc exec`)
- `jq` installed (for metadata collection — optional but recommended)

---

## Step 1: Find Your AAP Namespace

```bash
oc get aap -A
```

Note the value in the NAMESPACE column. You will use it in Step 3.

---

## Step 2: Download the Script

Obtain `collect-aap-scale-profile.sh` from your Red Hat support representative (or clone from https://github.com/kkmedlin/aap-scale-profiler) and place it in any directory on your local machine.

```bash
chmod +x collect-aap-scale-profile.sh
```

---

## Step 3: Run the Script

```bash
./collect-aap-scale-profile.sh <namespace>
```

Replace `<namespace>` with the value from Step 1. For example:

```bash
./collect-aap-scale-profile.sh <namespace>
```

The script will display its progress and create a file named `aap-scale-profile-<date>.tar.gz` in your current directory.

---

## Step 4 (Optional): Review the Profile

You can inspect the contents of the bundle to see exactly what data was collected.

List the files included:

```bash
tar -tzf aap-scale-profile-*.tar.gz
```

Print all files to the terminal (scroll with arrow keys, `q` to quit):

```bash
tar -xOzf aap-scale-profile-*.tar.gz | less
```

Print a single file to the terminal:

```bash
tar -xOzf aap-scale-profile-*.tar.gz ./bloat-controller.txt
```

Replace `bloat-controller.txt` with any filename from the list above.

---

## Step 5 (Optional): Share Results with Red Hat Support

If you're working with Red Hat Support, attach the `.tar.gz` file to your support case.

---

## What the Script Collects

The script collects **aggregate metrics only** — no names, no credentials, no automation content.

✅ Collected:
- Table bloat statistics
- Organization, inventory, host, project, and job template counts
- Job volume and event distribution (last 30 days)
- RBAC assignment counts
- PostgreSQL configuration settings

❌ Not collected:
- Organization, inventory, or host names
- User names, passwords, or API tokens
- Job output or playbook content
- Credentials or secrets

---

## Troubleshooting

**"oc: command not found"**
Install the OpenShift CLI: https://docs.openshift.com/container-platform/latest/cli_tools/openshift_cli/getting-started-cli.html

**"Not logged in to an OpenShift cluster"**
Run `oc login` with your cluster URL and credentials, then re-run the script.

**"Namespace not found"**
Verify the namespace with `oc get aap -A` and use the exact value shown.

**A query produced an empty file**
The script will still create the bundle. Send it to Red Hat along with a note about which query failed.

---

## Support

If you encounter issues or are working with Red Hat Support, provide:
1. The `.tar.gz` file
2. Your support case number
3. Any error messages from the script

---

**Project:** aap-scale-profiler  
**Script Version:** 1.0.0  
**Last Updated:** 2026-09-03
