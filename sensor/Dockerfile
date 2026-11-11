FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY focus_device.py .
# Non-root by default; docker-compose maps it to the host user so it can read its key.
USER 10001
CMD ["python", "focus_device.py"]
