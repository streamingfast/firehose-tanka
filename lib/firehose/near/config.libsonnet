local tk = import 'tk';
local utils = import 'utils.libsonnet';

local MiB = (1024 * 1024);

(import 'images.libsonnet') + {
  _config: {
    local c = self,
    local nameAppend = utils.nameAppend,

    namespace: tk.env.spec.namespace,

    first_streamable_block: 0,

    fqdn: error 'you must set an fqdn (or empty string to skip creating managedCertificate and ingress)',
    deployment_tag: error 'you must set a resources version tag, ex: v3',
    blocks_version: error 'you must set a blocks version version tag, ex: v3',
    default_storage_url_prefix: error 'you must set default_storage_prefix (ex: gs://my-bucket)',

    storage_class: 'gcpssd-lazy',
    volume_mode: 'Filesystem',
    default_grpc_port: 9000,
    default_blocks_write_account: '',
    default_read_account: '',
    default_backup_write_account: '',
    common_auth_plugin: '',
    backup_service_accounts: std.prune([
      if self.default_blocks_write_account != '' then self.default_blocks_write_account,
      if self.default_backup_write_account != '' then self.default_backup_write_account,
    ]),

    relayer_address: '%s:%d' % [nameAppend('relayer', c.deployment_tag), c.default_grpc_port],
    extractor_addresses: [
      'dns:///%(name)s-0.%(name)s:%(port)d' % { name: nameAppend('extractor', c.deployment_tag), port: c.default_grpc_port },
      'dns:///%(name)s-1.%(name)s:%(port)d' % { name: nameAppend('extractor', c.deployment_tag), port: c.default_grpc_port },
    ],
    mergedBlockStoreUrl(config, version):: {
      url: '%s/%s%s' % [
        config.default_storage_url_prefix,
        config.namespace,
        '/' + version,
      ],
    },
    merged_blocks_url: c.mergedBlockStoreUrl(c, c.blocks_version).url,

    oneBlocksUrl(config, version):: {
      url: config.mergedBlockStoreUrl(config, version).url + '-oneblock',
    },
    one_blocks_url: c.oneBlocksUrl(c, c.blocks_version).url,

    indexedBlocksUrl(config, version):: {
      url: config.mergedBlockStoreUrl(config, version).url + '-idx',
    },
    indexed_blocks_url: c.indexedBlocksUrl(c, c.blocks_version).url,

    forkedBlocksUrl(config, version):: {
      url: config.mergedBlockStoreUrl(config, version).url + '-forked',
    },
    forked_blocks_url: c.forkedBlocksUrl(c, c.blocks_version).url,

    block_index_url: c.blockIndexURL(c, 'idx'),
    blockIndexURL(config, short_name):: '%s/%s%s' % [
      config.default_storage_url_prefix,
      config.namespace,
      '/' + short_name,
    ],

    public_interface: if c.fqdn != '' then {
      name: 'default-ingress',
      managed_certs: {
        [std.strReplace(c.fqdn, '.', '-')]: c.fqdn,
      },
      rules: [{
        host: c.fqdn,
        paths: [{ path: '', service: c.firehose.service_name, port: c.firehose.default_grpc_port }],
      }],
      extra_annotations: {},
    },


    // resource base configuration
    extractor: {
      name: nameAppend('extractor', c.deployment_tag),
      replicas: 2,
      resource: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
        disk: error 'resource.disk must be set',
        disk_storage_class: c.storage_class,
      },

      node_config_file: error 'you must set a node config file',
      node_genesis_file: error 'you must set a node genesis file',
      node_key_file: error 'you must set a node key file',
      backup_config: error 'you must define a backup config',

      one_blocks_url: c.one_blocks_url,
      merged_blocks_url: c.merged_blocks_url,
      first_streamable_block: c.first_streamable_block,
      default_grpc_port: c.default_grpc_port,
      readiness_max_latency_seconds: 3600,
      arguments: '',
      start_block_num: 0,
      stop_block_num: 0,
      working_directory: '/data/extractor',
    },

    archive: {
      name: 'archive',
      replicas: 1,
      resource: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
        disk: error 'resource.disk must be set',
        disk_storage_class: c.storage_class,
      },

      node_config_file: error 'you must set a node config file',
      node_genesis_file: error 'you must set a node genesis file',
      node_key_file: error 'you must set a node key file',

      backup_config: error 'you must set archive_node_backups',

      one_blocks_url: c.one_blocks_url,
      merged_blocks_url: c.merged_blocks_url,
      first_streamable_block: c.first_streamable_block,
      default_grpc_port: c.default_grpc_port,
      //node_config: error 'node_config must set, import data using "importstr ./path/to/file.yaml',
      //node_genesis: error 'node_genesis must set, import data using "importstr ./path/to/file.base64 (encode the content to base64 and saves it in the file)',
      //node_validator_identity: error 'node_validator_identity must set, import data using "importstr ./path/to/file.yaml',
      readiness_max_latency_seconds: 3600,
      arguments: '',
      start_block_num: 0,
      stop_block_num: 0,
      working_directory: '/data/extractor',
    },

    merger: {
      name: nameAppend('merger', c.deployment_tag),
      replicas: 1,
      resource: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
      },

      one_blocks_url: c.one_blocks_url,
      merged_blocks_url: c.merged_blocks_url,
      forked_blocks_url: c.forked_blocks_url,
      first_streamable_block: c.first_streamable_block,
      default_grpc_port: c.default_grpc_port,
      prune_forked_blocks_after: 50000,
      time_between_store_lookups: '5s',
      time_between_store_pruning: '60s',
    },

    firehose: {
      name: nameAppend('firehose', c.deployment_tag),
      replicas: 2,
      resource: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
        disk: error 'resource.disk must be set { size: <required>, storage_class: <required>, max_size: <optional> } size option must be able to hold "cache_age_bytes + cache_recent_bytes" total',
      },

      backend_config_name: 'streamingfast-backendconfig',

      cache_enabled: true,
      cache_age_bytes: 400 * MiB,
      cache_recent_bytes: 400 * MiB,
      common_auth_plugin: c.common_auth_plugin,
      common_system_shutdown_signal_delay: '30s',
      default_grpc_port: c.default_grpc_port,
      first_streamable_block: c.first_streamable_block,
      service_name: nameAppend('firehose', c.deployment_tag),
      block_index_url: c.block_index_url,
      indexed_blocks_url: c.indexed_blocks_url,
      merged_blocks_url: c.merged_blocks_url,
      one_blocks_url: c.one_blocks_url,
      common_blockstream_addr: c.relayer_address,
      substreams_enabled: false,
      //substreams_client_endpoint: '',
      //substreams_client_insecure: 'true',
      //substreams_client_plaintext: 'false',
      //substreams_output_cache_save_interval: '100',
      //substreams_partial_mode_enabled: 'false',
      //substreams_state_store_url: '',
      //substreams_sub_request_block_range_size: '10000',
      //substreams_sub_request_parallel_jobs: '0',
    },

    relayer: {
      name: nameAppend('relayer', c.deployment_tag),
      replicas: 2,
      resource: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
      },

      first_streamable_block: c.first_streamable_block,
      default_grpc_port: c.default_grpc_port,
      default_read_account: c.default_read_account,
      max_source_latency: '1h',
      extractor_addresses: c.extractor_addresses,
      one_blocks_url: c.one_blocks_url,
    },

    receipt_index_builder: {
      name: nameAppend('receipt-index-builder', self.deployment_tag),
      deployment_tag: c.deployment_tag,
      replicas: 1,

      index_size: 10000,
      lookup_index_sizes: ['10000', '1000', '100'],
      start_block: 0,
      stop_block: 0,

      default_grpc_port: c.default_grpc_port,
      merged_blocks_url: c.merged_blocks_url,
      indexed_blocks_url: c.indexed_blocks_url,
      first_streamable_block: c.first_streamable_block,

      resources: {
        limits: ['1', '4Gi'],
        requests: ['300m', '4Gi'],
      },

    },
  },
}
