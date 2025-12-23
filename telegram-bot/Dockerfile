FROM python:3.12-slim

WORKDIR /app

# Upgrade pip
RUN pip install --no-cache-dir --upgrade pip

# Requirements
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source
COPY src/ .
COPY tests/ ./tests/

# Timezone data is needed for correct local time scheduling
RUN apt-get update && apt-get install -y tzdata && rm -rf /var/lib/apt/lists/*

CMD ["python", "main.py"]
