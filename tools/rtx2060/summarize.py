#!/usr/bin/env python3
"""summarize.py RUN - reads RUN/raw from run.sh and writes RUN/summary.json (flat metric -> number, what compare.py
diffs) and RUN/summary.md (the same, readable, with the run's state)."""
import glob, json, os, re, sys, time

RUN = sys.argv[1]
RAW = os.path.join(RUN, 'raw')
M = {}      # metric -> number, the comparable part
NOTES = []  # skips and failures, so a missing number is never silent

def read(*p):
    try: return open(os.path.join(RAW, *p)).read()
    except OSError: return None

def js(*p):
    t = read(*p)
    if t is None: return None
    try: return json.loads(t.strip().splitlines()[-1])
    except (ValueError, IndexError): return {'unparsed': t.strip()[:300]}

def counters(*p):
    t = read(*p) or ''
    c = {}
    for line in t.splitlines():
        k, _, v = line.partition(': ')
        if re.fullmatch(r'-?\d+', v.strip()): c[k.replace('debug.', '')] = int(v)
    return c

def cpu_seconds(t):  # ps time: [[dd-]hh:]mm:ss.cc
    if not t: return None
    t = t.strip(); days = 0
    if '-' in t: d, t = t.split('-'); days = int(d)
    parts = [float(x) for x in t.split(':')]
    s = 0.0
    for x in parts: s = s * 60 + x
    return s + days * 86400

# counters that only grow: reported as the change over a scenario; the rest are gauges, reported as their end value
GAUGES = {'nvrmfb_vram_mapped_bytes', 'nvrmfb_vram_budget_bytes', 'nvrmfb_vram_display_bytes', 'nvaccel_surface_gpu_wait_max_us',
          'nvrmfb_flip_us_max', 'nvrmfb_flip_latch_max_us', 'nvrm_kms_timer_depth', 'nvrm_kms_timer_max_depth'}
WATCH = ['nvaccel_vm_refused', 'nvaccel_vm_alloc', 'nvaccel_vm_parked', 'nvrmfb_vram_grants', 'nvaccel_iop_flips',
         'nvaccel_iop_flip_miss', 'nvrmfb_flip_latch_timeouts', 'nvaccel_surface_gpu_waits', 'nvaccel_surface_gpu_timeouts',
         'nvaccel_iop_late', 'nvaccel_iop_async_drop', 'nvrm_pageoff_runs']

def deltas(prefix, before, after):
    for k in WATCH:
        if k in before and k in after: M[f'{prefix}.{k}'] = after[k] - before[k]
    for k in ('nvrmfb_vram_mapped_bytes',):
        if k in after: M[f'{prefix}.{k}'] = after[k]

run = js('run.json') or {}
for k in ('panel_hz', 'accessibility', 'root'):
    if k in run: M[f'run.{k}'] = run[k]

# desktop
for d in sorted(glob.glob(os.path.join(RAW, 'desktop', '*'))):
    n = os.path.basename(d); p = f'desktop.{n}'
    sk = read('desktop', n, 'skipped.txt')
    if sk: NOTES.append(f'desktop {n} skipped: {sk.strip()}'); continue
    fg = js('desktop', n, 'framegap.json') or {}
    for k in ('fps', 'gap_max_ms', 'gaps_over_two_periods', 'gaps_missed_one', 'flips'):
        if k in fg: M[f'{p}.{k}'] = round(fg[k], 2) if isinstance(fg[k], float) else fg[k]
    # Animations come in bursts (a minimize, a Mission Control swoop) with an idle desktop between them, where the
    # clock and cursor flip a few times a second. Gaps over 50 ms split bursts; inside them a gap over two periods is
    # a visible stall. Pauses are counted apart: under continuous input (a drag, a scroll) every pause is a stall too.
    t = fg.get('flip_ms') or []
    period = 1000 / float(fg.get('panel_hz') or 60)
    gaps = [b - a for a, b in zip(t, t[1:])]
    burst = [g for g in gaps if g <= 50]
    if gaps:
        M[f'{p}.burst_seconds'] = round(sum(burst) / 1000, 2)
        M[f'{p}.burst_fps'] = round(len(burst) / (sum(burst) / 1000), 1) if burst else 0
        M[f'{p}.burst_gaps_over_two_periods'] = sum(1 for g in burst if g > 2 * period)
        M[f'{p}.burst_gap_p99_ms'] = round(sorted(burst)[int(len(burst) * 0.99)], 2) if burst else 0
        M[f'{p}.pauses_over_50ms'] = len(gaps) - len(burst)
    wall = float(read('desktop', n, 'wall-seconds.txt') or 0)
    c0, c1 = cpu_seconds(read('desktop', n, 'ws-cpu-before.txt')), cpu_seconds(read('desktop', n, 'ws-cpu-after.txt'))
    if c0 is not None and c1 is not None and wall:
        M[f'{p}.windowserver_cpu_pct'] = round((c1 - c0) / wall * 100, 1)
        if fg.get('flips'): M[f'{p}.windowserver_cpu_ms_per_frame'] = round((c1 - c0) * 1000 / fg['flips'], 2)
    deltas(p, counters('desktop', n, 'counters-before.txt'), counters('desktop', n, 'counters-after.txt'))

