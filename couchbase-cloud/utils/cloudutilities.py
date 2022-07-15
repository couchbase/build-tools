#!/usr/bin/env python3

import boto3
import botocore
import os
import json

class CouchbaseCloud:
    def __init__(self,profile):
        config =json.loads(open("config.json").read())
        self.session = boto3.session.Session(profile_name=profile)
        self.s3=config['s3']
        self.roles=config['roles']

    def assume_role (self, env):
        client = self.session.client('sts')
        return client.assume_role(
            RoleArn=self.roles[env]['ROLE_ARN'],
            RoleSessionName=self.roles[env]['ROLE_SESSION_NAME'],
            DurationSeconds=3600,
            ExternalId=self.roles[env]['EXTERNALID']
        )
    def download_agents (self, credentials):
        s3_resource = self.session.resource('s3',
            aws_access_key_id=credentials['AccessKeyId'],
            aws_secret_access_key=credentials['SecretAccessKey'],
            aws_session_token=credentials['SessionToken']
        )
        for file in self.s3['files']:
            name=os.path.basename(self.s3['files'][file])
            path=self.s3['files'][file]
            try:
                s3_resource.Bucket(self.s3['bucket']).download_file(path, name)
            except botocore.exceptions.ClientError as e:
                if e.response['Error']['Code'] == "404":
                    print("The object does not exist.")
                else:
                    raise

if __name__ == "__main__":
    couchbasecloud=CouchbaseCloud('CBROBOT')
    assumed_role_object=couchbasecloud.assume_role('production')
    credentials=assumed_role_object['Credentials']
    couchbasecloud.download_agents(credentials)
