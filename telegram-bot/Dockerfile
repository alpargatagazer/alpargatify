# Multi-stage build for smaller final image
FROM python:3.12-alpine AS builder

WORKDIR /app

# Install build dependencies (needed for compiling Python packages)
RUN apk add --no-cache gcc musl-dev linux-headers

# Copy and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Final stage - smaller runtime image
FROM python:3.12-alpine

WORKDIR /app

# Install only runtime dependencies (tzdata for timezone support)
RUN apk add --no-cache tzdata

# Copy Python packages from builder
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages

# Copy source code and scripts
COPY src/ .
COPY tests/ ./tests/
COPY run_tests.py .

CMD ["python", "main.py"]
