# bend-kube controller image.
#
# Build stage: the pinned Bend (tools/install-bend.sh; its C effect
# interface has no ABI promise, so the compiler version is part of the
# build) and clang compile one example controller to a native binary. Runtime stage: glibc, OpenSSL 3 (loaded
# with dlopen by src/effs/tls.c) and CA roots, running as non-root.
#
#   docker build --build-arg EXAMPLE=mirror -t bend-kube-mirror .

FROM debian:trixie-slim AS build
ARG EXAMPLE=mirror
RUN apt-get update \
 && apt-get install -y --no-install-recommends clang ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
COPY tools/install-bend.sh /tmp/install-bend.sh
RUN /tmp/install-bend.sh
ENV PATH=/root/.bend/bin:$PATH BEND_NO_TELEMETRY=1
WORKDIR /src
COPY src ./src
COPY examples ./examples
COPY LAWS.bend PROOF.bend ./
# The laws gate the image as they gate commits.
RUN bend PROOF.bend | tee /tmp/proof && grep -q "ALL PROOFS CHECK" /tmp/proof
RUN mkdir -p /out && cd examples && bend $EXAMPLE.bend -o /out/controller

# The TLS and proxy tests (tests/tls.sh) on Linux, the native lane under
# AddressSanitizer and UndefinedBehaviorSanitizer; nothing ships from here:
#   docker build --target tls-test .
FROM build AS tls-test
RUN apt-get update \
 && apt-get install -y --no-install-recommends libclang-rt-dev llvm libssl3t64 openssl python3 perl \
 && rm -rf /var/lib/apt/lists/*
COPY tests ./tests
RUN tests/tls.sh

FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends libssl3t64 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/controller /controller
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/controller"]
