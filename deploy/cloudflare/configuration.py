"""
NetBox configuration for the Cloudflare Containers deployment.

Every value is read from environment variables so the same image can run as the
web tier, the RQ worker, or a one-off management command. The Worker forwards
Cloudflare secrets into the container's environment at start.

See deploy/cloudflare/PLAN.md for the list of variables.
"""

import os
from urllib.parse import unquote, urlparse

from netbox_branching.utilities import DynamicSchemaDict


def _env(name, default=None):
    value = os.environ.get(name)
    return value if value not in (None, '') else default


def _env_bool(name, default=False):
    value = _env(name)
    if value is None:
        return default
    return value.strip().lower() in ('1', 'true', 'yes', 'on')


def _env_int(name, default):
    value = _env(name)
    return int(value) if value is not None else default


def _env_list(name, default=None):
    value = _env(name)
    if value is None:
        return list(default or [])
    return [item.strip() for item in value.split(',') if item.strip()]


def _require(name):
    value = _env(name)
    if value is None:
        raise RuntimeError(f'Required environment variable {name} is not set')
    return value


def _redis_from_url(url, default_db):
    """
    Translate redis://user:pass@host:port/db or rediss://... into NetBox's REDIS section format.
    """
    parsed = urlparse(url)
    if parsed.scheme not in ('redis', 'rediss'):
        raise RuntimeError(f'Unsupported Redis URL scheme {parsed.scheme!r}')
    database = default_db
    if parsed.path and parsed.path.strip('/'):
        database = int(parsed.path.strip('/'))
    return {
        'HOST': parsed.hostname or 'localhost',
        'PORT': parsed.port or 6379,
        'USERNAME': unquote(parsed.username) if parsed.username else '',
        'PASSWORD': unquote(parsed.password) if parsed.password else '',
        'DATABASE': database,
        'SSL': parsed.scheme == 'rediss',
        'INSECURE_SKIP_TLS_VERIFY': _env_bool('REDIS_INSECURE_SKIP_TLS_VERIFY', False),
    }


def _redis_from_parts(prefix, default_db):
    return {
        'HOST': _env(f'{prefix}_HOST', 'localhost'),
        'PORT': _env_int(f'{prefix}_PORT', 6379),
        'USERNAME': _env(f'{prefix}_USERNAME', ''),
        'PASSWORD': _env(f'{prefix}_PASSWORD', ''),
        'DATABASE': _env_int(f'{prefix}_DATABASE', default_db),
        'SSL': _env_bool(f'{prefix}_SSL', False),
        'INSECURE_SKIP_TLS_VERIFY': _env_bool('REDIS_INSECURE_SKIP_TLS_VERIFY', False),
    }


def _redis_section(url_var, prefix, default_db):
    url = _env(url_var)
    if url:
        return _redis_from_url(url, default_db)
    return _redis_from_parts(prefix, default_db)


#########################
#                       #
#   Required settings   #
#                       #
#########################

# The Worker is the only client that can reach the container, and Django validates
# the forwarded Host header against this list. Supply the public hostname(s).
ALLOWED_HOSTS = _env_list('ALLOWED_HOSTS', ['*'])

# PostgreSQL. Either DATABASE_URL (postgres://user:pass@host:5432/dbname?sslmode=require)
# or the individual DB_* variables.
_database_url = _env('DATABASE_URL')
if _database_url:
    _db = urlparse(_database_url)
    if _db.scheme not in ('postgres', 'postgresql'):
        raise RuntimeError(f'Unsupported DATABASE_URL scheme {_db.scheme!r}')
    _db_options = {}
    for part in _db.query.split('&'):
        if '=' in part:
            key, value = part.split('=', 1)
            _db_options[unquote(key)] = unquote(value)
    DATABASES = DynamicSchemaDict({
        'default': {
            'ENGINE': 'django.db.backends.postgresql',
            'NAME': _db.path.lstrip('/'),
            'USER': unquote(_db.username or ''),
            'PASSWORD': unquote(_db.password or ''),
            'HOST': _db.hostname or 'localhost',
            'PORT': str(_db.port or ''),
            'CONN_MAX_AGE': _env_int('DB_CONN_MAX_AGE', 300),
            'OPTIONS': {'sslmode': _env('DB_SSLMODE', 'require'), **_db_options},
        }
    })
else:
    DATABASES = DynamicSchemaDict({
        'default': {
            'ENGINE': 'django.db.backends.postgresql',
            'NAME': _env('DB_NAME', 'netbox'),
            'USER': _env('DB_USER', 'netbox'),
            'PASSWORD': _env('DB_PASSWORD', ''),
            'HOST': _env('DB_HOST', 'localhost'),
            'PORT': _env('DB_PORT', ''),
            'CONN_MAX_AGE': _env_int('DB_CONN_MAX_AGE', 300),
            'OPTIONS': {'sslmode': _env('DB_SSLMODE', 'require')},
        }
    })

# netbox-branching: DynamicSchemaDict (above) and this router let each request
# use the active branch's PostgreSQL schema. The plugin refuses to start without both.
DATABASE_ROUTERS = [
    'netbox_branching.database.BranchAwareRouter',
]

# Redis. Two logical databases: tasks (RQ) and caching. Managed providers such as
# Upstash expose a single DB per instance, so each section accepts its own URL.
REDIS = {
    'tasks': _redis_section('REDIS_TASKS_URL', 'REDIS_TASKS', 0),
    'caching': _redis_section('REDIS_CACHE_URL', 'REDIS_CACHE', 1),
}

SECRET_KEY = _require('SECRET_KEY')

