# Gunicorn configuration for the Cloudflare Containers web tier.
# The container is only reachable through the Worker, so binding all interfaces is safe.
import multiprocessing
import os

bind = f"0.0.0.0:{os.environ.get('PORT', '8001')}"

# Container memory is billed as provisioned, around the clock, so the web tier is
# sized to fit a 3 GiB instance next to Postgres, Redis and rqworker. Each NetBox
# worker (with the plugins) is about 450 MB unshared; two workers with four
# threads each are plenty for an internal tool. Override with GUNICORN_WORKERS.
workers = int(os.environ.get('GUNICORN_WORKERS', min(2, multiprocessing.cpu_count() * 2 + 1)))
threads = int(os.environ.get('GUNICORN_THREADS', 4))

# Import NetBox once in the master and fork the workers from it, so the code and
# module state are shared copy-on-write instead of loaded per worker.
preload_app = True

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


def pre_fork(server, worker):
    # Runs in the master before each fork. A database connection opened while
    # preloading (NetBox reads its config revision at startup) must not be
    # inherited by the workers. Freezing the GC keeps collections in the workers
    # from writing to, and so un-sharing, the preloaded objects.
    import gc
    from django.db import connections
    connections.close_all()
    gc.freeze()
