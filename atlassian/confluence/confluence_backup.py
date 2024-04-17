#!/usr/bin/python

'''This script demonstrates how to backup individual pages of a confluence space'''

from atlassian import Confluence
import tarfile
import glob
import argparse
from pathvalidate import sanitize_filename
from requests import HTTPError
import boto3
from botocore.exceptions import ClientError


def create_tar(tar_file, file_ext):
    '''Create a tarball for all the exported pages.
    tar_file: file name of the tarball
    file_ext: extension of files to include in tar
    '''

    tar = tarfile.open(tar_file, "w:gz")
    for f in glob.glob(f'*.{file_ext}'):
        tar.add(f)
    tar.close()
    print(f'Saved tar file {tar_file}')


def save_file(content, filename):
    '''Write content to a file.
    content: input content
    filename: file to write to
    '''
    f = open(f'{filename}', 'wb')
    f.write(content)
    f.close()
    print(f'Completed saving {filename}')


def s3_upload_file(tar_file, bucket):
    '''Upload tarball to s3
    tar_file: Tarball to upload
    bucket: Bucket to upload to
    '''

    object_name = tar_file
    session = boto3.Session(profile_name='cb-build')
    s3_client = session.client('s3')
    try:
        response = s3_client.upload_file(file_name, bucket, object_name)
    except ClientError as e:
        print(e)
        return False
    return True


if __name__ == '__main__':
    parser = argparse.ArgumentParser(
        description="Backup from confluence space CR to S3")
    parser.add_argument(
        '--user',
        type=str,
        required=True,
        help='Confluence user id')
    parser.add_argument(
        '--pat',
        type=str,
        required=True,
        help='Confluence user personal access token')
    parser.add_argument(
        '--export_type',
        type=str,
        choices=['pdf', 'doc'],
        required=True,
        help='Export file format, pdf, or doc')
    parser.add_argument(
        '--space_key',
        type=str,
        default='CR',
        help='Confluence space key')
    parser.add_argument(
        '--s3', default=True, action=argparse.BooleanOptionalAction)
    args = parser.parse_args()

    export_type = args.export_type
    user_id = args.user
    user_pat = args.pat
    spacekey = args.space_key

    bucket_name = 'cr-confluence-backup'
    tar_name = f'confluence_space_{spacekey}_backup_{export_type}.tar.gz'

    # Establish confluence connection session
    confluence = Confluence(
        url='https://hub.internal.couchbase.com/confluence',
        username=user_id,
        password=user_pat)

    cql = f'space.key="{spacekey}" and type="page"'
    space_info = confluence.cql(
        cql,
        limit=99999,
        expand='ancestors')
    total_pages = space_info.get('totalSize')

    for page in space_info.get('results'):
        file_name = sanitize_filename(f"{page['title']}.{export_type}")
        print(f'Getting content of {file_name}')
        if export_type == 'pdf':
            try:
                result = confluence.get_page_as_pdf(page['content']['id'])
            except HTTPError as e:
                print(f'Unable to download {file_name}')
                continue
            else:
                save_file(result, file_name)
        if export_type == 'doc':
            try:
                result = confluence.get_page_as_word(page['content']['id'])
            except HTTPError as e:
                print(f'Unable to download {file_name}')
                continue
            else:
                save_file(result, file_name)

    create_tar(tar_name, export_type)
    if args.s3:
        s3_upload_file(tar_name, bucket_name)
