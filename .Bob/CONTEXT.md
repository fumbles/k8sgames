# k8sgames — LLM Context

This file is authoritative context for AI assistants (Claude, IBM Bob) working in this repo.
Read this before making any changes.

---

## What this repo is

A **fork** of [rohitg00/k8sgames](https://github.com/rohitg00/k8sgames) — a browser-based
Kubernetes scenario simulator and game. The simulator teaches Kubernetes concepts through
interactive gameplay (sandbox, campaign, chaos, and challenge modes).

Our fork lives at `git@github.com:fumbles/k8sgames.git`.

**The only thing this fork adds** is the `deploy/` directory, which packages the simulator
as an OLM-managed workload so it can be installed and auto-updated on OpenShift via a
CatalogSource and Subscription.

---

## The prime directive

**Do not modify any simulator files.** Everything outside `deploy/` is upstream code.
Keeping those files untouched means we can pull upstream changes without merge conflicts.

Files owned by upstream (never edit):
```
index.html  draw.html  style.css  robots.txt  vercel.json
og-image.*  screenshot.png  js/**  LICENSE  README.md
```

All work goes in `deploy/`.

---

## Cluster details

| Item | Value |
|---|---|
| Platform | OpenShift (SNO) |
| Cluster domain | `apps.sno.yamlwrangler.com` |
| Target namespace | `games` (pre-existing, do not create) |
| CatalogSource namespace | `openshift-marketplace` |
| Docker Hub org | `fumbles` |
| Upstream repo | `https://github.com/rohitg00/k8sgames` |

---

## Repo topology

```
k8sgames/
├── index.html, style.css, js/, ...   ← upstream simulator (read-only)
└── deploy/                            ← everything we own
    ├── Dockerfile                     App image: clones upstream at build time, serves via nginx
    ├── bundle.Dockerfile              OLM bundle image (FROM scratch)
    ├── catalog.Dockerfile             OLM catalog image (opm FBC server)
    ├── Makefile                       All build/push targets
    ├── build.sh                       Main build script (version mgmt + ship)
    ├── Operator-README.md             Human-readable operator docs
    ├── .gitignore                     Excludes catalog/ and bin/
    │
    ├── bundle/
    │   ├── manifests/
    │   │   └── k8sgames.clusterserviceversion.yaml   OLM CSV (defines the Deployment)
    │   └── metadata/
    │       └── annotations.yaml                       OLM bundle metadata
    │
    ├── catalog/                       GENERATED — do not edit or commit
    │   └── k8sgames-catalog.yaml      FBC YAML produced by `make catalog`
    │
    └── config/catalog/                Static cluster manifests (apply once)
        ├── catalogsource.yaml
        ├── operatorgroup.yaml
        ├── subscription.yaml
        ├── service.yaml
        └── route.yaml
```

---

## OLM architecture

The app is packaged as a three-image OLM artifact. There is no custom controller —
OLM manages the Deployment directly from the ClusterServiceVersion (CSV).

```
docker.io/fumbles/k8sgames:vX.Y.Z          ← nginx serving static files
docker.io/fumbles/k8sgames-bundle:vX.Y.Z   ← OLM bundle (contains the CSV)
docker.io/fumbles/k8sgames-catalog:vX.Y.Z  ← FBC catalog served by opm
```

**How updates flow:**

1. A new app image is built (clones latest upstream at build time)
2. The bundle image is built (contains the new CSV pointing at the new app image)
3. `opm render` pulls the pushed bundle and generates `catalog/k8sgames-catalog.yaml`
4. The catalog image is built from that YAML and pushed
5. `CatalogSource.spec.updateStrategy.registryPoll` (10m) detects the new catalog image
6. OLM creates an InstallPlan; `installPlanApproval: Automatic` applies it without intervention

**What runs in the cluster (games namespace):**

| Resource | Kind | Notes |
|---|---|---|
| `k8sgames` | Deployment | Created and managed by OLM via the CSV |
| `k8sgames` | Service | Applied once alongside Subscription; port 8080, named port `http` |
| `k8sgames` | Route | Applied once; edge TLS, auto-generated host, redirects HTTP→HTTPS |

The Service and Route are static — they don't go through OLM and don't need re-applying
on version upgrades.

---

## Version management

**Single source of truth: `deploy/Makefile` line 1**

```makefile
VERSION ?= 0.1.0
```

`build.sh` reads this with `awk '/^VERSION \?=/ {print $3; exit}' Makefile`.

When `set_version old new` runs, it rewrites all pinned references atomically:

| File | What changes |
|---|---|
| `deploy/Makefile` | `VERSION ?= X.Y.Z` |
| `bundle/manifests/k8sgames.clusterserviceversion.yaml` | `name:`, `version:`, `containerImage:`, `spec.install` image, `replaces:` |
| `config/catalog/catalogsource.yaml` | `spec.image` tag |

The `spec.replaces` field in the CSV maintains the OLM upgrade graph so existing installs
upgrade cleanly. If a version was never published to a catalog, remove `replaces:` from
the CSV before shipping.

---

## Syncing upstream

The simulator source is not vendored — the app image clones it at build time via `GIT_REF`.
But the fork itself should track upstream to get bug fixes committed directly to the repo.

**Add the upstream remote (one time):**
```bash
git remote add upstream https://github.com/rohitg00/k8sgames.git
```

**Sync upstream main into the fork:**
```bash
git fetch upstream
git checkout main
git merge upstream/main          # fast-forward if no local commits on main
git push origin main
```

Conflicts are only possible if upstream modifies files we also modified — which should be
never, because we only touch `deploy/`. If a conflict does appear, always keep our version
of `deploy/` and accept upstream for everything else.

**Pinning upstream at build time:**

The `Dockerfile` accepts a `GIT_REF` build arg (branch, tag, or SHA):
```bash
# Latest upstream main (default):
make docker-build

# Specific upstream tag:
make docker-build IMG=docker.io/fumbles/k8sgames:v0.2.0 \
  && docker build --build-arg GIT_REF=v1.2.3 -f Dockerfile -t docker.io/fumbles/k8sgames:v0.2.0 .
```

---

## Build workflow

All commands run from `deploy/`.

### Local build (no push)
```bash
cd deploy
./build.sh build
```
Builds a native-arch app image locally. Good for smoke-testing the Dockerfile.

### Check only (no image build)
```bash
./build.sh check
```
Validates bundle manifests exist, runs optional linters (`operator-sdk bundle validate`,
`kube-linter`, `yamllint`) if installed.

### Bump and ship a new patch release
```bash
./build.sh build --new-version --ship
```
1. Bumps `0.1.0 → 0.1.1` (patch)
2. Rewrites all version references (Makefile, CSV, catalogsource)
3. Builds + pushes multi-arch (`linux/amd64`, `linux/arm64`) app image
4. Builds + pushes multi-arch bundle image
5. Runs `opm render` to generate `catalog/`, builds + pushes multi-arch catalog image
6. Prints the cluster install commands

Then commit and tag:
```bash
git add -A
git commit -m "k8sgames v0.1.1"
git tag v0.1.1
git push && git push --tags
```

### Ship a specific version
```bash
./build.sh build 1.0.0 --ship
```

### Skip quality gates (emergency)
```bash
./build.sh build --ship --skip-checks
```

---

## Cluster install

Run once (or after `undeploy`). The `games` namespace must already exist.

```bash
cd deploy

# 1. Register the catalog with OLM (openshift-marketplace namespace)
kubectl apply -f config/catalog/catalogsource.yaml

# 2. Scope OLM to the games namespace
kubectl apply -f config/catalog/operatorgroup.yaml

# 3. Subscribe — OLM installs the Deployment automatically
kubectl apply -f config/catalog/subscription.yaml

# 4. Service and Route (static, applied once)
kubectl apply -f config/catalog/service.yaml
kubectl apply -f config/catalog/route.yaml
```

Or: `make deploy` (same thing).

**Verify:**
```bash
kubectl get subscription k8sgames -n games
kubectl get csv -n games
kubectl get pods -n games -l app=k8sgames
kubectl get route k8sgames -n games -o jsonpath='{.spec.host}'
```

**Uninstall:**
```bash
make undeploy
# Then remove the CSV OLM left behind:
kubectl delete csv k8sgames.vX.Y.Z -n games
```

---

## How updates reach the cluster (no manual re-apply needed)

After first install, upgrades are fully automatic:

1. Run `./build.sh build --new-version --ship`
2. The catalog image is pushed with the new bundle
3. OLM polls `openshift-marketplace/k8sgames-catalog` every 10 minutes
4. OLM sees a new CSV in the catalog, creates an InstallPlan, applies it automatically
5. The Deployment is updated to the new app image; Service and Route are unchanged

---

## Key make targets

```bash
make help           # list all targets with descriptions
make docker-build   # build app image locally (native arch)
make docker-buildx  # build + push multi-arch app image
make bundle-build   # build bundle image locally
make bundle-buildx  # build + push multi-arch bundle image
make catalog        # generate catalog/ from pushed bundle image (needs opm)
make catalog-buildx # build + push multi-arch catalog image
make deploy         # apply all config/catalog/ manifests
make undeploy       # delete all config/catalog/ manifests
make clean          # rm -rf catalog/ bin/
```

---

## Conventions and constraints

- **Never edit files outside `deploy/`** — they belong to upstream.
- **Version is always set in `deploy/Makefile`** — nowhere else. `build.sh` propagates it.
- **`catalog/` is generated** — never hand-edit it. It is gitignored. Regenerated by `make catalog`.
- **The bundle is hand-crafted** — there is no `operator-sdk generate bundle` step. Edit
  `bundle/manifests/k8sgames.clusterserviceversion.yaml` directly for Deployment spec changes.
- **Service and Route are not OLM-managed** — apply them separately; they survive operator upgrades.
- **`spec.replaces` must be correct** — if you publish v0.1.1 and it says `replaces: k8sgames.v0.1.0`,
  v0.1.0 must have been in the catalog at some point. Remove `replaces:` for the very first publish.
- **Always commit and tag after `--ship`** — the version files change on disk; uncommitted state
  means the next `--new-version` bump will be wrong.
- **Docker Hub repos must exist before first push** — create `fumbles/k8sgames`,
  `fumbles/k8sgames-bundle`, and `fumbles/k8sgames-catalog` on Docker Hub first.
