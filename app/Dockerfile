# Build stage
FROM python:3.11-alpine AS builder

WORKDIR /app

RUN apk add --no-cache gcc musl-dev libffi-dev

COPY requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

# Run stage
FROM python:3.11-alpine

WORKDIR /app

# Copy installed packages from builder stage
COPY --from=builder /root/.local /root/.local
COPY app.py .

ENV PATH=/root/.local/bin:$PATH
ENV PYTHONUNBUFFERED=1

EXPOSE 5000

# Run with Gunicorn (running as root since runAsNonRoot is not allowed)
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]
