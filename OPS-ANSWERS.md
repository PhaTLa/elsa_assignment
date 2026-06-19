# Part 7 — Ops Questions

## Question 1: EKS 1.33 → 1.35 Upgrade (Zero Downtime)

### Upgrade Order

1. **Control Plane First**
   - AWS handles this automatically; check CloudWatch for `events.k8s.aws.amazonaws.com` events
   - API latency ±500ms during update, workloads unaffected

2. **CNI Add-ons** (VPC-CNI, CoreDNS, kube-proxy)
   - Update via EKS console or `aws eks update-addon`
   - Stagger updates 5 min apart to avoid simultaneous pod evictions
   - Watch `kubectl get pods -n kube-system` for pod restarts

3. **Worker Nodes** (gradual, using node groups)
   - Create new node group with v1.35, target same label selectors
   - Drain old nodes: `kubectl drain node-X --ignore-daemonsets --delete-emptydir-data`
   - Delete old node group when drained
   - Repeat per node group (do NOT drain all at once)

### Top 3 Risks

| Risk | Impact | Mitigation |
||--|--|
| **API server incompatibility** | Apps can't reach API during control plane rollout | Use API server version negotiation; test migration in staging first |
| **Pod network disruption** (CNI old version + new kubelet) | 60-120s DNS failures when node joins cluster | Update CNI BEFORE draining nodes; verify `aws-node` DaemonSet is Ready |
| **PDB violations during drain** | Pods stuck in `Terminating` → eviction timeout → node drain fails | Verify all Deployments have PDB or `maxUnavailable: 1`; drain with `--timeout=5m` |



## Question 2: Spot Reclaim Alert Fatigue

### Problem
Spot nodes get reclaimed at 3 AM → `KubeNodeUnreachable` → paging on-call → all resolve by new spots auto-replace.

### Strategy: 2-Tier Alert Design

**Tier 1: Suppress False Positives (Node-level)**
```yaml
# PrometheusRule: Silence alerts for FIRST 5 min of reclaim
- alert: KubeNodeUnreachable
  expr: kube_node_status_condition{condition="Ready"} == 0
  for: 6m  # Changed from 1m to 6m, assume that the issue automatically resolved in 5m
  annotations:
    summary: Node unreach (if > 6 min, REAL issue)
```

- Only alert if node is unreachable for **6+ minutes** (not 1 min)
- Spot gets 2-5 min to drain gracefully before auto-replacement kicks in
- Real issues (network partition, bad AMI) stay down longer

**Tier 2: Workload Health (Pod-level)**
- Monitor **pod ready replicas**, NOT node status
- If pods stay down >5 min after reclaim, THEN alert (actual workload impact)

**Tier 3: Time-Window Suppression (Context)**
- Scheduled maintenance window: auto-suppress node alerts 2:45 AM - 3:15 AM
- Link alert to Slack #ops channel, NOT PagerDuty (no page-out)
- Page only if: `KubeNodeUnreachable AND kube_deployment_status_replicas_ready < desired`

### Result
- Spot reclaims at 3 AM: No alerts, no pages
- Real failure (node stuck for 10 min): Alert + page after 6 min



## Question 3: Cloudflare + Mobile LCP 5s (HTML Caching Issue)

### Unresolved:
- **Reason**: I don't have any experience with this kind of error on Cloudflare before, because I don't often work with Cloudflare and mobile services.


## Question 4: Secrets Management on EKS

### Approach 1: AWS Secrets Manager + kube-secrets-store-csi-driver
**How:** Pods reference AWS Secrets Manager via CSI driver; secrets mounted as files
- Pros: No K8s secret objects (no etcd snooping), automatic rotation, audit trail
- Cons: ~200ms latency per secret fetch, extra IAM setup

### Approach 2: Sealed Secrets (kubeseal)
**How:** Encrypt secrets in Git, decrypt on cluster with private key
- Pros: GitOps-friendly, no external dependency, fast (no API call)
- Cons: Private key must be protected on cluster, no audit trail


## Recommendation for Startup

**Pick: AWS Secrets Manager + CSI Driver**

**Why:**
1. **Managed by AWS** → no operational burden (auto-rotation, compliance, backups)
2. **Audit trail** → "Who accessed DB password at 3 PM?" → CloudTrail shows it
3. **Multi-cluster ready** → Share secrets across prod clusters without replicating keys
4. **Startup scales** → When you hire 10 engineers, one keyless access manager > sealed-secrets chaos


**Sealed Secrets fallback:** If AWS costs blow up, pivot to Sealed Secrets then.



**Summary Table**

| Question | Answer Type | Complexity | Uptime Impact |
|-||--|--|
| 1. EKS Upgrade | Process + Risks | Medium | Zero-downtime W/ validation |
| 2. Spot Alerts | Alert tuning | Low | False-positive elimination |
| 3. Cache Diagnosis | N/A | N/A | N/A |
| 4. Secrets | Architecture | Medium | Operator dependency → AWS dependency |
