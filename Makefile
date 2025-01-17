$(info starting make in kong)

OS := $(shell uname | awk '{print tolower($$0)}')
MACHINE := $(shell uname -m)

DEV_ROCKS = "busted 2.1.1" "busted-htest 1.0.0" "luacheck 1.0.0" "lua-llthreads2 0.1.6" "http 0.4" "ldoc 1.4.6"
WIN_SCRIPTS = "bin/busted" "bin/kong"
BUSTED_ARGS ?= -v
TEST_CMD ?= bin/busted $(BUSTED_ARGS)

ifeq ($(OS), darwin)
OPENSSL_DIR ?= /usr/local/opt/openssl
GRPCURL_OS ?= osx
else
OPENSSL_DIR ?= /usr
GRPCURL_OS ?= $(OS)
endif

ifeq ($(MACHINE), aarch64)
GRPCURL_MACHINE ?= arm64
else
GRPCURL_MACHINE ?= $(MACHINE)
endif

.PHONY: install dependencies dev remove grpcurl \
	setup-ci setup-kong-build-tools \
	lint test test-integration test-plugins test-all \
	pdk-phase-check functional-tests \
	fix-windows release

ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
KONG_SOURCE_LOCATION ?= $(ROOT_DIR)
KONG_BUILD_TOOLS_LOCATION ?= $(KONG_SOURCE_LOCATION)/../kong-build-tools
RESTY_VERSION ?= `grep RESTY_VERSION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
RESTY_LUAROCKS_VERSION ?= `grep RESTY_LUAROCKS_VERSION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
RESTY_OPENSSL_VERSION ?= `grep RESTY_OPENSSL_VERSION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
RESTY_PCRE_VERSION ?= `grep RESTY_PCRE_VERSION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
KONG_BUILD_TOOLS ?= `grep KONG_BUILD_TOOLS_VERSION $(KONG_SOURCE_LOCATION)/.requirements | awk -F"=" '{print $$2}'`
GRPCURL_VERSION ?= 1.8.5
OPENRESTY_PATCHES_BRANCH ?= master
KONG_NGINX_MODULE_BRANCH ?= master
DOCKER_KONG_VERSION ?= master

PACKAGE_TYPE ?= deb

TAG := $(shell git describe --exact-match --tags HEAD || true)

ifneq ($(TAG),)
	ISTAG = true
	KONG_TAG = $(TAG)
	OFFICIAL_RELEASE = true
else
	# we're not building a tag so this is a nightly build
	RELEASE_DOCKER_ONLY = true
	OFFICIAL_RELEASE = false
	ISTAG = false
endif

clean:
	-rm -rf package
	-rm -rf docker-kong
	-docker rmi build-$(ARCHITECTURE)-$(PACKAGE_TYPE)
	-docker rmi test-$(ARCHITECTURE)-$(PACKAGE_TYPE)

release-docker-images:
	cd $(KONG_BUILD_TOOLS_LOCATION); \
	$(MAKE) \
	KONG_SOURCE_LOCATION=${KONG_SOURCE_LOCATION} \
	package-kong && \
	$(MAKE) \
	KONG_SOURCE_LOCATION=${KONG_SOURCE_LOCATION} \
	release-kong-docker-images

release:
	cd $(KONG_BUILD_TOOLS_LOCATION); \
	$(MAKE) \
	KONG_SOURCE_LOCATION=${KONG_SOURCE_LOCATION} \
	KONG_TAG=${KONG_TAG} \
	package-kong && \
	$(MAKE) \
	KONG_SOURCE_LOCATION=${KONG_SOURCE_LOCATION} \
	RELEASE_DOCKER_ONLY=${RELEASE_DOCKER_ONLY} \
	OFFICIAL_RELEASE=$(OFFICIAL_RELEASE) \
	KONG_TAG=${KONG_TAG} \
	release-kong

setup-ci:
	OPENRESTY=$(RESTY_VERSION) \
	LUAROCKS=$(RESTY_LUAROCKS_VERSION) \
	OPENSSL=$(RESTY_OPENSSL_VERSION) \
	OPENRESTY_PATCHES_BRANCH=$(OPENRESTY_PATCHES_BRANCH) \
	KONG_NGINX_MODULE_BRANCH=$(KONG_NGINX_MODULE_BRANCH) \
	.ci/setup_env.sh

