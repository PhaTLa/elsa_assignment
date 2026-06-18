# Troubleshooting Report — DevOps Assignment Part 3

---

## Overview

This document details all issues found in `troubleshoot/broken-app.yaml`, the diagnostic process, root causes, and fixes applied. All issues have been resolved and verified with `troubleshoot/verify.sh` → **PASS**.

---

## Issue 1: ConfigMap Mount Failure

### Symptom
Pod stuck in `Pending` state with `ContainerCreating` status. kubelet events show:
```
Warning  FailedMount  MountVolume.SetUp failed for volume "html": configmap "web-conf" not found
```

### Diagnosis

**Step 1:** Check pod status
```bash
$ kubectl describe pod web-7dfd85c595-2gz2x -n troubleshoot
Status: Pending
State: Waiting (ContainerCreating)
```

**Step 2:** Review events
```bash
$ kubectl get events -n troubleshoot --sort-by='.lastTimestamp'
Warning  FailedMount  pod/web-7dfd85c595-2gz2x  MountVolume.SetUp failed for volume "html": configmap "web-conf" not found
```

**Step 3:** Check ConfigMap resources
```bash
$ kubectl get cm -n troubleshoot
NAME         DATA   AGE
web-config   1      2m
```

**Step 4:** Compare with volume mount definition
```bash
$ kubectl describe pod web-7dfd85c595-2gz2x -n troubleshoot | grep -A 3 "html:"
Volumes:
  html:
    Type:      ConfigMap
    Name:      web-conf          # ← Pod looking for "web-conf"
```

### Root Cause
Typo in deployment manifest. Volume definition references ConfigMap name `web-conf`, but the actual ConfigMap is named `web-config`. Case matters; `web-conf` ≠ `web-config`.

**Broken Code (broken-app.yaml line 80):**
```yaml
volumes:
  - name: html
    configMap:
      name: web-conf              # ❌ Typo: should be "web-config"
```

**Actual ConfigMap (broken-app.yaml line 16):**
```yaml
kind: ConfigMap
metadata:
  name: web-config
```

### Fix
Changed ConfigMap reference to match the actual ConfigMap name:

```yaml
volumes:
  - name: html
    configMap:
      name: web-config            # ✓ Corrected
```

### Verification
After fix:
```bash
$ kubectl get pod -n troubleshoot -l app=web
NAME                    READY   STATUS    RESTARTS   AGE
web-6b8546c487-6fs8r    1/1     Running   0          1m
web-6b8546c487-m2jhd    1/1     Running   0          1m
```

**Lesson:** Resource names are case-sensitive and must match exactly. Use `kubectl get <resource-type>` to verify names before referencing them in manifests.

---

## Issue 2: HTTP Probe Port Mismatch

### Symptom
Once ConfigMap issue fixed, pod would start but stay non-ready. Health probes would repeatedly fail:
```
Warning  Unhealthy  Liveness probe failed: HTTP probe failed with "connection refused" on port 8080
```

### Diagnosis

**Manifest defines:**
```yaml
containers:
  - name: nginx
    ports:
      - containerPort: 80         # Nginx listens on port 80
    livenessProbe:
      httpGet:
        port: 8080                # Probe tries port 8080
    readinessProbe:
      httpGet:
        port: 8080                # Probe tries port 8080
```

**Reality:**
- Nginx listens on `containerPort: 80`
- Probes attempt to connect to port `8080`
- Port mismatch causes connection refused

### Root Cause
Port number inconsistency between container port declaration and probe definitions. Probes must match the actual port the application listens on.

### Fix
Updated both probes to use port 80:

```yaml
livenessProbe:
  httpGet:
    path: /
    port: 80                      # ✓ Matches containerPort
  initialDelaySeconds: 5
  periodSeconds: 10

readinessProbe:
  httpGet:
    path: /
    port: 80                      # ✓ Matches containerPort
  initialDelaySeconds: 3
  periodSeconds: 5
```

### Verification
After fix:
```bash
$ kubectl get pod -n troubleshoot -l app=web -o wide
NAME                    READY   STATUS    RESTARTS   AGE
web-6b8546c487-6fs8r    1/1     Running   0          1m
web-6b8546c487-m2jhd    1/1     Running   0          1m
```

