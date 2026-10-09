"""Run the Heavy Kill Notice smoke test under real LuaJIT.

Uses build/heavy_kill_notice.built.lua (run build.py first).

Usage:  D:\\py\\python.exe run_smoke_test.py
"""
import os
import sys

from lupa import luajit21

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'build', 'heavy_kill_notice.built.lua')
HARNESS = os.path.join(HERE, 'test', 'smoke_test.lua')

if not os.path.exists(SRC):
    sys.exit('missing %s -- run build.py first' % SRC)

lua = luajit21.LuaRuntime()
lua.globals().MOD_SRC = open(SRC, encoding='utf-8').read()
out = lua.execute(open(HARNESS, encoding='utf-8').read())
print(out)
sys.exit(0 if 'ALL PASS' in str(out) else 1)
