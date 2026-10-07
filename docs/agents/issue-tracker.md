# Issue tracker: Gitea

Issues live in the development repository on Gitea. An agent works them through the Gitea API. This document is the contract for each skill that creates, reads or changes an issue.

## Where issues live

| Place | Role |
| --- | --- |
| The development repository on Gitea | The only issue tracker. It is the `origin` remote of a development checkout. |
| The shared GitHub repository | Holds the `portable` branch and its tags. It has no issues. |

A clone of the shared repository has `origin` set to GitHub. Such a clone has no issue tracker. An agent in such a clone reports that. It does not open an issue on GitHub.

Rules:

- Do not open an issue on GitHub.
- No `gh issue`, `gh pr`, `gh api`, `gh repo` or `glab` command applies to this repository.
- Do not write a local ticket file. `.local/` is for worktrees and host values, not for tickets.
- When a skill says "publish to the issue tracker", create a Gitea issue with the operations below.

## Authentication

The token is in the environment variable `GITEA_TOKEN`. Send it in the header `Authorization: token $GITEA_TOKEN`.

- Do not print the token. Do not write it into a file, an issue or a commit message.
- If `GITEA_TOKEN` is not set, stop and report it. Do not look for a token in another place.
- `GET /user` gives the account of the token. Its `login` is the account for a claim.

In a development checkout, read the server and the repository from the remote:

```sh
git remote get-url origin
```

The URL has the form `<server>/{owner}/{repo}.git`. Set these shell variables for the examples of this document:

```sh
OWNER="<owner>"
REPO="<repo>"
API="<server>/api/v1/repos/$OWNER/$REPO"
```

Each path below is relative to `/api/v1` of that server. `{index}` is the number of an issue.

## Generic operations

| Operation | Method and path | Body |
| --- | --- | --- |
| Create an issue | `POST /repos/{owner}/{repo}/issues` | `title`, `body`, `labels` (label ids) |
| Read an issue | `GET /repos/{owner}/{repo}/issues/{index}` | none |
| Read its comments | `GET /repos/{owner}/{repo}/issues/{index}/comments` | none |
| List issues | `GET /repos/{owner}/{repo}/issues` | none; query `state`, `type`, `labels`, `page`, `limit` |
| Comment | `POST /repos/{owner}/{repo}/issues/{index}/comments` | `body` |
| List the labels of the repository | `GET /repos/{owner}/{repo}/labels` | none |
| Create a label | `POST /repos/{owner}/{repo}/labels` | `name`, `color`, `description` |
| Add labels | `POST /repos/{owner}/{repo}/issues/{index}/labels` | `labels` (label ids or label names) |
| Remove a label | `DELETE /repos/{owner}/{repo}/issues/{index}/labels/{id}` | none; `{id}` is the label id |
| Close | `PATCH /repos/{owner}/{repo}/issues/{index}` | `state` with the value `closed` |

Create an issue. The `labels` field takes label ids, not names:

```sh
curl -fsS -X POST -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d '{"title": "<title>", "body": "<body>", "labels": [<label-id>]}' "$API/issues"
```

Read an issue with its comments. A read of an issue is complete only with both requests:

```sh
curl -fsS -H "Authorization: token $GITEA_TOKEN" "$API/issues/$INDEX"
curl -fsS -H "Authorization: token $GITEA_TOKEN" "$API/issues/$INDEX/comments"
```

List the open issues, then the open issues with one label. `type=issues` leaves pull requests out. Read each page until a page is empty:

```sh
curl -fsS -H "Authorization: token $GITEA_TOKEN" "$API/issues?state=open&type=issues&limit=50&page=1"
curl -fsS -H "Authorization: token $GITEA_TOKEN" "$API/issues?state=open&type=issues&labels=needs-approval&limit=50&page=1"
```

The `labels` parameter takes label names, separated by commas. With more than one name, this Gitea version returns the issues that carry all of the names. A name that does not exist is ignored, so the result then holds every open issue. Thus confirm that each name exists, and check the `labels` field of each result on the client.

