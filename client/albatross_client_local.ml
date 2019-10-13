(* (c) 2017, 2018 Hannes Mehnert, all rights reserved *)

open Lwt.Infix

let version = `AV3

let socket ~tmpdir t = function
  | Some x -> x
  | None -> Vmm_core.socket_path ~tmpdir t

let connect socket_path =
  let c = Lwt_unix.(socket PF_UNIX SOCK_STREAM 0) in
  Lwt_unix.set_close_on_exec c ;
  Lwt_unix.connect c (Lwt_unix.ADDR_UNIX socket_path) >|= fun () ->
  c

let process fd =
  Vmm_lwt.read_wire fd >|= function
  | Error _ -> Error ()
  | Ok wire -> Ok (Albatross_cli.print_result version wire)

let read fd =
  (* now we busy read and process output *)
  let rec loop () =
    process fd >>= function
    | Error _ -> Lwt.return ()
    | Ok () -> loop ()
  in
  loop ()

let handle ~tmpdir opt_socket name (cmd : Vmm_commands.t) =
  let sock, next = Vmm_commands.endpoint cmd in
  connect (socket ~tmpdir sock opt_socket) >>= fun fd ->
  let header = Vmm_commands.{ version ; sequence = 0L ; name } in
  Vmm_lwt.write_wire fd (header, `Command cmd) >>= function
  | Error `Exception -> Lwt.return ()
  | Ok () ->
    (match next with
     | `Read -> read fd
     | `End -> process fd >|= ignore) >>= fun () ->
    Vmm_lwt.safe_close fd

let jump ~tmpdir opt_socket name cmd =
  Ok (Lwt_main.run (handle ~tmpdir opt_socket name cmd))

let info_policy _ opt_socket name tmpdir =
  jump ~tmpdir opt_socket name (`Policy_cmd `Policy_info)

let remove_policy _ opt_socket name tmpdir =
  jump ~tmpdir opt_socket name (`Policy_cmd `Policy_remove)

let add_policy _ opt_socket name vms memory cpus block bridges tmpdir =
  let p = Albatross_cli.policy vms memory cpus block bridges in
  jump ~tmpdir opt_socket name (`Policy_cmd (`Policy_add p))

let info_ _ opt_socket name tmpdir =
  jump ~tmpdir opt_socket name (`Unikernel_cmd `Unikernel_info)

let destroy _ opt_socket name tmpdir =
  jump ~tmpdir opt_socket name (`Unikernel_cmd `Unikernel_destroy)

let create _ opt_socket force name image image_type cpuid memory argv block network compression tmpdir =
  match Albatross_cli.create_vm force image image_type cpuid memory argv block network compression with
  | Ok cmd -> jump ~tmpdir opt_socket name (`Unikernel_cmd cmd)
  | Error (`Msg msg) -> Error (`Msg msg)

let console _ opt_socket name since tmpdir =
  jump ~tmpdir opt_socket name (`Console_cmd (`Console_subscribe since))

let stats_add _ opt_socket name vmmdev pid bridge_taps tmpdir =
  jump ~tmpdir opt_socket name (`Stats_cmd (`Stats_add (vmmdev, pid, bridge_taps)))

let stats_remove _ opt_socket name tmpdir =
  jump ~tmpdir opt_socket name (`Stats_cmd `Stats_remove)

let stats_subscribe _ opt_socket name tmpdir =
  jump ~tmpdir opt_socket name (`Stats_cmd `Stats_subscribe)

let event_log _ opt_socket name since tmpdir =
  jump ~tmpdir opt_socket name (`Log_cmd (`Log_subscribe since))

let block_info _ opt_socket block_name tmpdir =
  jump ~tmpdir opt_socket block_name (`Block_cmd `Block_info)

let block_create _ opt_socket block_name block_size tmpdir =
  jump ~tmpdir opt_socket block_name (`Block_cmd (`Block_add block_size))

let block_destroy _ opt_socket block_name tmpdir =
  jump ~tmpdir opt_socket block_name (`Block_cmd `Block_remove)

let help _ _ man_format cmds = function
  | None -> `Help (`Pager, None)
  | Some t when List.mem t cmds -> `Help (man_format, Some t)
  | Some _ -> List.iter print_endline cmds; `Ok ()

open Cmdliner
open Albatross_cli

let socket =
  let doc = "Socket to connect to" in
  Arg.(value & opt (some dir) None & info [ "socket" ] ~doc)

let runtime_directory =
  let doc = "directory in which to cache runtime data. a.k.a 'tmpdir'" in
  let fpath = Arg.conv (Fpath.of_string , Fpath.pp) in
  Arg.(value
       & opt fpath (Fpath.of_string
                      (match Vmm_unix.uname_t with
                       | `Linux -> "/run/albatross"
                       | `FreeBSD | _ -> "/var/run/albatross")
                    |> function Ok p -> p | Error _ -> failwith "oops.")
       & info [ "runtime-directory" ] ~doc)

let destroy_cmd =
  let doc = "destroys a virtual machine" in
  let man =
    [`S "DESCRIPTION";
     `P "Destroy a virtual machine."]
  in
  Term.(term_result (const destroy $ setup_log $ socket $ vm_name $ runtime_directory)),
  Term.info "destroy" ~doc ~man

let remove_policy_cmd =
  let doc = "removes a policy" in
  let man =
    [`S "DESCRIPTION";
     `P "Removes a policy."]
  in
  Term.(term_result (const remove_policy $ setup_log $ socket $ opt_vm_name $ runtime_directory)),
  Term.info "remove_policy" ~doc ~man

