(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2016.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

include P2p_types

include Logging.Make(struct let name = "p2p" end)

type 'meta meta_config = 'meta P2p_connection_pool.meta_config = {
  encoding : 'meta Data_encoding.t;
  initial : 'meta;
  score : 'meta -> float
}

type 'msg app_message_encoding = 'msg P2p_connection_pool.encoding =
    Encoding : {
      tag: int ;
      encoding: 'a Data_encoding.t ;
      wrap: 'a -> 'msg ;
      unwrap: 'msg -> 'a option ;
      max_length: int option ;
    } -> 'msg app_message_encoding

type 'msg message_config = 'msg P2p_connection_pool.message_config = {
  encoding : 'msg app_message_encoding list ;
  versions : Version.t list;
}

type config = {
  listening_port : port option;
  listening_addr : addr option;
  trusted_points : Point.t list ;
  peers_file : string ;
  closed_network : bool ;
  identity : Identity.t ;
  proof_of_work_target : Crypto_box.target ;
}

type limits = {

  authentification_timeout : float ;

  min_connections : int ;
  expected_connections : int ;
  max_connections : int ;

  backlog : int ;
  max_incoming_connections : int ;

  max_download_speed : int option ;
  max_upload_speed : int option ;

  read_buffer_size : int ;
  read_queue_size : int option ;
  write_queue_size : int option ;
  incoming_app_message_queue_size : int option ;
  incoming_message_queue_size : int option ;
  outgoing_message_queue_size : int option ;

  known_gids_history_size : int ;
  known_points_history_size : int ;
  max_known_gids : (int * int) option ;
  max_known_points : (int * int) option ;
}

let create_scheduler limits =
  let max_upload_speed =
    map_option limits.max_upload_speed ~f:(( * ) 1024) in
  let max_download_speed =
    map_option limits.max_upload_speed ~f:(( * ) 1024) in
  P2p_io_scheduler.create
    ~read_buffer_size:limits.read_buffer_size
    ?max_upload_speed
    ?max_download_speed
    ?read_queue_size:limits.read_queue_size
    ?write_queue_size:limits.write_queue_size
    ()

let create_connection_pool config limits meta_cfg msg_cfg io_sched =
  let pool_cfg = {
    P2p_connection_pool.identity = config.identity ;
    proof_of_work_target = config.proof_of_work_target ;
    listening_port = config.listening_port ;
    trusted_points = config.trusted_points ;
    peers_file = config.peers_file ;
    closed_network = config.closed_network ;
    min_connections = limits.min_connections ;
    max_connections = limits.max_connections ;
    max_incoming_connections = limits.max_incoming_connections ;
    authentification_timeout = limits.authentification_timeout ;
    incoming_app_message_queue_size = limits.incoming_app_message_queue_size ;
    incoming_message_queue_size = limits.incoming_message_queue_size ;
    outgoing_message_queue_size = limits.outgoing_message_queue_size ;
    known_gids_history_size = limits.known_gids_history_size ;
    known_points_history_size = limits.known_points_history_size ;
    max_known_points = limits.max_known_points ;
    max_known_gids = limits.max_known_gids ;
  }
  in
  let pool =
    P2p_connection_pool.create pool_cfg meta_cfg msg_cfg io_sched in
  pool

let bounds ~min ~expected ~max =
  assert (min <= expected) ;
  assert (expected <= max) ;
  let step_min =
    (expected - min) / 3
  and step_max =
    (max - expected) / 3 in
  { P2p_maintenance.min_threshold = min + step_min ;
    min_target = min + 2 * step_min ;
    max_target = max - 2 * step_max ;
    max_threshold = max - step_max ;
  }

let may_create_discovery_worker _config pool =
  Some (P2p_discovery.create pool)

let create_maintenance_worker limits pool disco =
  let bounds =
    bounds
      limits.min_connections
      limits.expected_connections
      limits.max_connections
  in
  P2p_maintenance.run
    ~connection_timeout:limits.authentification_timeout bounds pool disco

let may_create_welcome_worker config limits pool =
  match config.listening_port with
  | None -> Lwt.return None
  | Some port ->
      P2p_welcome.run
        ~backlog:limits.backlog pool
        ?addr:config.listening_addr
        port >>= fun w ->
      Lwt.return (Some w)

type ('msg, 'meta) connection = ('msg, 'meta) P2p_connection_pool.connection

module Real = struct

  type ('msg, 'meta) net = {
    config: config ;
    limits: limits ;
    io_sched: P2p_io_scheduler.t ;
    pool: ('msg, 'meta) P2p_connection_pool.t ;
    discoverer: P2p_discovery.t option ;
    maintenance: 'meta P2p_maintenance.t ;
    welcome: P2p_welcome.t option ;
  }

  let create ~config ~limits meta_cfg msg_cfg =
    let io_sched = create_scheduler limits in
    create_connection_pool
      config limits meta_cfg msg_cfg io_sched >>= fun pool ->
    let discoverer = may_create_discovery_worker config pool in
    let maintenance = create_maintenance_worker limits pool discoverer in
    may_create_welcome_worker config limits pool >>= fun welcome ->
    Lwt.return {
      config ;
      limits ;
      io_sched ;
      pool ;
      discoverer ;
      maintenance ;
      welcome ;
    }

  let gid { config } = config.identity.gid

  let maintain { maintenance } () =
    P2p_maintenance.maintain maintenance

  let roll _net () = Lwt.return_unit (* TODO implement *)

  (* returns when all workers have shutted down in the opposite
     creation order. *)
  let shutdown net () =
    Lwt_utils.may ~f:P2p_welcome.shutdown net.welcome >>= fun () ->
    P2p_maintenance.shutdown net.maintenance >>= fun () ->
    Lwt_utils.may ~f:P2p_discovery.shutdown net.discoverer >>= fun () ->
    P2p_connection_pool.destroy net.pool >>= fun () ->
    P2p_io_scheduler.shutdown ~timeout:3.0 net.io_sched

  let connections { pool } () =
    P2p_connection_pool.fold_connections pool
      ~init:[] ~f:(fun _gid c acc -> c :: acc)
  let find_connection { pool } gid =
    P2p_connection_pool.Gids.find_connection pool gid
  let connection_info _net conn =
    P2p_connection_pool.connection_info conn
  let connection_stat _net conn =
    P2p_connection_pool.connection_stat conn
  let global_stat { pool } () =
    P2p_connection_pool.pool_stat pool
  let set_metadata { pool } conn meta =
    P2p_connection_pool.Gids.set_metadata pool conn meta
  let get_metadata { pool } conn =
    P2p_connection_pool.Gids.get_metadata pool conn

  let rec recv _net conn =
    P2p_connection_pool.read conn >>=? fun msg ->
    lwt_debug "message read from %a"
      Connection_info.pp
      (P2p_connection_pool.connection_info conn) >>= fun () ->
    return msg

  let rec recv_any net () =
    let pipes =
      P2p_connection_pool.fold_connections
        net.pool ~init:[]
        ~f:begin fun _gid conn acc ->
        (P2p_connection_pool.is_readable conn >>= function
          | Ok () -> Lwt.return (Some conn)
          | Error _ -> Lwt_utils.never_ending) :: acc
      end in
    Lwt.pick (
      ( P2p_connection_pool.PoolEvent.wait_new_connection net.pool >>= fun () ->
        Lwt.return_none )::
      pipes) >>= function
    | None -> recv_any net ()
    | Some conn ->
        P2p_connection_pool.read conn >>= function
        | Ok msg ->
            lwt_debug "message read from %a"
              Connection_info.pp
              (P2p_connection_pool.connection_info conn) >>= fun () ->
            Lwt.return (conn, msg)
        | Error _ ->
            lwt_debug "error reading message from %a"
              Connection_info.pp
              (P2p_connection_pool.connection_info conn) >>= fun () ->
            Lwt_unix.yield () >>= fun () ->
            recv_any net ()

  let send _net conn m =
    P2p_connection_pool.write conn m >>= function
    | Ok () ->
        lwt_debug "message sent to %a"
          Connection_info.pp
          (P2p_connection_pool.connection_info conn) >>= fun () ->
        Lwt.return_unit
    | Error _ ->
        lwt_debug "error sending message from %a"
          Connection_info.pp
          (P2p_connection_pool.connection_info conn) >>= fun () ->
        Lwt.fail End_of_file (* temporary *)

  let try_send _net conn v =
    match P2p_connection_pool.write_now conn v with
    | Ok v ->
        Lwt.ignore_result
          (lwt_debug "message trysent to %a"
             Connection_info.pp
             (P2p_connection_pool.connection_info conn)) ;
        v
    | Error _ ->
        Lwt.ignore_result
          (lwt_debug "error trysending message to %a"
             Connection_info.pp
             (P2p_connection_pool.connection_info conn)) ;
        false

  let broadcast { pool } msg =
    P2p_connection_pool.write_all pool msg ;
    Lwt.ignore_result (lwt_debug "message broadcasted")

  let pool { pool } = pool
end

module Fake = struct

  let id = Identity.generate (Crypto_box.make_target 0.)
  let empty_stat = {
    Stat.total_sent = 0L ;
    total_recv = 0L ;
    current_inflow = 0 ;
    current_outflow = 0 ;
  }
  let connection_info = {
    Connection_info.incoming = false ;
    gid = id.gid ;
    id_point = (Ipaddr.V6.unspecified, None) ;
    remote_socket_port = 0 ;
    versions = [] ;
  }

end

type ('msg, 'meta) t = {
  gid : Gid.t ;
  maintain : unit -> unit Lwt.t ;
  roll : unit -> unit Lwt.t ;
  shutdown : unit -> unit Lwt.t ;
  connections : unit -> ('msg, 'meta) connection list ;
  find_connection : Gid.t -> ('msg, 'meta) connection option ;
  connection_info : ('msg, 'meta) connection -> Connection_info.t ;
  connection_stat : ('msg, 'meta) connection -> Stat.t ;
  global_stat : unit -> Stat.t ;
  get_metadata : Gid.t -> 'meta option ;
  set_metadata : Gid.t -> 'meta -> unit ;
  recv : ('msg, 'meta) connection -> 'msg tzresult Lwt.t ;
  recv_any : unit -> (('msg, 'meta) connection * 'msg) Lwt.t ;
  send : ('msg, 'meta) connection -> 'msg -> unit Lwt.t ;
  try_send : ('msg, 'meta) connection -> 'msg -> bool ;
  broadcast : 'msg -> unit ;
  pool : ('msg, 'meta) P2p_connection_pool.t option ;
}
type ('msg, 'meta) net = ('msg, 'meta) t

let create ~config ~limits meta_cfg msg_cfg =
  Real.create ~config ~limits meta_cfg msg_cfg  >>= fun net ->
  Lwt.return {
    gid = Real.gid net ;
    maintain = Real.maintain net ;
    roll = Real.roll net  ;
    shutdown = Real.shutdown net  ;
    connections = Real.connections net  ;
    find_connection = Real.find_connection net ;
    connection_info = Real.connection_info net  ;
    connection_stat = Real.connection_stat net ;
    global_stat = Real.global_stat net ;
    get_metadata = Real.get_metadata net ;
    set_metadata = Real.set_metadata net ;
    recv = Real.recv net ;
    recv_any = Real.recv_any net ;
    send = Real.send net ;
    try_send = Real.try_send net ;
    broadcast = Real.broadcast net ;
    pool = Some net.pool ;
  }

let faked_network = {
  gid = Fake.id.gid ;
  maintain = Lwt.return ;
  roll = Lwt.return ;
  shutdown = Lwt.return ;
  connections = (fun () -> []) ;
  find_connection = (fun _ -> None) ;
  connection_info = (fun _ -> Fake.connection_info) ;
  connection_stat = (fun _ -> Fake.empty_stat) ;
  global_stat = (fun () -> Fake.empty_stat) ;
  get_metadata = (fun _ -> None) ;
  set_metadata = (fun _ _ -> ()) ;
  recv = (fun _ -> Lwt_utils.never_ending) ;
  recv_any = (fun () -> Lwt_utils.never_ending) ;
  send = (fun _ _ -> Lwt_utils.never_ending) ;
  try_send = (fun _ _ -> false) ;
  broadcast = ignore ;
  pool = None
}

let gid net = net.gid
let maintain net = net.maintain ()
let roll net = net.roll ()
let shutdown net = net.shutdown ()
let connections net = net.connections ()
let find_connection net = net.find_connection
let connection_info net = net.connection_info
let connection_stat net = net.connection_stat
let global_stat net = net.global_stat ()
let get_metadata net = net.get_metadata
let set_metadata net = net.set_metadata
let recv net = net.recv
let recv_any net = net.recv_any ()
let send net = net.send
let try_send net = net.try_send
let broadcast net = net.broadcast

module Raw = struct
  type 'a t = 'a P2p_connection_pool.Message.t =
    | Bootstrap
    | Advertise of P2p_types.Point.t list
    | Message of 'a
    | Disconnect
  let encoding = P2p_connection_pool.Message.encoding
end

module RPC = struct

  let stat net =
    match net.pool with
    | None -> Stat.empty
    | Some pool -> P2p_connection_pool.pool_stat pool

  module Event = P2p_connection_pool.LogEvent

  let watch net =
    match net.pool with
    | None -> Watcher.create_fake_stream ()
    | Some pool -> P2p_connection_pool.watch pool

  let connect net point timeout =
    match net.pool with
    | None -> fail (Unclassified "fake net")
    | Some pool ->
        P2p_connection_pool.connect ~timeout pool point >>|? ignore

  module Connection = struct
    let info net gid =
      match net.pool with
      | None -> None
      | Some pool ->
          map_option
            (P2p_connection_pool.Gids.find_connection pool gid)
            ~f:P2p_connection_pool.connection_info

    let kick net gid wait =
      match net.pool with
      | None -> Lwt.return_unit
      | Some pool ->
          match P2p_connection_pool.Gids.find_connection pool gid with
          | None -> Lwt.return_unit
          | Some conn -> P2p_connection_pool.disconnect ~wait conn

    let list net =
      match net.pool with
      | None -> []
      | Some pool ->
          P2p_connection_pool.fold_connections
            pool ~init:[]
            ~f:begin fun _gid c acc ->
              P2p_connection_pool.connection_info c :: acc
            end

    let count net =
      match net.pool with
      | None -> 0
      | Some pool -> P2p_connection_pool.active_connections pool
  end

  module Point = struct
    type state =
      | Requested
      | Accepted
      | Running
      | Disconnected

    let state_encoding =
      let open Data_encoding in
      string_enum [
        "requested", Requested ;
        "accepted", Accepted ;
        "running", Running ;
        "disconnected", Disconnected ;
      ]

    type info = {
      trusted : bool ;
      greylisted_end : Time.t ;
      state : state ;
      gid : Gid.t option ;
      last_failed_connection : Time.t option ;
      last_rejected_connection : (Gid.t * Time.t) option ;
      last_established_connection : (Gid.t * Time.t) option ;
      last_disconnection : (Gid.t * Time.t) option ;
      last_seen : (Gid.t * Time.t) option ;
      last_miss : Time.t option ;
    }

    let info_encoding =
      let open Data_encoding in
      conv
        (fun { trusted ; greylisted_end ; state ; gid ;
               last_failed_connection ; last_rejected_connection ;
               last_established_connection ; last_disconnection ;
               last_seen ; last_miss ;
             } ->
          (trusted, greylisted_end, state, gid,
           last_failed_connection, last_rejected_connection,
           last_established_connection, last_disconnection,
           last_seen, last_miss)
        )
        (fun (trusted, greylisted_end, state, gid,
              last_failed_connection, last_rejected_connection,
              last_established_connection, last_disconnection,
              last_seen, last_miss) ->
          { trusted ; greylisted_end ; state ; gid ;
            last_failed_connection ; last_rejected_connection ;
            last_established_connection ; last_disconnection ;
            last_seen ; last_miss ;
          }
        )
        (obj10
           (req "trusted" bool)
           (dft "greylisted_end" Time.encoding Time.epoch)
           (req "state" state_encoding)
           (opt "gid" Gid.encoding)
           (opt "last_failed_connection" Time.encoding)
           (opt "last_rejected_connection" (tup2 Gid.encoding Time.encoding))
           (opt "last_established_connection" (tup2 Gid.encoding Time.encoding))
           (opt "last_disconnection" (tup2 Gid.encoding Time.encoding))
           (opt "last_seen" (tup2 Gid.encoding Time.encoding))
           (opt "last_miss" Time.encoding))

    let info_of_point_info i =
      let open P2p_connection_pool in
      let open P2p_connection_pool_types in
      let state, gid = match Point_info.State.get i with
        | Requested _ -> Requested, None
        | Accepted { current_gid } -> Accepted, Some current_gid
        | Running { current_gid } -> Running, Some current_gid
        | Disconnected -> Disconnected, None in
      Point_info.{
        trusted = trusted i ;
        state ; gid ;
        greylisted_end = greylisted_end i ;
        last_failed_connection = last_failed_connection i ;
        last_rejected_connection = last_rejected_connection i ;
        last_established_connection = last_established_connection i ;
        last_disconnection = last_disconnection i ;
        last_seen = last_seen i ;
        last_miss = last_miss i ;
      }

    let info net point =
      match net.pool with
      | None -> None
      | Some pool ->
          map_option
            (P2p_connection_pool.Points.info pool point)
            ~f:info_of_point_info

    module Event = P2p_connection_pool_types.Point_info.Event

    let events ?(max=max_int) ?(rev=false) net point =
      match net.pool with
      | None -> []
      | Some pool ->
          unopt_map
            (P2p_connection_pool.Points.info pool point)
            ~default:[]
            ~f:begin fun pi ->
              let evts =
                P2p_connection_pool_types.Point_info.fold_events
                  pi ~init:[] ~f:(fun a e -> e :: a) in
              (if rev then list_rev_sub else list_sub) evts max
            end

    let watch net point =
      match net.pool with
      | None -> raise Not_found
      | Some pool ->
          match P2p_connection_pool.Points.info pool point with
          | None -> raise Not_found
          | Some pi -> P2p_connection_pool_types.Point_info.watch pi

    let infos ?(restrict=[]) net =
      match net.pool with
      | None -> []
      | Some pool ->
          P2p_connection_pool.Points.fold_known
            pool ~init:[]
            ~f:begin fun point i a ->
              let info = info_of_point_info i in
              match restrict with
              | [] -> (point, info) :: a
              | _ when List.mem info.state restrict -> (point, info) :: a
              | _ -> a
            end

  end

  module Gid = struct
    type state =
      | Accepted
      | Running
      | Disconnected

    let state_encoding =
      let open Data_encoding in
      string_enum [
        "accepted", Accepted ;
        "running", Running ;
        "disconnected", Disconnected ;
      ]

    type info = {
      score : float ;
      trusted : bool ;
      state : state ;
      id_point : Id_point.t option ;
      stat : Stat.t ;
      last_failed_connection : (Id_point.t * Time.t) option ;
      last_rejected_connection : (Id_point.t * Time.t) option ;
      last_established_connection : (Id_point.t * Time.t) option ;
      last_disconnection : (Id_point.t * Time.t) option ;
      last_seen : (Id_point.t * Time.t) option ;
      last_miss : (Id_point.t * Time.t) option ;
    }

    let info_encoding =
      let open Data_encoding in
      conv
        (fun (
           { score ; trusted ; state ; id_point ; stat ;
             last_failed_connection ; last_rejected_connection ;
             last_established_connection ; last_disconnection ;
             last_seen ; last_miss }) ->
           ((score, trusted, state, id_point, stat),
            (last_failed_connection, last_rejected_connection,
             last_established_connection, last_disconnection,
             last_seen, last_miss)))
        (fun ((score, trusted, state, id_point, stat),
              (last_failed_connection, last_rejected_connection,
               last_established_connection, last_disconnection,
               last_seen, last_miss)) ->
          { score ; trusted ; state ; id_point ; stat ;
            last_failed_connection ; last_rejected_connection ;
            last_established_connection ; last_disconnection ;
            last_seen ; last_miss })
        (merge_objs
           (obj5
              (req "score" float)
              (req "trusted" bool)
              (req "state" state_encoding)
              (opt "id_point" Id_point.encoding)
              (req "stat" Stat.encoding))
           (obj6
              (opt "last_failed_connection" (tup2 Id_point.encoding Time.encoding))
              (opt "last_rejected_connection" (tup2 Id_point.encoding Time.encoding))
              (opt "last_established_connection" (tup2 Id_point.encoding Time.encoding))
              (opt "last_disconnection" (tup2 Id_point.encoding Time.encoding))
              (opt "last_seen" (tup2 Id_point.encoding Time.encoding))
              (opt "last_miss" (tup2 Id_point.encoding Time.encoding))))

    let info_of_gid_info pool i =
      let open P2p_connection_pool in
      let open P2p_connection_pool_types in
      let state, id_point = match Gid_info.State.get i with
        | Accepted { current_point } -> Accepted, Some current_point
        | Running { current_point } -> Running, Some current_point
        | Disconnected -> Disconnected, None
      in
      let gid = Gid_info.gid i in
      let meta = Gid_info.metadata i in
      let score = P2p_connection_pool.score pool meta in
      let stat =
        match P2p_connection_pool.Gids.find_connection pool gid with
        | None -> Stat.empty
        | Some conn -> P2p_connection_pool.connection_stat conn
      in Gid_info.{
          score ;
          trusted = trusted i ;
          state ;
          id_point ;
          stat ;
          last_failed_connection = last_failed_connection i ;
          last_rejected_connection = last_rejected_connection i ;
          last_established_connection = last_established_connection i ;
          last_disconnection = last_disconnection i ;
          last_seen = last_seen i ;
          last_miss = last_miss i ;
        }

    let info net gid =
      match net.pool with
      | None -> None
      | Some pool -> begin
          match P2p_connection_pool.Gids.info pool gid with
          | Some info -> Some (info_of_gid_info pool info)
          | None -> None
        end

    module Event = P2p_connection_pool_types.Gid_info.Event

    let events ?(max=max_int) ?(rev=false) net gid =
      match net.pool with
      | None -> []
      | Some pool ->
          unopt_map
            (P2p_connection_pool.Gids.info pool gid)
            ~default:[]
            ~f:begin fun gi ->
              let evts = P2p_connection_pool_types.Gid_info.fold_events gi
                  ~init:[] ~f:(fun a e -> e :: a) in
              (if rev then list_rev_sub else list_sub) evts max
            end

    let watch net gid =
      match net.pool with
      | None -> raise Not_found
      | Some pool ->
          match P2p_connection_pool.Gids.info pool gid with
          | None -> raise Not_found
          | Some gi -> P2p_connection_pool_types.Gid_info.watch gi

    let infos ?(restrict=[]) net =
      match net.pool with
      | None -> []
      | Some pool ->
          P2p_connection_pool.Gids.fold_known pool
            ~init:[]
            ~f:begin fun gid i a ->
              let info = info_of_gid_info pool i in
              match restrict with
              | [] -> (gid, info) :: a
              | _ when List.mem info.state restrict -> (gid, info) :: a
              | _ -> a
            end

  end

end
