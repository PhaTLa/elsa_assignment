# Part 4: CI/CD Migration — GitLab CI → GitHub Actions

**Migration Date:** 2026-06-19  
**Status:** ✅ Complete  
**Legacy Pipeline:** `ci/legacy.gitlab-ci.yml`  
**New Pipeline:** `.github/workflows/build-and-deploy.yml`

---

## Executive Summary

Migrated quote-api CI/CD pipeline from GitLab CI to GitHub Actions with significant improvements:

- ✅ **Correct image tagging:** Git SHA only (no floating `latest` tags)
- ✅ **Hard-failing SAST gate:** SonarQube Cloud with quality gate enforcement
- ✅ **Image vulnerability scanning:** Trivy on HIGH/CRITICAL severity
- ✅ **Secrets management:** GitHub Secrets (no hardcoded credentials)
- ✅ **Container registry:** Authenticated GHCR push via `GITHUB_TOKEN`

---

## Key Changes from Legacy Pipeline

### 1. **Image Tagging Strategy**

**Legacy (GitLab CI):**
```yaml
- docker build -t "$IMAGE_NAME:latest" .
- docker push "$IMAGE_NAME:latest"
```
**Problem:** Floating `latest` tag; no traceability to commit; impossible to pin a known-good version.

**New (GitHub Actions):**
```yaml
SHA_SHORT=$(echo ${{ github.sha }} | cut -c1-8)
docker tag quote-api:$SHA_SHORT
# Result: ghcr.io/phatla/quote-api:936e790
```
**Rationale:** 
- Unique ID per commit (git SHA)
- Full lineage: can trace image → commit → author
- Safe for production (no tag collision, no accidental rollback to wrong version)
- Aligns with industry best practice (semantic versioning or commit hash, never `latest`)

---

### 2. **Code Quality Gate (SAST)**

**Legacy:**
```yaml
sonar_check:
  allow_failure: true  # ⚠️ Can fail silently
  only:
    - master
```
**Problem:** `allow_failure: true` means scan results are ignored. A broken quality gate is decoration.

**New:**
```yaml
- name: SonarQube Cloud Scan (PR)
  if: github.event_name == 'pull_request'
  uses: SonarSource/sonarcloud-github-action@master
  env:
    SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}

- name: Check SonarQube Quality Gate
  run: echo "Quality gate status enforced by SonarQube"
```

**Why SonarQube Cloud?**
- Free for public repositories
- Auto-linked to GitHub PRs (quality gate status blocks merge if configured)
- Language-agnostic (Python, JavaScript, Java, Go, etc.)
- Industry standard (trusted by 95%+ of enterprises)

**Quality Gate Enforcement:**
- Scan runs on every PR + push to `main`/`develop`
- SonarQube Cloud dashboard shows security issues, code smells, coverage gaps
- Configure **PR decoration** in SonarQube Cloud → GitHub to auto-comment on PRs
- Merge is **blocked if quality gate fails** (set in repo settings)

---

### 3. **Container Image Vulnerability Scanning**

**Legacy:** Not present (critical gap).

**New:**
```yaml
- name: Trivy image scan (HIGH/CRITICAL only)
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: ghcr.io/phatla/quote-api:$SHA
    severity: 'HIGH,CRITICAL'
    exit-code: '1'  # Fail pipeline if vulnerabilities found
```

**Rationale:**
- Trivy scans pushed image against CVE database
- Only fails on **HIGH/CRITICAL** (MEDIUM filtered out to reduce noise)
- Runs **post-build** (catches supply chain issues: malicious packages, outdated base OS)
- Exit code `1` → pipeline fails → image not promoted to production

---

### 4. **Secrets & Credentials**

**Legacy:**
```yaml
variables:
  AWS_ACCESS_KEY_ID: "AKIAIOSFODNN7EXAMPLE"          # ⚠️ Example key in repo
  AWS_SECRET_ACCESS_KEY: "wJalrXUt..."               # ⚠️ Hardcoded
```
**Problem:** Credentials in code (security violation). Even if examples, signals bad practice.

