import Base
import ../src/json.bend as J
import ../src/yaml.bend as Y

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(J.Json.show(Y.Yaml.parse("apiVersion: v1\nclusters:\n- cluster:\n    certificate-authority-data: QUJD\n    server: https://127.0.0.1:6443\n  name: local\ncontexts:\n- context:\n    cluster: local\n    namespace: \"team-a\"   # comment\n    user: user\n  name: 'dev'\ncurrent-context: dev\nkind: Config\npreferences: {}\nusers:\n- name: user\n  user:\n    exec:\n      apiVersion: client.authentication.k8s.io/v1\n      args: [\"eks\", \"get-token\"]\n      command: aws\n      env:\n        - name: AWS_PROFILE\n          value: prod # the profile\n      provideClusterInfo: false\n    token: ~\n")))
    IO.print(J.Json.show(Y.Yaml.parse("# only\n---\na:\n  b:\n    - x\n    - 'it''s'\n  c: \"q#not comment\"\nd: true\n")))
    IO.print(J.Json.show(Y.Yaml.parse("context: {cluster: local, user: me}\nargs: [a, 'it''s', \"q\", true, ~]\nempty: {}\nnested: {a: [1, {b: c}]}\n")))
    IO.print(J.Json.show(Y.Yaml.parse("ca: |\n  -----BEGIN-----\n  abc\n\n  def\n  -----END-----\nnote: >-\n  folded\n  text\n\n  para\nkeep: |+\n  x\n\nitems:\n- |\n  one\n  two\n- plain\nafter: done\n")))
    IO.print(J.Json.show(Y.Yaml.parse("base: &b\n  image: nginx\n  port: 80\nname: &n web\nsvc:\n  <<: *b\n  port: 8080\n  owner: *n\nlist:\n- &item\n  a: 1\n- *item\n-\n- !!str 123\n- !custom plain\n")))
    IO.print(J.Json.show(J.Json.arr(Y.Yaml.parse_all("---\na: 1\n---\n# empty doc\n---\nb: [2]\n...\n"))))

    IO.print(J.Json.show(Y.Yaml.parse("a: -5\nb: +7\nc: -0.5\nd: 1e3\ne: 2.5E-3\nf: .5\ng: 5.\nh: 007\ni: 0\nj: -0\nk: 1.2.3\nl: -\nm: .\nn: e5\no: 5e\np: 0x1F\nq: .inf\nr: 12abc\ns: [-1, 2.0]\n")))
