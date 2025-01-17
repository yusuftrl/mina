open Core
open Integration_test_lib
open Currency

module Make (Engine : Engine_intf) = struct
  open Engine

  (* TODO: find a way to avoid this type alias (first class module signatures restrictions make this tricky) *)
  type network = Network.t

  type log_engine = Log_engine.t

  let config =
    let open Test_config in
    let open Test_config.Block_producer in
    let timing : Mina_base.Account_timing.t =
      Timed
        { initial_minimum_balance= Balance.of_int 1000
        ; cliff_time= Mina_numbers.Global_slot.of_int 4
        ; cliff_amount= Amount.zero
        ; vesting_period= Mina_numbers.Global_slot.of_int 2
        ; vesting_increment= Amount.of_int 50_000_000_000 }
    in
    { default with
      block_producers=
        [ {balance= "1000"; timing}
        ; {balance= "1000"; timing}
        ; {balance= "1000"; timing} ]
    ; num_snark_workers= 0 }

  let expected_error_event_reprs = []

  let rec to_string_query_results query_results str =
    match query_results with
    | element :: tail ->
        let node_id, peer_list = element in
        to_string_query_results tail
          ( str
          ^ Printf.sprintf "( %s, [%s]) " node_id
              (String.concat ~sep:", " peer_list) )
    | [] ->
        str

  let run network log_engine =
    let open Network in
    let open Malleable_error.Let_syntax in
    let logger = Logger.create () in
    [%log info] "mina_peers_test: started" ;
    let wait_for_init_partial node =
      Log_engine.wait_for_init node log_engine
    in
    let%bind () =
      Malleable_error.List.iter network.block_producers
        ~f:wait_for_init_partial
    in
    [%log info] "mina_peers_test: done waiting for initialization" ;
    let peer_list = network.block_producers in
    (* [%log info] "peers_list"
      ~metadata:
      [("namespace", `String t.namespace); ("pod_id", `String t.pod_id)] ; *)
    let get_peer_id_partial = Node.get_peer_id ~logger in
    (* each element in query_results represents the data of a single node relevant to this test. ( peer_id of node * [list of peer_ids of node's peers] ) *)
    let%bind (query_results : (string * string list) list) =
      Malleable_error.List.map peer_list ~f:get_peer_id_partial
    in
    [%log info]
      "mina_peers_test: successfully made graphql query.  query_results: %s"
      (to_string_query_results query_results "") ;
    let expected_peers, _ = List.unzip query_results in
    let test_compare_func (node_peer_id, visible_peers_of_node) =
      let expected_peers_of_node : string list =
        List.filter
          ~f:(fun p -> not (String.equal p node_peer_id))
          expected_peers
        (* expected_peers_of_node is just expected_peers but with the peer_id of the given node removed from the list *)
      in
      [%log info] "node_peer_id: %s" node_peer_id ;
      [%log info] "expected_peers_of_node: %s"
        (String.concat ~sep:" " expected_peers_of_node) ;
      [%log info] "visible_peers_of_node: %s"
        (String.concat ~sep:" " visible_peers_of_node) ;
      List.iter expected_peers_of_node ~f:(fun p ->
          assert (List.exists visible_peers_of_node ~f:(String.equal p)) )
      (* loop through visible_peers_of_node and make sure everything in that list is also in expected_peers_of_node *)
    in
    [%log info] "mina_peers_test: making assertions" ;
    return (List.iter query_results ~f:test_compare_func)
end