Comment:

```sh
curl -fsS -X POST -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d '{"body": "<text>"}' "$API/issues/$INDEX/comments"
```

Create a label. Only the label `wayfinder:parent:<map>` is created this way (section [Labels](#labels)):

```sh
curl -fsS -X POST -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d '{"name": "wayfinder:parent:<map>", "color": "#<hex>", "description": "<text>"}' "$API/labels"
```

The `color` value is any six-digit hex colour with `#`. The colour has no meaning.

Find a label id, add a label, remove a label:

```sh
curl -fsS -H "Authorization: token $GITEA_TOKEN" "$API/labels?limit=50&page=1"
curl -fsS -X POST -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d '{"labels": ["needs-approval"]}' "$API/issues/$INDEX/labels"
curl -fsS -X DELETE -H "Authorization: token $GITEA_TOKEN" "$API/issues/$INDEX/labels/$LABEL_ID"
```

Close:

```sh
curl -fsS -X PATCH -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d '{"state": "closed"}' "$API/issues/$INDEX"
```

Build a JSON body with a JSON tool when the text has quotes or line breaks. Do not build it by hand in the shell.

## Labels

This table is the complete list of labels that a skill can apply. Do not apply a label that is not in the table. Do not create a label outside the table without an approval.

| Label | Kind | Meaning |
| --- | --- | --- |
| `wayfinder:map` | map | The issue is a wayfinding map. |
| `wayfinder:parent:<map>` | child | The issue is a child of the map with the number `<map>`. A spec issue with tickets uses the same label with its own number. |
| `wayfinder:research` | ticket type | A research ticket. |
| `wayfinder:prototype` | ticket type | A prototype ticket. |
| `wayfinder:grilling` | ticket type | A grilling ticket. |
| `needs-approval` | triage | An approval comment is needed before a worker starts. |
| `ready-for-agent` | triage | An agent can take the issue. On a spec issue it means that the spec is ready for ticket creation, not for a worker. |

Rules:

- An implementation ticket is a child with no type label.
- `needs-approval` wins over `ready-for-agent`. An agent does not claim and does not start an issue that carries `needs-approval`, also when it carries `ready-for-agent`. Such an issue is not in the frontier.
- The skill that creates tickets from a spec removes `ready-for-agent` from the spec after it publishes the tickets.
- A skill creates the label `wayfinder:parent:<map>` itself when it charts a map or publishes a spec with tickets. It creates no other label.
- The repository holds other labels from earlier work (`tracking`, `worker`, `review`, `research`, `phase-*`). A skill does not apply them.

## Wayfinding operations

### Map and children

- The map is one issue with the label `wayfinder:map`.
- Gitea has no sub-issues. A child ticket carries the label `wayfinder:parent:<map>`, where `<map>` is the number of the map.
- For a new map, create the label `wayfinder:parent:<map>` first. Then publish the children.
- A scratch run deletes each label that it created, with `DELETE /repos/{owner}/{repo}/labels/{id}`.
- A child carries one ticket-type label when it has a type: `wayfinder:research`, `wayfinder:prototype` or `wayfinder:grilling`.
- Each map and each ticket has a stable title. Refer to an issue with a named link, not with a bare number.
- A named link has the issue title as the link text and the `html_url` field of the issue as the target.

List the open children of a map. First read the labels of the repository and confirm that `wayfinder:parent:<map>` exists. If it does not exist, stop and report it. A query with a label name that does not exist returns every open issue.

```sh
curl -fsS -H "Authorization: token $GITEA_TOKEN" "$API/labels?limit=50&page=1"
curl -fsS -H "Authorization: token $GITEA_TOKEN" "$API/issues?state=open&type=issues&labels=wayfinder:parent:$MAP&limit=50&page=1"
```

Check the `labels` field of each result. Drop each issue that does not carry `wayfinder:parent:<map>`.

### Map body

The map body holds no open-task checklist and no resolution detail. Under the heading "Decisions so far" it holds one line for each resolved ticket. The line is a named link to the ticket and a gist of one line. The detail stays in the resolution comment of the ticket.

Change the map body with `PATCH /repos/{owner}/{repo}/issues/{index}` and the field `body`. Read the body first, add the line, and send the whole body.

### Native dependencies

Blocking relations are native Gitea dependencies. Do not replace them with prose in an issue body.

| Operation | Method and path | Body |
| --- | --- | --- |
| Add a blocker | `POST /repos/{owner}/{repo}/issues/{index}/dependencies` | `IssueMeta`: `owner`, `repo`, `index` |
| Read the blockers | `GET /repos/{owner}/{repo}/issues/{index}/dependencies` | none |

The issue in the URL depends on the issue in the body. GET returns each issue that blocks the issue in the URL.

```sh
curl -fsS -X POST -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d "{\"owner\": \"$OWNER\", \"repo\": \"$REPO\", \"index\": <blocker-index>}" "$API/issues/$INDEX/dependencies"
curl -fsS -H "Authorization: token $GITEA_TOKEN" "$API/issues/$INDEX/dependencies"
```

Wire the dependencies in two passes:

1. Pass 1: create all issues. A blocker needs a real number before a relation can name it.
2. Pass 2: add each relation with POST. Then read the blockers of each issue back with GET.

Compare the result of the read-back with the approved graph. Report each difference. Do not continue with a graph that differs.

### Frontier

The frontier is the set of tickets that a worker can take now. A ticket is in the frontier when all of these are true:

- It is open and carries `wayfinder:parent:<map>`.
- It has no assignee. The `assignees` field of an unassigned issue is `null` or an empty list.
- Each of its blockers is closed.
- It does not carry `needs-approval` (section [Labels](#labels)).

Compute it from the tracker on each use:

1. Read `GET /repos/{owner}/{repo}/labels` and confirm that `wayfinder:parent:<map>` exists. If it does not exist, stop and report it.
2. List the open children of the map, all pages. Drop each result whose `labels` field does not hold `wayfinder:parent:<map>`.
3. Keep a child only when its `assignees` field is empty or `null`. Drop each child that carries `needs-approval`.
4. Read the blockers of each remaining child with `GET /repos/{owner}/{repo}/issues/{index}/dependencies`.
5. Keep the child when each blocker has the `state` value `closed`.

An empty frontier is valid only after step 1 passes. A checklist in an issue body is not a source for the frontier.

### Claim

Claim a ticket before work starts. A claim is an assignment to the account of the token and a claim comment.

```sh
curl -fsS -H "Authorization: token $GITEA_TOKEN" "${API%/repos/*}/user"
curl -fsS -X PATCH -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d '{"assignees": ["<login>"]}' "$API/issues/$INDEX"
curl -fsS -X POST -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
  -d '{"body": "Claimed: <who works on it and where>"}' "$API/issues/$INDEX/comments"
```

Read the issue first. If it has an assignee, do not claim it. Do not claim a ticket that carries `needs-approval` (section [Labels](#labels)).

### Resolve

1. Post the resolution comment on the ticket. It holds the decision or the result, and the evidence.
2. Close the ticket with `PATCH` and the `state` value `closed`.
3. Add one line for the ticket to "Decisions so far" in the map body.

Gitea refuses to close an issue while a blocker of it is open. The response is HTTP 412. Thus close the blockers first. A dry run closes the child before the map, or removes the dependency first.

## Publication safety

- Before a create, list the existing maps, labels and issues, all pages. Do not create a duplicate.
- After an unclear network result, read the tracker before a second create. Do not repeat a POST blindly.
- Do not overwrite an issue body that differs from the expected text. Report the difference.
- Publication of a map or of tickets does not assign a ticket and does not start a worker.
