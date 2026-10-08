#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 Michele (manvalan)
# SPDX-License-Identifier: MIT
# Source location: https://github.com/manvalan/OpenNPU
"""Minimal reader for ESP-DL .espdl model files (no dependencies).

An .espdl file is a 16-byte header ("EDL2", encryption mode, payload
size, padding) followed by a FlatBuffers buffer whose schema is
esp-dl/fbs_loader/espdl.fbs (an ONNX-like Model/Graph/Node/Tensor).
Only the parts needed to extract a quantized network are decoded:
graph nodes (op_type, inputs, outputs, attributes), initializers
(dims, data type, raw data, exponents) and value-info exponents.
Encrypted models (mode 1) are not supported.

Usage as a script: espdl_reader.py model.espdl   (prints the graph)
"""
import struct
import sys

# TensorDataType -> (struct code, size)
DTYPE = {1: ("f", 4), 2: ("B", 1), 3: ("b", 1), 4: ("H", 2), 5: ("h", 2), 6: ("i", 4), 7: ("q", 8),
         9: ("?", 1), 12: ("I", 4), 13: ("Q", 8)}
DTYPE_NAME = {1: "float", 2: "uint8", 3: "int8", 4: "uint16", 5: "int16", 6: "int32", 7: "int64",
              9: "bool", 12: "uint32", 13: "uint64"}


class Table:
    """A FlatBuffers table at absolute offset `pos` of buffer `buf`."""

    def __init__(self, buf, pos):
        self.buf, self.pos = buf, pos
        vt = pos - struct.unpack_from("<i", buf, pos)[0]
        self.vt = vt
        self.vt_len = struct.unpack_from("<H", buf, vt)[0]

    def _off(self, field):
        slot = 4 + 2 * field
        if slot >= self.vt_len:
            return 0
        return struct.unpack_from("<H", self.buf, self.vt + slot)[0]

    def scalar(self, field, fmt, default=0):
        o = self._off(field)
        return struct.unpack_from("<" + fmt, self.buf, self.pos + o)[0] if o else default

    def _ref(self, field):
        o = self._off(field)
        if not o:
            return None
        p = self.pos + o
        return p + struct.unpack_from("<I", self.buf, p)[0]

    def string(self, field):
        p = self._ref(field)
        if p is None:
            return None
        n = struct.unpack_from("<I", self.buf, p)[0]
        return self.buf[p + 4:p + 4 + n].decode()

    def table(self, field):
        p = self._ref(field)
        return Table(self.buf, p) if p is not None else None

    def vector(self, field):
        """(element start, count) of a vector field, or (None, 0)."""
        p = self._ref(field)
        if p is None:
            return None, 0
        return p + 4, struct.unpack_from("<I", self.buf, p)[0]

    def scalars(self, field, fmt, size):
        p, n = self.vector(field)
        return list(struct.unpack_from("<%d%s" % (n, fmt), self.buf, p)) if n else []

    def tables(self, field):
        p, n = self.vector(field)
        out = []
        for i in range(n):
            q = p + 4 * i
            out.append(Table(self.buf, q + struct.unpack_from("<I", self.buf, q)[0]))
        return out

    def strings(self, field):
        p, n = self.vector(field)
        out = []
        for i in range(n):
            q = p + 4 * i
            s = q + struct.unpack_from("<I", self.buf, q)[0]
            ln = struct.unpack_from("<I", self.buf, s)[0]
            out.append(self.buf[s + 4:s + 4 + ln].decode())
        return out


# field indices (declaration order in espdl.fbs; a union takes two slots)
MODEL_GRAPH = 7
G_NODE, G_NAME, G_INIT, G_DOC, G_INPUT, G_OUTPUT, G_VALUE_INFO = 0, 1, 2, 3, 4, 5, 6
N_INPUT, N_OUTPUT, N_NAME, N_OP, N_DOMAIN, N_ATTR = 0, 1, 2, 3, 4, 5
A_NAME, A_TYPE, A_F, A_I, A_S, A_INTS = 0, 3, 4, 5, 6, 11
T_DIMS, T_DTYPE, T_NAME, T_RAW, T_EXPONENTS = 0, 1, 6, 8, 13
V_NAME, V_EXPONENTS = 0, 3


