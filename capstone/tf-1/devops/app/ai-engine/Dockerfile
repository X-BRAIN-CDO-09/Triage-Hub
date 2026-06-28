# Stage 1: Build dependencies
FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Stage 2: Runtime (non-root)
FROM python:3.12-slim AS runtime
WORKDIR /app

# Non-root user (Diagram 1: PSS Restricted)
RUN groupadd -r appgroup && useradd -r -g appgroup -u 1000 appuser

COPY --from=builder /install /usr/local
COPY app ./app

USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/healthz')"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "2"]