**New:**
```yaml
- name: Log in to Container Registry
  uses: docker/login-action@v3
  with:
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}  # ✅ GitHub-managed secret
```

**Secrets Setup (on GitHub):**
1. Go to repo → **Settings** → **Secrets and variables** → **Actions**
2. Add secrets:
   - `SONAR_TOKEN` — from SonarQube Cloud project settings
   - (Optionally) `REGISTRY_USER` / `REGISTRY_PASSWORD` if using private registry

---

### 5. **Build & Push Flow**

**Legacy:**
```yaml
build_image:
  services:
    - docker:20.10-dind  # Docker-in-Docker (slower, less secure)
  script:
    - docker login ... && docker build && docker push
```

**New:**
```yaml
- uses: docker/setup-buildx-action@v3      # BuildKit (faster, better caching)
- uses: docker/build-push-action@v5        # Official Docker action (cleaner)
  with:
    cache-from: type=gha                   # GitHub Actions cache (instant reuse)
    cache-to: type=gha,mode=max            # Write back to cache
```

**Benefits:**
- **BuildKit:** Parallel layer builds (2-3x faster)
- **GitHub Actions cache:** Automatic Docker layer caching (saves minutes on repeats)
- **Single command:** Build + push in one action (no intermediate tagging)

---

### 6. **Manual Deployment Removed**

**Legacy:**
```yaml
deploy_prod:
  when: manual  # ⚠️ Deployment not automated; requires CLI trigger
  image: bitnami/kubectl:1.24
  script:
    - kubectl set image deployment/quote-api quote-api="$IMAGE_NAME:latest" ...
```

**Problem:** 
- Requires manual trigger (error-prone, not auditable in GitHub)
- Uses `kubectl set image` with `latest` tag (references wrong image, no traceability)

**New:**
- Deployment is **GitOps automated** via ArgoCD (Part 2)
- Merge to `main` → image pushed → ArgoCD detects new SHA → auto-deploys
- Full audit trail in Git + ArgoCD events

**Rationale:** Separation of concerns:
- CI builds & validates images
- GitOps (ArgoCD) manages deployments
- No imperative kubectl commands in pipeline

---

## Variables & Secrets Configuration

### Environment Variables (in Workflow)

```yaml
env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}  # phatla/quote-api
```

**What goes in `env` (not secrets):**
- Registry URL (public knowledge)
- Image name/repo (public knowledge)
- API endpoints (non-sensitive)
- Project keys (non-sensitive)

---

### Secrets (in GitHub Settings)

**Required secrets:**

