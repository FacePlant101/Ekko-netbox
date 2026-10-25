import uuid
from unittest.mock import Mock, patch

from django.db import DEFAULT_DB_ALIAS, transaction
from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework import status

from core.models import Job
from dcim.models import Site
from extras.branch_guard import acting_origin, enforce_branch_only, get_acting_user, is_write_permitted
from extras.models import CustomField, Tag
from netbox.context import current_request, events_queue
from users.models import User
from utilities.exceptions import AbortRequest
from utilities.request import NetBoxFakeRequest
from utilities.testing import APITestCase

BRANCH_SCHEMA_ALIAS = 'schema_branch_test'

# Simulates an active netbox-branching Branch
active_branch = patch('extras.branch_guard.get_active_branch', return_value=Mock(name='Branch'))


@override_settings(BRANCH_ONLY_USERS=['claude-mcp'])
class IsWritePermittedTestCase(TestCase):

    @classmethod
    def setUpTestData(cls):
        cls.restricted_user = User.objects.create_user(username='claude-mcp')
        cls.other_user = User.objects.create_user(username='alice')

    def test_main_refused(self):
        self.assertFalse(is_write_permitted(self.restricted_user, Site, DEFAULT_DB_ALIAS))

    @active_branch
    def test_branch_permitted(self, _):
        self.assertTrue(is_write_permitted(self.restricted_user, Site, BRANCH_SCHEMA_ALIAS))

    @active_branch
    def test_branch_exempt_model_refused(self, _):
        # Models which don't support branching are written to main even while a branch is active
        self.assertFalse(is_write_permitted(self.restricted_user, CustomField, DEFAULT_DB_ALIAS))

    def test_branch_alias_without_active_branch_refused(self):
        self.assertFalse(is_write_permitted(self.restricted_user, Site, BRANCH_SCHEMA_ALIAS))

    def test_branch_creation_permitted(self):
        branch_model = Mock()
        branch_model._meta.app_label = 'netbox_branching'
        self.assertTrue(is_write_permitted(self.restricted_user, branch_model, DEFAULT_DB_ALIAS))

    def test_other_user_permitted(self):
        self.assertTrue(is_write_permitted(self.other_user, Site, DEFAULT_DB_ALIAS))


@override_settings(BRANCH_ONLY_USERS=['claude-mcp'])
class BranchGuardSignalTestCase(TestCase):

    @classmethod
    def setUpTestData(cls):
        cls.site = Site.objects.create(name='Site 1', slug='site-1')
        cls.tag = Tag.objects.create(name='Tag 1', slug='tag-1')
        cls.restricted_user = User.objects.create_user(username='claude-mcp')
        cls.other_user = User.objects.create_user(username='alice')

    def setUp(self):
        self.addCleanup(acting_origin.set, None)
        self.addCleanup(current_request.set, None)
        self.addCleanup(events_queue.set, {})

    def set_user(self, user):
        request = NetBoxFakeRequest({'user': user, 'id': uuid.uuid4()})
        acting_origin.set(request)
        current_request.set(request)

    def test_create_refused(self):
        self.set_user(self.restricted_user)
        with self.assertRaises(AbortRequest):
            with transaction.atomic():
                Site.objects.create(name='Site 2', slug='site-2')
        self.assertFalse(Site.objects.filter(slug='site-2').exists())

    def test_update_refused(self):
        self.set_user(self.restricted_user)
        self.site.description = 'changed'
        with self.assertRaises(AbortRequest):
            with transaction.atomic():
                self.site.save()

    def test_delete_refused(self):
        self.set_user(self.restricted_user)
        with self.assertRaises(AbortRequest):
            with transaction.atomic():
                self.site.delete()
        self.assertTrue(Site.objects.filter(pk=self.site.pk).exists())
        # Events queued by core's pre_delete handler must be discarded
        self.assertEqual(events_queue.get(), {})

    def test_m2m_refused(self):
        self.set_user(self.restricted_user)
        with self.assertRaises(AbortRequest):
            with transaction.atomic():
                self.site.tags.add(self.tag)

    @active_branch
    def test_branch_write_permitted(self, _):
        self.set_user(self.restricted_user)
        enforce_branch_only(Site, BRANCH_SCHEMA_ALIAS)

    def test_merge_by_other_user_permitted(self):
        # netbox-branching's iterative merge replays each change with current_request.user set to the change's
        # author, which must not be mistaken for the user performing the merge.
        self.set_user(self.other_user)
        current_request.set(NetBoxFakeRequest({'user': self.restricted_user, 'id': uuid.uuid4()}))
        Site.objects.create(name='Site 2', slug='site-2')

    def test_job_by_restricted_user_refused(self):
        job = Job.objects.create(name='Merge branch', job_id=uuid.uuid4(), user=self.restricted_user)
        job.start()
        self.assertEqual(get_acting_user(), self.restricted_user)
        with self.assertRaises(AbortRequest):
            with transaction.atomic():
                Site.objects.create(name='Site 2', slug='site-2')
        job.terminate()
        self.assertIsNone(get_acting_user())

    def test_other_user_unaffected(self):
        self.set_user(self.other_user)
        site = Site.objects.create(name='Site 3', slug='site-3')
        site.tags.add(self.tag)
        site.delete()

    def test_no_request_unaffected(self):
        Site.objects.create(name='Site 4', slug='site-4').delete()

    @override_settings(BRANCH_ONLY_USERS=[])
    def test_disabled_by_default(self):
        self.set_user(self.restricted_user)
        Site.objects.create(name='Site 5', slug='site-5').delete()


class BranchGuardAPITestCase(APITestCase):
    model = Site

    def setUp(self):
        super().setUp()
        self.add_permissions('dcim.add_site', 'dcim.delete_site')

    def test_create_in_main(self):
        url = reverse('dcim-api:site-list')
        data = {'name': 'Site 1', 'slug': 'site-1'}

        with override_settings(BRANCH_ONLY_USERS=[self.user.username]):
            response = self.client.post(url, data, format='json', **self.header)
        self.assertHttpStatus(response, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Site.objects.exists())

        with override_settings(BRANCH_ONLY_USERS=['claude-mcp']):
            response = self.client.post(url, data, format='json', **self.header)
        self.assertHttpStatus(response, status.HTTP_201_CREATED)

    def test_delete_in_main(self):
        site = Site.objects.create(name='Site 1', slug='site-1')
        url = reverse('dcim-api:site-detail', kwargs={'pk': site.pk})

        with override_settings(BRANCH_ONLY_USERS=[self.user.username]):
            response = self.client.delete(url, **self.header)
        # The aborted delete leaves the test case's enclosing transaction unusable, so check only the response
        self.assertHttpStatus(response, status.HTTP_400_BAD_REQUEST)
        self.assertIn('within a branch', response.data['detail'])
