#!/usr/bin/env python3
"""Generates typed Bend views of Kubernetes objects (what k8s-openapi and
kube-derive give kube-rs) from a schema in JSON:

  tools/gen.py crd CRD.json [--version v1] -o out.bend
      a CustomResourceDefinition (YAML ones: tools/y2j first)
  tools/gen.py openapi DOC.json --type io.k8s.api.apps.v1.Deployment \\
      --group apps --version v1 --plural deployments [--depth 3] -o out.bend
      a type in a Kubernetes OpenAPI v3 document
      (kubectl get --raw /openapi/v3/apis/apps/v1)

Each object schema becomes a Data record with T.of (JSON -> Result, naming
the bad field's path), T.to (record -> JSON) and, for the root, T.res (the
resource) and T.api. Mapping: string -> String, boolean -> Bool, integer ->
U32 when its schema has minimum >= 0 (else String, its exact text, so
negatives and int64 round-trip), number -> String (text), arrays ->
List, objects with properties -> records, everything else (maps,
x-kubernetes-preserve-unknown-fields, int-or-string, cycles, past --depth)
-> J.Json. Fields not in `required` are Maybe; lists are always List (empty
when absent). metadata stays J.Json (read it with core.bend's Obj.*).
The output is ordered with tools/order.py."""
import argparse
import json
import os
import re
import subprocess
import sys

KEYWORDS = {"is", "match", "case", "type", "def", "law", "for", "exs", "do", "return",
            "import", "as", "where"}


def pascal(s):
    parts = re.split(r"[^A-Za-z0-9]+", s)
    return "".join(p[:1].upper() + p[1:] for p in parts if p)


def ident(s):
    v = re.sub(r"[^A-Za-z0-9_]", "_", s)
    if not v or v[0].isdigit() or v in KEYWORDS:
        v = "f_" + v
    return v


