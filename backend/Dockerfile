# Build: docker build -t tarkd backend/
# The image holds one static binary and nothing else, running as non-root.
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/tarkd ./cmd/tarkd

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/tarkd /tarkd
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/tarkd"]
CMD ["serve"]
