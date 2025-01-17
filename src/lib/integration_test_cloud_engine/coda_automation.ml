open Core
open Async
open Currency
open Signature_lib
open Mina_base
open Integration_test_lib
open Unix

module Network_config = struct
  type block_producer_config =
    { name: string
    ; class_: string [@key "class"]
    ; id: string
    ; private_key_secret: string
    ; enable_gossip_flooding: bool
    ; run_with_user_agent: bool
    ; run_with_bots: bool
    ; enable_peer_exchange: bool
    ; isolated: bool }
  [@@deriving to_yojson]

  type terraform_config =
    { cluster_name: string
    ; cluster_region: string
    ; testnet_name: string
    ; k8s_context: string
    ; coda_image: string
    ; coda_agent_image: string
    ; coda_bots_image: string
    ; coda_points_image: string
          (* this field needs to be sent as a string to terraform, even though it's a json encoded value *)
    ; runtime_config: Yojson.Safe.t
          [@to_yojson fun j -> `String (Yojson.Safe.to_string j)]
    ; coda_faucet_amount: string
    ; coda_faucet_fee: string
    ; seed_zone: string
    ; seed_region: string
    ; log_level: string
    ; log_txn_pool_gossip: bool
    ; block_producer_key_pass: string
    ; block_producer_starting_host_port: int
    ; block_producer_configs: block_producer_config list
    ; snark_worker_replicas: int
    ; snark_worker_fee: string
    ; snark_worker_public_key: string
    ; snark_worker_host_port: int
    ; agent_min_fee: string
    ; agent_max_fee: string
    ; agent_min_tx: string
    ; agent_max_tx: string }
  [@@deriving to_yojson]

  type t =
    { coda_automation_location: string
    ; project_id: string
    ; cluster_id: string
    ; keypairs: (string * Keypair.t) list
    ; constraint_constants: Genesis_constants.Constraint_constants.t
    ; genesis_constants: Genesis_constants.t
    ; terraform: terraform_config }
  [@@deriving to_yojson]

  let terraform_config_to_assoc t =
    let[@warning "-8"] (`Assoc assoc : Yojson.Safe.t) =
      terraform_config_to_yojson t
    in
    assoc

  let expand ~logger ~test_name ~(cli_inputs : Cli_inputs.t)
      ~(test_config : Test_config.t) ~(images : Container_images.t) =
    let { Test_config.k
        ; delta
        ; slots_per_epoch
        ; slots_per_sub_window
        ; proof_level
        ; txpool_max_size
        ; block_producers
        ; num_snark_workers
        ; snark_worker_fee
        ; snark_worker_public_key } =
      test_config
    in
    let user_from_env = Option.value (Unix.getenv "USER") ~default:"" in
    let user_sanitized =
      Str.global_replace (Str.regexp "\\W|_") "" user_from_env
    in
    let user_len = Int.min 5 (String.length user_sanitized) in
    let user = String.sub user_sanitized ~pos:0 ~len:user_len in
    let time_now = Unix.gmtime (Unix.gettimeofday ()) in
    let timestr =
      string_of_int time_now.tm_mday
      ^ string_of_int time_now.tm_hour
      ^ string_of_int time_now.tm_min
    in
    (* append the first 5 chars of the local system username of the person running the test, test name, and part of the timestamp onto the back of an integration test to disambiguate different test deployments, format is: *)
    (* username-testname-DaymonthHrMin *)
    (* ex: adalo-block-production-151134 ; user is adalovelace, running block production test, 15th of a month, 11:34 AM, GMT time*)
    let testnet_name = user ^ "-" ^ test_name ^ "-" ^ timestr in
    (* HARD CODED NETWORK VALUES *)
    let project_id = "o1labs-192920" in
    let cluster_id = "gke_o1labs-192920_us-west1_mina-integration-west1" in
    let cluster_name = "mina-integration-west1" in
    let k8s_context = cluster_id in
    let cluster_region = "us-west1" in
    let seed_zone = "us-west1-a" in
    let seed_region = "us-west1" in
    (* GENERATE ACCOUNTS AND KEYPAIRS *)
    let num_block_producers = List.length block_producers in
    let block_producer_keypairs, runtime_accounts =
      let keypairs = Array.to_list (Lazy.force Sample_keypairs.keypairs) in
      if List.length block_producers > List.length keypairs then
        failwith
          "not enough sample keypairs for specified number of block producers" ;
      let f index ({Test_config.Block_producer.balance; timing}, (pk, sk)) =
        let runtime_account =
          let timing =
            match timing with
            | Account.Timing.Untimed ->
                None
            | Timed t ->
                Some
                  { Runtime_config.Accounts.Single.Timed.initial_minimum_balance=
                      t.initial_minimum_balance
                  ; cliff_time= t.cliff_time
                  ; cliff_amount= t.cliff_amount
                  ; vesting_period= t.vesting_period
                  ; vesting_increment= t.vesting_increment }
          in
          let default = Runtime_config.Accounts.Single.default in
          { default with
            pk= Some (Public_key.Compressed.to_string pk)
          ; sk= None
          ; balance=
              Balance.of_formatted_string balance
              (* delegation currently unsupported *)
          ; delegate= None
          ; timing }
        in
        let secret_name = "test-keypair-" ^ Int.to_string index in
        let keypair =
          {Keypair.public_key= Public_key.decompress_exn pk; private_key= sk}
        in
        ((secret_name, keypair), runtime_account)
      in
      List.mapi ~f
        (List.zip_exn block_producers
           (List.take keypairs (List.length block_producers)))
      |> List.unzip
    in
    (* DAEMON CONFIG *)
    let proof_config =
      (* TODO: lift configuration of these up Test_config.t *)
      { Runtime_config.Proof_keys.level= Some proof_level
      ; sub_windows_per_window= None
      ; ledger_depth= None
      ; work_delay= None
      ; block_window_duration_ms= None
      ; transaction_capacity= None
      ; coinbase_amount= None
      ; supercharged_coinbase_factor= None
      ; account_creation_fee= None
      ; fork= None }
    in
    let constraint_constants =
      Genesis_ledger_helper.make_constraint_constants
        ~default:Genesis_constants.Constraint_constants.compiled proof_config
    in
    let runtime_config =
      { Runtime_config.daemon= Some {txpool_max_size= Some txpool_max_size}
      ; genesis=
          Some
            { k= Some k
            ; delta= Some delta
            ; slots_per_epoch= Some slots_per_epoch
            ; sub_windows_per_window=
                Some constraint_constants.supercharged_coinbase_factor
            ; slots_per_sub_window= Some slots_per_sub_window
            ; genesis_state_timestamp=
                Some Core.Time.(to_string_abs ~zone:Zone.utc (now ())) }
      ; proof= Some proof_config (* TODO: prebake ledger and only set hash *)
      ; ledger=
          Some
            { base= Accounts runtime_accounts
            ; add_genesis_winner= None
            ; num_accounts= None
            ; balances= []
            ; hash= None
            ; name= None }
      ; epoch_data= None }
    in
    let genesis_constants =
      Or_error.ok_exn
        (Genesis_ledger_helper.make_genesis_constants ~logger
           ~default:Genesis_constants.compiled runtime_config)
    in
    (* BLOCK PRODUCER CONFIG *)
    let base_port = 10001 in
    let block_producer_config index (secret_name, _) =
      { name= "test-block-producer-" ^ Int.to_string (index + 1)
      ; class_= "test"
      ; id= Int.to_string index
      ; private_key_secret= secret_name
      ; enable_gossip_flooding= false
      ; run_with_user_agent= false
      ; run_with_bots= false
      ; enable_peer_exchange= false
      ; isolated= false }
    in
    (* NETWORK CONFIG *)
    { coda_automation_location= cli_inputs.coda_automation_location
    ; project_id
    ; cluster_id
    ; keypairs= block_producer_keypairs
    ; constraint_constants
    ; genesis_constants
    ; terraform=
        { cluster_name
        ; cluster_region
        ; testnet_name
        ; seed_zone
        ; seed_region
        ; k8s_context
        ; coda_image= images.coda
        ; coda_agent_image= images.user_agent
        ; coda_bots_image= images.bots
        ; coda_points_image= images.points
        ; runtime_config= Runtime_config.to_yojson runtime_config
        ; block_producer_key_pass= "naughty blue worm"
        ; block_producer_starting_host_port= base_port
        ; block_producer_configs=
            List.mapi block_producer_keypairs ~f:block_producer_config
        ; snark_worker_replicas= num_snark_workers
        ; snark_worker_host_port= base_port + num_block_producers
        ; snark_worker_public_key
        ; snark_worker_fee
            (* log level is currently statically set and not directly configurable *)
        ; log_level= "Trace"
        ; log_txn_pool_gossip=
            true
            (* these currently aren't used for testnets, so we just give them defaults *)
        ; coda_faucet_amount= "10000000000"
        ; coda_faucet_fee= "100000000"
        ; agent_min_fee= "0.06"
        ; agent_max_fee= "0.1"
        ; agent_min_tx= "0.0015"
        ; agent_max_tx= "0.0015" } }

  let to_terraform network_config =
    let open Terraform in
    [ Block.Terraform
        { Block.Terraform.required_version= "~> 0.13.0"
        ; backend=
            Backend.S3
              { Backend.S3.key=
                  "terraform-" ^ network_config.terraform.testnet_name
                  ^ ".tfstate"
              ; encrypt= true
              ; region= "us-west-2"
              ; bucket= "o1labs-terraform-state"
              ; acl= "bucket-owner-full-control" } }
    ; Block.Provider
        { Block.Provider.provider= "aws"
        ; region= "us-west-2"
        ; zone= None
        ; alias= None
        ; project= None }
    ; Block.Provider
        { Block.Provider.provider= "google"
        ; region= network_config.terraform.cluster_region
        ; zone= Some "us-east1b"
        ; alias= Some "google-us-east1"
        ; project= Some network_config.project_id }
    ; Block.Module
        { Block.Module.local_name= "testnet_east"
        ; providers= [("google", ("google", "google-us-east1"))]
        ; source= "../../modules/kubernetes/testnet"
        ; args= terraform_config_to_assoc network_config.terraform } ]

  let testnet_log_filter network_config =
    Printf.sprintf
      {|
        resource.labels.project_id="%s"
        resource.labels.location="%s"
        resource.labels.cluster_name="%s"
        resource.labels.namespace_name="%s"
      |}
      network_config.project_id network_config.terraform.cluster_region
      network_config.terraform.cluster_name
      network_config.terraform.testnet_name
end

module Network_manager = struct
  type t =
    { logger: Logger.t
    ; cluster: string
    ; namespace: string
    ; keypair_secrets: string list
    ; testnet_dir: string
    ; testnet_log_filter: string
    ; constraint_constants: Genesis_constants.Constraint_constants.t
    ; genesis_constants: Genesis_constants.t
    ; block_producer_pod_names: Kubernetes_network.Node.t list
    ; snark_coordinator_pod_names: Kubernetes_network.Node.t list
    ; mutable deployed: bool
    ; keypairs: Keypair.t list }

  let run_cmd t prog args = Cmd_util.run_cmd t.testnet_dir prog args

  let run_cmd_exn t prog args = Cmd_util.run_cmd_exn t.testnet_dir prog args

  let create ~logger (network_config : Network_config.t) =
    let testnet_dir =
      network_config.coda_automation_location ^/ "terraform/testnets"
      ^/ network_config.terraform.testnet_name
    in
    (* cleanup old deployment, if it exists; we will need to take good care of this logic when we put this in CI *)
    let%bind () =
      if%bind File_system.dir_exists testnet_dir then (
        [%log warn]
          "Old network deployment found; attempting to refresh and cleanup" ;
        let%bind () =
          Cmd_util.run_cmd_exn testnet_dir "terraform" ["refresh"]
        in
        let%bind () =
          let open Process.Output in
          let%bind state_output =
            Cmd_util.run_cmd testnet_dir "terraform" ["state"; "list"]
          in
          if not (String.is_empty state_output.stdout) then
            Cmd_util.run_cmd_exn testnet_dir "terraform"
              ["destroy"; "-auto-approve"]
          else return ()
        in
        File_system.remove_dir testnet_dir )
      else return ()
    in
    [%log info] "Writing network configuration" ;
    let%bind () = Unix.mkdir testnet_dir in
    (* TODO: prebuild genesis proof and ledger *)
    (*
    let%bind inputs =
      Genesis_ledger_helper.Genesis_proof.generate_inputs ~proof_level ~ledger
        ~constraint_constants ~genesis_constants
    in
    let%bind (_, genesis_proof_filename) =
      Genesis_ledger_helper.Genesis_proof.load_or_generate ~logger ~genesis_dir ~may_generate:true
        inputs
    in
    *)
    Out_channel.with_file ~fail_if_exists:true (testnet_dir ^/ "main.tf.json")
      ~f:(fun ch ->
        Network_config.to_terraform network_config
        |> Terraform.to_string
        |> Out_channel.output_string ch ) ;
    let%bind () =
      Deferred.List.iter network_config.keypairs
        ~f:(fun (secret_name, keypair) ->
          Secrets.Keypair.write_exn keypair
            ~privkey_path:(testnet_dir ^/ secret_name)
            ~password:(lazy (return (Bytes.of_string "naughty blue worm"))) )
    in
    let testnet_log_filter =
      Network_config.testnet_log_filter network_config
    in
    let cons_node pod_id port =
      { Kubernetes_network.Node.cluster= network_config.cluster_id
      ; Kubernetes_network.Node.namespace=
          network_config.terraform.testnet_name
      ; Kubernetes_network.Node.pod_id
      ; Kubernetes_network.Node.node_graphql_port= port }
    in
    (* we currently only deploy 1 coordinator per deploy (will be configurable later) *)
    let snark_coordinator_pod_names = [cons_node "snark-coordinator-1" 3085] in
    let block_producer_pod_names =
      List.init (List.length network_config.terraform.block_producer_configs)
        ~f:(fun i ->
          cons_node (Printf.sprintf "test-block-producer-%d" (i + 1)) (i + 3086)
      )
    in
    let t =
      { logger
      ; cluster= network_config.cluster_id
      ; namespace= network_config.terraform.testnet_name
      ; testnet_dir
      ; testnet_log_filter
      ; constraint_constants= network_config.constraint_constants
      ; genesis_constants= network_config.genesis_constants
      ; keypair_secrets= List.map network_config.keypairs ~f:fst
      ; block_producer_pod_names
      ; snark_coordinator_pod_names
      ; deployed= false
      ; keypairs= List.unzip network_config.keypairs |> snd }
    in
    [%log info] "Initializing terraform" ;
    let%bind () = run_cmd_exn t "terraform" ["init"] in
    let%map () = run_cmd_exn t "terraform" ["validate"] in
    t

  let deploy t =
    if t.deployed then failwith "network already deployed" ;
    [%log' info t.logger] "Deploying network" ;
    let%bind () = run_cmd_exn t "terraform" ["apply"; "-auto-approve"] in
    [%log' info t.logger] "Uploading network secrets" ;
    let%map () =
      Deferred.List.iter t.keypair_secrets ~f:(fun secret ->
          run_cmd_exn t "kubectl"
            [ "create"
            ; "secret"
            ; "generic"
            ; secret
            ; "--cluster=" ^ t.cluster
            ; "--namespace=" ^ t.namespace
            ; "--from-file=key=" ^ secret
            ; "--from-file=pub=" ^ secret ^ ".pub" ] )
    in
    t.deployed <- true ;
    { Kubernetes_network.namespace= t.namespace
    ; constraint_constants= t.constraint_constants
    ; genesis_constants= t.genesis_constants
    ; block_producers= t.block_producer_pod_names
    ; snark_coordinators= t.snark_coordinator_pod_names
    ; archive_nodes= []
    ; testnet_log_filter= t.testnet_log_filter
    ; keypairs= t.keypairs }

  let destroy t =
    [%log' info t.logger] "Destroying network" ;
    if not t.deployed then failwith "network not deployed" ;
    let%bind () = run_cmd_exn t "terraform" ["destroy"; "-auto-approve"] in
    t.deployed <- false ;
    Deferred.unit

  let cleanup t =
    let%bind () = if t.deployed then destroy t else return () in
    [%log' info t.logger] "Cleaning up network configuration" ;
    let%bind () = File_system.remove_dir t.testnet_dir in
    Deferred.unit
end
