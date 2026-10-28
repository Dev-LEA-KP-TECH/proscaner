# -*- coding: utf-8 -*-
"""สร้างชุดค่าเฉพาะยี่ห้อ (assets/ext_packs) จาก OBDb + แหล่งอื่นที่ตรวจแล้ว

ทุกสูตรถูกตรวจกับคำตอบจริงที่บันทึกไว้ในชุดทดสอบของ OBDb (ถ้ามี) ด้วยตัวถอดค่าต้นฉบับของ OBDb
ถ้าสูตรที่แปลงได้ให้ค่าไม่ตรง จะตัดรายการนั้นทิ้งและรายงาน
"""
import json
import math
import os
import re
import sys

import yaml

sys.path.insert(0, os.path.dirname(__file__))
from formula_py import Formula  # noqa: E402
from thai_names import translate  # noqa: E402

OBDB = os.environ.get('OBDB_DIR', 'obdb')
OUT = sys.argv[1] if len(sys.argv) > 1 else 'out'
NOW_YEAR = 2026
LIB_VERSION = 1

# ---------------------------------------------------------------- ปีรุ่น

def filter_matches(f, year):
    if not f:
        return True
    fr = f.get('from')
    to = f.get('to')
    if fr is not None and to is not None:
        if fr < to:
            if fr <= year <= to:
                return True
        elif year >= fr or year <= to:
            return True
    elif to is not None:
        if year <= to:
            return True
    elif fr is not None:
        if year >= fr:
            return True
    return year in (f.get('years') or [])


def years_text(years):
    if not years:
        return ''
    ys = sorted(set(years))
    runs = []
    s = p = ys[0]
    for y in ys[1:]:
        if y == p + 1:
            p = y
            continue
        runs.append((s, p))
        s = p = y
    runs.append((s, p))
    parts = []
    for a, b in runs:
        if a == b:
            parts.append(str(a))
        elif b >= NOW_YEAR:
            parts.append(f'{a}+')
        else:
            parts.append(f'{a}–{b}')
    return ', '.join(parts)

# ---------------------------------------------------------------- ถอดค่าแบบ OBDb (อ้างอิง)