# launch
for f in sorted(glob.glob(os.path.join(RAW, 'launch', '*-first.json')) + glob.glob(os.path.join(RAW, 'launch', '*-second.json'))):
    r = js('launch', os.path.basename(f)) or {}
    app, pas = os.path.basename(f)[:-5].rsplit('-', 1)
    short = app.split('.')[-1]
    if 'skipped' in r: NOTES.append(f'launch {app} {pas}: skipped ({r["skipped"]})'); continue
    if r.get('window_ms') is None: NOTES.append(f'launch {app} {pas}: no window ({r.get("error", "timeout")})'); continue
    M[f'launch.{short}.{pas}_window_ms'] = r['window_ms']
def cache_kb(name):
    t = read('launch', name) or ''
    return sum(int(l.split()[0]) for l in t.splitlines() if re.match(r'\d+\s', l))
if read('launch', 'caches-before.txt') is not None:
    M['launch.shader_cache_kb_before'] = cache_kb('caches-before.txt')
    M['launch.shader_cache_kb_after'] = cache_kb('caches-after.txt')
    M['launch.mesa_disk_cache_present'] = int('mesa-disk-cache' in (read('launch', 'caches-after.txt') or ''))

# video
lst = js('video', 'list.json')
if lst and 'encoders' in lst:
    hw = [e['id'] for e in lst['encoders'] if e.get('hardware') and e.get('codec') in ('avc1', 'hvc1')]
    M['video.hw_encoders_listed'] = len(hw)
    M['video.hw_encoders_before_metal_device'] = len(lst.get('hardware_encoders_before_device', []))
    for c, v in lst.get('hardware_decode', {}).items(): M[f'video.hw_decode_supported.{c}'] = int(bool(v))
for c in ('h264', 'hevc', 'hevc10'):
    e = js('video', f'encode-{c}.json')
    if e is not None:
        if 'error' in e: NOTES.append(f'encode {c}: {e["error"]}'); M[f'video.encode.{c}.hardware'] = 0
        else:
            M[f'video.encode.{c}.hardware'] = int(bool(e.get('hardware')))
            M[f'video.encode.{c}.fps'] = round(e.get('encode_fps', 0), 1)
            M[f'video.encode.{c}.failures'] = e.get('failures', 0)
        deltas(f'video.encode.{c}', counters('video', f'encode-{c}-counters-before.txt'), counters('video', f'encode-{c}-counters-after.txt'))
    d = js('video', f'decode-{c}.json')
    if d is not None:
        if 'error' in d: NOTES.append(f'decode {c}: {d["error"]}'); M[f'video.decode.{c}.hardware'] = 0
        else:
            M[f'video.decode.{c}.hardware'] = int(bool(d.get('hardware')))
            M[f'video.decode.{c}.fps'] = round(d.get('decode_fps', 0), 1)
            M[f'video.decode.{c}.worst_frame_ms'] = round(d.get('worst_frame_ms', 0), 1)
    p = js('video', f'play-{c}.json')
    if p is not None and 'frames_shown' in p:
        M[f'video.play.{c}.shown_fps'] = round(p['shown_fps'], 1)
        M[f'video.play.{c}.dropped'] = p['frames_dropped']
        # a player that falls behind slows down instead of dropping: frames short of real time count too
        M[f'video.play.{c}.frames_short'] = max(round(p['content_fps'] * p['seconds']) - p['frames_shown'], 0)
        deltas(f'video.play.{c}', counters('video', f'play-{c}-counters-before.txt'), counters('video', f'play-{c}-counters-after.txt'))
    s = read('video', f'safari-{c}.json')
    if s is not None:
        try:
            q = json.loads(json.loads(s) if s.strip().startswith('"') else s)
            if q.get('play') != 'ok' or not q.get('presented'):
                NOTES.append(f'safari {c}: play {q.get("play")}, {q.get("callbacks")} frame callbacks, {q.get("visibility")}')
            else:
                fps = p.get('content_fps', 60) if p else 60
                M[f'video.safari.{c}.shown_fps'] = round(q['presented'] / q['wall_s'], 1)
                M[f'video.safari.{c}.frames_short'] = max(round(fps * q['wall_s']) - q['presented'], 0)
                M[f'video.safari.{c}.max_gap_ms'] = round(q['max_gap_ms'], 1)
                M[f'video.safari.{c}.gaps_over_two_frames'] = q['gaps_over_2']
        except (ValueError, KeyError, TypeError):
            NOTES.append(f'safari {c}: {s.strip()[:160]} (Develop > Allow JavaScript from Apple Events?)')

