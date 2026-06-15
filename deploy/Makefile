# VERSION is the semver for all images (app, bundle, catalog).
VERSION ?= 0.1.1

# CHANNELS / DEFAULT_CHANNEL for OLM bundle metadata.
CHANNELS ?= stable
DEFAULT_CHANNEL ?= stable
BUNDLE_METADATA_OPTS ?= --channels=$(CHANNELS) --default-channel=$(DEFAULT_CHANNEL)

# Docker Hub org — create docker.io/fumbles/k8sgames* repos before pushing.
DOCKER_ORG ?= fumbles

# Image references
IMG         ?= docker.io/$(DOCKER_ORG)/k8sgames:v$(VERSION)
BUNDLE_IMG  ?= docker.io/$(DOCKER_ORG)/k8sgames-bundle:v$(VERSION)
CATALOG_IMG ?= docker.io/$(DOCKER_ORG)/k8sgames-catalog:v$(VERSION)

# Multi-arch platforms for --ship builds
PLATFORMS ?= linux/amd64,linux/arm64

# Container tool: prefer docker, fall back to podman
CONTAINER_TOOL ?= $(shell command -v docker >/dev/null 2>&1 && echo docker || echo podman)
IS_PODMAN     := $(findstring podman,$(notdir $(CONTAINER_TOOL)))
LOAD_FLAG     := $(if $(IS_PODMAN),,--load)

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

LOCALBIN ?= $(CURDIR)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

OPM = $(LOCALBIN)/opm

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: all
all: docker-build bundle-build ## Build app + bundle images locally.

##@ App image

.PHONY: docker-build
docker-build: ## Build app image locally (native arch).
	$(CONTAINER_TOOL) build $(LOAD_FLAG) -f Dockerfile -t $(IMG) .

.PHONY: docker-push
docker-push: ## Push app image.
	$(CONTAINER_TOOL) push $(IMG)

.PHONY: docker-buildx
docker-buildx: ## Build + push multi-arch app image (linux/amd64 + arm64).
ifeq ($(IS_PODMAN),podman)
	- $(CONTAINER_TOOL) manifest rm $(IMG)
	$(CONTAINER_TOOL) build --platform=$(PLATFORMS) --manifest $(IMG) -f Dockerfile .
	$(CONTAINER_TOOL) manifest push --all $(IMG) docker://$(IMG)
