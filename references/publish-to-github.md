# Publishing a Hermes Skill to GitHub

When `git push` times out or is unavailable, use the GitHub API to create a repo and upload files directly.

## Pre-sync Verification: Diff Local vs Published

Before publishing changes, verify that local modifications are all intentional by diffing against the live GitHub version:

### Step 1 — Fetch GitHub version

```bash
curl -s "https://raw.githubusercontent.com/<owner>/<repo>/main/SKILL.md" > /tmp/github_skill.md
curl -s "https://raw.githubusercontent.com/<owner>/<repo>/main/references/<file>.md" > /tmp/github_ref.md
```

### Step 2 — Diff local vs GitHub

```bash
diff /tmp/github_skill.md /path/to/local/SKILL.md
```

### Step 3 — Verify each diff line

Check against a known change list. For each diff hunk, confirm:
- Is it a version bump or feature change you intentionally made?
- Is it a path normalization (`~` → `/home/user/`)?
- Is it an expected backward-compat addition?
- **Any unexpected diff is a red flag** — investigate before publishing.

### Step 4 — Check reference files too

If local reference files (`references/*`) were added or modified, check whether they exist on GitHub (some are local-only sensitive files that should NOT be published). The `sync-kanban-skill` script auto-excludes the local sensitive versions, but manual verification is safer.

---

## Workflow

### 1. Create Repo via API

```bash
curl -s -X POST \
  -H "Authorization: token <your-token>" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/user/repos \
  -d '{
    "name":"<repo-name>",
    "description":"<one-line description>",
    "private":false,
    "has_issues":true,
    "has_projects":false,
    "has_wiki":false
  }'
```

### 2. Upload Files via API (when git push fails)

If `git push` times out (common in WSL with HTTPS), upload each file individually:

```python
import base64, os
from hermes_tools import terminal

token = "<github-token>"
repo = "<owner>/<repo-name>"
branch = "main"
base = "/tmp/<skill-dir>"

# Walk and upload
for root, dirs, fnames in os.walk(base):
    if ".git" in root:
        continue
    for f in fnames:
        path = os.path.join(root, f)
        rel = os.path.relpath(path, base)
        with open(path, "rb") as fh:
            content = fh.read()
        encoded = base64.b64encode(content).decode()
        cmd = f'''curl -s -X PUT \\\
          -H "Authorization: token {token}" \\\
          -H "Accept: application/vnd.github.v3+json" \\\
          "https://api.github.com/repos/{repo}/contents/{rel}" \\\
          -d '{{
            "message": "Add {rel}",
            "content": "{encoded}",
            "branch": "{branch}"
          }}' '''
        result = terminal(cmd, timeout=30)
```

### 3. Verify

```bash
curl -s -H "Authorization: token <token>" \
  "https://api.github.com/repos/<owner>/<repo>/contents/"
```

### 4. Git Push Alternative (with token in URL)

If HTTPS push works but is slow, increase timeout or use token in remote URL:

```bash
git remote add origin https://<username>:<token>@github.com/<owner>/<repo>.git
git branch -m master main
git push -u origin main
```

## Pitfalls

- **Token scope**: needs `repo` (full control) for private repos, `public_repo` for public
- **File already exists**: PUT /contents/ will reject if file exists without a `sha`. Delete first, or use a different branch
- **Binary files**: base64 encode. The API content field expects base64
- **Rate limits**: 5000 req/hr authenticated. One file per request, not a problem for small skills
- **Git timeout in WSL**: HTTPS git push from WSL often stalls. The API approach is more reliable
- **Sensitive files in references/**: `architecture-decisions.md` contains private contact info and local paths accessible ONLY to this Hermes instance. Do NOT publish it to GitHub. The `sync-kanban-skill` script handles this automatically (it uses a separate public-only repo), but manual git push will expose sensitive data.
