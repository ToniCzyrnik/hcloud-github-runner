#!/usr/bin/env python3
"""Offline behavioral checks. Only copied scripts and owned temporary paths execute."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FAKE = '''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ['FIXTURE'])
a = sys.argv[1:]
with (p/'calls').open('a') as f: f.write(json.dumps(a)+'\\n')
q = json.loads((p/'queue').read_text())
if not q: sys.exit(91)
r = q.pop(0)
(p/'queue').write_text(json.dumps(q))
if r['url'] != a[-1]: sys.exit(92)
if r.get('bounded') and not all(x in a for x in ['--connect-timeout','--max-time','--retry-max-time']): sys.exit(93)
b = json.dumps(r.get('body', {}))
if '-o' in a: pathlib.Path(a[a.index('-o')+1]).write_text(b)
elif '-O' not in a: sys.stdout.write(b + ('\\n'+str(r.get('status',200)) if '-w' in a else ''))
sys.exit(r.get('exit',0))
'''
H = 'https://api.hetzner.cloud/v1/'
G = 'https://api.github.com/repos/example/fixture/actions/runners'

def response(url, body=None, status=200, bounded=True, **kw):
    return dict(url=url, body=body or {}, status=status, bounded=bounded, **kw)

def inventory(runners):
    return response(G+'?per_page=100&page=1', dict(total_count=len(runners), runners=runners))

COUNT = 0

def run(name, queue, inputs=None, ok=True, installer=None, check=None, baseline=False):
    global COUNT
    with tempfile.TemporaryDirectory(prefix='cyclenerd-test-') as tmp:
        p = Path(tmp)
        for f in ['action.sh','install.sh','cloud-init.template.yml','create-server.template.json']:
            shutil.copy2(ROOT/f, p/f)
        if baseline:
            script = 'install.sh' if installer is not None else 'action.sh'
            (p/script).write_bytes(subprocess.check_output(['git','show','94a0a4aa750d832b48cc0f66d24ed56c3fe69448:'+script], cwd=ROOT))
        b = p/'bin'
        b.mkdir()
        # No fallback PATH: unexpected commands cannot reach live executables.
        for cmd in ['bash','python3','basename','dirname','base64','cut','envsubst','jq','cp','grep','cat','uname','gzip','sed','mkdir']:
            target = shutil.which(cmd)
            assert target, cmd
            (b/cmd).symlink_to(target)
        (b/'curl').write_text(FAKE)
        (b/'curl').chmod(0o755)
        (b/'sleep').write_text('#!/usr/bin/env bash\nexit 0\n')
        (b/'sleep').chmod(0o755)
        (b/'tar').write_text('#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p bin\nprintf "#!/usr/bin/env bash\\nexit 0\\n" > bin/installdependencies.sh\nchmod +x bin/installdependencies.sh\n')
        (b/'tar').chmod(0o755)
        target = shutil.which('chmod')
        assert target
        (b/'chmod').symlink_to(target)
        (p/'queue').write_text(json.dumps(queue))
        env = dict(PATH=str(b), FIXTURE=tmp, HOME=tmp, INPUT_GITHUB_TOKEN='fake-github', INPUT_HCLOUD_TOKEN='fake-cloud', GITHUB_REPOSITORY='example/fixture', INPUT_MODE='delete', INPUT_NAME='owned', INPUT_SERVER_ID='42', GITHUB_OUTPUT=str(p/'output'), GITHUB_STEP_SUMMARY=str(p/'summary'), INPUT_DELETE_WAIT='0', INPUT_SERVER_WAIT='2', INPUT_RUNNER_WAIT='1')
        env.update(inputs or {})
        cmd = ['bash',str(p/'action.sh')]
        if installer is not None:
            cmd = ['bash',str(p/'install.sh'),'-d',str(p/'runner'),*installer]
        result = subprocess.run(cmd, env=env, cwd=p, capture_output=True, text=True, timeout=15)
        assert (result.returncode == 0) == ok, (name,result.stdout,result.stderr)
        assert json.loads((p/'queue').read_text()) == [], (name,'unused responses',result.stderr)
        if check: check(p,result)
    COUNT += 1
    print('PASS',name)

vm = response(H+'servers/42',dict(action=dict(id=7)))
absent = response(H+'servers/42',dict(error=dict(code='not_found')),404)
runner = dict(name='owned',id=8)
delrunner = response(G+'/8',status=204)
run('normal cleanup',[vm,inventory([runner]),delrunner])
run('both absent',[absent,inventory([])])
run('VM absent runner present',[absent,inventory([runner]),delrunner])
run('runner absent VM accepted',[vm,inventory([])])
for status in [401,403,500,503,404]:
    run('VM unknown '+str(status),[response(H+'servers/42',status=status),inventory([runner]),delrunner],ok=False)
run('VM transport independent registration',[response(H+'servers/42',exit=28),inventory([])],ok=False)
run('registration auth',[vm,response(G+'?per_page=100&page=1',status=401)],ok=False)
run('registration outage',[vm,response(G+'?per_page=100&page=1',status=503)],ok=False)
run('registration delete hidden auth',[vm,inventory([runner]),response(G+'/8',status=404)],ok=False)
run('inventory count mismatch',[vm,response(G+'?per_page=100&page=1',dict(total_count=2,runners=[]))],ok=False)
run('duplicates',[vm,inventory([runner,dict(name='owned',id=9)])],ok=False)
page = [dict(name='other'+str(i),id=100+i) for i in range(100)]
run('pagination',[vm,response(G+'?per_page=100&page=1',dict(total_count=101,runners=page)),response(G+'?per_page=100&page=2',dict(total_count=101,runners=[runner])),delrunner])
run('registration only',[inventory([])],dict(INPUT_REGISTRATION_ONLY='true',INPUT_SERVER_ID=''),check=lambda p,r: 'VM state was not checked or changed.' in (p/'summary').read_text() or (_ for _ in ()).throw(AssertionError()))
for changes in [dict(INPUT_SERVER_ID=''),dict(INPUT_SERVER_ID='0'),dict(INPUT_SERVER_ID='abc'),dict(INPUT_REGISTRATION_ONLY='true'),dict(INPUT_REGISTRATION_ONLY='yes'),dict(INPUT_NAME=''),dict(INPUT_REGISTRATION_ONLY='true',INPUT_SERVER_ID='',INPUT_MODE='create')]:
    run('invalid cleanup '+str(changes),[],changes,ok=False)

create_inputs=dict(INPUT_MODE='create',INPUT_SERVER_ID='',INPUT_PRIVATE_IPV4='10.0.0.7',INPUT_NETWORKS='12',INPUT_FIREWALLS='3,4')
def creation():
    return [response(G+'/registration-token',dict(token='fake-registration'),bounded=False),response(H+'servers',dict(server=dict(id=42)),bounded=False),response(H+'servers/42',dict(server=dict(status='running')),bounded=False)]
def attach():
    return response(H+'servers/42/actions/attach_to_network',dict(action=dict(id=77)),201)
def payload(p,r):
    data=json.loads((p/'create-server.json').read_text())
    assert not data.get('networks')
    assert data['firewalls']==[dict(firewall=3),dict(firewall=4)]
    assert 'server_id=42' in (p/'output').read_text()
    calls=[json.loads(x) for x in (p/'calls').read_text().splitlines()]
    a=next(a for a in calls if a[-1].endswith('attach_to_network'))
    assert json.loads(a[a.index('-d')+1])==dict(network=12,ip='10.0.0.7')
for ip in ['10.0.0.7','10.0.0.8']:
    q=creation()+[attach(),response(H+'actions/77',dict(action=dict(status='success'))),response(H+'servers/42',dict(server=dict(private_net=[dict(network=12,ip=ip)])))]
    if ip.endswith('.7'): q += [response(G,dict(runners=[runner]),bounded=False)]
    run('exact IP '+ip,q,create_inputs,ok=ip.endswith('.7'),check=payload)
run('attach rejection',creation()+[response(H+'servers/42/actions/attach_to_network',status=400)],create_inputs,ok=False)
run('attach action failure',creation()+[attach(),response(H+'actions/77',dict(action=dict(status='error')))],create_inputs,ok=False,check=payload)
run('attach poll timeout',creation()+[attach()]+[response(H+'actions/77',dict(action=dict(status='running')))]*2,create_inputs,ok=False,check=payload)
for extra in [dict(INPUT_PRIVATE_IPV4='010.0.0.7'),dict(INPUT_NETWORKS='12,13'),dict(INPUT_FIREWALLS='0'),dict(INPUT_FIREWALLS='3,')]:
    run('invalid create '+str(extra),[],dict(create_inputs,**extra),ok=False)
run('default create',creation()+[response(G,dict(runners=[runner]),bounded=False)],dict(INPUT_MODE='create'),check=lambda p,r: 'firewalls' not in json.loads((p/'create-server.json').read_text()) or (_ for _ in ()).throw(AssertionError()))
run('installer skip no download',[],installer=['-v','skip'])
url='https://github.com/actions/runner/releases/download/v2.321.0/actions-runner-linux-arm64-2.321.0.tar.gz'
# Architecture follows the local host, just as the installer does.
if os.uname().machine in ['x86_64','amd64']: url=url.replace('arm64','x64')
run('installer explicit',[response(url,bounded=False)],installer=['-v','2.321.0'])
run('installer latest',[response('https://api.github.com/repos/actions/runner/releases/latest',dict(tag_name='v2.321.0'),bounded=False),response(url,bounded=False)],installer=[])
# Baseline bugs: skip falls through to a download, explicit version becomes empty.
def attempted_version(p, version):
    calls = [json.loads(line) for line in (p/'calls').read_text().splitlines()]
    assert len(calls) == 1
    assert '/download/v'+version+'/' in calls[0][-1]

run('baseline skip regression',[],installer=['-v','skip'],ok=False,baseline=True,check=lambda p,r: attempted_version(p,''))
run('baseline explicit regression',[],installer=['-v','2.321.0'],ok=False,baseline=True,check=lambda p,r: attempted_version(p,''))
print(str(COUNT)+' focused checks passed')