class Gen:
    def __init__(self, doc, depth):
        self.doc = doc
        self.depth = depth
        self.types = {}  # name -> (fields, required)
        self.order = []

    def resolve(self, s):
        seen = 0
        while "$ref" in s or ("allOf" in s and len(s["allOf"]) == 1):
            if "allOf" in s:
                s = s["allOf"][0]
                continue
            ref = s["$ref"].split("/")[-1]
            s = self.doc["components"]["schemas"][ref]
            seen += 1
            if seen > 50:
                break
        return s

    def ty(self, s, name, depth, stack):
        """The Bend type, decoder and encoder for schema s."""
        ref = s.get("$ref") or (s.get("allOf") or [{}])[0].get("$ref")
        s = self.resolve(s)
        t = s.get("type")
        if s.get("x-kubernetes-int-or-string") or s.get("x-kubernetes-preserve-unknown-fields"):
            return ("J.Json", "T.Ty.json", "T.Ty.from_json")
        if t == "string":
            return ("String", "T.Ty.str", "T.Ty.from_str")
        if t == "boolean":
            return ("Bool", "T.Ty.bool", "T.Ty.from_bool")
        if t == "integer":
            # U32 only when the schema rules out negatives and int64;
            # otherwise the exact text, so -1 or 2^40 still round-trip.
            if s.get("format") != "int64" and s.get("minimum", -1) >= 0:
                return ("U32", "T.Ty.u32", "T.Ty.from_u32")
            return ("String", "T.Ty.num", "T.Ty.from_num")
        if t == "number":
            return ("String", "T.Ty.num", "T.Ty.from_num")
        if t == "array":
            inner = self.ty(s.get("items", {}), name + "Item", depth, stack)
            return ("List", inner)
        props = s.get("properties")
        if (t == "object" or props) and props and depth < self.depth and (ref or name) not in stack:
            key = ref.split(".")[-1] if ref else name
            tname = pascal(key) if ref else name
            if tname not in self.types:
                self.types[tname] = None
                fields = []
                for fname, fs in props.items():
                    fields.append((fname, self.ty(fs, tname + pascal(fname), depth + 1,
                                                  stack | {ref or name})))
                self.types[tname] = (fields, set(s.get("required", [])))
                self.order.append(tname)
            return (tname, tname + ".of", tname + ".to")
        return ("J.Json", "T.Ty.json", "T.Ty.from_json")

    def emit_type(self, name):
        fields, req = self.types[name]
        out = []
        decl = []
        for fname, ft in fields:
            decl.append("%s: %s" % (ident(fname), self.bend_ty(ft, fname in req)))
        out.append("type %s is Data:\n  %s{%s}\n" % (name, name, ", ".join(decl)))
        # decoder
        lines = ["def %s.of.go(+j: J.Json, +path: String) -> Result<&2, &2, String, %s>:" % (name, name),
                 "  do Result<&2, &2, String, %s>:" % name]
        vs = []
        for i, (fname, ft) in enumerate(fields):
            v = "v%d" % i
            vs.append(v)
            lines.append("    %s : %s <- %s" % (v, self.bend_ty(ft, fname in req),
                                            self.dec_call(ft, fname, fname in req)))
        lines.append("    return %s{%s}" % (name, ", ".join(vs)))
        out.append("\n".join(lines) + "\n")
        out.append("def %s.of(j: J.Json, path: String) -> Result<&2, &2, String, %s>:\n"
                   "  %s.of.go(j, path)\n" % (name, name, name))
        # encoder
        puts = [self.put_call(ft, fname, fname in req, "v%d" % i) for i, (fname, ft) in enumerate(fields)]
        out.append("def %s.to(t: %s) -> J.Json:\n  match t:\n    case %s{%s}:\n      T.Ty.obj([%s])\n"
                   % (name, name, name, ", ".join("v%d" % i for i in range(len(fields))),
                      ",\n        ".join(puts)))
        return "\n".join(out)

    def bend_ty(self, ft, required):
        if ft[0] == "List":
            return "List<&2, %s>" % self.bend_ty(ft[1], True)
        return ft[0] if required else "Maybe<&2, %s>" % ft[0]

    def dec_call(self, ft, fname, required):
        if ft[0] == "List":
            inner = ft[1]
            if inner[0] == "List":
                return 'T.Ty.list(~J.Json, ~T.Ty.json, j, "%s", path)' % fname
            return 'T.Ty.list(~%s, ~%s, j, "%s", path)' % (inner[0], inner[1], fname)
        return 'T.Ty.%s(~%s, ~%s, j, "%s", path)' % ("req" if required else "opt", ft[0], ft[1], fname)

    def put_call(self, ft, fname, required, v):
        if ft[0] == "List":
            inner = ft[1]
            if inner[0] == "List":
                return 'T.Ty.put_list(~J.Json, ~T.Ty.from_json, "%s", %s)' % (fname, v)
            return 'T.Ty.put_list(~%s, ~%s, "%s", %s)' % (inner[0], inner[2], fname, v)
        return 'T.Ty.%s(~%s, ~%s, "%s", %s)' % ("put" if required else "put_opt", ft[0], ft[2], fname, v)


