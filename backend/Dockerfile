# Build: docker build -t tarkd backend/
# The image holds one static binary and nothing else, running as non-root.
#
# Supply chain: both base images are pinned by tag AND digest, so a build always
# gets exactly these bytes. Dependabot (.github/dependabot.yml) proposes updates
# to the tag and the digest together. To refresh by hand:
#   docker buildx imagetools inspect golang:<tag> --format '{{.Manifest.Digest}}'
#   docker buildx imagetools inspect gcr.io/distroless/static-debian12:nonroot --format '{{.Manifest.Digest}}'
# golang must be at least the Go version in go.mod (a newer patch fixes standard
# library vulnerabilities; CI runs govulncheck).
FROM golang:1.27.2@sha256:5bc7f572bbaa98885a3a1fd9c0aa76b59e3e14e8628bfc316bbfd0c701e4818c AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tarkd ./cmd/tarkd
# Empty directories for backups and log files, owned by the runtime user so a
# volume mounted there starts out writable by it.
RUN mkdir -p /out/backups /out/logs && chmod 700 /out/backups /out/logs

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /out/tarkd /tarkd
COPY --from=build --chown=65532:65532 /out/backups /backups
COPY --from=build --chown=65532:65532 /out/logs /logs
USER nonroot:nonroot
EXPOSE 8080
# No shell or curl in this image, so the binary checks itself.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 CMD ["/tarkd", "healthcheck"]
ENTRYPOINT ["/tarkd"]
CMD ["serve"]
