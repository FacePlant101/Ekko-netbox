"""
Restrict the users listed in BRANCH_ONLY_USERS to modifying data within a NetBox Branching branch.

The guard hooks Django's pre_save, pre_delete and m2m_changed signals for every change-logged model, rather than
being expressed as CUSTOM_VALIDATORS/PROTECTION_RULES entries: those must list each model by hand, and custom
validators run only on clean(), so they do not see every save. A write by a restricted user is permitted only when
a branch is active *and* the write is routed to a branch schema. Checking the database alias as well as the active
branch also refuses changes to models which netbox-branching exempts from branching (e.g. custom fields or event
rules); these are always written to main, even while a branch is active.

The acting user is taken from the HTTP request or background job which initiated the change, not from
current_request: netbox-branching's iterative merge strategy replays each change with current_request.user set to
the change's original author, so a merge performed by another user must not be attributed to a restricted user.
"""
from contextlib import contextmanager
from contextvars import ContextVar

from django.conf import settings
from django.db import DEFAULT_DB_ALIAS
from django.db.models.signals import m2m_changed, pre_delete, pre_save
from django.dispatch import receiver
from django.utils.translation import gettext as _

from core.signals import clear_events, job_end, job_start
from netbox.models.features import ChangeLoggingMixin
from netbox.utils import register_request_processor
from utilities.exceptions import AbortRequest

__all__ = (
    'get_acting_user',
    'get_active_branch',
    'is_write_permitted',
)

# Apps whose models restricted users may always modify (e.g. to create a branch)
EXEMPT_APP_LABELS = (
    'netbox_branching',
)

# The HTTP request or Job (both have a `user` attribute) on whose behalf data is being changed
acting_origin = ContextVar('branch_guard_acting_origin', default=None)


@register_request_processor
@contextmanager
def track_request_origin(request):
    token = acting_origin.set(request)
    try:
        yield
    finally:
        acting_origin.reset(token)


@receiver(job_start)
def track_job_origin(sender, **kwargs):
    sender._branch_guard_token = acting_origin.set(sender)


@receiver(job_end)
def untrack_job_origin(sender, **kwargs):
    if token := getattr(sender, '_branch_guard_token', None):
        acting_origin.reset(token)
        del sender._branch_guard_token


def get_acting_user():
    """
    Return the user who initiated the current HTTP request or background job (if any).
    """
    return getattr(acting_origin.get(), 'user', None)


def get_active_branch():
    """
    Return the Branch activated by netbox-branching (if any), or None if the plugin is not installed.
    """
    try:
        from netbox_branching.contextvars import active_branch
    except ImportError:
        return None
    return active_branch.get()


def is_write_permitted(user, model, using):
    """
    Return False if the given user is restricted to branches and writing to `model` on the `using` database alias
    would modify main.
    """
    if getattr(user, 'username', None) not in settings.BRANCH_ONLY_USERS:
        return True
    if model._meta.app_label in EXEMPT_APP_LABELS:
        return True
    return get_active_branch() is not None and using != DEFAULT_DB_ALIAS


def enforce_branch_only(model, using):
    if not settings.BRANCH_ONLY_USERS or not issubclass(model, ChangeLoggingMixin):
        return
    user = get_acting_user()
    if not is_write_permitted(user, model, using):
        # Discard any events already queued by this request (e.g. by core's pre_delete handler, which runs first),
        # since the transaction will be rolled back.
        clear_events.send(sender=enforce_branch_only)
        raise AbortRequest(
            _("User {user} may only modify data within a branch. Activate a branch to change this {model}.").format(
                user=user.username,
                model=model._meta.verbose_name
            )
        )


@receiver(pre_save)
def branch_guard_save(sender, instance, using, **kwargs):
    enforce_branch_only(sender, using)


@receiver(pre_delete)
def branch_guard_delete(sender, instance, using, **kwargs):
    enforce_branch_only(sender, using)


@receiver(m2m_changed)
def branch_guard_m2m(sender, instance, action, using, **kwargs):
    if action in ('pre_add', 'pre_remove', 'pre_clear'):
        enforce_branch_only(type(instance), using)
