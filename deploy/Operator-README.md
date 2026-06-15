# k8sgames — OLM Deployment

This directory packages the upstream [k8sgames](https://github.com/rohitg00/k8sgames) static web app as an OLM-managed workload so it can be installed, upgraded, and kept in sync with upstream via a standard OpenShift Subscription.

No files in the parent directory are modified — the upstream simulator is pulled at image build time.

---

## Architecture

```
┌──────────────────────────────────────────────────┐
│                   Docker Hub                      │
│  fumbles/k8sgames:vX.Y.Z          (app image)    │
│  fumbles/k8sgames-bundle:vX.Y.Z   (OLM bundle)   │
│  fumbles/k8sgames-catalog:vX.Y.Z  (OLM catalog)  │
└────────────────────────┬─────────────────────────┘
                         │  registryPoll every 10m
                         ▼
┌──────────────────────────────────────────────────┐
│            OpenShift / OLM                        │
│                                                   │
│  CatalogSource (openshift-marketplace)            │
│    └─► Subscription (games ns)                   │
│          └─► InstallPlan → CSV → Deployment       │
└────────────────────────┬─────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────┐
│  games namespace                                  │
│  Deployment → Pod (nginx, port 8080, non-root)    │
│  Service (k8sgames:8080)                          │
│  Route  (edge TLS, auto-generated host)           │
└──────────────────────────────────────────────────┘
```

**Three-image model**

| Image | What it is | Who builds it |
|---|---|---|
| `k8sgames` | nginx-unprivileged serving static files cloned from upstream at build time | `Dockerfile` |
| `k8sgames-bundle` | OLM bundle — contains the ClusterServiceVersion (CSV) that defines the Deployment | `bundle.Dockerfile` |
| `k8sgames-catalog` | File-based catalog (FBC) served by `opm` — OLM discovers new versions here | `catalog.Dockerfile` |

There is no custom controller. OLM's install strategy manages the Deployment directly from the CSV. The Service and Route are static manifests applied once alongside the Subscription.

**Keeping up to date**

`CatalogSource.spec.updateStrategy.registryPoll` is set to `10m`. When a new catalog image is pushed, OLM detects it within 10 minutes and creates an InstallPlan. With `installPlanApproval: Automatic` the upgrade proceeds without manual intervention.

The app image clones upstream at build time via a `GIT_REF` build arg (default: `main`), so rebuilding the image always picks up the latest upstream content.

---

## Prerequisites

- OpenShift 4.x (OLM pre-installed)
- Docker or Podman with `buildx` support for multi-arch
- `opm` — downloaded automatically by `make opm`
- Docker Hub account with write access to `docker.io/fumbles/k8sgames*`
- `games` namespace already exists on the cluster

---

## Install on a cluster

> The catalog image must be pushed before you apply the CatalogSource.
> See [Build & Ship](#build--ship) below if you haven't done this yet.

```bash
cd deploy

# 1. Add the catalog to OLM (openshift-marketplace namespace)
kubectl apply -f config/catalog/catalogsource.yaml

# 2. Scope OLM to the games namespace
kubectl apply -f config/catalog/operatorgroup.yaml

# 3. Subscribe — OLM installs the Deployment automatically
kubectl apply -f config/catalog/subscription.yaml

# 4. Expose the app (Service + Route are static, applied once)
kubectl apply -f config/catalog/service.yaml
kubectl apply -f config/catalog/route.yaml
```

Or apply everything in one shot:

```bash
make deploy
```

**Check the install:**

```bash
# OLM subscription state
kubectl get subscription k8sgames -n games

# Running pod
kubectl get pods -n games -l app=k8sgames

# Route URL
kubectl get route k8sgames -n games -o jsonpath='{.spec.host}'
```

---

## Build & Ship

All commands run from the `deploy/` directory.

### First ship

```bash
cd deploy
./build.sh build --ship
```

This will:
1. Run quality gates (manifest checks, optional yamllint / kube-linter)
2. Build and push multi-arch (`linux/amd64` + `linux/arm64`) app image
3. Build and push multi-arch bundle image
4. Generate the file-based catalog via `opm render`, then build and push multi-arch catalog image
5. Print the install commands

### Release a new version

```bash
./build.sh build --new-version --ship
```

`--new-version` bumps the patch version (`0.1.0 → 0.1.1`), updates:
- `Makefile` `VERSION`
- CSV `name`, `version`, `containerImage`, `spec.install` image reference, and `spec.replaces`
- `catalogsource.yaml` catalog image tag

Then commit and tag:

```bash
git add -A
git commit -m "k8sgames v0.1.1"
git tag v0.1.1
git push && git push --tags
```

### Pin to a specific upstream commit

```bash
docker build --build-arg GIT_REF=abc1234 -f Dockerfile -t docker.io/fumbles/k8sgames:v0.1.1 .
```

### Build locally (no push)

```bash
./build.sh build
```

Builds a single-arch app image locally. Useful for smoke-testing before shipping.

### Other make targets

```bash
make help           # list all targets
make docker-build   # build app image (native arch, local)
make bundle-build   # build bundle image (local)
make catalog        # generate catalog/ from pushed bundle image (requires opm)
make catalog-build  # build catalog image from generated catalog/
make clean          # remove catalog/ and bin/
```

---

## Development

### Changing the Deployment spec

Edit `bundle/manifests/k8sgames.clusterserviceversion.yaml` under `spec.install.spec.deployments`. Then build and ship a new version.

### Changing the Service or Route

Edit `config/catalog/service.yaml` or `config/catalog/route.yaml` and re-apply. These are not OLM-managed and can be updated independently.

### Bumping to a specific version (not patch)

```bash
./build.sh build 1.0.0 --ship
```

### Quality gates only

```bash
./build.sh check
```

Validates manifests are present and runs any available optional linters (`yamllint`, `kube-linter`, `operator-sdk bundle validate`).

---

## File structure

```
deploy/
├── Dockerfile              App image — clones upstream, serves via nginx:unprivileged
├── bundle.Dockerfile       OLM bundle image (FROM scratch, copies manifests/)
├── catalog.Dockerfile      OLM catalog image (opm serves FBC yaml)
├── Makefile                Build / push / deploy targets
├── build.sh                Main build script (version management + quality gates)
├── .gitignore              Excludes generated catalog/ and bin/
│
├── bundle/
│   ├── manifests/
│   │   └── k8sgames.clusterserviceversion.yaml   CSV — defines the Deployment
│   └── metadata/
│       └── annotations.yaml                       OLM bundle metadata
│
├── catalog/                GENERATED by `make catalog` — do not commit
│   └── k8sgames-catalog.yaml
│
└── config/
    └── catalog/
        ├── catalogsource.yaml    CatalogSource (openshift-marketplace ns)
        ├── operatorgroup.yaml    OperatorGroup (games ns)
        ├── subscription.yaml     Subscription  (games ns, Automatic approval)
        ├── service.yaml          Service       (games ns, port 8080)
        └── route.yaml            Route         (games ns, edge TLS)
```

---

## Uninstall

```bash
make undeploy
```

Or manually:

```bash
kubectl delete subscription k8sgames -n games
kubectl delete csv k8sgames.vX.Y.Z -n games
kubectl delete operatorgroup games-og -n games
kubectl delete catalogsource k8sgames-catalog -n openshift-marketplace
kubectl delete service k8sgames -n games
kubectl delete route k8sgames -n games
```
