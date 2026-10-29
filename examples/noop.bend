import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/config.bend as K
import ../src/queue.bend as Q
import ../src/kube.bend as Kb

# A controller that does nothing for every ConfigMap in the cluster: the
# cost of watching, caching and queueing alone (a scale baseline).

def reconcile(o: J.Json, cfg: K.Config) -> IO(Q.Action):
  IO.pure(Q.Action, Q.AwaitChange{})

def main() -> IO(Unit):
  Kb.Kube.run(~reconcile, C.Api{C.Res.config_maps(), C.AllNs{}}, Nil{}, Kb.Opts.default())
