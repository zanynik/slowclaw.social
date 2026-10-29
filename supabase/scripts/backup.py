#!/usr/bin/env python3
"""Export this account's cloud records and checksum-verified original audio. No dependencies."""
import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request


class Cloud:
    def __init__(self, url, key):
        self.url, self.key, self.session, self.expires = url, key, {}, 0

    def request(self, path, payload):
        headers = {'apikey': self.key, 'Content-Type': 'application/json'}
        if self.session:
            headers['Authorization'] = 'Bearer ' + self.session['access_token']
        req = urllib.request.Request(self.url + path, json.dumps(payload).encode(), headers)
        try:
            with urllib.request.urlopen(req, timeout=90) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError('Cloud request failed (HTTP %s); no credentials logged.' % error.code) from None

    def login(self, email, password):
        self.set_session(self.request('/auth/v1/token?grant_type=password', {'email': email, 'password': password}))

    def set_session(self, session):
        self.session, self.expires = session, time.time() + session.get('expires_in', 3600) - 60

    def api(self, **payload):
        if time.time() >= self.expires:
            self.set_session(self.request('/auth/v1/token?grant_type=refresh_token', {'refresh_token': self.session['refresh_token']}))
        return self.request('/functions/v1/cloud-api', payload)


def verified(path, media):
    return path.is_file() and path.stat().st_size == media['bytes'] and hashlib.sha256(path.read_bytes()).hexdigest() == media['sha256']


def backup(cloud, directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    audio = directory / 'audio'
    audio.mkdir(exist_ok=True, mode=0o700)
    manifest = {'format': 'slowclaw-cloud-backup-v1', 'exported_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'entities': {}, 'audio': []}
    partial = directory / 'manifest.partial.json'
    def checkpoint():
        partial.write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        partial.chmod(0o600)
    for entity in ('entries', 'history', 'artifacts', 'media', 'reads', 'units', 'settings', 'usage'):
        rows = []
        for offset in range(0, 200001, 200):
            page = cloud.api(action='export', entity=entity, offset=offset)['rows']
            rows.extend(page)
            if len(page) < 200:
                break
        else:
            raise RuntimeError('Export pagination limit reached; backup is incomplete.')
        manifest['entities'][entity] = rows
        checkpoint()
    deleted = {row['id'] for row in manifest['entities']['entries'] if row.get('deleted_at')}
    for media in manifest['entities']['media']:
        if media['status'] != 'uploaded' or media['entry_id'] in deleted:
            continue
        filename = hashlib.sha256(media['id'].encode()).hexdigest() + '.audio'
        path = audio / filename
        if not verified(path, media):
            signed = cloud.api(action='audio_url', id=media['id'])['signedUrl']
            if urllib.parse.urlparse(signed).netloc != urllib.parse.urlparse(cloud.url).netloc or not signed.startswith('https://'):
                raise RuntimeError('Audio URL does not belong to this project.')
            temp = path.with_suffix('.partial')
            with urllib.request.urlopen(signed, timeout=120) as response, temp.open('wb') as output:
                remaining = int(media['bytes']) + 1
                while remaining:
                    chunk = response.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    output.write(chunk)
                    remaining -= len(chunk)
            temp.chmod(0o600)
            if not verified(temp, media):
                temp.unlink(missing_ok=True)
                raise RuntimeError('Audio checksum or size mismatch; backup is incomplete.')
            temp.replace(path)
        manifest['audio'].append({'media_id': media['id'], 'file': 'audio/' + filename, 'sha256': media['sha256']})
        checkpoint()
    partial.replace(directory / 'manifest.json')
    print('Backup complete: records and %d verified audio files.' % len(manifest['audio']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', required=True)
    parser.add_argument('--directory', required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'https://[a-z0-9-]+\.supabase\.co/?', args.url):
        parser.error('Use the Supabase project HTTPS URL.')
    os.umask(0o077)
    cloud = Cloud(args.url.rstrip('/'), getpass.getpass('Publishable key: '))
    cloud.login(input('Account email: '), getpass.getpass('Account password: '))
    backup(cloud, args.directory.expanduser().resolve())


if __name__ == '__main__':
    main()
