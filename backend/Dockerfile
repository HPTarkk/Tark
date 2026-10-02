# Build: docker build -t tarkd backend/
# The image holds one static binary and nothing else, running as non-root.
#
# Supply chain: the base images are pinned by tag and Dependabot keeps the
# tags current (.github/dependabot.yml). To pin by digest as well, run
#   docker buildx imagetools inspect golang:1.26 --format '{{.Manifest.Digest}}'
#   docker buildx imagetools inspect gcr.io/distroless/static-debian12:nonroot --format '{{.Manifest.Digest}}'
# and write them as `golang:1.26@sha256:...`; Dependabot then updates the
# digests too.
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tarkd ./cmd/tarkd

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/tarkd /tarkd
USER nonroot:nonroot
EXPOSE 8080
# No shell or curl in this image, so the binary checks itself.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 CMD ["/tarkd", "healthcheck"]
ENTRYPOINT ["/tarkd"]
CMD ["serve"]
