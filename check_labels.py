# -*- coding: utf-8 -*-
import re
src = open(r'D:\SteamLibrary\steamai\HD2HeavyKillNotice\src\heavy_kill_notice.lua', encoding='utf-8').read()

def blen(s):
    return len(s.encode('utf-8'))

# title
m = re.search(r"hd2\.options\(\{ id = 'heavy_kill_notice', title = '([^']*)'", src)
print('title', blen(m.group(1)), '<=40', 'OK' if blen(m.group(1)) <= 40 else 'FAIL', repr(m.group(1)))

for m in re.finditer(r"label = '([^']*)'", src):
    s = m.group(1)
    print('label', blen(s), '<=64', 'OK' if blen(s) <= 64 else 'FAIL', repr(s))

for m in re.finditer(r"description = '((?:[^'\\]|\\.)*)'", src):
    s = m.group(1).replace("\\'", "'")
    print('desc', blen(s), '<=400', 'OK' if blen(s) <= 400 else 'FAIL')

for m in re.finditer(r"choices = \{ ([^}]*)\}", src):
    for c in re.findall(r"'((?:[^'\\]|\\.)*)'", m.group(1)):
        print('choice', blen(c), '<=48', 'OK' if blen(c) <= 48 else 'FAIL', repr(c))