ARCHITECTURE ?= amd64
PACKAGE_TYPE ?= deb
PACKAGE_EXTENSION ?= $(PACKAGE_TYPE)
OPERATING_SYSTEM ?= ubuntu
OPERATING_SYSTEM_VERSION ?= 18.04
TEST_OPERATING_SYSTEM ?= $(OPERATING_SYSTEM):$(OPERATING_SYSTEM_VERSION)
KONG_VERSION ?= 3.0.1
DOCKER_BUILD_TARGET ?= build
DOCKER_BUILD_OUTPUT ?= --load
DOCKER_COMMAND ?= /bin/bash
DOCKER_RELEASE_REPOSITORY ?= kong/kong
KONG_TEST_CONTAINER_TAG ?= $(PACKAGE_TYPE)
PULP_HOST ?= "https://api.pulp.konnect-dev.konghq.com"
PULP_USERNAME ?= "admin"
PULP_PASSWORD ?= "foxy" # not the real password

docker/build:
	docker image inspect -f='{{.Id}}' $(DOCKER_BUILD_TARGET)-$(ARCHITECTURE)-$(PACKAGE_TYPE) || \
	docker buildx build \
		--platform="linux/$(ARCHITECTURE)" \
		--build-arg PACKAGE_TYPE=$(PACKAGE_TYPE) \
		--build-arg KONG_VERSION=$(KONG_VERSION) \
		--build-arg OPERATING_SYSTEM=$(OPERATING_SYSTEM) \
		--build-arg OPERATING_SYSTEM_VERSION=$(OPERATING_SYSTEM_VERSION) \
		--build-arg ARCHITECTURE=$(ARCHITECTURE) \
		--build-arg TEST_OPERATING_SYSTEM=$(TEST_OPERATING_SYSTEM) \
		--target=$(DOCKER_BUILD_TARGET) \
		-t $(DOCKER_BUILD_TARGET)-$(ARCHITECTURE)-$(PACKAGE_TYPE) \
		$(DOCKER_BUILD_OUTPUT) .

package:
	$(MAKE) DOCKER_BUILD_TARGET=build docker/build
	$(MAKE) DOCKER_BUILD_TARGET=test docker/build
	$(MAKE) DOCKER_BUILD_TARGET=package DOCKER_BUILD_OUTPUT="-o package" docker/build
	ls package/

package/deb:
	PACKAGE_TYPE=deb \
	OPERATING_SYSTEM=ubuntu \
	OPERATING_SYSTEM_VERSION=18.04 \
	$(MAKE) package

package/apk:
	PACKAGE_TYPE=apk \
	OPERATING_SYSTEM=alpine \
	OPERATING_SYSTEM_VERSION=3 \
	TEST_OPERATING_SYSTEM=kong:latest \
	$(MAKE) package

package/rpm:
	PACKAGE_TYPE=rpm \
	OPERATING_SYSTEM=redhat/ubi7-minimal \
	OPERATING_SYSTEM_VERSION=7 \
	TEST_OPERATING_SYSTEM=registry.access.redhat.com/ubi8/ubi-minimal \
	$(MAKE) package

package/test: package/docker setup-kong-build-tools
	docker tag kong-$(ARCHITECTURE)-$(PACKAGE_TYPE) $(DOCKER_RELEASE_REPOSITORY):$(KONG_TEST_CONTAINER_TAG)