# stats
ps = read('perfstats.txt')
if ps is not None:
    keys = sorted(set(re.findall(r'"([^"]+)"=', ''.join(l for l in ps.splitlines() if 'PerformanceStatistics' in l))) - {'PerformanceStatistics'})
    M['stats.perfstats_keys'] = len(keys)
    M['stats.device_utilization_present'] = int('Device Utilization %' in keys)
    NOTES.append('PerformanceStatistics keys: ' + (', '.join(keys) or 'none'))

# login
pl = read('login', 'per-second.txt')
if pl:
    rows = [l.split() for l in pl.splitlines() if len(l.split()) == 4]
    cpu = [cpu_seconds(r[1]) for r in rows]; flips = [int(r[2]) for r in rows]
    per = [round((b - a) * 100, 1) for a, b in zip(cpu, cpu[1:])]
    M['login.windowserver_cpu_pct_max'] = max(per) if per else 0
    M['login.windowserver_cpu_seconds'] = round(cpu[-1] - cpu[0], 2)
    M['login.seconds_over_50pct_cpu'] = sum(1 for x in per if x > 50)
    M['login.vm_refused'] = int(rows[-1][3]) - int(rows[0][3])
    M['login.flips'] = flips[-1] - flips[0]

end = counters('counters-end.txt')
for k in sorted(GAUGES):
    if k in end: M[f'end.{k}'] = end[k]
for k in ('nvaccel_vm_refused', 'nvaccel_vm_alloc'):
    if k in end: M[f'end.{k}'] = end[k]

json.dump(M, open(os.path.join(RUN, 'summary.json'), 'w'), indent=1, sort_keys=True)

# --- summary.md ---
state = []
for name, f in (('macOS', 'sw_vers.txt'), ('kexts', 'kexts.txt'), ('bundles', 'bundles.txt'), ('GPU profile', 'gpu-profile.txt'),
                ('boot-args', 'boot-args.txt'), ('BAR1', 'bar1-log.txt')):
    t = read('state', f)
    if t: state.append(f'**{name}**\n\n```\n{t.strip()}\n```')
bt = read('state', 'boottime.txt')
if bt and (m := re.search(r'sec = (\d+)', bt)):
    state.append(f'**Uptime at run**: {round((os.path.getmtime(os.path.join(RAW, "state", "boottime.txt")) - int(m.group(1))) / 60)} min')
md = [f'# {os.path.basename(RUN)}', '', f'Panel {M.get("run.panel_hz")} Hz; Accessibility {M.get("run.accessibility")}; '
      f'root {M.get("run.root")}. Frame gaps are judged against two refresh periods ({2000 / float(M.get("run.panel_hz") or 60):.1f} ms).', '']
groups = {}
for k, v in M.items():
    g = '.'.join(k.split('.')[:2]) if k.split('.')[0] in ('desktop', 'video') else k.split('.')[0]
    groups.setdefault(g, []).append((k[len(g) + 1:] or k, v))
for g in groups:
    md += [f'## {g}', '', '| metric | value |', '|---|---|'] + [f'| {k} | {v} |' for k, v in groups[g]] + ['']
if NOTES: md += ['## Notes', ''] + [f'- {n}' for n in NOTES] + ['']
if state: md += ['## State', ''] + state
open(os.path.join(RUN, 'summary.md'), 'w').write('\n'.join(md) + '\n')
