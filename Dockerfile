# syntax=docker/dockerfile:1.4

ARG PACKAGE_TYPE=deb
ARG ARCHITECTURE=amd64
ARG TEST_OPERATING_SYSTEM=ubuntu:22.04

# List out all image permutation to trick dependabot
FROM --platform=linux/amd64 ghcr.io/kong/kong-runtime:1.1.7-x86_64-linux-gnu as amd64-deb
FROM --platform=linux/amd64 ghcr.io/kong/kong-runtime:1.1.7-x86_64-linux-gnu as amd64-rpm
FROM --platform=linux/amd64 ghcr.io/kong/kong-runtime:1.1.7-x86_64-linux-musl as amd64-apk
FROM --platform=linux/arm64 ghcr.io/kong/kong-runtime:1.1.7-aarch64-linux-gnu as arm64-deb
FROM --platform=linux/arm64 ghcr.io/kong/kong-runtime:1.1.7-aarch64-linux-gnu as arm64-rpm
FROM --platform=linux/arm64 ghcr.io/kong/kong-runtime:1.1.7-aarch64-linux-musl as arm64-apk


FROM $ARCHITECTURE-$PACKAGE_TYPE as build

COPY . /kong
WORKDIR /kong

# Run our predecessor tests
# Configure, build, and install
RUN /test/*/test.sh && \
    ./install-kong.sh


FROM $TEST_OPERATING_SYSTEM as test

COPY --from=build /tmp/build /tmp/build
COPY --from=build /test /test
COPY ./install-test.sh /test/kong/test.sh
USER root
RUN /test/*/test.sh


# Use FPM to change the contents of /tmp/build into a deb / rpm / apk.tar.gz
FROM kong/fpm:0.5.1 as fpm

COPY --from=test /tmp/build /tmp/build
COPY --link /fpm /fpm

# Keep sync'd with the fpm/package.sh variables
ARG PACKAGE_TYPE=deb
ENV PACKAGE_TYPE=${PACKAGE_TYPE}

ARG KONG_VERSION=3.0.1
ENV KONG_VERSION=${KONG_VERSION}

ARG OPERATING_SYSTEM=ubuntu
ENV OPERATING_SYSTEM=${OPERATING_SYSTEM}

ARG OPERATING_SYSTEM_VERSION="22.04"
ENV OPERATING_SYSTEM_VERSION=${OPERATING_SYSTEM_VERSION}

ARG ARCHITECTURE=amd64
ENV ARCHITECTURE=${ARCHITECTURE}

WORKDIR /fpm
RUN ./package.sh


# Drop the fpm results into scratch so buildx can export it
FROM scratch as package

COPY --from=fpm /output/* /
