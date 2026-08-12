FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod .
COPY *.go .
RUN CGO_ENABLED=0 go build -o /game-engine .

FROM gcr.io/distroless/static-debian12
COPY --from=builder /game-engine /game-engine
ENTRYPOINT ["/game-engine"]
