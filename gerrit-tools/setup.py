import fnmatch
import importlib
import os
import re

from setuptools import setup

import gerrit_tools.version


# Let's add this later
# long_description = open('README.txt').read()


def discover_packages(base):
    """
    Discovers all sub-packages for a base package
    Note: does not work with namespaced packages (via pkg_resources
    or similar)
    """

    mod = importlib.import_module(base)
    mod_fname = mod.__file__
    mod_dirname = os.path.normpath(os.path.dirname(mod_fname))

    for root, _dirnames, filenames in os.walk(mod_dirname):
        for _ in fnmatch.filter(filenames, '__init__.py'):
            yield '.'.join(os.path.relpath(root).split(os.sep))


def reqfile_read(fname):
    with open(fname, 'r') as reqfile:
        reqs = reqfile.read()

    return filter(None, reqs.strip().splitlines())


def load_requirements(fname):
    requirements = list()

    for req in reqfile_read(fname):
        if 'git+' in req:
            subdir_re = re.compile(r'&subdirectory=.+$')
            req = '=='.join(
                re.sub(subdir_re, r'', req).rsplit('=')[-1].split('-', 3)[:2]
            )
        if req.startswith('--'):
            continue
        requirements.append(req)

    return requirements


REQUIREMENTS = dict()
REQUIREMENTS['install'] = load_requirements('requirements.txt')


setup_args = dict(
    name='patch_via_gerrit',
    version=gerrit_tools.version.__version__,
    description='Apply patches for Gerrit reviews to a repo sync',
    # long_description = long_description,
    author='Couchbase Build and Release Team',
    author_email='build-team@couchbase.com',
    license='Apache License, Version 2.0',
    packages=list(discover_packages('gerrit_tools')),
    include_package_data=True,
    install_requires=REQUIREMENTS['install'],
    entry_points={
        'console_scripts': [
            'patch_via_gerrit = gerrit_tools.scripts.patch_via_gerrit:main',
        ]
    },
    classifiers=[
        'Development Status :: 4 - Beta',
        'Environment :: Console',
        'Intended Audience :: Developers',
        'License :: OSI Approved',
        'Operating System :: MacOS :: MacOS X',
        'Operating System :: POSIX',
        'Programming Language :: Python :: 2.7',
    ]
)

if __name__ == '__main__':
    setup(**setup_args)
