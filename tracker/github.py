import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from urllib.parse import urlsplit

from . import store


def repo_name(value):
    repo = value.removesuffix("/")
    if repo.endswith(".git"):
        repo = repo[:-4]
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9-]*/[a-zA-Z0-9_.-]+", repo):
        raise ValueError("Enter a GitHub repository as owner/repo")
    if repo.split("/")[1] in (".", ".."):
        raise ValueError("Enter a GitHub repository as owner/repo")
    return repo.lower()


def normalize_repo(value):
    value = value.strip()
    if value.lower().startswith("https://github.com/"):
        value = value[len("https://github.com/"):]
    return repo_name(value)


def _auto_link_off_key(project):
    return f"github_autolink_off:{project}"


def set_repo(conn, project, value):
    if not conn.in_transaction:
        conn.execute("BEGIN IMMEDIATE")
    store.get_project(conn, project)
    repo = normalize_repo(value)
    existing = conn.execute("SELECT repo FROM github_projects WHERE project = ?", (project,)).fetchone()
    if existing and existing["repo"].casefold() == repo.casefold():
        return repo
    conn.execute("DELETE FROM settings WHERE key = ?", (_auto_link_off_key(project),))
    clear_pull_requests(conn, project)
    conn.execute(
        "INSERT INTO github_projects (project, repo) VALUES (?, ?) ON CONFLICT(project) "
        "DO UPDATE SET repo = excluded.repo, refreshed_at = NULL", (project, repo),
    )
    return repo


def clear_pull_requests(conn, project):
    conn.execute("DELETE FROM github_pr_routes WHERE project = ?", (project,))
    conn.execute("DELETE FROM github_prs WHERE project = ?", (project,))


def unlink(conn, project):
    conn.execute("BEGIN IMMEDIATE")
    store.get_project(conn, project)
    clear_pull_requests(conn, project)
    conn.execute("DELETE FROM github_projects WHERE project = ?", (project,))
    store.set_setting(conn, _auto_link_off_key(project), "1")


def set_pr_route(conn, project, number, remove=False):
    if type(number) is not int or not 0 < number <= 2147483647:
        raise ValueError("Enter a valid pull request number")
    conn.execute("BEGIN IMMEDIATE")
    link = conn.execute("SELECT repo FROM github_projects WHERE project = ?", (project,)).fetchone()
    if not link:
        raise ValueError("Connect a GitHub repository to this project first")
    repo = link["repo"]
    if remove:
        conn.execute("DELETE FROM github_pr_routes WHERE repo = ? AND number = ? AND project = ?",
                     (repo, number, project))
    else:
        existing = conn.execute("SELECT project FROM github_pr_routes WHERE repo = ? AND number = ?",
                                (repo, number)).fetchone()
        if existing and existing["project"] != project:
            raise ValueError(f"Pull request #{number} is routed to {existing['project']}. Remove that route first.")
        conn.execute("INSERT OR IGNORE INTO github_pr_routes VALUES (?, ?, ?)", (repo, number, project))
    return {"repo": repo, "number": number, "project": project}


def routes(conn):
    result = {}
    rows = conn.execute(
        "SELECT link.repo, link.project, route.number FROM github_projects AS link "
        "LEFT JOIN github_pr_routes AS route ON route.project = link.project "
        "AND route.repo = link.repo ORDER BY link.project, route.number"
    )
    for row in rows:
        project = row["project"]
        route = result.setdefault(row["repo"].lower(),
                                  {"project": project, "pull_requests": {}, "projects": []})
        if project not in route["projects"]:
            route["projects"].append(project)
        if row["number"] is not None:
            route["pull_requests"][row["number"]] = project
        if len(route["projects"]) > 1:
            route["project"] = None
    return result


def worktree_repos(folder):
    # Read local config only. This never contacts a Git remote or loads Git config includes.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        result = subprocess.run(
            ["/usr/bin/git", "-C", folder, "config", "--local", "--no-includes", "--null", "--get-regexp",
             r"^remote\.(origin|upstream)\.url$"],
            capture_output=True, timeout=2, env=env,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ()
    if result.returncode:
        return ()
    found = {}
    for record in result.stdout.decode("utf-8", errors="replace").split("\0"):
        key, _, url = record.partition("\n")
        for prefix in ("https://github.com/", "ssh://git@github.com/", "git@github.com:"):
            if url.lower().startswith(prefix):
                try:
                    found.setdefault(key, repo_name(url[len(prefix):]))
                except ValueError:
                    pass
                break
    return tuple(found[key] for key in ("remote.origin.url", "remote.upstream.url") if key in found)


