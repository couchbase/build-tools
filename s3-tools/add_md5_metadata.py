#!/usr/bin/env python3.6

# Simple program to take a set of files on AWS S3, download them,
# calculate their MD5 sums, and re-upload them with the sum included
# in their metadata

import hashlib
import os
import sys

import boto3
import botocore.exceptions


def get_md5(filename):
    """
    Generate the MD5 for a given file
    """

    hash_md5 = hashlib.md5()

    with open(filename, 'rb') as fh:
        for chunk in iter(lambda: fh.read(2 ** 20), b''):
            hash_md5.update(chunk)

    return hash_md5.hexdigest()


def add_md5_to_s3(s3_key):
    """
    Download given file from given bucket, calculate its MD5 hash,
    then re-upload it with the MD5 in the metadata
    """

    filename = s3_key.split('/')[-1]

    try:
        s3_bucket.download_file(s3_key, filename)
    except botocore.exceptions.ClientError:
        print(f'  Unable to retrieve {s3_key} from {s3_bucket}')
        return

    md5_hash = get_md5(filename)
    obj = s3.Object(s3_bucket.name, s3_key)

    try:
        obj.upload_file(
            filename,
            ExtraArgs={'ACL': 'public-read', 'Metadata': {'md5': md5_hash}}
        )
    except botocore.exceptions.ClientError:
        print(f'  Unable to upload {filename} to {s3_bucket} at {s3_key}')
        return

    try:
        os.remove(filename)
    except FileNotFoundError:
        pass


if len(sys.argv) != 3:
    print(f'Usage: {sys.argv[0]} <S3 bucket> <S3 base path>')
    sys.exit(1)

s3 = boto3.resource('s3')
s3_bucket = s3.Bucket(sys.argv[1])
s3_base_path = sys.argv[2]

if not s3_base_path.endswith('/'):
    s3_base_path += '/'

for obj in s3_bucket.objects.filter(Prefix=s3_base_path):
    print(f'Updating {obj.key} to have MD5 metadata')
    add_md5_to_s3(obj.key)
