#!/usr/bin/env python3
"""Disposable real-core account benchmark; all listeners are loopback, no OS mutations."""
import argparse,json,os,pathlib,platform,subprocess,sys,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--engine',required=True);p.add_argument('--counts',default='10,30,50');p.add_argument('--output',required=True);a=p.parse_args()
 engine=pathlib.Path(a.engine).resolve();counts=[int(n) for n in a.counts.split(',')]
 if not engine.is_file() or any(not 1<=n<=100 for n in counts):p.error('Engine file and counts 1-100 required')
 output=pathlib.Path(a.output)
 if output.exists() or output.is_symlink():p.error('Use a new output path')
 os.environ['SING_BOX_BIN']=str(engine);sys.path.insert(0,str(ROOT/'tests'))
 import test_manager as fixtures
 results=[]
 for count in counts:
  fixture=fixtures.ManagerTest();fixture.setUp();worker=None
  try:
   fixture.user_setup(count,mode='2',real=True)
   for n in range(count):fixture.add_user('bench-'+str(n))
   started=time.monotonic();worker=subprocess.Popen([fixtures.BASH,'-c',fixture.script('users_engine watch')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
   deadline=started+60
   while time.monotonic()<deadline:
    db=fixture.user_db()
    if all(u.get('running') for u in db['users']):break
    if worker.poll() is not None:raise RuntimeError('Supervisor exited during benchmark')
    time.sleep(.1)
   else:raise RuntimeError('Accounts did not become ready')
   ready=time.monotonic()-started;time.sleep(3);db=fixture.user_db();now=time.time()
   pids=[u['pid'] for u in db['users']]+[worker.pid]
   ps=subprocess.check_output(['ps','-o','pid=,rss=,pcpu=','-p',','.join(map(str,pids))],text=True)
   samples=[line.split() for line in ps.splitlines() if line.strip()]
   rss=sum(int(row[1]) for row in samples);cpu=sum(float(row[2]) for row in samples)
   sampled=[now-u['sampled_at'] for u in db['users'] if 'sampled_at' in u]
   pss=[]
   for pid in pids:
    try:
     lines=pathlib.Path('/proc/'+str(pid)+'/smaps_rollup').read_text().splitlines()
     pss.append(int(next(line.split()[1] for line in lines if line.startswith('Pss:'))))
    except (OSError,StopIteration):pass
   row={'pss_mib':round(sum(pss)/1024,3) if len(pss)==len(pids) else None,'accounts':count,'ready_seconds':round(ready,3),'sample_age_max_seconds':round(max(sampled),3),'processes_observed':len(samples),'rss_mib':round(rss/1024,3),'cpu_percent_snapshot':round(cpu,3),'traffic_load':'idle controllers, no client payload'}
   results.append(row);print(json.dumps(row),flush=True)
  finally:
   if worker is not None and worker.poll() is None:
    worker.terminate()
    try:worker.wait(timeout=20)
    except subprocess.TimeoutExpired:worker.kill();worker.wait(timeout=5)
   fixture.doCleanups()
 data={'platform':platform.system()+' '+platform.machine(),'core':subprocess.check_output([str(engine),'version'],text=True).splitlines()[0],'scope':'Real HY2 account cores, loopback-only; idle capacity snapshot, not throughput or billing accuracy','results':results}
 output.parent.mkdir(parents=True,exist_ok=True)
 with open(output,'x') as f:json.dump(data,f,indent=2)
 output.chmod(0o600)
if __name__=='__main__':main()
