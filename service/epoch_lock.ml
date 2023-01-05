open Lwt.Infix

type ('a, 'key) t = {
  mutable current :
    [ `Idle
    | `Activating of unit Lwt.t (* Promise resolves after moving to [`Active] *)
    | `Active of 'key * 'a
    | `Draining of
      unit Lwt.t * unit Lwt_condition.t
      (* Promise resolves after moving back to [`Active] *) ];
  mutable users : int; (* Zero unless active or draining *)
  create : 'key -> 'a Lwt.t;
  dispose : 'a -> unit Lwt.t;
  output : out_channel;
}

let print_s t s =
  output_string t.output s;
  flush t.output

let print_state t =
  match t.current with
  | `Idle -> print_s t "Idle\n"
  | `Activating _ -> print_s t "Activating\n"
  | `Active _ -> print_s t "Active\n"
  | `Draining _ -> print_s t "Draining\n"

let activate t epoch ~ready ~set_ready =
      print_s t "start activate with: ";
      print_state t;
      t.current <- `Activating ready;
      t.create epoch >|= fun v ->
      t.current <- `Active (epoch, v);
      print_s t "end activate with: ";
      print_state t;
      Lwt.wakeup_later set_ready ()

let rec with_epoch t epoch fn =
  let _ =
    print_s t "enter with_epoch(handle request) with: ";
    print_state t
  in
  match t.current with
  | `Active (current_epoch, v) when current_epoch = epoch ->
      t.users <- t.users + 1;
      Lwt.finalize
        (fun () -> fn v)
        (fun () ->
          t.users <- t.users - 1;
          (match t.current with
          | `Active _ -> ()
          | `Draining (_, cond) ->
              if t.users = 0 then Lwt_condition.broadcast cond ()
          | `Idle | `Activating _ -> assert false);
          Lwt.return_unit)
  | `Active (_, old_v) ->
      let cond = Lwt_condition.create () in
      let ready, set_ready = Lwt.wait () in
      t.current <- `Draining (ready, cond);
      (* After this point, no new users can start. *)
      let rec drain () =
        if t.users = 0 then Lwt.return_unit
        else Lwt_condition.wait cond >>= drain
      in
      drain () >>= fun () ->
      t.dispose old_v >>= fun () ->
      activate t epoch ~ready ~set_ready >>= fun () -> with_epoch t epoch fn
  | `Draining (ready, _) | `Activating ready ->
      ready >>= fun () -> with_epoch t epoch fn
  | `Idle ->
      let ready, set_ready = Lwt.wait () in
      activate t epoch ~ready ~set_ready >>= fun () -> with_epoch t epoch fn

let v ~create ~dispose ~output () =
  { current = `Idle; users = 0; create; dispose; output }
