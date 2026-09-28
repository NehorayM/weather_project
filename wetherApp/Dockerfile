FROM python:3.11-slim

RUN useradd -m appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY --chown=appuser:appuser . .

USER appuser

EXPOSE 8000

ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION

CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "3", "main:app"]