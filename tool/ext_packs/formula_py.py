# -*- coding: utf-8 -*-
"""ตัวคำนวณสูตรแบบเดียวกับ lib/core/obd/formula.dart (ใช้ตรวจชุดข้อมูลตอนสร้าง)"""
import re


class FormulaError(Exception):
    pass


def tokenize(s):
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c.isspace():
            i += 1
            continue
        if c in '+-*/%(),{}:':
            out.append(c)
            i += 1
            continue
        m = re.match(r'(0x[0-9A-Fa-f]+|\d+(\.\d+)?([eE][-+]?\d+)?|[A-Za-z][A-Za-z0-9]*)', s[i:])
        if not m:
            raise FormulaError(f'bad char {c!r}')
        out.append(m.group(0))
        i += len(m.group(0))
    if not out:
        raise FormulaError('empty')
    return out


def var_index(t):
    if not re.match(r'^[A-Z]{1,2}$', t):
        return None
    if len(t) == 1:
        return ord(t) - 65
    return (ord(t[0]) - 64) * 26 + (ord(t[1]) - 65)


class Formula:
    def __init__(self, src):
        self.src = src
        self.toks = tokenize(src)
        self.pos = 0
        self.max_var = -1
        self.ast = self.expr()
        if self.pos != len(self.toks):
            raise FormulaError('trailing ' + self.toks[self.pos])

    def peek(self):
        return self.toks[self.pos] if self.pos < len(self.toks) else None

    def take(self, expect=None):
        t = self.peek()
        if t is None:
            raise FormulaError('unexpected end')
        if expect is not None and t != expect:
            raise FormulaError(f'expected {expect} got {t}')
        self.pos += 1
        return t

    def expr(self):
        n = self.term()
        while self.peek() in ('+', '-'):
            op = self.take()
            r = self.term()
            l = n
            n = (lambda l, r: (lambda b: l(b) + r(b)))(l, r) if op == '+' else (lambda l, r: (lambda b: l(b) - r(b)))(l, r)
        return n

    def term(self):
        n = self.factor()
        while self.peek() in ('*', '/', '%'):
            op = self.take()
            r = self.factor()
            l = n
            if op == '*':
                n = (lambda l, r: (lambda b: l(b) * r(b)))(l, r)
            elif op == '/':
                def div(b, l=l, r=r):
                    d = r(b)
                    if d == 0:
                        raise FormulaError('div0')
                    return l(b) / d
                n = div
            else:
                n = (lambda l, r: (lambda b: dart_mod(l(b), r(b))))(l, r)
        return n

    def byte(self, b, i):
        if i >= len(b):
            raise IndexError('not enough data')
        return b[i]

    def factor(self):
        t = self.take()
        if t == '-':
            f = self.factor()
            return lambda b: -f(b)
        if t == '(':
            e = self.expr()
            self.take(')')
            return e
        if t == '{':
            v = var_index(self.take())
            if v is None:
                raise FormulaError('bit var')
            self.take(':')
            bit = int(self.take())
            self.take('}')
            if bit < 0 or bit > 7:
                raise FormulaError('bit range')
            self.max_var = max(self.max_var, v)
            return lambda b, v=v, bit=bit: float((self.byte(b, v) >> bit) & 1)
        if t.startswith('0x'):
            val = float(int(t[2:], 16))
            return lambda b: val
        try:
            num = float(t)
            return lambda b: num
        except ValueError:
            pass
        v = var_index(t)
        if v is not None and self.peek() != '(':
            self.max_var = max(self.max_var, v)
            return lambda b, v=v: float(self.byte(b, v))
        name = t.lower()
        self.take('(')
        args = [self.expr()]
        while self.peek() == ',':
            self.take(',')
            args.append(self.expr())
        self.take(')')

        def arg(i):
            if i >= len(args):
                raise FormulaError('arg count')
            return args[i]
        if name in ('s', 'signed'):
            a = arg(0)
            nb = args[1] if len(args) > 1 else None

            def sgn(b, a=a, nb=nb):
                n = int(round(nb(b))) if nb else 8
                x = int(round(a(b))) & ((1 << n) - 1)
                return float(x - (1 << n) if x >= (1 << (n - 1)) else x)
            return sgn
        if name == 's16':
            a, c = arg(0), arg(1)

            def s16(b, a=a, c=c):
                x = ((int(round(a(b))) & 0xFF) << 8) | (int(round(c(b))) & 0xFF)
                return float(x - 0x10000 if x >= 0x8000 else x)
            return s16
        if name == 'u16':
            a, c = arg(0), arg(1)
            return lambda b, a=a, c=c: float(((int(round(a(b))) & 0xFF) << 8) | (int(round(c(b))) & 0xFF))
        if name == 'bits':
            a, sh, ln = arg(0), arg(1), arg(2)

            def bits(b, a=a, sh=sh, ln=ln):
                x = int(round(a(b)))
                return float((x >> int(round(sh(b)))) & ((1 << int(round(ln(b)))) - 1))
            return bits
        if name == 'min':
            a, c = arg(0), arg(1)
            return lambda b, a=a, c=c: min(a(b), c(b))
        if name == 'max':
            a, c = arg(0), arg(1)
            return lambda b, a=a, c=c: max(a(b), c(b))
        if name == 'abs':
            a = arg(0)
            return lambda b, a=a: abs(a(b))
        raise FormulaError('unknown function ' + t)

    def eval(self, b):
        return self.ast(b)


def dart_mod(a, b):
    # Dart % บน double ให้ผลไม่ติดลบ (ตามเครื่องหมายตัวหาร) ใช้ math แบบเดียวกับ Python
    return a % b
