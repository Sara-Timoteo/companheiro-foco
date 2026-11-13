# Build stage: compile the C noise analyzer and run its unit tests.
# A failing test stops the build.
FROM python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b AS build
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev make \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY --from=firmware common/ ./
RUN make clean all

FROM python:3.12-slim@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY --from=build /src/libnoise_analyzer.so .
COPY focus_device.py .
# Non-root by default; docker-compose maps it to the host user so it can read its key.
USER 10001
CMD ["python", "focus_device.py"]
