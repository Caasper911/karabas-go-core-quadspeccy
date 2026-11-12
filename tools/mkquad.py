"""mkquad.py tv80_core.v tv80q_core.v

Makes the four-context tv80 core (tv80q_core) out of tv80_core: one copy of the logic, the state of four CPUs.
Input th (2 bits) is the CPU of this clock: every register X of the clocked blocks becomes a memory X_m[0:3]; X
(what the logic reads) is X_m[th]; each clocked block computes the next value of its registers in X_n (blocking,
starting from X, the old value: what was a non-blocking X <= v is X_n = v, a part X[i] the same part of X_n) and
writes X_m[th] <= X_n at its end. The right hand sides still read X, the old value, as the non-blocking assignments
did, and the last assignment wins, as before. The asynchronous resets become synchronous (reset_n is the reset of
CPU th). tv80_reg becomes tv80q_reg (the register file of the four CPUs). The combinational logic (mcode, ALU and
the rest) is unchanged and shared.

The quad core does what four tv80_core do when CPU k gets its cen only in the clocks with th = k (tv80_quad.v; the
equivalence test src/sim/tb_tv80q.v compares it with four tv80_core clock for clock).
"""
import re
import sys

src = open(sys.argv[1]).read()

# drop `ifdef TV80_REFRESH (not used: no DRAM refresh address), keep its `else part
def strip_ifdef(text, name):
    """remove the `ifdef name parts (name not defined): keep the `else parts and every other `ifdef as it is"""
    out = []
    stack = []   # per open `ifdef / `ifndef: [is ours, the part now is kept]
    for line in text.split('\n'):
        s = line.strip()
        tok = s.split()
        if tok and tok[0] in ('`ifdef', '`ifndef'):
            ours = len(tok) > 1 and tok[1] == name
            stack.append([ours, (tok[0] == '`ifndef') if ours else True])
            if ours:
                continue
        elif tok and tok[0] == '`else' and stack:
            if stack[-1][0]:
                stack[-1][1] = not stack[-1][1]
                continue
        elif tok and tok[0] == '`endif' and stack:
            top = stack.pop()
            if top[0]:
                continue
        if all(keep for ours, keep in stack if ours):
            out.append(line)
    return '\n'.join(out)

src = strip_ifdef(src, 'TV80_REFRESH')
lines = src.split('\n')

# the clocked blocks
blocks = []
i = 0
while i < len(lines):
    if re.search(r'always\s*@\s*\(\s*posedge clk', lines[i]):
        depth, j, started = 0, i, False
        while True:
            l = re.sub(r'//.*', '', lines[j])
            nb = len(re.findall(r'\bbegin\b', l))
            depth += nb
            started = started or nb > 0
            depth -= len(re.findall(r'\bend\b', l))
            if started and depth == 0:
                break
            j += 1
        blocks.append((i, j))
        i = j
    i += 1

lhs_re = re.compile(r'^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\[[^\]]*\])?\s*<=\s*(`TV80DELAY\s*)?')
assigned = {}
for (a, b) in blocks:
    names = []
    for k in range(a, b + 1):
        m = lhs_re.match(lines[k])
        if m and m.group(2) not in names:
            names.append(m.group(2))
    assigned[(a, b)] = names
all_names = [n for v in assigned.values() for n in v]
assert len(all_names) == len(set(all_names)), 'a register in two blocks'

# rewrite the blocks (from the last, the line numbers stay valid)
for (a, b) in sorted(blocks, reverse=True):
    names = assigned[(a, b)]
    for k in range(a, b + 1):
        m = lhs_re.match(lines[k])
        if m:
            lines[k] = m.group(1) + m.group(2) + '_n' + (m.group(3) or '') + ' = ' + lines[k][m.end():]
    lines[a] = re.sub(r'always\s*@\s*\(\s*posedge clk[^)]*\)', 'always @ (posedge clk)', lines[a])
    # the first begin (on the always line or the next)
    k = a
    while not re.search(r'\bbegin\b', re.sub(r'//.*', '', lines[k])):
        k += 1
    ind = re.match(r'\s*', lines[k]).group(0) + '  '
    lines[k] = lines[k] + '\n' + '\n'.join(f'{ind}{n}_n = {n};' for n in names)
    # before the last end
    ind_e = re.match(r'\s*', lines[b]).group(0) + '  '
    lines[b] = '\n'.join(f'{ind_e}{n}_m[th] <= {n}_n;' for n in names) + '\n' + lines[b]

src = '\n'.join(lines)

# the declarations of the registers: reg [w] a, b;  ->  memories, next values, the read of CPU th
decl_re = re.compile(r'^(\s*)reg\s*(\[[^\]]*\])?\s*([A-Za-z0-9_,\s]+);(.*)$', re.M)
def decl(m):
    ind, width, names, rest = m.group(1), m.group(2) or '', [n.strip() for n in m.group(3).split(',')], m.group(4)
    keep = [n for n in names if n not in all_names]
    out = []
    if keep:
        out.append(f'{ind}reg {width} {", ".join(keep)};{rest}')
    for n in names:
        if n in all_names:
            out.append(f'{ind}reg {width} {n}_m [0:3];')
            out.append(f'{ind}reg {width} {n}_n;')
            out.append(f'{ind}wire {width} {n} = {n}_m[th];')
    return '\n'.join(out)
src = decl_re.sub(decl, src)
missing = [n for n in all_names if f'{n}_m [0:3]' not in src]
assert not missing, missing

# the module: name, port th; the register file of four CPUs
src = src.replace('module tv80_core (', 'module tv80q_core (\n  th,', 1)
src = src.replace('  input     clk;', '  input     clk;\n  input [1:0] th;      // the CPU of this clock (quad: its state is read and written)', 1)
src = re.sub(r'tv80_reg\s+i_reg', 'tv80q_reg i_reg', src)
src = re.sub(r'(tv80q_reg i_reg\s*\(\s*)', r'\1\n     .th                   (th),', src)

head = ('// GENERATED by tools/mkquad.py from tv80_core.v: do not edit, edit the generator or tv80_core.v.\n'
        '// The four-context tv80 core: see tools/mkquad.py.\n')
open(sys.argv[2], 'w').write(head + src)
print(f'{sys.argv[2]}: {len(blocks)} clocked blocks, {len(all_names)} registers: {" ".join(all_names)}')
