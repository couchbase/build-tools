import logging
import os
from contextlib import contextmanager
from subprocess import DEVNULL, CalledProcessError, check_output, run
from typing import Generator

logger = logging.getLogger(__name__)
repos = {}


@contextmanager
def chdir(path: str) -> Generator[None, None, None]:
    logger.debug(f"Changing directory to {path}")
    original_path = os.getcwd()
    try:
        os.chdir(path)
        yield
    finally:
        logger.debug(f"Changing directory back to {original_path}")
        os.chdir(original_path)


def repo(repo: str, branch: str = None) -> 'Repo':
    logger.debug(f"Getting repo instance for {repo} (branch: {branch})")
    if repo not in repos:
        logger.debug(f"Creating new repo instance for {repo}")
        repos[repo] = Repo(repo, branch)
    return repos[repo]


class Repo:
    def __init__(self, repo: str, branch: str = None) -> None:
        logger.debug(f"Initializing repo {repo} with branch {branch}")
        self.repo = repo
        self.local_path = f"repos/{repo.split('/')[-1]}"
        logger.debug(f"Local path set to {self.local_path}")
        self.clone()
        if branch:
            logger.debug(f"Checking out initial branch {branch}")
            self.checkout(branch)

    def __str__(self):
        return self.repo

    def clone(self) -> None:
        logger.debug(f"Cloning/syncing repository {self.repo}")
        try:
            # Find repo root
            repo_root = check_output(["git", "rev-parse", "--show-toplevel"], stderr=DEVNULL).strip().decode('utf-8')
            logger.debug(f"Found git repository root at: {repo_root}")

            clean_git_clone = os.path.join(repo_root, "utilities", "clean_git_clone")

            if not os.path.exists(clean_git_clone):
                raise FileNotFoundError(f"Could not find {script_name} script at {clean_git_clone}")

            run([clean_git_clone,
                f"ssh://github.com/{self.repo}"],
                cwd="repos/",
                stdout=DEVNULL,
                stderr=DEVNULL)
            logger.debug(f"Successfully cloned {self.repo}")
        except Exception as e:
            logger.error(f"Failed to clone repository {self.repo}: {e}")
            raise

    def checkout_timestamp(self, timestamp: str, branch: str = "master") -> None:
        logger.debug(
            f"Checking out {self.repo} at timestamp {timestamp} on branch {branch}")
        try:
            with chdir(self.local_path):
                logger.debug("Resetting repository state")
                run(["git", "reset", "--hard", "HEAD"],
                    stdout=DEVNULL,
                    stderr=DEVNULL)
                run(["git", "clean", "-fd"],
                    stdout=DEVNULL,
                    stderr=DEVNULL)

                logger.debug(f"Finding commit before timestamp {timestamp}")
                sha = check_output(
                    ['git', 'rev-list', '-n', '1', '--before', timestamp, branch],
                    stderr=DEVNULL).strip().decode('utf-8')
                if not sha:
                    logger.warning(f"No commit found before timestamp {timestamp}")
                    return
                logger.debug(f"Found commit SHA {sha}")

                run(["git", "checkout", sha], stderr=DEVNULL)
                return sha
        except CalledProcessError as e:
            logger.error(f"Failed to checkout at timestamp {timestamp}: {e}")
            raise

    def checkout(self, revision: str) -> None:
        logger.debug(f"Checking out revision {revision} on {self.repo}")
        try:
            with chdir(self.local_path):
                logger.debug("Resetting repository state")
                run(["git", "reset", "--hard", "HEAD"],
                    stdout=DEVNULL,
                    stderr=DEVNULL)
                run(["git", "clean", "-fd"],
                    stdout=DEVNULL,
                    stderr=DEVNULL)

                logger.debug(f"Checking out revision {revision}")
                run(["git", "checkout", revision],
                    stdout=DEVNULL,
                    stderr=DEVNULL)
                logger.debug(f"Successfully checked out revision {revision}")
        except CalledProcessError as e:
            logger.error(f"Failed to checkout revision {revision}: {e}")
            raise
