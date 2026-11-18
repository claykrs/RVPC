import re
d = open(r'media/win30/staged/WIN.CNF', 'rb').read()
BS = chr(92)
for m in re.finditer(rb'[\x20-\x7e]{4,}', d):
    s = m.group().decode()
    up = s.upper()
    if any(k in up for k in ('KERNEL', 'WINDIR', 'WINDOWS', 'SYSTEM', '.EXE')) or BS in s:
        print('%04x: %s' % (m.start(), s[:110]))