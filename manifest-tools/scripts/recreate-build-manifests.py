"""
Program to migrate manifests from the build-team-manifests repository
to the build-manifests repository into a more organized and manageable
format.
"""

import os
import re
import sys

from pathlib import Path
from subprocess import check_call

import dulwich.porcelain

from dulwich.repo import Repo
from lxml import etree


SHERLOCK_RE = re.compile(r'Sherlock build (\d{3,4}) at ')
SUBJECT_RE = re.compile(r'build (\d\.\d\.\d)-(\d{1,4}) at ')
PRIME_RE = re.compile(r'BRANCH set to |[Rr]eset|fake|Stub|Creating|initial')


class BuildManifest:
    """
    For a given Dulwich walker entry, extract everything knowable
    or deducible about the build represented by that commit
    """

    class Ignored(Exception):
        """
        Empty exception class just to mark ignorable manifests
        """
        pass

    @staticmethod
    def create(repo, entry):
        """
        Factory method. Returns None if there is no meaningful
        manifest at the given git entry.
        """
        try:
            return BuildManifest(repo, entry)
        except BuildManifest.Ignored:
            return None

    def __init__(self, repo, entry):
        """ """
        self.repo = repo
        self.entry = entry
        # Doc for values that should exist
        self.manifest_path = None
        self.product = None
        self.release = None
        self.version = None
        self.bld_num = None
        self._introspect_entry()
        self._check_unwanted()
        self._determine_product()
        self._determine_release()
        self._determine_version()
        self._determine_build_num()

    def _introspect_entry(self):
        """
        Loads values deducible from the entry itself
        """
        self.commit = self.entry.commit
        self.commit_msg = self.commit.message.decode('utf-8')
        changes = self.entry.changes()
        if len(changes) == 0:
            # Possibly a merge commit or empty commit; in any case,
            # no more information is available
            raise BuildManifest.Ignored()
        if len(changes) > 1:
            # "Should never happen"
            print("Commit " + str(self.commit.sha().hexdigest())
                  + " has > 1 changes!")
            sys.exit(5)
        change = changes[0]
        self.manifest_path = change.new.path.decode('utf-8')
        self.manifest_text = \
            self.repo.get_object(change.new.sha).as_pretty_string()
        self.manifest = etree.XML(self.manifest_text)
        self.build_element = self.manifest.find("./project[@name='build']")

    def _check_unwanted(self):
        """
        Checks for certain unwanted commits and discards them
        """
        # Commits that exist to "prime the pump" of branch build numbers
        match = PRIME_RE.search(self.commit_msg)
        if match is not None:
            print("UNWANTED: {}".format(self.commit_msg))
            raise BuildManifest.Ignored()

    def _annot_value(self, name):
        """
        Returns the value for the build-project annotation with a given
        name, or None if said annotation doesn't exist (or is an un-
        substituted template @VARIABLE@).
        """
        annot = self.build_element.find("annotation[@name='{}']".format(name))
        if annot is None:
            return None

        value = annot.get("value")
        if value.startswith("@"):
            return None
        else:
            return value

    def _determine_product(self):
        """
        Uses logic and heuristics to compute the product for this build
        """
        # 1. If there's a PRODUCT annotation, trust that
        self.product = self._annot_value("PRODUCT")
        if self.product is not None:
            return

        # 2. If manifest path is in a subdirectory, that directory
        # name is the product
        self.product = os.path.dirname(self.manifest_path)
        if self.product == "":
            # 3. If NOT in a subdirectory, has to be Server
            self.product = "couchbase-server"

    def _determine_release(self):
        """
        Uses logic and heuristics to compute the release for this build
        """
        # 1. If there's a RELEASE annotation, trust that
        self.release = self._annot_value("RELEASE")
        if self.release is None:
            # 2. Otherwise, the basename of the manifest filename
            # is the release
            self.release = os.path.splitext(
                os.path.basename(self.manifest_path)
            )[0]

        if self.release.startswith("toy"):
            raise BuildManifest.Ignored()

    def _determine_version(self):
        """
        Uses logic and heuristics to compute the version for this build
        """
        # 1. If there's a VERSION annotation, trust that
        self.version = self._annot_value("VERSION")
        if self.version is not None:
            return

        # 2. Look for X.Y.Z-BBBB in commit message
        match = SUBJECT_RE.search(self.commit_msg)
        if match is not None:
            self.version = match.group(1)
            self._subj_bld_num = match.group(2)
            return

        # 3. Look for old-skool Sherlock commit message
        match = SHERLOCK_RE.search(self.commit_msg)
        if match is not None:
            self.version = "4.0.0"
            self._subj_bld_num = match.group(1)
            return

        # 4. Probably a commit we can ignore
        raise BuildManifest.Ignored()

    def _determine_build_num(self):
        """
        Uses logic and heuristics to compute the build number for this build
        """
        # 1. If there's a BLD_NUM annotation, trust that
        self.bld_num = self._annot_value("BLD_NUM")
        if self.bld_num is not None:
            return

        # 2. If we computed one from the subject line earlier, use that
        self.bld_num = getattr(self, '_subj_bld_num', None)

        # 3. If neither works, something is quite wrong - fail so someone
        # can investigate
        if self.bld_num is None:
            print("Could not find build number for {}!".format(
                self.commit_msg
            ))
            sys.exit(5)

    def _insert_annot(self, name, value):
        annot = etree.Element("annotation")
        annot.set("name", name)
        annot.set("value", value)
        annot.tail = "\n    "
        self.build_element.append(annot)

    def __str__(self):
        """
        Simple string representation of this build manifest
        """
        return self.manifest_path + " -> " + self.new_commit_msg()

    def fix_annots(self):
        """
        Removes any annotations from the "build" project in the manifest,
        and inserts PRODUCT, RELEASE, VERSION, and BLD_NUM attributes based on
        earlier introspection
        """
        for annot in self.build_element:
            if annot.tag != "annotation":
                continue
            self.build_element.remove(annot)
        self._insert_annot("PRODUCT", self.product)
        self._insert_annot("RELEASE", self.release)
        self._insert_annot("VERSION", self.version)
        self._insert_annot("BLD_NUM", self.bld_num)
        self.manifest_text = etree.tounicode(self.manifest)

    def new_commit_msg(self):
        """
        Returns the commit message for the newly-created build manifest.
        """
        return "{} {} build {}-{}".format(
            self.product, self.release, self.version, self.bld_num
        )

    def commit_self(self, repo):
        """
        Given a Dulwich repo, writes the .xml manifest with the appropriate
        name and in the appropriate subdirectories based on product,
        release, and version, and then commits this with a consistent
        commit message.
        """
        output_dir = os.path.join(self.product, self.release)
        if not os.path.exists(output_dir):
            os.makedirs(output_dir)
        output_file = os.path.join(output_dir, "{}.xml".format(self.version))
        with open(output_file, 'wb') as out:
            out.write(self.manifest_text.encode('utf-8'))
        repo.stage(output_file)
        repo.do_commit(
            message=self.new_commit_msg().encode('utf-8'),
            committer=self.commit.committer,
            author=self.commit.author,
            commit_timestamp=self.commit.commit_time,
            commit_timezone=self.commit.commit_timezone
        )


