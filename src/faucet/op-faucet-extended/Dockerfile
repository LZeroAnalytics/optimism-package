FROM golang:1.21-alpine as builder

RUN apk add --no-cache make gcc musl-dev linux-headers git jq bash

# Set working directory
WORKDIR /app

# Copy the op-faucet source code from the ethereum-optimism repository
COPY op-faucet/ ./op-faucet/

# Copy our extended files
COPY extended/ ./extended/

# Apply the extensions to the original code
RUN cp -f ./extended/faucet/backend/faucet.go ./op-faucet/faucet/backend/faucet.go && \
    cp -f ./extended/faucet/backend/types/types.go ./op-faucet/faucet/backend/types/types.go && \
    cp -f ./extended/faucet/frontend/faucet.go ./op-faucet/faucet/frontend/faucet.go && \
    cp -f ./extended/op-service/apis/faucet.go ./op-faucet/op-service/apis/faucet.go

# Build the extended op-faucet
WORKDIR /app/op-faucet
RUN go build -o op-faucet ./cmd/main.go

FROM alpine:latest

RUN apk add --no-cache ca-certificates jq curl

COPY --from=builder /app/op-faucet/op-faucet /usr/local/bin/

ENTRYPOINT ["op-faucet"]