def root(name, group, version, plural, namespaced, spec_ty, status_ty, spec_req):
    api_version = (group + "/" + version) if group else version
    ns = "True{}" if namespaced else "False{}"
    sdec = 'T.Ty.%s(~%s, ~%s, j, "spec", path)' % ("req" if spec_req else "opt", spec_ty[0], spec_ty[1])
    st = "%s" % spec_ty[0] if spec_req else "Maybe<&2, %s>" % spec_ty[0]
    sput = 'T.Ty.%s(~%s, ~%s, "spec", v1)' % ("put" if spec_req else "put_opt", spec_ty[0], spec_ty[2])
    status_part = ""
    if status_ty:
        status_part = True
    fields = "metadata: J.Json, spec: %s" % st + (", status: Maybe<&2, %s>" % status_ty[0] if status_ty else "")
    lines = ["# The %s resource, with typed spec%s; metadata stays JSON." % (name, " and status" if status_ty else ""),
             "type %s is Data:\n  %s{%s}\n" % (name, name, fields),
             "def %s.res() -> C.Res:\n  C.Res{\"%s\", \"%s\", \"%s\", \"%s\", %s}\n" % (name, group, version, name, plural, ns),
             "def %s.api(scope: C.Scope) -> C.Api:\n  C.Api{%s.res(), scope}\n" % (name, name),
             "def %s.of.go(+j: J.Json, +path: String) -> Result<&2, &2, String, %s>:\n  do Result<&2, &2, String, %s>:\n"
             "    v0 : J.Json <- Done{J.Json.get(j, \"metadata\")}\n    v1 : %s <- %s\n" % (name, name, name, st, sdec)
             + ('    v2 : Maybe<&2, %s> <- T.Ty.opt(~%s, ~%s, j, "status", path)\n' % (status_ty[0], status_ty[0], status_ty[1]) if status_ty else "")
             + "    return %s{v0, v1%s}\n" % (name, ", v2" if status_ty else ""),
             "# A watched object as a %s, or which field is wrong.\n"
             "def %s.of(j: J.Json) -> Result<&2, &2, String, %s>:\n  %s.of.go(j, \"\")\n" % (name, name, name, name),
             "def %s.to(t: %s) -> J.Json:\n  match t:\n    case %s{v0, v1%s}:\n"
             "      T.Ty.obj([Some{J.KV{\"apiVersion\", J.JStr{\"%s\"}}}, Some{J.KV{\"kind\", J.JStr{\"%s\"}}},\n"
             "        Some{J.KV{\"metadata\", v0}}, %s%s])\n"
             % (name, name, name, ", v2" if status_ty else "", api_version, name, sput,
                (', T.Ty.put_opt(~%s, ~%s, "status", v2)' % (status_ty[0], status_ty[2])) if status_ty else ""),
             ]
    if status_ty:
        lines.append("# A status patch body ({\"status\": …}) for Client.patch_status.\n"
                     "def %s.status_patch(s: %s) -> J.Json:\n  J.Json.obj([J.KV{\"status\", %s(s)}])\n"
                     % (name, status_ty[0], status_ty[2]))
    return "\n".join(lines)


def header(src, lib):
    return ("import Base\nimport %s/json.bend as J\nimport %s/core.bend as C\nimport %s/typed.bend as T\n\n"
            "# Generated by tools/gen.py from %s. Do not edit; regenerate.\n\n" % (lib, lib, lib, src))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["crd", "openapi"])
    ap.add_argument("schema")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--version")
    ap.add_argument("--type")
    ap.add_argument("--group", default="")
    ap.add_argument("--plural")
    ap.add_argument("--cluster", action="store_true", help="cluster-scoped (openapi mode)")
    ap.add_argument("--depth", type=int, default=8)
    ap.add_argument("--lib", help="path of src/ relative to the output (default: computed), "
                    "or a BendHub package's, like bend-kube-runtime@0.1.1.0/src")
    a = ap.parse_args()
    doc = json.load(open(a.schema))
    lib = a.lib or os.path.relpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"),
                                   os.path.dirname(os.path.abspath(a.out)))
    # A package path (name@version/...) is imported as is.
    if not lib.startswith(".") and "@" not in lib.split("/")[0]:
        lib = "./" + lib
    if a.mode == "crd":
        spec = doc["spec"]
        name = spec["names"]["kind"]
        vers = [v for v in spec["versions"] if a.version in (None, v["name"])]
        if not vers:
            sys.exit("no version %s" % a.version)
        v = vers[0]
        schema = v["schema"]["openAPIV3Schema"]
        g = Gen({}, a.depth)
        props = schema.get("properties", {})
        spec_ty = g.ty(props.get("spec", {}), name + "Spec", 0, set())
        status_ty = g.ty(props["status"], name + "Status", 0, set()) if "status" in props else None
        body = root(name, spec["group"], v["name"], spec["names"]["plural"], spec["scope"] == "Namespaced",
                    spec_ty, status_ty, "spec" in schema.get("required", []))
    else:
        g = Gen(doc, a.depth)
        s = doc["components"]["schemas"][a.type]
        name = a.type.split(".")[-1]
        props = g.resolve(s).get("properties", {})
        spec_ty = g.ty(props.get("spec", {}), name + "Spec", 0, set())
        status_ty = g.ty(props["status"], name + "Status", 0, set()) if "status" in props else None
        body = root(name, a.group, a.version, a.plural, not a.cluster, spec_ty, status_ty, False)
    text = header(os.path.basename(a.schema), lib)
    text += "\n".join(g.emit_type(t) for t in g.order) + "\n" + body
    open(a.out, "w").write(text)
    subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "order.py"), a.out],
                   check=True)
    print("wrote %s: %d types" % (a.out, len(g.order) + 1))


if __name__ == "__main__":
    main()
