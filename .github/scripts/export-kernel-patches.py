#!/usr/bin/env python3
"""Export retained CachyOS commits as patches for a kernel.org release.

Read exclusions from patches/cachyos/rules and write patches and their series
under patches/cachyos/. Check Pond's patches/series after exporting.
Patch application uses a scratch index, leaving the source checkout unchanged.

Usage:
    export-kernel-patches.py --git-dir <CachyOS/linux clone> --tag cachyos-7.3.4-1 \
        --package-dir linux-pond [--report report.md]

Exit status 1 indicates an error or a result requiring review.
"""
import argparse
import collections
import fnmatch
import os
import pathlib
import re
import subprocess
import sys
import tempfile

CACHYOS = pathlib.Path('patches/cachyos')
POND = pathlib.Path('patches')


def die(message):
    sys.exit('error: ' + message)


class Repo:
    def __init__(self, git_dir, scratch):
        self.git_dir = git_dir
        # Use a private index; Git still needs a work-tree path for index updates.
        self.env = dict(os.environ, GIT_INDEX_FILE=os.path.join(scratch, 'index'),
                        GIT_WORK_TREE=scratch, GIT_TERMINAL_PROMPT='0')

    def run(self, *args, data=None):
        return subprocess.run(['git', '--git-dir=' + self.git_dir, *args],
                              input=data, capture_output=True, env=self.env)

    def raw(self, *args, data=None):
        result = self.run(*args, data=data)
        if result.returncode:
            die('git %s: %s' % (' '.join(args[:3]), result.stderr.decode(errors='replace')[:800]))
        return result.stdout

    def text(self, *args):
        return self.raw(*args).decode(errors='replace').strip()


def parse_rules(path):
    """Read branch and subject rules; a missing file means no exclusions."""
    rules = []
    if not path.exists():
        return rules
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        kind, _, value = line.partition(' ')
        value = value.strip()
        if kind not in ('drop-branch', 'drop', 'keep') or not value:
            die('%s:%d: expected "drop-branch <name>", "drop <glob>" or "keep <glob>"' % (path, number))
        rules.append({'kind': kind, 'value': value, 'hits': 0})
    return rules


def decide(rules, branch, subject):
    """Return the first matching exclusion, unless a keep rule overrides it."""
    dropped_by = None
    for rule in rules:
        if rule['kind'] == 'drop-branch':
            matched = branch == rule['value']
        else:
            matched = fnmatch.fnmatchcase(subject, rule['value'])
        if not matched:
            continue
        rule['hits'] += 1
        if rule['kind'] == 'keep':
            return None
        dropped_by = dropped_by or rule
    return dropped_by


def find_base(repo, head, tag):
    """Find the upstream release on the first-parent chain and verify its version."""
    match = re.fullmatch(r'cachyos-(\d+\.\d+)(?:\.(\d+))?(-rc\d+)?-\d+', tag)
    if not match:
        die('unexpected tag name: ' + tag)
    major, minor, rc = match.groups()
    expected = 'Linux ' + major + ('.' + minor if minor not in (None, '0') else '') + (rc or '')
    for line in repo.text('log', '--first-parent', '--format=%H%x09%s', '-n', '2000', head).splitlines():
        sha, subject = line.split('\t', 1)
        if re.fullmatch(r'Linux \d+\.\d+(\.\d+)?(-rc\d+)?', subject):
            if subject != expected:
                die('%s is built on "%s", expected "%s"' % (tag, subject, expected))
            return sha, subject
    die('no kernel.org release commit found below ' + tag)


def downstream_series(repo, base, head):
    """Preserve topic merge order and commit order within each topic."""
    series = []
    for line in repo.text('rev-list', '--first-parent', '--reverse', '--parents', base + '..' + head).splitlines():
        sha, *parents = line.split()
        subject = repo.text('show', '-s', '--format=%s', sha)
        if len(parents) < 2:
            series.append({'sha': sha, 'branch': 'top', 'subject': subject})
            continue
        named = re.search(r"[Mm]erge branch '(?:[^/']+/)?([^']+)'", subject)
        branch = named.group(1) if named else 'merge'
        for commit in repo.text('rev-list', '--no-merges', '--reverse', '--topo-order', sha + '^1..' + sha).split():
            series.append({'sha': commit, 'branch': branch,
                           'subject': repo.text('show', '-s', '--format=%s', commit)})
    return series


def touch_counts(repo, base, head):
    """Count downstream commits per file, excluding merges."""
    counts = collections.Counter()
    for line in repo.text('log', '--no-merges', '--no-renames', '--format=', '--name-only', base + '..' + head).splitlines():
        if line:
            counts[line] += 1
    return counts


def slug(text, limit):
    return re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-')[:limit].strip('-') or 'patch'


def same_change(old, new):
    """Ignore blob IDs and hunk headers, preserving whitespace in patch contents."""
    def strip(diff):
        return re.sub(rb'(?m)^(index |@@ ).*$', b'', diff)
    return strip(old) == strip(new)


