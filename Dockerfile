FROM alpine:3.20

# Install required tools
RUN apk add --no-cache \
	bash \
	openssl \
	ca-certificates \
	bind-tools \
	netcat-openbsd \
	swaks \
	coreutils \
	jq

# Create non-root user and group
RUN addgroup -S octomailtest && adduser -S octomailtest -G octomailtest

# App directory (namespaced)
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
