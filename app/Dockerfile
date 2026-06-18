# Multi-stage build: Quote API
# Stage 1: Builder
FROM python:3.12-slim-bookworm AS builder

WORKDIR /build
COPY src/requirements.txt .

# Install dependencies to user site-packages (lighter than virtualenv)
RUN pip install --user --no-cache-dir -r requirements.txt

# Stage 2: Runtime (minimal)
FROM python:3.12-slim-bookworm

# Create non-root user
RUN useradd -m -u 1000 app

# Install curl for K8s probes (minimal)
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

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