def diff_part(content):
    """Extract the diff after the patch's commit-message header."""
    at = content.find(b'\ndiff --git ')
    return content[at + 1:] if at >= 0 else b''


def apply_commit(repo, commit, head, touches):
    """Apply a commit; return (state, conflicting_paths, applied_diff)."""
    own = repo.raw('diff', '--binary', '--full-index', '--no-renames', commit + '^1', commit)
    if not own.strip():
        return 'empty', [], b''
    before = repo.text('write-tree')

    def applied(state):
        after = repo.text('write-tree')
        return state, [], repo.raw('diff', '--binary', '--abbrev=12', '--no-renames', before, after)

    flags = ['apply', '--cached', '--whitespace=nowarn']
    if repo.run(*flags, data=own).returncode == 0:
        return applied('as-is')
    if repo.run(*flags, '-R', '--check', data=own).returncode == 0:
        return 'upstream', [], b''
    result = repo.run(*flags, '--3way', data=own)
    unmerged = sorted({line.split('\t', 1)[1] for line in repo.text('ls-files', '--unmerged').splitlines()})
    if result.returncode == 0 and not unmerged:
        return applied('adjusted')
    # Use CachyOS's final file only if this is its sole downstream change
    # or it already matches. Otherwise we could import later or dropped commits.
    def final(path):
        return repo.text('ls-tree', head, '--', path).split('\t', 1)[0]

    def current(path):
        return repo.text('ls-tree', before, '--', path).split('\t', 1)[0]

    if unmerged and all(touches[path] == 1 or final(path) == current(path) for path in unmerged):
        for path in unmerged:
            repo.raw('update-index', '--force-remove', '--', path)
            if final(path):
                mode, _, blob = final(path).split()
                repo.raw('update-index', '--add', '--cacheinfo', '%s,%s,%s' % (mode, blob, path))
        if repo.text('write-tree') == before:
            return 'upstream', [], b''
        return applied('merge-fix')
    repo.raw('read-tree', before)
    return 'conflict', unmerged or repo.text('diff', '--name-only', '--no-renames', commit + '^1', commit).splitlines(), b''


def render(repo, entry, diff):
    author, date, body = repo.text('show', '-s', '--format=%an <%ae>%x00%aD%x00%b', entry['sha']).split('\0')
    lines = ['From: ' + author, 'Date: ' + date, 'Subject: ' + entry['subject'],
             'CachyOS-Branch: ' + entry['branch'], '']
    # GNU patch recognizes indented diffs; '#' keeps quoted diffs in the message inert.
    lines += [('# ' + line).rstrip() for line in body.strip().splitlines()]
    return ('\n'.join(lines).rstrip('\n') + '\n---\n').encode() + diff


def self_test():
    rules = [{'kind': 'drop-branch', 'value': 't2', 'hits': 0},
             {'kind': 'keep', 'value': 'wifi: *', 'hits': 0},
             {'kind': 'drop', 'value': 'linux*-ADIOS-*', 'hits': 0}]
    assert decide(rules, 't2', 'apple: add a driver')['value'] == 't2'
    assert decide(rules, 't2', 'wifi: brcmfmac: fix') is None
    assert decide(rules, 'cachy', 'linux7.1-rc1-ADIOS-3.2.0')['kind'] == 'drop'
    assert decide(rules, 'cachy', 'Kconfig: Add CONFIG_CACHY') is None
    assert slug('USB: core: sanitize (C0)!', 64) == 'usb-core-sanitize-c0'
    assert diff_part(b'From: x\n---\ndiff --git a/f b/f\n') == b'diff --git a/f b/f\n'
    assert same_change(b'index 1..2\n@@ -1 +1 @@ f()\n-a\n+b\n', b'index 3..4\n@@ -9 +9 @@ g()\n-a\n+b\n')
    assert not same_change(b'@@ -1 +1 @@\n-a\n+b\n', b'@@ -1 +1 @@\n-a\n+\tb\n')
    print('self-test passed')


