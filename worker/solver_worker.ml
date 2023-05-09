(* Workers that can also solve opam jobs *)

open Lwt.Syntax
module Log_data = Log_data
module Context = Context
module Log = Log
module Process = Process

module Solver_request = struct
  open Capnp_rpc_lwt
  module Worker = Solver_service_api.Worker
  module Log = Solver_service_api.Solver.Log
  module Selection = Worker.Selection
  module Service = Solver_service.Service.Make (Solver_service.Opam_repository)

  type t =
    ( Service.Epoch.t,
      Solver_service.Remote_commit.t list )
    Solver_service.Epoch_lock.t

  let create ~n_workers () =
    let create_worker commits =
      let cmd =
        ( "",
          [|
            "solver-service";
            "--worker";
            Solver_service.Remote_commit.list_to_string commits;
          |] )
      in
      Lwt_process.open_process cmd
    in
    let create commits =
      Service.Epoch.create ~n_workers ~create_worker commits
    in
    Solver_service.Epoch_lock.v ~create ~dispose:Service.Epoch.dispose ()

  let solve t ~switch ~log ~request =
    let+ selections =
      Lwt.catch
        (fun () ->
          Capability.with_ref log @@ fun log ->
          let+ request = Service.handle ~switch t ~log request in
          Result.ok request)
        (function
          | Failure msg -> Lwt_result.fail (`Msg msg)
          | Lwt.Canceled -> Lwt_result.fail `Cancelled
          | ex -> Lwt.return (Fmt.error_msg "%a" Fmt.exn ex))
    in
    match selections with
    | Ok _ ->
        let response =
          Yojson.Safe.to_string
          @@ Solver_service_api.Worker.Solve_response.to_yojson selections
        in
        Solver_service_api.Solver.Log.info log "%s" response;
        Ok response
    | Error _ as error -> error
end

let solve_to_custom req =
  let open Cluster_api.Raw in
  let params =
    Yojson.Safe.to_string
    @@ Solver_service_api.Worker.Solve_request.to_yojson req
  in
  let custom = Builder.Custom.init_root () in
  let builder = Builder.Custom.payload_get custom in
  let request =
    Solver_service_api.Raw.Builder.Solver.Solve.Params.init_pointer builder
  in
  Solver_service_api.Raw.Builder.Solver.Solve.Params.request_set request params;
  let r = Reader.Custom.of_builder custom in
  Reader.Custom.payload_get r

let solve_of_custom c =
  let open Solver_service_api.Raw in
  let payload = Cluster_api.Custom.payload c in
  let r = Reader.of_pointer payload in
  let request = Reader.Solver.Solve.Params.request_get r in
  Solver_service_api.Worker.Solve_request.of_yojson
  @@ Yojson.Safe.from_string request

let cluster_worker_log log =
  let module L = Solver_service_api.Raw.Service.Log in
  L.local
  @@ object
       inherit L.service

       method write_impl params release_param_caps =
         let open L.Write in
         release_param_caps ();
         let msg = Params.msg_get params in
         Log_data.write log msg;
         Capnp_rpc_lwt.Service.(return (Response.create_empty ()))
     end

let solve ~solver ~switch:_ ~log c =
  match solve_of_custom c with
  | Error m -> failwith m
  | Ok s ->
      let+ response =
        Solver_service_api.Solver.solve ~log:(cluster_worker_log log) solver s
      in
      let response =
        Yojson.Safe.to_string
        @@ Solver_service_api.Worker.Solve_response.to_yojson response
      in
      Log_data.write log response;
      Ok response

let solve_request ~solver ~switch ~log c =
  match solve_of_custom c with
  | Error m -> failwith m
  | Ok request ->
      Solver_request.solve solver ~switch ~log:(cluster_worker_log log) ~request
