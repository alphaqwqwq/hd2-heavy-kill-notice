"""Build the Heavy Kill Notice addon.

1. inject src/catalog_gen.lua into src/heavy_kill_notice.lua at --@CATALOG@
2. syntax check the combined chunk with real LuaJIT (lupa)
3. package with HD2ArchiveTool/make_mod.py (fixed GUID -> re-import replaces)
4. verify the produced ZIP (container total + resource hash + manifest)

Usage:  D:\\py\\python.exe build.py
"""
import json
import os
import struct
import subprocess
import sys
import uuid
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'src', 'heavy_kill_notice.lua')
CAT = os.path.join(HERE, 'src', 'catalog_gen.lua')
BUILT = os.path.join(HERE, 'build', 'heavy_kill_notice.built.lua')
NAME = 'mods/heavykill/heavy_kill_notice'
DISPLAY = 'Heavy Kill Notice v1.5.0'
VERSION = '1.5.0'
DIST = os.path.join(HERE, 'dist')
GUID_FILE = os.path.join(HERE, 'guid.txt')
MAKE_MOD = r'D:\SteamLibrary\steamai\HD2ArchiveTool\make_mod.py'
PY = r'D:\py\python.exe'


def guid():
    if os.path.exists(GUID_FILE):
        return open(GUID_FILE).read().strip()
    value = str(uuid.uuid4())
    open(GUID_FILE, 'w').write(value + '\n')
    return value


def combine():
    os.makedirs(os.path.dirname(BUILT), exist_ok=True)
    main = open(SRC, encoding='utf-8').read()
    cat = open(CAT, encoding='utf-8').read().strip()
    assert '--@CATALOG@' in main, 'no --@CATALOG@ marker in source'
    out = main.replace('--@CATALOG@', cat)
    open(BUILT, 'w', encoding='utf-8', newline='\n').write(out)
    return out


def syntax_check(src):
    from lupa import luajit21
    lua = luajit21.LuaRuntime()
    lua.globals().SRC = src
    result = lua.execute(
        "local f,e=loadstring(SRC,'x') return f and ('parse OK, '..#SRC..' bytes') or ('PARSE ERROR: '..tostring(e))")
    print('syntax : %s  (%d lines)' % (result, src.count('\n') + 1))
    if 'ERROR' in str(result):
        sys.exit(1)


def build():
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, 'HeavyKillNotice-v%s.zip' % VERSION)
    if os.path.exists(out):
        os.remove(out)
    cmd = [PY, MAKE_MOD, '--name', NAME, '--guid', guid(), '--entry', BUILT,
           '--output', out, '--display', DISPLAY]
    print('build  : ' + ' '.join(cmd[2:]))
    proc = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8', errors='replace')
    print((proc.stdout or '') + (proc.stderr or ''))
    if proc.returncode != 0:
        sys.exit('make_mod failed')
    return out


def verify(path):
    sys.path.insert(0, r'D:\SteamLibrary\steamai\HD2ArchiveTool')
    from bingus_build import resource_hash
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        blob = None
        for n in names:
            if n.endswith('.patch_0'):
                blob = z.read(n)
                break
        assert blob, 'container missing'
        total = struct.unpack_from('<Q', blob, 0x20)[0]
        stamp = struct.unpack_from('<Q', blob, 0x68)[0]
        want = resource_hash(NAME)
        manifest = json.loads(z.read('manifest.json').decode('utf-8'))
    print('verify : entries=%d  container=%d B  size field %s  hash %s  Guid=%s'
          % (len(names), len(blob),
             'MATCH' if total == len(blob) else 'MISMATCH',
             'MATCH' if stamp == want else 'MISMATCH',
             manifest.get('Guid')))
    for n in names:
        print('           %s' % n)
    if not (total == len(blob) and stamp == want):
        sys.exit('container verification failed')


if __name__ == '__main__':
    src = combine()
    syntax_check(src)
    print('guid   : %s' % guid())
    verify(build())
    print('done.')