Probes now succeed and pods marked as Ready.

**Lesson:** Always match probe ports to the containerPort defined in the pod spec. Use `curl http://localhost:PORT` locally to verify port numbers.

---

## Issue 3: Excessive Memory Request

### Symptom
Pod can start but requests unrealistic amount of memory. In memory-constrained environments, pod would be stuck in `Pending` with:
```
0/5 nodes are available: 5 Insufficient memory
```

### Diagnosis

**Manifest requests:**
```yaml
resources:
  requests:
    cpu: 100m
    memory: 16Gi                  # 16 gigabytes
  limits:
    cpu: 500m
    memory: 16Gi
```

**Reality:**
- Nginx typically uses 20–50 MB of memory
- Requesting 16 GB is ~400× too high
- In this test environment, nodes happened to have enough memory (issue not blocking)

### Root Cause
Typo or placeholder value. 16Gi is unrealistic for a simple Nginx container. Should be 128Mi or less.

### Fix
Updated to realistic values:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi                 # ✓ Realistic for Nginx
  limits:
    cpu: 500m
    memory: 256Mi
```

### Verification
```bash
$ kubectl get pod -n troubleshoot -l app=web -o jsonpath='{.items[0].spec.containers[0].resources}'
{"limits":{"cpu":"500m","memory":"256Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}
```

Pods now request appropriate amounts.

**Lesson:** Know typical resource usage for your application:
- Nginx: 20–50 MB memory
- Python app: 100–200 MB memory
- Java JVM: 500 MB–1 GB memory

Too-high requests waste resources; too-low requests cause OOM kills. Test locally and adjust.

---

## Issue 4: Service Selector Mismatch

### Symptom
Service created but has no endpoints:
```bash
$ kubectl get endpoints web-svc -n troubleshoot
NAME      ENDPOINTS
web-svc   <none>
```

Traffic cannot route to pods because service doesn't recognize them.

### Diagnosis

**Step 1:** Check service selector
```bash
$ kubectl get svc web-svc -n troubleshoot -o jsonpath='{.spec.selector}'
{"app":"webapp"}
```

Service selector looks for `app: webapp`.

**Step 2:** Check pod labels
```bash
$ kubectl get pods -n troubleshoot -l app=web --show-labels
NAME                    READY   STATUS    RESTARTS   AGE   LABELS
web-6b8546c487-6fs8r    1/1     Running   0          3m    app=web,pod-template-hash=6b8546c487
web-6b8546c487-m2jhd    1/1     Running   0          3m    app=web,pod-template-hash=6b8546c487
```

Pods have label `app: web`, not `app: webapp`.

**Step 3:** Try to find pods with selector
```bash
$ kubectl get pods -n troubleshoot -l app=webapp
No resources found in troubleshoot namespace.
```

No pods match the service selector.

### Root Cause
Deployment creates pods with label `app: web`, but Service selector looks for `app: webapp`. Mismatch → no endpoints.

**Broken Code:**
```yaml
---
# Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  template:
    metadata:
      labels:
        app: web                  # Pod label is "web"

---
# Service
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: webapp                   # Service looks for "webapp" ← MISMATCH
```

### Fix
Changed Service selector to match pod labels:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-svc
spec:
  selector:
    app: web                      # ✓ Matches pod label
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

### Verification
After fix:
```bash
$ kubectl get endpoints web-svc -n troubleshoot
NAME      ENDPOINTS                             AGE
web-svc   10.244.167.141:80,10.244.191.138:80   43s

$ kubectl get svc web-svc -n troubleshoot
NAME      TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
web-svc   ClusterIP   10.96.127.128   <none>        80/TCP    43s
```

Service now has 2 endpoints (matching the 2 replicas).

**Lesson:** Service selectors are the most critical part of service discovery. Always verify:
```bash
# Do these match?
kubectl get pods --show-labels
kubectl get svc <name> -o jsonpath='{.spec.selector}'
```

---

## Issue 5: Service TargetPort Mismatch

### Symptom
Even if service had endpoints, traffic would not reach the container because targetPort doesn't match the actual port.

### Diagnosis

**Service definition (broken-app.yaml line 93):**
```yaml
ports:
  - protocol: TCP
    port: 80                      # Service listens on port 80
    targetPort: 8080              # But sends traffic to container port 8080
```

**Container definition (broken-app.yaml line 54):**
```yaml
containers:
  - name: nginx
    ports:
      - containerPort: 80         # Container listens on port 80
```

### Root Cause
Service targetPort (8080) doesn't match container port (80). kube-proxy would forward traffic to the non-existent port, causing connection refused.

### Fix
Changed targetPort to match container port:

```yaml
ports:
  - protocol: TCP
    port: 80
    targetPort: 80                # ✓ Matches containerPort
```

### Verification
```bash
$ kubectl get svc web-svc -n troubleshoot -o jsonpath='{.spec.ports[0]}'
{"name":"","port":80,"protocol":"TCP","targetPort":80}
```

**Lesson:** Service routing chain: Client → Service:port → Pod:targetPort → Container:port. All three must align or traffic fails silently.

---

## Issue 6: Missing GPU Node Toleration

### Symptom
ai-inference pod stuck in `Pending` indefinitely:
```bash
$ kubectl get pods -n troubleshoot -l app=ai-inference
NAME                           READY   STATUS    RESTARTS   AGE
ai-inference-6fdb9f84d7-88k5k   0/1     Pending   0          5m
```

Pod never schedules on the GPU node.

### Diagnosis

**Step 1:** Check pod scheduling constraints
```bash
$ kubectl describe pod ai-inference-6fdb9f84d7-88k5k -n troubleshoot | grep -A 5 "Node-Selectors"
Node-Selectors: node-type=gpu
Tolerations:
  node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
  node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
  # ❌ Missing: nvidia.com/gpu=true:NoSchedule
```

**Step 2:** Check GPU node taints
```bash
$ kubectl describe node elsa-worker4 | grep Taints
Taints: nvidia.com/gpu=true:NoSchedule
```

**Step 3:** Check GPU node labels
```bash
$ kubectl get node elsa-worker4 -L acme.io/node-type
NAME           STATUS   ROLES   AGE   VERSION   NODE-TYPE
elsa-worker4   Ready    <none>  3d    v1.35.0   gpu
```

**Step 4:** Check scheduler decision
```bash
$ kubectl get events -n troubleshoot | grep FailedScheduling
Warning  FailedScheduling  pod/ai-inference-6fdb9f84d7-88k5k  0/5 nodes are available: 2 node(s) had untolerated taint(s), 3 node(s) didn't match Pod's node affinity/selector.
```

### Root Cause
Two-part issue:

1. **Wrong label key:** Manifest uses `node-type: gpu` but correct label is `acme.io/node-type: gpu` (with namespace prefix)
2. **Missing toleration:** GPU node has taint `nvidia.com/gpu=true:NoSchedule` but pod has no matching toleration

The scheduler:
1. Finds nodeSelector matches GPU node (if label was correct)
2. Checks taints: finds `nvidia.com/gpu=true:NoSchedule`
3. Checks tolerations: finds none matching
4. **REJECTS** pod — cannot schedule

### Fix
Two changes:

1. **Fixed nodeSelector label to include namespace:**
```yaml
nodeSelector:
  acme.io/node-type: gpu          # ✓ Corrected with namespace prefix
```

2. **Added toleration for GPU taint:**
```yaml
tolerations:
  - key: nvidia.com/gpu
    operator: Equal
    value: "true"
    effect: NoSchedule             # ✓ Matches node taint
```

### Verification
After fix:
```bash
$ kubectl get pods -n troubleshoot -l app=ai-inference -o wide
NAME                           READY   STATUS    RESTARTS   AGE   IP               NODE           NOMINATED NODE   READINESS GATES
ai-inference-f765cc8d8-cqmp7   1/1     Running   0          2m    10.244.201.129   elsa-worker4   <none>           <none>

$ kubectl get node elsa-worker4 --show-labels | grep acme.io/node-type
elsa-worker4   Ready    <none>   3d   v1.35.0   acme.io/node-type=gpu
```

Pod now scheduled on GPU node as intended.

**Lesson:** Kubernetes taints & tolerations require exact matching:
- **NodeSelector constraint:** Pod can only run on nodes with matching labels
- **Taint constraint:** Pod CANNOT run on nodes with taints it doesn't tolerate
- Both must be satisfied. If pod specifies nodeSelector for a tainted node, it MUST have the toleration.

---

## Issue 7: Invalid Container Image Tag

### Symptom
Pod fails to start with `ErrImagePull` or `ImagePullBackOff`:
```bash
$ kubectl get pods -n troubleshoot
NAME                    READY   STATUS           RESTARTS   AGE
web-7dfd85c595-2gz2x    0/1     ErrImagePull     0          1m
```

### Diagnosis

**Step 1:** Check pod events
```bash
$ kubectl describe pod web-7dfd85c595-2gz2x -n troubleshoot | grep -A 5 "Events:"
Events:
  Type     Reason      Age    From     Message
  Normal   Scheduled   2m     ...      Successfully assigned
  Warning  Failed      1m     kubelet  Failed to pull image "nginx:1.25.99": rpc error
```

**Step 2:** Try pulling locally
```bash
$ docker pull nginx:1.25.99
Error response from daemon: manifest not found
```

Image tag `1.25.99` doesn't exist.

**Step 3:** Check valid tags
```bash
$ docker pull nginx:1.25-alpine
# Succeeds
```

### Root Cause
Typo in image tag. `nginx:1.25.99` is not a valid release. Correct tag should be `nginx:1.25` or `nginx:1.25-alpine` (slim, Alpine-based).

### Fix
Changed image tag to a valid, existing tag:

```yaml
image: nginx:1.25-alpine          # ✓ Valid Alpine variant
```

### Verification
```bash
$ kubectl get pod -n troubleshoot -l app=web -o jsonpath='{.items[0].spec.containers[0].image}'
nginx:1.25-alpine

$ docker pull nginx:1.25-alpine
# Succeeds
```

**Lesson:** Always validate image tags before deploying:
```bash
docker pull <registry>/<image>:<tag>  # Test locally
docker images | grep <image>          # Verify it pulled
```

Typos in image tags are silent failures—pods stay in `ErrImagePull` indefinitely.

---

## Issue 8: NetworkPolicy Blocks All Traffic

### Symptom
Pods running and healthy, but smoke-test job fails:
```bash
$ kubectl logs job/smoke-test -n troubleshoot
curl: (6) Could not resolve host: web-svc.troubleshoot.svc.cluster.local
```

Smoke-test pod cannot reach the web service or resolve DNS.

### Diagnosis

**Step 1:** Check NetworkPolicies
```bash
$ kubectl get networkpolicies -n troubleshoot
NAME           POD-SELECTOR   AGE
default-deny   <none>         3m
```

**Step 2:** Describe the policy
```bash
$ kubectl describe networkpolicy default-deny -n troubleshoot
Spec:
  PodSelector:     <none>
  Allowing ingress traffic: <none>      # DENY ALL ingress
  Allowing egress traffic:  <none>      # DENY ALL egress
  Policy Types: Ingress, Egress
```

Policy has no allow rules → everything denied.

**Step 3:** Try manual test
```bash
$ kubectl run -it --rm curl --image=curlimages/curl --restart=Never -- \
  curl http://web-svc.troubleshoot.svc.cluster.local
# Times out—no egress allowed
```

### Root Cause
NetworkPolicy `default-deny` intentionally blocks all traffic. This is a security pattern (deny by default, allow only necessary traffic), but without corresponding allow rules, no traffic flows.

The broken manifest only defined the deny policy without any allow rules:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
spec:
  podSelector: {}                 # Applies to ALL pods
  policyTypes:
    - Ingress
    - Egress
  # ❌ No ingress/egress allow rules
```

### Fix
Added 3 NetworkPolicies with least-privilege allow rules:

**1. allow-web-ingress** — Allow smoke-test pods to reach web pods
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-web-ingress
  namespace: troubleshoot
spec:
  podSelector:
    matchLabels:
      app: web
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: smoke-client
      ports:
        - protocol: TCP
          port: 80
```

**2. allow-dns-egress** — Allow all pods to query DNS
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: troubleshoot
spec:
  podSelector: {}                 # Applies to ALL pods
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector: {}   # DNS could be in any namespace
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

**3. allow-smoke-client** — Allow smoke-test pod to reach web and DNS
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-smoke-client
  namespace: troubleshoot
spec:
  podSelector:
    matchLabels:
      app: smoke-client
  policyTypes:
    - Egress
  egress:
    # Allow traffic to web pods
    - to:
        - podSelector:
            matchLabels:
              app: web
      ports:
        - protocol: TCP
          port: 80
    # Allow DNS queries
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### Verification
After fix:
```bash
$ kubectl logs job/smoke-test -n troubleshoot
<html><body><h1>TROUBLESHOOT-OK</h1></body></html>

$ bash troubleshoot/verify.sh
...
[7/7] In-cluster smoke test through the Service...
PASS
```

Smoke-test now succeeds.

**Lesson:** NetworkPolicy is a deny-by-default security pattern:
1. **Always define allow rules explicitly**, don't leave policies without them
2. **DNS is often forgotten** — without egress port 53, pods can't resolve hostnames
3. **Test policies** — apply and verify traffic flows as expected
4. **Document intent** — label policies with their purpose (allow-web-ingress, allow-dns)

---

## Summary of Fixes

| Issue | Component | Problem | Fix |
|-------|-----------|---------|-----|
| 1 | Deployment | ConfigMap name typo | `web-conf` → `web-config` |
| 2 | Deployment | Probe port mismatch | `8080` → `80` |
| 3 | Deployment | Memory request excessive | `16Gi` → `128Mi` |
| 4 | Service | Selector label mismatch | `app: webapp` → `app: web` |
| 5 | Service | TargetPort mismatch | `8080` → `80` |
| 6 | Deployment | GPU label & toleration | `node-type` → `acme.io/node-type` + added toleration |
| 7 | Deployment | Invalid image tag | `nginx:1.25.99` → `nginx:1.25-alpine` |
| 8 | NetworkPolicy | No allow rules | Added 3 policies for ingress/egress |

---

## Verification Checklist

✅ All issues fixed and verified:

- [x] ConfigMap mount error resolved
- [x] Pod health probes succeed
- [x] Memory requests realistic
- [x] Service has endpoints
- [x] Traffic routes to containers
- [x] GPU pod scheduled correctly
- [x] Image pulls successfully
- [x] Smoke-test job passes
- [x] `verify.sh` prints **PASS**

---

## Key Takeaways

### Common Mistakes to Avoid

1. **Typos in references** → Use `kubectl get <type>` to verify names before referencing
2. **Port number mismatches** → Match containerPort ↔ probe port ↔ service targetPort ↔ listen port
3. **Unrealistic resource requests** → Benchmark locally; start small, increase if needed
4. **Label/selector mismatches** → Always test: `kubectl get pods --show-labels` and check service selectors
5. **Missing taints/tolerations** → If pod targets specific nodes, check for taints and add tolerations
6. **Invalid image tags** → Pull locally first to verify tag exists
7. **NetworkPolicy without allow rules** → Test traffic flows; DNS requires port 53 egress
8. **Wrong label namespaces** → Some labels use namespace prefixes (acme.io/); check node labels carefully

### Diagnostic Commands

```bash
# Check pod status
kubectl describe pod <pod> -n <ns>
kubectl get events -n <ns> --sort-by='.lastTimestamp'

# Verify resources exist
kubectl get cm <name> -n <ns>
kubectl get svc <name> -n <ns> -o jsonpath='{.spec.selector}'

# Check pod labels
kubectl get pods --show-labels
kubectl get pods -l app=<label-value>

# Verify ports
kubectl get pods -o jsonpath='{.items[0].spec.containers[0].ports}'
kubectl get svc <name> -o jsonpath='{.spec.ports}'

# Check node labels & taints
kubectl get nodes -L <label-key>
kubectl describe node <node> | grep -A 5 Taints

# Test networking
kubectl exec -it <pod> -- sh
> curl http://service-name:port
> nslookup service-name
```

---

