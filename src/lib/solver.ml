module Worker = Solver_service_api.Worker
module Solver = Opam_0install.Solver.Make (Git_context)
module Store = Git_unix.Store
open Lwt.Infix

let env (vars : Worker.Vars.t) =
  let std_env =
    Opam_0install.Dir_context.std_env ~arch:vars.arch ~os:vars.os
      ~os_distribution:vars.os_distribution ~os_version:vars.os_version
      ~os_family:vars.os_family ()
  in
  function
  | "opam-version" ->
      (* Dir_context.std_env expands this variable to the
         version of the opam library we are linking against.
         We want the one from vars instead.
         Can be simplified once this is released:
         https://github.com/ocaml-opam/opam-0install-solver/pull/36
      *)
      Some (OpamVariable.string vars.opam_version)
  | v -> std_env v

let parse_opam (name, contents) =
  let pkg = OpamPackage.of_string name in
  let opam = OpamFile.OPAM.read_from_string contents in
  (OpamPackage.name pkg, (OpamPackage.version pkg, opam))

let solve ~packages ~pins ~root_pkgs (vars : Worker.Vars.t) =
  let ocaml_package = OpamPackage.Name.of_string vars.ocaml_package in
  let ocaml_version = OpamPackage.Version.of_string vars.ocaml_version in
  let context =
    Git_context.create () ~packages ~pins ~env:(env vars)
      ~constraints:
        (OpamPackage.Name.Map.singleton ocaml_package (`Eq, ocaml_version))
      ~test:(OpamPackage.Name.Set.of_list root_pkgs)
  in
  let t0 = Unix.gettimeofday () in
  let r = Solver.solve context (ocaml_package :: root_pkgs) in
  let t1 = Unix.gettimeofday () in
  Printf.printf "%.2f\n" (t1 -. t0);
  match r with
  | Ok sels ->
      let pkgs = Solver.packages_of_result sels in
      Ok (List.map OpamPackage.to_string pkgs)
  | Error diagnostics -> Error (Solver.diagnostics diagnostics)

let main commit =
  let packages =
    Lwt_main.run
      ( Opam_repository.open_store () >>= fun store ->
        Git_context.read_packages store commit )
  in
  let rec aux () =
    match input_line stdin with
    | exception End_of_file -> ()
    | len ->
        let len = int_of_string len in
        let data = really_input_string stdin len in
        let request =
          Worker.Solve_request.of_yojson (Yojson.Safe.from_string data)
          |> Result.get_ok
        in
        let {
          Worker.Solve_request.opam_repository_commit;
          root_pkgs;
          pinned_pkgs;
          platforms;
        } =
          request
        in
        let opam_repository_commit = Store.Hash.of_hex opam_repository_commit in
        assert (Store.Hash.equal opam_repository_commit commit);
        let root_pkgs = List.map parse_opam root_pkgs in
        let pinned_pkgs = List.map parse_opam pinned_pkgs in
        let pins = root_pkgs @ pinned_pkgs |> OpamPackage.Name.Map.of_list in
        let root_pkgs = List.map fst root_pkgs in
        platforms
        |> List.iter (fun (_id, platform) ->
               let msg =
                 match solve ~packages ~pins ~root_pkgs platform with
                 | Ok packages -> "+" ^ String.concat " " packages
                 | Error msg -> "-" ^ msg
               in
               Printf.printf "%d\n%s%!" (String.length msg) msg);
        aux ()
  in
  aux ()

let main commit =
  try main commit
  with ex ->
    Fmt.epr "solver bug: %a@." Fmt.exn ex;
    let msg =
      match ex with Failure msg -> msg | ex -> Printexc.to_string ex
    in
    let msg = "!" ^ msg in
    Printf.printf "0.0\n%d\n%s%!" (String.length msg) msg;
    raise ex


let spawn_local ~solver_dir : Solver_service_api.Solver.t =
  let p, c = Unix.(socketpair PF_UNIX SOCK_STREAM 0 ~cloexec:true) in
  Unix.clear_close_on_exec c;
  let cmd = ("", [| "solver-service" |]) in
  let _child = Lwt_process.open_process_none ~cwd:solver_dir ~stdin:(`FD_move c) cmd in
  let switch = Lwt_switch.create () in
  let p = Lwt_unix.of_unix_file_descr p
          |> Capnp_rpc_unix.Unix_flow.connect ~switch
          |> Capnp_rpc_net.Endpoint.of_flow (module Capnp_rpc_unix.Unix_flow)
            ~peer_id:Capnp_rpc_net.Auth.Digest.insecure
            ~switch in
  let conn = Capnp_rpc_unix.CapTP.connect ~restore:Capnp_rpc_net.Restorer.none p in
  let solver = Capnp_rpc_unix.CapTP.bootstrap conn (Capnp_rpc_net.Restorer.Id.public "solver") in
  solver |> Capnp_rpc_lwt.Capability.when_broken (fun ex ->
      Fmt.failwith "Solver process failed: %a" Capnp_rpc.Exception.pp ex
    );
  solver