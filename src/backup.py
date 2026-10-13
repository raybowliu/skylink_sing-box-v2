"""Private managed backups: integrity, preflight, bounded archive import and opt-in pruning."""
import hashlib,json,os,pathlib,shutil,subprocess,sys,tarfile,tempfile,time
base,backups,conf,binary,action,*args=sys.argv[1:];base=pathlib.Path(base);backups=pathlib.Path(backups);conf=pathlib.Path(conf)
OWNER='SKYBYTE backup v1'
def contained(value):
 p=pathlib.Path(value)
 if p.is_symlink() or p.resolve().parent!=backups.resolve() or not p.is_dir():raise ValueError('Not a managed backup directory')
 return p

def files(root):
 result={}
 for p in root.rglob('*'):
  if p.is_symlink():raise ValueError('Backup contains symlinks')
  if p.is_file() and p.name!='backup-manifest.json':result[str(p.relative_to(root))]=p
 return result

def manifest(root,replace=False):
 contents=files(root)
 if len(contents)>10000:raise ValueError('Too many backup files')
 d={'owner':OWNER,'schema':1,'created_at':int(time.time()),'files':{n:hashlib.sha256(p.read_bytes()).hexdigest() for n,p in contents.items()}}
 target=root/'backup-manifest.json'
 if target.is_symlink():raise ValueError('Manifest symlink')
 if target.exists():
  old=json.loads(target.read_text())
  if not replace or old.get('owner')!=OWNER or old.get('schema')!=1:raise ValueError('Manifest exists or ownership mismatch')
  d['created_at']=old['created_at']
 fd,tmp=tempfile.mkstemp(dir=root)
 with os.fdopen(fd,'w') as f:json.dump(d,f,indent=2);f.flush();os.fsync(f.fileno())
 os.replace(tmp,target)

def verify(root,required=False):
 contents=files(root);p=root/'backup-manifest.json'
 if not p.exists():
  if required:raise ValueError('Archive has no integrity manifest')
  print('Legacy backup: no digest manifest; configuration checks still required',file=sys.stderr);return
 d=json.loads(p.read_text())
 if d.get('owner')!=OWNER or d.get('schema')!=1 or set(d['files'])!=set(contents):raise ValueError('Backup manifest mismatch')
 for n,f in contents.items():
  if hashlib.sha256(f.read_bytes()).hexdigest()!=d['files'][n]:raise ValueError('Backup integrity check failed')

def check(root):
 verify(root)
 for name in ('config/config.json','state.json','sing-box.bin'):
  if not (root/name).is_file():raise ValueError('Incomplete backup')
 json.loads((root/'state.json').read_text())
 paths=[root/'config/config.json']
 paths+=list((root/'users').glob('*/server.json'))
 paths += [root/n for n in ('argo-server.json','warp-gateway.json') if (root/n).exists()]
 for path in paths:
  cfg=json.loads(path.read_text())
  for i in cfg.get('inbounds',[]):
   tls=i.get('tls',{})
   for field,name in (('certificate_path','hy2-backup.crt'),('key_path','hy2-backup.key')):
    if field in tls:
     candidate=root/'config'/name if path==paths[0] else path.parent/('certificate.crt' if field=='certificate_path' else 'private.key')
     if not candidate.is_file():raise ValueError('Backed-up certificate/key missing')
     tls[field]=str(candidate)
  fd,tmp=tempfile.mkstemp(dir=base)
  try:
   with os.fdopen(fd,'w') as f:json.dump(cfg,f)
   r=subprocess.run([binary,'check','-c',tmp],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
   if r.returncode:raise ValueError('Backed-up configuration does not validate')
  finally:os.unlink(tmp)

def managed():
 result=[]
 for p in backups.iterdir():
  if p.is_symlink() or not p.is_dir():continue
  try:
   d=json.loads((p/'backup-manifest.json').read_text())
   if d.get('owner')==OWNER and d.get('schema')==1:result.append((d['created_at'],p))
  except (OSError,ValueError,KeyError):continue
 return [p for _,p in sorted(result,key=lambda t:(t[0],t[1].name),reverse=True)]

if action=='manifest':manifest(pathlib.Path(args[0]))
elif action=='reseal':manifest(contained(args[0]),True)
elif action=='preflight':check(contained(args[0]));print('Backup integrity/configuration preflight passed')
elif action=='list':
 for p in managed():print(p.name+' | '+str(sum(f.stat().st_size for f in files(p).values()))+' bytes | '+str(p))
elif action=='archive':
 root=contained(args[0]);verify(root,True)
 with tarfile.open(args[1],'w:gz') as tar:
  for n,p in files(root).items():tar.add(p,arcname=n,recursive=False)
  tar.add(root/'backup-manifest.json',arcname='backup-manifest.json',recursive=False)
elif action=='import':
 destination=pathlib.Path(tempfile.mkdtemp(prefix='import-',dir=backups));success=False
 try:
  with tarfile.open(args[0],'r:gz') as tar:
   members=tar.getmembers()
   if len(members)>10000 or sum(m.size for m in members)>1024**3:raise ValueError('Archive exceeds limits')
   seen=set()
   for m in members:
    p=pathlib.PurePosixPath(m.name)
    if p.is_absolute() or '..' in p.parts or '\\' in m.name or m.name in seen or not m.isfile():raise ValueError('Unsafe archive entry')
    seen.add(m.name);target=destination/pathlib.Path(*p.parts);target.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    with tar.extractfile(m) as source,open(target,'xb') as out:shutil.copyfileobj(source,out)
    target.chmod(0o700 if m.name=='sing-box.bin' else 0o600)
  verify(destination,True);check(destination);success=True;print(destination)
 finally:
  if not success:shutil.rmtree(destination)
elif action=='prune':
 keep=int(args[0])
 if not 1<=keep<=1000:raise ValueError('Retention requires 1-1000')
 for p in managed()[keep:]:
  print(p)
  if args[1]=='apply':verify(p,True);shutil.rmtree(p)
else:raise ValueError('Unknown backup operation')