# Kong-build-tools backwards compatibility fix
	docker tag kong-$(ARCHITECTURE)-$(PACKAGE_TYPE) $(DOCKER_RELEASE_REPOSITORY):amd64-$(KONG_TEST_CONTAINER_TAG)
	docker tag kong-$(ARCHITECTURE)-$(PACKAGE_TYPE) $(DOCKER_RELEASE_REPOSITORY):arm64-$(KONG_TEST_CONTAINER_TAG)
	cp package/*$(ARCHITECTURE).$(PACKAGE_EXTENSION) $(KONG_BUILD_TOOLS_LOCATION)/output/
	cd $(KONG_BUILD_TOOLS_LOCATION); \
	KONG_SOURCE_LOCATION=$(PWD) \
	DOCKER_RELEASE_REPOSITORY=$(DOCKER_RELEASE_REPOSITORY) \
	KONG_TEST_CONTAINER_TAG=$(KONG_TEST_CONTAINER_TAG) \
	ARCHITECTURE=$(ARCHITECTURE) \
	$(MAKE) test

package/test/deb:
	PACKAGE_TYPE=deb \
	OPERATING_SYSTEM=ubuntu \
	OPERATING_SYSTEM_VERSION=18.04 \
	RESTY_IMAGE_BASE=ubuntu \
	RESTY_IMAGE_TAG=18.04 \
	$(MAKE) package/test

package/test/apk:
	PACKAGE_TYPE=apk \
	OPERATING_SYSTEM=alpine \
	OPERATING_SYSTEM_VERSION=3 \
	PACKAGE_EXTENSION=apk.tar.gz \
	RESTY_IMAGE_BASE=alpine \
	RESTY_IMAGE_TAG=3 \
	TEST_OPERATING_SYSTEM=kong:latest \
	$(MAKE) package/test

package/test/rpm:
# Kong-build-tools backwards compatibility fix
	docker pull --platform=linux/${ARCHITECTURE} registry.access.redhat.com/ubi8/ubi
	PACKAGE_TYPE=rpm \
	OPERATING_SYSTEM=redhat/ubi8-minimal \
	OPERATING_SYSTEM_VERSION=latest \
	RESTY_IMAGE_BASE=rhel \
	RESTY_IMAGE_TAG=8 \
	$(MAKE) package/test

package/docker: package
	-rm -rf docker-kong
	git clone --single-branch --branch $(DOCKER_KONG_VERSION) https://github.com/Kong/docker-kong.git docker-kong
	cp package/*.$(PACKAGE_EXTENSION) ./docker-kong/kong.$(PACKAGE_EXTENSION)
	docker pull --platform=linux/$(ARCHITECTURE) ${OPERATING_SYSTEM}:${OPERATING_SYSTEM_VERSION}
	sed -i.bak "s|^FROM .*|FROM --platform=linux/$(ARCHITECTURE) ${OPERATING_SYSTEM}:${OPERATING_SYSTEM_VERSION}|" docker-kong/Dockerfile.$(PACKAGE_TYPE)
	cd docker-kong && \
	docker image inspect -f '{{.ID}}' kong-$(ARCHITECTURE)-$(PACKAGE_TYPE) || \
	ASSET_LOCATION=local DOCKER_TAG_PREFIX=kong-$(ARCHITECTURE) PACKAGE=$(PACKAGE_TYPE) $(MAKE) build_v2
	-rm -rf docker-kong

package/docker/deb: package/deb
	PACKAGE_TYPE=deb OPERATING_SYSTEM=ubuntu OPERATING_SYSTEM_VERSION=18.04 $(MAKE) package/docker

package/docker/apk: package/apk
	PACKAGE_TYPE=apk OPERATING_SYSTEM=alpine OPERATING_SYSTEM_VERSION=3 PACKAGE_EXTENSION=apk.tar.gz $(MAKE) package/docker

package/docker/rpm: package/rpm
	PACKAGE_TYPE=rpm OPERATING_SYSTEM=redhat\/ubi7-minimal OPERATING_SYSTEM_VERSION=7 $(MAKE) package/docker

release/docker/deb: package/deb
	cd $(KONG_BUILD_TOOLS_LOCATION); \
	KONG_SOURCE_LOCATION=$(PWD) PACKAGE_TYPE=deb RESTY_IMAGE_BASE=ubuntu RESTY_IMAGE_TAG=18.04 $(MAKE) release-kong-docker-images

release/docker/apk: package/apk
	cd $(KONG_BUILD_TOOLS_LOCATION); \
	KONG_SOURCE_LOCATION=$(PWD) PACKAGE_TYPE=apk RESTY_IMAGE_BASE=alpine RESTY_IMAGE_TAG=3 $(MAKE) release-kong-docker-images

release/docker/rpm: package/rpm
	cd $(KONG_BUILD_TOOLS_LOCATION); \
	KONG_SOURCE_LOCATION=$(PWD) PACKAGE_TYPE=rpm RESTY_IMAGE_BASE=rhel RESTY_IMAGE_TAG=7 $(MAKE) release-kong-docker-images

release/package: package/$(PACKAGE_TYPE)
	mv ./package/*.$(PACKAGE_EXTENSION) ./package/kong-$(KONG_VERSION)-.$(ARCHITECTURE)
	docker run \
    -e PULP_HOST=$(PULP_HOST) \
    -e PULP_USERNAME=$(PULP_USERNAME) \
    -e PULP_PASSWORD=$(PULP_PASSWORD) \
    -v "$(PWD)/package:/files:ro" \
    -i kong/release-script \
		--package-type gateway \
        --file "/files/"`ls ./package` \
        --dist-name "$(OPERATING_SYSTEM)" \
		--dist-version $(OPERATING_SYSTEM_VERSION) \
        --major-version $(firstword $(subst ., ,$(KONG_VERSION))).x \
        --publish

setup-kong-build-tools:
	-git submodule update --init --recursive
	-git submodule status
	-rm -rf $(KONG_BUILD_TOOLS_LOCATION)
	-git clone https://github.com/colinh-kong/kong-build-tools.git --recursive $(KONG_BUILD_TOOLS_LOCATION)
	cd $(KONG_BUILD_TOOLS_LOCATION); \
	git reset --hard && git checkout $(KONG_BUILD_TOOLS); \

functional-tests: setup-kong-build-tools
	cd $(KONG_BUILD_TOOLS_LOCATION); \
	$(MAKE) setup-build && \
	$(MAKE) build-kong && \
	$(MAKE) test

install:
	@luarocks make OPENSSL_DIR=$(OPENSSL_DIR) CRYPTO_DIR=$(OPENSSL_DIR)

remove:
	-@luarocks remove kong

dependencies: bin/grpcurl
	@for rock in $(DEV_ROCKS) ; do \
	  if luarocks list --porcelain $$rock | grep -q "installed" ; then \
	    echo $$rock already installed, skipping ; \
	  else \
	    echo $$rock not found, installing via luarocks... ; \
	    luarocks install $$rock OPENSSL_DIR=$(OPENSSL_DIR) CRYPTO_DIR=$(OPENSSL_DIR) || exit 1; \
	  fi \
	done;

bin/grpcurl:
	@curl -s -S -L \
		https://github.com/fullstorydev/grpcurl/releases/download/v$(GRPCURL_VERSION)/grpcurl_$(GRPCURL_VERSION)_$(GRPCURL_OS)_$(GRPCURL_MACHINE).tar.gz | tar xz -C bin;
	@rm bin/LICENSE

dev: remove install dependencies

lint:
	@luacheck -q .
	@!(grep -R -E -I -n -w '#only|#o' spec && echo "#only or #o tag detected") >&2
	@!(grep -R -E -I -n -- '---\s+ONLY' t && echo "--- ONLY block detected") >&2

test:
	@$(TEST_CMD) spec/01-unit

test-integration:
	@$(TEST_CMD) spec/02-integration

test-plugins:
	@$(TEST_CMD) spec/03-plugins

test-all:
	@$(TEST_CMD) spec/

pdk-phase-checks:
	rm -f t/phase_checks.stats
	rm -f t/phase_checks.report
	PDK_PHASE_CHECKS_LUACOV=1 prove -I. t/01*/*/00-phase*.t
	luacov -c t/phase_checks.luacov
	grep "ngx\\." t/phase_checks.report
	grep "check_" t/phase_checks.report

fix-windows:
	@for script in $(WIN_SCRIPTS) ; do \
	  echo Converting Windows file $$script ; \
	  mv $$script $$script.win ; \
	  tr -d '\015' <$$script.win >$$script ; \
	  rm $$script.win ; \
	  chmod 0755 $$script ; \
	done;
