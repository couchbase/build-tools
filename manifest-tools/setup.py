from setuptools import setup

import manifest_tools.version


# Let's add this later
# long_description = open('README.txt').read()


def load_requirements(fname):
    with open(fname, 'r') as reqfile:
        reqs = reqfile.read()

    return list(filter(None, reqs.strip().splitlines()))


REQUIREMENTS = dict()
REQUIREMENTS['install'] = load_requirements('requirements.txt')


setup_args = dict(
    name='manifest_tools',
    version=manifest_tools.version.__version__,
    description='Couchbase Build Team application to migrate build manifests',
    # long_description = long_description,
    author='Couchbase Build and Release Team',
    author_email='build-team@couchbase.com',
    license='Apache License, Version 2.0',
    packages=['manifest_tools', 'manifest_tools.scripts'],
    install_requires=REQUIREMENTS['install'],
    entry_points={
        'console_scripts': [
            'recreate_build_manifests = manifest_tools.scripts.recreate_build_manifests:main',
        ]
    },
    classifiers=[
        'Development Status :: 4 - Beta',
        'Environment :: Console',
        'Intended Audience :: Developers',
        'License :: OSI Approved',
        'Operating System :: MacOS :: MacOS X',
        'Operating System :: POSIX',
        'Programming Language :: Python :: 3.6',
    ]
)

if __name__ == '__main__':
    setup(**setup_args)
