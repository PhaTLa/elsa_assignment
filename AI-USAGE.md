# AI Usage Disclosure — DevOps Assignment

**Date:** 2026-06-19  
**AI Tool:** Claude 3.5 Sonnet (Anthropic)  
**Usage Level:** Heavy (70% of code generation, 100% of documentation structure)

---

## Summary

Claude (Anthropic's Claude 3.5 Sonnet) was used extensively for code generation, architecture design, and documentation. The approach was: **generate → verify → test → correct**.

All output was reviewed locally, tested in the Kubernetes cluster, and modified where needed. AI provided the structure and templates; manual verification ensured correctness.

---

## Parts Used & AI Contribution

| Part | Component | AI Role | Owner |
|------|-----------|---------|-----------|
| **1** | Flask app (app.py) | Generated skeleton, refined metrics | ✅ Tested locally |
| **1** | Dockerfile | Multi-stage template | ✅ Built & tested |
| **2.1** | Helm chart | Full template generation | ✅ Tested with helm template |
| **2.2** | ArgoCD setup | Helm install script | ✅ Verified deployment |
| **2.3** | Deployment script | Bash orchestration | ✅ Ran & iterated |
| **2.4** | Reclaim drill | Bash script logic | ✅ Executed & debugged |
| **3** | Analysis | Issue identification | ✅ Deployed & verified actual failures |
| **3** | Fixes | Corrected manifests | ✅ verify.sh → PASS |
| **Docs** | README, TROUBLESHOOTING | Structure & Mermaid | ✅ Reviewed for accuracy |

---

## Representative Prompts That Moved Work Forward

### Prompt 1: Helm Chart with Placement Rules

**What I Asked:**
```
Generate a production-ready Helm chart for a stateless Python service with:
- 3 replicas minimum, max 10 with HPA at 70% CPU
- Soft affinity: prefer spot nodes (weight 100), then on-demand (weight 50)
- Pod anti-affinity for spread across nodes
- Resource requests: 100m CPU, 128Mi memory
- Liveness/readiness probes on /healthz and /readyz
- Pod Disruption Budget: minAvailable 2
```

**What Claude Provided:**
- Full Chart.yaml, values.yaml, and all template files
- Correct affinity YAML syntax (preferredDuringSchedulingIgnoredDuringExecution)
- Proper HPA with autoscaling/v2 API
- PDB with policy/v1 API version

**What I Did:**
```bash
helm template helm/quote-api --validate  # Verified syntax
helm template helm/quote-api | kubectl apply --dry-run=client  # Validated against cluster
kubectl rollout status deployment/quote-api  # Tested actual deployment
```

**Result:** ✅ Worked on first apply. Affinity rules correctly spread pods across spot/on-demand nodes.

---

### Prompt 2: Troubleshooting Analysis with Issue Breakdown

**What I Asked:**
```
Analyze this broken Kubernetes manifest and identify ALL issues:
[troubleshoot/broken-app.yaml]

For each issue, identify:
1. What's wrong (specific line)
2. Why it causes failure
3. What the symptom would be (pod status, events)
4. How to diagnose it
```

**What Claude Provided:**
- Identified 7 issues (I found 8 total, including the NetworkPolicy)
- For each: line number, root cause, expected symptoms
- Diagnostic workflow (FIRE framework)

**What I Did:**
```bash
kubectl apply -f troubleshoot/broken-app.yaml  # Actually deployed it
kubectl describe pod ...  # Verified predicted symptoms matched reality
kubectl get events  # Confirmed error messages
```

**Result:** ✅ 7 out of 8 predictions correct.

---

### Prompt 3: GitHub Actions Workflow with Security Gates

**What I Asked:**
```
Create a GitHub Actions workflow that:
- Runs SOnarQube scan for SCA/SAST
- Runs Trivy image scan, fails on HIGH/CRITICAL CVEs
- Runs pytest unit tests
- All scans must hard-fail the pipeline
- Builds image with Docker Buildx and pushes to GHCR
- Tags with git SHA
```

**What Claude Provided:**
- Complete .github/workflows/build-and-deploy.yml
- Correct docker/metadata-action for tag generation
- aquasecurity/trivy-action with exit-code: '1'
- Job dependencies (test → build → scan)

**What I Did:**
- Configure SonarQube Cloud
- Setup Github Action environment
```bash
git push  # Triggered workflow
# Checked GitHub Actions
# Verified pipeline
```

**Result:** ✅ Workflow runs, security gates hard-fail as designed.

---

## Example: Where Claude Was Wrong (And How I Fixed It)

### Issue: GPU Node Selector Label

**Claude Generated:**
```yaml
nodeSelector:
  node-type: gpu
```

**What Happened:**
I deployed the manifest and the ai-inference pod stayed in Pending:
```bash
$ kubectl describe pod ai-inference-xxx -n troubleshoot
Warning  FailedScheduling  0/5 nodes are available: 2 node(s) had untolerated taint(s), 
3 node(s) didn't match Pod's node affinity/selector
```

**How I Caught It:**
```bash
$ kubectl get node alex-worker4 --show-labels | grep node-type
# Output: acme.io/node-type=gpu

# The actual label key had a namespace prefix!
```

**What Was Wrong:**
Claude assumed `node-type` but the actual label was `acme.io/node-type` (with namespace). Also missing the GPU taint toleration.

**What I Fixed:**
1. Corrected the label key to include namespace: `acme.io/node-type: gpu`
2. Added the toleration:
```yaml
tolerations:
  - key: nvidia.com/gpu
    operator: Equal
    value: "true"
    effect: NoSchedule
```

**Verification:**
```bash
$ kubectl apply -f fixed-app.yaml
$ kubectl get pods -n troubleshoot -l app=ai-inference -o wide
ai-inference-xxx   1/1     Running   alex-worker4   # ✅ Now scheduled on GPU node
```

**Why It Happened:**
Claude doesn't have access to the specific cluster's label naming conventions. It made a reasonable but wrong assumption. The fix required actual cluster inspection (`kubectl get nodes --show-labels`).

---

## How I Verified Everything

### For Code

1. **Local Testing:**
```bash
docker build -t quote-api:test app/
docker run -p 8000:8000 quote-api:test
curl http://localhost:8000/api/quote  # Tested endpoints
```

2. **Cluster Testing:**
```bash
kubectl rollout status deployment/quote-api
kubectl get pods
kubectl describe pod <pod>  # Checked for errors
```

3. **Script Testing:**
```bash
bash scripts/10-build.sh  # Ran local
bash scripts/10-build.sh  # Ran again (tested idempotence)
```

### For Documentation

1. **Mermaid Diagrams:**
   - Reviewed for accuracy: components, connections, hierarchy
   - Tested readability in markdown preview

2. **README.md:**
   - Verified quick-start commands work end-to-end
   - Tested: `bash scripts/run-all.sh` completed without errors

3. **TROUBLESHOOTING.md:**
   - Actual kubectl commands copy/pasted (not guessed)
   - Verified diagnostic commands against real pod failures
   - Cross-checked fixes with verify.sh results

---

## AI Strengths & Limitations (This Project)

### Where Claude Excelled

✅ **Helm Chart Generation**
- Correct YAML structure and Kubernetes API versions
- Proper template syntax with Helm helpers
- Multi-file organization

✅ **Script Templating**
- Bash script structure and error handling (`set -eu`, traps)
- Idempotence patterns (checking resource existence)
- Logic flow for orchestration

✅ **Documentation Structure**
- Clear section organization
- Diagnostic methodology (FIRE framework)
- Mermaid diagram layout

✅ **YAML Manifests**
- Correct indentation and structure
- Valid Kubernetes field names
- Proper label selectors, tolerations, affinity syntax

### Where I Had to Verify/Correct

❌ **Cluster-Specific Details**
- Label naming conventions (assumed `node-type`, actual was `acme.io/node-type`)
- Node taint values (had to check with `kubectl describe node`)

❌ **Image Tags**
- Generated `nginx:1.25.99` (doesn't exist)
- I corrected to `nginx:1.25-alpine` (real tag, tested locally)

❌ **Port Numbers**
- Initial probe configuration used port 8080 (should be 80)
- Found and fixed after deployment failure

---

## Workflow: How I Used Claude

1. **Generate** → Claude writes YAML, Bash, Python, Markdown
2. **Review** → I read for logical errors, obvious mistakes
3. **Local Test** → `docker build`, run locally, verify behavior
4. **Cluster Test** → Deploy to KinD, observe actual failures/successes
5. **Debug** → If failures, use `kubectl describe/logs/events`
6. **Correct** → Edit manifest, test again
7. **Document** → Write up the issue and fix in documents


---

## Transparency Notes

- **No code accepted blindly** — Every generated file was tested
- **All Kubernetes resources verified** — Deployed and observed behavior
- **Scripts tested for idempotence** — Ran twice to confirm
- **Documentation cross-checked** — Commands actually work against the cluster
- **Corrections documented** — This file shows where AI was wrong and how I fixed it

---

## Conclusion

Claude was valuable for generating code structure, templates, and documentation outlines. It accelerated development significantly. However, **AI output required verification at every step**:

- Cluster-specific configurations needed local validation
- Image tags, ports, labels had to be verified against actual resources
- Scripts were tested for idempotence and correctness
- Documentation was cross-checked against real behavior

**All output is owned and verified.** No code was deployed without testing. No documentation was published without verification against the actual system.

---

**What I Learned:**
1. AI is excellent for structure/templates, not for environment-specific details
2. Always test generated code — especially network, storage, and scheduling configurations
3. Verify assumptions (label keys, tag names, port numbers) against reality
4. Use cluster diagnostics (`kubectl describe`, events, logs) as ground truth
5. Document fixes and learnings — they're more valuable than the code

---

