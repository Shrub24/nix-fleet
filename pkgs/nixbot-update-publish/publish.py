"""Open or update the update pull request, then request its auto-merge.

Runs after the effect has pushed its automation branch. The token is the one
nixbot supplies for the effect's `GitToken` reference, passed in the
environment so it stays out of the process arguments.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

AUTO_MERGE = (
    "mutation($id:ID!){enablePullRequestAutoMerge(input:{"
    "pullRequestId:$id,mergeMethod:SQUASH}){clientMutationId}}"
)
PULL_ID = (
    "query($owner:String!,$name:String!,$number:Int!){"
    "repository(owner:$owner,name:$name){pullRequest(number:$number){id}}}"
)


class Failed(Exception):
    """The effect fails with this message."""


def api_base(remote: str) -> str:
    host = urllib.parse.urlsplit(remote).hostname or "github.com"
    return (
        "https://api.github.com" if host == "github.com" else f"https://{host}/api/v3"
    )


def send(
    url: str, token: str, method: str = "GET", payload: dict | None = None
) -> dict:
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("Accept", "application/vnd.github+json")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        raise Failed(
            f"{method} {url}: {error.code} {error.read().decode().strip()}"
        ) from error
    return json.loads(body) if body else {}


def open_pull_request(
    api: str, repo: str, head: str, base: str, title: str, body: str, token: str
) -> tuple[dict, bool]:
    query = urllib.parse.urlencode({"head": head, "state": "open", "base": base})
    existing = send(f"{api}/repos/{repo}/pulls?{query}", token)
    if existing:
        number = existing[0]["number"]
        return (
            send(
                f"{api}/repos/{repo}/pulls/{number}",
                token,
                "PATCH",
                {"title": title, "body": body},
            ),
            False,
        )
    return (
        send(
            f"{api}/repos/{repo}/pulls",
            token,
            "POST",
            {"title": title, "head": head, "base": base, "body": body},
        ),
        True,
    )


def request_auto_merge(api: str, repo: str, pull: dict, token: str) -> None:
    """Enable auto-merge, or merge now where the repository does not offer it.

    Auto-merge is a repository setting. Where it is off, GitHub refuses the
    mutation, so the pull request is merged directly once it is mergeable and
    the refusal is reported if it is not.
    """
    owner, name = repo.split("/", 1)
    node = send(
        f"{api}/graphql",
        token,
        "POST",
        {
            "query": PULL_ID,
            "variables": {"owner": owner, "name": name, "number": pull["number"]},
        },
    )
    if "errors" in node:
        raise Failed(f"resolving pull request #{pull['number']}: {node['errors']}")
    enabled = send(
        f"{api}/graphql",
        token,
        "POST",
        {
            "query": AUTO_MERGE,
            "variables": {"id": node["data"]["repository"]["pullRequest"]["id"]},
        },
    )
    if "errors" not in enabled:
        print(f"Enabled auto-merge (squash) on #{pull['number']}")
        return
    reason = enabled["errors"]
    if pull.get("mergeable") is False:
        raise Failed(f"enabling auto-merge on #{pull['number']}: {reason}")
    try:
        send(
            f"{api}/repos/{repo}/pulls/{pull['number']}/merge",
            token,
            "PUT",
            {"merge_method": "squash"},
        )
    except Failed as error:
        raise Failed(
            f"enabling auto-merge on #{pull['number']}: {reason}: {error}"
        ) from error
    print(f"Auto-merge unavailable ({reason}); merged #{pull['number']} directly")


def main(argv: list[str]) -> int:
    auto_merge = "--auto-merge" in argv
    argv = [argument for argument in argv if argument != "--auto-merge"]
    if len(argv) != 7:
        print(
            "usage: publish [--auto-merge] REMOTE REPO HEAD BASE TITLE BODY_FILE",
            file=sys.stderr,
        )
        return 2
    remote, repo, head, base, title, body_file = argv[1:]
    try:
        token = os.environ["TOKEN"]
        with open(body_file, encoding="utf-8") as handle:
            body = handle.read()
        api = api_base(remote)
        pull, created = open_pull_request(
            api, repo, f"{repo.split('/', 1)[0]}:{head}", base, title, body, token
        )
        print(f"{'Opened' if created else 'Updated'} pull request #{pull['number']}")
        if auto_merge:
            request_auto_merge(api, repo, pull, token)
        else:
            print(f"Left #{pull['number']} open for review")
    except (Failed, KeyError, OSError) as error:
        print(f"package-updates: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
