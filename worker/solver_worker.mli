module Log_data = Log_data
module Context = Context
module Log = Log
module Process = Process

module Solver_request : sig
  type t

  val create : n_workers:int -> unit -> t

  val solve :
    t ->
    switch:Lwt_switch.t ->
    log:Solver_service_api.Solver.Log.X.t Capnp_rpc_lwt.Capability.t ->
    request:Solver_service_api.Worker.Solve_request.t ->
    (string, [ `Cancelled | `Msg of string ]) Lwt_result.t
end

val solve_to_custom :
  Solver_service_api.Worker.Solve_request.t -> Cluster_api.Custom.payload
(** [solve_to_custom req] converts the solver request to a custom job
    specification. *)

val solve_of_custom :
  Solver_service_api.Raw.Reader.pointer_t Cluster_api.Custom.t ->
  (Solver_service_api.Worker.Solve_request.t, string) result
(** [solve_of_custom c] tries to read the custom job specification as a solver
    request. *)

val solve :
  solver:Solver_service_api.Solver.X.t Capnp_rpc_lwt.Capability.t ->
  switch:Lwt_switch.t ->
  log:Log_data.t ->
  Solver_service_api.Raw.Reader.pointer_t Cluster_api.Custom.t ->
  (string, 'b) result Lwt.t
(** [solve ~solver ~switch ~log c] interprets [c] as a solver request and solves
    it using [solver]. *)

val solve_request :
  solver:Solver_request.t ->
  switch:Lwt_switch.t ->
  log:Log_data.t ->
  Solver_service_api.Raw.Reader.pointer_t Cluster_api.Custom.t ->
  (string, [ `Cancelled | `Msg of string ]) Lwt_result.t
(** [handle ~solver ~switch ~log c] interprets [c] as a solver request and
    solves it using [solver]. *)
