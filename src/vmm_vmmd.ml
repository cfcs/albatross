(* (c) 2017, 2018 Hannes Mehnert, all rights reserved *)

open Astring

open Vmm_core

open Rresult
open R.Infix

type 'a t = {
  wire_version : Vmm_commands.version ;
  console_counter : int64 ;
  stats_counter : int64 ;
  log_counter : int64 ;
  resources : Vmm_resources.t ;
  waiters : 'a String.Map.t ;
}

let in_shutdown = ref false

let killall t =
  match List.map snd (Vmm_trie.all t.resources.Vmm_resources.unikernels) with
  | [] -> false
  | vms -> in_shutdown := true ; List.iter Vmm_unix.destroy vms ; true

let waiter t id =
  let name = Name.to_string id in
  match String.Map.find name t.waiters with
  | None -> t, None
  | Some waiter ->
    let waiters = String.Map.remove name t.waiters in
    { t with waiters }, Some waiter

let register t id create =
  let name = Name.to_string id in
  match String.Map.find name t.waiters with
  | None ->
    let task, waiter = create () in
    Some ({ t with waiters = String.Map.add name waiter t.waiters }, task)
  | Some _ -> None

let init wire_version =
  let t = {
    wire_version ;
    console_counter = 1L ;
    stats_counter = 1L ;
    log_counter = 1L ;
    resources = Vmm_resources.empty ;
    waiters = String.Map.empty ;
  } in
  match Vmm_unix.find_block_devices () with
  | Error (`Msg msg) ->
    Logs.warn (fun m -> m "couldn't find block devices %s" msg) ;
    t
  | Ok devs ->
    let resources =
      List.fold_left (fun r (id, size) ->
          match Vmm_resources.insert_block r id size with
          | Error (`Msg msg) ->
            Logs.err (fun m -> m "couldn't insert block device %a (%dMB): %s" Name.pp id size msg) ;
            r
          | Ok r -> r)
        t.resources devs
    in
    { t with resources }

type service_out = [
  | `Stat of Vmm_commands.wire
  | `Log of Vmm_commands.wire
  | `Cons of Vmm_commands.wire
]

type out = [ service_out | `Data of Vmm_commands.wire ]

type 'a create =
  'a t -> ('a t * out list * Name.t * Unikernel.t, [ `Msg of string ]) result

let log t name event =
  let data = (Ptime_clock.now (), event) in
  let header = Vmm_commands.{ version = t.wire_version ; sequence = t.log_counter ; name } in
  let log_counter = Int64.succ t.log_counter in
  Logs.debug (fun m -> m "log %a" Log.pp data) ;
  ({ t with log_counter }, `Log (header, `Data (`Log_data data)))

let restore_unikernels () =
  match Vmm_unix.restore () with
  | Error `NoFile ->
    Logs.warn (fun m -> m "no state dump found, starting with no unikernels") ;
    Ok Vmm_trie.empty
  | Error (`Msg msg) -> Error (`Msg ("while reading state: " ^ msg))
  | Ok data ->
    match Vmm_asn.unikernels_of_cstruct data with
    | Error (`Msg msg) -> Error (`Msg ("couldn't parse state: " ^ msg))
    | Ok unikernels ->
      Logs.info (fun m -> m "restored some unikernels") ;
      Ok unikernels

let dump_unikernels t =
  let unikernels = Vmm_trie.all t.resources.Vmm_resources.unikernels in
  let trie = List.fold_left (fun t (name, unik) ->
      fst @@ Vmm_trie.insert name unik.Unikernel.config t)
      Vmm_trie.empty unikernels
  in
  let data = Vmm_asn.unikernels_to_cstruct trie in
  match Vmm_unix.dump data with
  | Error (`Msg msg) -> Logs.err (fun m -> m "failed to dump unikernels: %s" msg)
  | Ok () -> Logs.info (fun m -> m "dumped current state")

let setup_stats t name vm =
  let stat_out =
    let name = match Vmm_unix.vm_device vm with
      | Error _ -> ""
      | Ok name -> name
    and ifs = Unikernel.(List.combine vm.config.network_interfaces vm.taps)
    in
    `Stats_add (name, vm.Unikernel.pid, ifs)
  in
  let header = Vmm_commands.{ version = t.wire_version ; sequence = t.stats_counter ; name } in
  let t = { t with stats_counter = Int64.succ t.stats_counter } in
  t, `Stat (header, `Command (`Stats_cmd stat_out))

