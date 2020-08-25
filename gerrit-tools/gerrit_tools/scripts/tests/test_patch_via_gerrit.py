import os
import pytest
from gerrit_tools.scripts import patch_via_gerrit
from gerrit_tools.scripts.tests import conftest

def test_check_env_vars():
    source_path = os.getenv('source_path')
    gerrit_url = os.getenv('gerrit_url')
    gerrit_user = os.getenv('gerrit_user')
    gerrit_pass = os.getenv('gerrit_pass')
    if None in [source_path, gerrit_url, gerrit_user, gerrit_pass]:
        pytest.exit("Missing environment variable/s")

def test_cd():
    with patch_via_gerrit.cd("/usr/bin"):
        assert os.getcwd() == "/usr/bin"

class TestGerritPatches:
    source_path = os.getenv('source_path')
    gerrit_patches = patch_via_gerrit.GerritPatches(os.getenv('gerrit_url'), os.getenv('gerrit_user'), os.getenv('gerrit_pass'), source_path)

    def reset(self):
        self.gerrit_patches.seen_reviews = set()
        conftest.reset_checkout()

    def test_rest_get(self):
        # getting via rest API
        assert self.gerrit_patches.rest.get("/changes/?q=owner:self%20status:open")

    def test_get_one_review(self):
        # getting one review
        reviews = self.gerrit_patches.get_reviews([134808], 'review')
        assert list(reviews).sort() == [134808].sort()

    def test_get_two_reviews(self):
        # getting two reviews
        reviews = self.gerrit_patches.get_reviews([134808, 134809], 'review')
        assert list(reviews).sort() == [134808, 134809].sort()

    def test_get_changes_via_review_id(self):
        # getting a change via review id
        changes = self.gerrit_patches.get_changes_via_review_id(134808)
        assert changes[134808].change_id == 'Ic2e7bfd58bd4fcf3be5330338f9376f1a958cf6a'

    def test_get_changes_via_change_id(self):
        # getting a review via a change id
        changes = self.gerrit_patches.get_changes_via_change_id('Ic2e7bfd58bd4fcf3be5330338f9376f1a958cf6a')
        assert list(changes) == [134808]

    def test_get_changes_via_topic_id(self):
        # getting changes via a topic id
        # note: we don't use topics in gerrit, this just tests getting an empty response
        changes = self.gerrit_patches.get_changes_via_topic_id('test')
        assert not changes

    def test_get_open_parents(self):
        # todo: need to do this with a change which has parents too.
        change = self.gerrit_patches.get_open_parents(self.gerrit_patches.get_changes_via_review_id(134808)[134808])
        assert not change

    def test_patch_repo_sync_master_branch(self):
        # applying a single patch on master
        self.reset()
        self.gerrit_patches.patch_repo_sync([134808], 'review')
        assert os.path.exists(f'{self.source_path}/tlm/test/change1')

    def test_patch_repo_sync_madhatter_branch(self):
        # applying a single patch on mad hatter (should not be applied because manifest points at master for that project)
        self.reset()
        self.gerrit_patches.patch_repo_sync([134811], 'review')
        assert not os.path.exists(f'{self.source_path}/tlm/test/change3')

    def test_patch_repo_sync_master_branch_shared_change_id(self):
        # applying a single patch on the master branch, which shares its change_id with a similar change on mad-hatter
        self.reset()
        self.gerrit_patches.patch_repo_sync([134812], 'review')
        assert os.path.exists(f'{self.source_path}/tlm/test/change4a') \
            and not os.path.exists(f'{self.source_path}/tlm/test/change4b')

    def test_patch_repo_sync_mad_hatter_branch_shared_change_id(self):
        # applying a single patch on the mad-hatter branch, which shares its change_id with a similar change on master
        # only master change should apply, as manifest points at master branch for that project
        self.reset()
        self.gerrit_patches.patch_repo_sync([134814], 'review')
        assert os.path.exists(f'{self.source_path}/tlm/test/change4a') \
            and not os.path.exists(f'{self.source_path}/tlm/test/change4b')

    def test_patch_repo_sync_multiple_changes_with_shared_id_by_review_id(self):
        # applying multiple changes, one of which:
        #   applies a change to master
        #   shares its change_id with a change on mad-hatter which should *not* be applied
        #   shared its change_id with a change in geocouch which *should* be applied
        self.reset()
        self.gerrit_patches.patch_repo_sync([134808, 134814], 'review')
        assert os.path.exists(f'{self.source_path}/tlm/test/change1') \
            and os.path.exists(f'{self.source_path}/tlm/test/change4a') \
            and not os.path.exists(f'{self.source_path}/tlm/test/change4b') \
            and os.path.exists(f'{self.source_path}/geocouch/test/change4c')

    def test_patch_repo_sync_multiple_changes_with_shared_id_by_review_id_2(self):
        # applying a single geocouch change which shares a change ID with:
        #   a tlm/master change (which should be applied)
        #   a tlm/mad-hatter change (which should be ignored)
        self.reset()
        self.gerrit_patches.patch_repo_sync([134874], 'review')
        assert  os.path.exists(f'{self.source_path}/tlm/test/change4a') \
            and not os.path.exists(f'{self.source_path}/tlm/test/change4b') \
            and os.path.exists(f'{self.source_path}/geocouch/test/change4c')
