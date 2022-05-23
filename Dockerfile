FROM alpine:3.20

# Install base tools from stable repos
RUN apk add --no-cache \
	bash \
	openssl \
	ca-certificates \
	bind-tools \
	netcat-openbsd \
	coreutils \
	jq

# Install swaks from edge/testing
RUN apk add --no-cache \
	--repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing \
	swaks

# Create non-root user and group
RUN addgroup -S octomailtest && adduser -S octomailtest -G octomailtest

# App directory
WORKDIR /app/octomailtest

# Copy scripts
COPY src/mail mail
COPY src/imap imap
COPY docker/entrypoint.sh entrypoint.sh

# Permissions
RUN chmod +x mail imap entrypoint.sh \
	&& chown -R octomailtest:octomailtest /app/octomailtest

# Switch to non-root user
USER octomailtest

ENTRYPOINT ["./entrypoint.sh"]
