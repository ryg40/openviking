# Architecture explorer

`docs/architecture.html` is an interactive map of OpenViking as this repository deploys it.
It is one self-contained HTML file with four views, a search, a group filter and a short guided tour.
It makes no network request, so it opens from the file system without a server.

## What it shows

| View | Content |
| --- | --- |
| Runtime and deployment | The clients, the network path, the `openviking` container, the host files and the model endpoints. Each edge names the protocol or the file. |
| Server internals | The HTTP API, `/mcp`, the service layer, retrieval, sessions and memory, the parsers and queues, VikingFS, RAGFS, the vector index and the model clients. |
| Data flows | Three flows on the nodes of the server internals: add context, retrieve context and session commit. Each step names the code that runs. |
| Repository, release and image | The Git refs from the upstream tag to `portable` and the `shared` remote, the checks on each edge, the image build and the run. |

Each node has a summary, a group, the files that define it, the configuration keys that shape it and its edges.
Some nodes also have a value.
The public build shows example values from tracked files.
Each edge tells what passes over it.
In the repository view, each edge also lists its checks.
The file paths in the panel are text, not links.

The model describes the source tree; the generator does not read the code.
After an upstream sync, compare the server internals with the code under `openviking/` and update `docs/architecture/model.json`.

## Open it

1. Open `docs/architecture.html` in a browser.
   A double-click in a file manager is enough.
2. Select a node to open its panel on the right.
   The panel shows the summary, the value, the files, the keys and the edges.
3. Select Tour for a short guided walk through the views.

| Action | Mouse | Keyboard |
| --- | --- | --- |
| Open the panel of a node | Click the node | Tab to the node, then Enter |
| Close the panel | The close button | Escape |
| Show what passes over an edge | Click the edge or its label | Enter on an edge in the panel |
| Drill down into a component | Double-click a node with the layer icon, or use the button in the panel | The button in the panel |
| Go back after a drill-down | The path above the graph | Escape |
| Search nodes, files and keys | The search field | `/` |
| Step through a flow | Next and Back | Left and right arrow keys |
| Zoom and fit | Mouse wheel, `+`, `−`, Fit | `+`, `-`, `0` |
| Pan | Drag the background | None |

The group buttons above the graph hide and show a group.
The theme button changes between auto, light and dark.
The URL fragment keeps the view, the node and the flow step, for example `#view=flows&flow=commit&step=3`.

## Files

| File | Purpose |
| --- | --- |
| `docs/architecture/model.json` | Nodes, edges, views, flows and the tour, with placeholders such as `{{host.public_url}}` |
| `docs/architecture/values.public.json` | Example values for the placeholders, each with the tracked file it comes from |
| `docs/architecture/template.html` | HTML, CSS and the renderer |
| `docs/scripts/build-architecture.py` | The generator: model plus template plus one value file gives one HTML file |
| `docs/architecture.html` | The public build. Do not edit it; rebuild it. |

## Rebuild the public build

Run this command after each change to the model, the template or the public values:

```sh
python3 -I docs/scripts/build-architecture.py \
  --values docs/architecture/values.public.json --out docs/architecture.html
```

Commit the changed source files and `docs/architecture.html` together.
To check that the tracked build is current, add `--check`.
The generator then compares and writes nothing:

```sh
python3 -I docs/scripts/build-architecture.py --check \
  --values docs/architecture/values.public.json --out docs/architecture.html
```

The generator exits 1 in these cases:

- A placeholder has no value.
- A value of the value file is not used.
- The model names a node, a group, a flow or a view that does not exist.
- The output is not current (with `--check`).

It needs Python 3 and its standard library only.
Each value of `docs/architecture/values.public.json` comes from a tracked file.
A value file never holds a credential.

## Make a local build for a host

A host can make its own build with its real names and values.
The value file and the build stay under `.local/architecture/`, which Git ignores.

1. Make the directory and copy the public value file:

   ```sh
   mkdir -p .local/architecture
   cp docs/architecture/values.public.json .local/architecture/values.local.json
   ```

2. Replace each value with the value of the host.
   Use the host override `.local/compose.host.yaml`, the deployment record of the host, `docker inspect` of the container and the keys of `.env` and `data/ov.conf` that are not secret.
3. Build the file:

   ```sh
   python3 -I docs/scripts/build-architecture.py \
     --values .local/architecture/values.local.json \
     --out .local/architecture/openviking-local-dev.html
   ```

4. Open `.local/architecture/openviking-local-dev.html` in a browser.
   The header and the footer show the build name and the note of the value file.

Warning: never copy a credential into a value file. Read `.env` and `data/ov.conf` only through a filter that drops each key whose name contains key, token, secret or password.

Filters for the two files:

```sh
sed -E '/KEY|TOKEN|SECRET|PASSWORD/s/=.*/=<redacted>/' .env
python3 -I -c '
import json
def walk(o, p=""):
    for k, v in o.items():
        q = p + "." + k if p else k
        if any(s in k.lower() for s in ("key", "token", "secret", "password")):
            continue
        walk(v, q) if isinstance(v, dict) else print(q, "=", json.dumps(v))
walk(json.load(open("data/ov.conf")))'
```

Warning: do not use the output of `docker compose config` as a source. It contains the root API key.

Warning: the local build shows host names, URLs and model endpoints. Do not commit it, publish it or send it to another party.

The generator refuses a value file with the name `.env`, `ov.conf` or `ovcli.conf`, and a value file under the state directory `data/`.

## Design

- The renderer draws SVG with its own layered layout, without a third-party library.
  Groups stand in columns, columns stand in rows, and nodes form a grid inside each group.
- Edges are cubic curves.
  The ports of each node side follow the order of the other ends.
  Edge labels avoid nodes and other labels where the space allows.
- The server internals view has wider gaps and a stricter label placement.
  No label touches a node, a group title or another label.
  A label without room on its edge stands nearby, with a dotted leader line to its edge.
- The data flow view reuses the layout of the server internals and marks the nodes of one flow, step by step.
- Each graph is an SVG with a title and a description.
  Each node is a focusable button.
- The colors pass a contrast of 4.5:1 for text in light and dark mode.
- A content security policy in the file blocks every network request.

Not verified: the explorer in Firefox and Safari. The checks use Chrome.
