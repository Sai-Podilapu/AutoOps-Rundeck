# The reasoning half of AutoOps agents.
#
# Multi-stage: resolve wheels in a builder that carries a compiler, then copy
# the installed tree onto a slim runtime that does not. Several of the
# dependencies here (pydantic-core, tokenizers, and whatever crewai drags in)
# ship platform wheels most of the time and fall back to building from source
# when they do not, and a runtime image carrying gcc for that eventuality is a
# permanently larger attack surface for an occasional convenience.
#
# NOTE ON PINNING: every other Dockerfile in this repo pins its base image by
# digest as well as by tag. The digests are deliberately absent here because
# they must be read from a real `docker pull` — a made-up digest does not
# degrade to the tag, it fails the build outright. Add them with:
#     docker pull python:3.12-slim-bookworm
#     docker inspect --format='{{index .RepoDigests 0}}' python:3.12-slim-bookworm
# and paste the result as `FROM python:3.12-slim-bookworm@sha256:...`.

FROM python:3.12-slim-bookworm AS build

# Kept out of the runtime stage. See the note above.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential=12.9 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Dependencies resolve from pyproject alone, so this layer is cached across
# every change to the agents themselves — which is most changes.
COPY pyproject.toml ./
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install .

COPY agent_runtime ./agent_runtime
RUN /opt/venv/bin/pip install --no-deps .


FROM python:3.12-slim-bookworm

# Non-root, matching every other service here. This process reaches out to
# model vendors and is reached only by agent-service; it needs nothing on the
# filesystem it does not ship with.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin autoops

COPY --from=build --chown=autoops:autoops /opt/venv /opt/venv

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

USER autoops
WORKDIR /home/autoops
EXPOSE 8089

# The healthcheck hits /health, which is unauthenticated precisely so that
# compose can reach it without holding the internal secret. It reports the
# agent registry and the prompt version, so a container that is up but running
# the wrong build is visible from `docker inspect` alone.
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=12 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8089/health', timeout=2).status==200 else 1)"

# One worker per container. The service is stateless, so scaling is horizontal
# and belongs to compose/k8s — and a single worker keeps one slow model call
# from being hidden behind a process pool during an incident.
CMD ["uvicorn", "agent_runtime.app.main:app", \
     "--host", "0.0.0.0", "--port", "8089", \
     "--workers", "1", "--timeout-keep-alive", "65"]
