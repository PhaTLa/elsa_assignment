# Part 4: CI/CD Migration — GitLab CI → GitHub Actions

**Date:** 2026-06-19 | **Status:** ✅ Complete  
**Legacy:** `ci/legacy.gitlab-ci.yml` | **New:** `.github/workflows/build-and-deploy.yml`

---

## Summary

Migrated from GitLab CI to GitHub Actions with fail-fast architecture, proper image tagging, and security scanning.

**Improvements:**
- ✅ Git SHA-only tagging (no `latest`)
- ✅ SCA/SAST scan before build (fail-fast)
- ✅ Trivy image scanning (HIGH/CRITICAL)
- ✅ Idempotent builds (skip if image exists)
- ✅ Secrets in GitHub (not code)

---

## Architecture

```
Scan Code (2 min)          Build Image (5 min)
    ↓                            ↓
SonarQube Cloud        Check: Image exists?
(quality gate)              ├─ Yes → Skip
    │                       └─ No → Build → Trivy → Push
    ├─ Fail → Stop
    └─ Pass → Build
```

---

## Key Changes

| Aspect | Legacy | New | Why |
|--------|--------|-----|-----|
| **Tag** | `:latest` | `:SHA8` | Traceability |
| **SAST** | `allow_failure: true` | Hard-fail | Actually enforced |
| **Scan order** | After build | Before build | Fail-fast |
| **Scanner** | Sonar (broken) | SonarQube Cloud | Works, free public |
| **Image scan** | None | Trivy | Supply chain security |
| **Secrets** | Hardcoded vars | GitHub Secrets | Security best practice |
| **Base OS** | Debian 12 (19 CVEs) | Alpine (0 CVEs) | Smaller, secure |

---

## What Was Done

### 1. GitHub Actions Workflow
**File:** `.github/workflows/build-and-deploy.yml`

Two jobs with dependency:
- **`scan-code`** (2-3 min): Runs SonarQube Cloud scan
  - Fails pipeline if quality gate violated
  - Runs on: push to main/develop, pull_request to main
  
- **`build-and-push`** (only if scan-code passes)
  - Checks if image already exists (skips if yes)
  - Builds with Alpine base
  - Scans with Trivy (HIGH/CRITICAL only)
  - Pushes to GHCR with git SHA tag

### 2. SonarQube Cloud Config
**File:** `sonar-project.properties`
```properties
sonar.projectKey=PhaTLa_elsa_assignment
sonar.organization=phatla
sonar.sources=app/src
sonar.python.version=3.9
```

Setup:
1. Go to https://sonarcloud.io
2. Create organization (key: your GitHub username)
3. Create project linked to your repo
4. Generate token → Add to GitHub Secrets as `SONAR_TOKEN`

### 3. Container Image Fixes
- **Base:** Debian slim → Alpine (19 CVEs → 0)
- **Werkzeug:** 3.0.1 → 3.0.3 (CVE-2024-34069)
- **Package manager:** `apt-get` → `apk add --no-cache`

---

## GitHub Setup Required (One-Time)

1. **Enable Actions permissions:**
   - Repo → Settings → Actions → General
   - Enable "Allow all actions"
   - Set "Workflow permissions" to "Read and write"

2. **Add `SONAR_TOKEN` secret:**
   - Repo → Settings → Secrets and variables → Actions
   - New secret: `SONAR_TOKEN`
   - Value: Token from SonarQube Cloud (Account → Security → Tokens)

3. **Test:**
   - Actions tab → Run workflow manually
   - Wait 3-5 min → Should pass all steps ✅

---

## Variables Reference

**Workflow env (public):**
```yaml
REGISTRY: ghcr.io
```

**Secrets (hidden):**
```yaml
SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}     # You add to GitHub
GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}   # Auto-provided
```

**SonarQube config (in sonar-project.properties):**
```properties
sonar.projectKey=PhaTLa_elsa_assignment   # Your project key
sonar.organization=phatla                 # Your org key
sonar.sources=app/src                     # Source dir
sonar.python.version=3.9                  # Language version
```

---

## Result

✅ **On every push to main/develop:**
1. Code scanned by SonarQube (2-3 min)
2. If quality gate passes, image built (5-10 min)
3. Image scanned by Trivy
4. If no HIGH/CRITICAL CVEs, pushed to GHCR: `ghcr.io/phatla/elsa_assignment:abc1234`
5. ArgoCD auto-deploys (Part 2 integration)

✅ **On re-run of same commit:**
- Image check detects existing SHA
- Build/scan skipped (30 sec, cost-efficient)

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| "Not authorized" from SonarQube | Check `SONAR_TOKEN` in GitHub Secrets; verify project key matches |
| "repository name must be lowercase" | Fixed in workflow (auto-converts mixed case) |
| Trivy finds HIGH/CRITICAL CVEs | Update base image or dependencies in requirements.txt |
| Workflow never runs | Check Actions permissions: Settings → Actions → General |

---

## Commits This Session

```
b11a29e Feature: skip build/scan if image SHA exists
5c5b702 Fix: update Werkzeug 3.0.1 → 3.0.3
0a2432e Fix: switch base image Debian → Alpine
1b3958b Fix: correct SonarQube project key
4615bd7 Refactor: move SCA/SAST before image build
2a91344 Fix: convert image name to lowercase
```

---

## See Also

- `.github/workflows/build-and-deploy.yml` — Full workflow
- `sonar-project.properties` — SonarQube config
- `Docs/PART-4-GITHUB-ACTIONS-SETUP.md` — Detailed setup
- `Docs/PART-4-TROUBLESHOOTING.md` — Common issues
- `ci/legacy.gitlab-ci.yml` — Old pipeline (reference only)