let remove_stats t name =
  let header = Vmm_commands.{ version = t.wire_version ; sequence = t.stats_counter ; name } in
  let t = { t with stats_counter = Int64.succ t.stats_counter } in
  (t, `Stat (header, `Command (`Stats_cmd `Stats_remove)))

let handle_create t reply name vm_config =
  (match Vmm_resources.find_vm t.resources name with
   | Some _ -> Error (`Msg "VM with same name is already running")
   | None -> Ok ()) >>= fun () ->
  Logs.debug (fun m -> m "now checking resource policies") ;
  Vmm_resources.check_vm t.resources name vm_config >>= fun () ->
  (* prepare VM: save VM image to disk, create fifo, ... *)
  Vmm_unix.prepare name vm_config >>= fun taps ->
  Logs.debug (fun m -> m "prepared vm with taps %a" Fmt.(list ~sep:(unit ",@ ") string) taps) ;
  let cons_out =
    let header = Vmm_commands.{ version = t.wire_version ; sequence = t.console_counter ; name } in
    (header, `Command (`Console_cmd `Console_add))
  in
  Ok ({ t with console_counter = Int64.succ t.console_counter },
      [ `Cons cons_out ],
      `Create (fun t ->
          (* actually execute the vm *)
          let block_device = match vm_config.Unikernel.block_device with
            | None -> None
            | Some block -> Some (Name.block_name name block)
          in
          Vmm_unix.exec name vm_config taps block_device >>= fun vm ->
          Logs.debug (fun m -> m "exec()ed vm") ;
          Vmm_resources.insert_vm t.resources name vm >>= fun resources ->
          let t = { t with resources } in
          dump_unikernels t ;
          let t, out = log t name (`Unikernel_start (name, vm.Unikernel.pid, vm.Unikernel.taps, None)) in
          let t, stat_out = setup_stats t name vm in
          Ok (t, stat_out :: out :: reply, name, vm)))

let handle_shutdown t name vm r =
  (match Vmm_unix.shutdown name vm with
   | Ok () -> ()
   | Error (`Msg e) -> Logs.warn (fun m -> m "%s while shutdown vm %a" e Unikernel.pp vm)) ;
  let resources = match Vmm_resources.remove_vm t.resources name with
    | Error (`Msg e) ->
      Logs.warn (fun m -> m "%s while removing vm %a from resources" e Unikernel.pp vm) ;
      t.resources
    | Ok resources -> resources
  in
  let t = { t with resources } in
  if not !in_shutdown then dump_unikernels t ;
  let t, logout = log t name (`Unikernel_stop (name, vm.Unikernel.pid, r)) in
  let t, stat_out = remove_stats t name in
  (t, [ stat_out ; logout ])

let handle_policy_cmd t reply id = function
  | `Policy_remove ->
    Logs.debug (fun m -> m "remove policy %a" Name.pp id) ;
    Vmm_resources.remove_policy t.resources id >>= fun resources ->
    Ok ({ t with resources }, [ reply (`String "removed policy") ], `End)
  | `Policy_add policy ->
    Logs.debug (fun m -> m "insert policy %a" Name.pp id) ;
    let same_policy = match Vmm_resources.find_policy t.resources id with
      | None -> false
      | Some p' -> Policy.equal policy p'
    in
    if same_policy then
      Ok (t, [ reply (`String "no modification of policy") ], `Loop)
    else
      Vmm_resources.insert_policy t.resources id policy >>= fun resources ->
      Ok ({ t with resources }, [ reply (`String "added policy") ], `Loop)
  | `Policy_info ->
    Logs.debug (fun m -> m "policy %a" Name.pp id) ;
    let policies =
      Vmm_trie.fold id t.resources.Vmm_resources.policies
        (fun prefix policy policies-> (prefix, policy) :: policies)
        []
    in
    match policies with
    | [] ->
      Logs.debug (fun m -> m "policies: couldn't find %a" Name.pp id) ;
      Error (`Msg "policy: not found")
    | _ ->
      Ok (t, [ reply (`Policies policies) ], `End)

let handle_unikernel_cmd t reply id msg_to_err = function
  | `Unikernel_info ->
    Logs.debug (fun m -> m "info %a" Name.pp id) ;
    let vms =
      Vmm_trie.fold id t.resources.Vmm_resources.unikernels
        (fun id vm vms -> (id, vm.Unikernel.config) :: vms)
        []
    in
    begin match vms with
      | [] ->
        Logs.debug (fun m -> m "info: couldn't find %a" Name.pp id) ;
        Error (`Msg "info: no unikernel found")
      | _ ->
        Ok (t, [ reply (`Unikernels vms) ], `End)
    end
  | `Unikernel_create vm_config ->
    let success = reply (`String "created VM") in
    handle_create t [ success ] id vm_config
  | `Unikernel_force_create vm_config ->
    begin
      let resources =
        match Vmm_resources.remove_vm t.resources id with
        | Error _ -> t.resources
        | Ok r -> r
      in
      Vmm_resources.check_vm resources id vm_config >>= fun () ->
      match Vmm_resources.find_vm t.resources id with
      | None ->
        let success = reply (`String "created VM (didn't exist before)") in
        handle_create t [ success ] id vm_config
      | Some vm ->
        Vmm_unix.destroy vm ;
        let success = reply (`String "destroyed and created VM") in
        Ok (t, [], `Wait_and_create
              (id, fun t -> msg_to_err @@ handle_create t [ success ] id vm_config))
    end
  | `Unikernel_destroy ->
    match Vmm_resources.find_vm t.resources id with
    | Some vm ->
      Vmm_unix.destroy vm ;
      let s = reply (`String "destroyed unikernel") in
      Ok (t, [], `Wait (id, s))
    | None -> Error (`Msg "destroy: not found")

let handle_block_cmd t reply id = function
  | `Block_remove ->
    Logs.debug (fun m -> m "removing block %a" Name.pp id) ;
    begin match Vmm_resources.find_block t.resources id with
      | None -> Error (`Msg "remove block: not found")
      | Some (_, true) -> Error (`Msg "remove block: is in use")
      | Some (_, false) ->
        Vmm_unix.destroy_block id >>= fun () ->
        Vmm_resources.remove_block t.resources id >>= fun resources ->
        Ok ({ t with resources }, [ reply (`String "removed block") ], `End)
    end
  | `Block_add size ->
    begin
      Logs.debug (fun m -> m "insert block %a: %dMB" Name.pp id size) ;
      match Vmm_resources.find_block t.resources id with
      | Some _ -> Error (`Msg "block device with same name already exists")
      | None ->
        Vmm_resources.check_block t.resources id size >>= fun () ->
        Vmm_unix.create_block id size >>= fun () ->
        Vmm_resources.insert_block t.resources id size >>= fun resources ->
        Ok ({ t with resources }, [ reply (`String "added block device") ], `Loop)
    end
  | `Block_info ->
    Logs.debug (fun m -> m "block %a" Name.pp id) ;
    let blocks =
      Vmm_trie.fold id t.resources.Vmm_resources.block_devices
        (fun prefix (size, active) blocks -> (prefix, size, active) :: blocks)
        []
    in
    match blocks with
    | [] ->
      Logs.debug (fun m -> m "block: couldn't find %a" Name.pp id) ;
      Error (`Msg "block: not found")
    | _ ->
      Ok (t, [ reply (`Block_devices blocks) ], `End)

let handle_command t (header, payload) =
  let msg_to_err = function
    | Ok x -> x
    | Error (`Msg msg) ->
      Logs.err (fun m -> m "error while processing command: %s" msg) ;
      (t, [ `Data (header, `Failure msg) ], `End)
  and reply x = `Data (header, `Success x)
  and id = header.Vmm_commands.name
  in
  msg_to_err (
    match payload with
    | `Command (`Policy_cmd pc) -> handle_policy_cmd t reply id pc
    | `Command (`Unikernel_cmd vc) -> handle_unikernel_cmd t reply id msg_to_err vc
    | `Command (`Block_cmd bc) -> handle_block_cmd t reply id bc
    | _ ->
      Logs.err (fun m -> m "ignoring %a" Vmm_commands.pp_wire (header, payload)) ;
      Error (`Msg "unknown command"))