let info_cmd =
  let doc = "information about VMs" in
  let man =
    [`S "DESCRIPTION";
     `P "Shows information about VMs."]
  in
  Term.(term_result (const info_ $ setup_log $ socket $ opt_vm_name $ runtime_directory)),
  Term.info "info" ~doc ~man

let policy_cmd =
  let doc = "active policies" in
  let man =
    [`S "DESCRIPTION";
     `P "Shows information about policies."]
  in
  Term.(term_result (const info_policy $ setup_log $ socket $ opt_vm_name $ runtime_directory)),
  Term.info "policy" ~doc ~man

let add_policy_cmd =
  let doc = "Add a policy" in
  let man =
    [`S "DESCRIPTION";
     `P "Adds a policy."]
  in
  Term.(term_result (const add_policy $ setup_log $ socket $ vm_name $ vms $ mem $ cpus $ opt_block_size $ bridge $ runtime_directory)),
  Term.info "add_policy" ~doc ~man

let create_cmd =
  let doc = "creates a virtual machine" in
  let man =
    [`S "DESCRIPTION";
     `P "Creates a virtual machine."]
  in
  Term.(term_result (const create $ setup_log $ socket $ force $ vm_name $ image $ cpu $ vm_mem $ args $ block $ net $ compress_level $ runtime_directory)),
  Term.info "create" ~doc ~man

let console_cmd =
  let doc = "console of a VM" in
  let man =
    [`S "DESCRIPTION";
     `P "Shows console output of a VM."]
  in
  Term.(term_result (const console $ setup_log $ socket $ vm_name $ since $ runtime_directory)),
  Term.info "console" ~doc ~man

let stats_subscribe_cmd =
  let doc = "statistics of VMs" in
  let man =
    [`S "DESCRIPTION";
     `P "Shows statistics of VMs."]
  in
  Term.(term_result (const stats_subscribe $ setup_log $ socket $ opt_vm_name $ runtime_directory)),
  Term.info "stats" ~doc ~man

let stats_remove_cmd =
  let doc = "remove statistics of VM" in
  let man =
    [`S "DESCRIPTION";
     `P "Removes statistics of VM."]
  in
  Term.(term_result (const stats_remove $ setup_log $ socket $ opt_vm_name $ runtime_directory)),
  Term.info "stats_remove" ~doc ~man

let stats_add_cmd =
  let doc = "Add VM to statistics gathering" in
  let man =
    [`S "DESCRIPTION";
     `P "Add VM to statistics gathering."]
  in
  Term.(term_result (const stats_add $ setup_log $ socket $ opt_vm_name $ vmm_dev_req0 $ pid_req1 $ bridge_taps $ runtime_directory)),
  Term.info "stats_add" ~doc ~man

let log_cmd =
  let doc = "Event log" in
  let man =
    [`S "DESCRIPTION";
     `P "Shows event log of VM."]
  in
  Term.(term_result (const event_log $ setup_log $ socket $ opt_vm_name $ since $ runtime_directory)),
  Term.info "log" ~doc ~man

let block_info_cmd =
  let doc = "Information about block devices" in
  let man =
    [`S "DESCRIPTION";
     `P "Block device information."]
  in
  Term.(term_result (const block_info $ setup_log $ socket $ opt_block_name $ runtime_directory)),
  Term.info "block" ~doc ~man

let block_create_cmd =
  let doc = "Create a block device" in
  let man =
    [`S "DESCRIPTION";
     `P "Creation of a block device."]
  in
  Term.(term_result (const block_create $ setup_log $ socket $ block_name $ block_size $ runtime_directory)),
  Term.info "create_block" ~doc ~man

let block_destroy_cmd =
  let doc = "Destroys a block device" in
  let man =
    [`S "DESCRIPTION";
     `P "Destroys a block device."]
  in
  Term.(term_result (const block_destroy $ setup_log $ socket $ block_name $ runtime_directory)),
  Term.info "destroy_block" ~doc ~man

let help_cmd =
  let topic =
    let doc = "The topic to get help on. `topics' lists the topics." in
    Arg.(value & pos 0 (some string) None & info [] ~docv:"TOPIC" ~doc)
  in
  let doc = "display help about vmmc" in
  let man =
    [`S "DESCRIPTION";
     `P "Prints help about albatross local client commands and subcommands"]
  in
  Term.(ret (const help $ setup_log $ socket $ Term.man_format $ Term.choice_names $ topic)),
  Term.info "help" ~doc ~man

let default_cmd =
  let doc = "VMM local client" in
  let man = [
    `S "DESCRIPTION" ;
    `P "$(tname) connects to albatrossd via a local socket" ]
  in
  Term.(ret (const help $ setup_log $ socket $ Term.man_format $ Term.choice_names $ Term.pure None)),
  Term.info "albatross_client_local" ~version:"%%VERSION_NUM%%" ~doc ~man

let cmds = [ help_cmd ; info_cmd ;
             policy_cmd ; remove_policy_cmd ; add_policy_cmd ;
             destroy_cmd ; create_cmd ;
             block_info_cmd ; block_create_cmd ; block_destroy_cmd ;
             console_cmd ;
             stats_subscribe_cmd ; stats_add_cmd ; stats_remove_cmd ; log_cmd ]

let () =
  match Term.eval_choice default_cmd cmds
  with `Ok () -> exit 0 | _ -> exit 1
