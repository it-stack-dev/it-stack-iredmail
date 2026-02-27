# Dockerfile — IT-Stack IREDMAIL wrapper
# Module 09 | Category: communications | Phase: 2
# Base image: iredmail/iredmail:stable

FROM iredmail/iredmail:stable

# Labels
LABEL org.opencontainers.image.title="it-stack-iredmail" \
      org.opencontainers.image.description="iRedMail email server" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-iredmail"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/iredmail/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
