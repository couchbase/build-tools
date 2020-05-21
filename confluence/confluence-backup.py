#!/usr/bin/python
from atlassian import Confluence
import json
import tarfile
import glob
import sys
import os
import argparse
import boto3
from botocore.exceptions import ClientError
from requests import HTTPError

def create_tar(tarfilename):
    tar = tarfile.open(tarfilename, "w:gz")
    for f in glob.glob("*.pdf"):
        tar.add(f)
    tar.close()
    print("Saved tar file ", tarfilename)

def save_file(content, title):
    file_pdf = open(title + ".pdf", 'wb')
    file_pdf.write(content)
    file_pdf.close()
    print("Completed saving ", title)

def get_params():
    parser = argparse.ArgumentParser(description="Backup pages from confluence space CR to S3")
    parser.add_argument('userid', help='Confluence user id')
    parser.add_argument('password', help='Confluence user password')
    return parser.parse_args()

def s3_upload_file(file_name, bucket, object_name=None):
    """
    :param file_name: File to upload
    :param bucket: Bucket to upload to
    :param object_name: S3 object name. If not specified then file_name is used
    :return: True if file was uploaded, else False
    """

    # If S3 object_name was not specified, use file_name
    if object_name is None:
        object_name = os.path.basename(file_name)

    #create session based on keys and credentials in ~/.aws/credentials
    session = boto3.Session(profile_name='cb-build')

    # Upload the file
    s3_client = session.client('s3')
    try:
        response = s3_client.upload_file(file_name, bucket, object_name)
    except ClientError as e:
        print(e)
        return False
    return True


if __name__ == '__main__':
    params=get_params()
    spacekey='CR'
    bucket_name='cr-confluence-backup'
    tar_name='confluence_space_CR_backup.tar.gz'

    #set page_limit used for confluence rest api
    #default is 25 or 50, which is way to low
    page_limit=500

    #Establish confluence connection session
    confluence = Confluence(
        url='https://hub.internal.couchbase.com/confluence',
        username=params.userid,
        password=params.password)

    #filter out pages are not necessary to be backed up
    #7242630 is the page ID of "archived".
    #"Production Build Status" does not return, results in socket timeout
    cql='space.key=' + '"' + spacekey+ '"' + ' and type="page" \
        and title !~ "Build Team Status" and title !~ "buildbot" \
        and title !~ "Production Build Status" and ancestor != 7242630'
    response = confluence.cql(
        cql,
        limit=page_limit,
        expand='ancestors')
    if response.get('totalSize') > page_limit:
        #If total page number is higher than the set limit,
        #rerun the cql with higher limit
        response = confluence.cql(
            cql,
            limit=response.get('totalSize'),
            expand='ancestors')

    for page in response.get('results'):
        print("Getting content of ", page['title'].replace('/', ''))
        response = confluence.get_page_as_pdf(page['content']['id'])

        #Remove "/" if it exist in page title before saving the file
        #else it will cause issue during page creation
        save_file(content=response, title=page['title'].replace('/', ''))

    create_tar(tar_name)
    s3_upload_file(tar_name, bucket_name, object_name=None)
