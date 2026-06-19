# Multi-stage build: Quote API
# Stage 1: Builder
FROM python:3.12-alpine AS builder

WORKDIR /build
COPY src/requirements.txt .

# Install dependencies to user site-packages (lighter than virtualenv)
RUN pip install --user --no-cache-dir -r requirements.txt

# Stage 2: Runtime (minimal)
FROM python:3.12-alpine

# Create non-root user
RUN adduser -D -u 1000 app

# Install curl for K8s probes (minimal, Alpine only)
RUN apk add --no-cache curl

# Copy dependencies from builder
COPY --from=builder /root/.local /home/app/.local

# Copy application code
COPY --chown=app:app src/ /app/

WORKDIR /app
USER app

# Set PATH for user packages
ENV PATH=/home/app/.local/bin:$PATH
ENV PYTHONUNBUFFERED=1

EXPOSE 8000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8000/healthz || exit 1

CMD ["python", "app.py"]