def extract_bits(data, bix, ln, blsb):
    total = len(data) * 8
    if bix + ln > total:
        raise ValueError('not enough data')
    arr = bytearray(data)
    if blsb and ln > 8:
        sb = bix // 8
        cnt = (ln + 7) // 8
        eb = min(sb + cnt, len(arr))
        arr[sb:eb] = bytes(reversed(arr[sb:eb]))
    r = 0
    for i in range(bix, bix + ln):
        if arr[i // 8] & (1 << (7 - (i % 8))):
            r |= 1 << (bix + ln - i - 1)
    return r


def obdb_decode(fmt, data):
    if 'map' in fmt:
        raw = extract_bits(data, fmt.get('bix', 0), fmt['len'], False)
        m = fmt['map']
        v = m.get(str(raw))
        if v is None:
            return None
        return v['value'] if isinstance(v, dict) else str(v)
    raw = extract_bits(data, fmt.get('bix', 0), fmt['len'], fmt.get('blsb', False))
    if fmt.get('sign') and raw & (1 << (fmt['len'] - 1)):
        raw -= 1 << fmt['len']
    v = raw * fmt.get('mul', 1) / fmt.get('div', 1) + fmt.get('add', 0)
    mn = fmt.get('min', 0)
    mx = fmt['max']
    if mx > mn:
        v = max(mn, min(v, mx))
    eps = sys.float_info.epsilon
    if fmt.get('nullmin') is not None and v <= fmt['nullmin'] + eps:
        return None
    if fmt.get('nullmax') is not None and v >= fmt['nullmax'] - eps:
        return None
    return v

# ---------------------------------------------------------------- สร้างสูตร

def letter(i):
    if i < 26:
        return chr(65 + i)
    return chr(64 + i // 26) + chr(65 + i % 26)


def num(x):
    if isinstance(x, float) and x.is_integer() and abs(x) < 1e15:
        x = int(x)
    s = repr(x)
    if 'e' in s or 'E' in s:
        s = ('%.12f' % x).rstrip('0').rstrip('.')
    return s


def raw_expr(fmt):
    """สูตรค่าดิบ (ก่อนคูณ/หาร) และจำนวนไบต์ที่ใช้"""
    bix = fmt.get('bix', 0)
    ln = fmt['len']
    blsb = fmt.get('blsb', False)
    sign = fmt.get('sign', False)
    b0 = bix // 8
    b1 = (bix + ln - 1) // 8
    n = b1 - b0 + 1
    if n > 5 or b1 > 701:  # ตัวแปรในสูตรมีถึง ZZ (ไบต์ที่ 702)
        return None
    idx = list(range(b0, b1 + 1))
    aligned = bix % 8 == 0 and ln % 8 == 0
    if blsb and ln > 8:
        if not aligned:
            return None
        idx = list(reversed(idx))
    if aligned and n == 2 and sign:
        return f'S16({letter(idx[0])},{letter(idx[1])})', b1 + 1
    if n == 1:
        e = letter(idx[0])
    else:
        terms = []
        for k, i in enumerate(idx):
            mul = 256 ** (n - 1 - k)
            terms.append(letter(i) if mul == 1 else f'{letter(i)}*{mul}')
        e = '(' + '+'.join(terms) + ')'
    shift = n * 8 - ((bix % 8) + ln)
    if not aligned or shift != 0 or ln != n * 8:
        if ln == 1:
            # บิตเดียว: ใช้ {A:n} ที่อ่านง่าย (n นับจาก LSB)
            e = '{' + letter(idx[0]) + ':' + str(shift) + '}'
        else:
            e = f'bits({e},{shift},{ln})'
    if sign:
        e = f'S({e},{ln})' if ln != 8 else f'S({e})'
    return e, b1 + 1


def scaled_expr(raw, mul, div, add):
    e = raw
    composite = not re.match(r'^([A-Z]{1,2}|S16\(.*\)|S\(.*\)|bits\(.*\)|\{.*\}|\(.*\))$', e)
    if composite and (mul != 1 or div != 1):
        e = f'({e})'
    if mul != 1:
        e = f'{e}*{num(mul)}'
    if div != 1:
        e = f'{e}/{num(div)}'
    if add:
        e = f'{e}{"+" if add > 0 else "-"}{num(abs(add))}'
    return e

# ---------------------------------------------------------------- หน่วย

UNIT = {
    'celsius': ('°C', 1, 0), 'kilopascal': ('kPa', 1, 0), 'bars': ('bar', 1, 0), 'psi': ('psi', 1, 0),
    'volts': ('V', 1, 0), 'millivolts': ('mV', 1, 0), 'kilovolts': ('kV', 1, 0), 'amps': ('A', 1, 0),
    'milliamps': ('mA', 1, 0), 'kiloamps': ('kA', 1, 0), 'ampereHours': ('Ah', 1, 0),
    'milliampereHours': ('mAh', 1, 0), 'kiloampereHours': ('kAh', 1, 0), 'percent': ('%', 1, 0),
    'rpm': ('rpm', 1, 0), 'kilometers': ('กม.', 1, 0), 'meters': ('ม.', 1, 0), 'centimeters': ('ซม.', 1, 0),
    'millimeters': ('มม.', 1, 0), 'kilometersPerHour': ('กม./ชม.', 1, 0), 'metersPerSecond': ('ม./วิ', 1, 0),
    'liters': ('L', 1, 0), 'litersPerHour': ('L/h', 1, 0), 'gramsPerSecond': ('g/s', 1, 0),
    'gramsPerLiter': ('g/L', 1, 0), 'kilogramsPerHour': ('kg/h', 1, 0), 'milligramsPerStroke': ('mg/st', 1, 0),
    'newtonMeters': ('N·m', 1, 0), 'degrees': ('°', 1, 0), 'radians': ('rad', 1, 0), 'seconds': ('วินาที', 1, 0),
    'minutes': ('นาที', 1, 0), 'hours': ('ชม.', 1, 0), 'milliseconds': ('ms', 1, 0),
    'metersPerSecondSquared': ('m/s²', 1, 0), 'gravity': ('g', 1, 0), 'hertz': ('Hz', 1, 0),
    'kilohertz': ('kHz', 1, 0), 'ohms': ('Ω', 1, 0), 'kiloohms': ('kΩ', 1, 0), 'milliohms': ('mΩ', 1, 0),
    'megaohms': ('MΩ', 1, 0), 'microohms': ('µΩ', 1, 0), 'watts': ('W', 1, 0), 'kilowatts': ('kW', 1, 0),
    'milliwatts': ('mW', 1, 0), 'kilowattHours': ('kWh', 1, 0), 'joules': ('J', 1, 0), 'kilojoules': ('kJ', 1, 0),
    'scalar': ('', 1, 0), 'normal': ('', 1, 0), 'unknown': ('', 1, 0), 'kelvin': ('K', 1, 0),
    # แปลงเป็นหน่วยที่ใช้ในไทย
    'fahrenheit': ('°C', 5 / 9, -32 * 5 / 9), 'miles': ('กม.', 1.609344, 0),
    'milesPerHour': ('กม./ชม.', 1.609344, 0), 'gallons': ('L', 3.785411784, 0),
    'gallonsPerHour': ('L/h', 3.785411784, 0), 'poundFoot': ('N·m', 1.3558179483, 0),
    'inches': ('มม.', 25.4, 0), 'feet': ('ม.', 0.3048, 0), 'yards': ('ม.', 0.9144, 0),
}
BOOL_LABELS = {
    'offon': {0: 'ปิด', 1: 'เปิด'}, 'onoff': {0: 'เปิด', 1: 'ปิด'},
    'noyes': {0: 'ไม่', 1: 'ใช่'}, 'yesno': {0: 'ใช่', 1: 'ไม่'},
}

# ---------------------------------------------------------------- กลุ่ม

GROUP_ORDER = [
    'หัวฉีดรายสูบ · ค่าชดเชย (feedback)', 'หัวฉีดรายสูบ · ค่าชดเชยปริมาณ', 'หัวฉีดรายสูบ · บาลานซ์',
    'หัวฉีดรายสูบ · ปริมาณฉีด', 'DPF / ไอเสีย', 'เกียร์', 'น้ำมันเชื้อเพลิง / การฉีด', 'เทอร์โบ / ไอดี', 'EGR',
    'เครื่องยนต์', 'จุดระเบิด / รอบรายสูบ', 'ไฟฟ้า / แบตเตอรี่', 'ระยะทาง / สถิติ', 'ความเร็ว / การทรงตัว',
    'เบรก', 'ยาง / ล้อ', 'แอร์', 'ระบบขับเคลื่อน', 'ตัวรถ / สวิตช์', 'กล่อง ECU',
]
DEFAULT_ON = ['หัวฉีดรายสูบ', 'DPF / ไอเสีย', 'เกียร์']


def group_of(name, path):
    n = name.lower()
    p = (path or '').split('.')[0]
    has_cyl = re.search(r'(cylinder|cyl\.?)\s*#?\s*\d|value \d$|volume \d$', n)
    if 'injection feedback value' in n:
        return 'หัวฉีดรายสูบ · ค่าชดเชย (feedback)'
    if has_cyl and re.search(r'fuel compensation|fuel correction|quantity correction', n):
        return 'หัวฉีดรายสูบ · ค่าชดเชยปริมาณ'
    if has_cyl and 'balance rate' in n:
        return 'หัวฉีดรายสูบ · บาลานซ์'
    if has_cyl and re.search(r'injection volume|fuel quantity|injection, cylinder|volume control|injection duration|injector pulse', n):
        return 'หัวฉีดรายสูบ · ปริมาณฉีด'
    if has_cyl and re.search(r'misfire|engine speed of cylinder|speed deviation', n):
        return 'จุดระเบิด / รอบรายสูบ'
    if re.search(r'particulate|\bdpf\b|soot|dpnr|regeneration|pm accumulation|exhaust gas temp|exhaust thermistor|catalyst temp|exhaust back', n) and p != 'Brakes':
        return 'DPF / ไอเสีย'
    if 'exhaust gas recirculation' in n or re.search(r'\begr\b', n):
        return 'EGR'
    if p == 'Transmission' or re.search(r'transmission|\batf\b|gear|lock-up|lock up|torque converter|shift|turbine speed|clutch slip', n):
        return 'เกียร์'
    if re.search(r'boost|turbo|intake air|manifold|charge air|intercooler|barometric|atmosphere|throttle inlet', n):
        return 'เทอร์โบ / ไอดี'
    if p == 'Fuel' or re.search(r'fuel|inject|rail', n):
        return 'น้ำมันเชื้อเพลิง / การฉีด'
    if p == 'Engine':
        return 'เครื่องยนต์'
    if p in ('Battery', 'Electrical'):
        return 'ไฟฟ้า / แบตเตอรี่'
    if p in ('Trips', 'Stats', 'Clocks'):
        return 'ระยะทาง / สถิติ'
    if p in ('Movement', 'Orientation'):
        return 'ความเร็ว / การทรงตัว'
    if p == 'Brakes':
        return 'เบรก'
    if p == 'Tires':
        return 'ยาง / ล้อ'
    if p == 'Climate':
        return 'แอร์'
    if p in ('Drivetrain', 'Fluids'):
        return 'ระบบขับเคลื่อน'
    if p == 'ECU':
        return 'กล่อง ECU'
    return 'ตัวรถ / สวิตช์'

# ---------------------------------------------------------------- ชุดทดสอบ (คำตอบจริง)

def parse_response(text, hdr_len):
    """แยกคำตอบใน yaml (มี header + ISO-TP) เป็นไบต์ข้อความเต็ม"""
    lines = [l.strip() for l in str(text).strip().splitlines() if l.strip()]
    msg = []
    expect = None
    for l in lines:
        body = l[hdr_len:]
        b = bytes.fromhex(body)
        if not b:
            continue
        pci = b[0] >> 4
        if pci == 0:
            ln = b[0] & 0x0F
            return list(b[1:1 + ln])
        if pci == 1:
            expect = ((b[0] & 0x0F) << 8) | b[1]
            msg = list(b[2:])
        elif pci == 2:
            msg.extend(b[1:])
    if expect is None:
        raise ValueError('no frames')
    return msg[:expect]


def load_tests(repo, id_map=None):
    """คืน {command_id: [(year, payload_full_message, expected_dict)]} และ {command_id: set(years)}"""
    base = os.path.join(OBDB, repo, 'tests', 'test_cases')
    cases = {}
    support = {}
    if not os.path.isdir(base):
        return cases, support
    for y in sorted(os.listdir(base)):
        if not y.isdigit():
            continue
        year = int(y)
        cs = os.path.join(base, y, 'command_support.yaml')
        if os.path.exists(cs):
            doc = yaml.safe_load(open(cs)) or {}
            for ecu, lst in (doc.get('supported_commands_by_ecu') or {}).items():
                for item in lst or []:
                    cid = item.split(':')[0].split('|')[0]
                    support.setdefault(cid, set()).add(year)
        cdir = os.path.join(base, y, 'commands')
        if not os.path.isdir(cdir):
            continue
        for f in os.listdir(cdir):
            doc = yaml.safe_load(open(os.path.join(cdir, f)))
            cid = doc['command_id'].split('|')[0]
            support.setdefault(cid, set()).add(year)
            for tc in doc.get('test_cases') or []:
                exp = tc.get('expected_values') or {}
                if id_map:
                    exp = {id_map(k): v for k, v in exp.items()}
                cases.setdefault(cid, []).append((year, tc['response'], exp))
    return cases, support


def command_id(c):
    svc, pid = list(c['cmd'].items())[0]
    parts = [c['hdr']]
    if 'eax' in c:
        parts.append(c['eax'])
    if 'rax' in c:
        parts.append(c['rax'])
    return '.'.join(parts) + '.' + svc + pid

# ---------------------------------------------------------------- ที่อยู่

def addresses(c):
    """คืน (header สำหรับ ExtPid, rx หรือ None ถ้าเป็นค่าปกติ, ความยาว header ในชุดทดสอบ)"""
    hdr = c['hdr'].upper()
    rax = c.get('rax', '').upper()
    if len(hdr) == 3:
        default_rx = '%03X' % (int(hdr, 16) + 8)
        rx = rax or default_rx
        return hdr, (rx if rx != default_rx else None), 3
    if len(hdr) == 4:
        pri = c.get('pri', '18').upper()
        tester = c.get('tst', 'F1').upper()
        tx = pri + hdr + tester
        if len(rax) == 8:
            rx = rax
        elif len(rax) == 6:
            rx = pri + rax
        elif len(rax) == 2:
            rx = pri + 'DA' + tester + rax
        else:
            rx = pri + 'DA' + tester + hdr[2:4]
        default_rx = pri + 'DA' + tester + hdr[2:4] if hdr.startswith('DA') else None
        return tx, (rx if rx != default_rx else None), 8
    return None

# ---------------------------------------------------------------- แปลงชุด OBDb

def signalset_files(repo):
    base = os.path.join(OBDB, repo, 'signalsets', 'v3')
    files = []
    for f in os.listdir(base):
        if f == 'default.json':
            continue
        m = re.match(r'^(\d{4})-(\d{4})\.json$', f)
        if m:
            files.append((int(m.group(1)), int(m.group(2)), os.path.join(base, f)))
    return files, os.path.join(base, 'default.json')


def convert_repo(repo, years, extra_tests=(), stats=None):
    ranges, default = signalset_files(repo)
    by_file = {}
    for y in years:
        f = default
        for a, b, path in ranges:
            if a <= y <= b:
                f = path
        by_file.setdefault(f, []).append(y)
    cases, support = load_tests(repo)
    for (erepo, emap) in extra_tests:
        c2, s2 = load_tests(erepo, emap)
        for k, v in c2.items():
            cases.setdefault(k, []).extend(v)
        for k, v in s2.items():
            support.setdefault(k, set()).update(v)
    pids = []
    skipped = {'eax': 0, 'din': 0, 'kline': 0, 'svc01': 0, 'unit': 0, 'hidden': 0, 'dtc': 0, 'formula': 0, 'mismatch': 0}
    for path, file_years in by_file.items():
        doc = json.load(open(path))
        for c in doc.get('commands', []):
            svc, pid = list(c['cmd'].items())[0]
            if 'eax' in c:
                skipped['eax'] += len(c['signals'])
                continue
            if 'din' in c:
                skipped['din'] += len(c['signals'])
                continue
            if c.get('proto') in ('9141-2', '14230'):
                skipped['kline'] += len(c['signals'])
                continue
            if svc == '01':
                skipped['svc01'] += len(c['signals'])
                continue
            cyears = [y for y in file_years if filter_matches(c.get('filter'), y)]
            if not cyears:
                continue
            addr = addresses(c)
            if not addr:
                continue
            hdr, rx, hlen = addr
            req = svc + pid.upper()
            cid = command_id(c)
            dbg_years = [y for y in cyears if c.get('dbg') or (c.get('dbgfilter') and filter_matches(c['dbgfilter'], y))]
            ev_years = sorted(support.get(cid, set()))
            tests = cases.get(cid, [])
            echo = 2 if svc == '22' else 1
            parsed = []
            for (y, resp, exp) in tests:
                try:
                    full = parse_response(resp, hlen)
                except Exception:
                    continue
                if len(full) < 1 + echo or full[0] != int(svc, 16) + 0x40:
                    continue
                parsed.append((y, full[1 + echo:], exp))
            for s in c['signals']:
                fmt = s['fmt']
                if s.get('hidden'):
                    skipped['hidden'] += 1
                    continue
                if (s.get('path') or '').startswith('DTCs'):
                    skipped['dtc'] += 1
                    continue
                unit_key = fmt.get('unit')
                if unit_key in ('hex', 'ascii') or (unit_key and unit_key not in UNIT and unit_key not in BOOL_LABELS):
                    skipped['unit'] += 1
                    continue
                if fmt['len'] > 32:
                    skipped['formula'] += 1
                    continue
                r = raw_expr(fmt)
                if not r:
                    skipped['formula'] += 1
                    continue
                raw, nbytes = r
                labels = None
                if 'map' in fmt:
                    labels = {}
                    for k, v in fmt['map'].items():
                        if isinstance(v, dict):
                            d = v.get('description') or v.get('value')
                            val = v.get('value')
                            labels[int(k)] = d if d == val or not val else f'{val} · {d}'
                        else:
                            labels[int(k)] = str(v)
                    formula = raw
                    unit = ''
                    mn, mx = None, None
                    dec = 0
                    factor, offset = 1, 0
                elif unit_key in BOOL_LABELS:
                    labels = BOOL_LABELS[unit_key]
                    formula = raw
                    unit = ''
                    mn, mx = 0, 1
                    dec = 0
                    factor, offset = 1, 0
                else:
                    unit, factor, offset = UNIT.get(unit_key or 'unknown')
                    mul = fmt.get('mul', 1) * factor
                    div = fmt.get('div', 1)
                    add = fmt.get('add', 0) * factor + offset
                    if factor != 1:
                        # รวมตัวคูณให้อ่านง่าย
                        mul = round(mul, 10)
                        add = round(add, 6)
                    formula = scaled_expr(raw, mul, div, add)
                    mn = fmt.get('min', 0) * factor + offset
                    mx = fmt['max'] * factor + offset
                    step = abs(mul / div) if div else 1
                    if step >= 1 and float(add).is_integer():
                        dec = 0
                    else:
                        dec = max(0, math.ceil(-math.log10(step) - 1e-9)) if step > 0 else 2
                        if step * 10 ** dec != round(step * 10 ** dec):
                            dec += 1
                        dec = min(dec, 2)
                    if unit in ('°C', 'rpm', 'กม.', 'กม./ชม.', '%', 'kPa') and dec > 1:
                        dec = 1
                try:
                    f = Formula(formula)
                except Exception as e:
                    print('BAD FORMULA', repo, s['id'], formula, e)
                    skipped['formula'] += 1
                    continue
                # ตรวจกับคำตอบจริง
                ev = []
                bad = False
                seen = set()
                for (y, payload, exp) in parsed:
                    if s['id'] not in exp:
                        continue
                    expected = exp[s['id']]
                    try:
                        ref = obdb_decode(fmt, bytes(payload))
                    except Exception:
                        continue
                    ours = eval_ours(f, payload, fmt, labels, factor, offset)
                    if not same(ref, expected, fmt, factor, offset) or not same_ours(ours, ref, fmt, labels, factor, offset):
                        print('MISMATCH', repo, s['id'], formula, payload, 'exp', expected, 'ref', ref, 'ours', ours)
                        bad = True
                        break
                    key = str(expected)
                    if key in seen or len(ev) >= 3:
                        continue
                    seen.add(key)
                    trimmed = payload[:nbytes]
                    shown = None if ref is None else ours
                    if isinstance(shown, float):
                        shown = round(shown, 6)
                    ev.append({'y': y, 'r': bytes(trimmed).hex().upper(), 'v': shown})
                if bad:
                    skipped['mismatch'] += 1
                    continue
                name_en = s['name'].strip()
                th = translate(name_en)
                p = {
                    'id': s['id'],
                    'name': th or name_en,
                    'req': req,
                    'f': formula,
                    'hdr': hdr,
                }
                if th:
                    p['en'] = name_en
                if rx:
                    p['rx'] = rx
                if unit:
                    p['unit'] = unit
                if mn is not None:
                    p['min'] = clean(mn)
                    p['max'] = clean(mx)
                p['dec'] = dec
                p['group'] = group_of(name_en, s.get('path'))
                if labels:
                    p['labels'] = {str(k): v for k, v in sorted(labels.items())}
                if 'map' not in fmt and unit_key not in BOOL_LABELS:
                    for k_src, k_dst in (('nullmin', 'nmin'), ('nullmax', 'nmax'), ('omin', 'omin'), ('omax', 'omax')):
                        if fmt.get(k_src) is not None:
                            p[k_dst] = clean(fmt[k_src] * factor + offset)
                if s.get('description'):
                    p['desc'] = s['description']
                if len(cyears) < len(years):
                    p['yr'] = years_text(cyears)
                if ev_years:
                    p['evy'] = ev_years
                if ev:
                    p['ev'] = ev
                if dbg_years and not ev_years:
                    p['dbg'] = True
                pids.append(p)
    if stats is not None:
        stats[repo] = skipped
    return pids


def clean(x):
    if isinstance(x, float):
        x = round(x, 6)
        if x.is_integer():
            return int(x)
    return x


def eval_ours(f, payload, fmt, labels, factor, offset):
    try:
        v = f.eval(payload)
    except Exception as e:
        return ('ERR', str(e))
    if labels is not None and 'map' in fmt:
        lab = labels.get(int(round(v)))
        return lab
    return v


def same(ref, expected, fmt, factor, offset):
    if ref is None or expected is None:
        return ref is None and expected is None
    if isinstance(ref, str) or isinstance(expected, str):
        return str(ref) == str(expected)
    # ค่าที่คาดไว้ในชุดทดสอบปัดเป็นทศนิยม 5 ตำแหน่ง
    return abs(ref - expected) <= 1e-5 * max(1, abs(expected)) + 6e-6


def same_ours(ours, ref, fmt, labels, factor, offset):
    if isinstance(ours, tuple):
        return False
    if 'map' in fmt:
        if ref is None:
            return ours is None
        # ป้ายของเราอาจเป็น "VALUE · desc" ให้เทียบส่วน value
        return ours is not None and (ours == ref or str(ours).split(' · ')[0] == str(ref))
    # ใช้ขอบเขต/ค่าว่างแบบเดียวกับแอป: clamp เพื่อตรวจค่าว่าง แล้วเทียบค่าที่ clamp
    v = ours
    mn = fmt.get('min', 0)
    mx = fmt['max']
    vo = (v - offset) / factor if factor != 1 or offset else v  # กลับเป็นหน่วยเดิมของ OBDb
    if mx > mn:
        vo = max(mn, min(vo, mx))
    eps = sys.float_info.epsilon
    if fmt.get('nullmin') is not None and vo <= fmt['nullmin'] + eps:
        vo = None
    elif fmt.get('nullmax') is not None and vo >= fmt['nullmax'] - eps:
        vo = None
    if ref is None or vo is None:
        return ref is None and vo is None
    return abs(vo - ref) <= 1e-6 * max(1, abs(ref)) + 1e-9

# ---------------------------------------------------------------- ชุดที่ใส่ในแอป

OBDB_LICENSE = 'CC BY-SA 4.0'
CHANGES = 'แปลงเป็นรูปแบบของ ProScaner, แปลงหน่วยเป็นเมตริก, แปลชื่อเป็นภาษาไทยบางส่วน, ตัดคำสั่งที่ต้องเข้าโหมดพิเศษออก'


def obdb_src(repo, extra=()):
    s = [{'name': f'OBDb {repo}', 'url': f'https://github.com/OBDb/{repo}', 'license': OBDB_LICENSE,
          'by': 'ผู้ร่วมพัฒนา OBDb', 'changes': CHANGES}]
    for r in extra:
        s.append({'name': f'OBDb {r} (ชุดทดสอบ)', 'url': f'https://github.com/OBDb/{r}', 'license': OBDB_LICENSE,
                  'by': 'ผู้ร่วมพัฒนา OBDb', 'changes': 'ใช้คำตอบจริงในชุดทดสอบเป็นหลักฐานเพิ่ม'})
    return s


SCANGAUGE = {'name': 'ScanGauge Australia: Isuzu X-Gauges', 'url': 'https://www.scangauge.com.au/isuzu-x-gauges/',
             'by': 'ScanGauge Australia', 'changes': 'แปลงจากรูปแบบ X-Gauge (TXD/RXF/RXD/MTH) เป็นสูตร, แปลง ft-lb เป็น N·m'}
OBD2AU = {'name': 'OBD2 Australia: Auto Transmission Temperature PIDs',
          'url': 'https://obd2australia.com.au/auto-transmission-temperature-pids/', 'by': 'OBD2 Australia',
          'changes': 'ใช้เป็นแหล่งยืนยันซ้ำ'}
PROSCANER_TECH2 = {'name': 'ProScaner: เทียบกับ Isuzu Tech2 บนรถจริง', 'url': '', 'by': 'ProScaner',
                   'changes': 'วัดเอง 26 ต.ค. 2026 กับ D-Max 2007 เครื่อง 3.0 (4JJ1) กล่อง 98135379 ที่ผ่านการรีแมพ: '
                              'อ่าน DID ด้วย ELM327 เทียบกับหน้า "ข้อมูลเครื่องยนต์1" ของ Tech2 ตอนดับเครื่องและเดินเบา '
                              'และเทียบกับ PID มาตรฐานของรถคันเดียวกัน'}
PROSCANER_PID = {'name': 'ProScaner: เทียบกับ PID มาตรฐานของรถคันเดียวกัน', 'url': '', 'by': 'ProScaner',
                 'changes': 'วัดเอง 27 ต.ค. 2026 กับ D-Max 2007 คันเดิม: อ่าน DID พร้อม PID มาตรฐาน (รอบเครื่อง 0C, '
                            'ความดันราง 23, คันเร่ง 49/4A) ตอนบิดกุญแจ เดินเบา และเร่งค้าง 1,500–2,500 รอบ '
                            '(หน้า "จับคู่กับค่า OBD มาตรฐาน" และบันทึกการสื่อสาร)'}


def fortuner_to_hilux(k):
    return 'HILUX_' + k[len('FORTUNER_'):] if k.startswith('FORTUNER_') else k


PACKS = [
    dict(lib='toyota_hilux', repo='Toyota-Hilux', years=(2005, NOW_YEAR), brand='Toyota',
         name='Toyota Hilux (Vigo, Revo) / Fortuner', models=['Hilux Revo', 'Hilux Vigo', 'Hilux', 'Fortuner'],
         extra_tests=[('Toyota-Fortuner', fortuner_to_hilux)],
         note='ครอบคลุมเครื่อง 1GD/2GD (Revo 2015+), 1KD/2KD (Vigo) และเบนซิน ข้อมูลจากฐานข้อมูลเปิด OBDb '
              'รายการที่ขึ้นว่า "เคยพบในรถจริง" มีคำตอบจริงจากรถ Hilux/Fortuner ยืนยันการถอดค่าแล้ว '
              'ส่วนที่เหลือยังรอยืนยัน ก่อนใช้ตัดสินงานซ่อมควรเทียบกับ Techstream อย่างน้อยหนึ่งครั้ง'),
    dict(lib='toyota_hiace', repo='Toyota-Hiace', years=(2005, NOW_YEAR), brand='Toyota',
         name='Toyota Hiace / Commuter', models=['Hiace', 'Commuter', 'Ventury', 'Majesty'],
         note='ข้อมูลจาก OBDb มีคำตอบจริงจากรถปี 2015 (รุ่น H200) รุ่นใหม่ 2019+ ยังไม่มีข้อมูลยืนยัน'),
    dict(lib='mitsubishi_triton', repo='Mitsubishi-Triton', years=(2005, NOW_YEAR), brand='Mitsubishi',
         name='Mitsubishi Triton / Pajero Sport', models=['Triton', 'Pajero Sport'],
         note='คำสั่ง 21xx ของกล่อง 7E0/7E1 มีคำตอบจริงจาก Triton ปี 2018 (เครื่อง 4N15) '
              'รายการที่ขึ้นว่าใช้กับปี 2023+ เป็นของ Triton ใหม่ (เครื่อง 4N16) ยังรอยืนยันทั้งหมด '
              'Pajero Sport ใช้เครื่อง 4N15 เดียวกันแต่ยังไม่มีข้อมูลยืนยัน'),
    dict(lib='ford_ranger', repo='Ford-Ranger', years=(2012, NOW_YEAR), brand='Ford', ignore_ranges=True,
         name='Ford Ranger / Mazda BT-50 (รุ่นพื้นฐาน Ranger)', models=['Ranger', 'Raptor', 'BT-50'],
         note='ข้อมูลส่วนใหญ่บันทึกจาก Ranger ตลาดสหรัฐฯ ปี 2019 ขึ้นไป (โครงสร้างกล่องแบบเดียวกับ Ranger T6/รุ่นใหม่) '
              'ค่าของเครื่องดีเซลอาจไม่ตอบหรือต่างจากเครื่องเบนซิน ควรกด "ทดสอบกับรถคันนี้" ก่อน'),
    dict(lib='ford_everest', repo='Ford-Everest', years=(2015, NOW_YEAR), brand='Ford',
         name='Ford Everest', models=['Everest'],
         note='ข้อมูลจาก OBDb มีคำตอบจริงจากรถปี 2024–2025'),
    dict(lib='chevrolet_colorado', repo='Chevrolet-Colorado', years=(2012, 2022), brand='Chevrolet',
         name='Chevrolet Colorado / Trailblazer', models=['Colorado', 'Trailblazer'],
         note='ข้อมูลจาก Colorado ตลาดสหรัฐฯ (มีเครื่อง 2.8 Duramax แบบเดียวกับรุ่นไทย) ยังไม่มีข้อมูลยืนยันกับรุ่นไทย'),
    dict(lib='isuzu_dmax_2020', repo='Mazda-BT50', years=(2021, NOW_YEAR), brand='Isuzu',
         name='Isuzu D-Max / MU-X (2020 ขึ้นไป)', models=['D-Max', 'MU-X', 'BT-50'],
         manual='dmax2020', disp_years=(2020, NOW_YEAR),
         note='D-Max รุ่นนี้ยังไม่มีในฐานข้อมูลเปิด จึงใช้ข้อมูลของ Mazda BT-50 รุ่นใหม่ (ตัวรถ เครื่อง และกล่องมาจาก Isuzu) '
              'รวมกับ X-Gauge ของ ScanGauge ออสเตรเลียที่ระบุว่าใช้กับ D-Max/MU-X 2021+ ทุกรายการยังรอยืนยันกับรถไทย '
              'อุณหภูมิน้ำมันเกียร์มีเลขคำสั่ง 2 แบบจากคนละแหล่ง ให้กด "ทดสอบกับรถคันนี้" เพื่อดูว่าแบบไหนตอบ'),
]

CAR_NOTE = ('ข้อมูลจากฐานข้อมูลเปิด OBDb ส่วนใหญ่บันทึกจากรถตลาดต่างประเทศ รุ่นที่ขายในไทยอาจใช้เครื่องหรือกล่องต่างกัน '
            'กด "ทดสอบกับรถคันนี้" ก่อน แล้วเทียบค่าที่ต้องใช้กับเครื่องมือศูนย์')


def car(lib, repo, brand, name, models, years=(2008, NOW_YEAR)):
    return dict(lib=lib, repo=repo, years=years, brand=brand, name=name, models=models, note=CAR_NOTE, group_set='car')


PACKS += [
    car('toyota_corolla', 'Toyota-Corolla', 'Toyota', 'Toyota Corolla / Altis', ['Corolla', 'Altis', 'Corolla Altis']),
    car('toyota_corolla_cross', 'Toyota-Corolla-Cross', 'Toyota', 'Toyota Corolla Cross', ['Corolla Cross']),
    car('toyota_yaris', 'Toyota-Yaris', 'Toyota', 'Toyota Yaris (ข้อมูลหลายตลาด)', ['Yaris']),
    car('toyota_vios', 'Toyota-Vios', 'Toyota', 'Toyota Vios / Yaris Ativ', ['Vios', 'Yaris Ativ']),
    car('toyota_yaris_cross', 'Toyota-Yaris-Cross', 'Toyota', 'Toyota Yaris Cross', ['Yaris Cross']),
    car('toyota_camry', 'Toyota-Camry', 'Toyota', 'Toyota Camry', ['Camry']),
    car('toyota_chr', 'Toyota-C-HR', 'Toyota', 'Toyota C-HR', ['C-HR']),
    car('toyota_veloz', 'Toyota-Veloz', 'Toyota', 'Toyota Veloz', ['Veloz']),
    car('honda_city', 'Honda-City', 'Honda', 'Honda City', ['City']),
    car('honda_civic', 'Honda-Civic', 'Honda', 'Honda Civic', ['Civic']),
    car('honda_jazz', 'Honda-Fit', 'Honda', 'Honda Jazz / Fit', ['Jazz', 'Fit']),
    car('honda_hrv', 'Honda-HR-V', 'Honda', 'Honda HR-V', ['HR-V']),
    car('honda_crv', 'Honda-CR-V', 'Honda', 'Honda CR-V', ['CR-V']),
    car('honda_accord', 'Honda-Accord', 'Honda', 'Honda Accord', ['Accord']),
    car('mazda_2', 'Mazda-2', 'Mazda', 'Mazda 2', ['Mazda2', '2']),
    car('mazda_3', 'Mazda-3', 'Mazda', 'Mazda 3', ['Mazda3', '3']),
    car('mazda_cx3', 'Mazda-CX-3', 'Mazda', 'Mazda CX-3', ['CX-3']),
    car('mazda_cx30', 'Mazda-CX-30', 'Mazda', 'Mazda CX-30', ['CX-30']),
    car('mazda_cx5', 'Mazda-CX-5', 'Mazda', 'Mazda CX-5', ['CX-5']),
    car('nissan_kicks', 'Nissan-Kicks', 'Nissan', 'Nissan Kicks', ['Kicks']),
    car('nissan_xtrail', 'Nissan-X-Trail', 'Nissan', 'Nissan X-Trail', ['X-Trail']),
    car('nissan_march', 'Nissan-Micra', 'Nissan', 'Nissan March / Micra', ['March', 'Micra', 'Almera']),
    car('mitsubishi_outlander', 'Mitsubishi-Outlander', 'Mitsubishi', 'Mitsubishi Outlander', ['Outlander']),
    car('mg_zs', 'MG-ZS', 'MG', 'MG ZS', ['ZS']),
    car('mg_hs', 'MG-HS', 'MG', 'MG HS', ['HS']),
    car('suzuki_swift', 'Suzuki-Swift', 'Suzuki', 'Suzuki Swift', ['Swift']),
    car('ford_focus', 'Ford-Focus', 'Ford', 'Ford Focus', ['Focus']),
    car('ford_fiesta', 'Ford-Fiesta', 'Ford', 'Ford Fiesta', ['Fiesta']),
]

def _ev(*pairs):
    """หลักฐานจากรถจริงปี 2007: (ไบต์ดิบเป็นเลขฐาน 16, ค่าที่ถอดได้ซึ่งตรงกับ Tech2)"""
    return [{'y': 2007, 'r': r, 'v': v} for r, v in pairs]


_V = dict(f='A/10', unit='V', min=0, max=5.1, dec=1, group='เซนเซอร์ (แรงดันไฟ)', hdr='7E0', src=1, evy=[2007])
_T = dict(f='A-40', unit='°C', min=-40, max=215, dec=0, hdr='7E0', src=1, evy=[2007])

MANUAL = {
    'dmax2007': [
        dict(id='DMAX07_ECT', name='อุณหภูมิน้ำหล่อเย็น', en='Engine coolant temperature', req='221210', group='เครื่องยนต์',
             ev=_ev(('43', 27), ('55', 45), ('52', 42)),
             desc='ตรงกับ Tech2 และไบต์เท่ากับ PID 05 ของรถคันเดียวกันทุกครั้ง (27, 45, 42 °C)', **_T),
        dict(id='DMAX07_FT', name='อุณหภูมิน้ำมันเชื้อเพลิง', en='Fuel temperature', req='221211',
             group='น้ำมันเชื้อเพลิง / การฉีด', ev=_ev(('45', 29), ('53', 43)), desc='ตรงกับ Tech2 (29 °C ตอนดับเครื่อง)', **_T),
        dict(id='DMAX07_IAT', name='อุณหภูมิอากาศเข้า', en='Intake air temperature', req='221212', group='เทอร์โบ / ไอดี',
             ev=_ev(('43', 27), ('45', 29)), desc='ตรงกับ Tech2 (27 °C ตอนดับเครื่อง)', **_T),
        dict(id='DMAX07_ECT_V', name='แรงดันเซนเซอร์อุณหภูมิน้ำหล่อเย็น', en='ECT sensor voltage', req='221110',
             ev=_ev(('14', 2.0), ('0D', 1.3)), desc='ลดลงเมื่อเครื่องร้อน ตรงกับ Tech2 (2.0 V ตอนเย็น 1.2–1.3 V ที่ 45 °C)', **_V),
        dict(id='DMAX07_FT_V', name='แรงดันเซนเซอร์อุณหภูมิน้ำมันเชื้อเพลิง', en='Fuel temperature sensor voltage',
             req='221111', ev=_ev(('13', 1.9), ('0E', 1.4)), desc='ตรงกับ Tech2 (1.9 V ตอนดับเครื่อง)', **_V),
        dict(id='DMAX07_IAT_V', name='แรงดันเซนเซอร์อุณหภูมิอากาศเข้า', en='IAT sensor voltage', req='221112',
             ev=_ev(('14', 2.0), ('12', 1.8)), desc='ตรงกับ Tech2 (2.0 V)', **_V),
        dict(id='DMAX07_APP1_V', name='แรงดันเซนเซอร์คันเร่ง (APP) 1', en='APP sensor 1 voltage', req='221100',
             ev=_ev(('06', 0.6)), desc='ตรงกับ Tech2 ตอนไม่เหยียบคันเร่ง (0.6 V)', **_V),
        dict(id='DMAX07_APP2_V', name='แรงดันเซนเซอร์คันเร่ง (APP) 2', en='APP sensor 2 voltage', req='221101',
             ev=_ev(('2B', 4.3)), desc='ตรงกับ Tech2 ตอนไม่เหยียบคันเร่ง (4.3 V)', **_V),
        dict(id='DMAX07_APP3_V', name='แรงดันเซนเซอร์คันเร่ง (APP) 3', en='APP sensor 3 voltage', req='221102',
             ev=_ev(('2B', 4.3)), desc='ตรงกับ Tech2 ตอนไม่เหยียบคันเร่ง (4.3 V)', **_V),
        dict(id='DMAX07_BOOST_V', name='แรงดันเซนเซอร์ความดันบูสต์', en='Boost pressure sensor voltage', req='221151',
             ev=_ev(('17', 2.3)),
             desc='ตรงกับ Tech2 (2.3 V) รถเดิมตามคู่มือควรประมาณ 1.0 V ตอนเดินเบา (รถที่ทดสอบผ่านการรีแมพ)', **_V),
        dict(id='DMAX07_ITP_V', name='แรงดันเซนเซอร์ตำแหน่งลิ้นเร่งไอดี', en='Intake throttle position sensor voltage',
             req='221170', ev=_ev(('2A', 4.2)), desc='ตรงกับ Tech2 (4.2 V)', **_V),
        dict(id='DMAX07_ITP', name='ตำแหน่งลิ้นเร่งไอดี', en='Intake throttle position', req='221270', f='A', unit='%',
             min=0, max=255, dec=0, group='เทอร์โบ / ไอดี', hdr='7E0', src=1, evy=[2007], ev=_ev(('6F', 111)),
             desc='ตรงกับ Tech2 (111 % ตอนเดินเบา)'),
        dict(id='DMAX07_BARO', name='ความดันบรรยากาศ', en='Barometric pressure', req='221241', f='A', unit='kPa',
             min=0, max=255, dec=0, group='เทอร์โบ / ไอดี', hdr='7E0', src=1, evy=[2007], ev=_ev(('64', 100)),
             desc='ตรงกับ Tech2 และ PID 33 (100 kPa) หมายเหตุ: 221251 ก็อ่านได้ 100 เช่นกัน ยังไม่รู้ว่าเป็นค่าอะไร'),
        dict(id='DMAX07_BOOST_DES', name='ความดันบูสต์ที่ต้องการ', en='Desired boost pressure', req='221130', f='A',
             unit='kPa', min=0, max=255, dec=0, group='เทอร์โบ / ไอดี', hdr='7E0', src=1, evy=[2007],
             ev=_ev(('75', 117), ('76', 118)),
             desc='ตรงกับ Tech2 สองช่วงเวลา (117 kPa ตอนดับเครื่อง 118 kPa ตอนเดินเบา) รถเดิมตามคู่มือประมาณ 100 kPa '
                  'ตอนเดินเบา ค่านี้ขึ้นกับการตั้งค่าในกล่อง (รถที่ทดสอบผ่านการรีแมพ)'),
        dict(id='DMAX07_BOOST', name='ความดันบูสต์ (รอยืนยัน)', en='Boost pressure', req='221240', f='A', unit='kPa',
             min=0, max=255, dec=0, group='เทอร์โบ / ไอดี', hdr='7E0', src=1,
             desc='อ่านได้ 69 ขณะที่ Tech2 ขึ้น 70 kPa ทั้งตอนดับเครื่องและเดินเบา ยังไม่ได้เทียบตอนมีบูสต์จริง '
                  '(27 ต.ค. ยังเป็น 69 ตลอดแม้เร่งค้าง 2,500 รอบตอนจอด ซึ่งไม่มีภาระ บูสต์จึงไม่ขึ้นอยู่แล้ว)'),
        dict(id='DMAX07_ITP_DES', name='ตำแหน่งลิ้นเร่งไอดีที่ต้องการ (รอยืนยัน)', en='Desired intake throttle position',
             req='221470', f='A', unit='%', min=0, max=255, dec=0, group='เทอร์โบ / ไอดี', hdr='7E0', src=1,
             desc='อ่านได้ 87 ตรงกับ Tech2 (87 %) หนึ่งครั้งตอนเดินเบา'),
        # 27 ต.ค. 2026: เทียบกับ PID มาตรฐานของรถคันเดียวกัน (src=4)
        dict(id='DMAX07_RPM', name='รอบเครื่องยนต์', en='Engine speed', req='221203', f='A*256+B', unit='rpm',
             min=0, max=8000, dec=0, group='เครื่องยนต์', hdr='7E0', src=4, evy=[2007],
             ev=_ev(('03E9', 1001), ('0655', 1621)),
             desc='ค่าดิบ 2 ไบต์เท่ากับรอบเครื่องจาก PID 0C ของรถคันเดียวกันทุกจุด (1,001 รอบตอนเดินเบา 1,621 รอบตอนเร่งค้าง)'),
        dict(id='DMAX07_RPM2', name='รอบเครื่องยนต์ ค่าที่ 2 (รอยืนยัน)', en='Engine speed 2', req='221204', f='A*256+B',
             unit='rpm', min=0, max=8000, dec=0, group='เครื่องยนต์', hdr='7E0', src=4,
             desc='เปลี่ยนตามรอบเครื่องเหมือน 221203 (1,559 และ 2,587 รอบ ขณะรอบจริง 1,566 และ 2,581) '
                  'แต่ตอนเดินเบานิ่งที่ 1,000 พอดีตลอด อาจเป็นรอบที่กล่องใช้คุม'),
        dict(id='DMAX07_IDLE_DES', name='รอบเดินเบาที่ต้องการ (รอยืนยัน)', en='Desired idle speed', req='221410',
             f='A*256+B', unit='rpm', min=0, max=3000, dec=0, group='เครื่องยนต์', hdr='7E0', src=4,
             desc='อ่านได้ 1,000 ตลอด ทั้งตอนบิดกุญแจ เดินเบา และเร่ง ขณะเครื่องยังไม่ร้อนเต็มที่ (27–65 °C) '
                  'ตรงกับรอบเดินเบาจริงที่ 1,000'),
        dict(id='DMAX07_APP', name='ตำแหน่งคันเร่ง (รอยืนยัน)', en='Accelerator pedal position', req='221200', f='A',
             unit='%', min=0, max=100, dec=0, group='เครื่องยนต์', hdr='7E0', src=4,
             desc='0 ตอนปล่อยคันเร่ง ขึ้นตามแรงดันเซนเซอร์คันเร่ง (15 เมื่อ APP1 1.2 V, 26 เมื่อ 1.5 V)'),
        dict(id='DMAX07_FRP', name='ความดันราง', en='Fuel rail pressure', req='221250', f='A', unit='MPa',
             min=0, max=255, dec=0, group='น้ำมันเชื้อเพลิง / การฉีด', hdr='7E0', src=4, evy=[2007],
             ev=_ev(('20', 32), ('23', 35)),
             desc='ตรงกับ PID 23 ของรถคันเดียวกัน (32 และ 35 MPa ตอนเดินเบา, 48 ที่ 1,500 รอบ, 84 ที่ 2,500 รอบ)'),
        dict(id='DMAX07_FRP_DES', name='ความดันรางที่ต้องการ (รอยืนยัน)', en='Desired fuel rail pressure', req='221450',
             f='A', unit='MPa', min=0, max=255, dec=0, group='น้ำมันเชื้อเพลิง / การฉีด', hdr='7E0', src=4,
             desc='ไปตามความดันรางจริงทุกช่วง (เดินเบา 31–32, 1,500–1,900 รอบ 46–56, เร่ง 72 MPa) และเลข 14xx '
                  'ของกล่องนี้เป็นค่าที่ต้องการของ 12xx (ลิ้นไอดีจริง 1270 / ที่ต้องการ 1470 เทียบกับ Tech2 แล้ว)'),
        dict(id='DMAX07_FRP_V', name='แรงดันเซนเซอร์ความดันราง (รอยืนยัน)', en='Fuel rail pressure sensor voltage',
             req='221150', src=4,
             desc='ขึ้นเป็นเส้นตรงตามความดันราง: 0.9 V ตอนดับเครื่อง, 1.5 V ที่ 35 MPa, 2.3 V ที่ 84 MPa '
                  '(คู่กับ 221250 ตามรูปแบบเลข 11xx แรงดันเซนเซอร์ / 12xx ค่าจริง)',
             **{k: v for k, v in _V.items() if k not in ('src', 'evy')}),
        dict(id='SG_DMAX_ATF', name='อุณหภูมิน้ำมันเกียร์ (เกียร์อัตโนมัติ)', en='ATF temperature', req='221940', f='A-40',
             hdr='7E2', unit='°C', min=-40, max=215, dec=0, group='เกียร์', src=2,
             desc='ScanGauge ออสเตรเลียและ OBD2 Australia ระบุว่าใช้กับ D-Max/MU-X 2008–2020 รุ่นเกียร์อัตโนมัติ '
                  '(รถที่ทดสอบเป็นเกียร์ธรรมดา กล่อง 7E2 จึงไม่ตอบ)'),
    ],
    'dmax2020': [
        dict(id='SG_DMAX21_ATF1', name='อุณหภูมิน้ำมันเกียร์ (อ่างน้ำมัน) · ScanGauge', en='ATF temperature A (oil pan)',
             req='228042', f='A-40', hdr='621', rx='6A1', unit='°C', min=-40, max=215, dec=0, group='เกียร์', src=1),
        dict(id='SG_DMAX21_ATF2', name='อุณหภูมิน้ำมันเกียร์ (ทอร์คคอนเวอร์เตอร์) · ScanGauge',
             en='ATF temperature B (torque converter)', req='228082', f='A-40', hdr='621', rx='6A1', unit='°C',
             min=-40, max=215, dec=0, group='เกียร์', src=1),
        dict(id='SG_DMAX21_TCS', name='สลิปทอร์คคอนเวอร์เตอร์ · ScanGauge', en='Torque converter slip',
             req='2280D2', f='(A*256+B)', hdr='621', rx='6A1', unit='rpm', min=0, max=65535, dec=0, group='เกียร์', src=1),
        dict(id='SG_DMAX21_TRQ', name='แรงบิดเครื่องยนต์ · ScanGauge', en='Engine torque',
             req='228050', f='(A*256+B)*0.498941-847.386', hdr='621', rx='6A1', unit='N·m', min=-848, max=31850, dec=0,
             group='เครื่องยนต์', src=1),
    ],
    'dmax2012': [
        dict(id='SG_DMAX_ATF', name='อุณหภูมิน้ำมันเกียร์', en='ATF temperature', req='221940', f='A-40', hdr='7E2',
             unit='°C', min=-40, max=215, dec=0, group='เกียร์', src=1,
             desc='ScanGauge ออสเตรเลียและ OBD2 Australia ระบุตรงกันว่าใช้กับ D-Max/MU-X 2008–2020'),
        dict(id='SAE_EGT_B1S1', name='อุณหภูมิไอเสีย แถว 1 เซ็นเซอร์ 1 (PID 78)', en='Exhaust gas temperature bank 1 sensor 1',
             req='0178', f='(B*256+C)/10-40', hdr='', unit='°C', min=-40, max=6513.5, dec=1, group='DPF / ไอเสีย', src=1,
             desc='PID มาตรฐาน SAE J1979 ScanGauge ระบุว่าใช้ได้กับ Isuzu รุ่นที่มี DPF ปี 2016 ขึ้นไป'),
        dict(id='SAE_ECT_S1', name='อุณหภูมิน้ำหล่อเย็น เซ็นเซอร์ 1 (PID 67)', en='Engine coolant temperature sensor 1',
             req='0167', f='B-40', hdr='', unit='°C', min=-40, max=215, dec=0, group='เครื่องยนต์', src=1,
             desc='PID มาตรฐาน SAE J1979 ใช้ดูความร้อนจริงเมื่อเข็มบนหน้าปัดถูกหน่วงไว้ (ScanGauge ระบุว่าใช้กับ D-Max/MU-X 2017+)'),
        dict(id='SAE_ECT_S2', name='อุณหภูมิน้ำหล่อเย็น เซ็นเซอร์ 2 (PID 67)', en='Engine coolant temperature sensor 2',
             req='0167', f='C-40', hdr='', unit='°C', min=-40, max=215, dec=0, group='เครื่องยนต์', src=1),
    ],
}

MANUAL_PACKS = [
    dict(lib='isuzu_dmax_2007', brand='Isuzu', years=(2007, 2011), name='Isuzu D-Max (2007–2011) · เทียบกับ Tech2',
         models=['D-Max'], manual='dmax2007', sources=[PROSCANER_TECH2, SCANGAUGE, OBD2AU, PROSCANER_PID], all_on=True,
         note='ค่าที่ขึ้นว่าพบในรถจริง ถูกเทียบกับ Isuzu Tech2 หรือกับ PID มาตรฐานของรถคันเดียวกันแล้ว (D-Max 2007 เครื่อง 3.0 4JJ1 กล่อง 98135379) '
              'ทุกคำสั่งส่งไปกล่องเครื่อง 7E0 ซึ่งเป็นเลขมาตรฐาน ลองกับรถปีอื่นได้ปลอดภัย '
              'รถที่ใช้ทดสอบผ่านการรีแมพ: เลข DID ใช้ได้กับกล่องรุ่นเดียวกัน แต่ค่าเป้าหมาย เช่น บูสต์ที่ต้องการ อาจต่างจากรถเดิม '
              'ยังไม่พบเลขของปริมาณฉีดและแรงดันแบต ค่าที่ค้นพบแต่ยังไม่รู้ชื่อ ให้เทียบกับ Tech2 ในหน้าของแต่ละค่าเพื่อเพิ่มเอง'),
    dict(lib='isuzu_dmax_2012', brand='Isuzu', years=(2012, 2019), name='Isuzu D-Max / MU-X (2012–2019)',
         models=['D-Max', 'MU-X', 'Chevrolet Colorado'], manual='dmax2012',
         sources=[SCANGAUGE, OBD2AU],
         note='ยังมีข้อมูลน้อย: มีอุณหภูมิน้ำมันเกียร์ (2 แหล่งตรงกัน) และค่ามาตรฐาน SAE ที่ช่วยดูความร้อน/ไอเสีย '
              'ยังไม่พบเลขของค่าชดเชยหัวฉีดและ DPF ที่เชื่อถือได้ ให้ใช้ "ค้นหาค่าที่กล่องตอบ" กับโหมดเทียบค่าคู่กับ G-IDSS เพื่อเพิ่มเอง'),
]


def finish(pack_def, pids, sources):
    groups = []
    for g in GROUP_ORDER:
        if any(p['group'] == g for p in pids):
            groups.append(g)
    for p in pids:
        if p['group'] not in groups:
            groups.append(p['group'])
    order = {g: i for i, g in enumerate(groups)}
    pids.sort(key=lambda p: (order[p['group']], p['hdr'], p['req'], p['name']))
    cmds = {(p['hdr'], p.get('rx', ''), p['req']) for p in pids}
    on = [g for g in groups if any(g.startswith(d) for d in DEFAULT_ON)]
    if pack_def.get('all_on'):
        on = list(groups)
    evy = sorted({y for p in pids for y in p.get('evy', [])})
    return {
        'proscaner_pack': 1,
        'id': 'lib_' + pack_def['lib'],
        'lib': pack_def['lib'],
        'libv': LIB_VERSION,
        'name': pack_def['name'],
        'brand': pack_def['brand'],
        'models': pack_def['models'],
        'years': list(pack_def.get('disp_years') or pack_def['years']),
        'note': pack_def['note'],
        'kind': 'car' if pack_def.get('group_set') == 'car' else 'truck',
        'src': sources,
        'on': on,
        'evy': evy,
        'cmds': len(cmds),
        'pids': pids,
    }


def manual_pids(key, sources):
    out = []
    for m in MANUAL[key]:
        p = {k: v for k, v in m.items() if k != 'src'}
        p['srcn'] = sources[m['src'] - 1]['name'] if m.get('src') else None
        if p['srcn'] is None:
            del p['srcn']
        Formula(p['f'])
        out.append(p)
    return out


def gen_years(repo):
    """ช่วงปีที่รุ่นนี้มีขาย (จาก generations.yaml ของ OBDb) เริ่มไม่ก่อน 2008 (ยุค CAN) ใช้แสดงผลและจับคู่รถเท่านั้น"""
    path = os.path.join(OBDB, repo, 'generations.yaml')
    if not os.path.exists(path):
        return None
    gens = (yaml.safe_load(open(path, encoding='utf-8')) or {}).get('generations') or []
    live = [g for g in gens if g.get('start_year') and (g.get('end_year') is None or g['end_year'] >= 2008)]
    if not live:
        return None
    start = max(2008, min(g['start_year'] for g in live))
    end = NOW_YEAR if any(g.get('end_year') is None for g in live) else max(g['end_year'] for g in live)
    return (start, end)


def main():
    os.makedirs(OUT, exist_ok=True)
    index = []
    stats = {}
    for d in PACKS:
        if d.get('group_set') == 'car' and not d.get('disp_years'):
            d['disp_years'] = gen_years(d['repo'])
        years = list(range(d['years'][0], d['years'][1] + 1))
        if d.get('ignore_ranges'):
            global signalset_files
            orig = signalset_files
            signalset_files = lambda repo: ([], os.path.join(OBDB, repo, 'signalsets', 'v3', 'default.json'))  # noqa: E731
            pids = convert_repo(d['repo'], years, d.get('extra_tests', ()), stats)
            signalset_files = orig
        else:
            pids = convert_repo(d['repo'], years, d.get('extra_tests', ()), stats)
        sources = obdb_src(d['repo'], [r for r, _ in d.get('extra_tests', ())])
        if d.get('manual'):
            sources.append(SCANGAUGE)
            pids = manual_pids(d['manual'], sources[:0] + [SCANGAUGE]) + pids
            for p in pids:
                if p['id'].startswith('BT50_'):
                    p['srcn'] = sources[0]['name']
        if not pids:
            print('EMPTY', d['lib'])
            continue
        pack = finish(d, pids, sources)
        write(pack, index)
    for d in MANUAL_PACKS:
        pids = manual_pids(d['manual'], d['sources'])
        pack = finish(d, pids, d['sources'])
        write(pack, index)
    json.dump({'proscaner_lib': 1, 'version': LIB_VERSION, 'packs': index}, open(os.path.join(OUT, 'index.json'), 'w'),
              ensure_ascii=False, separators=(',', ':'))
    print(json.dumps(stats, ensure_ascii=False, indent=0))


def scan_jobs(pids, limit=10):
    """ช่วงค้นหาที่น่าจะเจอค่าของรุ่นนี้ (จัดกลุ่มเลขคำสั่งตามกล่องและไบต์สูง)"""
    groups = {}
    for p in pids:
        hdr = p['hdr']
        if not hdr:
            continue
        rx = p.get('rx')
        svc = p['req'][:2]
        if svc == '21':
            key = (hdr, rx, 0x21, 0x00, 0xFF)
        elif svc == '22':
            hi = int(p['req'][2:4], 16)
            key = (hdr, rx, 0x22, hi << 8, (hi << 8) | 0xFF)
        else:
            continue
        groups.setdefault(key, set()).add(p['req'])
    ranked = sorted(groups.items(), key=lambda kv: -len(kv[1]))[:limit]
    out = []
    for (hdr, rx, svc, a, b), reqs in sorted(ranked, key=lambda kv: (kv[0][0], kv[0][2], kv[0][3])):
        j = {'h': hdr, 's': svc, 'a': a, 'b': b, 'n': len(reqs)}
        if rx:
            j['rx'] = rx
        out.append(j)
    return out


def write(pack, index):
    fn = pack['lib'] + '.json'
    json.dump(pack, open(os.path.join(OUT, fn), 'w'), ensure_ascii=False, separators=(',', ':'))
    n = len(pack['pids'])
    nev = sum(1 for p in pack['pids'] if p.get('evy'))
    index.append({'file': fn, 'lib': pack['lib'], 'name': pack['name'], 'brand': pack['brand'], 'models': pack['models'],
                  'years': pack['years'], 'count': n, 'evCount': nev, 'evy': pack['evy'], 'cmds': pack['cmds'],
                  'src': [s['name'] for s in pack['src']], 'scan': scan_jobs(pack['pids']), 'kind': pack['kind']})
    size = os.path.getsize(os.path.join(OUT, fn))
    print(f"{pack['lib']:26s} pids={n:4d} evidence={nev:4d} cmds={pack['cmds']:4d} evy={pack['evy']} size={size//1024}KB groups={len({p['group'] for p in pack['pids']})}")


def main_manual_only():
    """สร้างใหม่เฉพาะชุดที่เขียนเอง (MANUAL_PACKS) แล้วรวมเข้ากับ index.json เดิม ไม่ต้องมีข้อมูล OBDb
    ใช้: python tool/ext_packs/make_packs.py assets/ext_packs --manual-only"""
    path = os.path.join(OUT, 'index.json')
    old = json.load(open(path, encoding='utf-8'))
    fresh = []
    for d in MANUAL_PACKS:
        pids = manual_pids(d['manual'], d['sources'])
        write(finish(d, pids, d['sources']), fresh)
    by_lib = {e['lib']: e for e in fresh}
    out = [by_lib.pop(e['lib'], e) for e in old['packs']]
    # ชุดใหม่ วางต่อจากชุดยี่ห้อเดียวกันตัวสุดท้าย
    for e in by_lib.values():
        pos = max((i for i, x in enumerate(out) if x['brand'] == e['brand']), default=len(out) - 1)
        out.insert(pos + 1, e)
    json.dump({'proscaner_lib': 1, 'version': old.get('version', LIB_VERSION), 'packs': out}, open(path, 'w'),
              ensure_ascii=False, separators=(',', ':'))


if __name__ == '__main__':
    if '--manual-only' in sys.argv[2:]:
        main_manual_only()
    else:
        main()