class Tensor:
    def __init__(self, t):
        self.name = t.string(T_NAME)
        self.dims = t.scalars(T_DIMS, "q", 8)
        self.dtype = t.scalar(T_DTYPE, "i")
        self.exponents = t.scalars(T_EXPONENTS, "q", 8)
        p, n = t.vector(T_RAW)        # [AlignedBytes] = n * 16 bytes inline
        count = 1
        for d in self.dims:
            count *= d
        fmt, size = DTYPE[self.dtype]
        raw = t.buf[p:p + 16 * n] if n else b""
        self.data = list(struct.unpack_from("<%d%s" % (count, fmt), raw, 0)) if count and raw else []

    def __repr__(self):
        return "%s %s %s exp=%s" % (self.name, DTYPE_NAME.get(self.dtype, self.dtype), self.dims, self.exponents)


class Node:
    def __init__(self, t):
        self.name = t.string(N_NAME)
        self.op = t.string(N_OP)
        self.inputs = t.strings(N_INPUT)
        self.outputs = t.strings(N_OUTPUT)
        self.attrs = {}
        for a in t.tables(N_ATTR):
            ty = a.scalar(A_TYPE, "i")
            nm = a.string(A_NAME)
            if ty == 1:
                o = a._off(A_F)
                self.attrs[nm] = struct.unpack_from("<f", a.buf, a.pos + o)[0] if o else 0.0
            elif ty == 2:
                o = a._off(A_I)
                self.attrs[nm] = struct.unpack_from("<q", a.buf, a.pos + o)[0] if o else 0
            elif ty == 3:
                p, n = a.vector(A_S)
                self.attrs[nm] = a.buf[p:p + n].decode() if n else ""
            elif ty == 7:
                self.attrs[nm] = a.scalars(A_INTS, "q", 8)
            else:
                self.attrs[nm] = "<type %d>" % ty

    def __repr__(self):
        return "%s %s(%s) -> %s %s" % (self.name, self.op, ", ".join(self.inputs), ", ".join(self.outputs), self.attrs)


class EspdlModel:
    def __init__(self, path):
        data = open(path, "rb").read()
        magic = data[:4]
        if magic not in (b"EDL2", b"EDL1"):
            raise ValueError("not a single .espdl model (header %r)" % magic)
        mode, size = struct.unpack_from("<II", data, 4)
        if mode != 0:
            raise ValueError("encrypted .espdl models are not supported")
        start = 16 if magic == b"EDL2" else 12
        buf = data[start:start + size]
        root = Table(buf, struct.unpack_from("<I", buf, 0)[0])
        g = root.table(MODEL_GRAPH)
        self.nodes = [Node(n) for n in g.tables(G_NODE)]
        self.init = {t.name: t for t in (Tensor(x) for x in g.tables(G_INIT))}
        self.value_exp = {}
        for field in (G_INPUT, G_OUTPUT, G_VALUE_INFO):
            for v in g.tables(field):
                self.value_exp[v.string(V_NAME)] = v.scalars(V_EXPONENTS, "q", 8)
        self.inputs = [v.string(V_NAME) for v in g.tables(G_INPUT)]
        self.outputs = [v.string(V_NAME) for v in g.tables(G_OUTPUT)]


if __name__ == "__main__":
    m = EspdlModel(sys.argv[1])
    print("inputs", [(i, m.value_exp.get(i)) for i in m.inputs], "outputs", [(o, m.value_exp.get(o)) for o in m.outputs])
    for n in m.nodes:
        print(n)
        for i in n.inputs:
            if i in m.init:
                print("    init", m.init[i])
            elif i in m.value_exp:
                print("    act ", i, "exp", m.value_exp[i])