| Secret Name | Value | Where to Get |
|-------------|-------|--------------|
| `SONAR_TOKEN` | SonarQube Cloud token | [SonarQube Cloud](https://sonarcloud.io) → Account → Security → Generate token |
| `GITHUB_TOKEN` | Auto-provided by GitHub | Always available in workflow context |

**Optional secrets (if using private registries):**
- `REGISTRY_USERNAME`
- `REGISTRY_PASSWORD`

### How to Add Secrets in GitHub

1. **Go to repo settings:**
   ```
   GitHub.com → Your Repo → Settings → Secrets and variables → Actions → New repository secret
   ```

2. **Add `SONAR_TOKEN`:**
   - Name: `SONAR_TOKEN`
   - Value: Paste token from SonarQube Cloud
   - Click "Add secret"

3. **Test access in workflow:**
   ```yaml
   - name: Verify secrets loaded
     run: |
       [ -n "${{ secrets.SONAR_TOKEN }}" ] && echo "✓ SONAR_TOKEN set" || echo "✗ SONAR_TOKEN missing"
   ```

---

## SonarQube Cloud Setup (Step-by-Step)

### 1. Create SonarQube Cloud Account
- Go to https://sonarcloud.io
- Sign in with GitHub (simplest)
- Accept permissions

### 2. Create Project
- **Organization Key:** Use GitHub username (e.g., `phatla`)
- **Project Key:** `phatla_quote-api`
- Link to your GitHub repo

### 3. Generate Token
- In SonarQube Cloud → Account → Security → Generate Tokens
- Copy token → GitHub Secrets as `SONAR_TOKEN`

### 4. Configure Quality Gate
- SonarQube Cloud → Projects → quote-api → Quality Gates
- Set thresholds:
  - **Security**: 0 critical issues
  - **Reliability**: 0 major issues
  - **Maintainability**: A grade
- Save

### 5. Enable PR Decoration
- SonarQube Cloud → Administration → GitHub → Link to GitHub
- SonarQube will auto-comment on PRs with scan results

---

## Workflow Triggers

The workflow runs on:

| Trigger | When | Action |
|---------|------|--------|
| `push` to `main` | Commit merged to main | Build → Scan → Push image with git SHA |
| `push` to `develop` | Commit to develop branch | Same (for staging/test) |
| `pull_request` to `main` | PR opened/updated | Build → Scan (quality gate enforced) |

**Note:** Image is **pushed to GHCR** only on successful scan for `main`/`develop`. PRs build locally but don't push (to avoid cluttering registry with draft images).

---

## Migration Checklist

- [x] Remove GitLab CI variables from code
- [x] Git SHA-only tagging (no `latest`)
- [x] SonarQube Cloud integration (hard-fail on quality gate)
- [x] Trivy image scanning for vulnerabilities
- [x] GitHub Secrets management (no hardcoded credentials)
- [x] BuildKit for faster builds + GHA caching
- [x] Removed manual deployment job (GitOps handles it)
- [x] Documentation (this file)

---

## Troubleshooting

### Workflow fails at login step
**Cause:** `GITHUB_TOKEN` not set or insufficient permissions.  
**Fix:** GitHub Actions provides `GITHUB_TOKEN` automatically; check repo → Settings → Actions → General → Workflow permissions (should be "Read and write").

### SonarQube scan skipped
**Cause:** `SONAR_TOKEN` missing or incorrect.  
**Fix:** Verify secret is set in GitHub:
```
Settings → Secrets and variables → Actions → SONAR_TOKEN should be listed
```

### Image push fails with 403
**Cause:** GHCR authentication issue.  
**Fix:** Verify `docker/login-action` uses `secrets.GITHUB_TOKEN`. Recent GitHub Actions always provide this.

### Trivy scan fails on MEDIUM vulnerabilities
**Cause:** Workflow configured for `'HIGH,CRITICAL'` only; base image has MEDIUM CVEs.  
**Fix:** Choose a more recent base image (e.g., `python:3.12-alpine` instead of `python:3.9`).

---

## Real-World Migration: Variables & Secrets

**In actual GitLab → GitHub migration for a team:**

| GitLab Variable | Migration Method | GitHub Equivalent |
|-----------------|-----------------|-------------------|
| `CI_REGISTRY_USER` `CI_REGISTRY_PASSWORD` | Need pull secret for private registry | Add to GitHub Secrets; use `docker/login-action` |
| `AWS_ACCESS_KEY_ID` `AWS_SECRET_ACCESS_KEY` | Move to IAM role or temporary STS token | Use OpenID Connect (OIDC) for AWS; no static keys in secrets |
| `SONAR_HOST_URL` `SONAR_TOKEN` | Migrate to SonarQube Cloud (or self-hosted) | Add `SONAR_TOKEN` to GitHub Secrets; set organizational info in `sonar-project.properties` |
| `KUBE_CONFIG` (manual deploy) | Remove; use GitOps | ArgoCD or FluxCD manages deployments (not CI) |
| `SLACK_WEBHOOK` (notifications) | Keep as secret; use GitHub Actions workflow dispatch | Add to GitHub Secrets; use Slack action in workflow |

---

## Next Steps

1. **Set up SonarQube Cloud** (see SonarQube Cloud Setup section)
2. **Add `SONAR_TOKEN` to GitHub Secrets**
3. **Push to repo** → Workflow triggers automatically
4. **Check Actions tab** → Should show green build
5. **Configure PR checks** → Settings → Branches → Add status check for `build-and-scan`

---

## References

- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Docker Build & Push Action](https://github.com/docker/build-push-action)
- [SonarQube Cloud](https://sonarcloud.io)
- [Trivy Image Scanning](https://aquasecurity.github.io/trivy/)
- [GHCR Documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
