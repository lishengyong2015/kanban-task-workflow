# Publishing a Hermes Skill to GitHub

When `git push` times out or is unavailable, use the GitHub API to create a repo and upload files directly.

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
        cmd = f'''curl -s -X PUT \\
          -H "Authorization: token {token}" \\
          -H "Accept: application/vnd.github.v3+json" \\
          "https://api.github.com/repos/{repo}/contents/{rel}" \\
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
- **Git timout in WSL**: HTTPS git push from WSL often stalls. The API approach is more reliable