# Optional API token peppers (NetBox 4.5+, required for v2 API tokens).
# API_TOKEN_PEPPERS="1=<pepper>,2=<pepper>"
API_TOKEN_PEPPERS = {}
for _pair in _env_list('API_TOKEN_PEPPERS'):
    _id, _pepper = _pair.split('=', 1)
    API_TOKEN_PEPPERS[int(_id)] = _pepper


#########################
#                       #
#   Optional settings   #
#                       #
#########################

ADMINS = []
ALLOW_TOKEN_RETRIEVAL = _env_bool('ALLOW_TOKEN_RETRIEVAL', False)

# Keep empty; permissions are managed in the UI.
AUTH_PASSWORD_VALIDATORS = [
    {
        'NAME': 'utilities.password_validation.AlphanumericPasswordValidator',
    },
    {
        'NAME': 'django.contrib.auth.password_validation.MinimumLengthValidator',
        'OPTIONS': {
            'min_length': 12,
        }
    },
]

BASE_PATH = _env('BASE_PATH', '')

CORS_ORIGIN_ALLOW_ALL = _env_bool('CORS_ORIGIN_ALLOW_ALL', False)
CORS_ORIGIN_WHITELIST = _env_list('CORS_ORIGIN_WHITELIST')
CORS_ORIGIN_REGEX_WHITELIST = []

# Required because the browser talks to the Worker over HTTPS while the container
# only ever sees plain HTTP. settings.py already honours X-Forwarded-Proto.
CSRF_TRUSTED_ORIGINS = _env_list('CSRF_TRUSTED_ORIGINS')
CSRF_COOKIE_NAME = 'csrftoken'
CSRF_COOKIE_SECURE = _env_bool('COOKIE_SECURE', True)
SESSION_COOKIE_SECURE = _env_bool('COOKIE_SECURE', True)

DEBUG = _env_bool('DEBUG', False)

DEFAULT_LANGUAGE = _env('DEFAULT_LANGUAGE', 'en-us')

EMAIL = {
    'SERVER': _env('EMAIL_SERVER', 'localhost'),
    'PORT': _env_int('EMAIL_PORT', 25),
    'USERNAME': _env('EMAIL_USERNAME', ''),
    'PASSWORD': _env('EMAIL_PASSWORD', ''),
    'USE_SSL': _env_bool('EMAIL_USE_SSL', False),
    'USE_TLS': _env_bool('EMAIL_USE_TLS', False),
    'TIMEOUT': _env_int('EMAIL_TIMEOUT', 10),
    'FROM_EMAIL': _env('EMAIL_FROM', ''),
}

EXEMPT_VIEW_PERMISSIONS = []

INTERNAL_IPS = ('127.0.0.1', '::1')

LOGIN_PERSISTENCE = _env_bool('LOGIN_PERSISTENCE', False)
LOGIN_REQUIRED = _env_bool('LOGIN_REQUIRED', True)
LOGIN_TIMEOUT = None

METRICS_ENABLED = _env_bool('METRICS_ENABLED', False)

# Enabled plugins: the PLUGINS env var when set, otherwise the plugins.txt file
# shipped in the image (one module name per line, '#' comments). The image build
# reads the same file for collectstatic, so there is one list to maintain.
def _plugins_from_file(path='/opt/netbox/plugins.txt'):
    try:
        with open(path) as fh:
            return [line.strip() for line in fh if line.strip() and not line.lstrip().startswith('#')]
    except OSError:
        return []


PLUGINS = _env_list('PLUGINS') or _plugins_from_file()
# netbox-branching must be the last plugin loaded.
if 'netbox_branching' in PLUGINS:
    PLUGINS = [name for name in PLUGINS if name != 'netbox_branching'] + ['netbox_branching']
PLUGINS_CONFIG = {
    'netbox_branching': {
        # Parallel connections used to copy tables and build indexes when a branch
        # is provisioned. The default (4) suits a dedicated multi-core database; this
        # one shares a single vCPU with gunicorn and rqworker.
        'provision_workers': _env_int('BRANCHING_PROVISION_WORKERS', 1),
    },
}

# Remote authentication via a trusted header. Pairs with Cloudflare Access when
# the Worker copies Cf-Access-Authenticated-User-Email into the configured header.
REMOTE_AUTH_ENABLED = _env_bool('REMOTE_AUTH_ENABLED', False)
REMOTE_AUTH_BACKEND = 'netbox.authentication.RemoteUserBackend'
REMOTE_AUTH_HEADER = _env('REMOTE_AUTH_HEADER', 'HTTP_REMOTE_USER')
REMOTE_AUTH_USER_EMAIL = _env('REMOTE_AUTH_USER_EMAIL', 'HTTP_REMOTE_USER_EMAIL')
REMOTE_AUTH_AUTO_CREATE_USER = _env_bool('REMOTE_AUTH_AUTO_CREATE_USER', True)
REMOTE_AUTH_DEFAULT_GROUPS = _env_list('REMOTE_AUTH_DEFAULT_GROUPS')
REMOTE_AUTH_DEFAULT_PERMISSIONS = {}

RELEASE_CHECK_URL = None

RQ_DEFAULT_TIMEOUT = _env_int('RQ_DEFAULT_TIMEOUT', 300)

# Media and custom scripts stay on the container disk (defaults). The all-in-one
# role includes them in every base backup and restores them on start, so no
# object-storage credentials are needed in the container.

TIME_ZONE = _env('TIME_ZONE', 'UTC')

# Short date/time formats
DATE_FORMAT = 'N j, Y'
SHORT_DATE_FORMAT = 'Y-m-d'
TIME_FORMAT = 'g:i a'
SHORT_TIME_FORMAT = 'H:i:s'
DATETIME_FORMAT = 'N j, Y g:i a'
SHORT_DATETIME_FORMAT = 'Y-m-d H:i'
