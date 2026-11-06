import pathlib,subprocess,tempfile,tarfile,io
p=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    base=pathlib.Path(tmp)/'baseline';base.mkdir()
    archive=subprocess.check_output(['git','archive','e174b5232a0f7e18ed79c25e3e83481de507b0e7'],cwd=p)
    tarfile.open(fileobj=io.BytesIO(archive)).extractall(base)
    for name in ['GeometryTests','DipGeometryTests','SecondTierPolicyTests']:
        results=[]
        for label,root in [('baseline',base),('current',p)]:
            binary=pathlib.Path(tmp)/(label+name)
            subprocess.run(['xcrun','clang','-Wall','-Wextra','-Werror',str(root/'tools'/(name+'.c')),'-framework','CoreGraphics','-lm','-o',str(binary)],check=True)
            r=subprocess.run([str(binary)],capture_output=True)
            text=(r.stdout+r.stderr).decode(errors='replace')
            (p/'build'/(label+'-'+name+'.log')).write_text(text)
            results.append((r.returncode,text))
            print(label,name,'exit',r.returncode,flush=True)
        assert results[0]==results[1],name+' regression relative to baseline'
        print(('PASS' if results[1][0]==0 else 'KNOWN BASELINE FAILURE (not a passing test):')+' '+name,flush=True)