def main():
    if sys.argv[1:] == ['--self-test']:
        return self_test()
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--git-dir', required=True, help='clone of CachyOS/linux that has the tag')
    parser.add_argument('--tag', required=True, help='for example cachyos-7.3.4-1')
    parser.add_argument('--package-dir', required=True, type=pathlib.Path)
    parser.add_argument('--report', type=pathlib.Path, help='write the Markdown report here (default: stdout)')
    parser.add_argument('--verify-base', metavar='URL',
                        help="kernel.org git URL; fail unless CachyOS's base commit is that repository's release tag")
    args = parser.parse_args()
    package = args.package_dir / CACHYOS
    pond = args.package_dir / POND

    with tempfile.TemporaryDirectory() as scratch:
        repo = Repo(args.git_dir, scratch)
        head = repo.text('rev-parse', '--verify', args.tag + '^{commit}')
        base, base_subject = find_base(repo, head, args.tag)
        if args.verify_base:
            # Verify that the export base matches the kernel.org source used by the build.
            ref = 'refs/tags/v' + base_subject.split()[1] + '^{}'
            listed = subprocess.run(['git', 'ls-remote', args.verify_base, ref], capture_output=True, text=True)
            if listed.returncode or listed.stdout.split()[:1] != [base]:
                die('%s is not %s at %s (got %r)' % (base, ref, args.verify_base, listed.stdout.strip() or listed.stderr.strip()))
        rules = parse_rules(package / 'rules')
        touches = touch_counts(repo, base, head)

        old_names = (package / 'series').read_text().split() if (package / 'series').exists() else []
        old_diffs = {name: diff_part((package / name).read_bytes())
                     for name in old_names if (package / name).exists()}

        repo.raw('read-tree', base)
        names, used = [], set()
        report = collections.defaultdict(list)
        dropped = collections.Counter()
        dropped_files = set()
        for entry in downstream_series(repo, base, head):
            rule = decide(rules, entry['branch'], entry['subject'])
            label = '%s: %s' % (entry['branch'], entry['subject'])
            if rule:
                dropped['%s %s' % (rule['kind'], rule['value'])] += 1
                dropped_files.update(repo.text('diff', '--name-only', '--no-renames',
                                               entry['sha'] + '^1', entry['sha']).splitlines())
                continue
            state, files, diff = apply_commit(repo, entry['sha'], head, touches)
            if state == 'empty':
                continue
            if state == 'upstream':
                report['Already in the plain kernel (left out)'].append(label)
                continue
            if state == 'conflict':
                report['NEEDS ATTENTION: does not apply'].append('%s (%s)' % (label, ', '.join(files)))
                continue
            if b'GIT binary patch' in diff:
                report['NEEDS ATTENTION: binary change, which `patch` cannot apply'].append(label)
            stem = '%s-%s' % (slug(entry['branch'], 20), slug(entry['subject'], 64))
            name, count = stem + '.patch', 1
            while name in used:
                count += 1
                name = '%s-%d.patch' % (stem, count)
            used.add(name)
            names.append(name)
            if state == 'adjusted':
                report['Line context adjusted to apply (same change)'].append(label)
            elif state == 'merge-fix':
                report["Uses CachyOS's merged version of a file"].append(label)
            if name not in old_diffs:
                report['New'].append(label)
            elif not same_change(old_diffs[name], diff):
                report['Changed'].append(label)
            else:
                continue  # Avoid rewriting files when only diff metadata changed.
            (package / name).write_bytes(render(repo, entry, diff))

        # Files touched by dropped commits may differ; all others must match CachyOS.
        odd = [path for path in repo.text('diff', '--name-only', '--no-renames', repo.text('write-tree'), head).splitlines()
               if path not in dropped_files]
        if odd:
            report["NEEDS ATTENTION: differs from CachyOS's kernel in a file no rule drops"] += odd[:50] + (
                ['... and %d more' % (len(odd) - 50)] if len(odd) > 50 else [])

        for name in old_names:
            if name not in used:
                report['Removed (gone from CachyOS, absorbed by the kernel, or dropped by a rule)'].append(name)
                (package / name).unlink(missing_ok=True)
        (package / 'series').write_text(''.join(name + '\n' for name in names))

        if (pond / 'series').exists():
            for name in (pond / 'series').read_text().split('\n'):
                name = name.strip()
                if name and not name.startswith('#') and repo.run('apply', '--cached', '--whitespace=nowarn',
                                     data=(pond / name).read_bytes()).returncode:
                    report['NEEDS ATTENTION: does not apply'].append('Pond patch ' + name)

    out = ['### CachyOS kernel patches: `%s`' % args.tag, '',
           '- Plain kernel: %s (`%s`)' % (base_subject, base[:12]),
           '- CachyOS tag commit: `%s`' % head[:12],
           '- Kept: %d patch files. Dropped by rule: %d commits.' % (len(names), sum(dropped.values())), '']
    for title in sorted(report, key=lambda t: (not t.startswith('NEEDS'), t)):
        out += ['**%s**' % title, ''] + ['- ' + item for item in report[title]] + ['']
    if dropped:
        out += ['**Dropped by rule**', ''] + ['- `%s`: %d' % item for item in sorted(dropped.items())] + ['']
    unused = ['- `%s %s`' % (r['kind'], r['value']) for r in rules if not r['hits']]
    if unused:
        out += ['**Rules that matched nothing (renamed or gone upstream?)**', ''] + unused + ['']
    text = '\n'.join(out)
    if args.report:
        args.report.write_text(text)
    else:
        print(text)
    return 1 if any(title.startswith('NEEDS') for title in report) else 0


if __name__ == '__main__':
    sys.exit(main())
