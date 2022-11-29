local tk = import 'tk';
local utils = import 'utils.libsonnet';

local MiB = (1024 * 1024);

(import 'images.libsonnet') + {
  _config: {
    local c = self,
    local nameAppend = utils.nameAppend,

    namespace: tk.env.spec.namespace,

    first_streamable_block: 0,

    deployment_tag: error 'you must set a resources version tag, ex: v3',
    blocks_version: error 'you must set a blocks version version tag, ex: v3',
    default_storage_url_prefix: error 'you must set default_storage_prefix (ex: gs://my-bucket)',

    storage_class: 'gcpssd-lazy',
    volume_mode: 'Filesystem',
    default_grpc_port: 9000,
    default_blocks_write_account: '',
    default_read_account: '',
    common_auth_plugin: '',

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

    // resource base configuration
    reader: {
      name: nameAppend('reader', c.deployment_tag),
      replicas: 2,
      resource: {
        requests: error 'resource.requests must be set',
        limits: error 'resource.limits must be set',
        disk: { size: error 'resource.disk.size must be set', max_size: null, storage_class: $._config.storage_class },
      },

      one_blocks_url: c.one_blocks_url,
      merged_blocks_url: c.merged_blocks_url,
      first_streamable_block: c.first_streamable_block,
      default_grpc_port: c.default_grpc_port,
      node_config: error 'node_config must set, import data using "importstr ./path/to/file.yaml',
      node_genesis: error 'node_genesis must set, either user url "https://..." or import data using "importstr ./path/to/file.base64 (encode the content to base64 and saves it in the file)',
      // Optional field, either user url "https://..." or import data using "importstr './path/to/file.yaml'" or content direclty
      node_waypoint: '',
      // Optional field, import data using "importstr ./path/to/file.yaml'
      node_validator_identity: '',
      // Optional field, import data using "importstr ./path/to/file.yaml'
      node_vfn_identity: '',

      readiness_max_latency_seconds: 3600,
      arguments: '',
      start_block_num: 0,
      stop_block_num: 0,
      working_directory: '/data/reader',
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
        disk: { size: null, max_size: null, storage_class: $._config.storage_class },
      },

      blocks_cache_enabled: false,
      blocks_cache_age_bytes: 400 * MiB,
      blocks_cache_recent_bytes: 400 * MiB,
      common_auth_plugin: c.common_auth_plugin,
      common_system_shutdown_signal_delay: '30s',
      default_grpc_port: c.default_grpc_port,
      first_streamable_block: c.first_streamable_block,
      service_name: nameAppend('firehose', c.deployment_tag),
      merged_blocks_url: c.merged_blocks_url,
      one_blocks_url: c.one_blocks_url,
      relayer_address: error 'firehose.relayer_address must set, you can use \'"dns:///%s" % k.util.internalServiceAddr($.relayer, "relayer-grpc")"\'',
      substreams_client_endpoint: '',
      substreams_client_insecure: 'true',
      substreams_client_plaintext: 'false',
      substreams_enabled: false,
      substreams_output_cache_save_interval: '100',
      substreams_partial_mode_enabled: 'false',
      substreams_state_store_url: '',
      substreams_sub_request_block_range_size: '10000',
      substreams_sub_request_parallel_jobs: '0',
      real_time_tolerance: '5m',
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

      // You can use the following pattern to defined your address:
      //
      //     local readerService = k.util.internalServiceName($.fireaptos.reader),
      //
      //     reader_addresses: [
      //       "dns:///%s:%s:%d" % [k.util.podNameFromSts($.fireaptos.reader, 0), readerService, c.default_grpc_port],
      //       "dns:///%s:%s:%d" % [k.util.podNameFromSts($.fireaptos.reader, 1), readerService, c.default_grpc_port]
      //     ],
      reader_addresses: error 'relayer.reader_addresses must set, see comment above this line for extended samples',
      one_blocks_url: c.one_blocks_url,
    },
  },
}
