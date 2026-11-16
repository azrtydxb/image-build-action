# Tiny multi-arch test image. Every RUN runs on the build host ($BUILDPLATFORM) and the target
# stage has none, so no arch needs emulation.
FROM --platform=$BUILDPLATFORM docker.io/library/golang:1.25-alpine AS build
ARG TARGETOS
ARG TARGETARCH
ARG MSG=none
WORKDIR /src
COPY main.go .
RUN --mount=type=secret,id=tok test "$(cat /run/secrets/tok)" = s3cr3t
RUN --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -ldflags "-X main.msg=$MSG" -o /out/hello main.go

FROM docker.io/library/busybox:1.37
COPY --from=build /out/hello /hello
ENTRYPOINT ["/hello"]
