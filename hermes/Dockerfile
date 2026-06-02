FROM python:3.11

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
ENV PATH="/root/.local/bin:${PATH}"

RUN pip install --no-cache-dir playwright
RUN playwright install chromium
RUN playwright install-deps chromium

RUN mkdir -p /root/.hermes

WORKDIR /root/.hermes

# Don't run interactive TUI by default - keep container alive for exec
CMD ["tail", "-f", "/dev/null"]