else
	- $(CONTAINER_TOOL) buildx create --name k8sgames-builder
	$(CONTAINER_TOOL) buildx use k8sgames-builder
	$(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --tag $(IMG) -f Dockerfile . || \
		{ $(CONTAINER_TOOL) buildx rm k8sgames-builder; exit 1; }
	- $(CONTAINER_TOOL) buildx rm k8sgames-builder
endif

##@ OLM bundle

.PHONY: bundle-build
bundle-build: ## Build bundle image locally (native arch).
	$(CONTAINER_TOOL) build $(LOAD_FLAG) -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push bundle image.
	$(CONTAINER_TOOL) push $(BUNDLE_IMG)

.PHONY: bundle-buildx
bundle-buildx: ## Build + push multi-arch bundle image.
ifeq ($(IS_PODMAN),podman)
	- $(CONTAINER_TOOL) manifest rm $(BUNDLE_IMG)
	$(CONTAINER_TOOL) build --platform=$(PLATFORMS) --manifest $(BUNDLE_IMG) -f bundle.Dockerfile .
	$(CONTAINER_TOOL) manifest push --all $(BUNDLE_IMG) docker://$(BUNDLE_IMG)
else
	- $(CONTAINER_TOOL) buildx create --name k8sgames-builder
	$(CONTAINER_TOOL) buildx use k8sgames-builder
	$(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --tag $(BUNDLE_IMG) -f bundle.Dockerfile . || \
		{ $(CONTAINER_TOOL) buildx rm k8sgames-builder; exit 1; }
	- $(CONTAINER_TOOL) buildx rm k8sgames-builder
endif

##@ OLM catalog (file-based catalog)

.PHONY: catalog
catalog: opm ## Generate file-based catalog under catalog/ from the pushed bundle image.
	@if [ ! -f "$$HOME/.config/containers/policy.json" ] && [ ! -f /etc/containers/policy.json ]; then \
		mkdir -p "$$HOME/.config/containers"; \
		echo '{"default":[{"type":"insecureAcceptAnything"}]}' > "$$HOME/.config/containers/policy.json"; \
		echo "Created $$HOME/.config/containers/policy.json (needed by opm render)"; \
	fi
	rm -rf catalog && mkdir -p catalog
	$(OPM) init k8sgames --default-channel=$(DEFAULT_CHANNEL) --output yaml > catalog/k8sgames-catalog.yaml
	$(OPM) render $(BUNDLE_IMG) --output yaml >> catalog/k8sgames-catalog.yaml
	@REPLACES=$$(grep '^  replaces:' bundle/manifests/k8sgames.clusterserviceversion.yaml | awk '{print $$2}'); \
	if [ -n "$$REPLACES" ]; then \
		printf -- "---\nschema: olm.channel\npackage: k8sgames\nname: $(DEFAULT_CHANNEL)\nentries:\n- name: k8sgames.v$(VERSION)\n  replaces: $$REPLACES\n" \
			>> catalog/k8sgames-catalog.yaml; \
	else \
		printf -- "---\nschema: olm.channel\npackage: k8sgames\nname: $(DEFAULT_CHANNEL)\nentries:\n- name: k8sgames.v$(VERSION)\n" \
			>> catalog/k8sgames-catalog.yaml; \
	fi

.PHONY: catalog-build
catalog-build: catalog ## Build catalog image locally.
	$(CONTAINER_TOOL) build $(LOAD_FLAG) -f catalog.Dockerfile -t $(CATALOG_IMG) .

.PHONY: catalog-push
catalog-push: ## Push catalog image.
	$(CONTAINER_TOOL) push $(CATALOG_IMG)

.PHONY: catalog-buildx
catalog-buildx: catalog ## Build + push multi-arch catalog image.
ifeq ($(IS_PODMAN),podman)
	- $(CONTAINER_TOOL) manifest rm $(CATALOG_IMG)
	$(CONTAINER_TOOL) build --platform=$(PLATFORMS) --manifest $(CATALOG_IMG) -f catalog.Dockerfile .
	$(CONTAINER_TOOL) manifest push --all $(CATALOG_IMG) docker://$(CATALOG_IMG)
else
	- $(CONTAINER_TOOL) buildx create --name k8sgames-builder
	$(CONTAINER_TOOL) buildx use k8sgames-builder
	$(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --tag $(CATALOG_IMG) -f catalog.Dockerfile . || \
		{ $(CONTAINER_TOOL) buildx rm k8sgames-builder; exit 1; }
	- $(CONTAINER_TOOL) buildx rm k8sgames-builder
endif

##@ Cluster install

.PHONY: deploy
deploy: ## Apply CatalogSource, OperatorGroup, Subscription, Service, and Route.
	kubectl apply -f config/catalog/catalogsource.yaml
	kubectl apply -f config/catalog/operatorgroup.yaml
	kubectl apply -f config/catalog/subscription.yaml
	kubectl apply -f config/catalog/service.yaml
	kubectl apply -f config/catalog/route.yaml

.PHONY: undeploy
undeploy: ## Remove all installed resources.
	kubectl delete -f config/catalog/route.yaml --ignore-not-found
	kubectl delete -f config/catalog/service.yaml --ignore-not-found
	kubectl delete -f config/catalog/subscription.yaml --ignore-not-found
	kubectl delete -f config/catalog/operatorgroup.yaml --ignore-not-found
	kubectl delete -f config/catalog/catalogsource.yaml --ignore-not-found

##@ Tools

.PHONY: opm
opm: $(OPM) ## Download opm locally if necessary.
$(OPM): | $(LOCALBIN)
	@echo "Downloading opm..."
	OS=$$(go env GOOS 2>/dev/null || uname -s | tr '[:upper:]' '[:lower:]') && \
	ARCH=$$(go env GOARCH 2>/dev/null || uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
	curl -sSLo $(OPM) \
		https://github.com/operator-framework/operator-registry/releases/download/v1.55.0/$${OS}-$${ARCH}-opm && \
	chmod +x $(OPM)

.PHONY: clean
clean: ## Remove build artifacts.
	rm -rf catalog bin
