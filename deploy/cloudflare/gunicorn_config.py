# Gunicorn configuration for the Cloudflare Containers web tier.
# The container is only reachable through the Worker, so binding all interfaces is safe.
import multiprocessing
import os

bind = f"0.0.0.0:{os.environ.get('PORT', '8001')}"

# standard-1 has 4 GiB and half a vCPU; three workers with three threads each is
# plenty and keeps memory around 1.5 GiB. Override with GUNICORN_WORKERS.
workers = int(os.environ.get('GUNICORN_WORKERS', min(3, multiprocessing.cpu_count() * 2 + 1)))
threads = int(os.environ.get('GUNICORN_THREADS', 3))

# Long enough for large exports and bulk imports; the Worker has no shorter limit.
timeout = int(os.environ.get('GUNICORN_TIMEOUT', 120))
graceful_timeout = 30

max_requests = 5000
max_requests_jitter = 500

# Log to stdout/stderr so Workers Logs picks everything up.
accesslog = '-'
errorlog = '-'
loglevel = os.environ.get('GUNICORN_LOG_LEVEL', 'info')

# Trust X-Forwarded-* from the Worker (the only possible client).
forwarded_allow_ips = '*'
