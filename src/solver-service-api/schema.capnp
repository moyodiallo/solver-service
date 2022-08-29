
@0x9ac524e0ec04d45e;
# !!! This id is the same with as the file
# "https://github.com/ocurrent/ocaml-multicore-ci/blob/master/api/schema.capnp"
# to avoid the Unimplemented Error

interface Log {
  write @0 (msg :Text);
}

interface Solver {
  solve @0 (request :Text, log :Log) -> (response :Text);
}
