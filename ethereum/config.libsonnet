local tk = import 'tk';
local MiB = (1024 * 1024);
local GiB = (1024 * 1024 * 1024);

local append(name, tag) = (if tag == '' then name else '%s-%s' % [name, tag]);

(import 'images.libsonnet') + {
  _config+:: {
    local top = self,

    namespace: tk.env.spec.namespace,
    fqdn: error 'you must set an fqdn (or empty string to bypass public_interface)',

    deployment_tag: '',
    blocks_version: error 'you must set a blocks version version tag, ex: v3',
    storage_class: 'gcpssd-lazy',
    volume_mode: 'Filesystem',

    first_streamable_block: 0,
    default_storage_url_prefix: error 'you must set default_storage_prefix (ex: gs://my-bucket)',
    merged_blocks_url_suffix: '/' + self.blocks_version,
    relayer_address: (if std.get(top, 'relayer') != null then 'dns:///%s:%d' % [append('relayer', self.deployment_tag), top.relayer.default_grpc_port] else ''),

    default_dlog: '.*=info',
    default_db_writer: '',
    default_blocks_write_account: '',
    default_read_account: '',
    default_backup_write_account: '',
    backup_service_accounts: std.prune([
      if self.default_blocks_write_account != '' then self.default_blocks_write_account,
      if self.default_backup_write_account != '' then self.default_backup_write_account,
    ]),

    chain_id: 1,
    chain_consensus_algorithm: 'pow',  // Valid values: 'pow', 'pos'
    network_id: 1,

    node_jwt_secret: '',
    node_readiness_max_latency_seconds: 600,

    default_extra_env_vars: {},
    common_auth_plugin: '',

    default_grpc_port: 9000,


    merged_blocks_url_prefix: self.default_storage_url_prefix,
    merged_blocks_url: '%s/%s%s' % [
      self.merged_blocks_url_prefix,
      self.namespace,
      self.merged_blocks_url_suffix,
    ],
    one_blocks_url: self.merged_blocks_url + '-oneblock',
    forked_blocks_url: self.merged_blocks_url + '-forked',

    block_index_url: self.merged_blocks_url + '-idx',

    // Default resource config
    backup: {
      name: append('backup', self.deployment_tag),
      deployment_tag: top.deployment_tag,
      replicas: 1,
      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
        disk: error 'resource.disk must be set',
        disk_max: '3Ti',
        disk_storage_class: top.storage_class,
      },
      dlog: top.default_dlog,
      extra_env_vars: top.default_extra_env_vars,
      arguments: '',
      backup_config: error 'you must define a backup config to use a backup node',
      default_grpc_port: top.default_grpc_port,
      readiness_max_latency_seconds: top.node_readiness_max_latency_seconds,
    },

    consensus: {
      name: append('consensus', self.deployment_tag),
      deployment_tag: top.deployment_tag,
      replicas: 1,

      resources: {
        requests: ['4', '4Gi'],
        limits: ['4', '8Gi'],
        disk: { size: '32Gi', max_size: '100Gi', storage_class: top.storage_class },
      },

      dlog: top.default_dlog,
      extra_env_vars: top.default_extra_env_vars,
      api_port: 5052,
      p2p_port: 9000,
      network: error '"network" must be defined',
      execution_endpoint: error '"execution_endpoint" must be set to a valid node endpoint and port should match node --authrpc.port value of Reader',
    },

    evm_executor: {
      local evm_executor = self,

      labels: { version: top.deployment_tag },
      default_grpc_port: top.default_grpc_port,
      merged_blocks_url: top.merged_blocks_url,
      one_blocks_url: top.one_blocks_url,
      name_suffix: '',
      common_auth_plugin: top.common_auth_plugin,
      relayer_address: top.relayer_address,
      store_dsn: 'badger://{data-dir}/db',
      extra_env_vars: {},

      executor: {
        enabled: true,
        name: 'evm-executor',
        replicas: 2,

        resources: {
          requests: ['1', '100Mi'],
          limits: ['2', '1Gi'],
        },

        timeout_sec: 900,
        dlog: top.default_dlog,
        extra_env_vars: top.default_extra_env_vars,
        chain: error 'executor.chain must be set to a supported chain',
        listen_addr: ':%d' % self.listen_addr_port,
        listen_addr_port: 8080,
        state_provider_dsn: (
          if evm_executor.statedb.deployment == 'single' then
            'statedb://statedb-hybrid%s:%s' % [evm_executor.name_suffix, evm_executor.default_grpc_port]
          else
            'statedb://statedb-server%s:%s' % [evm_executor.name_suffix, evm_executor.default_grpc_port]
        ),
      },

      statedb: {
        name: 'statedb',
        // Deployment determines if StateDB runs a single StatefulSet that does both indexing
        // and serving ('single') or if they are split in two, one StatefulSet for indexing
        // and one Deployment for serving.
        deployment: 'split',
        store_dsn_params: '',  //'?createTable=true',

        // Only used (indexer & server) when deployment is 'split'
        indexer: {
          replicas: 1,

          resources: {
            requests: ['1', '500Mi'],
            limits: ['1', '800Mi'],
            disk: error 'statedb.indexer.disk must be specified, use empty string to denote remote database usage',
            disk_storage_class: top.storage_class,
          },

          dlog: top.default_dlog,
          extra_env_vars: top.default_extra_env_vars,
          default_grpc_port: evm_executor.default_grpc_port,
          merged_blocks_url: evm_executor.merged_blocks_url,
          one_blocks_url: evm_executor.one_blocks_url,
          relayer_address: evm_executor.relayer_address,
        },

        server: {
          replicas: 1,

          resources: {
            requests: ['500m', '250Mi'],
            limits: ['1', '500Mi'],
          },

          dlog: top.default_dlog,
          extra_env_vars: top.default_extra_env_vars,
          default_grpc_port: evm_executor.default_grpc_port,
          merged_blocks_url: evm_executor.merged_blocks_url,
          one_blocks_url: evm_executor.one_blocks_url,
          relayer_address: evm_executor.relayer_address,
        },

        // Only used when deployment is 'single'
        hybrid: {
          replicas: 1,

          resources: {
            requests: ['1', '500Mi'],
            limits: ['1', '800Mi'],
            disk: error 'statedb.hybrid.disk must be specified, use empty string to denote remote database usage',
            disk_storage_class: top.storage_class,
          },

          dlog: top.default_dlog,
          extra_env_vars: top.default_extra_env_vars,
          default_grpc_port: evm_executor.default_grpc_port,
          merged_blocks_url: evm_executor.merged_blocks_url,
          relayer_address: evm_executor.relayer_address,
        },
      },
    },

    relayer: {
      name: append('relayer', self.deployment_tag),
      deployment_tag: top.deployment_tag,
      replicas: 2,

      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
      },

      dlog: top.default_dlog,
      extra_env_vars: top.default_extra_env_vars,
      first_streamable_block: top.first_streamable_block,
      reader_name: append('reader', self.deployment_tag),
      reader_port: top.reader.default_grpc_port,
      default_grpc_port: top.default_grpc_port,
      one_blocks_url: top.one_blocks_url,
      max_source_latency: '5m',
      reader_addresses:
        (if std.get(top, 'reader') != null then [
           'dns:///%s-0.%s:%d' % [self.reader_name, self.reader_name, self.reader_port],
           'dns:///%s-1.%s:%d' % [self.reader_name, self.reader_name, self.reader_port],
         ] else []),
    },

    firehose: {
      name: append('firehose', self.deployment_tag),
      deployment_tag: top.deployment_tag,
      replicas: 2,

      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
      },

      with_grpc_health_port: false,
      dlog: top.default_dlog,
      extra_env_vars: top.default_extra_env_vars,
      service_account: if self.substreams_enabled then $._config.default_blocks_write_account else $._config.default_read_account,
      backend_config_name: 'firehose-backend-config',
      first_streamable_block: top.first_streamable_block,
      block_index_url: top.block_index_url,
      common_auth_plugin: top.common_auth_plugin,
      common_system_shutdown_signal_delay: '30s',
      default_grpc_port: top.default_grpc_port,
      discoveryServiceURL: '',
      service_name: append('firehose', self.deployment_tag),
      merged_blocks_url: top.merged_blocks_url,
      one_blocks_url: top.one_blocks_url,
      forked_blocks_url: top.forked_blocks_url,
      relayer_address: top.relayer_address,
      substreams_enabled: false,
    },

    substreams_tier1: {
      name: append('substreams', self.deployment_tag) + '-tier1',
      deployment_tag: top.deployment_tag,
      replicas: 2,

      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
      },

      dlog: top.default_dlog,
      extra_env_vars: top.default_extra_env_vars,
      service_account: if self.substreams_enabled then $._config.default_blocks_write_account else $._config.default_read_account,
      backend_config_name: 'firehose-backend-config',
      first_streamable_block: top.first_streamable_block,
      block_index_url: top.block_index_url,
      common_auth_plugin: top.common_auth_plugin,
      common_system_shutdown_signal_delay: '30s',
      default_grpc_port: top.default_grpc_port,
      discoveryServiceURL: '',
      service_name: append('substreams', self.deployment_tag) + '-tier1',
      merged_blocks_url: top.merged_blocks_url,
      one_blocks_url: top.one_blocks_url,
      forked_blocks_url: top.forked_blocks_url,
      relayer_address: top.relayer_address,

      with_grpc_health_port: false,
      substreams_tier2_name: append('substreams', self.deployment_tag) + '-tier2',
      substreams_tier2_port: top.substreams_tier2.default_grpc_port,
      substreams_client_endpoint: '',
      substreams_client_insecure: 'true',
      substreams_client_plaintext: 'false',
      substreams_enabled: true,
      substreams_output_cache_save_interval: '100',
      substreams_partial_mode_enabled: 'false',
      substreams_rpc_endpoints: [],
      substreams_rpc_cache_store_url: '',
      substreams_state_store_url: '',
      substreams_sub_request_block_range_size: '10000',
      substreams_sub_request_parallel_jobs: '0',
      substreams_stores_save_interval: '1000',
      substreams_request_stats_enabled: false,
    },

    substreams_tier2: {
      name: append('substreams', self.deployment_tag) + '-tier2',
      deployment_tag: top.deployment_tag,
      replicas: 4,
      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
      },
      merged_blocks_url: top.merged_blocks_url,
      block_index_url: top.block_index_url,
      forked_blocks_url: top.forked_blocks_url,
      dlog: top.default_dlog,
      extra_env_vars: top.default_extra_env_vars,

      cache_recent_bytes: 2 * GiB,
      cache_age_bytes: 2 * GiB,
      common_system_shutdown_signal_delay: '0',
      image_pull_policy: 'IfNotPresent',
      node_pool: 'hpchaos-c2-8-32',

      service_account: top.default_blocks_write_account,
      backend_config_name: 'firehose-backend-config',
      first_streamable_block: top.first_streamable_block,
      common_auth_plugin: top.common_auth_plugin,
      default_grpc_port: top.default_grpc_port,
      discoveryServiceURL: '',
      service_name: append('firehose', self.deployment_tag),
      one_blocks_url: top.one_blocks_url,

      with_grpc_health_port: false,
      substreams_tier2_name: append('substreams-tier2', self.deployment_tag),
      substreams_tier2_port: top.substreams_tier2.default_grpc_port,
      substreams_client_endpoint: '',
      substreams_client_insecure: 'true',
      substreams_client_plaintext: 'false',
      substreams_enabled: true,
      substreams_output_cache_save_interval: '100',
      substreams_partial_mode_enabled: 'false',
      substreams_rpc_endpoints: [],
      substreams_rpc_cache_store_url: '',
      substreams_state_store_url: '',
      substreams_sub_request_block_range_size: '10000',
      substreams_sub_request_parallel_jobs: '0',
      substreams_stores_save_interval: '1000',
      substreams_request_stats_enabled: false,
    },

    merger: {
      name: append('merger', self.deployment_tag),
      deployment_tag: top.deployment_tag,
      replicas: 1,

      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
      },

      dlog: top.default_dlog,
      extra_env_vars: top.default_extra_env_vars,
      prune_forked_blocks_after: 200000,
      first_streamable_block: top.first_streamable_block,
      default_grpc_port: top.default_grpc_port,
      merged_blocks_url: top.merged_blocks_url,
      one_blocks_url: top.one_blocks_url,
      forked_blocks_url: top.forked_blocks_url,
    },

    reader: {
      name: append('reader', self.deployment_tag),
      deployment_tag: top.deployment_tag,
      replicas: 2,

      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
        disk: error 'resource.disk must be set',
        disk_max: '3Ti',
        disk_storage_class: top.storage_class,
      },

      dlog: top.default_dlog,
      extra_env_vars: top.default_extra_env_vars,
      first_streamable_block: top.first_streamable_block,
      auth_port: 8551,
      auth_jwt_secret: top.node_jwt_secret,  // Set to a JWT token that is used to authenticated request from Consensus nodes
      rpc_port: 8545,
      arguments: '',
      bootstrap_data_url: '',  // set to same as miner if you are producing blocks on a dev chain
      default_grpc_port: top.default_grpc_port,
      enforce_peers: '',  // set 'miner' here if you are producing blocks on a dev chain
      one_blocks_url: top.one_blocks_url,

      readiness_max_latency_seconds: top.node_readiness_max_latency_seconds,
    },

    miner: {
      name: append('miner', self.deployment_tag),
      deployment_tag: top.deployment_tag,
      replicas: 1,

      resources: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
        disk: error 'resource.disk must be set',
        disk_max: '500Gi',
        disk_storage_class: top.storage_class,
      },

      dlog: top.default_dlog,
      extra_env_vars: top.default_extra_env_vars,
      arguments: '',
      bootstrap_data_url: '',  // set to same as miner if you are producing blocks on a dev chain
      default_grpc_port: top.default_grpc_port,
      nodekey: error 'you must set the nodekey to use a dev miner',
    },

    combined_index_builder: {
      name: append('combined-index-builder', self.deployment_tag),
      deployment_tag: top.deployment_tag,
      replicas: 1,

      index_size: 10000,
      lookup_index_sizes: ['100', '1000', '10000'],
      start_block: 0,
      stop_block: 0,

      block_index_url: top.block_index_url,
      default_grpc_port: top.default_grpc_port,
      merged_blocks_url: top.merged_blocks_url,
      first_streamable_block: top.first_streamable_block,

      resources: {
        limits: ['1', '4Gi'],
        requests: ['300m', '4Gi'],
      },
      dlog: top.default_dlog,
      extra_env_vars: top.default_extra_env_vars,

    },

    public_interface: if top.fqdn != '' then {
      name: 'default-ingress',
      managed_certs: {
        [std.strReplace(top.fqdn, '.', '-')]: top.fqdn,
      },
      rules: [{
        host: top.fqdn,
        paths: [{ path: '', service: top.firehose.service_name, port: top.firehose.default_grpc_port }],
      }],
      extra_annotations: {},
    },
  },
}