def checkout(path, url, bare=True):
    """
    Either clones a new git repo from URL into path (if it didn't already
    exist), or else fetches new content from URL into repo at path (if it
    did already exist). In either case returns a Dulwich Repo object on
    path.
    """
    abspath = Path(path).resolve()
    cfgpath = abspath / ("config" if bare else ".git/config")
    abspath = str(abspath)
    if cfgpath.exists():
        print("Fetching {}".format(url))
        # QQQ Dulwich fetch() is broken
        # dulwich.porcelain.fetch(abspath, url)
        check_call(['git', 'fetch', '--all'], cwd=path)
    else:
        print("Cloning {}".format(url))
        dulwich.porcelain.clone(url, target=abspath, bare=bare)
    return Repo(abspath)


def main():
    # Paths for old and new repositories
    btm_dir = "build-team-manifests"
    bm_dir = "build-manifests"
    btm_url = 'git://github.com/couchbase/build-team-manifests'
    bm_url = 'ssh://git@github.com/couchbase/build-manifests'

    # Walk the new-school repository, forming set of all known builds
    # (for incremental-translation purposes)
    bm_repo = checkout(bm_dir, bm_url, bare=False)
    print("Forming list of known builds")
    # QQQ Can't figure out how to do this in Dulwich
    check_call(['git', 'reset', '--hard', 'origin/master'], cwd=bm_dir)
    # dulwich.porcelain.reset(bm_repo, "hard", bm_master)
    bm_walker = bm_repo.get_walker()
    bm_builds = {x.commit.message.decode('utf-8') for x in bm_walker}

    # Find timestamp of last loaded build - optimization.
    # Since we also prevent duplicate manifests for the same build with the
    # bm_builds index, we subtract one day from this timestamp. That should
    # be more than enough to account for any oddly mis-ordered entries in
    # build-team-manifests.
    # Note: as a special case, if the commit has no parents (as it
    # will if you create a new repository with only a README on GitHub),
    # ignore the timestamp and pull from the beginning of time. This allows
    # this script to bootstrap itself with a new blank repository.
    bm_master = bm_repo.get_object(
        bm_repo.refs[b"refs/remotes/origin/master"]
    )
    if len(bm_master.parents) == 0:
        sincetime = 0
    else:
        sincetime = bm_master.commit_time - 24*60*60

    # Walk the old-school repository
    btm_repo = checkout(btm_dir, btm_url)
    heads = [btm_repo.get_object(btm_repo.refs[x]).id
             for x in btm_repo.refs.keys()
             if x.startswith(b"refs")]
    w = btm_repo.get_walker(
        include=heads,
        exclude=[b"79aaba8ca8700c14709951a1b86ab67b0b12331a"],
        reverse=True,
        since=sincetime
    )

    # For each new build, create a new commit in new-school repository
    print(f"Processing new builds since timestamp {sincetime}...")
    os.chdir(bm_dir)
    for entry in w:
        manifest = BuildManifest.create(btm_repo, entry)
        if manifest is not None:
            # sincetime = manifest.commit.commit_time
            if manifest.new_commit_msg() in bm_builds:
                print("Skipping already-processed build {}".format(
                    manifest.new_commit_msg()
                ))
                continue
            print(str(manifest))
            manifest.fix_annots()
            manifest.commit_self(bm_repo)

    # Push build-manifests up to GitHub
    dulwich.porcelain.push(bm_repo, bm_url, b"refs/heads/master")

    print("Done!")


if __name__ == "__main__":
    main()