def agent_context(routes, by_branch, local_repos, project, branch):
    if local_repos:
        repo = next((name for name in local_repos if name in routes), None)
    elif project:
        repo = next((name for name, route in routes.items()
                     if project in route["projects"]), None)
    else:
        repo = None
    matches = by_branch.get((repo, branch), ())
    return repo, matches[0] if len(matches) == 1 else None


def gh_path():
    for candidate in (shutil.which("gh"), "/opt/homebrew/bin/gh", "/usr/local/bin/gh"):
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise ValueError("Install GitHub CLI and sign in with gh auth login")


def auth_status():
    try:
        command = gh_path()
    except ValueError:
        return {"status": "missing"}
    try:
        result = subprocess.run(
            [command, "auth", "status", "--hostname", "github.com"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15,
            env=dict(os.environ, GH_PROMPT_DISABLED="1"),
        )
    except (subprocess.TimeoutExpired, OSError):
        return {"status": "unavailable"}
    if result.returncode:
        return {"status": "unverified"}
    try:
        user = subprocess.run([command, "api", "user", "--jq", ".login"], capture_output=True, text=True, timeout=15,
                              env=dict(os.environ, GH_PROMPT_DISABLED="1"))
        login = user.stdout.strip() if user.returncode == 0 else None
    except (subprocess.TimeoutExpired, OSError):
        login = None
    return {"status": "connected", "login": login or None}


def head_commit(folder):
    """The checked-out commit of a local folder, read without contacting any remote."""
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    try:
        result = subprocess.run(["/usr/bin/git", "-C", folder, "rev-parse", "--verify", "--quiet", "HEAD"],
                                capture_output=True, text=True, timeout=2, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None
    commit = result.stdout.strip()
    return commit if result.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", commit) else None


def fetch_prs(repo):
    command = [gh_path(), "pr", "list", "--repo", "github.com/" + repo, "--state", "all",
               "--limit", "150", "--json", "number,headRefName,title,state,url,isCrossRepository"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=35, env=dict(os.environ, GH_PROMPT_DISABLED="1"))
    except subprocess.TimeoutExpired:
        raise ValueError("GitHub took too long to respond. Try again.") from None
    if result.returncode:
        message = result.stderr.strip().splitlines()
        detail = message[0] if message else "Check the repository name and your GitHub CLI session."
        raise ValueError(f"GitHub could not load pull requests. {detail}")
    try:
        return json.loads(result.stdout)
    except ValueError:
        raise ValueError("GitHub CLI returned an unreadable result") from None


def pull_request_rows(project, repo):
    entries = []
    for item in fetch_prs(repo):
        url = urlsplit(item["url"])
        number = item["number"]
        if item["isCrossRepository"] or url.scheme != "https" or url.netloc != "github.com":
            continue
        if url.path.casefold() != f"/{repo}/pull/{number}".casefold():
            continue
        entries.append((project, number, item["headRefName"], item["title"], item["state"], item["url"]))
    return entries


def refresh(conn, project, repository=None):
    store.get_project(conn, project)
    previous = conn.execute("SELECT repo FROM github_projects WHERE project = ?", (project,)).fetchone()
    if repository is None and previous is None:
        raise ValueError("Set a GitHub repository for this project first")
    repo = normalize_repo(repository) if repository is not None else previous["repo"]
    entries = pull_request_rows(project, repo)
    conn.execute("BEGIN IMMEDIATE")
    current = conn.execute("SELECT repo FROM github_projects WHERE project = ?", (project,)).fetchone()
    if current != previous:
        raise ValueError("The repository changed while syncing. Reload it and try again.")
    if repository is not None:
        set_repo(conn, project, repo)
    conn.execute("DELETE FROM github_prs WHERE project = ?", (project,))
    conn.executemany("INSERT INTO github_prs VALUES (?, ?, ?, ?, ?, ?)", entries)
    conn.execute("UPDATE github_projects SET refreshed_at = ? WHERE project = ?", (int(time.time() * 1000), project))
    return {"repo": repo, "pull_requests": len(entries)}


def links_by_branch(conn):
    by_branch = {}
    sources = {}
    for row in conn.execute("SELECT repo, project FROM github_projects WHERE refreshed_at IS NOT NULL "
                            "ORDER BY refreshed_at DESC, project"):
        sources.setdefault(row["repo"].lower(), row["project"])
    for repo, project in sources.items():
        for row in conn.execute("SELECT number, branch, title, state, url FROM github_prs WHERE project = ?",
                                (project,)):
            by_branch.setdefault((repo, row["branch"]), []).append(dict(row))
    return by_branch
