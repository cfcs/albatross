(* (c) 2018 Hannes Mehnert, all rights reserved *)

type service = [ `Console | `Log | `Stats | `Vmmd ]

val socket_path : tmpdir:Fpath.t -> service -> string
val pp_socket : tmpdir:Fpath.t -> service Fmt.t

module IS : sig
  include Set.S with type elt = int
end

module IM : sig
  include Map.S with type key = int
end

module Name : sig
  type t

  val is_root : t -> bool
  val equal : t -> t -> bool

  val image_file : tmpdir:Fpath.t -> t -> Fpath.t
  (** [image_file tmpdir image_name] is
      [Fpath.(tmpdir/image_name."img")]*)

  val fifo_file : tmpdir:Fpath.t -> t -> Fpath.t
  (** [fifo_file tmpdir fifo_name] is
      [Fpath.(tmpdir/"fifo"/fifo_name)]*)

  val of_list : string list -> (t, [> `Msg of string ]) result
  val to_list : t -> string list
  val append : string -> t -> (t, [> `Msg of string ]) result
  val prepend : string -> t -> (t, [> `Msg of string ]) result
  val append_exn : string -> t -> t

  val root : t
  val valid_label : string -> bool
  val to_string : t -> string
  val of_string : string -> (t, [> `Msg of string ]) result
  val drop_super : super:t -> sub:t -> t option
  val is_sub : super:t -> sub:t -> bool
  val domain : t -> t
  val pp : t Fmt.t
  val block_name : t -> string -> t
end

module Policy : sig
  type t = {
    vms : int;
    cpuids : IS.t;
    memory : int;
    block : int option;
    bridges : Astring.String.Set.t;
  }

  val equal : t -> t -> bool

  val pp : t Fmt.t
end

module Unikernel : sig
  type typ = [ `Hvt_amd64 | `Hvt_amd64_compressed
             | `Hvt_arm64
             | `Spt_amd64 | `Spt_arm64 ]
  val pp_typ : typ Fmt.t

  type config = {
    cpuid : int;
    memory : int;
    block_device : string option;
    network_interfaces : string list;
    image : typ * Cstruct.t;
    argv : string list option;
  }

  val pp_image : (typ * Cstruct.t) Fmt.t

  val pp_config : config Fmt.t

  type t = {
    config : config;
    cmd : Bos.Cmd.t;
    pid : int;
    taps : string list;
  }

  val pp : t Fmt.t
end

module Stats : sig
  type rusage = {
    utime : int64 * int;
    stime : int64 * int;
    maxrss : int64;
    ixrss : int64;
    idrss : int64;
    isrss : int64;
    minflt : int64;
    majflt : int64;
    nswap : int64;
    inblock : int64;
    outblock : int64;
    msgsnd : int64;
    msgrcv : int64;
    nsignals : int64;
    nvcsw : int64;
    nivcsw : int64;
  }
  val pp_rusage : rusage Fmt.t
  val pp_rusage_mem : rusage Fmt.t

  type kinfo_mem = {
    vsize : int64 ;
    rss : int64 ;
    tsize : int64 ;
    dsize : int64 ;
    ssize : int64 ;
  }

  val pp_kinfo_mem : kinfo_mem Fmt.t

  type vmm = (string * int64) list
  val pp_vmm : vmm Fmt.t
  val pp_vmm_mem : vmm Fmt.t

  type ifdata = {
    bridge : string;
    flags : int32;
    send_length : int32;
    max_send_length : int32;
    send_drops : int32;
    mtu : int32;
    baudrate : int64;
    input_packets : int64;
    input_errors : int64;
    output_packets : int64;
    output_errors : int64;
    collisions : int64;
    input_bytes : int64;
    output_bytes : int64;
    input_mcast : int64;
    output_mcast : int64;
    input_dropped : int64;
    output_dropped : int64;
  }
  val pp_ifdata : ifdata Fmt.t

  type t = rusage * kinfo_mem option * vmm option * ifdata list
  val pp : t Fmt.t
end

type process_exit = [ `Exit of int | `Signal of int | `Stop of int ]

val pp_process_exit : process_exit Fmt.t

module Log : sig
  type log_event = [
    | `Login of Name.t * Ipaddr.V4.t * int
    | `Logout of Name.t * Ipaddr.V4.t * int
    | `Startup
    | `Unikernel_start of Name.t * int * string list * string option
    | `Unikernel_stop of Name.t * int * process_exit
    | `Hup
  ]

  val name : log_event -> Name.t

  val pp_log_event : log_event Fmt.t

  type t = Ptime.t * log_event

  val pp : t Fmt.t
end
