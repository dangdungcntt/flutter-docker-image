SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := build

VERSION_MANIFEST ?= config/version.json
DOCKERFILE ?= android.Dockerfile
BUILDER ?= flutter-local
IMAGE ?= flutter-android

FLUTTER_VERSION = $(shell jq -er '.flutter.version' $(VERSION_MANIFEST))
FASTLANE_VERSION = $(shell jq -er '.fastlane.version' $(VERSION_MANIFEST))
ANDROID_BUILD_TOOLS_VERSION = $(shell jq -er '.android.buildTools.version' $(VERSION_MANIFEST))
ANDROID_PLATFORM_VERSIONS = $(shell jq -er '[.android.platforms[].version | tostring] | join(" ")' $(VERSION_MANIFEST))
ANDROID_NDK_VERSION = $(shell jq -er '.android.ndk.version' $(VERSION_MANIFEST))
CMAKE_VERSION = $(shell jq -er '.android.cmake.version' $(VERSION_MANIFEST))

TAG ?= $(FLUTTER_VERSION)
PLATFORMS ?= linux/amd64,linux/arm64/v8
OUTPUT ?= dist/$(IMAGE)-$(TAG).oci.tar

HOST_ARCH := $(shell uname -m)
ifneq ($(filter arm64 aarch64,$(HOST_ARCH)),)
LOCAL_PLATFORM ?= linux/arm64/v8
else
LOCAL_PLATFORM ?= linux/amd64
endif

BUILD_ARGS = \
	--build-arg "flutter_version=$(FLUTTER_VERSION)" \
	--build-arg "fastlane_version=$(FASTLANE_VERSION)" \
	--build-arg "android_build_tools_version=$(ANDROID_BUILD_TOOLS_VERSION)" \
	--build-arg "android_platform_versions=$(ANDROID_PLATFORM_VERSIONS)" \
	--build-arg "android_ndk_version=$(ANDROID_NDK_VERSION)" \
	--build-arg "cmake_version=$(CMAKE_VERSION)"

BUILD = docker buildx build \
	--builder "$(BUILDER)" \
	--file "$(DOCKERFILE)" \
	--target android \
	$(BUILD_ARGS)

.PHONY: help check builder print-config build build-amd64 build-arm64 build-multiarch push-multiarch inspect

help: ## Show available targets.
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check: ## Verify local build dependencies.
	@command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
	@command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
	@docker info >/dev/null
	@docker buildx version >/dev/null
	@jq empty "$(VERSION_MANIFEST)"

builder: check ## Create and bootstrap the reusable Buildx builder.
	@if ! docker buildx inspect "$(BUILDER)" >/dev/null 2>&1; then \
		docker buildx create --name "$(BUILDER)" --driver docker-container; \
	fi
	@docker buildx inspect "$(BUILDER)" --bootstrap >/dev/null

print-config: check ## Print resolved versions, image name, and platforms.
	@printf '%s\n' \
		"image=$(IMAGE):$(TAG)" \
		"local_platform=$(LOCAL_PLATFORM)" \
		"platforms=$(PLATFORMS)" \
		"flutter=$(FLUTTER_VERSION)" \
		"fastlane=$(FASTLANE_VERSION)" \
		"android_build_tools=$(ANDROID_BUILD_TOOLS_VERSION)" \
		"android_platforms=$(ANDROID_PLATFORM_VERSIONS)" \
		"android_ndk=$(ANDROID_NDK_VERSION)" \
		"cmake=$(CMAKE_VERSION)"

build: builder ## Build the native image and load it into the local Docker daemon.
	$(BUILD) \
		--platform "$(LOCAL_PLATFORM)" \
		--tag "$(IMAGE):$(TAG)" \
		--load \
		.

build-amd64: builder ## Build amd64 and load it as IMAGE:TAG-amd64.
	$(BUILD) \
		--platform linux/amd64 \
		--tag "$(IMAGE):$(TAG)-amd64" \
		--load \
		.

build-arm64: builder ## Build arm64/v8 and load it as IMAGE:TAG-arm64.
	$(BUILD) \
		--platform linux/arm64/v8 \
		--tag "$(IMAGE):$(TAG)-arm64" \
		--load \
		.

build-multiarch: builder ## Build all platforms into a local OCI archive.
	@mkdir -p "$(dir $(OUTPUT))"
	$(BUILD) \
		--platform "$(PLATFORMS)" \
		--tag "$(IMAGE):$(TAG)" \
		--output "type=oci,dest=$(OUTPUT)" \
		.
	@echo "Created $(OUTPUT)"

push-multiarch: builder ## Build and push a multi-architecture image.
	$(BUILD) \
		--platform "$(PLATFORMS)" \
		--tag "$(IMAGE):$(TAG)" \
		--push \
		.

inspect: check ## Inspect the pushed IMAGE:TAG manifest.
	docker buildx imagetools inspect "$(IMAGE):$(TAG)"
